#!/bin/bash

AutoSu()
{
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "Lance ce script en root (sudo n'est pas installé)."
  local self
  self="$(realpath "${BASH_SOURCE[0]}")"
  exec sudo -p "$(basename "$0") doit être lancé en root. Mot de passe de %u : " \
    -- bash "$self" "$@"
}

InstallMariaDBModule()
{
    apt-get install -y php-mysql
}

InstallPhp()
{
    apt-get install -y php
}

InstallSuryKey()
{
    apt-get -y install lsb-release ca-certificates curl
    curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
    apt-get update
}

## Script starts here ##
AutoSu

apt-get update

if [ ! -f "/etc/apt/sources.list.d/php.list" ]; then
    InstallSuryKey
fi

InstallPhp

if dpkg -s mariadb-server; then
    InstallMariaDBModule
fi

