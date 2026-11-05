#!/usr/bin/env bash
# Run on the Incus host as root.
set -euo pipefail

[[ $(id -u) -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
systemctl is-active --quiet systemd-resolved

command -v jq >/dev/null || { echo 'Install jq on the host first.' >&2; exit 1; }
bridge=$(incus --force-local query '/1.0/profiles/default?project=default' | jq -er '
  [.devices[] | select(.type == "nic") |
    (.network // (if .nictype == "bridged" then .parent else empty end))]
  | unique
  | if length == 1 then .[0]
    else error("Default profile must reference exactly one network") end
')
[[ $bridge =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid bridge name.' >&2; exit 1; }
network=$(incus --force-local query "/1.0/networks/$bridge?project=default")
jq -e '.managed == true and .type == "bridge"' <<< "$network" >/dev/null || {
  echo "Default profile network $bridge is not a managed bridge." >&2; exit 1;
}
address=$(jq -r '.config["ipv4.address"] // empty' <<< "$network")
address=${address%/*}
domain=$(jq -r '.config["dns.domain"] // empty' <<< "$network")
domain=${domain:-incus}
mode=$(jq -r '.config["dns.mode"] // empty' <<< "$network")
mode=${mode:-managed}

[[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Bridge needs an IPv4 address.' >&2; exit 1; }
[[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo 'Invalid bridge DNS domain.' >&2; exit 1; }
[[ $mode == managed || $mode == dynamic ]] || { echo 'Bridge DNS must use managed or dynamic mode.' >&2; exit 1; }

unit="incus-dns-$bridge.service"
device_unit=$(systemd-escape --path --suffix=device "/sys/subsystem/net/devices/$bridge")
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
cat > "$temp_dir/$unit" <<EOF
[Unit]
Description=Incus bridge DNS for $bridge
BindsTo=$device_unit
After=$device_unit

[Service]
Type=oneshot
ExecStart=/usr/bin/resolvectl dns $bridge $address
ExecStart=/usr/bin/resolvectl domain $bridge ~$domain
ExecStart=/usr/bin/resolvectl dnssec $bridge off
ExecStart=/usr/bin/resolvectl dnsovertls $bridge off
ExecStopPost=/usr/bin/resolvectl revert $bridge
RemainAfterExit=yes

[Install]
WantedBy=$device_unit
EOF

systemd-analyze verify "$temp_dir/$unit"
install -m 644 "$temp_dir/$unit" "/etc/systemd/system/$unit"
systemctl daemon-reload
systemctl enable "$unit"
systemctl restart "$unit"
systemctl is-active "$unit"
resolvectl status "$bridge"
