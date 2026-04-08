#!/bin/bash

# ==========================================================
# IDENTIFIANTS ADMIN DE BASE
# ==========================================================

DEFAULT_ADMIN_USER="admin"
DEFAULT_ADMIN_PWD="changemoisitupeux"

# ==========================================================
# VARIABLES DE DÉPLOIEMENT
# ==========================================================

SCRIPT_DIR=$(dirname "$0")
DOSSIER_DEPLOIEMENT="${SCRIPT_DIR}/deploiement"
DOSSIER_APPLICATION="${SCRIPT_DIR}/application"

mkdir -p "$DOSSIER_DEPLOIEMENT" "$DOSSIER_APPLICATION" 2>/dev/null

# ==========================================================
# INITIALISATION DU SCRIPT ET DU FICHIER DE LOG
# ==========================================================

# Définition du chemin des logs
LOG_FILE="/var/log/setup.log"

if ! $(touch  "$LOG_FILE"); then
    echo "Echec de la création du fichier de log, droits insuffisants"
    exit 1
fi

# Fonction de journalisation avec double écriture
log_message() {
    local TYPE="$1"
    local MESSAGE="$2"
    local FORMATTED_MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [$TYPE] $MESSAGE"

    # Écriture sur la console (stdout)
    echo "$FORMATTED_MSG"

    # Écriture dans le fichier de log (avec horodatage)
    echo "$FORMATTED
" >> "$LOG_FILE" 2>&1
}

# Journalisation de démarrage
log_message INFO "Début de l'exécution du script de déploiement Ubuntu."

# Vérification si le serveur est déjà configuré
FICHIER_SERVEUR_DEJA_CONFIGURE="/etc/serveur_configure"
if [ -f "$FICHIER_SERVEUR_DEJA_CONFIGURE" ]; then
    log_message INFO "Le serveur a déjà été configuré, arrêt du script."
    exit 0
fi

# ==========================================================
# PHASE 1 : CONFIGURATION NON-INTERACTIVE ET FUSEAU HORAIRE
# ==========================================================

log_message INFO "Phase 1 : Configuration du mode APT non-interactif et du fuseau horaire."

# Désactivation des invites interactives
export DEBIAN_FRONTEND=noninteractive
log_message DEBUG "DEBIAN_FRONTEND défini sur 'noninteractive'."

# Définition du fuseau horaire
TIMEZONE="Europe/Paris"
log_message INFO "Définition du fuseau horaire sur : $TIMEZONE."
echo "$TIMEZONE" > /etc/timezone >> "$LOG_FILE" 2>&1

# ==========================================================
# PHASE 2 : MISE À JOUR ET INSTALLATION DES PAQUETS
# ==========================================================

log_message INFO "Phase 2 : Mise à jour et installation des paquets de base."

log_message INFO "Mise à jour de l'index des paquets (apt update)..."
if ! apt update --yes >> "$LOG_FILE" 2>&1; then
    log_message ERREUR "Échec de la mise à jour de l'index APT. Voir le fichier de log pour les détails."
    exit 1
fi

log_message INFO "Mise à niveau des paquets existants (apt upgrade)..."
if ! apt upgrade --yes >> "$LOG_FILE" 2>&1; then
    log_message AVERTISSEMENT "Échec ou avertissement lors de l'upgrade des paquets. Voir le fichier de log."
fi

log_message INFO "Installation de l'utilitaire de mise à jour de sécurité unattended-upgrades"
if ! apt install --yes unattended-upgrades >> "$LOG_FILE" 2>&1; then
    log_message AVERTISSEMENT "Échec ou avertissement lors de l'installation."
else
    echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
fi

log_message INFO "Installation de tzdata et des paquets de base."
if ! apt install --yes tzdata nano cron wget screen ssh sudo >> "$LOG_FILE" 2>&1; then
    log_message AVERTISSEMENT "Échec ou avertissement lors de l'installation des paquets de base."
fi

dpkg-reconfigure -f noninteractive tzdata >> "$LOG_FILE" 2>&1
log_message DEBUG "tzdata reconfiguré en mode non-interactif."

# ==========================================================
# PHASE 3 : CONFIGURATION DE LA CRONTAB
# ==========================================================

log_message INFO "Phase 3 : Configuration de la crontab"

service cron start >> "$LOG_FILE" 2>&1

/usr/bin/crontab - <<EOF >> "$LOG_FILE" 2>&1
0 2 * * * /usr/bin/apt update -y && /usr/bin/apt upgrade -y && /usr/bin/apt autoremove -y && /usr/bin/apt autoclean
EOF

log_message INFO "Crontab configurée avec succès."
