#!/usr/bin/env bash
# Run as root only inside a fresh Debian image builder, never on the host.
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run inside the builder as root.' >&2; exit 1; }
[[ $(systemd-detect-virt --container) == lxc ]] || { echo 'Expected an Incus/LXC container.' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git openssh-client openssh-server sudo \
  build-essential pkg-config unzip zip xz-utils \
  less nano procps iproute2 locales tmux chromium fonts-liberation

# Official mise apt repository, isolated signing key.
install -d -m 755 /etc/apt/keyrings
curl --fail --silent --show-error --location --retry 3 \
  https://mise.jdx.dev/gpg-key.pub -o /etc/apt/keyrings/mise.asc
echo 'deb [signed-by=/etc/apt/keyrings/mise.asc] https://mise.jdx.dev/deb stable main' > /etc/apt/sources.list.d/mise.list
apt-get update
apt-get install -y mise

id dev >/dev/null 2>&1 || useradd --create-home --shell /bin/bash dev
echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev
chmod 440 /etc/sudoers.d/dev
visudo -cf /etc/sudoers.d/dev
# Start dev's systemd user manager at boot, so user services survive logout.
install -d /var/lib/systemd/linger
touch /var/lib/systemd/linger/dev
cat > /etc/profile.d/devbox.sh <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
EOF
install -d -o dev -g dev /home/dev/projects /home/dev/.config
# Per-container secrets (KEY=value lines), never part of the image.
install -d -m 700 -o dev -g dev /home/dev/.config/devbox
if ! grep -q '# devbox' /home/dev/.bashrc; then
  cat >> /home/dev/.bashrc <<'EOF'

# devbox
eval "$(mise activate bash)"
eval "$(starship init bash)"
if [ -f "$HOME/.config/devbox/secrets.env" ]; then
  set -a
  . "$HOME/.config/devbox/secrets.env"
  set +a
fi
EOF
fi
# Sourced by Debian's default .bashrc.
cat > /home/dev/.bash_aliases <<'EOF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'
alias ts='tmux new -A -s'
alias tl='tmux ls'
EOF
# gh helper uses the mise shim: gh auth setup-git would pin a versioned path that mise prune deletes.
cat > /home/dev/.gitconfig <<'EOF'
[alias]
	co = checkout
	br = branch
	ci = commit
	st = status
	can = commit --amend --no-edit
	graph = log --graph --pretty=format:'%Cred%h%Creset | %Cgreen%as%Creset | %Cblue%<(10,trunc)%an%Creset | %s %C(yellow)%d'
	plog = log --pretty=format:'%Cred%h%Creset | %Cgreen%as%Creset | %Cblue%<(10,trunc)%an%Creset | %s %C(yellow)%d'
[credential "https://github.com"]
	helper =
	helper = !/home/dev/.local/share/mise/shims/gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !/home/dev/.local/share/mise/shims/gh auth git-credential
EOF
# Starship prompt based on host config.
cat > /home/dev/.config/starship.toml <<'EOF'
add_newline = true
command_timeout = 200
format = "[$directory$git_branch$git_status]($style)$character"

[character]
error_symbol = "[❯](bold red)"
success_symbol = "[❯](bold white)"

[directory]
truncation_length = 2
truncation_symbol = "…/"
style = "bold blue"
repo_root_style = "bold blue"
repo_root_format = "[$repo_root]($repo_root_style)[$path]($style)[$read_only]($read_only_style) "

[git_branch]
format = "[$branch]($style) "
style = "italic blue dimmed"

[git_status]
format     = '[$all_status]($style)'
style      = "blue"
ahead      = "⇡${count} "
diverged   = "⇕⇡${ahead_count}⇣${behind_count} "
behind     = "⇣${count} "
conflicted = " "
up_to_date = " "
untracked  = "? "
modified   = " "
stashed    = ""
staged     = ""
renamed    = ""
deleted    = ""
EOF
install -d /home/dev/.config/herdr
echo 'onboarding = false' > /home/dev/.config/herdr/config.toml
# Claude Code defaults; herdr merges its hooks into settings.json below.
install -d /home/dev/.claude
cat > /home/dev/.claude/settings.json <<'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  },
  "modelSettings": {
    "claude-opus-5-5": {
      "effortLevel": "high"
    }
  }
}
EOF
cat > /home/dev/.claude/statusline-command.sh <<'EOF'
#!/bin/bash
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
cwd="${cwd/#$HOME/\~}"
model=$(echo "$input" | jq -r '.model.display_name')
effort=$(echo "$input" | jq -r '.effort.level // empty')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
fh=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
wk=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

out="$cwd · $model"
[ -n "$effort" ] && out="$out · $effort"
[ -n "$ctx" ] && out="$out · ctx $(printf '%.0f' "$ctx")%"
[ -n "$fh" ] && out="$out · 5h $(printf '%.0f' "$fh")%"
[ -n "$wk" ] && out="$out · wk $(printf '%.0f' "$wk")%"
printf '%s' "$out"
EOF
cat > /home/dev/.claude/CLAUDE.md <<'EOF'
Write and change files with the Write and Edit tools, not with Bash (no heredocs, `sed -i`, `echo >`, or scripts that write files).
EOF
chown -R dev:dev /home/dev

su - dev -c 'mise use --global node@lts codex claude github:anomalyco/opencode grok gh jq ripgrep fzf zoxide eza bat fd starship lazygit herdr uv'
# Official installer, not mise: mise's cursor-agent exposes its bundled node, which shadows mise's node.
su - dev -c 'curl --fail --silent --show-error --location --retry 3 https://cursor.com/install | bash'
su - dev -c 'node --version && npm --version && codex --version && claude --version && opencode --version && grok --version && cursor-agent --version && gh --version && jq --version && rg --version && fzf --version && zoxide --version && eza --version && bat --version && fd --version && starship --version && lazygit --version && herdr --version && uv --version && uvx --version'
su - dev -c '[[ $(mise which node) == "$HOME/.local/share/mise/installs/node/"* ]]' \
  || { echo 'node does not resolve to the mise-installed Node.' >&2; exit 1; }
# herdr needs each agent config directory; grok creates its own only on first run.
su - dev -c 'install -d ~/.grok && for agent in claude codex opencode cursor grok; do herdr integration install "$agent"; done && herdr integration status'
tmux -V
chromium --version

# Enable SSH after creating a container and generating unique host keys.
install -d /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-devbox.conf
systemctl disable --now ssh.service
rm -f /etc/ssh/ssh_host_*
apt-get clean
rm -rf /var/lib/apt/lists/*
# New containers must generate their own machine identity on first boot.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
