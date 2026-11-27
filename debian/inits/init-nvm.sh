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

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.4/install.sh | bash
source ~/.bashrc

nvm i --lts
nvm i node

nvm use node
