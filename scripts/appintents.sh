#!/usr/bin/env bash
# App Intents metadata for SwiftPM-built bundles — the step Xcode's "Extract app intents
# metadata" phase runs and plain `swift build` skips. Without it the intents in
# MechanicianIntents.swift compile and work in-process but are INVISIBLE to Siri, Spotlight,
# and Shortcuts (no Metadata.appintents in the bundle).
#
# Two subcommands, called by dev.sh and build-app.sh:
#
#   appintents.sh prepare
#     Emits the const-extraction protocol list the Swift frontend needs and prints its path.
#     The toolchain ships this list as a wrapper object; the frontend wants a flat JSON array,
#     so we flatten it. The caller passes the path via:
#       -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc <path>
#     together with:
#       -Xswiftc -emit-const-values-path -Xswiftc <bindir>/Mechanician.swiftconstvalues
#     (release/WMO honors the explicit path; debug ignores it and emits per-file
#     .swiftconstvalues under <bindir>/Mechanician.build/ — extract handles both.)
#
#   appintents.sh extract <bin-dir> <app-bundle>
#     Runs appintentsmetadataprocessor over the recorded const values and writes
#     <app>/Contents/Resources/Metadata.appintents. MUST run before codesign — the seal
#     has to cover the metadata.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE=Mechanician
DEPLOYMENT_TARGET=26.0
TRIPLE="arm64-apple-macos${DEPLOYMENT_TARGET}"

toolchain_dir() {
  # …/XcodeDefault.xctoolchain/usr/bin/swiftc → …/XcodeDefault.xctoolchain
  cd "$(dirname "$(xcrun --find swiftc)")/../.." && pwd
}

case "${1:-}" in
  prepare)
    TOOLCHAIN="$(toolchain_dir)"
    SRC="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"
    OUT="$REPO/build/appintents-protocols.json"
    mkdir -p "$REPO/build"
    # {"version":1,"constValueProtocols":[…]} → […] (the frontend rejects the wrapper form)
    python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["constValueProtocols"], open(sys.argv[2],"w"))' "$SRC" "$OUT"
    echo "$OUT"
    ;;

  extract)
    BINDIR="$2"; APP="$3"
    TOOLCHAIN="$(toolchain_dir)"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    XCODE_BUILD="$(xcodebuild -version | awk '/Build version/{print $3}')"

    SOURCES="$BINDIR/appintents-sources.txt"
    CONSTVALS="$BINDIR/appintents-constvals.txt"
    # Source paths must string-match what the compiler recorded (SwiftPM uses absolute paths).
    find "$REPO/app/Sources/$MODULE" -name '*.swift' | sort > "$SOURCES"
    if [ -f "$BINDIR/$MODULE.swiftconstvalues" ]; then
      # AUTHORITATIVE: the `-emit-const-values-path` single file the CURRENT build wrote to the bin
      # dir. Use ONLY it. Do NOT also glob the Intermediates tree — it ACCUMULATES stale
      # .swiftconstvalues from earlier builds/variants (e.g. a `-testable-` variant, or a build from
      # before a refactor), and appintentsmetadataprocessor UNIONS everything it's handed, which
      # silently re-adds deleted intents to the shipped Metadata.appintents. (That shipped the
      # removed "Get Answer from Mechanician" intent in 0.8.x.)
      echo "$BINDIR/$MODULE.swiftconstvalues" > "$CONSTVALS"
    else
      # Fallback only when the single file wasn't emitted (older/per-file backend layouts).
      {
        find "$BINDIR/$MODULE.build" -name '*.swiftconstvalues' 2>/dev/null || true
        find "$BINDIR/../../Intermediates.noindex/$MODULE.build" -name '*.swiftconstvalues' 2>/dev/null || true
      } | sort -u > "$CONSTVALS"
    fi
    if [ ! -s "$CONSTVALS" ]; then
      echo "appintents: no .swiftconstvalues found under $BINDIR — was the build run with the const-values flags?" >&2
      exit 1
    fi

    OUT="$("$(xcrun --find appintentsmetadataprocessor)" \
      --output "$APP/Contents/Resources" \
      --toolchain-dir "$TOOLCHAIN" \
      --module-name "$MODULE" \
      --sdk-root "$SDK" \
      --xcode-version "$XCODE_BUILD" \
      --platform-family macOS \
      --deployment-target "$DEPLOYMENT_TARGET" \
      --target-triple "$TRIPLE" \
      --source-file-list "$SOURCES" \
      --swift-const-vals-list "$CONSTVALS" 2>&1)" || { echo "$OUT" >&2; exit 1; }

    # The tool can exit 0 while producing nothing ("skipping writing output") or after
    # per-item errors — treat both as failure, like Bazel's rules_apple does.
    if echo "$OUT" | grep -qiE "error:|skipping writing output"; then
      echo "$OUT" >&2
      exit 1
    fi
    if [ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
      echo "$OUT" >&2
      echo "appintents: extractor reported success but wrote no extract.actionsdata" >&2
      exit 1
    fi
    ACTIONS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("actions",{})), "actions,", len(d.get("entities",{})), "entities")' "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null || echo "written")"
    echo "appintents: Metadata.appintents ✓ ($ACTIONS)"
    ;;

  *)
    echo "usage: appintents.sh prepare | extract <bin-dir> <app-bundle>" >&2
    exit 64
    ;;
esac
