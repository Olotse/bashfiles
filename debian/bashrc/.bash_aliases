#!/bin/bash

type node > /dev/null 2>&1 \
    && alias ngstart='npm start' \
    && alias vuestart='npm run serve' \
    && alias vuebuild='npm run build'

type apache2 > /dev/null 2>&1 \
    && alias a2access='sudo tail -f /var/log/apache2/access.log' \
    && alias a2error='sudo tail -f /var/log/apache2/error.log'

alias pkgupdate='sudo apt-get update && sudo apt-get upgrade'
alias sysupdate='sudo apt-get update && sudo apt-get dist-upgrade'
