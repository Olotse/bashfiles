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
