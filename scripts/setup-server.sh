#!/usr/bin/env bash
# =============================================================================
# Botwire Linux Runner — Server Setup Script
# =============================================================================
# Run this on a fresh Ubuntu 22.04 / 24.04 server as root to prepare it for
# hosting Botwire Linux runners.
#
# Usage:
#   curl -fsSL https://your-cdn/setup-runner-server.sh | bash
#   # or after copying to the server:
#   bash setup-runner-server.sh [--admin-pubkey "ssh-ed25519 AAAA..."]
#
# What it does:
#   1. Installs system dependencies (JavaScriptCore GTK, curl, etc.)
#   2. Creates the botwire-runner system user
#   3. Creates workspace directories with correct permissions
#   4. Downloads or symlinks the botwire-runner binary
#   5. Installs the botwire-runner systemd service template
#   6. Authorizes the Botwire admin server's SSH key
#   7. Enables cgroup v2 if needed
#   8. Prints next steps
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
RUNNER_USER="botwire"
RUNNER_HOME="/var/lib/botwire-runner"
WORKSPACE_BASE="/var/lib/botwire-runner/workspaces"
CONFIG_DIR="/etc/botwire-runner"
LOG_DIR="/var/log"
BINARY_PATH="/usr/local/bin/botwire-runner"
SERVICE_NAME="botwire-runner@"

# Admin server SSH public key (passed as argument or set here)
ADMIN_PUBKEY="${1:-}"
for arg in "$@"; do
  case "$arg" in
    --admin-pubkey=*) ADMIN_PUBKEY="${arg#*=}" ;;
    --admin-pubkey)   shift; ADMIN_PUBKEY="${1:-}" ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "✅ $*"; }
warn()  { echo "⚠️  $*"; }
fatal() { echo "❌ $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fatal "Must run as root."

OS=$(. /etc/os-release && echo "$ID")
VERSION=$(. /etc/os-release && echo "$VERSION_ID")
info "Detected OS: $OS $VERSION"

# ── 1. System Dependencies ────────────────────────────────────────────────────
info "Installing system dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
  libjavascriptcoregtk-4.1-0 \
  libjavascriptcoregtk-4.1-dev \
  curl \
  ca-certificates \
  openssh-server \
  cgroup-tools \
  systemd

info "Dependencies installed."

# ── 1b. Optional: Headless Chromium (for browser automation API) ──────────────
info "Checking for Chromium (optional, needed for browser automation)..."
if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null || command -v google-chrome &>/dev/null; then
  CHROME_BIN=$(command -v chromium-browser || command -v chromium || command -v google-chrome)
  info "Chromium found: $CHROME_BIN"
else
  warn "No Chromium/Chrome binary found."
  warn "Browser automation features (page.goto, page.click, screenshots, etc.) will not work."
  warn "To install: apt-get install -y chromium-browser"
  read -r -p "Install chromium-browser now? [y/N] " INSTALL_CHROME
  if [[ "$INSTALL_CHROME" =~ ^[Yy] ]]; then
    apt-get install -y --no-install-recommends chromium-browser
    info "Chromium installed."
  else
    info "Skipping Chromium. You can install it later with: apt-get install chromium-browser"
  fi
fi

# ── 2. Create botwire system user ─────────────────────────────────────────────
if ! id -u "$RUNNER_USER" &>/dev/null; then
  useradd --system --no-create-home --shell /bin/false "$RUNNER_USER"
  info "Created system user: $RUNNER_USER"
else
  info "System user $RUNNER_USER already exists."
fi

# ── 3. Create directories ─────────────────────────────────────────────────────
info "Creating workspace directories..."
mkdir -p "$RUNNER_HOME" "$WORKSPACE_BASE" "$CONFIG_DIR"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
chmod 750 "$RUNNER_HOME" "$WORKSPACE_BASE" "$CONFIG_DIR"
info "Directories: $RUNNER_HOME, $WORKSPACE_BASE, $CONFIG_DIR"

# ── 4. Install botwire-runner binary ─────────────────────────────────────────
if [[ ! -f "$BINARY_PATH" ]]; then
  warn "botwire-runner binary not found at $BINARY_PATH."
  warn "The admin server will copy it via SCP during provisioning."
  warn "Or copy it manually: scp botwire-runner root@<this-server>:$BINARY_PATH"
else
  chmod +x "$BINARY_PATH"
  info "Binary already at $BINARY_PATH: $("$BINARY_PATH" --version 2>/dev/null || echo 'version unknown')"
fi

# ── 5. Install systemd service template ───────────────────────────────────────
info "Installing systemd service template..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << 'SERVICE'
[Unit]
Description=Botwire Linux Runner (%i)
After=network.target
Wants=network.target

[Service]
Type=simple
User=botwire
Group=botwire
ExecStart=/usr/local/bin/botwire-runner cloud --config /etc/botwire-runner/%i/config.json
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/botwire-runner-%i.log
StandardError=append:/var/log/botwire-runner-%i.log
Environment=HOME=/var/lib/botwire-runner

# Cgroup v2 resource limits are applied by the admin server dynamically.
# The service runs inside the botwire.slice to allow per-instance cgroup control.
Slice=botwire.slice

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
info "Installed systemd service template: ${SERVICE_NAME}.service"
info "Start a specific runner instance with: systemctl start botwire-runner@<runnerID>"

# ── 6. Cgroup v2 setup ────────────────────────────────────────────────────────
info "Checking cgroup v2..."
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  info "cgroup v2 is active."
  # Create botwire slice and enable cpu + memory controllers
  mkdir -p /sys/fs/cgroup/botwire
  echo "+cpu +memory" > /sys/fs/cgroup/botwire/cgroup.subtree_control 2>/dev/null || warn "Could not set subtree_control (may need reboot)"
else
  warn "cgroup v2 not detected. Add 'systemd.unified_cgroup_hierarchy=1' to kernel cmdline and reboot."
  warn "On Ubuntu: edit /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT and run update-grub"
fi

# ── 7. SSH key authorization ──────────────────────────────────────────────────
info "Configuring SSH authorized keys..."
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if [[ -n "$ADMIN_PUBKEY" ]]; then
  if grep -qF "$ADMIN_PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    info "Admin SSH key already authorized."
  else
    echo "$ADMIN_PUBKEY" >> "$AUTH_KEYS"
    info "Admin SSH key added to $AUTH_KEYS"
  fi
else
  warn "No --admin-pubkey provided."
  warn "Add the admin server's public key to $AUTH_KEYS manually:"
  warn "  ssh-copy-id -i /path/to/admin_key.pub root@<this-server>"
  warn "  # or: cat admin_key.pub >> $AUTH_KEYS"
fi

# ── 8. SSH hardening (optional) ───────────────────────────────────────────────
info "Checking SSH config..."
SSHD_CONF="/etc/ssh/sshd_config"
if grep -q "^PasswordAuthentication yes" "$SSHD_CONF" 2>/dev/null; then
  warn "Password authentication is still enabled. Consider disabling it:"
  warn "  sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' $SSHD_CONF && systemctl reload sshd"
fi

# ── 9. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Botwire Runner Server Setup Complete"
echo "============================================================"
echo ""
echo "  System user:   $RUNNER_USER"
echo "  Workspaces:    $WORKSPACE_BASE"
echo "  Config dir:    $CONFIG_DIR"
echo "  Binary:        $BINARY_PATH"
echo "  Service:       ${SERVICE_NAME}<runnerID>"
echo "  Logs:          /var/log/botwire-runner-<runnerID>.log"
echo "  Chromium:      $(command -v chromium-browser || command -v chromium || command -v google-chrome || echo 'NOT INSTALLED (browser automation disabled)')"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Copy the runner binary (if not done):"
echo "     scp botwire-runner root@<this-server>:$BINARY_PATH"
echo "     chmod +x $BINARY_PATH"
echo ""
echo "  2. Add this server in the Botwire admin dashboard:"
echo "     Runners → Runner Servers → + Add Server"
echo "     Address: <this-server-ip>"
echo "     SSH User: root"
echo "     SSH Key Path: /path/to/your/admin_key  (on the admin server)"
echo ""
echo "  3. Click 'Test SSH' in the dashboard to verify connectivity."
echo ""
echo "  4. The admin will automatically provision runners via SSH"
echo "     when users with packages are assigned to this host."
echo ""
echo "  OR — for a user-owned runner (paired via the app):"
echo ""
echo "  A. Get a pairing token from the Botwire iOS app:"
echo "     Settings → Paired Devices → Pair Linux Server"
echo ""
echo "  B. On this server, run:"
echo "     botwire-runner pair \\"
echo "       --relay https://algo.botwire.app \\"
echo "       --token bw_pair_<TOKEN> \\"
echo "       --name 'My Server' \\"
echo "       --config /etc/botwire-runner/my-runner/config.json"
echo ""
echo "  C. Start and enable the runner service:"
echo "     systemctl enable --now botwire-runner@my-runner"
echo ""
echo "============================================================"
