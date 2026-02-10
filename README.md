# TahoeProxy

TahoeProxy is a macOS proxy controller built with SwiftUI and Swift Concurrency. It provides a local SOCKS5 + HTTP CONNECT proxy core, system proxy management (manual + PAC), subscription parsing, and diagnostics tooling.

## Requirements
- macOS 13+
- Xcode 15 / Swift 5.9+

## Build & Run
1. Open `Package.swift` in Xcode.
2. Select the **TahoeProxy** executable target.
3. Run.

## Entitlements
This app targets the macOS App Sandbox and requires:
- `com.apple.security.app-sandbox = true`
- `com.apple.security.network.client = true`
- `com.apple.security.network.server = true`
- Keychain access if you store credentials

Add the entitlements in Xcode when exporting an app bundle.

## Features
- One-click system proxy enable/disable (manual or PAC)
- Local SOCKS5 server (CONNECT) + HTTP CONNECT proxy
- Subscription import (URL or pasted text)
- PAC rule editor for DIRECT / PROXY
- Diagnostics export (settings, proxy snapshot, logs)

## Known Limitations
- Does not provide per-app proxying (system-wide only)
- No HTTPS MITM, no root certificates
- UDP ASSOCIATE is stubbed for future expansion

## Next Steps
- NetworkExtension (NEAppProxyProvider) integration for per-app routing
- UDP relay support
- Advanced rules and per-group routing
