#!/usr/bin/env bash
# Configure SSH access to a project container.
# Generates host keys, starts sshd, installs your public key,
# and adds a Host entry to ~/.ssh/config.
#
# Usage:
#   ./setup-ssh.sh CONTAINER [--port HOST_PORT[:CONTAINER_PORT]]
#                  [--remote-port CONTAINER_PORT[:HOST_PORT]]...
#
# Examples:
#   ./setup-ssh.sh my-project
#   ./setup-ssh.sh my-project --port 1100
#   ./setup-ssh.sh my-project --port 1100 --remote-port 9222 --remote-port 9876
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Configure SSH access to a project container.
Generates host keys, starts sshd, installs your public key,
and adds a Host entry to ~/.ssh/config.

Usage:
  ./setup-ssh.sh CONTAINER [--port HOST_PORT[:CONTAINER_PORT]]
                 [--remote-port CONTAINER_PORT[:HOST_PORT]]...

  --port         Forward a host port to the container (LocalForward).
  --remote-port  Forward a container port to the host (RemoteForward). Repeatable.

Examples:
  ./setup-ssh.sh my-project
  ./setup-ssh.sh my-project --port 1100
  ./setup-ssh.sh my-project --port 1100 --remote-port 9222 --remote-port 9876
EOF
  exit "${1:-0}"
}

die() { echo "$*" >&2; exit 1; }

container=""
pubkey="$HOME/.ssh/id_ed25519.pub"
port=""
remote_ports=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --port)
      [[ $# -ge 2 ]] || die 'Missing value for --port.'
      port="$2"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --remote-port)
      [[ $# -ge 2 ]] || die 'Missing value for --remote-port.'
      remote_ports+=("$2"); shift 2 ;;
    --remote-port=*) remote_ports+=("${1#*=}"); shift ;;
    --) shift; break ;;
    -*) die "Unknown option: $1. See --help." ;;
    *)
      [[ -z $container ]] || die 'Only one CONTAINER argument allowed.'
      container="$1"; shift ;;
  esac
done

[[ -n $container ]] || die 'Usage: ./setup-ssh.sh CONTAINER [--port PORT]. See --help.'
[[ $container =~ ^[a-zA-Z][a-zA-Z0-9-]*$ && ${#container} -le 63 && $container != *- ]] \
  || die 'Invalid container name.'

[[ $pubkey == *.pub ]] || die 'Public key must be a .pub file.'
[[ -f $pubkey ]] || die "Public key not found: $pubkey"
ssh-keygen -l -f "$pubkey" >/dev/null || die "Invalid SSH public key: $pubkey"
private_key="${pubkey%.pub}"
identity_file="$private_key"
[[ $identity_file == "$HOME"/* ]] && identity_file="~/.ssh/${identity_file#"$HOME/.ssh/"}"

# Parse PORT or FIRST:SECOND into port_a and port_b.
parse_ports() {
  port_a="${1%%:*}"
  port_b="${1#*:}"
  [[ $port_b == "$1" ]] && port_b="$port_a"
  [[ $port_a =~ ^[0-9]{1,5}$ && $port_b =~ ^[0-9]{1,5}$ ]] \
    || die "$2 must be PORT or $3 (1-65535)."
  (( 10#$port_a >= 1 && 10#$port_a <= 65535 && 10#$port_b >= 1 && 10#$port_b <= 65535 )) \
    || die "$2 must be from 1 to 65535."
}

forwards=()
if [[ -n $port ]]; then
  parse_ports "$port" '--port' 'HOST_PORT:CONTAINER_PORT'
  forwards+=("    LocalForward 127.0.0.1:$port_a 127.0.0.1:$port_b")
fi
for remote_port in "${remote_ports[@]}"; do
  parse_ports "$remote_port" '--remote-port' 'CONTAINER_PORT:HOST_PORT'
  forwards+=("    RemoteForward 127.0.0.1:$port_a 127.0.0.1:$port_b")
done

command -v incus >/dev/null || die 'Install Incus first.'
incus info "$container" >/dev/null || die "Container not found: $container"

incus exec "$container" -- ssh-keygen -A
incus exec "$container" -- systemctl enable --now ssh
incus exec "$container" -- install -d -m 700 -o dev -g dev /home/dev/.ssh

incus file push "$pubkey" "$container/home/dev/.ssh/authorized_keys" --mode=600
incus exec "$container" -- chown dev:dev /home/dev/.ssh/authorized_keys
incus list "$container"

config="$HOME/.ssh/config"
install -d -m 700 "$(dirname "$config")"
touch "$config"
chmod 600 "$config"
if grep -Eq "^Host[[:space:]]+$container([[:space:]]|\$)" "$config"; then
  echo "SSH config already has Host $container in $config; leaving it unchanged." >&2
else
  {
    printf '\nHost %s\n' "$container"
    printf '    HostName %s.incus\n' "$container"
    printf '    User dev\n'
    (( ${#forwards[@]} )) && printf '%s\n' "${forwards[@]}"
  } >> "$config"
  echo "Added Host $container to $config."
fi

echo "SSH ready: ssh $container"
