#!/usr/bin/env bash
# =============================================================================
#  vaultwarden-apache.sh : installation et mise à jour de Vaultwarden
#  derrière Apache sur Debian 12 / 13
#
#  Commandes :
#    install   Installe Docker, Vaultwarden, les vhosts Apache, le certificat
#              Let's Encrypt et les sauvegardes quotidiennes.
#    update    Sauvegarde, télécharge la dernière image, redémarre et vérifie
#              que Vaultwarden répond. En cas d'échec, retour arrière auto.
#    rollback  Revient à l'image précédente et restaure la sauvegarde faite
#              juste avant la dernière mise à jour.
#    status    Vérifie toute la chaîne : Docker, conteneur, accès local,
#              pare-feu, ordre de démarrage, Apache, HTTPS, certificat,
#              sauvegardes. Code de sortie 1 en cas d'erreur (utilisable
#              en supervision).
#    signups [on|off]
#              Affiche, ouvre ou ferme les inscriptions (met aussi à jour
#              le réglage fait depuis /admin, qui sinon l'emporterait).
#
#  Après l'installation, le script est copié dans /usr/local/bin :
#    vaultwarden-apache update      (sudo est ajouté automatiquement)
#
#  Pour une installation non interactive, place les variables APRÈS sudo
#  (sudo ne transmet pas l'environnement), comme dans l'exemple ci-dessous.
#
#  Installation non interactive possible :
#    sudo DOMAIN=vault.exemple.fr ACME_EMAIL=moi@exemple.fr SIGNUPS=true \
#         VW_PORT=8222 bash vaultwarden-apache.sh install
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/vaultwarden"
BACKUP_DIR="/var/backups/vaultwarden"
ACME_ROOT="/var/www/letsencrypt"
BACKUP_BIN="/usr/local/bin/vaultwarden-backup"
SELF_BIN="/usr/local/bin/vaultwarden-apache"
ROLLBACK_FILE="$INSTALL_DIR/.rollback"
PREVIOUS_TAG="vaultwarden/server:previous"
KEEP_DAYS=30

msg()  { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage : sudo $(basename "$0") <commande>

  install    Installer Vaultwarden derrière Apache
  update     Mettre à jour Vaultwarden (sauvegarde + retour arrière auto)
  rollback   Annuler la dernière mise à jour
  status     Vérifier que tout fonctionne (alias : check)
  signups    Afficher l'état des inscriptions
  signups on|off   Ouvrir ou fermer les inscriptions
EOF
  exit 1
}

# Affichage des vérifications
FAILS=0
WARNS=0
ok()   { printf '  \e[1;32m[OK]\e[0m %s\n' "$*"; }
note() { printf '  \e[1;33m[!!]\e[0m %s\n' "$*"; WARNS=$((WARNS + 1)); }
bad()  { printf '  \e[1;31m[KO]\e[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
hint() { printf '       \e[2m-> %s\e[0m\n' "$*"; }
section() { printf '\n\e[1m%s\e[0m\n' "$*"; }

# rc.local recharge-t-il le pare-feu (iptables-restore) ?
rclocal_loads_firewall() {
  [[ -f /etc/rc.local ]] && grep -Eq '^[^#]*iptables-restore' /etc/rc.local
}

DOCKER_DROPIN="/etc/systemd/system/docker.service.d/after-firewall.conf"

# --- Fonctions utilitaires ---------------------------------------------------
# Relance automatiquement le script avec sudo s'il n'est pas lancé en root
require_root() {
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "Lance ce script en root (sudo n'est pas installé)."
  local self
  self="$(realpath "${BASH_SOURCE[0]}")"
  exec sudo -p "$(basename "$0") doit être lancé en root. Mot de passe de %u : " \
    -- bash "$self" "$@"
}

require_installed() {
  [[ -f "$INSTALL_DIR/docker-compose.yml" ]] \
    || die "Aucune installation trouvée dans $INSTALL_DIR."
}

# Port local de Vaultwarden, lu dans docker-compose.yml
vw_port() {
  local port
  port="$(grep -oP '127\.0\.0\.1:\K[0-9]+(?=:80)' "$INSTALL_DIR/docker-compose.yml" | head -n1 || true)"
  [[ -n "$port" ]] || die "Port de Vaultwarden introuvable dans docker-compose.yml."
  echo "$port"
}

# Image utilisée par le service vaultwarden (ex. vaultwarden/server:latest)
vw_image() {
  (cd "$INSTALL_DIR" && docker compose config --images) | grep -m1 vaultwarden \
    || die "Image Vaultwarden introuvable dans docker-compose.yml."
}

vw_version() {
  timeout 10 docker exec vaultwarden /vaultwarden --version 2>/dev/null </dev/null \
    || echo "version inconnue"
}

# Attend que Vaultwarden réponde sur /alive (2 s entre chaque essai)
wait_alive() {
  local port=$1 tries=${2:-45} i
  for ((i = 0; i < tries; i++)); do
    if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
         "http://127.0.0.1:${port}/alive" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# =============================================================================
#  INSTALL
# =============================================================================
do_install() {
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" != "debian" || ! "${VERSION_ID:-}" =~ ^(12|13)$ ]]; then
    die "Debian 12 ou 13 requis (détecté : ${PRETTY_NAME:-inconnu})."
  fi

  if [[ -e "$INSTALL_DIR/docker-compose.yml" ]]; then
    die "Une installation existe déjà dans $INSTALL_DIR. Pour mettre à jour : $0 update"
  fi

  # --- Questions -------------------------------------------------------------
  local DOMAIN="${DOMAIN:-}" ACME_EMAIL="${ACME_EMAIL:-}" SIGNUPS="${SIGNUPS:-}"
  local VW_PORT="${VW_PORT:-8222}" ans

  if [[ -z "$DOMAIN" ]]; then
    read -rp "Nom de domaine pour Vaultwarden (ex. vault.exemple.fr) : " DOMAIN
  fi
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "Nom de domaine invalide : $DOMAIN"

  if [[ -z "$ACME_EMAIL" ]]; then
    read -rp "Adresse e-mail pour Let's Encrypt (alertes de certificat) : " ACME_EMAIL
  fi
  [[ "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "Adresse e-mail invalide : $ACME_EMAIL"

  if [[ -z "$SIGNUPS" ]]; then
    read -rp "Autoriser les inscriptions le temps de créer ton compte ? [O/n] " ans
    if [[ "${ans,,}" == n* ]]; then SIGNUPS=false; else SIGNUPS=true; fi
  fi
  [[ "$SIGNUPS" =~ ^(true|false)$ ]] || die "SIGNUPS doit valoir true ou false."

  if ! [[ "$VW_PORT" =~ ^[0-9]+$ ]] || (( VW_PORT <= 1024 || VW_PORT >= 65536 )); then
    die "VW_PORT invalide : $VW_PORT"
  fi
  if ss -ltnH "sport = :$VW_PORT" | grep -q .; then
    die "Le port local $VW_PORT est déjà utilisé. Relance avec VW_PORT=un_autre_port."
  fi

  if command -v apache2ctl >/dev/null 2>&1 \
     && apache2ctl -S 2>/dev/null | grep -Eqi "(namevhost|alias) ${DOMAIN//./\\.}( |$)"; then
    die "Apache a déjà un VirtualHost pour $DOMAIN. Retire-le ou choisis un autre domaine."
  fi

  warn "Le domaine $DOMAIN doit pointer (enregistrement DNS A/AAAA) vers ce serveur,"
  warn "et les ports 80 et 443 doivent être joignables depuis Internet."
  read -rp "Continuer ? [O/n] " ans
  [[ "${ans,,}" == n* ]] && die "Annulé."

  # --- Paquets de base -------------------------------------------------------
  msg "Installation des paquets (Apache, Certbot, outils)…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg openssl argon2 sqlite3 \
    apache2 certbot

  # --- Docker ----------------------------------------------------------------
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg "Docker et Compose déjà présents, on garde l'existant."
  else
    msg "Installation de Docker depuis le dépôt officiel…"
    local pkg
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
      apt-get remove -y -q "$pkg" >/dev/null 2>&1 || true
    done
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi
  # Toujours activer Docker au boot, même s'il était déjà installé
  systemctl enable --now docker

  # --- Apache : modules et vhost HTTP ----------------------------------------
  msg "Activation des modules Apache nécessaires…"
  a2enmod -q proxy proxy_http proxy_wstunnel headers rewrite ssl http2 >/dev/null

  install -d -m 0755 "$ACME_ROOT/.well-known/acme-challenge"

  msg "Création du VirtualHost HTTP (validation Let's Encrypt + redirection HTTPS)…"
  cat > /etc/apache2/sites-available/vaultwarden.conf <<EOF
# Vaultwarden - HTTP : sert uniquement les défis Let's Encrypt, redirige le reste
<VirtualHost *:80>
    ServerName ${DOMAIN}

    Alias /.well-known/acme-challenge/ ${ACME_ROOT}/.well-known/acme-challenge/
    <Directory ${ACME_ROOT}>
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://${DOMAIN}%{REQUEST_URI} [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/vaultwarden-error.log
    CustomLog \${APACHE_LOG_DIR}/vaultwarden-access.log combined
</VirtualHost>
EOF
  a2ensite -q vaultwarden >/dev/null
  apache2ctl configtest
  systemctl reload apache2

  # --- Certificat Let's Encrypt ----------------------------------------------
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    msg "Un certificat existe déjà pour ${DOMAIN}, on le réutilise."
  else
    msg "Obtention du certificat Let's Encrypt…"
    certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
      -m "$ACME_EMAIL" --agree-tos -n \
      --deploy-hook "systemctl reload apache2" \
      || die "Échec de Certbot. Vérifie le DNS de ${DOMAIN} et l'ouverture du port 80."
  fi

  # --- Apache : vhost HTTPS --------------------------------------------------
  msg "Création du VirtualHost HTTPS (reverse proxy vers Vaultwarden)…"
  cat > /etc/apache2/sites-available/vaultwarden-ssl.conf <<EOF
# Vaultwarden - HTTPS : reverse proxy vers le conteneur (127.0.0.1:${VW_PORT})
<VirtualHost *:443>
    ServerName ${DOMAIN}
    Protocols h2 http/1.1

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem

    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "same-origin"

    ProxyRequests Off
    ProxyPreserveHost On
    RequestHeader set X-Real-IP "%{REMOTE_ADDR}s"
    RequestHeader set X-Forwarded-Proto "https"

    # upgrade=websocket : notifications temps réel (synchro instantanée des clients)
    ProxyPass        / http://127.0.0.1:${VW_PORT}/ upgrade=websocket
    ProxyPassReverse / http://127.0.0.1:${VW_PORT}/

    ErrorLog \${APACHE_LOG_DIR}/vaultwarden-error.log
    CustomLog \${APACHE_LOG_DIR}/vaultwarden-access.log combined
</VirtualHost>
EOF
  a2ensite -q vaultwarden-ssl >/dev/null
  apache2ctl configtest
  systemctl reload apache2

  # --- Jeton d'administration ------------------------------------------------
  msg "Génération du mot de passe de la page /admin…"
  local ADMIN_PASS ADMIN_HASH ADMIN_HASH_ESC
  ADMIN_PASS="$(openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-32)"
  ADMIN_HASH="$(printf '%s' "$ADMIN_PASS" \
    | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4)"
  # Dans docker-compose.yml, chaque "$" doit être doublé
  ADMIN_HASH_ESC="${ADMIN_HASH//\$/\$\$}"

  # --- Docker Compose --------------------------------------------------------
  msg "Création de $INSTALL_DIR…"
  install -d -m 0700 "$INSTALL_DIR" "$INSTALL_DIR/vw-data"

  cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "https://${DOMAIN}"
      SIGNUPS_ALLOWED: "${SIGNUPS}"
      ADMIN_TOKEN: '${ADMIN_HASH_ESC}'
      IP_HEADER: "X-Real-IP"
    ports:
      # Uniquement en local : seul Apache y accède
      - "127.0.0.1:${VW_PORT}:80"
    volumes:
      - ./vw-data:/data
EOF
  chmod 600 "$INSTALL_DIR/docker-compose.yml"

  # --- Sauvegardes -----------------------------------------------------------
  msg "Mise en place des sauvegardes quotidiennes…"
  cat > "$BACKUP_BIN" <<EOF
#!/usr/bin/env bash
# Sauvegarde à chaud de Vaultwarden (base SQLite + pièces jointes + clés)
set -euo pipefail
SRC="${INSTALL_DIR}/vw-data"
DEST="${BACKUP_DIR}"
KEEP_DAYS=${KEEP_DAYS}
EOF
  cat >> "$BACKUP_BIN" <<'EOF'
TS="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077
mkdir -p "$DEST"

if [[ -f "$SRC/db.sqlite3" ]]; then
  sqlite3 "$SRC/db.sqlite3" ".backup '$TMP/db.sqlite3'"
fi
for item in attachments sends config.json rsa_key.pem rsa_key.pub.pem; do
  if [[ -e "$SRC/$item" ]]; then
    cp -a "$SRC/$item" "$TMP/"
  fi
done

tar -czf "$DEST/vaultwarden-$TS.tar.gz" -C "$TMP" .
find "$DEST" -name 'vaultwarden-*.tar.gz' -mtime +"$KEEP_DAYS" -delete
echo "$DEST/vaultwarden-$TS.tar.gz"
EOF
  chmod 700 "$BACKUP_BIN"

  cat > /etc/systemd/system/vaultwarden-backup.service <<EOF
[Unit]
Description=Sauvegarde de Vaultwarden

[Service]
Type=oneshot
ExecStart=${BACKUP_BIN}
EOF

  cat > /etc/systemd/system/vaultwarden-backup.timer <<'EOF'
[Unit]
Description=Sauvegarde quotidienne de Vaultwarden

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vaultwarden-backup.timer

  # --- Ordre de démarrage Docker / pare-feu ----------------------------------
  # Si rc.local recharge la table filter, il doit passer AVANT Docker,
  # sinon il efface les chaînes réseau créées par Docker.
  if rclocal_loads_firewall && [[ ! -f "$DOCKER_DROPIN" ]]; then
    msg "Pare-feu chargé par rc.local : Docker démarrera après lui."
    install -d -m 0755 "$(dirname "$DOCKER_DROPIN")"
    printf '[Unit]\nAfter=rc-local.service\n' > "$DOCKER_DROPIN"
    systemctl daemon-reload
  fi

  # --- Copie du script pour les mises à jour ---------------------------------
  # Lisible par tous (il ne contient aucun secret) pour que la relance
  # automatique via sudo fonctionne depuis un compte utilisateur
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" "$SELF_BIN"
  fi
  # Ancien emplacement : il passerait avant /usr/local/bin dans le PATH de root
  rm -f /usr/local/sbin/vaultwarden-apache

  # --- Démarrage -------------------------------------------------------------
  msg "Téléchargement de l'image et démarrage de Vaultwarden…"
  cd "$INSTALL_DIR"
  docker compose pull -q
  docker compose up -d

  msg "Attente du démarrage…"
  if wait_alive "$VW_PORT"; then
    msg "Vaultwarden répond ($(vw_version))."
  else
    warn "Vaultwarden ne répond pas encore. Diagnostic : sudo vaultwarden-apache status"
  fi

  # --- Récapitulatif ---------------------------------------------------------
  cat <<EOF

$(printf '\e[1;32m')Vaultwarden est installé derrière Apache !$(printf '\e[0m')

  Coffre       : https://${DOMAIN}
  Page admin   : https://${DOMAIN}/admin
  Mot de passe admin (affiché UNE seule fois, note-le) :

      ${ADMIN_PASS}

  Dossier      : ${INSTALL_DIR}
  Vhosts       : /etc/apache2/sites-available/vaultwarden{,-ssl}.conf
  Logs Apache  : /var/log/apache2/vaultwarden-*.log
  Sauvegardes  : ${BACKUP_DIR} (tous les jours vers 3 h 30, ${KEEP_DAYS} jours gardés)
  Certificat   : renouvelé automatiquement par Certbot (timer systemd)

  Mise à jour  : sudo vaultwarden-apache update
  Annulation   : sudo vaultwarden-apache rollback
  Vérification : sudo vaultwarden-apache status
EOF

  if [[ "$SIGNUPS" == "true" ]]; then
    cat <<EOF

$(printf '\e[1;33m')IMPORTANT :$(printf '\e[0m') les inscriptions sont ouvertes. Une fois ton compte créé, ferme-les :

  sudo vaultwarden-apache signups off
EOF
  fi
}

# =============================================================================
#  UPDATE
# =============================================================================
do_update() {
  require_installed
  [[ -x "$BACKUP_BIN" ]] || die "Script de sauvegarde introuvable : $BACKUP_BIN"
  cd "$INSTALL_DIR"

  local port img old_id new_id old_ver backup_file
  port="$(vw_port)"
  img="$(vw_image)"
  old_ver="$(vw_version)"

  # Image réellement utilisée par le conteneur (sinon celle présente en local)
  old_id="$(docker inspect --format '{{.Image}}' vaultwarden 2>/dev/null \
    || docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)"

  msg "Version actuelle : $old_ver"
  msg "Recherche d'une nouvelle image ($img)…"
  docker compose pull -q vaultwarden
  new_id="$(docker image inspect --format '{{.Id}}' "$img")"

  if [[ -n "$old_id" && "$old_id" == "$new_id" ]]; then
    msg "Vaultwarden est déjà à jour, rien à faire."
    return 0
  fi

  msg "Nouvelle image disponible. Sauvegarde avant mise à jour…"
  backup_file="$("$BACKUP_BIN" | tail -n1)"
  # Compatible avec l'ancien script de sauvegarde ("Sauvegarde créée : <chemin>")
  backup_file="${backup_file##*: }"
  [[ -f "$backup_file" ]] || die "La sauvegarde a échoué, mise à jour annulée."
  msg "Sauvegarde : $backup_file"

  # On garde l'ancienne image sous un tag dédié pour pouvoir y revenir
  if [[ -n "$old_id" ]]; then
    docker tag "$old_id" "$PREVIOUS_TAG"
    printf '%s\n%s\n' "$backup_file" "$img" > "$ROLLBACK_FILE"
    chmod 600 "$ROLLBACK_FILE"
  fi

  msg "Redémarrage de Vaultwarden sur la nouvelle image…"
  docker compose up -d vaultwarden

  msg "Vérification du démarrage…"
  if wait_alive "$port"; then
    msg "Mise à jour réussie : $old_ver -> $(vw_version)"
    docker image prune -f >/dev/null
    msg "En cas de souci plus tard : sudo vaultwarden-apache rollback"
  else
    warn "Vaultwarden ne répond pas après la mise à jour."
    docker compose logs --tail 30 vaultwarden || true
    if [[ -f "$ROLLBACK_FILE" ]]; then
      warn "Retour automatique à la version précédente…"
      do_rollback
    fi
    die "Mise à jour échouée."
  fi
}

# =============================================================================
#  ROLLBACK
# =============================================================================
do_rollback() {
  require_installed
  [[ -f "$ROLLBACK_FILE" ]] || die "Aucune mise à jour à annuler."
  docker image inspect "$PREVIOUS_TAG" >/dev/null 2>&1 \
    || die "Image précédente ($PREVIOUS_TAG) introuvable."

  local backup_file img port tmp
  { read -r backup_file; read -r img; } < "$ROLLBACK_FILE"
  [[ -f "$backup_file" ]] || die "Sauvegarde introuvable : $backup_file"
  port="$(vw_port)"
  cd "$INSTALL_DIR"

  msg "Arrêt de Vaultwarden…"
  docker compose stop vaultwarden

  msg "Restauration des données depuis $backup_file…"
  tmp="$(mktemp -d)"
  tar -xzf "$backup_file" -C "$tmp"
  rm -f vw-data/db.sqlite3-wal vw-data/db.sqlite3-shm
  cp -a "$tmp"/. vw-data/
  rm -rf "$tmp"

  msg "Retour à l'image précédente…"
  docker tag "$PREVIOUS_TAG" "$img"
  docker compose up -d vaultwarden

  if wait_alive "$port"; then
    rm -f "$ROLLBACK_FILE"
    msg "Retour arrière réussi ($(vw_version))."
    warn "Le prochain « update » retentera la nouvelle version : attends un correctif si besoin."
  else
    die "Vaultwarden ne répond toujours pas : cd $INSTALL_DIR && docker compose logs -f"
  fi
}

# =============================================================================
#  STATUS
# =============================================================================
do_status() {
  require_installed
  local compose="$INSTALL_DIR/docker-compose.yml"
  local port domain state health policy cip policy_in last age_days

  port="$(vw_port)"
  domain="$(grep -oP 'DOMAIN: "https://\K[^"/]+' "$compose" | head -n1 || true)"

  printf '\e[1mVérification de Vaultwarden%s\e[0m\n' "${domain:+ ($domain)}"

  # --- Docker ----------------------------------------------------------------
  section "Docker"
  if systemctl is-active -q docker; then ok "Service Docker actif"
  else bad "Service Docker arrêté"; hint "sudo systemctl start docker"; fi
  if systemctl is-enabled -q docker 2>/dev/null; then ok "Docker démarre automatiquement au boot"
  else bad "Docker ne démarre pas au boot"; hint "sudo systemctl enable docker"; fi

  # --- Conteneur -------------------------------------------------------------
  section "Conteneur"
  state="$(docker inspect -f '{{.State.Status}}' vaultwarden 2>/dev/null || echo absent)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}inconnu{{end}}' \
    vaultwarden 2>/dev/null || echo inconnu)"
  policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' vaultwarden 2>/dev/null || echo aucune)"

  if [[ "$state" == "running" ]]; then
    ok "Conteneur en marche ($(vw_version))"
  else
    bad "Conteneur dans l'état : $state"
    hint "cd $INSTALL_DIR && sudo docker compose up -d && sudo docker compose logs --tail 30"
  fi
  case "$health" in
    healthy)   ok "Vérification de santé interne : OK" ;;
    starting)  note "Conteneur en cours de démarrage, relance le test dans 30 s" ;;
    unhealthy) bad "Conteneur « unhealthy »"; hint "sudo docker logs --tail 50 vaultwarden" ;;
    *)         note "État de santé inconnu" ;;
  esac
  if [[ "$policy" =~ ^(unless-stopped|always)$ ]]; then
    ok "Redémarrage automatique : $policy"
  else
    bad "Pas de redémarrage automatique (politique : $policy)"
    hint "Ajoute « restart: unless-stopped » dans $compose"
  fi

  # --- Accès local -----------------------------------------------------------
  section "Accès local (Apache -> Vaultwarden)"
  if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 5 \
       "http://127.0.0.1:${port}/alive" >/dev/null 2>&1; then
    ok "Vaultwarden répond sur 127.0.0.1:${port}"
  else
    bad "Pas de réponse sur 127.0.0.1:${port}"
    cip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      vaultwarden 2>/dev/null || true)"
    if [[ "$state" == "running" && -n "$cip" ]]; then
      if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 5 \
           "http://${cip}:80/alive" >/dev/null 2>&1; then
        hint "Le conteneur répond en direct ($cip) : règles Docker manquantes."
        hint "sudo systemctl restart docker"
      else
        hint "Le conteneur ne répond pas non plus en direct ($cip) :"
        hint "le pare-feu bloque probablement les réponses du réseau Docker (voir ci-dessous)."
      fi
    fi
  fi

  # --- Pare-feu --------------------------------------------------------------
  section "Pare-feu"
  if command -v iptables >/dev/null 2>&1; then
    if iptables -n -L DOCKER >/dev/null 2>&1; then
      ok "Chaînes réseau de Docker présentes"
    else
      bad "Chaînes réseau de Docker absentes (pare-feu rechargé après Docker ?)"
      hint "sudo systemctl restart docker"
    fi

    local input_rules established
    input_rules="$(iptables -S INPUT 2>/dev/null || true)"
    policy_in="$(awk '$1 == "-P" {print $3}' <<<"$input_rules")"
    # Règle ESTABLISHED sans restriction d'interface (-i)
    established="$(grep 'ESTABLISHED' <<<"$input_rules" | grep -v -- ' -i ' | grep -- '-j ACCEPT' || true)"
    if [[ "$policy_in" == "ACCEPT" ]]; then
      ok "Politique INPUT : ACCEPT (rien ne bloque les réponses)"
    elif [[ -n "$established" ]]; then
      ok "Connexions établies acceptées sur toutes les interfaces"
    else
      bad "Les réponses ne sont acceptées que sur certaines interfaces (Docker bloqué)"
      hint "Immédiat : sudo iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      hint "Permanent : ajoute cette règle dans ton fichier de règles iptables"
    fi
  else
    note "Commande iptables absente, vérification du pare-feu ignorée"
  fi

  # --- Ordre de démarrage ----------------------------------------------------
  section "Démarrage du serveur"
  if rclocal_loads_firewall; then
    if [[ "$(systemctl show docker -p After 2>/dev/null)" == *rc-local.service* ]]; then
      ok "Docker démarre après le pare-feu chargé par rc.local"
    else
      bad "Docker peut démarrer avant rc.local, qui effacerait alors ses règles"
      hint "sudo mkdir -p $(dirname "$DOCKER_DROPIN")"
      hint "printf '[Unit]\\nAfter=rc-local.service\\n' | sudo tee $DOCKER_DROPIN"
      hint "sudo systemctl daemon-reload"
    fi
  else
    ok "Pas de pare-feu chargé par rc.local, rien à ordonner"
  fi

  # --- Apache et HTTPS -------------------------------------------------------
  section "Apache et HTTPS"
  if systemctl is-active -q apache2; then ok "Apache actif"
  else bad "Apache arrêté"; hint "sudo systemctl start apache2"; fi

  if [[ -e /etc/apache2/sites-enabled/vaultwarden.conf && -e /etc/apache2/sites-enabled/vaultwarden-ssl.conf ]]; then
    ok "VirtualHosts Vaultwarden activés"
  else
    bad "VirtualHosts Vaultwarden non activés"
    hint "sudo a2ensite vaultwarden vaultwarden-ssl && sudo systemctl reload apache2"
  fi

  if [[ -n "$domain" ]]; then
    if curl -fsS --noproxy '*' --connect-timeout 5 --max-time 10 \
         "https://${domain}/alive" >/dev/null 2>&1; then
      ok "https://${domain} répond"
    else
      bad "https://${domain} ne répond pas"
      hint "sudo tail -n 20 /var/log/apache2/vaultwarden-error.log"
    fi

    local cert="/etc/letsencrypt/live/${domain}/fullchain.pem" end days
    if [[ -f "$cert" ]]; then
      end="$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if (( days < 0 )); then
        bad "Certificat expiré depuis $(( -days )) jour(s)"; hint "sudo certbot renew"
      elif (( days < 15 )); then
        note "Certificat expire dans $days jour(s) (le renouvellement aurait dû avoir lieu)"
        hint "sudo certbot renew --dry-run"
      else
        ok "Certificat valide encore $days jours"
      fi
    else
      bad "Certificat introuvable : $cert"
    fi
    if systemctl is-active -q certbot.timer; then ok "Renouvellement automatique du certificat actif"
    else note "Timer certbot inactif"; hint "sudo systemctl enable --now certbot.timer"; fi
  else
    note "Domaine introuvable dans $compose, tests HTTPS ignorés"
  fi

  # --- Sauvegardes -----------------------------------------------------------
  section "Sauvegardes"
  if systemctl is-active -q vaultwarden-backup.timer; then ok "Sauvegarde quotidienne programmée"
  else bad "Timer de sauvegarde inactif"; hint "sudo systemctl enable --now vaultwarden-backup.timer"; fi

  last="$(find "$BACKUP_DIR" -maxdepth 1 -name 'vaultwarden-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n1 || true)"
  if [[ -z "$last" ]]; then
    note "Aucune sauvegarde pour l'instant (la première a lieu vers 3 h 30)"
    hint "Pour en faire une maintenant : sudo $BACKUP_BIN"
  else
    age_days=$(( ( $(date +%s) - ${last%%.*} ) / 86400 ))
    if (( age_days > 2 )); then
      note "Dernière sauvegarde vieille de $age_days jours : ${last#* }"
      hint "sudo journalctl -u vaultwarden-backup --since -3d"
    else
      ok "Dernière sauvegarde : ${last#* }"
    fi
  fi

  # --- Sécurité --------------------------------------------------------------
  section "Sécurité"
  if [[ "$(signups_effective)" == "true" ]]; then
    note "Inscriptions ouvertes : n'importe qui peut créer un compte"
    hint "sudo vaultwarden-apache signups off"
  else
    ok "Inscriptions fermées"
  fi
  if [[ -n "$(signups_override)" ]]; then
    note "Le réglage des inscriptions est aussi défini dans /admin (config.json), qui prime sur docker-compose.yml"
    hint "La commande « signups on|off » met à jour les deux fichiers"
  fi

  # --- Bilan -----------------------------------------------------------------
  printf '\n'
  if (( FAILS > 0 )); then
    printf '\e[1;31m%d erreur(s)\e[0m, %d avertissement(s).\n' "$FAILS" "$WARNS"
    return 1
  elif (( WARNS > 0 )); then
    printf '\e[1;33mAucune erreur\e[0m, %d avertissement(s).\n' "$WARNS"
  else
    printf '\e[1;32mTout est en ordre.\e[0m\n'
  fi
}

# =============================================================================
#  SIGNUPS
# =============================================================================
# Valeur dans docker-compose.yml (vide si absente)
signups_compose() {
  grep -oP 'SIGNUPS_ALLOWED: "\K(true|false)' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null \
    | head -n1 || true
}

# Valeur enregistrée depuis /admin dans config.json (vide si absente)
signups_override() {
  local cfg="$INSTALL_DIR/vw-data/config.json"
  [[ -f "$cfg" ]] || return 0
  grep -oP '"signups_allowed"\s*:\s*\K(true|false)' "$cfg" | head -n1 || true
}

# Valeur réellement appliquée : config.json > docker-compose.yml > défaut (true)
signups_effective() {
  local o c
  o="$(signups_override)"
  if [[ -n "$o" ]]; then echo "$o"; return; fi
  c="$(signups_compose)"
  echo "${c:-true}"
}

do_signups() {
  require_installed
  local want="$1" val compose="$INSTALL_DIR/docker-compose.yml"
  local cfg="$INSTALL_DIR/vw-data/config.json" port

  case "${want,,}" in
    "")
      if [[ "$(signups_effective)" == "true" ]]; then
        msg "Inscriptions : OUVERTES"
      else
        msg "Inscriptions : fermées"
      fi
      if [[ -n "$(signups_override)" ]]; then
        warn "Valeur définie depuis /admin (config.json), elle prime sur docker-compose.yml."
      fi
      echo "Pour changer : sudo $(basename "$0") signups on|off"
      return 0
      ;;
    on|open|ouvrir)    val=true ;;
    off|close|fermer)  val=false ;;
    *)                 usage ;;
  esac

  local override
  override="$(signups_override)"
  if [[ "$(signups_compose)" == "$val" && ( -z "$override" || "$override" == "$val" ) ]]; then
    msg "Rien à faire : les inscriptions sont déjà $([[ $val == true ]] && echo ouvertes || echo fermées)."
    return 0
  fi

  # docker-compose.yml : remplace la valeur, ou ajoute la ligne si absente
  if grep -q 'SIGNUPS_ALLOWED:' "$compose"; then
    sed -i -E "s/(SIGNUPS_ALLOWED: )\"(true|false)\"/\1\"${val}\"/" "$compose"
  else
    sed -i "/^    environment:/a\\      SIGNUPS_ALLOWED: \"${val}\"" "$compose"
  fi

  # config.json (réglage fait depuis /admin) : sinon il l'emporterait
  if [[ -n "$override" ]]; then
    cp -p "$cfg" "$cfg.bak"
    sed -i -E "s/(\"signups_allowed\"[[:space:]]*:[[:space:]]*)(true|false)/\1${val}/" "$cfg"
    msg "Réglage de /admin (config.json) mis à jour aussi (copie : config.json.bak)."
  fi

  msg "Redémarrage de Vaultwarden…"
  port="$(vw_port)"
  cd "$INSTALL_DIR"
  docker compose up -d --force-recreate vaultwarden
  wait_alive "$port" || die "Vaultwarden ne répond pas : sudo $(basename "$0") status"

  if [[ "$(signups_effective)" == "$val" ]]; then
    if [[ "$val" == "true" ]]; then
      warn "Inscriptions OUVERTES : n'importe qui peut créer un compte."
      warn "Pense à les refermer : sudo $(basename "$0") signups off"
    else
      msg "Inscriptions fermées. Tu peux toujours inviter quelqu'un depuis /admin."
    fi
  else
    die "Le changement n'a pas été pris en compte, vérifie $compose et $cfg."
  fi
}

# =============================================================================
#  Point d'entrée
# =============================================================================
[[ $# -ge 1 && $# -le 2 ]] || usage
[[ $# -eq 1 || "$1" == "signups" ]] || usage
require_root "$@"
case "$1" in
  install)      do_install ;;
  update)       do_update ;;
  rollback)     do_rollback ;;
  status|check) do_status ;;
  signups)      do_signups "${2:-}" ;;
  *)            usage ;;
esac
