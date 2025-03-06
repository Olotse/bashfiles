#!/bin/bash

AutoSu()
{
	[[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"
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

