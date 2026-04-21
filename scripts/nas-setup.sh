#!/usr/bin/env bash
#
# One-time NAS setup. Configures dockerd to set the Docker socket's
# group to `administrators`, so users in that group can talk to the
# socket without sudo — survives Container Manager restarts and
# reboots (unlike a one-off `chown`).
#
# Run from your Mac once:
#   scp -O scripts/nas-setup.sh nas:~/
#   ssh -t nas 'sudo bash ~/nas-setup.sh'
#   ssh nas 'rm ~/nas-setup.sh'    # optional cleanup
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "!! This script needs to run as root. Try: sudo bash $0" >&2
  exit 1
fi

CONF=/var/packages/ContainerManager/etc/dockerd.json

if [ ! -f "$CONF" ]; then
  echo "!! $CONF not found. Is Container Manager installed?" >&2
  exit 1
fi

echo "→ current dockerd.json:"
cat "$CONF" || true
echo

echo "→ merging in 'group': 'administrators'"
python3 - "$CONF" <<'PY'
import json, sys, os
path = sys.argv[1]
with open(path) as fp:
    data = json.load(fp)
data["group"] = "administrators"
with open(path, "w") as fp:
    json.dump(data, fp, indent=2)
    fp.write("\n")
PY

echo "→ new dockerd.json:"
cat "$CONF"
echo

echo "→ restarting Container Manager (Docker daemon goes with it)"
synopkg restart ContainerManager

echo -n "→ waiting for docker socket to come back"
for _ in $(seq 1 30); do
  if [ -S /var/run/docker.sock ]; then
    echo "."
    break
  fi
  echo -n "."
  sleep 1
done
echo

echo "→ socket owner/perms:"
ls -la /var/run/docker.sock

if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  echo
  echo "✓ Done. Users in the administrators group can now use docker without sudo."
  echo "  Current user groups:"
  id
else
  echo "!! docker info failed as root — something went wrong with the restart." >&2
  exit 1
fi
