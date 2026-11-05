#!/usr/bin/env bash
# Create or update the devbox Incus profile and network ACL.
# Run on the Incus host as a member of incus-admin (no sudo). Rerun to update.
#
# The profile hardens project containers and image builders:
# - ACL: no traffic to private, link-local, CGNAT or ULA networks (LAN, host,
#   VPNs, other containers); internet allowed. Only the host may connect in.
# - NIC: MAC, IPv4 and IPv6 spoofing filters.
# - Isolated ID map: each container gets its own host UID/GID range.
# - Memory and process caps, so a runaway container cannot freeze the host.
set -euo pipefail

profile=devbox
acl=devbox

die() { echo "$*" >&2; exit 1; }

command -v incus >/dev/null || die 'Install Incus first.'
command -v jq >/dev/null || die 'Install jq on the host first.'

bridge=$(incus --force-local query '/1.0/profiles/default?project=default' | jq -er '
  [.devices[] | select(.type == "nic") |
    (.network // (if .nictype == "bridged" then .parent else empty end))]
  | unique
  | if length == 1 then .[0]
    else error("Default profile must reference exactly one network") end
')
[[ $bridge =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'Invalid bridge name.'
network=$(incus --force-local query "/1.0/networks/$bridge?project=default")
jq -e '.managed == true and .type == "bridge"' <<< "$network" >/dev/null \
  || die "Default profile network $bridge is not a managed bridge."

# The host reaches containers from the bridge addresses.
host_ips=$(jq -r '
  [.config["ipv4.address"], .config["ipv6.address"]]
  | map(select(. != null and . != "" and . != "none") | sub("/.*"; ""))
  | join(",")
' <<< "$network")
[[ -n $host_ips ]] || die "Bridge $bridge has no IP address."

acl_yaml=$(cat <<EOF
description: 'devbox: internet only, no private networks; only the host connects in'
egress:
- action: reject
  description: Private, link-local, CGNAT and ULA networks (LAN, host, VPNs, containers)
  destination: 10.0.0.0/8,100.64.0.0/10,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,fc00::/7,fe80::/10
  state: enabled
- action: allow
  description: Internet
  state: enabled
ingress:
- action: allow
  description: Host (SSH and port forwards)
  source: $host_ips
  state: enabled
EOF
)

profile_yaml=$(cat <<EOF
description: 'devbox: hardened project container'
config:
  boot.autostart: "false"
  security.protection.delete: "true"
  security.idmap.isolated: "true"
  limits.memory: 80%
  limits.processes: "20000"
devices:
  eth0:
    name: eth0
    network: $bridge
    type: nic
    security.acls: $acl
    security.mac_filtering: "true"
    security.ipv4_filtering: "true"
    security.ipv6_filtering: "true"
EOF
)

incus network acl show "$acl" >/dev/null 2>&1 || incus network acl create "$acl"
incus network acl edit "$acl" <<< "$acl_yaml"
incus profile show "$profile" >/dev/null 2>&1 || incus profile create "$profile"
incus profile edit "$profile" <<< "$profile_yaml"

echo "Profile ready: $profile (ACL $acl on $bridge)."
