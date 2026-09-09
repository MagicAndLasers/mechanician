#!/usr/bin/env bash
# Canonical local/CI verification for source changes. This command is intentionally publish-free.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

command -v node >/dev/null || { echo "!! Node.js 24+ is required" >&2; exit 1; }
command -v npm >/dev/null || { echo "!! npm is required" >&2; exit 1; }
command -v swift >/dev/null || { echo "!! the Swift 6.2 toolchain is required" >&2; exit 1; }

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 24 ] \
  || { echo "!! Node.js 24+ is required (found $(node --version))" >&2; exit 1; }

echo "==> shell syntax"
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$REPO" -path "$REPO/.git" -prune -o -path "$REPO/build" -prune -o \
  -path "$REPO/app/.build" -prune -o -path "$REPO/agentd/node_modules" -prune -o \
  -name '*.sh' -type f -print0)

echo "==> property lists"
plutil -lint "$REPO/app/Mechanician-Info.plist" >/dev/null

# A customer name written into a comment or a test fixture ships when this repository publishes.
# It has happened, and it came back two days after a hand sweep removed it, so it needs a gate
# rather than another sweep.
#
# The list of names cannot live here: writing it down in a public file is the leak it prevents.
# It is derived instead from the private tenant configuration, one directory per tenant, so adding
# a customer covers them automatically and nobody maintains a second list. With no private
# configuration present there is nothing to protect and nothing to learn, so the gate skips: a
# public fork stays green and is told only that the check did not run.
echo "==> customer names"
ENTERPRISE_CONFIG="${MECHANICIAN_ENTERPRISE_CONFIG:-}"
denylist_terms=""
if [ -n "$ENTERPRISE_CONFIG" ] && [ -d "$ENTERPRISE_CONFIG/tenants" ]; then
  for tenant in "$ENTERPRISE_CONFIG"/tenants/*/; do
    [ -d "$tenant" ] || continue
    denylist_terms="$denylist_terms
$(basename "$tenant")"
  done
fi
private_denylist=""
[ -z "$ENTERPRISE_CONFIG" ] || private_denylist="$ENTERPRISE_CONFIG/tenant-denylist.txt"
# Aliases a directory slug does not spell: a trading name, an acronym, a former name.
for extra in "${MECHANICIAN_TENANT_DENYLIST:-}" \
             "$private_denylist" \
             "$REPO/scripts/tenant-denylist.local.txt"; do
  [ -n "$extra" ] && [ -f "$extra" ] || continue
  denylist_terms="$denylist_terms
$(cat "$extra")"
done

denylist_hits=0
denylist_checked=0
while IFS= read -r term; do
  # Trim the ends only. Stripping every space would silently fuse a two-word trading name into
  # one that can never match, which reads as a passing check.
  term="$(printf '%s' "$term" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$term" in ''|'#'*) continue ;; esac
  denylist_checked=$((denylist_checked + 1))
  # -w so a name embedded in an unrelated word is not a hit, -i because the leak is often a
  # lowercased slug, -I so a binary fixture cannot fail the gate with an unreadable match.
  if git -C "$REPO" grep -Fwni -I -e "$term" -- . >/dev/null 2>&1; then
    echo "!! a tenant name appears in tracked files:" >&2
    git -C "$REPO" grep -Fwni -I -e "$term" -- . >&2
    denylist_hits=$((denylist_hits + 1))
  fi
done <<EOF
$denylist_terms
EOF

if [ "$denylist_hits" -gt 0 ]; then
  echo "!! name the deployment shape, not the customer (\"a managed Vertex deployment\")." >&2
  echo "!! for a fictional tenant in a test, the suite already uses Acme and Northwind." >&2
  exit 1
fi
if [ "$denylist_checked" -eq 0 ]; then
  echo "    skipped: no tenant configuration found, so no names to check"
else
  echo "    $denylist_checked name(s) checked, none present"
fi

# Ignore rules prevent accidental additions, but `git add -f` can still publish compiler records,
# bytecode, Finder metadata, or local environment files. These formats have carried developer paths
# and credentials in earlier history, so the tracked snapshot must reject them explicitly.
echo "==> forbidden generated and local files"
forbidden_tracked="$(
  git -C "$REPO" ls-files -- '*.dia' '*.pyc' '.DS_Store' '.env' '.env.*' \
    | grep -Ev '(^|/)\.env\.example$' \
    || true
)"
if [ -n "$forbidden_tracked" ]; then
  echo "!! generated or local-only files are tracked:" >&2
  printf '%s\n' "$forbidden_tracked" >&2
  exit 1
fi

# Three of the agentd tests spawn a PTY, and node-pty's `pty.node` is ad-hoc signed. macOS refuses to
# map an ad-hoc library into a process signed with a Team ID, so running this suite under the app's
# own Developer ID signed node — which is exactly what `node` resolves to in a shell hosted by
# Mechanician — fails those three every time. The error is a `Cannot find module
# './prebuilds/darwin-arm64//pty.node'` load failure, which reads like a missing file and is not one.
#
# That produced a whole day of chasing a phantom: the same three tests failing locally, passing in CI
# and passing individually, and being written off as flaky. Prefer an unsigned node here the way
# `dev.sh` already does for the same reason, and if the only node available is signed, say so instead
# of reporting three behavioural failures for a code-signing rule.
agentd_node_dir=""
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  if [ -x "$candidate" ] && ! codesign -dv "$candidate" 2>&1 | grep -q "TeamIdentifier=[^n]"; then
    agentd_node_dir="$(dirname "$candidate")"
    break
  fi
done
if [ -z "$agentd_node_dir" ] \
   && codesign -dv "$(command -v node)" 2>&1 | grep -q "TeamIdentifier=[^n]"; then
  echo "!! the only node on PATH is Team-ID signed ($(command -v node))." >&2
  echo "!! node-pty cannot load under it, so the three PTY tests would fail for that reason alone." >&2
  echo "!! install an unsigned node (brew install node) or run check.sh outside Mechanician." >&2
  exit 1
fi

echo "==> locked agentd install"
(
  cd "$REPO/agentd"
  [ -n "$agentd_node_dir" ] && PATH="$agentd_node_dir:$PATH" && export PATH
  echo "    node: $(command -v node) ($(node --version))"
  npm ci --ignore-scripts --no-audit --no-fund
  find node_modules/node-pty -name spawn-helper -exec chmod +x {} +
  npm test

  # The registry audit endpoint has occasionally timed out after the entire suite passed. Retry
  # only transport/service failures; a real advisory failure remains immediate and authoritative.
  audit_attempt=1
  while :; do
    if audit_output="$(npm audit --omit=dev --audit-level=high 2>&1)"; then
      printf '%s\n' "$audit_output"
      break
    else
      audit_status=$?
    fi
    printf '%s\n' "$audit_output" >&2
    if [[ "$audit_output" =~ (audit\ endpoint\ returned\ an\ error|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|socket\ hang\ up|503\ Service\ Unavailable|504\ Gateway\ Timeout|fetch\ failed) ]] \
       && [ "$audit_attempt" -lt 3 ]; then
      audit_attempt=$((audit_attempt + 1))
      echo "    npm audit transport failure; retrying (attempt $audit_attempt of 3)" >&2
      sleep 5
      continue
    fi
    exit "$audit_status"
  done
)

echo "==> Node source syntax"
while IFS= read -r -d '' source; do
  node --check "$source"
done < <(find "$REPO/agentd/src" "$REPO/agentd/test" -type f -name '*.mjs' -print0)

# The generated provider facts must match their source. Without this stage the generated files are
# simply a third hand-maintained copy: the daemon and the app could still be edited apart, which is
# exactly the drift that opened the daemon's preview-surface gate on two routes.
echo "==> generated provider facts"
node "$REPO/scripts/generate-provider-facts.mjs" --check

echo "==> Mechanician Help corpus"
while IFS= read -r -d '' source; do
  node --check "$source"
done < <(find "$REPO/scripts" -maxdepth 1 -type f -name '*.mjs' -print0)
node --test "$REPO/scripts/test/help-corpus.test.mjs"
node --test "$REPO/scripts/test/help-expertise.test.mjs"
node --test "$REPO/scripts/test/enterprise-packaging.test.mjs"
node --test "$REPO/scripts/test/runtime-wrappers.test.mjs"
node "$REPO/scripts/build-help-corpus.mjs" --check

echo "==> format spike evidence"
node --test "$REPO"/spike/format-r2/test/*.test.mjs

echo "==> bundled Codex version pins"
node --input-type=module - "$REPO" <<'NODE'
import fs from 'node:fs'
import path from 'node:path'

const repo = process.argv[2]
const packageVersion = JSON.parse(fs.readFileSync(path.join(repo, 'agentd/package.json')))
  .dependencies['@openai/codex']
const extract = (file, expression, label) => {
  const match = fs.readFileSync(path.join(repo, file), 'utf8').match(expression)
  if (!match) throw new Error(`could not read ${label} from ${file}`)
  return match[1]
}
const pins = {
  package: packageVersion,
  JavaScript: extract('agentd/src/codex-runtime.mjs', /BUNDLED_CODEX_VERSION\s*=\s*['"]([^'"]+)/, 'JavaScript pin'),
  Swift: extract('app/Sources/Mechanician/CodexRuntime.swift', /bundledVersion\s*=\s*"([^"]+)/, 'Swift pin'),
  packaging: extract('build-app.sh', /BUNDLED_CODEX_VERSION="([^"]+)/, 'packaging pin'),
  staging: extract('scripts/stage-agentd.sh', /EXPECTED_CODEX_VERSION="([^"]+)/, 'staging pin'),
}
const drift = Object.entries(pins).filter(([, value]) => value !== packageVersion)
if (drift.length) throw new Error(`Codex version drift: ${JSON.stringify(pins)}`)
console.log(`    ${packageVersion} across package, JavaScript, Swift, staging, and packaging`)
NODE

echo "==> production dependency stage"
PACKAGE_CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-package-check.XXXXXX")"
cleanup_package_check() { rm -rf "$PACKAGE_CHECK_ROOT"; }
trap cleanup_package_check EXIT
"$REPO/scripts/stage-agentd.sh" "$PACKAGE_CHECK_ROOT/agentd"
node --input-type=module - "$PACKAGE_CHECK_ROOT/agentd/agentd-sbom.cdx.json" <<'NODE'
import fs from 'node:fs'
const bom = JSON.parse(fs.readFileSync(process.argv[2]))
const components = new Map((bom.components ?? []).map((component) => [component.name, component.version]))
if (!components.has('@openai/codex') || !components.has('@openai/codex-darwin-arm64')) {
  throw new Error('production SBOM is missing the Codex package or its Darwin arm64 runtime')
}
NODE
rm -rf "$PACKAGE_CHECK_ROOT"
trap - EXIT

echo "==> Swift tests (macOS arm64)"
# Capture the test run's output as well as showing it: the compiler emits its diagnostics during
# this build, so the warning budget can read them from here instead of compiling the module a
# second time. Locally, invalidate first — an incremental build compiles nothing and would report
# no warnings at all.
SWIFT_LOG="$(mktemp "${TMPDIR:-/tmp}/mechanician-swift.XXXXXX")"
cleanup_swift_log() { rm -f "$SWIFT_LOG"; }
trap cleanup_swift_log EXIT
# `if`, not `[ … ] && …`: under `set -e` the latter exits the whole script on a fresh checkout,
# where there is no build to invalidate and nothing needed doing.
if [ -d "$REPO/app/.build" ]; then
  find "$REPO/app/Sources" -name '*.swift' -exec touch {} +
fi
(
  cd "$REPO/app"
  swift test --arch arm64
) 2>&1 | tee "$SWIFT_LOG"
swift_status="${PIPESTATUS[0]}"
[ "$swift_status" -eq 0 ] || exit "$swift_status"

"$REPO/scripts/verify-upgrade-proof.sh" --log "$SWIFT_LOG"

echo "==> Swift warning budget"
"$REPO/scripts/warning-budget.sh" --log "$SWIFT_LOG"

"$REPO/scripts/localization-baseline.sh"

echo "==> whitespace"
git -C "$REPO" diff --check

echo "==> all checks passed"
