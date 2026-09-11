# GX10 system-wide GPU guard

Thermal pacing for the whole box, Sogni-style, covering every local AI
workload (hermes gateways, sglang/vllm/llama servers, comfy-worker, anything
in docker). Two parts:

- `gpu-guard.sh` - daemon: above a hold temp, pauses GPU-heavy containers and
  (optionally) stops user services; resumes them when the GPU cools.
- `gpu-pacer.sh` - wrapper: serializes batch jobs per lane and enforces a rest
  after accumulated busy time (same defaults as Sogni: rest 60s per 1800s busy).

Requires: bash, nvidia-smi, docker, flock, curl (only if you want Telegram alerts).

## Install

```bash
mkdir -p ~/backups/scripts
cp gpu-guard.sh gpu-pacer.sh ~/backups/scripts/
chmod +x ~/backups/scripts/gpu-guard.sh ~/backups/scripts/gpu-pacer.sh
sudo cp ~/backups/scripts/gpu-guard.sh /usr/local/bin/gpu-guard.sh
sudo cp gpu-guard.service /etc/systemd/system/gpu-guard.service

# config
sudo tee /etc/default/gpu-guard <<'EOF'
GUARD_HOLD_TEMP_C=82
GUARD_RESUME_TEMP_C=74
GUARD_POLL_SEC=20
GUARD_MIN_HOLD_SEC=60
GUARD_RESUME_STABLE_SEC=120
GUARD_WHITELIST=portainer,watchtower
GUARD_SVC_USER=ben
GUARD_USER_SERVICES=
# optional Telegram alerts:
# GUARD_TG_BOT_TOKEN=
# GUARD_TG_CHAT_ID=
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gpu-guard
```

Dry-run first if you want to watch decisions without pausing anything:
add `GUARD_DRY_RUN=1` to /etc/default/gpu-guard, restart, watch the log.

## Config knobs

| Var | Default | Meaning |
|---|---|---|
| GUARD_HOLD_TEMP_C | 82 | pause workloads at/above this core temp |
| GUARD_RESUME_TEMP_C | hold - 8 | resume at/below this |
| GUARD_POLL_SEC | 20 | sample interval |
| GUARD_MIN_HOLD_SEC | 60 | never resume before this |
| GUARD_RESUME_STABLE_SEC | 120 | temp must stay under resume this long |
| GUARD_WHITELIST | (empty) | comma-separated container names never paused |
| GUARD_USER_SERVICES | (empty) | comma-separated systemctl --user units to stop/start |
| GUARD_SVC_USER | ben | user that owns those --user services |
| GUARD_TG_BOT_TOKEN / GUARD_TG_CHAT_ID | (empty) | Telegram alerts; runs fine without |

Note: containers that exit/restart on their own while paused are simply skipped
on resume (logged as WARN). The guard only unpauses what it paused.

## Using the pacer

Wrap any heavy batch command:

```bash
~/backups/scripts/gpu-pacer.sh -- python3 render_batch.py --all
~/backups/scripts/gpu-pacer.sh --lane video -- python3 wan22_batch.py
```

Env knobs: PACER_RENDER_SEC (1800), PACER_REST_SEC (60), PACER_STATE_DIR.
Lanes are independent queues; jobs in one lane run one at a time (flock).
An idle gap >= rest duration counts as the rest, same as Sogni's rule.

## Verify

```bash
journalctl -u gpu-guard -f          # guard decisions
watch -n2 nvidia-smi                # temp + clocks
docker ps                           # (Paused) shows on held containers
```

Force a test without heat: set GUARD_HOLD_TEMP_C below current temp, restart
the service, watch the pauses in journalctl, then set it back and restart.

## Rollback / uninstall

```bash
sudo systemctl disable --now gpu-guard
# resume anything still paused:
for c in $(docker ps -q --filter status=paused); do docker unpause $c; done
sudo rm /etc/systemd/system/gpu-guard.service /usr/local/bin/gpu-guard.sh /etc/default/gpu-guard
sudo systemctl daemon-reload
# pacer: just stop calling it; rm -rf ~/.local/state/gpu-pacer
```

## Honest notes

- This is thermal pacing. It cannot fix power delivery. Your suspected
  PSU-limit hard power losses need the clock cap, not this - keep the
  2200MHz cap as the always-on layer; the guard is the second layer on top.
- The guard fails open on purpose: if nvidia-smi can't return a temp it does
  nothing. Check `journalctl -u gpu-guard` once after install to confirm it
  reads your GB10 temp.
- docker pause freezes a container instantly but holds its memory. A paused
  13-gateway pile still occupies unified memory; it just stops burning GPU.
- 128GB unified memory OOM is a separate problem: cap concurrent hermes
  gateways (13 at once is a lot for one box) and install earlyoom
  (`sudo apt install earlyoom`) so the kernel kills the fattest process
  instead of hanging the whole box.
