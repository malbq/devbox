# devbox

One persistent, hardened Incus container per project, built from a shared Debian 13 image with coding agents preinstalled. Checkouts, dependencies, agent logins and secrets stay isolated inside each container, away from the host and LAN.

## Requirements

Linux host with Incus. UFW optional (use the rules below if active). `jq` required for the DNS and profile scripts.

## Quick start

1. Grant Incus access, allocate unprivileged ID maps, start Incus, then initialize it (log out/in or `newgrp` after the group change):

```sh
sudo usermod -aG incus-admin "$USER"
sudo usermod --add-subuids 1000000-1999999 --add-subgids 1000000-1999999 root
sudo systemctl enable --now incus.service
newgrp incus-admin
incus admin init --minimal
```

2. If UFW is active, allow DHCP/DNS from the bridge and deny other host services; order matters (`prepend` puts each rule first, so the deny ends up after the allows):

```sh
sudo ufw prepend deny in on incusbr0
sudo ufw prepend allow in on incusbr0 to any port 67 proto udp    # DHCPv4
sudo ufw prepend allow in on incusbr0 to any port 547 proto udp   # DHCPv6
sudo ufw prepend allow in on incusbr0 to any port 53              # DNS
sudo ufw route allow in on incusbr0
sudo ufw route allow out on incusbr0
sudo ufw status numbered
```

3. Resolve container names (`my-project.incus`) from the host:

```sh
sudo ./setup-dns.sh
```

4. Create the hardened `devbox` profile and network ACL:

```sh
./setup-profile.sh
```

5. Build the shared image `dev`:

```sh
./build-image.sh
```

6. Launch a project container:

```sh
incus launch dev my-project --profile default --profile devbox
```

7. Configure SSH (host keys, your public key, pinned known_hosts, `~/.ssh/config`; `--port` forwards a local port):

```sh
./setup-ssh.sh my-project --port 8080
```

8. Inside the container (`ssh my-project`), auth, clone and log in; put secrets in `~/.config/devbox/secrets.env` (`KEY=value`, `chmod 600`):

```sh
gh auth login
cd ~/projects && gh repo clone OWNER/my-project && cd my-project
git config --global user.name 'Your Name'
git config --global user.email you@example.com
claude
codex login
opencode auth login
cursor-agent login
grok login
```

## Optional

**Cursor worker** — after `cursor-agent login`:

```sh
./setup-cursor-worker.sh my-project
# or: ./setup-cursor-worker.sh my-project /home/dev/other
```

**Remote port forwards** — expose host services inside the container while SSH is connected:

```sh
./setup-ssh.sh my-project --port 8080 --remote-port 9222 --remote-port 9876
```

**LAN access** — remove the ACL from one container:

```sh
incus config device override my-project eth0 security.acls=
```

## Daily use

```sh
incus list
incus stop my-project
incus start my-project
ssh my-project
```

Containers do not autostart with the host.

## Security

- Unprivileged containers with isolated ID maps; host files and credentials are not mounted.
- Network ACL: internet only (no LAN, host services, VPNs or other containers); UFW covers host public IPv6.
- User `dev` has passwordless sudo inside the container only, not on the host.
- SSH is key-only; each container has its own host keys, pinned on the host.
- Logins and `secrets.env` live inside each container; anything there can read them.
- Memory (80%) and process (20,000) caps limit runaway containers.

## Delete a container

Check for unpushed work first. Then:

```sh
incus stop my-project
incus config set my-project security.protection.delete=false
incus delete my-project
```

## Image

Debian 13 with user `dev`, Git, SSH, tmux, build tools, Chromium, daily security updates, mise tools (Node LTS, codex, claude, opencode, grok, gh, and common CLI helpers), and cursor-agent.
