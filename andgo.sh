#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CONTEXT HEADER: ALLWAYSUP INSTALLER + GIT SYNC INITIALIZATION (FINAL)
#
# PURPOSE:
#   - Create system user: allwaysup
#   - Create required directory structure:
#         /home/allwaysup/install
#         /home/allwaysup/services/backup
#         /home/allwaysup/wifi_tools        (network tools only)
#         /home/allwaysup/gitrepo           (bare repo location)
#
#   - Initialize working git repo: /home/allwaysup
#   - Initialize bare repo:        /home/allwaysup/gitrepo/allwaysup.git
#   - Generate unique SSH key:     ed25519_allwaysup_<owner>_<uuid>
#   - DO NOT CLONE or PULL any code. Repo remains empty except README.md.
#
#   - Populate sync automation script: /home/allwaysup/services/backup/allwaysup_local_sync.sh
#       * Mirrors /home/allwaysup → /home/allwaysup/gitrepo
#       * Uses rsync with a strict exclusion list
#       * Log rotation (keeps last 25 logs)
#
#
# --------------------------------------------------------------------
# FOR DOWNLOAD AND INSTALL
# --------------------------------------------------------------------
# Download installer into current directory:
# curl -L "https://raw.githubusercontent.com/DeGrinch/allwaysup_install/main/andgo.sh" -o andgo.sh
#
# Make executable:
# chmod +x andgo.sh
#
# Run installer:
# ./andgo.sh
# --------------------------------------------------------------------
#
# REQUIREMENTS:
#   - Must be run as root
###############################################################################

DEFAULT_REPO="https://github.com/CMO-GAMING/allwaysup"
SYSTEM_USER="allwaysup"
ROOT="/home/${SYSTEM_USER}"
SSH_DIR="${ROOT}/.ssh"
WORK_REPO="${ROOT}"
BARE_REPO="${ROOT}/gitrepo/allwaysup.git"
SYNC_BIN="${ROOT}/services/backup/allwaysup_local_sync.sh"

log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 1; }

id "$SYSTEM_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$SYSTEM_USER"

mkdir -p "${ROOT}/install" "${ROOT}/wifi_tools" "${ROOT}/services/backup"
chown -R "$SYSTEM_USER":"$SYSTEM_USER" "$ROOT"

read -rp "Repo URL (default ${DEFAULT_REPO}): " REPO_URL
REPO_URL="${REPO_URL:-$DEFAULT_REPO}"

REPO_OWNER="$(echo "$REPO_URL" | sed -E 's|.*github.com[:/]+([^/]+).*$|\1|')"
UUID="$(uuidgen)"
KEY_NAME="ed25519_allwaysup_${REPO_OWNER}_${UUID}"
KEY_PATH="${SSH_DIR}/${KEY_NAME}"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$SSH_DIR"

echo
echo "Optional: provide path to existing SSH private key (ENTER to auto-generate):"
read -rp "> " KEY_SRC

if [[ -n "$KEY_SRC" && -f "$KEY_SRC" ]]; then
    cp "$KEY_SRC" "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    chown "$SYSTEM_USER":"$SYSTEM_USER" "$KEY_PATH"
else
    sudo -u "$SYSTEM_USER" ssh-keygen -t ed25519 -C "$KEY_NAME" -f "$KEY_PATH" -N "" >/dev/null
fi

ssh-keyscan -t rsa github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null
chmod 644 "${SSH_DIR}/known_hosts"
chown "$SYSTEM_USER":"$SYSTEM_USER" "${SSH_DIR}/known_hosts"

echo
echo "----- PUBLIC KEY (ADD TO GITHUB) -----"
cat "${KEY_PATH}.pub"
echo "--------------------------------------"
echo

mkdir -p "$(dirname "$BARE_REPO")"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$(dirname "$BARE_REPO")"

if [[ ! -d "$BARE_REPO" ]]; then
    sudo -u "$SYSTEM_USER" git init --bare "$BARE_REPO"
fi

if [[ ! -d "${WORK_REPO}/.git" ]]; then
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" init
    sudo -u "$SYSTEM_USER" bash -c "cd '$WORK_REPO'; echo '# allwaysup repo' > README.md"
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" add README.md
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" commit -m 'initial commit'
fi

if [[ "$REPO_URL" =~ ^https://github.com/(.+)/(.+)$ ]]; then
    REPO_URL="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
fi

sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote remove origin 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote remove localpush 2>/dev/null || true

sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote add origin "$REPO_URL"
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote add localpush "$BARE_REPO"

sudo -u "$SYSTEM_USER" git -C "$BARE_REPO" remote remove upstream 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$BARE_REPO" remote add upstream "$REPO_URL"

###############################################################################
# WRITE EXACT SYNC SCRIPT (DO NOT MODIFY CONTENT)
###############################################################################
cat > "$SYNC_BIN" <<'EOF'
#!/bin/bash
# ---------------------------------------------------------------------
# allwaysup_local_sync.sh
# Safely mirrors /home/allwaysup -> /home/allwaysup/gitrepo
# Excludes sensitive, system, cache, and non-versionable files.
# Rotates logs, keeps last 25 (older logs deleted).
# ---------------------------------------------------------------------

SOURCE="/home/allwaysup/"
TARGET="/home/allwaysup/gitrepo"
LOGDIR="/home/allwaysup/logs"
LOGFILE="$LOGDIR/sync_to_repo.log"
DATESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

mkdir -p "$LOGDIR"

cd "$LOGDIR" || exit 1
if [ -f "$LOGFILE" ]; then
  gzip -f "$LOGFILE"
fi

ls -1t sync_to_repo.log* 2>/dev/null | tail -n +26 | xargs -r rm -f

echo "[$DATESTAMP] Starting sync from $SOURCE to $TARGET" >> "$LOGFILE"

if [ "$SOURCE" = "$TARGET" ]; then
  echo "ERROR: Source and target directories are identical. Aborting." | tee -a "$LOGFILE"
  exit 1
fi

if [ ! -d "$TARGET/.git" ]; then
  echo "ERROR: Target does not appear to be a Git repository. Aborting." | tee -a "$LOGFILE"
  exit 1
fi

rsync -av --delete \
  --exclude='.env' \
  --exclude='tmp/' \
  --exclude='public_html/' \
  --exclude='homes/' \
  --exclude='cgi-bin/' \
  --exclude='.filemin/' \
  --exclude='.spamassassin/' \
  --exclude='.tmp/' \
  --exclude='awstats/' \
  --exclude='bin/' \
  --exclude='virtualmin-backup/' \
  --exclude='etc/' \
  --exclude='.awstats-htpasswd' \
  --exclude='.lesshst' \
  --exclude='guild_settings.db*' \
  --exclude='about_the_database.txt' \
  --exclude='.workspace_context.json' \
  --exclude='thegoatbot.db*' \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='.gitignore' \
  --exclude='.mypy_cache/' \
  --exclude='__pycache__/' \
  --exclude='.cache/' \
  --exclude='.config/' \
  --exclude='.gnupg/' \
  --exclude='.local/' \
  --exclude='.npm/' \
  --exclude='.pm2/' \
  --exclude='.ssh/' \
  --exclude='.vscode-remote-containers/' \
  --exclude='.vscode-server/' \
  --exclude='.venv/' \
  --exclude='venv/' \
  --exclude='.bash_history' \
  --exclude='.bash_logout' \
  --exclude='.bashrc' \
  --exclude='.profile' \
  --exclude='.python_history' \
  --exclude='.selected_editor' \
  --exclude='.sudo_as_admin_successful' \
  --exclude='.wget-hsts' \
  --exclude='backups_src/' \
  --exclude='allwaysup_BACKUPS/' \
  --exclude='custom_packages/' \
  --exclude='data/' \
  --exclude='guild_member_logs/' \
  --exclude='logs/' \
  --exclude='sync_logs/' \
  --exclude='Maildir/' \
  --exclude='node_modules/' \
  --exclude='snap/' \
  --exclude='trash/' \
  --exclude='.trash/' \
  --exclude='.Trash/' \
  --exclude='*.log' \
  --exclude='*.sqlite*' \
  --exclude='*.bak' \
  --exclude='*.py_backup_*' \
  --exclude='*.token*' \
  --exclude='*.secret*' \
  --exclude='berconpy-client.tar.gz' \
  --exclude='cron.log' \
  --exclude='hourly_sync.log' \
  --exclude='package-lock.json' \
  --exclude='thegoatbot.log' \
  --exclude='assets/' \
  --exclude='ecosystem.config.js' \
  --exclude='lint_report.txt' \
  --exclude='mypy_report.txt' \
  --exclude='db_helper.py*' \
  --exclude='allwaysup/' \
  "$SOURCE" "$TARGET" >> "$LOGFILE" 2>&1

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
  echo "[$DATESTAMP] Sync completed successfully." >> "$LOGFILE"
else
  echo "[$DATESTAMP] Sync failed with exit code $EXIT_CODE" >> "$LOGFILE"
fi

exit $EXIT_CODE
EOF

chmod +x "$SYNC_BIN"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$SYNC_BIN"

log "installer complete"
