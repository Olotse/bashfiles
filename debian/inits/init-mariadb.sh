#!/bin/bash

AutoSu()
{
	[[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"
}

## Script starts here ##
AutoSu

apt-get update

if dpkg -s mariadb-server
    then apt-get upgrade mariadb-server
    else apt-get install mariadb-server
fi
