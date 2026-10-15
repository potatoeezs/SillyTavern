
#!/bin/bash

set -o pipefail

# ---- Paths ----
BASE_DIR="$(pwd)"
DATA_DIR="$BASE_DIR/data"
TEMP_DIR="$BASE_DIR/temp_data"

log() {
    echo "[backup $(date -u +%F_%T_UTC)] $*"
}

# ---- Git identity ----
git config --global user.email "backup@coolify.local"
git config --global user.name "Coolify Backup"

# ---- GitHub authentication ----
if [ -z "$GITHUB_TOKEN" ]; then
    log "ERROR: GITHUB_TOKEN is missing. Cannot restore backup."
    exit 1
fi

REPO_URL="https://github.com/potatoeezs/st-backup.git"

AUTH_HEADER=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w 0)

if ! git config --global \
    http.https://github.com/.extraheader \
    "AUTHORIZATION: basic $AUTH_HEADER"; then
    log "ERROR: Could not configure GitHub authentication."
    exit 1
fi

unset AUTH_HEADER

# ---- Tunables ----
DISK_THRESHOLD=70
INTERVAL=180
PRUNE_COOLDOWN=900

# ---- Prepare directories ----
mkdir -p "$DATA_DIR"
rm -rf "$TEMP_DIR"

# ---- Restore backup ----
log "Cloning backup repository..."

if git clone --depth 1 --single-branch --branch main "$REPO_URL" "$TEMP_DIR"; then
    log "Backup repository cloned successfully."

    # Remove startup scripts from restored data
    rm -f "$TEMP_DIR/run-backup.sh" "$TEMP_DIR/start.sh"

    # Restore files without overwriting existing local files
    if ! cp -rn "$TEMP_DIR"/. "$DATA_DIR"/; then
        log "WARN: Some backup files could not be copied."
    fi

    rm -rf "$TEMP_DIR"
else
    log "ERROR: Backup clone failed."
    log "Check token permissions, repository access, and network."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# ---- Initialize Git in data directory ----
cd "$DATA_DIR" || exit 1

if [ ! -d ".git" ]; then
    git init -b main || exit 1
fi

git config --global --add safe.directory "$DATA_DIR"
git remote set-url origin "$REPO_URL" 2>/dev/null ||
    git remote add origin "$REPO_URL"

cd "$BASE_DIR" || exit 1

# ---- Helpers ----
is_num() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

disk_pct() {
    df -P "$DATA_DIR" 2>/dev/null |
        awk 'NR==2 {print $5}' |
        tr -d '%'
}

# ---- LFS pruning ----
LAST_PRUNE_FILE="$BASE_DIR/.last_lfs_prune"

prune_lfs() {
    local now last age

    now=$(date +%s)
    last=0

    if [ -f "$LAST_PRUNE_FILE" ]; then
        last=$(cat "$LAST_PRUNE_FILE" 2>/dev/null || echo 0)
        is_num "$last" || last=0
    fi

    if [ "$PRUNE_COOLDOWN" -gt 0 ]; then
        age=$((now - last))

        if [ "$age" -lt "$PRUNE_COOLDOWN" ]; then
            log "LFS prune skipped; cooldown has not elapsed."
            return 0
        fi
    fi

    (
        cd "$DATA_DIR" || exit 1

        if git lfs prune --verify-remote; then
            log "LFS prune completed."
            echo "$now" > "$LAST_PRUNE_FILE"
        else
            log "WARN: LFS prune failed; continuing."
        fi
    )
}

# ---- Convert extension repositories to regular tracked files ----
convert_extension_gitlinks() {
    local extensions_dir="$DATA_DIR/default-user/extensions"
    local ext_dir rel mode tracked hold

    [ -d "$extensions_dir" ] || return 0

    # Only inspect direct extension folders, not nested repositories.
    while IFS= read -r -d '' ext_dir; do
        [ -e "$ext_dir/.git" ] || continue

        rel="${ext_dir#"$DATA_DIR"/}"

        mode=$(git ls-files --stage -- "$rel" |
            awk 'NR==1 {print $1}')

        tracked=$(git ls-files -- "$rel" | head -n 1)

        # Convert existing gitlinks or newly installed extensions.
        if [ "$mode" = "160000" ] || [ -z "$tracked" ]; then
            log "Converting extension to regular files: $rel"

            # Remove only the gitlink from the parent index.
            if [ "$mode" = "160000" ]; then
                if ! git rm --cached -f -- "$rel"; then
                    log "ERROR: Could not remove extension gitlink: $rel"
                    return 1
                fi
            fi

            # Temporarily hide nested Git metadata so Git stages files,
            # rather than treating the extension as another repository.
            hold="$BASE_DIR/.extension-git-hold-$$"

            if [ -e "$hold" ]; then
                log "ERROR: Temporary metadata path already exists: $hold"
                return 1
            fi

            if ! mv "$ext_dir/.git" "$hold"; then
                log "ERROR: Could not temporarily move extension Git metadata: $rel"
                return 1
            fi

            if git add -A -- "$rel"; then
                if ! mv "$hold" "$ext_dir/.git"; then
                    log "ERROR: Could not restore extension Git metadata: $rel"
                    log "Metadata remains at: $hold"
                    return 1
                fi

                log "Extension files staged successfully: $rel"
            else
                mv "$hold" "$ext_dir/.git" || true
                log "ERROR: Could not stage extension files: $rel"
                return 1
            fi
        fi
    done < <(
        find "$extensions_dir" \
            -mindepth 1 -maxdepth 1 -type d -print0
    )

    return 0
}

# ---- Backup and push ----
save_data() {
    (
        cd "$DATA_DIR" || exit 1

        # Convert extension gitlinks before staging all data.
        if ! convert_extension_gitlinks; then
            log "ERROR: Extension conversion failed. Skipping backup."
            return 1
        fi

        if ! git add -A; then
            log "ERROR: git add failed. Skipping backup."
            return 1
        fi

        if [ -z "$(git status --porcelain)" ]; then
            return 0
        fi

        # Never push without recognizable SillyTavern data.
        if [ -z "$(find "$DATA_DIR" -maxdepth 3 \
            \( -name 'settings.json' -o -name 'config.yaml' \) \
            -print -quit 2>/dev/null)" ]; then
            log "WARN: No SillyTavern user data found."
            log "Refusing to push to protect the remote backup."
            return 1
        fi

        if ! git commit -m "Auto backup: $(date -u +%F_%T_UTC)"; then
            log "ERROR: Commit failed. Skipping backup."
            return 1
        fi

        if git push origin main --force; then
            log "Backup pushed. Data filesystem at $(disk_pct)%."
        else
            log "ERROR: Git push failed."
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
        log "Disk threshold reached. Pruning LFS before backup."
        prune_lfs
    else
        log "Disk usage below threshold. No prune needed."
    fi

    save_data
}

# ---- Start SillyTavern ----
node server.js &
ST_PID=$!

# ---- Graceful shutdown ----
shutdown() {
    trap - SIGTERM SIGINT
    log "Shutdown requested. Saving data..."

    save_data

    kill -TERM "$ST_PID" 2>/dev/null || true
    wait "$ST_PID" 2>/dev/null || true

    exit 0
}

trap shutdown SIGTERM SIGINT

# ---- Automatic backup loop ----
(
    while kill -0 "$ST_PID" 2>/dev/null; do
        sleep "$INTERVAL"

        if kill -0 "$ST_PID" 2>/dev/null; then
            cycle
        fi
    done
) &

BACKUP_PID=$!

# Wait for SillyTavern to exit
wait "$ST_PID"
ST_EXIT=$?

# ---- Final backup ----
log "SillyTavern exited with code $ST_EXIT. Running final backup."

save_data

kill "$BACKUP_PID" 2>/dev/null || true

exit "$ST_EXIT"
