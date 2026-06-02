#!/bin/bash

SELF="$(realpath "$0")"
ARGS=("$@")
PROGRAM="$(basename "$0")"

[[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"

SCRIPT_DIR="$(dirname "$SELF")"
SERVICES_DIR="$SCRIPT_DIR/services"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
INSTALL_SCRIPTS_DIR="/cconf/scripts/smsnotify"
CONFIG_FILE="$INSTALL_SCRIPTS_DIR/config.sh"

echo "=== Installation de smsnotify ==="

# Copie des scripts
echo "Copie des scripts vers $INSTALL_SCRIPTS_DIR..."
mkdir -p "$INSTALL_SCRIPTS_DIR"
cp "$SCRIPTS_DIR/"*.sh "$INSTALL_SCRIPTS_DIR/"
chmod +x "$INSTALL_SCRIPTS_DIR/"*.sh

# Copie des services
echo "Copie des services vers /etc/systemd/system/..."
cp "$SERVICES_DIR/"*.service /etc/systemd/system/

# Demande des credentials
echo ""
read -p "Free Mobile user : " SMS_USER
read -s -p "Free Mobile pass : " SMS_PASS
echo ""

# Remplacement dans config.sh
echo "Configuration de config.sh..."
sed -i "s/{{USER}}/$SMS_USER/g" "$CONFIG_FILE"
sed -i "s/{{PASS}}/$SMS_PASS/g" "$CONFIG_FILE"

# Protection de config.sh
echo "Protection de config.sh..."
chmod 600 "$CONFIG_FILE"

# Activation des services
echo "Activation des services..."
systemctl daemon-reload
systemctl enable smsstatenotify smsnetnotify
systemctl start smsstatenotify smsnetnotify

echo ""
echo "=== Installation terminée ! ==="
echo "Status des services :"
systemctl status smsstatenotify smsnetnotify --no-pager
