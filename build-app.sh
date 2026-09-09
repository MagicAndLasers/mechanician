#!/usr/bin/env bash
# Assemble Mechanician.app: release build + bundled agentd, code-signed.
# Signs with a Developer ID Application identity if one is present (hardened runtime,
# ready for notarization); otherwise ad-hoc signs so the app runs on this machine.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PRODUCT_NAME is the SPM product / Mach-O executable / CFBundleIconFile stem — fixed to match
# Package.swift and every parameterized bundle's CFBundleExecutable. APP_NAME is only the .app bundle
# + DMG display name. Managed enterprise profiles use the standard app and never set these knobs.
# Everything below defaults to the public app's values (FR-103 M0: no change to the public build).
PRODUCT_NAME="Mechanician"
APP_NAME="${MECHANICIAN_APP_NAME:-$PRODUCT_NAME}"
APP="$REPO/build/$APP_NAME.app"
INFO_PLIST="${MECHANICIAN_INFO_PLIST:-$REPO/app/Mechanician-Info.plist}"
APP_ICON="${MECHANICIAN_APP_ICON:-$REPO/app/Resources/Mechanician.icns}"
PRODUCT_DISPLAY_FONT="$REPO/app/Resources/dm-serif-display-latin.woff2"
ENTITLEMENTS="${MECHANICIAN_ENTITLEMENTS:-$REPO/app/Mechanician.entitlements}"
JIT_ENTITLEMENTS_FILE="${MECHANICIAN_JIT_ENTITLEMENTS:-$REPO/app/JITRuntime.entitlements}"
# Optional tenant profile (FR-103): a tenant.json copied into Contents/Resources before signing, so
# its integrity rides on the app signature. Unset for the public build ⇒ TenantProfile.default.
TENANT_PROFILE="${MECHANICIAN_TENANT_PROFILE:-}"
DOGFOOD_BUILD="${MECHANICIAN_DOGFOOD_BUILD:-0}"

case "$DOGFOOD_BUILD" in
  0|1) ;;
  *) echo "!! MECHANICIAN_DOGFOOD_BUILD must be 0 or 1"; exit 1 ;;
esac
if [ "${MECHANICIAN_DISTRIBUTION_BUILD:-0}" = "1" ] && [ "$DOGFOOD_BUILD" = "1" ]; then
  echo "!! a distribution build cannot be stamped as dogfood"
  exit 1
fi

[ -f "$INFO_PLIST" ] || { echo "!! Info.plist not found: $INFO_PLIST"; exit 1; }
[ -f "$APP_ICON" ] || { echo "!! app icon not found: $APP_ICON"; exit 1; }
[ -f "$PRODUCT_DISPLAY_FONT" ] || { echo "!! product display font not found: $PRODUCT_DISPLAY_FONT"; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "!! entitlements not found: $ENTITLEMENTS"; exit 1; }
[ -f "$JIT_ENTITLEMENTS_FILE" ] || { echo "!! JIT entitlements not found: $JIT_ENTITLEMENTS_FILE"; exit 1; }
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
PLIST_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" 2>/dev/null || true)"
PLIST_PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
TENANT_ID="default"
TENANT_PROFILE_SHA256=""
if [ -n "$TENANT_PROFILE" ]; then
  [ -f "$TENANT_PROFILE" ] || { echo "!! tenant profile not found: $TENANT_PROFILE"; exit 1; }
  # This macOS plutil can extract JSON paths but its `-lint` mode accepts only plist syntax. A
  # no-output conversion still performs a strict JSON parse before any values are trusted.
  plutil -convert json -o /dev/null "$TENANT_PROFILE"
  TENANT_ID="$(plutil -extract tenantId raw -o - "$TENANT_PROFILE")"
  [[ "$TENANT_ID" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] \
    || { echo "!! tenantId must be a lowercase filesystem-safe identifier"; exit 1; }
  TENANT_BUNDLE_IDENTIFIER="$(plutil -extract bundleIdentifier raw -o - "$TENANT_PROFILE")"
  [ "$TENANT_BUNDLE_IDENTIFIER" = "$BUNDLE_IDENTIFIER" ] \
    || { echo "!! tenant profile bundle id $TENANT_BUNDLE_IDENTIFIER does not match $BUNDLE_IDENTIFIER"; exit 1; }
  PROFILE_FEED_URL="$(plutil -extract update.feedURL raw -o - "$TENANT_PROFILE" 2>/dev/null || true)"
  PROFILE_PUBLIC_ED_KEY="$(plutil -extract update.publicEDKey raw -o - "$TENANT_PROFILE" 2>/dev/null || true)"
  [ -n "$PROFILE_FEED_URL" ] && [ "$PROFILE_FEED_URL" = "$PLIST_FEED_URL" ] \
    || { echo "!! tenant profile update feed does not match Info.plist"; exit 1; }
  [ -n "$PROFILE_PUBLIC_ED_KEY" ] && [ "$PROFILE_PUBLIC_ED_KEY" = "$PLIST_PUBLIC_ED_KEY" ] \
    || { echo "!! tenant profile Sparkle public key does not match Info.plist"; exit 1; }
  TENANT_PROFILE_SHA256="$(/usr/bin/shasum -a 256 "$TENANT_PROFILE" | awk '{print $1}')"
elif [ "$BUNDLE_IDENTIFIER" != "ai.mechanician.app" ]; then
  echo "!! non-public bundle $BUNDLE_IDENTIFIER requires MECHANICIAN_TENANT_PROFILE"
  exit 1
fi

# Capture tracked source identity once. The Help artifact and signed build record must describe the
# same snapshot; later checks abort if source changes while this assembler is running.
SOURCE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
SOURCE_DIFF_SHA256="$(git -C "$REPO" diff --binary HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
verify_source_identity() {
  local current_commit current_diff
  current_commit="$(git -C "$REPO" rev-parse HEAD)"
  current_diff="$(git -C "$REPO" diff --binary HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
  [ "$current_commit" = "$SOURCE_COMMIT" ] && [ "$current_diff" = "$SOURCE_DIFF_SHA256" ] \
    || { echo "!! tracked source changed while assembling Mechanician"; exit 1; }
}

# The `mechanician://` scheme belongs to the bundle identity, exactly like the support directory and
# the Keychain services. A link carries a bare UUID and every identity resolves UUIDs against its
# own store, so a shared scheme would let LaunchServices hand a link minted by the public app to a
# tenant bundle, which would look it up in a different store and silently find nothing.
# app/Mechanician-Info.plist declares the public scheme; a tenant bundle id gets its slug appended
# here. Mirrors MechanicianEnvironment.urlScheme(for:), which URLSchemeIdentityTests pins.
case "$BUNDLE_IDENTIFIER" in
  ai.mechanician.app) URL_SCHEME="mechanician" ;;
  ai.mechanician.app.*)
    SLUG="${BUNDLE_IDENTIFIER#ai.mechanician.app.}"
    SLUG="${SLUG%%.*}"
    [ -n "$SLUG" ] || { echo "!! cannot derive a URL scheme from bundle id $BUNDLE_IDENTIFIER"; exit 1; }
    URL_SCHEME="mechanician-$SLUG" ;;
  *) echo "!! cannot derive a URL scheme from bundle id $BUNDLE_IDENTIFIER"; exit 1 ;;
esac
if [ "$URL_SCHEME" != "mechanician" ]; then
  # Patch a working copy so the shipped app/Mechanician-Info.plist stays the public truth, and
  # reassign INFO_PLIST before it is used — it is both embedded into the binary (__TEXT,__info_plist)
  # and copied to Contents/Info.plist, and those two must describe ONE identity.
  SCHEME_PLIST="$REPO/build/$APP_NAME-bundle-Info.plist"
  mkdir -p "$REPO/build"
  cp "$INFO_PLIST" "$SCHEME_PLIST"
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $URL_SCHEME" "$SCHEME_PLIST"
  INFO_PLIST="$SCHEME_PLIST"
fi
# Only the public Mechanician bundle owns the portable Conversation Record type. Tenant bundles can
# inspect the same files via Finder/Open With, but must never displace the public app as the default
# double-click target. Resolve declarations by UTI rather than array position because supported
# custom tenant plists may add or reorder their own declarations.
if [ "$BUNDLE_IDENTIFIER" != "ai.mechanician.app" ]; then
  "$REPO/scripts/downgrade-conversation-record-plist.sh" "$INFO_PLIST"
fi
echo "==> url scheme: $URL_SCHEME://"

# Release artifacts must not silently change because a beta/new Xcode happens to be installed.
# These defaults describe the audited toolchain; an intentional toolchain update changes the pins
# in source (or explicitly overrides all three values for a local experiment).
PINNED_XCODE_VERSION="${MECHANICIAN_XCODE_VERSION:-26.6}"
PINNED_XCODE_BUILD="${MECHANICIAN_XCODE_BUILD:-17F113}"
PINNED_SDK_VERSION="${MECHANICIAN_SDK_VERSION:-26.5}"
export DEVELOPER_DIR="${MECHANICIAN_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] \
  || { echo "!! pinned Xcode developer directory not found: $DEVELOPER_DIR"; exit 1; }
XCODE_VERSION="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
XCODE_BUILD="$(xcodebuild -version | sed -n '2s/^Build version //p')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[ "$XCODE_VERSION" = "$PINNED_XCODE_VERSION" ] && [ "$XCODE_BUILD" = "$PINNED_XCODE_BUILD" ] \
  || { echo "!! Xcode $XCODE_VERSION ($XCODE_BUILD) does not match pinned $PINNED_XCODE_VERSION ($PINNED_XCODE_BUILD)"; exit 1; }
[ "$SDK_VERSION" = "$PINNED_SDK_VERSION" ] \
  || { echo "!! macOS SDK $SDK_VERSION does not match pinned $PINNED_SDK_VERSION"; exit 1; }
echo "==> toolchain: Xcode $XCODE_VERSION ($XCODE_BUILD), macOS SDK $SDK_VERSION"

echo "==> swift build -c release"
# Embed Info.plist into the binary (__TEXT,__info_plist). TCC reads the EMBEDDED plist for a
# signed executable — without this, mic/speech APIs hard-abort as if the usage strings were
# missing even though Contents/Info.plist has them. Must be on every swift build invocation.
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST")
# App Intents: record const values during the build so the metadata extractor (below) can
# emit Metadata.appintents — without it Siri/Spotlight/Shortcuts can't see the app's intents.
# Apple Silicon only — the macOS 26 floor and the arm64-only bundled Node/engine make an Intel
# slice pointless. `--arch arm64` guarantees a single-arch build even on an Intel host.
ARCH_FLAGS=(--arch arm64)
BIN_DIR="$(cd "$REPO/app" && swift build -c release --product "$PRODUCT_NAME" \
  "${ARCH_FLAGS[@]}" "${PLIST_FLAGS[@]}" --show-bin-path)"
PROTOCOLS_JSON="$("$REPO/scripts/appintents.sh" prepare)"
CONST_FLAGS=(-Xswiftc -emit-const-values-path -Xswiftc "$BIN_DIR/$PRODUCT_NAME.swiftconstvalues"
             -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
             -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS_JSON")
( cd "$REPO/app" && swift build -c release --product "$PRODUCT_NAME" \
  "${ARCH_FLAGS[@]}" "${PLIST_FLAGS[@]}" "${CONST_FLAGS[@]}" >/dev/null )
# The native Keychain broker is a separate, minimal Security.framework executable. Build it without
# the app's embedded Info.plist/App Intents linker flags, then bundle and sign it below.
( cd "$REPO/app" && swift build -c release --product MechanicianKeychainHelper \
  "${ARCH_FLAGS[@]}" >/dev/null )

DSYM_SOURCE="$BIN_DIR/$PRODUCT_NAME.dSYM"
[ -d "$DSYM_SOURCE" ] || { echo "!! release dSYM missing at $DSYM_SOURCE"; exit 1; }
rm -rf "$REPO/build/$APP_NAME.app.dSYM"
ditto "$DSYM_SOURCE" "$REPO/build/$APP_NAME.app.dSYM"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/agentd"
cp "$BIN_DIR/$PRODUCT_NAME" "$APP/Contents/MacOS/$PRODUCT_NAME"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$APP_ICON" "$APP/Contents/Resources/Mechanician.icns"
KEYCHAIN_HELPER="$BIN_DIR/MechanicianKeychainHelper"
[ -x "$KEYCHAIN_HELPER" ] \
  || { echo "!! native Keychain helper missing at $KEYCHAIN_HELPER"; exit 1; }
cp "$KEYCHAIN_HELPER" "$APP/Contents/Resources/MechanicianKeychainHelper"
chmod +x "$APP/Contents/Resources/MechanicianKeychainHelper"
# FR-103: embed the tenant profile (if any) pre-sign so its integrity is covered by the signature.
if [ -n "$TENANT_PROFILE" ]; then
  cp "$TENANT_PROFILE" "$APP/Contents/Resources/tenant.json"
  echo "==> embedded tenant profile: $(basename "$TENANT_PROFILE")"
fi
cp "$REPO/app/Resources/figure-source.png" "$APP/Contents/Resources/figure-source.png"   # legacy splash fallback
cp "$REPO/app/Resources/magic_and_lasers.PNG" "$APP/Contents/Resources/magic-and-lasers.png"  # launch splash art (Magic & Lasers mark)
cp "$PRODUCT_DISPLAY_FONT" "$APP/Contents/Resources/dm-serif-display-latin.woff2"
# Pinned Mermaid renderer (FR-334). Bundled, never fetched: artifact previews have no network, and
# a diagram must not stop rendering because a CDN is down. Rendered offscreen, then frozen to SVG.
cp "$REPO/app/Resources/mermaid.min.js" "$APP/Contents/Resources/mermaid.min.js"
# Normalize resource perms to world-readable — `cp` preserves source perms, and a stray 0600
# source (magic_and_lasers.PNG had one) makes generate_appcast warn about irregular permissions.
chmod 644 "$APP/Contents/Resources/"*.png "$APP/Contents/Resources/Mechanician.icns"
chmod 644 "$APP/Contents/Resources/dm-serif-display-latin.woff2"
chmod 644 "$APP/Contents/Resources/mermaid.min.js"

# Localization. Compiled by the shared script so this bundle and dev.sh's cannot drift; see
# scripts/compile-string-catalog.sh for why this is a build step rather than SwiftPM resources.
# Only a dogfood build carries the `en-XA` pseudo-locale — a release must never ship it.
if [ "${MECHANICIAN_DOGFOOD_BUILD:-}" = "1" ]; then
  "$REPO/scripts/compile-string-catalog.sh" "$APP" --pseudo
else
  "$REPO/scripts/compile-string-catalog.sh" "$APP"
fi

echo "==> extracting App Intents metadata"
"$REPO/scripts/appintents.sh" extract "$BIN_DIR" "$APP"   # release builds fail hard: a bundle without Metadata.appintents ships invisible intents

echo "==> staging agentd dependencies from package-lock.json"
AGENTD_STAGE="$REPO/build/.agentd-release-stage.$$"
rm -rf "$AGENTD_STAGE"
cleanup_agentd_stage() { rm -rf "$AGENTD_STAGE"; }
trap cleanup_agentd_stage EXIT
"$REPO/scripts/stage-agentd.sh" "$AGENTD_STAGE"

echo "==> bundling agentd (src + locked production deps)"
cp -R "$REPO/agentd/src" "$APP/Contents/Resources/agentd/src"
cp "$AGENTD_STAGE/package.json" "$AGENTD_STAGE/package-lock.json" "$APP/Contents/Resources/agentd/"
cp -R "$AGENTD_STAGE/node_modules" "$APP/Contents/Resources/agentd/node_modules"
# node-pty's spawn-helper must stay executable (cp can preserve, npm can strip it).
find "$APP/Contents/Resources/agentd/node_modules" -name spawn-helper -exec chmod +x {} \;

# The Mac Bridge is a development fixture, not a shipped feature: it exists to exercise an
# OAuth-authenticated MCP server end to end. Everything it exposed to a client, Mechanician's own
# agent already had natively, so serving it over loopback bought the user nothing. Kept in the repo
# with its tests; excluded from the bundle so it cannot be reached from a shipped app.
rm -rf "$APP/Contents/Resources/agentd/src/mac-bridge"

echo "==> pruning bundled node_modules (Mac-only, runtime-only)"
NM="$APP/Contents/Resources/agentd/node_modules"
# non-darwin-arm64 native prebuilds (node-pty ships Windows + Intel we never load on this Mac app)
find "$NM" -type d \( -name 'win32-*' -o -name 'linux-*' -o -name 'darwin-x64' \) -path '*prebuilds*' -exec rm -rf {} + 2>/dev/null || true
# The lock records every Codex platform package, while this arm64-only app needs exactly one.
find "$NM/@openai" -maxdepth 1 -type d -name 'codex-*' \
  ! -name 'codex-darwin-arm64' -exec rm -rf {} + 2>/dev/null || true
# sourcemaps + TypeScript declarations (never used at runtime)
find "$NM" \( -name '*.map' -o -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' \) -delete 2>/dev/null || true
# tests + docs (keep LICENSE* for attribution)
find "$NM" -type d \( -name test -o -name tests -o -name __tests__ -o -name docs -o -name .github \) -exec rm -rf {} + 2>/dev/null || true
find "$NM" -iname '*.md' ! -iname 'license*' -delete 2>/dev/null || true

BUNDLED_CODEX_VERSION="0.148.0"
ANTHROPIC_CLAUDE_TEAM_ID="Q6L2SF6YDW"
ANTHROPIC_CLAUDE_IDENTIFIER="com.anthropic.claude-code"
BUNDLED_CLAUDE="$NM/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
BUNDLED_CODEX="$NM/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
BUNDLED_CODEX_HOST="$NM/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex-code-mode-host"
[ -x "$BUNDLED_CLAUDE" ] \
  || { echo "!! bundled Claude engine is missing or not executable: $BUNDLED_CLAUDE"; exit 1; }
codesign --verify --strict --verbose=2 "$BUNDLED_CLAUDE" >/dev/null 2>&1 \
  || { echo "!! bundled Claude engine has no valid vendor signature"; exit 1; }
CLAUDE_TEAM_ID="$(codesign -dvv "$BUNDLED_CLAUDE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
CLAUDE_IDENTIFIER="$(codesign -dvv "$BUNDLED_CLAUDE" 2>&1 | sed -n 's/^Identifier=//p')"
[ "$CLAUDE_TEAM_ID" = "$ANTHROPIC_CLAUDE_TEAM_ID" ] \
  || { echo "!! bundled Claude engine team is $CLAUDE_TEAM_ID, expected $ANTHROPIC_CLAUDE_TEAM_ID"; exit 1; }
[ "$CLAUDE_IDENTIFIER" = "$ANTHROPIC_CLAUDE_IDENTIFIER" ] \
  || { echo "!! bundled Claude engine identifier is $CLAUDE_IDENTIFIER, expected $ANTHROPIC_CLAUDE_IDENTIFIER"; exit 1; }
[ -x "$BUNDLED_CODEX" ] \
  || { echo "!! bundled Codex App Server is missing or not executable: $BUNDLED_CODEX"; exit 1; }
[ -x "$BUNDLED_CODEX_HOST" ] \
  || { echo "!! bundled Codex code-mode host is missing or not executable: $BUNDLED_CODEX_HOST"; exit 1; }
[ "$("$BUNDLED_CODEX" --version)" = "codex-cli $BUNDLED_CODEX_VERSION" ] \
  || { echo "!! bundled Codex App Server failed its pinned version check"; exit 1; }

echo "==> bundling the Node runtime (self-contained — no system Node required)"
DEFAULT_NODE_VERSION="v24.18.0"
DEFAULT_NPM_VERSION="11.16.0"
DEFAULT_NODE_SHA256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
NODE_VERSION="${MECHANICIAN_NODE_VERSION:-$DEFAULT_NODE_VERSION}"
EXPECTED_NPM_VERSION="${MECHANICIAN_NPM_VERSION:-$DEFAULT_NPM_VERSION}"
NODE_TRIPLE="darwin-arm64"
NODE_CACHE="$REPO/build/.node-cache"
if [ "$NODE_VERSION" = "$DEFAULT_NODE_VERSION" ]; then
  NODE_SHA256="${MECHANICIAN_NODE_SHA256:-$DEFAULT_NODE_SHA256}"
elif [ -n "${MECHANICIAN_NODE_SHA256:-}" ]; then
  NODE_SHA256="$MECHANICIAN_NODE_SHA256"
else
  echo "!! MECHANICIAN_NODE_SHA256 is required when overriding MECHANICIAN_NODE_VERSION"
  exit 1
fi
NODE_ARCHIVE_NAME="node-$NODE_VERSION-$NODE_TRIPLE.tar.gz"
NODE_ARCHIVE="$NODE_CACHE/$NODE_ARCHIVE_NAME"
mkdir -p "$NODE_CACHE"
if [ ! -f "$NODE_ARCHIVE" ]; then
  echo "    downloading Node $NODE_VERSION ($NODE_TRIPLE)…"
  NODE_DOWNLOAD="$NODE_ARCHIVE.download"
  rm -f "$NODE_DOWNLOAD"
  curl --fail --location --retry 3 --retry-all-errors \
    "https://nodejs.org/dist/$NODE_VERSION/$NODE_ARCHIVE_NAME" -o "$NODE_DOWNLOAD"
  mv "$NODE_DOWNLOAD" "$NODE_ARCHIVE"
fi
if ! printf '%s  %s\n' "$NODE_SHA256" "$NODE_ARCHIVE" | /usr/bin/shasum -a 256 -c -; then
  rm -f "$NODE_ARCHIVE"
  echo "!! bundled Node archive failed SHA-256 verification"
  exit 1
fi
NODE_EXTRACT="$(mktemp -d)"
tar xzf "$NODE_ARCHIVE" -C "$NODE_EXTRACT" \
  "node-$NODE_VERSION-$NODE_TRIPLE/bin/node" \
  "node-$NODE_VERSION-$NODE_TRIPLE/lib/node_modules/npm" \
  "node-$NODE_VERSION-$NODE_TRIPLE/LICENSE"
BUNDLED_NPM_VERSION="$("$NODE_EXTRACT/node-$NODE_VERSION-$NODE_TRIPLE/bin/node" \
  -p 'require(process.argv[1]).version' \
  "$NODE_EXTRACT/node-$NODE_VERSION-$NODE_TRIPLE/lib/node_modules/npm/package.json")"
[ "$BUNDLED_NPM_VERSION" = "$EXPECTED_NPM_VERSION" ] \
  || { echo "!! bundled npm is $BUNDLED_NPM_VERSION, expected $EXPECTED_NPM_VERSION"; exit 1; }
cp "$NODE_EXTRACT/node-$NODE_VERSION-$NODE_TRIPLE/bin/node" "$APP/Contents/Resources/node"
chmod +x "$APP/Contents/Resources/node"   # picked up by the Mach-O signing pass below
cp -R "$NODE_EXTRACT/node-$NODE_VERSION-$NODE_TRIPLE/lib/node_modules/npm" \
  "$APP/Contents/Resources/npm"
# The runtime's commands live in their own directory, because that directory goes on the PATH the
# agent's shell commands run with. `Contents/Resources` cannot: it is a shared namespace holding
# icons, the Help corpus, `agentd/` — and the npm payload above, an unexecutable DIRECTORY named
# `npm`. A bare `npm` then resolves to it and zsh answers "permission denied" (exit 126), which
# reads to a person and to a model as a blocked command rather than a missing one.
RUNTIME_BIN="$APP/Contents/Resources/runtime"
mkdir -p "$RUNTIME_BIN"
for wrapper in "$REPO"/scripts/runtime/*; do
  cp "$wrapper" "$RUNTIME_BIN/$(basename "$wrapper")"
  chmod +x "$RUNTIME_BIN/$(basename "$wrapper")"
done
# `node` itself is signed in place beside the payload; the runtime directory reaches it by link so
# that a stock Mac resolves a bare `node` too.
ln -sf ../node "$RUNTIME_BIN/node"
for required in node npm npx; do
  [ -x "$RUNTIME_BIN/$required" ] \
    || { echo "!! bundled runtime is missing an executable $required: $RUNTIME_BIN/$required"; exit 1; }
done

# Product knowledge is generated from reviewed public sources and sealed by the outer app
# signature. Use the exact bundled Node/SQLite writer so two distribution builds have the same
# database bytes rather than depending on whichever developer runtime happens to be first in PATH.
"$REPO/scripts/stage-help-corpus.sh" \
  "$APP" "$INFO_PLIST" "$TENANT_ID" "$APP/Contents/Resources/node" \
  "$SOURCE_COMMIT" "$SOURCE_DIFF_SHA256"
HELP_CORPUS_SCHEMA_VERSION="$(/usr/bin/sqlite3 -readonly \
  "$APP/Contents/Resources/MechanicianHelp.sqlite" 'PRAGMA user_version;')"
[[ "$HELP_CORPUS_SCHEMA_VERSION" =~ ^[1-9][0-9]*$ ]] \
  || { echo "!! staged Help corpus has an invalid schema version"; exit 1; }
HELP_CORPUS_SHA256="$(/usr/bin/shasum -a 256 \
  "$APP/Contents/Resources/MechanicianHelp.sqlite" | awk '{print $1}')"

echo "==> embedding Sparkle.framework (auto-update)"
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE_FW" ] \
  || { echo "!! Sparkle.framework not found at $SPARKLE_FW — refusing an incomplete release bundle"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM links Sparkle at @loader_path; in the bundle it lives in Frameworks/.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$PRODUCT_NAME"

echo "==> packaging third-party license texts"
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
copy_license() {
  local source="$1" destination="$2"
  [ -f "$source" ] || { echo "!! required license file missing: $source"; exit 1; }
  cp "$source" "$LICENSES/$destination"
}
copy_license "$REPO/LICENSE" "Mechanician-MIT.txt"
copy_license "$REPO/THIRD-PARTY-NOTICES.md" "THIRD-PARTY-NOTICES.md"
copy_license "$NODE_EXTRACT/node-$NODE_VERSION-$NODE_TRIPLE/LICENSE" "Node.js.txt"
copy_license "$NODE_EXTRACT/node-$NODE_VERSION-$NODE_TRIPLE/lib/node_modules/npm/LICENSE" "npm.txt"
copy_license "$REPO/app/.build/checkouts/Sparkle/LICENSE" "Sparkle-MIT.txt"
copy_license "$REPO/app/.build/checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt" "Sparkle-ed25519.txt"
copy_license "$REPO/app/.build/checkouts/SwiftTerm/LICENSE" "SwiftTerm-MIT.txt"
copy_license "$REPO/app/Resources/DMSerifDisplay-OFL.txt" "DM-Serif-Display-OFL.txt"
copy_license "$REPO/app/Resources/Mermaid-MIT.txt" "Mermaid-MIT.txt"
copy_license "$AGENTD_STAGE/node_modules/@anthropic-ai/claude-agent-sdk/LICENSE.md" "Anthropic-Claude-Agent-SDK.txt"
copy_license "$AGENTD_STAGE/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/LICENSE.md" "Anthropic-Claude-Agent-Engine-darwin-arm64.txt"
copy_license "$REPO/agentd/licenses/OpenAI-Codex-Apache-2.0.txt" "OpenAI-Codex-Apache-2.0.txt"
copy_license "$REPO/agentd/licenses/OpenAI-Codex-NOTICE.txt" "OpenAI-Codex-NOTICE.txt"
copy_license "$REPO/agentd/licenses/Ratatui-MIT.txt" "OpenAI-Codex-Ratatui-MIT.txt"
copy_license "$AGENTD_STAGE/node_modules/@modelcontextprotocol/sdk/LICENSE" "Model-Context-Protocol-SDK-MIT.txt"
copy_license "$AGENTD_STAGE/node_modules/diff/LICENSE" "diff-BSD-3-Clause.txt"
copy_license "$AGENTD_STAGE/node_modules/isomorphic-git/LICENSE.md" "isomorphic-git-MIT.txt"
copy_license "$AGENTD_STAGE/node_modules/node-pty/LICENSE" "node-pty-MIT.txt"
copy_license "$AGENTD_STAGE/node_modules/zod/LICENSE" "zod-MIT.txt"
copy_license "$REPO/agentd/licenses/standardwebhooks-MIT.txt" "standardwebhooks-MIT.txt"
copy_license "$REPO/app/Package.resolved" "SwiftPM-Package.resolved.json"
copy_license "$REPO/agentd/package-lock.json" "npm-package-lock.json"
copy_license "$AGENTD_STAGE/agentd-sbom.cdx.json" "agentd-sbom.cdx.json"

echo "==> recording build provenance"
verify_source_identity
NPM_LOCK_SHA256="$(/usr/bin/shasum -a 256 "$REPO/agentd/package-lock.json" | awk '{print $1}')"
SWIFTPM_LOCK_SHA256="$(/usr/bin/shasum -a 256 "$REPO/app/Package.resolved" | awk '{print $1}')"
SBOM_SHA256="$(/usr/bin/shasum -a 256 "$AGENTD_STAGE/agentd-sbom.cdx.json" | awk '{print $1}')"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
TENANT_PROFILE_SHA256_JSON="null"
[ -z "$TENANT_PROFILE_SHA256" ] || TENANT_PROFILE_SHA256_JSON="\"$TENANT_PROFILE_SHA256\""
DOGFOOD_BUILD_JSON="false"
[ "$DOGFOOD_BUILD" = "0" ] || DOGFOOD_BUILD_JSON="true"
PROVENANCE_FILE="$APP/Contents/Resources/BuildProvenance.json"
cat > "$PROVENANCE_FILE" <<EOF
{
  "schemaVersion": 1,
  "application": "$APP_NAME",
  "bundleIdentifier": "$BUNDLE_IDENTIFIER",
  "tenantId": "$TENANT_ID",
  "tenantProfileSHA256": $TENANT_PROFILE_SHA256_JSON,
  "version": "$APP_VERSION",
  "build": "$APP_BUILD",
  "dogfood": $DOGFOOD_BUILD_JSON,
  "architecture": "arm64",
  "sourceCommit": "$SOURCE_COMMIT",
  "sourceDiffSHA256": "$SOURCE_DIFF_SHA256",
  "xcodeVersion": "$XCODE_VERSION",
  "xcodeBuild": "$XCODE_BUILD",
  "macOSSDK": "$SDK_VERSION",
  "nodeVersion": "$NODE_VERSION",
  "nodeArchiveSHA256": "$NODE_SHA256",
  "codexVersion": "$BUNDLED_CODEX_VERSION",
  "npmLockSHA256": "$NPM_LOCK_SHA256",
  "swiftPackageResolvedSHA256": "$SWIFTPM_LOCK_SHA256",
  "agentdSBOMSHA256": "$SBOM_SHA256",
  "helpCorpusSchemaVersion": $HELP_CORPUS_SCHEMA_VERSION,
  "helpCorpusSHA256": "$HELP_CORPUS_SHA256"
}
EOF
# The runtime rollout policies trust this signed bit. Validate the exact packaged bytes before
# signing so a malformed or mismatched record can never silently select the wrong storage path.
plutil -convert json -o /dev/null "$PROVENANCE_FILE"
PACKAGED_DOGFOOD="$(plutil -extract dogfood raw -o - "$PROVENANCE_FILE")"
[ "$PACKAGED_DOGFOOD" = "$DOGFOOD_BUILD_JSON" ] \
  || { echo "!! packaged dogfood provenance is $PACKAGED_DOGFOOD, expected $DOGFOOD_BUILD_JSON"; exit 1; }
PACKAGED_HELP_SCHEMA="$(plutil -extract helpCorpusSchemaVersion raw -o - "$PROVENANCE_FILE")"
PACKAGED_HELP_SHA256="$(plutil -extract helpCorpusSHA256 raw -o - "$PROVENANCE_FILE")"
[ "$PACKAGED_HELP_SCHEMA" = "$HELP_CORPUS_SCHEMA_VERSION" ] \
  && [ "$PACKAGED_HELP_SHA256" = "$HELP_CORPUS_SHA256" ] \
  || { echo "!! packaged Help provenance does not match MechanicianHelp.sqlite"; exit 1; }
verify_source_identity
rm -rf "$NODE_EXTRACT"

SIGNING_TEAM_ID="${MECHANICIAN_SIGNING_TEAM_ID:-5YPG2C4S34}"
if [ -n "${MECHANICIAN_SIGNING_IDENTITY:-}" ]; then
  DEVID="$MECHANICIAN_SIGNING_IDENTITY"
else
  DEVID="$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application:[^\"]*(${SIGNING_TEAM_ID})\)\".*/\1/p" | head -1)"
fi

if [ -n "${DEVID:-}" ]; then
  echo "==> signing with: $DEVID (hardened runtime)"
  # Sign ordinary nested Mach-O binaries without application or JIT exceptions.
  while IFS= read -r f; do
    if file "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --sign "$DEVID" "$f"
    fi
  done < <(find "$APP/Contents/Resources" -type f \( -perm -111 -o -name '*.node' \) \
    ! -path "$APP/Contents/Resources/node" ! -path "$BUNDLED_CLAUDE" \
    ! -path "$BUNDLED_CODEX" ! -path "$BUNDLED_CODEX_HOST")
  # Only Mechanician-owned JIT-capable executables receive our executable-memory exceptions.
  # Preserve Anthropic's original signature on the Claude engine: its signing identity is part of
  # the Keychain access boundary for the refreshable credential created by `claude auth login`.
  for jit_binary in "$APP/Contents/Resources/node" "$BUNDLED_CODEX" "$BUNDLED_CODEX_HOST"; do
    codesign --force --options runtime --timestamp --entitlements "$JIT_ENTITLEMENTS_FILE" \
      --sign "$DEVID" "$jit_binary"
    JIT_ENTITLEMENTS="$(codesign -d --entitlements - "$jit_binary" 2>&1)"
    echo "$JIT_ENTITLEMENTS" | grep -q 'com.apple.security.cs.allow-jit' \
      || { echo "!! JIT entitlement missing after signing: $jit_binary"; exit 1; }
    echo "$JIT_ENTITLEMENTS" | grep -q 'com.apple.security.cs.allow-unsigned-executable-memory' \
      || { echo "!! executable-memory entitlement missing after signing: $jit_binary"; exit 1; }
    if echo "$JIT_ENTITLEMENTS" | grep -q 'com.apple.security.cs.disable-library-validation'; then
      echo "!! unexpected library-validation exception on $jit_binary"
      exit 1
    fi
  done
  CLAUDE_ENTITLEMENTS="$(codesign -d --entitlements - "$BUNDLED_CLAUDE" 2>&1)"
  echo "$CLAUDE_ENTITLEMENTS" | grep -q 'com.apple.security.cs.allow-jit' \
    || { echo "!! vendor-signed Claude engine is missing its JIT entitlement"; exit 1; }
  echo "$CLAUDE_ENTITLEMENTS" | grep -q 'com.apple.security.cs.allow-unsigned-executable-memory' \
    || { echo "!! vendor-signed Claude engine is missing its executable-memory entitlement"; exit 1; }
  # Sign embedded Sparkle inside-out (hardened runtime, its own code, no app
  # entitlements — Sparkle's helpers must not inherit the app's).
  SP="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SP" ]; then
    echo "==> signing Sparkle helpers"
    for tgt in \
      "$SP/Versions/B/XPCServices/Installer.xpc" \
      "$SP/Versions/B/XPCServices/Downloader.xpc" \
      "$SP/Versions/B/Autoupdate" \
      "$SP/Versions/B/Updater.app"; do
      [ -e "$tgt" ] && codesign --force --options runtime --timestamp --sign "$DEVID" "$tgt"
    done
    codesign --force --options runtime --timestamp --sign "$DEVID" "$SP"
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$APP"
  echo "==> verify"
  codesign --verify --deep --strict --verbose=2 "$APP"
  SIGNED_TEAM_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$SIGNED_TEAM_ID" = "$SIGNING_TEAM_ID" ] \
    || { echo "!! signed app team $SIGNED_TEAM_ID does not match expected $SIGNING_TEAM_ID"; exit 1; }

  # Auth gate (pre-notarize): the freshly-signed app must be able to authenticate Claude under a
  # sanitized, GUI-like launch — the exact condition that shipped broken in 0.11.0/0.11.1/0.11.2.
  # Running it here fails a broken build in seconds instead of after the ~25-minute notarization, and
  # a build that cannot connect to Claude can never reach the publish step. Skips when no login exists.
  if [ "${MECHANICIAN_DISTRIBUTION_BUILD:-0}" = "1" ]; then
    echo "==> verifying packaged Claude auth (pre-notarize gate)"
    "$APP/Contents/Resources/node" "$REPO/scripts/verify-packaged-auth.mjs" "$APP" \
      || { echo "!! packaged auth verification failed — refusing to notarize a build that cannot connect to Claude"; exit 1; }
  fi

  # Notarize when a notarytool keychain profile is named. Set one up once with:
  #   xcrun notarytool store-credentials "mechanician-notary" \
  #     --apple-id "<APPLE_ID>" --team-id 5YPG2C4S34
  # then run:  MECHANICIAN_NOTARY_PROFILE=mechanician-notary ./build-app.sh
  if [ -n "${MECHANICIAN_NOTARY_PROFILE:-}" ]; then
    ZIP="$REPO/build/$APP_NAME.zip"
    echo "==> notarizing via profile: $MECHANICIAN_NOTARY_PROFILE"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$MECHANICIAN_NOTARY_PROFILE" --wait
    # Staple, then confirm the ticket is really on the bundle. Both are retried.
    #
    # `stapler` reaches Apple's CloudKit when it cannot satisfy a request locally, and that lookup
    # fails transiently. It killed the 0.26.0 release: notarization was Accepted, `staple` printed
    # "The staple and validate action worked!", and the very next `validate` returned
    # "CloudKit query ... failed due to (null)" and error 65. Running `stapler validate` by hand a
    # minute later passed, and `spctl` already said "accepted, source=Notarized Developer ID".
    #
    # A release script whose whole point is running unattended must not throw away a completed
    # notarization over one network blip, so a transient answer is retried rather than fatal. What
    # is NOT relaxed is the requirement itself: the loop still has to see a real success, and
    # `spctl` below still assesses the bundle, so an unstapled app cannot get past here.
    echo "==> stapling"
    staple_step() {   # $1 = stapler action, for the message
      local attempt=1
      until xcrun stapler "$1" "$APP"; do
        if [ "$attempt" -ge 5 ]; then
          echo "!! stapler $1 failed 5 times — this is not transient"
          return 1
        fi
        echo "   stapler $1 failed (attempt $attempt); Apple's ticket service may be slow, retrying"
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
      done
    }
    staple_step staple
    staple_step validate
    spctl --assess --type execute --verbose=2 "$APP"
  else
    [ "${MECHANICIAN_DISTRIBUTION_BUILD:-0}" != "1" ] \
      || { echo "!! MECHANICIAN_NOTARY_PROFILE is required for a distribution build"; exit 1; }
    echo "==> Signed (not notarized). Set MECHANICIAN_NOTARY_PROFILE to notarize."
  fi
else
  if [ "${MECHANICIAN_DISTRIBUTION_BUILD:-0}" = "1" ]; then
    echo "!! no Developer ID Application identity for team $SIGNING_TEAM_ID — refusing distribution build"
    exit 1
  fi
  echo "==> no Developer ID identity — ad-hoc signing (runs locally, not distributable)"
  codesign --force --deep --sign - "$APP"
fi

rm -rf "$AGENTD_STAGE"
trap - EXIT
echo "==> done: $APP"
