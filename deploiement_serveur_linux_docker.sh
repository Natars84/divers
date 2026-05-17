#!/bin/bash

set -euo pipefail

# ==========================================================
# VARIABLES DE DÉPLOIEMENT
# ==========================================================

# Génération de numéro de port SSH
## Définition des bornes du générateur
PORT_SSH_MINIMUM=10000
PORT_SSH_MAXIMUM=60000
#####

TIMEZONE="Europe/Paris"
LOG_FILE="/var/log/setup.log"
DOSSIER_DOCKER="/opt/docker"

FICHIER_SERVEUR_DEJA_CONFIGURE="/etc/serveur_configure" # Fichier indiquant que ce script a déjà été exécuté, donc le serveur est déjà configuré

# ==========================================================
# INITIALISATION DU SCRIPT ET DU FICHIER DE LOG
# ==========================================================

if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "Echec de la création du fichier de log, droits insuffisants (utilisez sudo)"
    exit 1
fi

if [ -z "$SUDO_USER" ] || [ "$SUDO_USER" = "root" ]; then
    log_message ERREUR "Lancez ce script avec sudo depuis un utilisateur non-root."
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
# VÉRIFICATION DE LA CONNECTIVITÉ INTERNET
# ==========================================================
log_message INFO "Vérification de la connectivité Internet et DNS."

# Test DNS
if ! getent hosts google.com > /dev/null 2>&1; then
    log_message ERREUR "Résolution DNS impossible. Tentative de correction..."

    # Correction persistante via systemd-resolved
    cat <<EOF > /etc/systemd/resolved.conf
[Resolve]
DNS=1.1.1.1 9.9.9.9 8.8.8.8
FallbackDNS=1.0.0.1 149.112.112.112
DNSSEC=yes
DNSOverTLS=yes
EOF

    systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1

    # S'assurer que resolv.conf pointe bien vers systemd-resolved
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    # Nouveau test après correction
    if ! getent hosts google.com > /dev/null 2>&1; then
        log_message ERREUR "DNS toujours inaccessible après correction. Arrêt du script."
        exit 1
    fi
    log_message INFO "DNS corrigé et persistant via systemd-resolved."
fi

# Test connectivité HTTP
if ! wget -q --spider --timeout=10 https://google.com > /dev/null 2>&1; then
    log_message ERREUR "Pas d'accès Internet (HTTP). Vérifiez votre passerelle ou pare-feu."
    exit 1
fi

log_message INFO "Connectivité Internet OK."

# ==========================================================
# PHASE 0 : DEMANDER A L'UTILISATEUR LES INFORMATIONS UTILES
# ==========================================================
# Configuration du nom du serveur
read -r -p "Nom du serveur ? (Par défaut: $(hostname)) : " NOM_SERVEUR
NOM_SERVEUR=${NOM_SERVEUR:-$(hostname)} # Le nom d'hôte de la machine par défaut
NOM_SERVEUR=$(echo "$NOM_SERVEUR" | tr -dc '[:alnum:]\-_') # Suppression des caractères problématiques

# Génération de la paire de clés SSH sur le serveur
NOM_CLE="$NOM_SERVEUR"
CHEMIN_CLE="/home/$SUDO_USER/.ssh/$NOM_CLE"

mkdir -p "/home/$SUDO_USER/.ssh"
chmod 700 "/home/$SUDO_USER/.ssh"

if [ ! -f "$CHEMIN_CLE" ]; then
    ssh-keygen -t ed25519 -f "$CHEMIN_CLE" -C "$NOM_CLE" -N ""
    log_message INFO "Paire de clés SSH générée : $CHEMIN_CLE"
else
    log_message INFO "Clé SSH déjà existante, conservée : $CHEMIN_CLE"
fi

# Autorisation de la clé publique sur ce serveur
cat "$CHEMIN_CLE.pub" >> "/home/$SUDO_USER/.ssh/authorized_keys"
chmod 600 "/home/$SUDO_USER/.ssh/authorized_keys"
chown -R "$SUDO_USER:$SUDO_USER" "/home/$SUDO_USER/.ssh"

# Affichage de la clé privée à copier sur le PC client
echo ""
echo "========================================================"
echo "  COPIEZ cette clé privée sur votre PC MAINTENANT"
echo "  Commande depuis votre PC :"
echo "  Fichier de destination recommandé : ~/.ssh/$NOM_CLE"
echo "========================================================"
cat "$CHEMIN_CLE"
echo "========================================================"
echo ""

# Pause — l'utilisateur confirme avoir copié la clé avant de continuer
read -r -p "Avez-vous copié la clé privée sur votre PC ? (oui/non) : " CLE_COPIEE
if [ "$CLE_COPIEE" != "oui" ]; then
    log_message ERREUR "Clé non confirmée. Arrêt du script pour éviter un lockout."
    exit 1
fi

# ==========================================================
# PHASE 1 : CONFIGURATION NON-INTERACTIVE ET FUSEAU HORAIRE
# ==========================================================
log_message INFO "Phase 1 : Configuration du mode APT non-interactif et du fuseau horaire."

export DEBIAN_FRONTEND=noninteractive

log_message INFO "Définition du fuseau horaire sur : $TIMEZONE."
ln -fs /usr/share/zoneinfo/$TIMEZONE /etc/localtime
dpkg-reconfigure -f noninteractive tzdata >> "$LOG_FILE" 2>&1

log_message INFO "Hostname de la machine renomée en: $NOM_SERVEUR"
hostname "$NOM_SERVEUR" # On met à jour le nom de la machine

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
(crontab -l 2>/dev/null; echo "0 2 * * * root apt update -y && apt upgrade -y && apt autoclean") | crontab -

# ==========================================================
# PHASE 4 : CONFIGURATION DE LA CONNEXION SSH
# ==========================================================
PORT_SSH=$(shuf -i $PORT_SSH_MINIMUM-$PORT_SSH_MAXIMUM -n 1) # Génération aléatoire du port SSH
log_message INFO "Phase 4 : Configuration SSH sur le port ${PORT_SSH}."

# Backup de la configuration SSH actuelle
if [ -f /etc/ssh/sshd_config ]; then
    mv /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
fi

# Injection de la nouvelle configuration SSH
cat <<EOF > /etc/ssh/sshd_config
# Configuration sécurisée
Port ${PORT_SSH}
Protocol 2
AddressFamily inet
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 2
LoginGraceTime 30
UsePAM yes
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
LogLevel VERBOSE
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

chown root:root /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config

mkdir -p /run/sshd
chmod 755 /run/sshd

systemctl stop ssh.socket >/dev/null 2>&1
systemctl disable ssh.socket >/dev/null 2>&1
systemctl mask ssh.socket >/dev/null 2>&1

# On valide la config SSH avant de redémarrer le service
CONFIG_SSH_VALIDE=0
if sshd -t; then
    CONFIG_SSH_VALIDE=1
    systemctl restart ssh
    log_message INFO "Service SSH redémarré avec succès sur le port ${PORT_SSH}."
else
    log_message ERREUR "ERREUR de syntaxe SSH. Le service n'a PAS été redémarré."
    mv /etc/ssh/sshd_config /etc/ssh/sshd_config.new
    mv /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    systemctl unmask ssh.socket >/dev/null 2>&1
    systemctl start ssh.socket >/dev/null 2>&1
    log_message INFO "Configuration SSH initiale restaurée."
fi

# ==========================================================
# PHASE 5 : PARE-FEU ET FAIL2BAN
# ==========================================================
log_message INFO "Phase 5 : Configuration UFW et Fail2Ban."

# UFW - Toujours autoriser le port SSH AVANT d'activer
ufw --force reset >> "$LOG_FILE" 2>&1
ufw default deny incoming
ufw default allow outgoing

# On ouvre le port SSH configuré (22 si la config SSH a échouée)
if [ $CONFIG_SSH_VALIDE -ne 1 ]; then
    PORT_SSH=22
    ufw allow ${PORT_SSH}/tcp
fi
ufw allow ${PORT_SSH}/tcp

echo "y" | ufw enable >> "$LOG_FILE" 2>&1

# Configuration de Fail2Ban
log_message INFO "Configuration des jails Fail2Ban..."

cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ${PORT_SSH}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

systemctl restart fail2ban >> "$LOG_FILE" 2>&1

# ==========================================================
# PHASE 6 : DOCKER
# ==========================================================
log_message INFO "Phase 6 : Installation et configuration de Docker."

# Ajout de la clé GPG de Docker
apt install ca-certificates curl >> "$LOG_FILE" 2>&1
install -m 0755 -d /etc/apt/keyrings >> "$LOG_FILE" 2>&1
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1
chmod a+r /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1

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
apt update --yes >> "$LOG_FILE" 2>&1
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

# Création du groupe Docker (utilsisation de la commande Docker sans sudo)
groupadd docker
usermod -aG docker $SUDO_USER

# Création d'un utilisateur dédié à Docker
useradd -r -s /bin/false -g docker dockeruser

# Test post-installation de Docker
log_message INFO "Test post-installation de docker."
docker run hello-world >> "$LOG_FILE" 2>&1

# Création du dossier Docker accueillant les projets compose
mkdir -p $DOSSIER_DOCKER
chown dockeruser:docker $DOSSIER_DOCKER
chmod 770 $DOSSIER_DOCKER

# Création d'un script de prune Docker
emplacementScriptPruneDocker="$DOSSIER_DOCKER/prune.sh"
cat << 'EOF' > "$emplacementScriptPruneDocker"
#!/bin/bash
LOG_PREFIX="[Docker-prune]"

log_message() { 
    echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $1" 
}

if [[ $EUID -ne 0 ]]; then
    log_message "ERREUR: le script doit être lancé en tant que 'root' (sudo)."
    exit 1
fi

log_message "Début du nettoyage complet de Docker."
docker system prune -af --volumes

log_message "Nettoyage terminé."
log_message "Espace disque actuel :"
docker system df
exit 0
EOF

chmod +x "$emplacementScriptPruneDocker"

# Lancement de Docker au démarrage
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# Ajout d'un raccourcis vers Docker
ln -s $DOSSIER_DOCKER /home/$SUDO_USER/docker

# ==========================================================
# PHASE 7 : PERSONNALISATION DU TERMINAL UTILISATEUR
# ==========================================================
log_message INFO "Phase 7 : personnalisation du serveur"
log_message INFO "Modification des prompt utilisateur et root"
cat << 'EOF' | sudo tee -a "/home/$SUDO_USER/.bashrc" > /dev/null
# Configuration personnalisée
export PS1="\[\$(tput bold)\]\[\$(tput setaf 6)\]\t: [\[\$(tput setaf 2)\]\u\[\$(tput setaf 7)\]\[\$(tput setaf 6)\]@\[\$(tput bold)\]\[\$(tput setaf 3)\]\H\[\$(tput setaf 6)\]]\[\$(tput setaf 5)\] \w\\$ \[\$(tput sgr0)\]"
EOF

# Personnalisation de la ligne de prompt des futurs utilisateurs
cat << 'EOF' | sudo tee -a "/etc/skel/.bashrc" > /dev/null
# Configuration personnalisée
export PS1="\[\$(tput bold)\]\[\$(tput setaf 6)\]\t: [\[\$(tput setaf 2)\]\u\[\$(tput setaf 7)\]\[\$(tput setaf 6)\]@\[\$(tput bold)\]\[\$(tput setaf 3)\]\H\[\$(tput setaf 6)\]]\[\$(tput setaf 5)\] \w\\$ \[\$(tput sgr0)\]"
EOF

# Personnalisation de la ligne de prompt de root
cat << 'EOF' | sudo tee -a "/root/.bashrc" > /dev/null
# Configuration personnalisée
export PS1="\[\$(tput bold)\]\[\$(tput setaf 6)\]\t: [\[\$(tput setaf 1)\]\u\[\$(tput setaf 7)\]\[\$(tput setaf 6)\]@\[\$(tput bold)\]\[\$(tput setaf 3)\]\H\[\$(tput setaf 6)\]]\[\$(tput setaf 5)\] \w\\$ \[\$(tput sgr0)\]"
EOF

log_message INFO "Génération du MOTD"
apt install --yes figlet toilet >> "$LOG_FILE" 2>&1
toilet --termwidth -f standard "$NOM_SERVEUR" --filter border > /etc/motd
apt remove --yes figlet toilet >> "$LOG_FILE" 2>&1
apt autoremove --yes >> "$LOG_FILE" 2>&1

touch "$FICHIER_SERVEUR_DEJA_CONFIGURE"
log_message INFO "Fin de configuration. Pensez à vérifier votre accès avant de fermer cette session."
