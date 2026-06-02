#!/bin/bash
SMS_USER="{{USER}}"
SMS_PASS="{{PASS}}"
STATE_FILE="/var/lib/smsnotify/smsnotify.state"
NET_STATE_FILE="/var/lib/smsnotify/network.state"
CHECK_HOST="152.228.163.1"
CHECK_INTERVAL=60

send_sms() {
  curl -G "https://smsapi.free-mobile.fr/sendmsg" \
    --data-urlencode "user=$SMS_USER" \
    --data-urlencode "pass=$SMS_PASS" \
    --data-urlencode "msg=$1"
}
