# GB10 Temperature Monitor

Thermal logs and a GPU guard for a GB10 box that runs hot under sustained
GPU load. Two things live here:

1. **A thermal report** (`index.html`) - what temperatures the box actually
   hit over several months of local AI work.
2. **A GPU guard package** - system-wide thermal pacing that pauses
   GPU-heavy workloads when the box gets too hot and resumes them when it
   cools down.

If you run local AI workloads on a GB10 machine (hermes gateways,
sglang/vllm/llama servers, comfy-worker, anything in docker) and want to
reduce heat wear and tear, the guard package is for you.

## Thermal report

Static report of the local GX10 monitor logs from **2026-05-25** through
**2026-09-12**.

- Highest CPU: **98°C** at `2026-08-16 21:05:50`
- Highest GPU: **90°C** at `2026-07-20 14:04:52`
- Records reviewed: **896,626** (5704 malformed lines excluded)

Open `index.html` locally or publish with GitHub Pages.

## GPU guard package

System-wide thermal pacing for the whole box, covering every local AI
workload - not just one app's jobs.

- `gpu-guard.sh` - thermal guard daemon. Polls GPU temp via `nvidia-smi`.
  Above the hold threshold (default **82C**) it `docker pause`s GPU-heavy
  containers (everything running except a whitelist) and can optionally stop
  user systemd services. When the GPU stays under the resume threshold
  (default **74C**) for a stable interval, it unpauses only what it paused.
  Fails open with a warning if no temp is readable. Optional Telegram alerts
  on hold/resume via env vars (runs fine without them).
- `gpu-pacer.sh` - duty-cycle pacer for batch jobs. Serializes jobs per lane
  and enforces rests: **60s rest per 1800s of accumulated busy time**, with
  idle-gap reset.
- `gpu-guard.service` - systemd unit to run the guard at boot
  (`After=nvidia-persistenced.service docker.service`).

### Install

See `INSTALL.md` for full steps, config knobs, dry-run mode, verification
(`journalctl -u gpu-guard`, `watch nvidia-smi`), and rollback. Short version:

```bash
sudo cp gpu-guard.sh /usr/local/bin/gpu-guard.sh
sudo cp gpu-guard.service /etc/systemd/system/gpu-guard.service
sudo systemctl enable --now gpu-guard.service
```
