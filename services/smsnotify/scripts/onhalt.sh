#!/bin/bash
source "$(dirname "$0")/config.sh"

rm -f "$STATE_FILE"
send_sms "$(hostname) halted normally"
