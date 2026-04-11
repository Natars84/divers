#!/bin/bash

# ==========================================================
# VARIABLES DE DÉPLOIEMENT
# ==========================================================
PORT_SSH=47165
TIMEZONE="Europe/Paris"
LOG_FILE="/var/log/setup.log"
FICHIER_SERVEUR_DEJA_CONFIGURE="/etc/serveur_configure" # Fichier indiquant que ce script a déjà été exécuté, donc le serveur est déjà configuré

# ==========================================================
# INITIALISATION DU SCRIPT ET DU FICHIER DE LOG
# ==========================================================

if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "Echec de la création du fichier de log, droits insuffisants (utilisez sudo)"
    exit 1
fi

log_message() {
    local TYPE="$1"
    local MESSAGE="$2"
    local FORMATTED_MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [$TYPE] $MESSAGE"

    echo "$FORMATTED_MSG"
    # Correction ici : Utilisation de la variable MESSAGE correcte
    echo "$FORMATTED_MSG" >> "$LOG_FILE" 2>&1
}

log_message INFO "Début de l'exécution du script de déploiement Ubuntu."

if [ -f "$FICHIER_SERVEUR_DEJA_CONFIGURE" ]; then
    log_message INFO "Le serveur a déjà été configuré, arrêt du script."
    exit 0
fi

# ==========================================================
# PHASE 1 : CONFIGURATION NON-INTERACTIVE ET FUSEAU HORAIRE
# ==========================================================
log_message INFO "Phase 1 : Configuration du mode APT non-interactif et du fuseau horaire."

export DEBIAN_FRONTEND=noninteractive

log_message INFO "Définition du fuseau horaire sur : $TIMEZONE."
ln -fs /usr/share/zoneinfo/$TIMEZONE /etc/localtime
dpkg-reconfigure -f noninteractive tzdata >> "$LOG_FILE" 2>&1

# ==========================================================
# PHASE 2 : MISE À JOUR ET INSTALLATION DES PAQUETS
# ==========================================================
log_message INFO "Phase 2 : Mise à jour et installation des paquets de base."

apt update --yes >> "$LOG_FILE" 2>&1
apt upgrade --yes >> "$LOG_FILE" 2>&1

log_message INFO "Installation des paquets essentiels..."
apt install --yes unattended-upgrades tzdata nano cron wget screen ssh sudo ufw fail2ban >> "$LOG_FILE" 2>&1

# Configuration auto-upgrades
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades >> "$LOG_FILE" 2>&1

# ==========================================================
# PHASE 3 : CONFIGURATION DE LA CRONTAB
# ==========================================================
log_message INFO "Phase 3 : Configuration de la crontab."

# Mise à jour du système chaque nuit à 2h du matin en tant que root
echo "0 2 * * * root apt update -y && apt upgrade -y && apt autoclean" | crontab -

# ==========================================================
# PHASE 4 : CONFIGURATION DE LA CONNEXION SSH
# ==========================================================
log_message INFO "Phase 4 : Configuration SSH sur le port ${PORT_SSH}."

# Backup de la configuration SSH actuelle
if [ -f /etc/ssh/sshd_config ]; then
    mv /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
fi

# Injection de la nouvelle configuration SSH
echo "# Configuration sécurisée" > /etc/ssh/sshd_config
echo "Port ${PORT_SSH}" >> /etc/ssh/sshd_config
echo "Protocol 2" >> /etc/ssh/sshd_config
echo "AddressFamily inet" >> /etc/ssh/sshd_config
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
echo "AuthenticationMethods publickey" >> /etc/ssh/sshd_config
echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
echo "MaxSessions 2" >> /etc/ssh/sshd_config
echo "LoginGraceTime 30" >> /etc/ssh/sshd_config
echo "X11Forwarding no" >> /etc/ssh/sshd_config
echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
echo "AllowAgentForwarding no" >> /etc/ssh/sshd_config
echo "AllowStreamLocalForwarding no" >> /etc/ssh/sshd_config
echo "GatewayPorts no" >> /etc/ssh/sshd_config
echo "PermitTunnel no" >> /etc/ssh/sshd_config
echo "KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" >> /etc/ssh/sshd_config
echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com" >> /etc/ssh/sshd_config
echo "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com" >> /etc/ssh/sshd_config
echo "LogLevel VERBOSE" >> /etc/ssh/sshd_config
echo "PrintMotd no" >> /etc/ssh/sshd_config
echo "AcceptEnv LANG LC_*" >> /etc/ssh/sshd_config
echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config

chown root:root /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config

# ==========================================================
# PHASE 5 : PARE-FEU ET FAIL2BAN
# ==========================================================
log_message INFO "Phase 5 : Configuration UFW et Fail2Ban."

# UFW - Toujours autoriser le port SSH AVANT d'activer
ufw --force reset >> "$LOG_FILE" 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ${PORT_SSH}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable >> "$LOG_FILE" 2>&1

# Configuration de Fail2Ban
log_message INFO "Configuration des jails Fail2Ban..."

echo "[sshd]" > /etc/fail2ban/jail.local
echo "enabled = true" >> /etc/fail2ban/jail.local
echo "port = ${PORT_SSH}" >> /etc/fail2ban/jail.local
echo "filter = sshd" >> /etc/fail2ban/jail.local
echo "logpath = /var/log/auth.log" >> /etc/fail2ban/jail.local
echo "maxretry = 3" >> /etc/fail2ban/jail.local
echo "bantime = 3600" >> /etc/fail2ban/jail.local

systemctl restart fail2ban >> "$LOG_FILE" 2>&1

# ==========================================================
# PHASE 6 : DOCKER
# ==========================================================
log_message INFO "Phase 6 : Installation et configuration de Docker."

# Ajout de la clé GPG de Docker
apt install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Ajout du dépôt aux sources APT
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Mise à jour des dépôts et installation de Docker
apt update --yes
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Création du groupe Docker (utilsisation de la commande Docker sans sudo)
groupeadd docker
sudo usermod -aG docker $USER
newgrp docker

# Test post-installation de Docker
echo "Test post-installation de docker."
docker run hello-world

# Lancement de Docker au démarrage
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# ==========================================================
# FINALISATION
# ==========================================================
# On valide la config SSH avant de redémarrer le service
if sshd -t; then
    systemctl restart ssh
    log_message INFO "Service SSH redémarré avec succès sur le port ${PORT_SSH}."
    touch "$FICHIER_SERVEUR_DEJA_CONFIGURE"
else
    log_message ERREUR "ERREUR de syntaxe SSH. Le service n'a PAS été redémarré."
fi

log_message INFO "Fin de configuration. Pensez à vérifier votre accès avant de fermer cette session."
