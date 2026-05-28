# Glack

A native macOS app for Google Chat with Slack-style UX.

## The why

Google Chat's web app makes basic actions painful:
- Channel switching is slow
- Cmd-K barely works
- Search is unreliable
- No native Mac feel (menus, hotkeys, system integration)

Glack is a from-scratch native client that talks to the Google Chat REST API directly (no webview wrapper) and presents a Slack-style UI: fast channel/DM switching, working Cmd-K, real search, native menus, global hotkeys.

## Stack

- **Swift + SwiftUI + AppKit bridges**, min macOS 14 (Sonoma)
- **Google Chat REST API v1** for spaces, messages, threads, send/edit/delete
- **OAuth 2.0** via `ASWebAuthenticationSession` + PKCE; refresh token in **Keychain**
- **SQLite** via [GRDB.swift](https://github.com/groue/GRDB.swift) with FTS5 for local full-history search
- Eventually a sibling `glack-mcp` binary so Claude / other agents can read and act on Chat via [MCP](https://modelcontextprotocol.io)

The Chat REST API has no remote full-text search, so Glack owns the index end-to-end: a rate-limited background worker pulls history into the local DB and FTS5 powers a Slack-parity search overlay.

## Status

Very early. Scaffolding (Phase 0).

## Build

The project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen        # one-time
xcodegen generate            # regenerates Glack.xcodeproj
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Glack -configuration Debug build
```

`Glack.xcodeproj` is gitignored — edit `project.yml` instead, regenerate to apply.

## License

MIT. See LICENSE.
