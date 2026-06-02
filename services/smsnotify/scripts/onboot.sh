#!/bin/bash
source "$(dirname "$0")/config.sh"
mkdir -p "$(dirname "$STATE_FILE")"

if [ -f "$STATE_FILE" ]; then
  last_seen=$(journalctl -b -1 --output=short --no-pager 2>/dev/null | tail -1 | awk '{print $1, $2, $3}')
  if [ -n "$last_seen" ]; then
    msg="$(hostname) started after POWER OUTAGE (last log: $last_seen)"
  else
    msg="$(hostname) started after POWER OUTAGE (last log unavailable)"
  fi
else
  msg="$(hostname) started normally"
fi

echo "pid=$$" > "$STATE_FILE"
echo "date=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"

send_sms "$msg"
