#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
builder="devbox-build-$(date +%s)-$$"

incus profile show devbox >/dev/null 2>&1 \
  || { echo 'Profile devbox not found. Run ./setup-profile.sh first.' >&2; exit 1; }
# Builders run third-party installers, so they get the same hardened profile.
incus launch images:debian/13 "$builder" --profile default --profile devbox \
  -c security.protection.delete=false
trap 'echo "Build did not finish. Builder retained for inspection: $builder" >&2' ERR
incus exec "$builder" -- bash -s < "$script_dir/setup.sh"
incus stop "$builder"
incus publish "$builder" --alias dev --reuse
incus delete "$builder"
trap - ERR

echo 'Image ready: dev'
