# GB10 Temperature Monitor

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE-APACHE)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE-MIT)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE-GPL)

Thermal logs and a GPU guard for a GB10 box that runs hot under sustained
GPU load - built because months of local AI work (hermes gateways,
sglang/vllm/llama servers, comfy-worker, all in docker) pushed the box to
98C CPU / 90C GPU peaks, and nothing was pacing the heat.

If you run local AI workloads on a GB10 machine and want to reduce heat
wear and tear, the guard package is for you.

## What's in this repo

Two things live here:

1. **A thermal report** (`index.html`) - what temperatures the box actually
   hit over several months of local AI work.
2. **A GPU guard package** - system-wide thermal pacing that pauses
   GPU-heavy workloads when the box gets too hot and resumes them when it
   cools down.

## Temperature monitor

The live monitor service and script are versioned here as `monitor_gx10.sh` and
`gx10-monitor.service`. The data dashboard has been moved to the dedicated
[asus-gx10-monitor](https://github.com/benczb/asus-gx10-monitor) repository.

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

## Install

Requires: bash, nvidia-smi, docker, flock, curl (only if you want Telegram
alerts).

See [INSTALL.md](INSTALL.md) for full steps, config knobs, dry-run mode,
verification (`journalctl -u gpu-guard`, `watch nvidia-smi`), rollback, and
honest notes on what the guard can and cannot fix. Short version:

```bash
sudo cp gpu-guard.sh /usr/local/bin/gpu-guard.sh
sudo cp gpu-guard.service /etc/systemd/system/gpu-guard.service
sudo systemctl enable --now gpu-guard.service
```

## Using the pacer

Wrap any heavy batch command so it rests on a duty cycle:

```bash
~/backups/scripts/gpu-pacer.sh -- python3 render_batch.py --all
~/backups/scripts/gpu-pacer.sh --lane video -- python3 wan22_batch.py
```

Lanes are independent queues; jobs in one lane run one at a time. Env knobs:
`PACER_RENDER_SEC` (1800), `PACER_REST_SEC` (60), `PACER_STATE_DIR`. See
[INSTALL.md](INSTALL.md) for details.

## Notes

- The guard only ever unpauses what it paused; containers that exit or
  restart on their own while paused are skipped on resume (logged as WARN).
- The guard fails open on purpose: if `nvidia-smi` can't return a temp it
  does nothing. Check `journalctl -u gpu-guard` once after install to
  confirm it reads your GB10 temp.

## Contributing

Issues and PRs welcome. If you change the guard, test with `GUARD_DRY_RUN=1`
first (see [INSTALL.md](INSTALL.md)) so it logs decisions without pausing
anything.

## License

Take your pick: [Apache-2.0](LICENSE-APACHE), [MIT](LICENSE-MIT), or
[GPL-3.0](LICENSE-GPL).
