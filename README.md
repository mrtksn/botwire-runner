# Botwire Runner

The open-source Linux runner for [Botwire](https://botwire.app) — connect any Linux server to your Botwire account and deploy, execute, and serve your projects headlessly.

```
iOS/macOS App ──BREP/relay──► Botwire Runner (your Linux server)
                               │
                               ├── Stores deployments persistently
                               ├── Executes JavaScript via JavaScriptCore
                               ├── Serves HTTP routes via relay proxy
                               └── Runs agentic workflows with LLM integration
```

## Quick Install

```bash
# On your Linux server (Ubuntu 22.04 / 24.04)
curl -fsSL https://raw.githubusercontent.com/mrtksn/botwire-runner/main/scripts/setup-server.sh | sudo bash
```

This installs system dependencies, creates the `botwire` user, sets up cgroup v2 for resource isolation, and installs the systemd service template.

## Pairing Your Server

1. **Get a pairing token** from the Botwire iOS app:
   Settings → Paired Devices → Pair Linux Server

2. **Claim the token** on your server:
   ```bash
   botwire-runner pair \
     --relay https://algo.botwire.app \
     --token bw_pair_<YOUR_TOKEN> \
     --name "My Linux Server" \
     --config /etc/botwire-runner/my-runner/config.json
   ```

3. **Start the runner**:
   ```bash
   # As a systemd service (persistent across reboots)
   sudo systemctl enable --now botwire-runner@my-runner

   # Or run directly
   botwire-runner cloud --config /etc/botwire-runner/my-runner/config.json
   ```

Your server appears in the Botwire app as a deploy target within seconds.

## Building from Source

### Requirements

| Requirement | Version |
|-------------|---------|
| Swift | 5.10+ (6.x recommended) |
| OS | Ubuntu 22.04+, Debian 12+, or macOS 14+ (for development) |
| JavaScriptCore GTK | `libjavascriptcoregtk-4.1-dev` (Linux only) |

### Build

```bash
# Install dependencies (Linux)
sudo apt-get install -y libjavascriptcoregtk-4.1-dev

# Clone and build
git clone https://github.com/mrtksn/botwire-runner.git
cd botwire-runner
swift build -c release

# Install the binary
sudo cp .build/release/botwire-runner /usr/local/bin/botwire-runner
```

### macOS (for development)

```bash
swift build    # JavaScriptCore.framework is built-in
swift test
```

## Commands

```bash
botwire-runner help                    # Show all commands

# Server pairing
botwire-runner pair --token bw_pair_...  # Pair with a Botwire account
botwire-runner cloud --config ...        # Run as a persistent cloud worker

# Development & testing
botwire-runner status                    # Check relay connectivity
botwire-runner run --project P.json      # Execute a project locally
botwire-runner serve --project P.json    # Serve a project via HTTP
botwire-runner inspect --project P.json  # Print project details

# Configuration
botwire-runner init-config               # Generate a default config file
botwire-runner sample-project            # Generate a sample project
```

## Architecture

The runner implements the **BREP** (Botwire Runtime Exchange Protocol) — the same protocol used by the iOS and macOS apps:

| Endpoint | Purpose |
|----------|---------|
| `GET /brep/v1/hello` | Identity handshake |
| `POST /brep/v1/receive/startup` | Receive a full project deployment |
| `POST /brep/v1/receive/algorithm` | Receive a single algorithm |
| `POST /brep/v1/return/startup` | Recall — serialize state, return snapshot, delete local |
| `POST /brep/v1/execute/codeblock` | Execute a code block on demand |

The runner connects to the Botwire relay via WebSocket tunnel. All traffic is end-to-end between your devices — the relay routes but does not inspect payloads.

### Internal Modules

| Module | Purpose |
|--------|---------|
| `BotwireCore` | Project models, config, bundle loading |
| `BotwireRelay` | Relay HTTP client, WebSocket tunnel client |
| `BotwireRuntime` | JavaScript execution (JavaScriptCore), host bridge |
| `BotwirePersistence` | OxiDB embedded database, settings sync |
| `BotwireShared` | Protocol types, bus contracts, agent scripts |
| `BotwireTransferCore` | Snapshot serialization for deployment round-trips |

## Browser Automation (Optional)

The runner includes a built-in headless Chrome/Chromium controller via the Chrome DevTools Protocol (CDP). This powers the `browser.*` and `page.*` APIs in your Botwire projects — navigate pages, click elements, fill forms, take screenshots, evaluate JavaScript, etc.

**Requires Chromium or Google Chrome** installed on the server:

```bash
# Ubuntu/Debian
sudo apt-get install -y chromium-browser

# Or Google Chrome
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
sudo apt-get update && sudo apt-get install -y google-chrome-stable
```

If no Chrome binary is found, the runner still works — all other features (JS execution, HTTP routes, database, deploys) function normally. Only `browser.*` API calls will return an error.

**Security**: Each project gets its own isolated Chrome process with a unique user-data-dir and random debug port. Processes are cleaned up after execution.

## systemd Service

The setup script installs a parameterized systemd unit `botwire-runner@.service`:

```bash
# Start a runner instance
sudo systemctl start botwire-runner@my-runner

# Enable auto-start on boot
sudo systemctl enable botwire-runner@my-runner

# View logs
journalctl -u botwire-runner@my-runner -f
```

Each instance reads its config from `/etc/botwire-runner/<instance>/config.json`.

## Server Setup Guide

For detailed instructions on preparing a server (SSH keys, cgroups, firewall, etc.), see [docs/SERVER_SETUP.md](docs/SERVER_SETUP.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and contribution guidelines.

## License

MIT — see [LICENSE](LICENSE).
