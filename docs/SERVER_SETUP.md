# Linux Runner Server Setup Guide

Last updated: 2026-05-22

This guide covers two scenarios:

1. **Admin-managed server** — a server the Botwire admin provisions and manages via SSH. The admin dashboard controls runner lifecycle. Users don't touch the server.
2. **User-owned server** — a personal Linux machine or VPS that a user pairs directly to their Botwire account from the iOS app.

Both result in a runner appearing as a relay-connected device in the user's Botwire app. The difference is who provisions the config and manages the process lifecycle.

---

## Requirements

| Requirement | Value |
|-------------|-------|
| OS | Ubuntu 22.04 LTS or 24.04 LTS (amd64) |
| RAM | 512 MB minimum, 1–2 GB recommended per runner |
| CPU | 1 vCPU minimum |
| Disk | 2 GB minimum per runner workspace |
| Network | Outbound HTTPS to `algo.botwire.app` (port 443) |
| SSH | Port 22 open for admin access (admin-managed only) |

---

## Quick Setup (Both Scenarios)

Run on the target server as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mrtksn/Botwire/main/scripts/setup-runner-server.sh) \
  --admin-pubkey "ssh-ed25519 AAAA... admin@botwire"
```

Or copy and run the script from the repo:

```bash
scp scripts/setup-runner-server.sh root@<server>:/tmp/
ssh root@<server> "bash /tmp/setup-runner-server.sh --admin-pubkey 'ssh-ed25519 AAAA...'"
```

The script:
- Installs `libjavascriptcoregtk-4.1` (the JavaScript runtime)
- Creates the `botwire` system user
- Creates workspace directories (`/var/lib/botwire-runner/`)
- Installs the `botwire-runner@.service` systemd unit template
- Enables cgroup v2 for resource enforcement
- Adds the admin server's SSH public key to `authorized_keys`

---

## Part 1 — Admin-Managed Server

### What This Means

The admin server (`algo.botwire.app`) SSHes into this server to:
- Copy the `botwire-runner` binary (via SCP)
- Write per-user `config.json` files
- Start/stop runner processes
- Apply cgroup CPU/memory limits
- Read process logs

No human needs to log in to the runner server after setup.

### Step 1 — Generate an SSH Key on the Admin Server

On the **admin server** (`root@<admin-server-ip>`):

```bash
# Generate a dedicated key for runner host access
ssh-keygen -t ed25519 -f /root/.ssh/botwire_runner -C "botwire-admin@algo.botwire.app" -N ""

# Print the public key — you'll need this for the runner server
cat /root/.ssh/botwire_runner.pub
```

> ⚠️ This key lives only on the admin server. Never copy the **private** key anywhere else.

### Step 2 — Authorize the Key on the Runner Server

On the **runner server**:

```bash
# Either pass it to the setup script:
bash setup-runner-server.sh --admin-pubkey "ssh-ed25519 AAAA... botwire-admin@algo.botwire.app"

# Or add it manually after setup:
echo "ssh-ed25519 AAAA... botwire-admin@algo.botwire.app" >> /root/.ssh/authorized_keys
```

### Step 3 — Copy the Runner Binary

The admin server SCP-copies the binary during provisioning, but you can also do it manually:

```bash
# On your Mac (after building):
scp /path/to/.build/release/botwire-runner root@<runner-server>:/usr/local/bin/botwire-runner

# Or copy from the existing admin/dev server:
ssh root@<admin-server-ip> "cat /usr/local/bin/botwire-runner" | ssh root@<runner-server> "cat > /usr/local/bin/botwire-runner && chmod +x /usr/local/bin/botwire-runner"
```

### Step 4 — Add the Server in the Admin Dashboard

1. Go to **Runners → Runner Servers → + Add Server**
2. Fill in:
   - **Server Address**: the IP or hostname (`167.99.199.35`)
   - **Display Name**: anything descriptive (`Frankfurt Runner 1`)
   - **SSH User**: `root` (or whatever user you authorized the key for)
   - **SSH Port**: `22`
   - **SSH Key Path**: `/root/.ssh/botwire_runner` ← path **on the admin server**
   - **Capacity**: max simultaneous runners (`-1` = unlimited)
3. Click **Save Server**, then **Test SSH** to verify the connection

If Test SSH shows ✓ OK, the admin can now provision runners on this host automatically when users are assigned packages.

### Step 5 — Verify

```bash
# From the admin server, test SSH connectivity:
ssh -i /root/.ssh/botwire_runner -o BatchMode=yes root@<runner-server> "echo botwire-host-ok"
# → botwire-host-ok

# Check the runner binary is available:
ssh -i /root/.ssh/botwire_runner root@<runner-server> "/usr/local/bin/botwire-runner status"
```

### How Runner Provisioning Works

When the admin provisions a runner for a user on this host, it:

1. Creates `/etc/botwire-runner/<runnerID>/` directory via SSH
2. Writes `config.json` with relay credentials (`relayAuthToken`, `sessionToken`, `shareableID`)
3. Starts `botwire-runner cloud --config /etc/botwire-runner/<runnerID>/config.json` via SSH (or `systemctl start botwire-runner@<runnerID>`)
4. The runner connects to `wss://algo.botwire.app/tunnel` and authenticates
5. The relay sends `devices_updated` to the user's iOS app
6. The runner appears in the app as a deploy target

---

## Part 2 — User-Owned Server (Self-Hosted Runner)

This is for a user who has their own VPS or home server and wants to connect it to their Botwire account without admin involvement.

### Step 1 — Run the Setup Script

On your server:

```bash
# As root — installs dependencies and sets up the system user
bash <(curl -fsSL https://raw.githubusercontent.com/mrtksn/Botwire/main/scripts/setup-runner-server.sh)
```

### Step 2 — Install the Runner Binary

Download the latest pre-built binary (when available from releases), or build from source:

```bash
# Option A — copy from the admin/dev server (if you have access):
scp root@<admin-server-ip>:/usr/local/bin/botwire-runner /usr/local/bin/botwire-runner
chmod +x /usr/local/bin/botwire-runner

# Option B — build from source on the server (~8–10 min, requires Swift 6.3+):
apt-get install -y swift  # or install from swift.org
git clone https://github.com/mrtksn/Botwire.git
cd Botwire/LinuxRunner
swift build -c release
cp .build/release/botwire-runner /usr/local/bin/botwire-runner
```

### Step 3 — Get a Pairing Token from the iOS App

1. Open the **Botwire** iOS app
2. Go to **Settings → Paired Devices → Pair Linux Server**
3. The app generates a one-time token and shows a command like:

```bash
botwire-runner pair \
  --relay https://algo.botwire.app \
  --token bw_pair_abc123...
```

The token is **valid for 15 minutes** and can only be used once.

### Step 4 — Claim the Token on Your Server

```bash
# Create a config directory for this runner instance
mkdir -p /etc/botwire-runner/my-runner

# Claim the token — this writes all credentials to config.json
botwire-runner pair \
  --relay https://algo.botwire.app \
  --token bw_pair_abc123... \
  --name "My Home Server" \
  --workspace /var/lib/botwire-runner/workspaces/my-runner \
  --config /etc/botwire-runner/my-runner/config.json

# → Output:
# Paired runner: My Home Server
#   runnerID:    linux-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   shareableID: some-word-1234
#   relay:       https://algo.botwire.app
#   config:      /etc/botwire-runner/my-runner/config.json
```

### Step 5 — Start as a Persistent Service

```bash
# Enable and start the systemd service
systemctl enable --now botwire-runner@my-runner

# Check it's running
systemctl status botwire-runner@my-runner

# Watch logs
journalctl -u botwire-runner@my-runner -f
# or: tail -f /var/log/botwire-runner-my-runner.log
```

The runner connects to the relay and appears in your Botwire app immediately. If the server reboots, systemd restarts the runner automatically.

### Step 6 — Verify in the App

The Botwire iOS app should now show the runner under **Settings → Paired Devices** and as a deploy target when sending projects. If it doesn't appear within 30 seconds, check the logs.

---

## Troubleshooting

### "botwire-host-ok" test fails from admin dashboard

```bash
# On the admin server, test manually:
ssh -i /root/.ssh/botwire_runner -o BatchMode=yes root@<runner-server> "printf botwire-host-ok"

# Common causes:
# - Wrong key path in admin dashboard (path is on the ADMIN server, not the runner)
# - Key not in authorized_keys on the runner server
# - SSH is blocked by firewall (check: nc -zv <runner-server> 22)
# - Wrong SSH user (default is root; change if you used a different user)
```

### Runner connects but app doesn't see it

```bash
# Check the relay sees it:
curl -s https://algo.botwire.app/api/v1/status
# connectedDevices should increase

# Check the runner log for auth errors:
tail -20 /var/log/botwire-runner-my-runner.log
# "auth_error: Invalid or expired session token" → session token expired
#   Fix: run botwire-runner pair again with a new token from the app

# "auth_error: Invalid device credentials" → relay DB doesn't have the device
#   This can happen if the relay was wiped. Re-pair from the app.
```

### Session token expired (runner was offline >30 days)

```bash
# Get a fresh pairing token from the app, re-pair:
botwire-runner pair \
  --relay https://algo.botwire.app \
  --token bw_pair_NEW_TOKEN \
  --config /etc/botwire-runner/my-runner/config.json

# Restart the service:
systemctl restart botwire-runner@my-runner
```

### Cgroup limits not applied

```bash
# Check cgroup v2 is active:
cat /sys/fs/cgroup/cgroup.controllers
# Should list: cpuset cpu io memory hugetlb pids rdma misc

# If missing, enable in grub:
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
update-grub
reboot
```

---

## Directory Reference

| Path | Purpose |
|------|---------|
| `/usr/local/bin/botwire-runner` | Runner binary |
| `/etc/botwire-runner/<id>/config.json` | Per-runner config (credentials, workspace path) |
| `/var/lib/botwire-runner/workspaces/<id>/` | Runner workspace (deployed projects, OxiDB) |
| `/var/log/botwire-runner-<id>.log` | Runner logs |
| `/etc/systemd/system/botwire-runner@.service` | Systemd unit template |
| `/sys/fs/cgroup/botwire/<id>/` | Cgroup v2 resource enforcement |

## Config File Reference (`config.json`)

The `botwire-runner pair` command writes this automatically. Fields:

```json
{
  "runnerID": "linux-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "runnerName": "My Home Server",
  "shareableID": "some-word-1234",
  "relayBaseURL": "https://algo.botwire.app",
  "tunnelURL": "wss://algo.botwire.app/tunnel",
  "relayAuthToken": "relay_...",
  "sessionToken": "eyJ...",
  "workspacePath": "/var/lib/botwire-runner/workspaces/my-runner"
}
```

> ⚠️ `sessionToken` is a JWT that expires in **30 days**. If the runner is offline when it expires, re-pair from the app to get a fresh token.
