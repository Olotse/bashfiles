#!/bin/bash
source "$(dirname "$0")/config.sh"
mkdir -p "$(dirname "$NET_STATE_FILE")"
echo "up" > "$NET_STATE_FILE"

while true; do
  current_state=$(cat "$NET_STATE_FILE")

  if ping -c 1 -W 5 "$CHECK_HOST" > /dev/null 2>&1; then
    if [ "$current_state" = "down" ]; then
      now=$(date '+%Y-%m-%d %H:%M:%S')
      down_time=$(cat "$NET_STATE_FILE.downtime" 2>/dev/null)
      send_sms "$(hostname) network is back UP at $now (was DOWN since $down_time)"
      echo "up" > "$NET_STATE_FILE"
    fi
  else
    if [ "$current_state" = "up" ]; then
      now=$(date '+%Y-%m-%d %H:%M:%S')
      echo "$now" > "$NET_STATE_FILE.downtime"
      send_sms "$(hostname) network is DOWN since $now"
      echo "down" > "$NET_STATE_FILE"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
