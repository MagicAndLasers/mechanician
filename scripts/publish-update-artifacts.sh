#!/usr/bin/env bash
# Publish immutable release objects and reconcile the two mutable Stable download aliases.
#
# Versioned release objects are write-once. A repeated invocation succeeds only when the
# already-published object is byte-for-byte identical to the local input. Stable aliases are
# deliberately mutable, but only after the signed live appcast names the requested build as the
# newest default-channel release; destination-generation preconditions prevent concurrent writers
# from silently overwriting one another.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="${MECHANICIAN_UPDATE_BUCKET:-gs://mechanician-updates}"
ARTIFACT_NAME="${MECHANICIAN_ARTIFACT_NAME:-Mechanician}"
SPARKLE_ACCOUNT="${MECHANICIAN_SPARKLE_ACCOUNT:-ed25519}"
GCLOUD="${MECHANICIAN_GCLOUD:-gcloud}"
XMLLINT="${MECHANICIAN_XMLLINT:-/usr/bin/xmllint}"
XSLTPROC="${MECHANICIAN_XSLTPROC:-/usr/bin/xsltproc}"
SIGN_UPDATE="${MECHANICIAN_SIGN_UPDATE:-$REPO/app/.build/artifacts/sparkle/Sparkle/bin/sign_update}"

BUCKET="${BUCKET%/}"
LATEST_ZIP="$ARTIFACT_NAME-latest.zip"
LATEST_DMG="$ARTIFACT_NAME-latest.dmg"

die() {
  echo "!! $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: scripts/publish-update-artifacts.sh upload-immutable <local-file> <object-name>
       scripts/publish-update-artifacts.sh object-facts <object-name>
       scripts/publish-update-artifacts.sh reconcile-stable-aliases <version> <build> [<zip-generation> <zip-crc32c> <dmg-generation> <dmg-crc32c>]

upload-immutable creates a versioned bucket object exactly once. If the object
already exists, success requires byte-for-byte equality with the local file.

reconcile-stable-aliases updates the stable ZIP and DMG aliases from their
versioned objects only while the signed live appcast names that version/build as
the newest default-channel release. It is safe to rerun after a partial failure.
EOF
}

[[ "$BUCKET" =~ ^gs://[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die "MECHANICIAN_UPDATE_BUCKET must be a canonical gs:// bucket or bucket path"
[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "MECHANICIAN_ARTIFACT_NAME must be filesystem/URL safe"
command -v "$GCLOUD" >/dev/null || die "gcloud is required"
command -v node >/dev/null || die "Node.js is required"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-update-publisher.XXXXXX")"
cleanup_work_root() { /bin/rm -rf "$WORK_ROOT"; }
trap cleanup_work_root EXIT

validate_object_name() {
  local object="$1"
  [ -n "$object" ] || die "bucket object name must not be empty"
  [ "$object" = "$(basename "$object")" ] || die "bucket object must be a root object: $object"
  case "$object" in
    .*|*/*|*\\*|*$'\t'*|*$'\r'*|*$'\n'*) die "invalid bucket object name: $object" ;;
  esac
}

# Prints generation, size, CRC32C, recorded version, recorded build, recorded source generation,
# recorded source CRC32C, cache policy, and object name as a tab-separated row. Keeping the empty metadata
# columns is important: cut(1), unlike shell IFS parsing, does not collapse adjacent tabs.
describe_object() {
  local object="$1"
  "$GCLOUD" storage objects describe "$BUCKET/$object" \
    --format='json(generation,size,crc32c_hash,custom_fields,cache_control,name)' \
    | node -e '
      let input = ""
      process.stdin.setEncoding("utf8")
      process.stdin.on("data", chunk => { input += chunk })
      process.stdin.on("end", () => {
        const object = JSON.parse(input)
        const fields = object.custom_fields ?? {}
        const values = [
          object.generation,
          object.size,
          object.crc32c_hash,
          fields["mechanician-version"],
          fields["mechanician-build"],
          fields["mechanician-source-generation"],
          fields["mechanician-source-crc32c"],
          object.cache_control,
          object.name,
        ]
        process.stdout.write(values.map(value => value ?? "").join("\t") + "\n")
      })
    '
}

describe_version() {
  local object="$1" generation="$2"
  "$GCLOUD" storage objects describe "$BUCKET/$object#$generation" \
    --format='value(generation,size,crc32c_hash)'
}

field() {
  printf '%s\n' "$1" | /usr/bin/cut -f"$2"
}

verify_existing_exact() {
  local local_file="$1" object="$2" row generation size after download_dir download
  row="$(describe_object "$object")" || return 1
  generation="$(field "$row" 1)"
  size="$(field "$row" 2)"
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || die "published object has no valid generation: $object"
  [[ "$size" =~ ^[0-9]+$ ]] || die "published object has no valid size: $object"
  [ "$size" = "$(/usr/bin/stat -f '%z' "$local_file")" ] \
    || die "immutable object already exists with different bytes: $object (size mismatch)"

  download_dir="$(mktemp -d "$WORK_ROOT/object.XXXXXX")"
  download="$download_dir/$object"
  "$GCLOUD" storage cp "$BUCKET/$object" "$download"
  after="$(describe_object "$object")" \
    || die "immutable object disappeared while it was being verified: $object"
  [ "$(field "$after" 1)" = "$generation" ] \
    || die "immutable object changed generation while it was being verified: $object"
  /usr/bin/cmp -s "$local_file" "$download" \
    || die "immutable object already exists with different bytes: $object"
  echo "    immutable object already exists with exact bytes: $object"
}

upload_immutable() {
  local local_file="$1" object="$2" row
  [ -f "$local_file" ] || die "local release artifact is missing: $local_file"
  validate_object_name "$object"

  if describe_object "$object" >/dev/null 2>&1; then
    verify_existing_exact "$local_file" "$object"
    return
  fi

  if ! "$GCLOUD" storage cp --if-generation-match=0 "$local_file" "$BUCKET/$object"; then
    # Another release process may have won the create-only race. It is an idempotent success only
    # when that winner published exactly the same bytes.
    verify_existing_exact "$local_file" "$object" \
      || die "could not create immutable object: $object"
    return
  fi
  # Verify the generation-stable remote bytes, not only the size. This also fails closed if an
  # operator or competing process replaces the object immediately after our create-only write.
  verify_existing_exact "$local_file" "$object"
  echo "    created immutable object: $object"
}

object_facts() {
  local object="$1" row
  validate_object_name "$object"
  row="$(describe_object "$object")" || die "published object is missing: $object"
  [[ "$(field "$row" 1)" =~ ^[1-9][0-9]*$ ]] || die "published object has no valid generation: $object"
  [ -n "$(field "$row" 3)" ] || die "published object has no CRC32C: $object"
  printf '%s\t%s\n' "$(field "$row" 1)" "$(field "$row" 3)"
}

snapshot_live_stable() {
  local output="$1" before after stylesheet summary exact_count
  [ -x "$SIGN_UPDATE" ] || die "Sparkle sign_update is required at $SIGN_UPDATE"
  [ -x "$XMLLINT" ] || die "xmllint is required at $XMLLINT"
  [ -x "$XSLTPROC" ] || die "xsltproc is required at $XSLTPROC"

  before="$(describe_object appcast.xml)" || die "could not describe the live appcast"
  "$GCLOUD" storage cp "$BUCKET/appcast.xml" "$output" >/dev/null
  after="$(describe_object appcast.xml)" || die "could not re-describe the live appcast"
  [ "$(field "$before" 1)" = "$(field "$after" 1)" ] \
    || die "the live appcast changed while Stable aliases were being reconciled"
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$output" >/dev/null \
    || die "the live appcast signature is invalid"
  "$XMLLINT" --nonet --noout "$output" 2>/dev/null \
    || die "the live appcast is not well-formed XML"

  stylesheet="${output}.stable-head.xslt"
  /bin/cat > "$stylesheet" <<'XSLT'
<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <xsl:output method="text"/>
  <xsl:template match="/">
    <xsl:for-each select="/rss/channel/item[not(sparkle:channel)]">
      <xsl:sort select="number(sparkle:version)" data-type="number" order="descending"/>
      <xsl:if test="position() = 1">
        <xsl:value-of select="sparkle:version"/><xsl:text>&#9;</xsl:text>
        <xsl:value-of select="sparkle:shortVersionString"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>
</xsl:stylesheet>
XSLT
  summary="$("$XSLTPROC" --nonet "$stylesheet" "$output")" \
    || die "could not identify the live Stable release"
  [ -n "$summary" ] || die "the live appcast has no default-channel release"
  [[ "$(field "$summary" 1)" =~ ^[1-9][0-9]*$ ]] \
    || die "the live Stable release has an invalid build"
  [[ "$(field "$summary" 2)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "the live Stable release has an invalid version"
  exact_count="$("$XMLLINT" --nonet --xpath \
    "count(/rss/channel/item[*[local-name()='version' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle' and text()='$(field "$summary" 1)'] and *[local-name()='shortVersionString' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle' and text()='$(field "$summary" 2)'] and not(*[local-name()='channel' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle'])])" \
    "$output" 2>/dev/null)" || die "could not validate the live Stable release"
  [ "$exact_count" = "1" ] || die "the live Stable release is ambiguous"
  printf '%s\n' "$summary"
}

alias_is_exact() {
  local alias="$1" version="$2" build="$3" source_generation="$4" source_size="$5" source_crc="$6"
  local row
  row="$(describe_object "$alias")" || return 1
  [ "$(field "$row" 2)" = "$source_size" ] \
    && [ "$(field "$row" 3)" = "$source_crc" ] \
    && [ "$(field "$row" 4)" = "$version" ] \
    && [ "$(field "$row" 5)" = "$build" ] \
    && [ "$(field "$row" 6)" = "$source_generation" ] \
    && [ "$(field "$row" 7)" = "$source_crc" ] \
    && [ "$(field "$row" 8)" = "no-cache, max-age=0" ]
}

live_stable_is() {
  local version="$1" build="$2" feed="$3" summary
  summary="$(snapshot_live_stable "$feed")"
  [ "$(field "$summary" 1)" = "$build" ] && [ "$(field "$summary" 2)" = "$version" ]
}

reconcile_alias() {
  local source="$1" alias="$2" version="$3" build="$4" work="$5" expected_generation="${6:-}" expected_crc="${7:-}"
  local source_row source_generation source_size source_crc current_source alias_row alias_generation alias_build attempt feed
  source_row="$(describe_object "$source")" || die "Stable source object is missing: $source"
  source_generation="$(field "$source_row" 1)"
  source_size="$(field "$source_row" 2)"
  source_crc="$(field "$source_row" 3)"
  [[ "$source_generation" =~ ^[1-9][0-9]*$ ]] || die "Stable source has no valid generation: $source"
  [[ "$source_size" =~ ^[1-9][0-9]*$ ]] || die "Stable source has no valid size: $source"
  [ -n "$source_crc" ] || die "Stable source has no CRC32C: $source"
  if [ -n "$expected_generation" ] || [ -n "$expected_crc" ]; then
    [[ "$expected_generation" =~ ^[1-9][0-9]*$ ]] \
      || die "expected source generation is invalid: $source"
    [ -n "$expected_crc" ] || die "expected source CRC32C is missing: $source"
    [ "$source_generation" = "$expected_generation" ] && [ "$source_crc" = "$expected_crc" ] \
      || die "immutable Stable source no longer matches the validated generation: $source"
  fi

  if alias_is_exact "$alias" "$version" "$build" "$source_generation" "$source_size" "$source_crc"; then
    echo "    Stable alias already names the exact source generation: $alias"
    return
  fi

  attempt=1
  while [ "$attempt" -le 5 ]; do
    feed="$work/appcast-alias-$attempt.xml"
    live_stable_is "$version" "$build" "$feed" \
      || die "live Stable release is no longer $version ($build); refusing to move $alias"
    current_source="$(describe_version "$source" "$source_generation")" \
      || die "immutable Stable source generation disappeared: $source#$source_generation"
    [ "$(field "$current_source" 1)" = "$source_generation" ] \
      && [ "$(field "$current_source" 2)" = "$source_size" ] \
      && [ "$(field "$current_source" 3)" = "$source_crc" ] \
      || die "immutable Stable source changed while aliases were being reconciled: $source"

    if alias_row="$(describe_object "$alias" 2>/dev/null)"; then
      alias_generation="$(field "$alias_row" 1)"
      alias_build="$(field "$alias_row" 5)"
      if [[ "$alias_build" =~ ^[1-9][0-9]*$ ]] && [ "$alias_build" -gt "$build" ]; then
        die "Stable alias already names newer build $alias_build; refusing rollback to $build: $alias"
      fi
    else
      alias_generation=0
    fi
    if "$GCLOUD" storage cp \
      --cache-control='no-cache, max-age=0' \
      --custom-metadata="mechanician-version=$version,mechanician-build=$build,mechanician-source-generation=$source_generation,mechanician-source-crc32c=$source_crc" \
      "--if-generation-match=$alias_generation" \
      "$BUCKET/$source#$source_generation" "$BUCKET/$alias"; then
      alias_is_exact "$alias" "$version" "$build" "$source_generation" "$source_size" "$source_crc" \
        || die "Stable alias does not match its immutable source after copy: $alias"
      echo "    reconciled Stable alias: $alias"
      return
    fi

    # A competing process may have performed the same copy. Accept only that exact result; any
    # other conflict is retried after another signed-feed check.
    if alias_is_exact "$alias" "$version" "$build" "$source_generation" "$source_size" "$source_crc"; then
      echo "    competing process reconciled the exact Stable alias: $alias"
      return
    fi
    attempt=$((attempt + 1))
  done
  die "could not reconcile Stable alias after 5 generation conflicts: $alias"
}

reconcile_stable_aliases() {
  local version="$1" build="$2" zip_generation="${3:-}" zip_crc="${4:-}" dmg_generation="${5:-}" dmg_crc="${6:-}" work feed
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be numeric semantic version"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] || die "build must be a positive integer"
  work="$(mktemp -d "$WORK_ROOT/aliases.XXXXXX")"
  feed="$work/appcast-initial.xml"
  live_stable_is "$version" "$build" "$feed" \
    || die "live Stable release is not $version ($build); aliases remain unchanged"

  if [ -n "$zip_generation" ] || [ -n "$dmg_generation" ]; then
    local zip_row dmg_row
    zip_row="$(describe_object "$ARTIFACT_NAME-$version.zip")" \
      || die "validated Stable ZIP source is missing"
    dmg_row="$(describe_object "$ARTIFACT_NAME-$version.dmg")" \
      || die "validated Stable DMG source is missing"
    [ "$(field "$zip_row" 1)" = "$zip_generation" ] && [ "$(field "$zip_row" 3)" = "$zip_crc" ] \
      || die "immutable Stable source no longer matches the validated generation: $ARTIFACT_NAME-$version.zip"
    [ "$(field "$dmg_row" 1)" = "$dmg_generation" ] && [ "$(field "$dmg_row" 3)" = "$dmg_crc" ] \
      || die "immutable Stable source no longer matches the validated generation: $ARTIFACT_NAME-$version.dmg"
  fi

  reconcile_alias "$ARTIFACT_NAME-$version.dmg" "$LATEST_DMG" "$version" "$build" "$work" "$dmg_generation" "$dmg_crc"
  reconcile_alias "$ARTIFACT_NAME-$version.zip" "$LATEST_ZIP" "$version" "$build" "$work" "$zip_generation" "$zip_crc"
}

MODE="${1:-}"
case "$MODE" in
  upload-immutable)
    [ "$#" -eq 3 ] || { usage >&2; exit 64; }
    upload_immutable "$2" "$3"
    ;;
  object-facts)
    [ "$#" -eq 2 ] || { usage >&2; exit 64; }
    object_facts "$2"
    ;;
  reconcile-stable-aliases)
    [ "$#" -eq 3 ] || [ "$#" -eq 7 ] || { usage >&2; exit 64; }
    reconcile_stable_aliases "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
