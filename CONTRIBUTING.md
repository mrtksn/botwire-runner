# Contributing to Botwire Runner

Thanks for your interest in contributing to the Botwire Runner!

## Development Setup

### macOS (recommended for development)

```bash
git clone https://github.com/mrtksn/botwire-runner.git
cd botwire-runner
swift build
swift test
```

JavaScriptCore is built-in on macOS, so no additional dependencies are needed.

### Linux

```bash
sudo apt-get install -y libjavascriptcoregtk-4.1-dev
git clone https://github.com/mrtksn/botwire-runner.git
cd botwire-runner
swift build
```

## Project Structure

```
Sources/
├── botwire-runner/         CLI entry point and cloud worker logic
├── BotwireCore/            Project models, config, bundle loading
├── BotwireRelay/           Relay HTTP + WebSocket tunnel client
├── BotwireRuntime/         JS execution engine (JavaScriptCore)
├── BotwirePersistence/     OxiDB embedded storage, settings sync
├── BotwireShared/          Protocol types, bus contracts, agent scripts
├── BotwireTransferCore/    Snapshot serialization
└── CJavaScriptCoreGTK/     System library bridge (Linux only)
```

## How to Contribute

1. **Fork** the repo and create a feature branch
2. **Make your changes** with clear commit messages
3. **Test** on both macOS and Linux if possible
4. **Open a PR** describing what you changed and why

## Reporting Issues

Open an issue on GitHub with:
- What you expected to happen
- What actually happened
- Your OS and Swift version (`swift --version`)
- Relevant log output

## Code Style

- Follow the existing Swift style in the codebase
- Use `async/await` for asynchronous code
- Keep functions focused and document non-obvious behavior

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
