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

## Dry-run testing (block two)

Use dry-run mode before enabling active protection. The guard will read the
real GPU temperature and report the containers it would pause, but it will not
pause containers or stop user services.

Install the guard and create a dry-run configuration:

```bash
cd ~/gb10_guard
sudo install -m 0755 gpu-guard.sh /usr/local/bin/gpu-guard.sh
sudo install -m 0644 gpu-guard.service /etc/systemd/system/gpu-guard.service
sudo tee /etc/default/gpu-guard >/dev/null <<'EOF'
GUARD_HOLD_TEMP_C=82
GUARD_RESUME_TEMP_C=74
GUARD_POLL_SEC=20
GUARD_MIN_HOLD_SEC=60
GUARD_RESUME_STABLE_SEC=120
GUARD_WHITELIST=
GUARD_USER_SERVICES=
GUARD_DRY_RUN=1
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-guard.service
```

Watch the guard without affecting workloads:

```bash
journalctl -u gpu-guard.service -f
```

To exercise the hold path without heating the machine, temporarily set the
hold threshold below the current GPU temperature. For example, if the GPU is
currently 75C:

```bash
sudo sed -i 's/^GUARD_HOLD_TEMP_C=.*/GUARD_HOLD_TEMP_C=74/' /etc/default/gpu-guard
sudo systemctl restart gpu-guard.service
journalctl -u gpu-guard.service -f
```

You should see a `HOLD` message followed by `[dry-run] would pause container:`
messages. Confirm that workloads remain usable with `docker ps` and that no
container is paused:

```bash
docker ps --filter status=paused
```

Restore the normal thresholds after the test:

```bash
sudo sed -i 's/^GUARD_HOLD_TEMP_C=.*/GUARD_HOLD_TEMP_C=82/' /etc/default/gpu-guard
sudo systemctl restart gpu-guard.service
```

Keep `GUARD_DRY_RUN=1` until you have reviewed the proposed container list.
To enable active protection later, set it to `0`, configure a deliberate
`GUARD_WHITELIST`, and restart the service:

```bash
sudo sed -i 's/^GUARD_DRY_RUN=1/GUARD_DRY_RUN=0/' /etc/default/gpu-guard
sudo systemctl restart gpu-guard.service
```

Do not use an empty whitelist in active mode unless you intentionally want
all running Docker containers to be eligible for pausing.

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
