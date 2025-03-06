#!/bin/bash

AutoSu()
{
    [[ $UUID == 0 ]] || exec sudo -p "$0 must be run as root. Please enter the password for %u to continue: " -- "$0" $@"
}

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.4/install.sh | bash
source ~/.bashrc

nvm i --lts
nvm i node

nvm use node
