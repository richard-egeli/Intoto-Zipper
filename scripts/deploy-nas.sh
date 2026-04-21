#!/usr/bin/env bash
#
# One-shot deploy helper — runs from your Mac. SSHs to the NAS alias
# `nas`, writes /volume1/docker/synology_zipper/.env with a freshly
# generated SECRET_KEY_BASE, ships the compose file, then pulls the
# latest image from ghcr.io and restarts the container.
#
# Drive service-account credentials are uploaded at runtime through
# the app's /settings page — no files on disk, no env vars, no
# bind-mounts for secrets.
#
# Usage:  bash scripts/deploy-nas.sh
#
# Prereqs:
#   - SSH alias `nas` resolves and key-based auth works (see README /
#     ssh-copy-id instructions).
#   - Your NAS user can reach the Docker socket (member of the group
#     owning /var/run/docker.sock; on DSM, this typically means the
#     docker group or administrators).
#
set -euo pipefail

NAS=${NAS_HOST:-nas}
REMOTE_DIR=/volume1/docker/synology_zipper

PHX_HOST=${PHX_HOST:-192.168.1.46}
IMAGE=${SYNZ_IMAGE:-ghcr.io/richard-egeli/synology_zipper:latest}

echo "→ Ensuring NAS project directory + data dir exist"
ssh "$NAS" "mkdir -p $REMOTE_DIR/data"

echo "→ Syncing docker-compose.yml to $NAS"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
scp -O "$REPO_ROOT/docker-compose.yml" "$NAS:$REMOTE_DIR/docker-compose.yml"

echo "→ Generating SECRET_KEY_BASE locally"
SECRET=$(openssl rand -base64 48)

echo "→ Writing $REMOTE_DIR/.env on $NAS"
ssh "$NAS" "cat > $REMOTE_DIR/.env" <<EOF
SECRET_KEY_BASE=$SECRET
PHX_HOST=$PHX_HOST
HOST_PORT=4000
SYNZ_IMAGE=$IMAGE
DATA_DIR=$REMOTE_DIR/data
EOF

echo "→ Locking down .env perms + sanity check"
ssh "$NAS" "chmod 600 $REMOTE_DIR/.env && awk -F= '{if (\$1==\"SECRET_KEY_BASE\") printf \"%s=<%d chars>\\n\", \$1, length(\$2); else print}' $REMOTE_DIR/.env"

echo "→ Restarting container via compose"
ssh "$NAS" "cd $REMOTE_DIR && docker compose down && docker compose pull && docker compose up -d --wait"

echo "→ Container status"
ssh "$NAS" "cd $REMOTE_DIR && docker compose ps"

echo
echo "✓ Done. Next steps:"
echo "  1. Browse http://$PHX_HOST:4000/"
echo "  2. Go to Settings → upload your Google service-account JSON key"
echo "  3. Add a source on the Overview page and turn on auto-upload"
