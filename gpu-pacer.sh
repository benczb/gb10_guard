#!/usr/bin/env bash
# gpu-pacer.sh - duty-cycle pacer for heavy batch GPU jobs on the GX10.
# Serializes jobs per named lane and enforces a rest after accumulated busy
# time, mirroring Sogni's COOLDOWN_RENDER_SEC/COOLDOWN_REST_SEC defaults.
# An idle gap >= rest duration satisfies the rest (same as Sogni).
#
# Usage:
#   gpu-pacer.sh [--lane NAME] -- command args...
# Env knobs: PACER_RENDER_SEC (default 1800), PACER_REST_SEC (default 60),
#            PACER_STATE_DIR (default ~/.local/state/gpu-pacer)
set -uo pipefail

RENDER_SEC="${PACER_RENDER_SEC:-1800}"
REST_SEC="${PACER_REST_SEC:-60}"
STATE_DIR="${PACER_STATE_DIR:-$HOME/.local/state/gpu-pacer}"
LANE="default"

while [ $# -gt 0 ]; do
  case "$1" in
    --lane) LANE="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "gpu-pacer: unknown arg $1 (expected --lane NAME or --)" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: gpu-pacer.sh [--lane NAME] -- command args..." >&2; exit 2; }

mkdir -p "$STATE_DIR"
LEDGER="$STATE_DIR/$LANE.env"
LOCK="$STATE_DIR/$LANE.lock"

log() { echo "$(date '+%F %T') gpu-pacer[$LANE]: $*"; logger -t gpu-pacer "[$LANE] $*" 2>/dev/null || true; }

# one job per lane at a time
exec 9>"$LOCK"
flock 9

ACCUM=0; LAST_END=0
[ -f "$LEDGER" ] && . "$LEDGER"

now=$(date +%s)
# an idle gap >= REST_SEC already satisfies the rest
if [ "$LAST_END" -gt 0 ] && [ $((now - LAST_END)) -ge "$REST_SEC" ]; then
  ACCUM=0
fi
if [ "$ACCUM" -ge "$RENDER_SEC" ]; then
  log "accumulated ${ACCUM}s busy >= ${RENDER_SEC}s - resting ${REST_SEC}s before starting"
  sleep "$REST_SEC"
  ACCUM=0
fi

log "starting: $* (accum busy ${ACCUM}s / ${RENDER_SEC}s)"
start=$(date +%s)
"$@"
rc=$?
end=$(date +%s)
ACCUM=$((ACCUM + end - start))
printf 'ACCUM=%s\nLAST_END=%s\n' "$ACCUM" "$end" > "$LEDGER"
log "finished rc=$rc in $((end - start))s (accum busy ${ACCUM}s / ${RENDER_SEC}s)"
exit "$rc"
