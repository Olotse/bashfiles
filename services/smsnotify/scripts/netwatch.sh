#!/bin/bash
source "$(dirname "$0")/config.sh"
mkdir -p "$(dirname "$NET_STATE_FILE")"
echo "up" > "$NET_STATE_FILE"

while true; do
  current_state=$(cat "$NET_STATE_FILE")

  if ping -c 1 -W 5 "$CHECK_HOST" > /dev/null 2>&1; then
    if [ "$current_state" = "down" ]; then
      send_sms "$(hostname) network is back UP"
      echo "up" > "$NET_STATE_FILE"
    fi
  else
    if [ "$current_state" = "up" ]; then
      send_sms "$(hostname) network is DOWN"
      echo "down" > "$NET_STATE_FILE"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
