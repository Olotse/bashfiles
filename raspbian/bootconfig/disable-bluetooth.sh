#!/bin/sh

if [ "$(whoami)" != "root" ]; then
    SUDO=sudo
fi

if [ -d "/boot/firmware" ]; then
    CONFIG_PATH=/boot/firmware/config.txt
else
    CONFIG_PATH=/boot/config.txt
fi

${SUDO} echo "\n# Disable Bluetooth\ndtoverlay=disable-bt" >> ${CONFIG_PATH}

${SUDO} systemctl disable hciuart.service
${SUDO} systemctl disable bluetooth.service

scriptname=`basename ${0}`
scriptpath=$(dirname $(readlink -f ${0}))

scriptrealpath=${scriptpath}/${scriptname}
${SUDO} chmod u-x ${scriptrealpath}
