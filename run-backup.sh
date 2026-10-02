#!/bin/bash

# ---- Paths derived from the real working directory (no hardcoded /app) ----
BASE_DIR="$(pwd)"
DATA_DIR="$BASE_DIR/data"

log() { echo "[backup $(date -u +%F_%T_UTC)] $*"; }

# ---- Git identity & safety ----
git config --global user.email "backup@coolify.local"
git config --global user.name "Coolify Backup"
git config --global --add safe.directory "$DATA_DIR"

REPO_URL="https://${GITHUB_TOKEN}@github.com/potatoeezs/st-backup.git"

# ---- Tunables ----
DISK_THRESHOLD=70      # % usage on the data filesystem that triggers LFS prune
INTERVAL=180           # seconds between cycles
PRUNE_COOLDOWN=900     # seconds; minimum gap between LFS prunes (0 = every cycle)

mkdir -p "$DATA_DIR"
rm -rf temp_data

# Clone backup if not already present
if git clone "$REPO_URL" temp_data; then
    rm -f temp_data/run-backup.sh temp_data/start.sh
    cp -rn temp_data/. "$DATA_DIR"/ 2>/dev/null || true
    rm -rf temp_data
else
    log "WARN: clone failed (network / token / repo?). Continuing with existing local data."
fi

# Ensure data has git remote initialized
cd "$DATA_DIR" || exit 1
if [ ! -d ".git" ]; then
    git init -b main
    git remote add origin "$REPO_URL"
fi
git remote set-url origin "$REPO_URL"
cd "$BASE_DIR" || exit 1

# ---- Helpers ----
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Portable disk-usage read (wrapped df lines can't break the parse)
disk_pct() {
    df -P "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%'
}

# ---- Step 1: LFS prune (runs BEFORE backup, per spec) ----
LAST_PRUNE_FILE="$BASE_DIR/.last_lfs_prune"

prune_lfs() {
    local now last age
    now=$(date +%s)
    last=0
    [ -f "$LAST_PRUNE_FILE" ] && last=$(cat "$LAST_PRUNE_FILE" 2>/dev/null || echo 0)

    if [ "$PRUNE_COOLDOWN" -gt 0 ]; then
        age=$(( now - last ))
        if [ "$age" -lt "$PRUNE_COOLDOWN" ]; then
            log "LFS prune skipped (last run ${age}s ago, cooldown ${PRUNE_COOLDOWN}s)."
            return 0
        fi
    fi

    (
        cd "$DATA_DIR" || exit 1
        # --verify-remote deletes only objects confirmed present on the remote,
        # so pruning before push cannot lose data.
        if git lfs prune --verify-remote; then
            log "LFS prune completed."
            echo "$now" > "$LAST_PRUNE_FILE"
        else
            log "WARN: LFS prune failed (not an LFS repo? network?). Continuing."
        fi
    )
}

# ---- Step 2: backup + push (logic unchanged) ----
save_data() {
    (
        cd "$DATA_DIR" || exit 1

        if ! git add -A; then
            log "ERROR: git add failed (disk full?). Skipping this cycle."
            return 1
        fi

        if [ -z "$(git status --porcelain)" ]; then
            return 0
        fi

        # Safety: never overwrite a good remote with an empty data tree
        if [ -z "$(find "$DATA_DIR" -maxdepth 3 \( -name 'settings.json' -o -name 'config.yaml' \) -print -quit 2>/dev/null)" ]; then
            log "WARN: no SillyTavern user data found. Refusing to push to avoid wiping the remote."
            return 1
        fi

        if ! git commit -m "Auto backup: $(date -u +%F_%T_UTC)"; then
            log "ERROR: commit failed. Skipping this cycle."
            return 1
        fi

        if git push origin main --force; then
            log "Backup pushed. Data filesystem at $(disk_pct)%."
        else
            log "ERROR: git push failed (disk full / auth / network?)."
            return 1
        fi
    )
}

# ---- Main cycle ----
cycle() {
    local usage
    usage=$(disk_pct)
    log "Cycle start. Disk usage: ${usage:-unknown}%."

    if is_num "$usage" && [ "$usage" -ge "$DISK_THRESHOLD" ]; then
        log "Disk at ${usage}% (>= ${DISK_THRESHOLD}%). Pruning LFS before backup."
        prune_lfs
    else
        log "Disk at ${usage:-?}% (< ${DISK_THRESHOLD}%). No prune needed."
    fi

    save_data
}

trap 'save_data; kill -TERM $ST_PID 2>/dev/null; exit 0' SIGTERM SIGINT

# Start SillyTavern in the background
node server.js &
ST_PID=$!

# Background loop: disk check -> prune -> backup -> push, every 3 minutes
(
    while kill -0 "$ST_PID" 2>/dev/null; do
        sleep "$INTERVAL"
        cycle
    done
) &

wait "$ST_PID"

# Final save if ST exits on its own
save_data
