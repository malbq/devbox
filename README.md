# devbox

One persistent Incus container per project, built from a shared Debian 13 image.
Checkouts, dependencies and agent logins stay inside each container.

## Initialize Incus

With Incus installed and running, grant your user access:
```sh
sudo usermod -aG incus-admin "$USER"
```

Allocate IDs for unprivileged containers:
```sh
sudo usermod --add-subuids 1000000-1999999 --add-subgids 1000000-1999999 root
```

Start Incus now and at boot:
```sh
sudo systemctl enable --now incus.service
```

Log out and back in or activate your new group with:
```sh
newgrp incus-admin
```

Initialize the default [minimal setup](https://linuxcontainers.org/incus/docs/main/howto/initialize/#minimal-setup):

```sh
incus admin init --minimal
incus profile show default
```

If UFW is active, allow DHCP and DNS from containers to the host, and container
traffic routed through the host (bridge `incusbr0` by default; otherwise builds
fail with `Temporary failure resolving`). Containers get no other access to
host services:

```sh
sudo ufw allow in on incusbr0 to any port 67 proto udp    # DHCPv4
sudo ufw allow in on incusbr0 to any port 547 proto udp   # DHCPv6
sudo ufw allow in on incusbr0 to any port 53              # DNS
sudo ufw route allow in on incusbr0
sudo ufw route allow out on incusbr0
```

If you used the broader `sudo ufw allow in on incusbr0` before, remove it with
`sudo ufw delete allow in on incusbr0`. UFW is the only layer that blocks
containers from reaching the host's public IPv6 addresses; the devbox ACL below
covers private ranges only.

To resolve container names (`my-project.incus`) from the host, install a
systemd service (`incus-dns-<bridge>.service`, e.g. `incus-dns-incusbr0.service`).
The setup script discovers the bridge from the local Incus default project's
`default` profile and installs the service:

```sh
sudo ./setup-dns.sh
```

It configures `systemd-resolved` using the bridge's IP and DNS domain (`incus`
by default). Requires `jq` on the host. Rerun if the bridge settings change.

Verify the service and DNS resolver with:

```sh
systemctl status incus-dns-incusbr0.service
resolvectl query my-project.incus
```

## Create the devbox profile

Create the hardened `devbox` profile and network ACL used by builders and
project containers (no sudo; rerun to update them):

```sh
./setup-profile.sh
```

The profile applies:
- **Network ACL `devbox`:** containers reach the internet but not private,
  link-local, CGNAT or ULA ranges: your LAN, router, host addresses, VPNs such
  as Tailscale, Docker networks or other devbox containers. DHCP and DNS from
  the bridge still work. Only the host can connect in (SSH).
- **Spoofing filters:** a container cannot use another MAC, IPv4 or IPv6 address.
- **Isolated ID map** (`security.idmap.isolated`): each container gets its own
  host UID/GID range, so a process escaping one container does not own another
  container's files. The 1,000,000 IDs allocated above fit about 15 containers.
- **Safety caps, not quotas:** each container can use up to 80% of host memory
  and 20,000 processes, so a runaway container or fork bomb leaves the host
  responsive enough to stop it (`incus stop --force my-project`). CPU is not
  capped; the kernel shares it fairly with host processes. Several containers
  at full load together can still exhaust host memory.
- `boot.autostart=false` and `security.protection.delete=true`.

To let one container reach your LAN (e.g. a database on another machine),
remove the ACL from that container only:

```sh
incus config device override my-project eth0 security.acls=
```

## Build the shared image

Run from this repository after creating the profile:

```sh
./build-image.sh
```

The script provisions a fresh temporary container with the `devbox` profile, publishes it as image `dev`, then deletes the builder. Failed builds retain the builder for inspection.

The image includes user `dev` with sudo, Git, SSH, tmux, build tools, Chromium for tests, daily unattended Debian security updates, mise-managed tools (Node LTS, coding agents: codex, claude, opencode, grok, plus herdr, gh, lazygit, uv, jq, ripgrep, fzf, zoxide, eza, bat, fd, starship), and cursor-agent from Cursor's installer (mise's package would shadow Node with its bundled copy) inside each container.

It also ships defaults for `dev`:
- Shell aliases (`ll`, `la`, `ts NAME` attaches or creates a tmux session, `tl` lists sessions) and a Starship prompt.
- Git aliases (`co`, `br`, `ci`, `st`, `can`, `graph`, `plog`) and a gh credential helper that survives `mise prune`.
- Claude Code status line, effort and `CLAUDE.md`. herdr integrations for claude, codex, opencode, cursor and grok.
- Linger for `dev`, so systemd user services run without a login session.

Repeat after editing `setup.sh`; existing project containers keep their state and receive updates independently. Never run `setup.sh` in a working container: it clears machine identity and SSH host keys for image publication.

Builds are not pinned: `setup.sh` installs the latest Debian packages, the latest mise tool versions and runs Cursor's installer script (`curl https://cursor.com/install | bash`). Two builds at different times can differ.

## Create a project container

```sh
incus launch dev my-project --profile default --profile devbox
```

To harden an existing container, add the profile (the first start afterwards
remaps file ownership to the isolated ID range, which can take a while):

```sh
incus stop my-project
incus profile add my-project devbox
incus start my-project
```

## Connect over SSH

Generate unique host keys, start SSH, install your host's public key,
pin the container's host keys in `~/.ssh/known_hosts`, and add a
`~/.ssh/config` entry:

```sh
./setup-ssh.sh my-project --port 8080
```

By default the script replaces `authorized_keys` (initial setup; any keys already in the container are removed), uses `~/.ssh/id_ed25519.pub`, and adds this host entry (`--port 8080` adds the forward; use a different local port per project).

`ssh my-project` connects directly to the container and forwards host port 8080 to its dev server.
Use `my-project` in your editor's SSH connection too, then open `/home/dev/projects/my-project`.
Only the public key is copied. Repeat with a different host alias and local port for each project.

Host keys are read through `incus exec`, not trusted on first connection, and
the entry sets `StrictHostKeyChecking yes`, so a changed key fails the
connection. The entry also sets `IdentitiesOnly yes`, `ForwardAgent no` and
`ForwardX11 no`, so the container cannot use your host's SSH agent or X
display. SSH uses the first value it finds for each option: if an earlier
`Host *` block in `~/.ssh/config` sets `ForwardAgent yes`, it wins. Keep
`Host *` at the end of the file.

`--remote-port` (repeatable) exposes host services inside the container while SSH is connected, e.g. host Chrome DevTools on 9222 and Blender MCP on 9876:

```sh
./setup-ssh.sh my-project --port 8080 --remote-port 9222 --remote-port 9876
```

Remote forwards let anything in the container, including coding agents, reach those host services while SSH is connected. Forward only services you trust the container with.

An existing `Host` entry is left unchanged (host keys are still re-pinned); edit `~/.ssh/config` to add forwards or the options above later.

## Set up the project

Inside the container (`ssh my-project`):

```sh
gh auth login                        # Keeps the image's gh credential helper
cd ~/projects && gh repo clone OWNER/my-project && cd my-project
git config --global user.name 'Your Name'
git config --global user.email you@example.com
claude                               # Log in to each agent you use
codex login
opencode auth login
cursor-agent login
grok login
```

Secrets go in `~/.config/devbox/secrets.env` (`KEY=value` lines, `chmod 600`); new shells export them. Never put them in `.bashrc`.

Install project dependencies and project tools (`mise use` in the checkout for project-pinned versions).

### Cursor worker (optional)

After `cursor-agent login`, run a Cursor "My Machines" worker as a systemd user service, named after the container:

```sh
./setup-cursor-worker.sh my-project                    # Worker dir /home/dev/projects/my-project
./setup-cursor-worker.sh my-project /home/dev/other    # Custom worker dir
```

Logs: `ssh my-project journalctl --user -u cursor-agent-worker -f`.

## Daily use

```sh
incus list
incus stop my-project
incus start my-project
ssh my-project
```

Files and logins persist across stop/start.
Processes must be started again (enabled user services such as the Cursor worker start with the container); containers do not autostart with the host.

## Security model

- Containers are unprivileged Incus containers with isolated ID maps; the host's files and credentials are not mounted.
- User `dev` has passwordless sudo (`NOPASSWD: ALL`) inside the container. Agents and scripts running as `dev` can act as root in the container, but not on the host.
- Containers reach the internet only: no LAN, host services, VPNs or other containers (`devbox` ACL, plus UFW for the host). Spoofing filters stop them from impersonating other addresses.
- Memory and process caps keep a runaway container from freezing the host.
- SSH accepts only key authentication; password and root logins are disabled. Each container generates its own host keys, pinned on the host.
- Debian security updates install daily (`unattended-upgrades`). mise tools update only when you run `mise upgrade` or rebuild the image.
- Logins and secrets (`gh`, agents, `secrets.env`) live inside each container. Anything running in that container can read them.
- Port forwards (`--port`, `--remote-port`) bind to `127.0.0.1` only.

## Delete a container

Deletion protection blocks accidental removal; it does not check Git.
After checking for unpushed commits, local changes, stashes and other data you need:

```sh
incus stop my-project                  # If running
incus config set my-project security.protection.delete=false
incus delete my-project
```

## License

[MIT](LICENSE)
