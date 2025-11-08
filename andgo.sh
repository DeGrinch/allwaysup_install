#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ALLWAYSUP INSTALLER + GIT SYNC & AUTOMATION
# filename: andgo.sh
#
# PURPOSE / WHAT THIS INSTALLER DOES:
# -----------------------------------
#   1. Creates a system user named: allwaysup
#   2. Creates these folders:
#        /home/allwaysup/install                  (scripts that run once)
#        /home/allwaysup/services/backup          (sync + git push automation)
#        /home/allwaysup/wifi_tools               (reserved for future tools)
#        /home/allwaysup/gitrepo                  (bare repo storage)
#   3. Initializes git:
#        /home/allwaysup/                         (working repo)
#        /home/allwaysup/gitrepo/allwaysup.git    (bare repo mirror)
#   4. Generates SSH key (format): ed25519_allwaysup_<owner>_<uuid>
#        - only one key can exist
#        - prompts if key already exists
#   5. Populates automation scripts:
#        allwaysup_local_sync.sh                  (rsync filesystem → bare repo)
#        git_auto_push.sh                         (auto commit + push only if needed)
#        initialize_repo.sh                       (pull from GitHub ONLY IF empty)
#        establish_localrepo_sync_and_git_push_cron.sh (installs cron *after* repo exists)
#
# NOTHING IS CLONED DURING INSTALL.
# Repo remains empty except README.md until user runs initialize_repo.sh.
#
# -----------------------------------------------------------------------------
# REQUIREMENTS: must be run as root
# -----------------------------------------------------------------------------
#
# INSTALL COMMAND (from github):
# curl -L "https://raw.githubusercontent.com/DeGrinch/allwaysup_install/main/andgo.sh" -o andgo.sh
# chmod +x andgo.sh
# ./andgo.sh
###############################################################################


# --------------------------
# INSTALL CONFIG & CONSTANTS
# --------------------------
DEFAULT_REPO="https://github.com/CMO-GAMING/allwaysup"
SYSTEM_USER="allwaysup"
ROOT="/home/${SYSTEM_USER}"
SSH_DIR="${ROOT}/.ssh"
WORK_REPO="${ROOT}"
BARE_REPO_DIR="${ROOT}/gitrepo"
BARE_REPO="${ROOT}/gitrepo/allwaysup.git"

# Script output locations
SYNC_BIN="${ROOT}/services/backup/allwaysup_local_sync.sh"
GIT_PUSH_BIN="${ROOT}/services/backup/git_auto_push.sh"
INIT_BIN="${ROOT}/install/initialize_repo.sh"
CRON_SETUP_BIN="${ROOT}/install/establish_localrepo_sync_and_git_push_cron.sh"

log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }


###############################################################################
# ROOT CHECK
###############################################################################
[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: must run as root"; exit 1; }


###############################################################################
# CREATE USER AND DIRECTORY STRUCTURE
###############################################################################
# Creates user only if not already made.
id "$SYSTEM_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$SYSTEM_USER"

mkdir -p "${ROOT}/install" "${ROOT}/wifi_tools" "${ROOT}/services/backup" "${BARE_REPO_DIR}"
chown -R "$SYSTEM_USER":"$SYSTEM_USER" "$ROOT"


###############################################################################
# PROMPT USER FOR REPOSITORY URL
###############################################################################
read -rp "Repo URL (default ${DEFAULT_REPO}): " REPO_URL
REPO_URL="${REPO_URL:-$DEFAULT_REPO}"

# extract repo owner from provided URL
REPO_OWNER="$(echo "$REPO_URL" | sed -E 's|.*github.com[:/]+([^/]+).*$|\1|')"

UUID="$(uuidgen)"
KEY_NAME="ed25519_allwaysup_${REPO_OWNER}_${UUID}"
KEY_PATH="${SSH_DIR}/${KEY_NAME}"


###############################################################################
# SSH KEY MANAGEMENT FOR GITHUB ACCESS
###############################################################################
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"; chown "$SYSTEM_USER":"$SYSTEM_USER" "$SSH_DIR"

# detect any existing key files
EXISTING_KEYS=$(find "$SSH_DIR" -maxdepth 1 -type f \( -name "*.pem" -o -name "id_*" -o -name "ed25519*" \) || true)

if [[ -n "$EXISTING_KEYS" ]]; then
    echo
    echo "SSH key(s) found in ~/.ssh/"
    echo "Generating a NEW key will revoke access to remote repo until updated."
    echo
    echo "1. KEEP existing key"
    echo "2. DELETE and generate new key"
    read -rp "Choice [1 or 2]: " ANSWER

    if [[ "$ANSWER" == "2" ]]; then
        rm -f $EXISTING_KEYS
        USE_EXISTING_KEY=false
    else
        USE_EXISTING_KEY=true
    fi
else
    USE_EXISTING_KEY=false
fi

# key copy or generate
if [[ "$USE_EXISTING_KEY" != true ]]; then
    echo
    echo "Optional: provide private key path (ENTER = auto-generate new key)"
    read -rp "> " KEY_SRC

    if [[ -n "$KEY_SRC" && -f "$KEY_SRC" ]]; then
        cp "$KEY_SRC" "$KEY_PATH"
        chmod 600 "$KEY_PATH"
        chown "$SYSTEM_USER":"$SYSTEM_USER" "$KEY_PATH"
    else
        sudo -u "$SYSTEM_USER" ssh-keygen -t ed25519 -C "$KEY_NAME" -f "$KEY_PATH" -N "" >/dev/null
    fi
fi

# trust github
ssh-keyscan -t rsa github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null
chmod 644 "${SSH_DIR}/known_hosts"
chown "$SYSTEM_USER":"$SYSTEM_USER" "${SSH_DIR}/known_hosts"

echo
echo "----- ADD THIS SSH KEY TO GITHUB → REPO → DEPLOY KEYS -----"

if [[ -f "${KEY_PATH}.pub" ]]; then
    cat "${KEY_PATH}.pub"
else
    # try to detect existing .pub key instead of failing
    EXISTING_PUB=$(find "$SSH_DIR" -maxdepth 1 -type f -name "*.pub" | head -n 1 || true)
    if [[ -n "$EXISTING_PUB" ]]; then
        cat "$EXISTING_PUB"
    else
        echo "(no public key found – you must manually copy key to ~/.ssh)"
    fi
fi

echo "------------------------------------------------------------"
echo



###############################################################################
# REPO INITIALIZATION (local only)
###############################################################################
[[ ! -d "$BARE_REPO" ]] && sudo -u "$SYSTEM_USER" git init --bare "$BARE_REPO"

if [[ ! -d "${WORK_REPO}/.git" ]]; then
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" init

    # set git identity so commits don't error out
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" config user.name "AllWaysUp Automation"
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" config user.email "no-reply@allwaysup.local"

    sudo -u "$SYSTEM_USER" bash -c "echo '# allwaysup repo' > ${ROOT}/README.md"
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" add README.md
    sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" commit -m 'initial commit'
fi


# force HTTP → SSH conversion
if [[ "$REPO_URL" =~ ^https://github.com/(.+)/(.+)$ ]]; then
    REPO_URL="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
fi


# connect remotes
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote remove origin 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote remove localpush 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote add origin "$REPO_URL"
sudo -u "$SYSTEM_USER" git -C "$WORK_REPO" remote add localpush "$BARE_REPO"

sudo -u "$SYSTEM_USER" git -C "$BARE_REPO" remote remove upstream 2>/dev/null || true
sudo -u "$SYSTEM_USER" git -C "$BARE_REPO" remote add upstream "$REPO_URL"



###############################################################################
# SCRIPT: allwaysup_local_sync.sh
# PURPOSE: rsync filesystem into bare repo (mirror local data → gitrepo)
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
[ -f "$LOGFILE" ] && gzip -f "$LOGFILE"
ls -1t sync_to_repo.log* | tail -n +26 | xargs -r rm -f

echo "[$DATESTAMP] Starting rsync..." >> "$LOGFILE"

rsync -av --delete \
    --exclude='.ssh/' \
    --exclude='.git/' \
    --exclude='*.log' \
    --exclude='node_modules/' \
    "$SOURCE" "$TARGET" >> "$LOGFILE" 2>&1

echo "[$DATESTAMP] Sync complete" >> "$LOGFILE"
EOF



###############################################################################
# SCRIPT: git_auto_push.sh
# PURPOSE: commits + pushes ONLY IF there are staged changes
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
    echo "[$DATESTAMP] No changes to push." >> "$LOGFILE"
    exit 0
fi

git commit -m "Automated sync: $DATESTAMP" >> "$LOGFILE" 2>&1
git push --all origin >> "$LOGFILE" 2>&1
EOF



###############################################################################
# SCRIPT: initialize_repo.sh
# PURPOSE: ONLY pulls from GitHub if bare repo has no commits
###############################################################################
cat > "$INIT_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SYSTEM_USER="$SYSTEM_USER"
ROOT="$ROOT"
BARE="${BARE_REPO}"
WORK="$WORK_REPO"
export SYSTEM_USER ROOT BARE WORK

echo "Checking if bare repo has data..."

if ! sudo -u "$SYSTEM_USER" git -C "$BARE" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Bare repo is empty."
    echo "Pull from GitHub?"
    echo " 1. Yes"
    echo " 2. No"
    read -rp "> " ANSWER

    [[ "\$ANSWER" != "1" ]] && exit 0

    sudo -u "$SYSTEM_USER" git -C "$BARE" fetch upstream --all || {
        echo "Unable to reach GitHub. Ensure SSH key added to repo."
        exit 1
    }

    sudo -u "$SYSTEM_USER" git -C "$WORK" pull --ff-only origin || {
        echo "Pull not safe. Manual intervention required."
        exit 1
    }

    /home/allwaysup/install/establish_localrepo_sync_and_git_push_cron.sh
    exit 0
fi

/home/allwaysup/install/establish_localrepo_sync_and_git_push_cron.sh
EOF



###############################################################################
# SCRIPT: establish_localrepo_sync_and_git_push_cron.sh
# PURPOSE: sets cron AFTER repo exists
###############################################################################
cat > "$CRON_SETUP_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSTEM_USER="allwaysup"

# run rsync + git push as 'allwaysup' without needing 'allwaysup' sudo
CRONLINE='0 * * * * su - allwaysup -c "/home/allwaysup/services/backup/allwaysup_local_sync.sh && /home/allwaysup/services/backup/git_auto_push.sh"'

# ensure we only add once
( crontab -l 2>/dev/null | grep -v "allwaysup_local_sync" ; echo "$CRONLINE" ) | crontab -

EOF



###############################################################################
# PERMISSIONS + KICK OFF INITIAL SCRIPT
###############################################################################
chmod +x "$SYNC_BIN" "$GIT_PUSH_BIN" "$INIT_BIN" "$CRON_SETUP_BIN"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$SYNC_BIN" "$GIT_PUSH_BIN" "$INIT_BIN" "$CRON_SETUP_BIN"

echo
echo "Running first-time repo initializer..."
"$INIT_BIN" || echo "Add SSH key to GitHub and re-run: $INIT_BIN"


###############################################################################
# POST-INSTALL SUMMARY
###############################################################################
echo
echo "========================================================="
echo " ✅ INSTALL COMPLETE"
echo "========================================================="
echo "Add SSH key to GitHub → REPO → Settings → Deploy keys"
echo "Then run:  /home/allwaysup/install/initialize_repo.sh"
echo
echo "Repo paths:"
echo "  Working repo:   /home/allwaysup/"
echo "  Bare repo:      /home/allwaysup/gitrepo/"
echo "  Scripts:        /home/allwaysup/services/backup/"
echo "========================================================="
