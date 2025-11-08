#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ALLWAYSUP INSTALLER + GIT SYNC AUTOMATION
# filename: andgo.sh
#
# INSTALLATION PURPOSE:
#   - Create system user: allwaysup
#   - Create required directory structure:
#         /home/allwaysup/install
#         /home/allwaysup/services/backup
#         /home/allwaysup/wifi_tools
#         /home/allwaysup/gitrepo              (bare repo storage)
#
#   - Initialize Git:
#         Working repo: /home/allwaysup
#         Bare repo:    /home/allwaysup/gitrepo/allwaysup.git
#   - Generate SSH key (format): ed25519_allwaysup_<owner>_<uuid>
#         Ensures single key use, prompts if keys already exist.
#   - Do NOT clone or pull any data during install.
#         Working repo contains only README.md after initialization.
#
#   - Populate automation scripts:
#         /home/allwaysup/services/backup/allwaysup_local_sync.sh
#             Mirrors /home/allwaysup → /home/allwaysup/gitrepo
#             Uses rsync + exclusion rules
#             Compresses logs and retains last 25
#
#         /home/allwaysup/services/backup/git_auto_push.sh
#             Auto git commit + push (only if changes exist)
#
#         /home/allwaysup/install/initialize_repo.sh
#             Allows optional GitHub pull if repo is empty
#
#         /home/allwaysup/install/establish_localrepo_sync_and_git_push_cron.sh
#             Creates cron entry for automated sync + git push
#             Only executed after repo is successfully initialized
#
# RESULT AFTER INSTALL:
#   ✅ Repo structure created
#   ✅ SSH key created or reused
#   ✅ Sync + push automation scripts in place
#   ✅ No data pulled until user approves
#
# REQUIREMENTS:
#   - Must be run as root
#
# INSTALLER USAGE:
# curl -L "https://raw.githubusercontent.com/DeGrinch/allwaysup_install/main/andgo.sh" -o andgo.sh
# chmod +x andgo.sh
# ./andgo.sh
###############################################################################

DEFAULT_REPO="https://github.com/CMO-GAMING/allwaysup"
SYSTEM_USER="allwaysup"
ROOT="/home/${SYSTEM_USER}"
SSH_DIR="${ROOT}/.ssh"
WORK_REPO="${ROOT}"
BARE_REPO_DIR="${ROOT}/gitrepo"
BARE_REPO="${ROOT}/gitrepo/allwaysup.git"
SYNC_BIN="${ROOT}/services/backup/allwaysup_local_sync.sh"
INIT_BIN="${ROOT}/install/initialize_repo.sh"
CRON_SETUP_BIN="${ROOT}/install/establish_localrepo_sync_and_git_push_cron.sh"
GIT_PUSH_BIN="${ROOT}/services/backup/git_auto_push.sh"

log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }


###############################################################################
# ROOT CHECK
###############################################################################
[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 1; }


###############################################################################
# USER + DIRECTORY STRUCTURE
###############################################################################
id "$SYSTEM_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$SYSTEM_USER"

mkdir -p "${ROOT}/install" "${ROOT}/wifi_tools" "${ROOT}/services/backup" "${BARE_REPO_DIR}"
chown -R "$SYSTEM_USER":"$SYSTEM_USER" "$ROOT"


###############################################################################
# REPO URL INPUT
###############################################################################
read -rp "Repo URL (default ${DEFAULT_REPO}): " REPO_URL
REPO_URL="${REPO_URL:-$DEFAULT_REPO}"

REPO_OWNER="$(echo "$REPO_URL" | sed -E 's|.*github.com[:/]+([^/]+).*$|\1|')"
UUID="$(uuidgen)"
KEY_NAME="ed25519_allwaysup_${REPO_OWNER}_${UUID}"
KEY_PATH="${SSH_DIR}/${KEY_NAME}"


###############################################################################
# SSH KEY MANAGEMENT
###############################################################################
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"; chown "$SYSTEM_USER":"$SYSTEM_USER" "$SSH_DIR"

EXISTING_KEYS=$(find "$SSH_DIR" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_*" -o -name "ed25519*" \) || true)

if [[ -n "$EXISTING_KEYS" ]]; then
    echo
    echo "SSH key(s) already exist!"
    echo "Generating a new key will REVOKE the old repo access."
    echo "1. Keep current key"
    echo "2. Delete and generate new"
    read -rp "Choose [1 or 2]: " ANSWER

    if [[ "$ANSWER" == "2" ]]; then
        find "$SSH_DIR" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_*" -o -name "ed25519*" \) -exec rm -f {} +
        USE_EXISTING_KEY=false
    else
        USE_EXISTING_KEY=true
    fi
else
    USE_EXISTING_KEY=false
fi

if [[ "$USE_EXISTING_KEY" != true ]]; then
    echo
    echo "Optional: supply path to existing private key (ENTER for auto-generate):"
    read -rp "> " KEY_SRC

    if [[ -n "$KEY_SRC" && -f "$KEY_SRC" ]]; then
        cp "$KEY_SRC" "$KEY_PATH"
        chmod 600 "$KEY_PATH"
        chown "$SYSTEM_USER":"$SYSTEM_USER" "$KEY_PATH"
    else
        sudo -u "$SYSTEM_USER" ssh-keygen -t ed25519 -C "$KEY_NAME" -f "$KEY_PATH" -N "" >/dev/null
    fi
fi

ssh-keyscan -t rsa github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null
chmod 644 "${SSH_DIR}/known_hosts"
chown "$SYSTEM_USER":"$SYSTEM_USER" "${SSH_DIR}/known_hosts"

echo
echo "----- PUBLIC KEY — ADD TO GITHUB → REPO → DEPLOY KEYS -----"
cat "${KEY_PATH}.pub" || true
echo "------------------------------------------------------------"
echo


###############################################################################
# REPO INITIALIZATION
###############################################################################
[[ ! -d "$BARE_REPO" ]] && sudo -u "$SYSTEM_USER" git init --bare "$BARE_REPO"

if [[ ! -d "${WORK_REPO}/.git" ]]; then
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" init
    sudo -u "$SYSTEM_USER" bash -c "echo '# allwaysup repo' > ${ROOT}/README.md"
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
# SCRIPT: allwaysup_local_sync.sh
###############################################################################
cat > "$SYNC_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SOURCE="/home/allwaysup/"
TARGET="/home/allwaysup/gitrepo"
LOGDIR="/home/allwaysup/logs"
LOGFILE="$LOGDIR/sync_to_repo.log"
DATESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

mkdir -p "$LOGDIR"

cd "$LOGDIR" || exit 1
if [ -f "$LOGFILE" ]; then gzip -f "$LOGFILE"; fi
ls -1t sync_to_repo.log* | tail -n +26 | xargs -r rm -f

echo "[$DATESTAMP] Sync starting" >> "$LOGFILE"

rsync -av --delete \
    --exclude='.ssh/' --exclude='.git/' --exclude='*.log' \
    "$SOURCE" "$TARGET" >> "$LOGFILE" 2>&1

echo "[$DATESTAMP] Sync done" >> "$LOGFILE"
EOF


###############################################################################
# SCRIPT: git_auto_push.sh
###############################################################################
cat > "$GIT_PUSH_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO="/home/allwaysup"
LOGFILE="/home/allwaysup/logs/git_auto_push.log"
DATESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

mkdir -p "$(dirname "$LOGFILE")"
cd "$REPO" || exit 1

git add -A

if git diff --cached --quiet; then
    echo "[$DATESTAMP] Nothing to commit" >> "$LOGFILE"
    exit 0
fi

git commit -m "Automated sync: $DATESTAMP" >> "$LOGFILE" 2>&1
git push --all origin >> "$LOGFILE" 2>&1
EOF


###############################################################################
# SCRIPT: initialize_repo.sh
###############################################################################
cat > "$INIT_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSTEM_USER="allwaysup"
ROOT="/home/$SYSTEM_USER"
BARE="$ROOT/gitrepo"
WORK="$ROOT"

echo "checking for repo data..."

if ! sudo -u "$SYSTEM_USER" git -C "$BARE" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "No repo data detected."
    echo "Pull from GitHub now?"
    echo "  1. Yes"
    echo "  2. No"
    read -rp "> " ANSWER

    [[ "$ANSWER" != "1" ]] && exit 0

    sudo -u "$SYSTEM_USER" git -C "$BARE" fetch upstream --all || {
        echo "Unable to reach GitHub. Add SSH key to repo."
        exit 1
    }

    sudo -u "$SYSTEM_USER" git -C "$WORK" pull --ff-only origin || {
        echo "Pull not safe. Resolve manually."
        exit 1
    }

    /home/allwaysup/install/establish_localrepo_sync_and_git_push_cron.sh
    exit 0
fi

/home/allwaysup/install/establish_localrepo_sync_and_git_push_cron.sh
exit 0
EOF


###############################################################################
# SCRIPT: establish_localrepo_sync_and_git_push_cron.sh
###############################################################################
cat > "$CRON_SETUP_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSTEM_USER="allwaysup"
CRON_LINE='0 * * * * nice -n 10 ionice -c2 -n7 /home/allwaysup/services/backup/allwaysup_local_sync.sh && nice -n 10 ionice -c2 -n7 /home/allwaysup/services/backup/git_auto_push.sh'

if sudo -u "$SYSTEM_USER" crontab -l | grep -F "$CRON_LINE" >/dev/null 2>&1; then exit 0; fi

( sudo -u "$SYSTEM_USER" crontab -l 2>/dev/null; echo "$CRON_LINE" ) | sudo -u "$SYSTEM_USER" crontab -
EOF


###############################################################################
# PERMISSIONS + RUN INITIALIZATION
###############################################################################
chmod +x "$SYNC_BIN" "$GIT_PUSH_BIN" "$INIT_BIN" "$CRON_SETUP_BIN"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$SYNC_BIN" "$GIT_PUSH_BIN" "$INIT_BIN" "$CRON_SETUP_BIN"

echo; echo "Running repo initializer..."
"$INIT_BIN" || echo "Add SSH key to GitHub and re-run initialize_repo.sh"


###############################################################################
# POST INSTALL
###############################################################################
echo
echo "========================================================="
echo " INSTALL COMPLETE"
echo "========================================================="
echo "Add SSH key to GitHub → REPO → Settings → Deploy keys"
echo "Re-run if needed:  $INIT_BIN"
echo
echo "To sync manually:"
echo "      /home/allwaysup/services/backup/allwaysup_local_sync.sh"
echo
echo "To auto push manually:"
echo "      /home/allwaysup/services/backup/git_auto_push.sh"
echo
echo "Repo paths:"
echo "  Working repo:   /home/allwaysup/"
echo "  Bare repo:      /home/allwaysup/gitrepo/"
echo "  Install scripts:/home/allwaysup/install/"
echo "========================================================="
