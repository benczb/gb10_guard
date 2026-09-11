# GB10 Temperature Monitor

Static report of the local GX10 monitor logs from **2026-05-25** through **2026-09-12**.

- Highest CPU: **98°C** at `2026-08-16 21:05:50`
- Highest GPU: **90°C** at `2026-07-20 14:04:52`
- Records reviewed: **896,626** (5704 malformed lines excluded)

Open `index.html` locally or publish with GitHub Pages.

## GPU guard package

System-wide thermal pacing for the whole GX10 box, covering every local AI
workload (hermes gateways, sglang/vllm/llama servers, comfy-worker, anything
in docker) - not just one app's jobs. Built to reduce wear and tear on a
GB10 machine that runs hot under sustained GPU load.

### What it does

- `gpu-guard.sh` - thermal guard daemon. Polls GPU temp via `nvidia-smi`.
  Above the hold threshold (default **82C**) it `docker pause`s GPU-heavy
  containers (everything running except a whitelist) and can optionally stop
  user systemd services. When the GPU stays under the resume threshold
  (default **74C**) for a stable interval, it unpauses only what it paused.
  Fails open with a warning if no temp is readable. Optional Telegram alerts
  on hold/resume via env vars (runs fine without them).
- `gpu-pacer.sh` - duty-cycle pacer for batch jobs. Serializes jobs per lane
  and enforces rests mirroring Sogni's worker defaults: **60s rest per 1800s
  of accumulated busy time**, with idle-gap reset.
- `gpu-guard.service` - systemd unit to run the guard at boot
  (`After=nvidia-persistenced.service docker.service`).

### Why

Sogni's fast-worker ships its own GPU guard and render rests, but that only
paces Sogni jobs. This package gives the same style of protection to every
other workload on the box.

### Config

Env vars in `/etc/default/gpu-guard`: hold/resume temps, poll interval,
minimum hold, resume-stable window, container whitelist, optional
`systemctl --user` service list (set `GUARD_SVC_USER` to the desktop user),
optional Telegram `BOT_TOKEN`/`CHAT_ID`.

### Install

See `INSTALL.md` for full steps, dry-run mode, verification
(`journalctl -u gpu-guard`, `watch nvidia-smi`), and rollback. Short version:

```bash
sudo cp gpu-guard.sh /usr/local/bin/gpu-guard.sh
sudo cp gpu-guard.service /etc/systemd/system/gpu-guard.service
sudo systemctl enable --now gpu-guard.service
```

### Honest limits

This is thermal pacing only. It cannot fix power-delivery or PSU limits and
would not have prevented hard power losses. It pairs with a GPU clock cap
(e.g. 2200MHz via `nvidia-smi -lgc` + systemd) as the always-on layer. OOM
protection for the 128GB unified memory is separate: cap concurrent heavy
processes and install `earlyoom` (see INSTALL.md).
