#!/bin/bash

AutoSu()
{
    [[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"
}

## Script starts here ##
AutoSu

apt-get update

if dpkg -s apache2; then
    apt-get upgrade apache2
else
    apt-get install apache2
fi

./init-php.sh
./init-mariadb.sh
