# Mac Bridge — a development fixture, not a shipped feature

This is an OAuth-authenticated MCP server that exposes three of this Mac's capabilities
(`list_shortcuts`, `run_shortcut`, `ask_on_device`) to any MCP client over loopback.

**It is deliberately excluded from the app bundle** (see `build-app.sh`) and has no UI. Nothing in
`app/Sources` references it.

## Why it is not shipped

It was built to prove an OAuth-authenticated MCP server worked end to end — dynamic client
registration, PKCE, resource indicators, refresh, revocation, and a human consent step that the
resource server asks for but never grants itself. That worked, and the tests here still pin it.

What it did not do was earn its place in the product:

- Mechanician's own agent **already has** `ListShortcuts`, `RunShortcut`, `DiscoverAppActions`,
  `RunCapability`, `SaveCapability` and `RunAppleScript` natively (`agentd/src/agentd.mjs`). Every
  prompt a user might type in Mechanician went through those, never through this server.
- The bridge never registered itself as an MCP server, so it did nothing at all until some *other*
  app connected to it. A user could enable it, see an endpoint, and observe no change anywhere.
- The one capability it had that Mechanician's agent lacked was `ask_on_device` — Apple's on-device
  foundation model. Reaching that through loopback HTTP and OAuth, to run a local binary, is the
  wrong shape. The right fix is a native tool, tracked separately.

## What it is still good for

It is the only OAuth-speaking MCP server we control, which makes it the test target for MCP auth
work on both provider lanes. `test/mac-bridge-*.test.mjs` drives the real process, including that
revoking a client invalidates a token it already holds (200 → 401) rather than merely removing a row.

## Running it

    node agentd/src/mac-bridge/server.mjs --port 7777

Consent requests arrive as NDJSON on stdout and decisions go back on stdin; with no parent answering
them, every request times out as a **denial**. `MAC_BRIDGE_AUTO_APPROVE=1` bypasses the human for
tests only.

`ask_on_device` compiles `on-device.swift` on first use, which needs `swiftc` from the developer
tools. That was a defect when this shipped; it is fine for a fixture that only ever runs from a
working tree.
