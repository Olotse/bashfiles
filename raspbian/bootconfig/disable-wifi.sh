#!/bin/sh

if [ "$(whoami)" != "root" ]; then
    SUDO=sudo
fi

if [ -d "/boot/firmware" ]; then
    CONFIG_PATH=/boot/firmware/config.txt
else
    CONFIG_PATH=/boot/config.txt
fi

${SUDO} echo "\n# Disable Wi-Fi\ndtoverlay=disable-wifi" >> ${CONFIG_PATH}

scriptname=`basename ${0}`
scriptpath=$(dirname $(readlink -f ${0}))

scriptrealpath=${scriptpath}/${scriptname}
chmod u-x ${scriptrealpath}
