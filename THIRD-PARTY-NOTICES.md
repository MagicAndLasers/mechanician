# Third-Party Notices

Mechanician is distributed under the MIT License. Release bundles contain the components below,
which remain subject to their own terms. The top-level license inventory, the npm lockfile, the
agent daemon's production SBOM, and the SwiftPM resolution file are included in
`Mechanician.app/Contents/Resources/Licenses/`.

## Native application

- **SwiftTerm 1.13.0**: MIT License. https://github.com/migueldeicaza/SwiftTerm
- **Sparkle 2.9.4**: MIT License, with additional permissively licensed components included by
  Sparkle. https://github.com/sparkle-project/Sparkle
- **DM Serif Display Regular**: Copyright 2014–2018 Adobe and 2019 Google LLC; SIL Open Font
  License 1.1. https://github.com/google/fonts/tree/main/ofl/dmserifdisplay
- **Mermaid 11.17.0**: MIT License. The `dist/mermaid.min.js` browser build, vendored unmodified at
  `app/Resources/mermaid.min.js`. It lays Mermaid artifacts out in a throwaway offscreen web view;
  the diagram is frozen to SVG before display, so this code never runs in a preview a person is
  looking at. https://github.com/mermaid-js/mermaid

`app/Package.resolved` also pins `swift-argument-parser`. It reaches the graph through a SwiftTerm
executable target (`Termcast`) that Mechanician does not depend on, and it is not present in the
app bundle.

## Bundled runtime and agent daemon

- **Node.js 24.18.0**: Node.js license and the third-party notices incorporated into that license.
  https://nodejs.org/
- **npm 11.16.0**: Artistic License 2.0 and the dependency notices incorporated into npm's
  license file. Bundled from the same pinned Node.js distribution.
  https://github.com/npm/cli
- **@anthropic-ai/claude-agent-sdk 0.3.257** and its Darwin arm64 engine: © Anthropic PBC;
  all rights reserved. Use is subject to Anthropic's applicable legal agreements.
  https://code.claude.com/docs/en/legal-and-compliance
- **@openai/codex 0.148.0 (OpenAI Codex CLI / App Server)**: Copyright 2025 OpenAI; Apache
  License 2.0.
  The bundled distribution includes code derived from Ratatui under the MIT License; see the
  packaged OpenAI Codex NOTICE file. https://github.com/openai/codex
- **@modelcontextprotocol/sdk 1.30.0**: MIT License. Used for MCP OAuth client flows and error
  types. https://github.com/modelcontextprotocol/typescript-sdk
- **diff 9.0.0**: BSD 3-Clause License. https://github.com/kpdecker/jsdiff
- **isomorphic-git 1.38.7**: MIT License. https://github.com/isomorphic-git/isomorphic-git
- **node-pty 1.1.0**: MIT License. https://github.com/microsoft/node-pty
- **zod 4.4.3**: MIT License. https://github.com/colinhacks/zod

`express` 5.2.1 (MIT) is present in the bundled `node_modules` as a transitive dependency of
`@modelcontextprotocol/sdk`, but nothing in a release bundle loads it. The only agentd source that
imports it is the `mac-bridge` development fixture, and `build-app.sh` deletes
`Contents/Resources/agentd/src/mac-bridge` from the bundle.

The production npm tree is installed from `agentd/package-lock.json`. License files supplied by
transitive npm packages remain alongside those packages in the bundled `node_modules` directory.
Four transitive packages do not include a license file in their published tarball:
`clean-git-ref 2.0.1` declares Apache-2.0, while `diff3 0.0.3`, `minimisted 2.0.1`, and
`standardwebhooks 1.0.0` declare MIT. The exact `standardwebhooks` library license from its
[published source revision](https://github.com/standard-webhooks/standard-webhooks/blob/929bf0c1928b188287eaf88d0a9f0a4e87df6499/libraries/LICENSE)
is therefore included in the top-level license inventory. The other three published source
revisions do not provide an exact license text to reproduce there; their license declarations
remain recorded in the npm lockfile and agentd SBOM.

The primary list above calls out every direct npm dependency, the proprietary runtimes, and the
SwiftPM packages the app links; it does not relicense any third-party software.
