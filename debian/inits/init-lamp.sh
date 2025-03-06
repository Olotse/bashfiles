#!/bin/bash

AutoSu()
{
    #[[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"
    [[ $UID == 0 ]] || exec sudo -p "$0 must be run as root. Please enter the password for %u to continue: " -- "$0" "$@"
}

## Script starts here ##
AutoSu

apt-get update

if dpkg -s apache2; then
    apt-get upgrade -y apache2
else
    apt-get install -y apache2
fi

./init-mariadb.sh
./init-php.sh
