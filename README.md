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

## Privacy

**Glack has no backend.** Your data stays on your Mac and in your own Google Workspace account. Nothing routes through Glack infrastructure, because no such infrastructure exists.

Concretely:
- Sign-in is `ASWebAuthenticationSession` → `accounts.google.com` directly. Your credentials never touch Glack.
- Every read and write is an HTTPS call from your Mac straight to `chat.googleapis.com` with your OAuth token. No proxy, no relay, no middleman.
- The local cache lives at `~/Library/Application Support/Glack/glack.db` (SQLite + FTS5 index) on your Mac. Delete that file and Glack forgets everything.
- The OAuth refresh token sits in your Mac's Keychain. It's only ever sent back to Google to mint a new access token.
- No analytics, telemetry, or crash reporting endpoint exists in this codebase.

The eventual MCP server (`glack-mcp`) runs locally and talks to Claude Desktop over stdio on the same machine. If you then ask Claude to summarize your Chat, Claude sees the messages it summarizes — that's a property of using an LLM as a client, not of Glack.

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
