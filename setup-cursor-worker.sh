#!/usr/bin/env bash
# Run a Cursor "My Machines" worker as a systemd user service in a project container.
# Log in first inside the container with: cursor-agent login
#
# Usage:
#   ./setup-cursor-worker.sh CONTAINER [WORKER_DIR]
#
# Examples:
#   ./setup-cursor-worker.sh my-project
#   ./setup-cursor-worker.sh my-project /home/dev/my-project
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Run a Cursor "My Machines" worker as a systemd user service in a project container.
Log in first inside the container with: cursor-agent login

Usage:
  ./setup-cursor-worker.sh CONTAINER [WORKER_DIR]

WORKER_DIR defaults to /home/dev/projects/CONTAINER. The worker is named CONTAINER.

Examples:
  ./setup-cursor-worker.sh my-project
  ./setup-cursor-worker.sh my-project /home/dev/my-project
EOF
  exit "${1:-0}"
}

die() { echo "$*" >&2; exit 1; }

[[ ${1:-} == -h || ${1:-} == --help ]] && usage 0
[[ $# -ge 1 && $# -le 2 ]] || usage 1
container="$1"
worker_dir="${2:-/home/dev/projects/$container}"
[[ $container =~ ^[a-zA-Z][a-zA-Z0-9-]*$ && ${#container} -le 63 && $container != *- ]] \
  || die 'Invalid container name.'
[[ $worker_dir =~ ^/[a-zA-Z0-9/._-]+$ ]] || die 'WORKER_DIR must be an absolute path without spaces.'

command -v incus >/dev/null || die 'Install Incus first.'
incus info "$container" >/dev/null || die "Container not found: $container"
incus exec "$container" -- test -d "$worker_dir" || die "Directory not found in $container: $worker_dir"
incus exec "$container" -- test -f /home/dev/.config/cursor/auth.json \
  || die "Not logged in. Run inside $container: cursor-agent login"

unit=cursor-agent-worker.service
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
cat > "$temp_dir/$unit" <<EOF
[Unit]
Description=Cursor My Machines worker
Documentation=https://cursor.com/docs/cloud-agent/self-hosted/my-machines
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$worker_dir
# Login tokens live in ~/.config/cursor/auth.json (access + refresh).
# AGENT_CLI_CREDENTIAL_STORE=file keeps that store, not a keyring.
# Do not use --auth-token-file here: that file is a 1-hour JWT and does not refresh.
Environment=HOME=/home/dev
Environment=AGENT_CLI_CREDENTIAL_STORE=file
Environment=PATH=/home/dev/.local/bin:/home/dev/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/dev/.local/bin/cursor-agent worker \\
  --name $container \\
  --worker-dir $worker_dir \\
  --data-dir /home/dev/.local/share/cursor-agent-worker \\
  --idle-release-timeout 0 \\
  --wait 60 \\
  start
Restart=always
RestartSec=5
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF

# Linger keeps the user manager, and so the worker, running without a login session.
incus exec "$container" -- loginctl enable-linger dev
incus exec "$container" -- systemctl start "user@$(incus exec "$container" -- id -u dev).service"
incus exec "$container" -- install -d -o dev -g dev /home/dev/.config/systemd /home/dev/.config/systemd/user
incus file push "$temp_dir/$unit" "$container/home/dev/.config/systemd/user/$unit" --mode=644
incus exec "$container" -- chown dev:dev "/home/dev/.config/systemd/user/$unit"
incus exec "$container" -- systemctl --user -M dev@ daemon-reload
incus exec "$container" -- systemctl --user -M dev@ enable --now "$unit"
incus exec "$container" -- systemctl --user -M dev@ --no-pager status "$unit"
