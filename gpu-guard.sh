#!/usr/bin/env bash
# gpu-guard.sh - system-wide GPU thermal guard for the GX10.
# Polls GPU temp/power via nvidia-smi. At/above HOLD temp, pauses GPU-heavy
# docker containers (all running except whitelist) and optionally stops
# user-level services. Below RESUME temp for a stable interval (and after a
# minimum hold), unpauses exactly what it paused. Logs to journald/stdout.
# Optional Telegram alert on hold/resume via GUARD_TG_BOT_TOKEN/CHAT_ID.
set -uo pipefail

HOLD_TEMP="${GUARD_HOLD_TEMP_C:-82}"
RESUME_TEMP="${GUARD_RESUME_TEMP_C:-$((HOLD_TEMP - 8))}"
POLL="${GUARD_POLL_SEC:-20}"
MIN_HOLD="${GUARD_MIN_HOLD_SEC:-60}"
RESUME_STABLE="${GUARD_RESUME_STABLE_SEC:-120}"
WHITELIST="${GUARD_WHITELIST:-}"            # comma-separated exact container names, never paused
USER_SERVICES="${GUARD_USER_SERVICES:-}"    # comma-separated systemctl --user units to stop/start
SVC_USER="${GUARD_SVC_USER:-${SUDO_USER:-$(whoami)}}"
NVIDIA_SMI="${NVIDIA_SMI_BIN:-nvidia-smi}"
DOCKER="${DOCKER_BIN:-docker}"
STATE_FILE="${GUARD_STATE_FILE:-$HOME/.local/state/gpu-guard.paused}"
TG_TOKEN="${GUARD_TG_BOT_TOKEN:-}"
TG_CHAT="${GUARD_TG_CHAT_ID:-}"
DRY_RUN="${GUARD_DRY_RUN:-0}"

mkdir -p "$(dirname "$STATE_FILE")"

log() {
  local msg="gpu-guard: $*"
  echo "$(date '+%F %T') $msg"
  logger -t gpu-guard "$*" 2>/dev/null || true
}

alert() {
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
  curl -sS -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT" --data-urlencode "text=GX10 gpu-guard: $*" >/dev/null 2>&1 || true
}

read_gpu() {
  # prints "temp power_w" or nothing on failure (fail-open: we only act on valid temps)
  "$NVIDIA_SMI" --query-gpu=temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null \
    | head -n1 | awk -F',' '{gsub(/ /,""); t=$1+0; p=$2+0; if (t>0) print t, p}'
}

is_whitelisted() {
  local name="$1" w
  IFS=',' read -ra items <<< "$WHITELIST"
  for w in "${items[@]:-}"; do [ -n "$w" ] && [ "$name" = "$w" ] && return 0; done
  return 1
}

pause_targets() {
  "$DOCKER" ps --format '{{.Names}}' 2>/dev/null | while read -r c; do
    [ -n "$c" ] && ! is_whitelisted "$c" && echo "$c"
  done
}

do_pause() {
  : > "$STATE_FILE.tmp"
  local c
  while read -r c; do
    if [ "$DRY_RUN" = "1" ]; then log "[dry-run] would pause container: $c"
    elif "$DOCKER" pause "$c" >/dev/null 2>&1; then log "paused container: $c"
    else log "WARN failed to pause: $c"; continue; fi
    echo "$c" >> "$STATE_FILE.tmp"
  done < <(pause_targets)
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  local s
  IFS=',' read -ra svcs <<< "$USER_SERVICES"
  for s in "${svcs[@]:-}"; do
    [ -n "$s" ] || continue
    if [ "$DRY_RUN" = "1" ]; then log "[dry-run] would stop user service: $s"
    else
      su - "$SVC_USER" -c "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user stop $s" \
        && log "stopped user service: $s" || log "WARN failed to stop service: $s"
    fi
  done
}

do_resume() {
  local c
  if [ -f "$STATE_FILE" ]; then
    while read -r c; do
      [ -n "$c" ] || continue
      if [ "$DRY_RUN" = "1" ]; then log "[dry-run] would unpause container: $c"
      elif "$DOCKER" unpause "$c" >/dev/null 2>&1; then log "unpaused container: $c"
      else log "WARN failed to unpause (maybe restarted already): $c"; fi
    done < "$STATE_FILE"
    rm -f "$STATE_FILE"
  fi
  local s
  IFS=',' read -ra svcs <<< "$USER_SERVICES"
  for s in "${svcs[@]:-}"; do
    [ -n "$s" ] || continue
    if [ "$DRY_RUN" = "1" ]; then log "[dry-run] would start user service: $s"
    else
      su - "$SVC_USER" -c "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user start $s" \
        && log "started user service: $s" || log "WARN failed to start service: $s"
    fi
  done
}

log "starting. hold=${HOLD_TEMP}C resume=${RESUME_TEMP}C poll=${POLL}s min_hold=${MIN_HOLD}s resume_stable=${RESUME_STABLE}s dry_run=${DRY_RUN}"

state=cool
held_since=0
below_since=0
while true; do
  read -r temp power <<< "$(read_gpu)"
  if [ -z "${temp:-}" ]; then
    log "WARN could not read GPU temp (fails open, no action)"
    sleep "$POLL"; continue
  fi
  if [ "$state" = cool ]; then
    if [ "$temp" -ge "$HOLD_TEMP" ]; then
      state=held; held_since=$(date +%s); below_since=0
      log "HOLD at ${temp}C (limit ${HOLD_TEMP}C, power ${power}W) - pausing GPU workloads"
      alert "HOLD ${temp}C - pausing GPU workloads"
      do_pause
    fi
  else
    now=$(date +%s)
    if [ "$temp" -le "$RESUME_TEMP" ]; then
      [ "$below_since" = 0 ] && below_since=$now
    else
      below_since=0
    fi
    if [ "$below_since" != 0 ] \
       && [ $((now - below_since)) -ge "$RESUME_STABLE" ] \
       && [ $((now - held_since)) -ge "$MIN_HOLD" ]; then
      state=cool
      log "RESUME at ${temp}C (target ${RESUME_TEMP}C, held $((now - held_since))s) - resuming workloads"
      alert "RESUME ${temp}C - workloads resumed"
      do_resume
    fi
  fi
  sleep "$POLL"
done
