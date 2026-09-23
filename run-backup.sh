#!/bin/bash

# Configure Git inside container
git config --global user.email "backup@coolify.local"
git config --global user.name "Coolify Backup"
git config --global --add safe.directory /app/data

REPO_URL="https://${GITHUB_TOKEN}@github.com/potatoeezs/st-backup.git"

mkdir -p data
rm -rf temp_data

# Clone backup if not already present
if git clone "$REPO_URL" temp_data; then
    rm -f temp_data/run-backup.sh temp_data/start.sh
    cp -rn temp_data/. data/ 2>/dev/null || true
    rm -rf temp_data
fi

# Ensure data has git remote initialized
cd data || exit 1
if [ ! -d ".git" ]; then
    git init -b main
    git remote add origin "$REPO_URL"
fi
git remote set-url origin "$REPO_URL"
cd ..

save_data() {
    (
        cd data || exit
        git add -A
        if [ -n "$(git status --porcelain)" ]; then
            git commit -m "Auto backup: $(date -u +%F_%T_UTC)"
            git push origin main --force
        fi
    )
}

trap 'save_data; kill -TERM $ST_PID 2>/dev/null; exit 0' SIGTERM SIGINT

# Start SillyTavern in the background
node server.js &
ST_PID=$!

# Background loop pushing changes every 3 minutes
(
    while kill -0 "$ST_PID" 2>/dev/null; do
        sleep 180
        save_data
    done
) &

wait "$ST_PID"
