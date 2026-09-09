#!/usr/bin/env bash
# Mechanician dev launcher: wires agentd's path + Anthropic key, then runs the app.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
SOURCE_DIFF_SHA256="$(git -C "$REPO" diff --binary HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
export MECHANICIAN_AGENTD="${MECHANICIAN_AGENTD:-$REPO/agentd/src/agentd.mjs}"
export MECHANICIAN_AMBIENTD="${MECHANICIAN_AMBIENTD:-$REPO/agentd/src/ambientd.mjs}"
export MECHANICIAN_ICON="$REPO/app/Resources/Mechanician.icns"

# Run agentd on a Node that can load this repo's node_modules.
#
# npm ships node-pty's `pty.node` ad-hoc signed, and macOS refuses to map an ad-hoc library into a
# process signed with a Team ID: "mapping process and mapped file (non-platform) have different Team
# IDs". The app's own Node is Developer ID signed, so pointing a dev build at the raw repo tree — the
# whole purpose of this script — makes every terminal fail to spawn. The packaged app is unaffected:
# its agentd tree is signed along with the bundle. Prefer an unsigned Node here and fall back to the
# app's, which is still correct whenever the tree happens to be signed.
if [ -z "${MECHANICIAN_NODE:-}" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
    if [ -x "$candidate" ]; then
      export MECHANICIAN_NODE="$candidate"
      break
    fi
  done
fi

# Working directory the agent's tools operate in. Defaults to $HOME so the agent
# doesn't act inside the app source; override by exporting MECHANICIAN_CWD first.
# (A proper in-app folder picker is coming.)
export MECHANICIAN_CWD="${MECHANICIAN_CWD:-$HOME}"

# Auth: default to the user's Claude subscription (no API key). The app honors this
# MECHANICIAN_AUTH env at startup, overriding its persisted setting. Test metered
# API-key mode with: MECHANICIAN_AUTH=apikey ./dev.sh
export MECHANICIAN_AUTH="${MECHANICIAN_AUTH:-subscription}"

if [ "$MECHANICIAN_AUTH" = "apikey" ]; then
  # Resolve ANTHROPIC_API_KEY without ever printing it:
  #   1. already-exported env  2. macOS Keychain  3. agentd/.env
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    if key=$(security find-generic-password -a mechanician -s ANTHROPIC_API_KEY -w 2>/dev/null); then
      export ANTHROPIC_API_KEY="$key"
    elif [ -f "$REPO/agentd/.env" ]; then
      set -a; . "$REPO/agentd/.env"; set +a
    fi
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "[dev] auth=apikey — ANTHROPIC_API_KEY resolved."
  else
    # agentd's mock lane is gated on MECHANICIAN_ENABLE_MOCK_PROVIDER=1 (see MOCK_PROVIDER_ENABLED
    # in agentd/src/agentd.mjs). This script does not set it, so with no key agentd reports
    # mode=unavailable and refuses every turn rather than answering with canned text.
    echo "[dev] auth=apikey but no key found. agentd will start unavailable and every turn will fail."
    echo "[dev] Provide ANTHROPIC_API_KEY, or run MECHANICIAN_ENABLE_MOCK_PROVIDER=1 ./dev.sh for canned replies."
  fi
else
  # Subscription mode: no metered key; agentd uses the Claude login in ~/.claude.
  unset ANTHROPIC_API_KEY
  echo "[dev] auth=subscription — using your Claude login (no API key)."
fi

# Build against the NEWEST installed macOS SDK — the point of this project is to learn and
# exploit the latest OS features (Liquid Glass, etc.). Prefer an Xcode that ships a higher
# macOS SDK (e.g. a beta with macOS 27 "Golden Gate"). Override with
# MECHANICIAN_DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./dev.sh
if [ -z "${MECHANICIAN_DEVELOPER_DIR:-}" ]; then
  best_dev=""; best_major=0
  for app in /Applications/Xcode*.app; do
    sdkdir="$app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs"
    [ -d "$sdkdir" ] || continue
    for sdk in "$sdkdir"/MacOSX*.sdk; do
      ver="$(basename "$sdk")"; ver="${ver#MacOSX}"; ver="${ver%.sdk}"
      major="${ver%%.*}"
      case "$major" in ''|*[!0-9]*) continue;; esac
      if [ "$major" -gt "$best_major" ]; then best_major="$major"; best_dev="$app/Contents/Developer"; fi
    done
  done
  [ -n "$best_dev" ] && export DEVELOPER_DIR="$best_dev"
else
  export DEVELOPER_DIR="$MECHANICIAN_DEVELOPER_DIR"
fi
echo "[dev] building against macOS SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo '?')  (Xcode: ${DEVELOPER_DIR:-default})"

# EXPECTED, and not ours:
#
#   warning: missing creator for mutated node:
#     (.build/out/Products/Debug/SwiftTerm_SwiftTerm.bundle/Contents/MacOS)
#
# Choosing the newest Xcode above also chooses its SwiftPM, and in the betas that defaults to
# `--build-system swiftbuild` (the native engine is deprecated there). Swift Build emits this while
# planning the resource bundle SwiftTerm declares for its Metal shader — a directory node it sees
# mutated with no producing task. Nothing in this repo creates that node, and the bundle is not
# copied into the app at all, in dev or in the shipped release; SwiftTerm uses its default renderer.
#
# Release and CI do not see it: build-app.sh pins DEVELOPER_DIR to /Applications/Xcode.app, whose
# SwiftPM still defaults to the native engine. So this is a preview of what release builds will
# print once swiftbuild becomes the default everywhere.
#
# Do not "fix" it by forcing `--build-system native`: measured, that trades this warning for the
# engine warning that native itself is deprecated. Nothing we control removes it — a fresh .build,
# plain `swift build` without this script's flags, and SwiftTerm 1.13 through 1.15 all still emit it.
#
# So the build output below rewrites that one exact line into a short note rather than printing a
# long path every time. It is replaced, not dropped: a second occurrence, or any other thing Swift
# Build has to say, still reaches you unchanged.

cd "$REPO/app"

# Assemble a minimal .app bundle around the debug binary and run THAT (not raw
# `swift run`), so the dev build is a real bundle — a proper icon in the Dock, Stage
# Manager, and Mission Control, plus a bundle identity. The debug binary links Sparkle
# from the build dir, so we add that dir as an rpath after copying it into the bundle.
echo "[dev] building…"
# Dev bundle identity: ai.mechanician.app.dev + "Mechanician Dev" — NOT the installed app's
# ai.mechanician.app. Two bundles registered under one id broke Shortcuts' App Intents
# registry (WFInterchangeAppRegistry: "Failed to load a definition for ai.mechanician.app"):
# LaunchServices can't hold duplicate registrations per id, so Shortcuts/Spotlight/Siri
# resolution flapped between the installed app and this build. A distinct dev id keeps the
# registrations disjoint. Generated as a PATCHED COPY of the release plist so the shipped
# values in app/Mechanician-Info.plist (used by build-app.sh) stay untouched. Sparkle keys
# are stripped too: the dev build must never self-update, and UpdaterManager already treats
# a missing SUFeedURL as "updates are handled by the installed app".
# Side effects of the new identity (intended): fresh TCC prompts once (mic/speech/automation),
# and a separate UserDefaults domain — full dev/stable isolation, matching the separate
# MECHANICIAN_SUPPORT_DIR store below.
DEV_PLIST="$REPO/build/Mechanician-dev-Info.plist"
mkdir -p "$REPO/build"
cp "$REPO/app/Mechanician-Info.plist" "$DEV_PLIST"
# The `mechanician://` scheme is part of the bundle identity, like the support directory and the
# Keychain services: a link carries a bare UUID, and the dev build resolves UUIDs against its own
# store. Sharing the public scheme would let LaunchServices hand a link minted by the installed app
# to this build, which would look the UUID up in a different store and silently find nothing.
# Mirrors MechanicianEnvironment.urlScheme(for:); URLSchemeIdentityTests pins the two together.
/usr/libexec/PlistBuddy \
  -c 'Set :CFBundleIdentifier ai.mechanician.app.dev' \
  -c 'Set :CFBundleName Mechanician Dev' \
  -c 'Set :CFBundleDisplayName Mechanician Dev' \
  -c 'Set :CFBundleURLTypes:0:CFBundleURLName Mechanician Dev Link' \
  -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 mechanician-dev' \
  "$DEV_PLIST"
# The installed public app owns the portable Conversation Record type. The dev bundle must still
# receive Finder/Open With events for `.convrec`, but registering a second exporter/Owner would let
# whichever build launched last steal double-clicks from the dogfood app. Keep the same interoperable
# UTI while downgrading the dev copy to an importer and Alternate viewer. The helper resolves both
# declarations by UTI, so future source-plist reordering cannot silently downgrade the wrong type.
"$REPO/scripts/downgrade-conversation-record-plist.sh" "$DEV_PLIST"
# Services entries land in every app's Services menu, where two identically-named submenus would be
# indistinguishable — and picking the wrong one during verification means driving the installed app
# against real conversations. Rename the dev submenu so the two are never confused.
for i in 0 1 2 3; do
  title="$(/usr/libexec/PlistBuddy -c "Print :NSServices:$i:NSMenuItem:default" "$DEV_PLIST" 2>/dev/null)" || continue
  /usr/libexec/PlistBuddy \
    -c "Set :NSServices:$i:NSMenuItem:default Mechanician Dev/${title#Mechanician/}" "$DEV_PLIST"
done
# Which build a screenshot came from. Only dev bundles carry this key; the Agents panel draws it in
# its footer, so a cropped capture identifies its own binary. `Add` rather than `Set` — the key is
# absent from the shipped plist by design.
BUILD_STAMP="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$REPO" diff --quiet 2>/dev/null || BUILD_STAMP="$BUILD_STAMP+dirty"
/usr/libexec/PlistBuddy \
  -c "Add :MechanicianBuildStamp string $BUILD_STAMP $(date '+%H:%M')" "$DEV_PLIST"
for k in SUFeedURL SUEnableAutomaticChecks SUScheduledCheckInterval SUPublicEDKey; do
  /usr/libexec/PlistBuddy -c "Delete :$k" "$DEV_PLIST" 2>/dev/null || true
done

# Embed the DEV Info.plist into the binary's __TEXT,__info_plist section. TCC reads the
# EMBEDDED plist for a signed executable, not Contents/Info.plist — without this, privacy-gated
# APIs (mic / speech) hard-abort with "missing NSSpeechRecognitionUsageDescription" even though
# the bundle plist has the key. It must be the same patched plist as Contents/Info.plist so
# TCC/LaunchServices/AppIntents all see ONE consistent (dev) identity. Same flags must be on
# every `swift build` invocation or an incremental rebuild drops the section.
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DEV_PLIST")
# App Intents: have the compiler record const values during the build so the metadata
# extractor (below) can emit Metadata.appintents — the piece `swift build` alone skips,
# without which Siri/Spotlight/Shortcuts can't see the app's intents.
BINDIR="$(swift build "${PLIST_FLAGS[@]}" --show-bin-path)"
PROTOCOLS_JSON="$("$REPO/scripts/appintents.sh" prepare)"
CONST_FLAGS=(-Xswiftc -emit-const-values-path -Xswiftc "$BINDIR/Mechanician.swiftconstvalues"
             -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
             -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS_JSON")
swift build "${PLIST_FLAGS[@]}" "${CONST_FLAGS[@]}" 2>&1 | sed \
  -e 's|^warning: missing creator for mutated node.*|[dev] (known upstream Swift Build warning about SwiftTerm'"'"'s resource bundle — see dev.sh)|'
build_status="${PIPESTATUS[0]}"
[ "$build_status" -eq 0 ] || exit "$build_status"
APP="$REPO/build/Mechanician-dev.app"

# Cleanup: earlier dev builds registered build/ bundles under the SHARED id, which is what
# corrupted Shortcuts' registry in the first place. Unregister any stale build/ registrations
# before this (re)build re-registers under the dev id. Harmless when nothing is registered.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$REPO/build/Mechanician.app" >/dev/null 2>&1 || true

# Prune dev registrations whose bundle is no longer on disk. Builds from other worktrees and from
# temporary clones accumulate in the LaunchServices database and outlive the directories they came
# from — five were registered here when this was added, four of them dead. That matters because this
# app has a documented history of Shortcuts refusing to load its App Intents definition when several
# bundles claim the same identifier.
#
# Deliberately only unregisters paths that no longer exist, so another live worktree's dev build
# keeps its registration. The blunt alternative, `lsregister -kill -r`, rebuilds the whole system
# database and is far too much for a dev launcher.
while read -r stale; do
  [ -n "$stale" ] || continue
  [ -d "$stale" ] && continue
  "$LSREGISTER" -u "$stale" >/dev/null 2>&1 || true
done < <("$LSREGISTER" -dump 2>/dev/null \
  | grep -oE "^[[:space:]]*path:[[:space:]]+[^[:space:]]*Mechanician-dev\.app" \
  | awk '{print $2}' | sort -u || true)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/Mechanician" "$APP/Contents/MacOS/Mechanician"
cp "$DEV_PLIST" "$APP/Contents/Info.plist"
cp "$REPO/app/Resources/Mechanician.icns" "$APP/Contents/Resources/Mechanician.icns"
cp "$REPO/app/Resources/magic_and_lasers.PNG" "$APP/Contents/Resources/magic-and-lasers.png"  # launch splash art
cp "$REPO/app/Resources/dm-serif-display-latin.woff2" "$APP/Contents/Resources/dm-serif-display-latin.woff2"
cp "$REPO/app/Resources/mermaid.min.js" "$APP/Contents/Resources/mermaid.min.js"  # pinned Mermaid renderer (FR-334)
# The Help reader and the future agent tool share this exact immutable corpus. Stage it through the
# same helper as release packaging before the bundle is signed.
HELP_NODE="${MECHANICIAN_NODE:-$(command -v node || true)}"
"$REPO/scripts/stage-help-corpus.sh" \
  "$APP" "$DEV_PLIST" default "$HELP_NODE" "$SOURCE_COMMIT" "$SOURCE_DIFF_SHA256"
# Localization, via the same script build-app.sh uses. A dev build ALWAYS carries the `en-XA`
# pseudo-locale: it is never shipped, and it is the build you can actually force a language on.
# The installed app and a dogfood build share the bundle id `ai.mechanician.app`, so `defaults
# write` on that domain hits whichever of the two LaunchServices decides to launch — this bundle's
# distinct id is what makes a locale override land on the binary under test.
# Must run BEFORE codesign below: the signature seals Contents/Resources.
"$REPO/scripts/compile-string-catalog.sh" "$APP" --pseudo
"$REPO/scripts/appintents.sh" extract "$BINDIR" "$APP" \
  || echo "[dev] WARNING: App Intents metadata extraction failed — intents won't be OS-visible in this build"
install_name_tool -add_rpath "$BINDIR" "$APP/Contents/MacOS/Mechanician" 2>/dev/null || true

# install_name_tool rewrites the Mach-O, which invalidates the ad-hoc signature that
# `swift build` applied. macOS 26/27 kill an invalidly-signed binary at dyld launch
# ("CODESIGNING Invalid Page"), so re-sign the bundle ad-hoc before running. Uses the
# plist's CFBundleIdentifier — the DEV id — as the signing identifier, so Dock/TCC/
# LaunchServices all see the dev build as a distinct app from the installed one.
echo "[dev] signing…"
codesign --force --sign - "$APP"

# Re-register the freshly signed bundle, and nudge the Services cache.
#
# Neither LaunchServices nor pbs notices a rebuild on its own. A URL scheme or an NSServices entry
# added to the plist can therefore stay invisible for a whole session, which reads as "the feature
# is broken" rather than "the cache is stale" — and the reverse also happens, where a removed entry
# lingers. The unregister calls above only clear stale build/ copies; this registers the new one.
#
# Verify with `lsregister -dump` or `pbs -dump`, never by looking for the item in a menu: a
# correctly declared entry can be absent from the menu for an entire session. `mdls` does not answer
# scheme-handler questions at all.
#
# Every call is best-effort. dev.sh runs under `set -euo pipefail`, and a cache nudge failing is
# never a reason to fail the build.
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
PBS="/System/Library/CoreServices/pbs"
if [ -x "$PBS" ]; then
  "$PBS" -flush >/dev/null 2>&1 || true
  "$PBS" -update >/dev/null 2>&1 || true
fi

# Build/package the isolated Dev app without starting another GUI process. Automated checks use
# this first, then launch exactly one explicitly configured background verification process.
if [ "${MECHANICIAN_DEV_BUILD_ONLY:-0}" = "1" ]; then
  echo "[dev] build-only — app ready at $APP"
  exit 0
fi

# Print and optionally override the Dev bundle's isolated paths. The app also derives these paths
# from its distinct bundle id, so opening Mechanician-dev.app directly cannot fall back to stable
# data. Keeping them explicit here makes source-tree provider children and diagnostics transparent.
export MECHANICIAN_SUPPORT_DIR="${MECHANICIAN_SUPPORT_DIR:-$HOME/Library/Application Support/Mechanician-dev}"
# Codex may already be running the shell that launches this script, which means CODEX_HOME
# can be inherited from the primary Mechanician process. Always derive the dev Codex home
# from the isolated support directory unless the caller supplies an explicit dev override.
export CODEX_HOME="${MECHANICIAN_DEV_CODEX_HOME:-$MECHANICIAN_SUPPORT_DIR/codex}"
# Also isolate the agent SDK's config/session/credential dir. Sharing ~/.claude with a
# running primary/stable instance crashes it (concurrent session + credential-refresh state),
# which shows up as every MCP tool returning "Stream closed". agentd pairs this directory with
# Claude's app-scoped secure storage, so a fresh dev store owns an independent login.
export MECHANICIAN_CONFIG_DIR="${MECHANICIAN_CONFIG_DIR:-$MECHANICIAN_SUPPORT_DIR/claude}"
echo "[dev] store: $MECHANICIAN_SUPPORT_DIR"
echo "[dev] config: $MECHANICIAN_CONFIG_DIR"
echo "[dev] codex: $CODEX_HOME"

exec "$APP/Contents/MacOS/Mechanician"
