#!/usr/bin/env bash

export TZ="Asia/Singapore"

LOG_DIR="/home/benjamin/backups/logs/cpustats"

CPU_LIMIT=85
GPU_LIMIT=82
INTERVAL=10

mkdir -p "$LOG_DIR"

while true; do

    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    DATE_SUFFIX=$(date "+%Y-%m-%d")

    LOG_FILE="$LOG_DIR/cpu_stats_${DATE_SUFFIX}.csv"

    # create CSV header once
    if [ ! -f "$LOG_FILE" ]; then
        echo "Timestamp,CPU_Temp,GPU_Temp,RAM_Used,RAM_Available,Status" > "$LOG_FILE"
    fi

    # CPU TEMP
    CPU_TEMP=0

    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        RAW_CPU=$(cat /sys/class/thermal/thermal_zone0/temp)
        CPU_TEMP=$((RAW_CPU / 1000))
    fi

    # GPU TEMP
    GPU_TEMP=0

    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_TEMP=$(nvidia-smi \
            --query-gpu=temperature.gpu \
            --format=csv,noheader,nounits \
            2>/dev/null | head -n1)

        [ -z "$GPU_TEMP" ] && GPU_TEMP=0
    fi

    # RAM
    RAM_USED=$(free -h | awk '/Mem:/ {print $3}')
    RAM_AVAILABLE=$(free -h | awk '/Mem:/ {print $7}')

    # STATUS
    STATUS="OK"

    if [ "$CPU_TEMP" -ge "$CPU_LIMIT" ] || [ "$GPU_TEMP" -ge "$GPU_LIMIT" ]; then
        STATUS="HOT"
    fi

    # SAVE TO LOG
    echo "$TIMESTAMP,$CPU_TEMP,$GPU_TEMP,$RAM_USED,$RAM_AVAILABLE,$STATUS" >> "$LOG_FILE"

    # Keep journald event-focused; the CSV remains the complete time series.
    if [ "$STATUS" = "HOT" ]; then
        echo "HOT: timestamp=$TIMESTAMP cpu=${CPU_TEMP}C gpu=${GPU_TEMP}C log=$LOG_FILE"
    fi

    sleep "$INTERVAL"

done
