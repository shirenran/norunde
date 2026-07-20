# Contributing to Norunde

Thanks for helping improve Norunde.

## Development setup

- macOS 14+
- Xcode 15+ **or** Command Line Tools + macOS SDK

```bash
# CLI build (no full Xcode required)
bash scripts/build-app.sh
swift scripts/smoke-logic.swift
open build/Norunde.app

# Install to ~/Applications
bash scripts/install.sh
```

With full Xcode:

```bash
cd App/Norunde
xcodebuild -project Norunde.xcodeproj -scheme Norunde -destination 'platform=macOS' test
```

## Pull requests

1. Keep changes focused; one concern per PR when possible
2. Match existing Swift style (KISS, small types, Chinese UI strings are OK)
3. Prefer reusing existing services over new parallel paths
4. For process/PATH/package.json behavior, add or extend tests when practical
5. Do not commit personal paths, secrets, `.trellis/`, or local build products

## Reporting bugs

Please include:

- macOS version
- How you built/installed (Xcode / `build-app.sh` / `install.sh`)
- Package manager involved (`pnpm` / `npm` / `yarn` / `bun`)
- Steps to reproduce
- Relevant log lines from the in-app log panel

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
