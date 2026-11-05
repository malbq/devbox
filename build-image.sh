#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
builder="devbox-build-$(date +%s)-$$"

incus launch images:debian/13 "$builder" -c boot.autostart=false
trap 'echo "Build did not finish. Builder retained for inspection: $builder" >&2' ERR
incus exec "$builder" -- bash -s < "$script_dir/setup.sh"
incus stop "$builder"
incus publish "$builder" --alias dev --reuse
incus delete "$builder"
trap - ERR

echo 'Image ready: dev'
