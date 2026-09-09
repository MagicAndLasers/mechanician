#!/usr/bin/env bash
# Stage only the full archives that the live Sparkle feed needs, then prove that
# generate_appcast preserved every compatibility branch before publishing it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="${MECHANICIAN_UPDATE_BUCKET:-gs://mechanician-updates}"
URL_PREFIX="${MECHANICIAN_UPDATE_URL_PREFIX:-https://storage.googleapis.com/mechanician-updates/}"
ARTIFACT_NAME="${MECHANICIAN_ARTIFACT_NAME:-Mechanician}"
SPARKLE_ACCOUNT="${MECHANICIAN_SPARKLE_ACCOUNT:-ed25519}"
GCLOUD="${MECHANICIAN_GCLOUD:-gcloud}"
XMLLINT="${MECHANICIAN_XMLLINT:-/usr/bin/xmllint}"
SIGN_UPDATE="${MECHANICIAN_SIGN_UPDATE:-$REPO/app/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
SPARKLE_NS="http://www.andymatuschak.org/xml-namespaces/sparkle"
MAX_FEED_BYTES=10485760
MAX_BRANCHES=64
MAX_DELTAS_PER_ITEM=32
MAX_ARCHIVE_BYTES=17179869184

die() {
  echo "!! $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: scripts/stage-update-history.sh stage <stage-dir>
       scripts/stage-update-history.sh preserve-unaffected <stage-dir> <build>
       scripts/stage-update-history.sh prepare-promotion <stage-dir> <build> <version>
       scripts/stage-update-history.sh verify-promotion <stage-dir> <build> <version>
       scripts/stage-update-history.sh verify-transition <stage-dir> <build> <version> <stable|daily>
       scripts/stage-update-history.sh verify-remote <stage-dir>
       scripts/stage-update-history.sh publish <stage-dir>

stage downloads a stable live appcast snapshot and only its direct full ZIP
enclosures. prepare-promotion rewrites one exact Daily item as Stable and prints
either promotion-required or already-promoted. verify-transition validates a
new generate_appcast candidate; verify-promotion validates the exact promotion
rewrite. verify-remote proves every candidate enclosure exists before publish
performs a generation-matched appcast update.
EOF
}

preserve_unaffected() {
  local stage="$1" new_build="$2" before candidate stylesheet output items deltas root_delta object
  [[ "$new_build" =~ ^[1-9][0-9]*$ ]] || die "new build must be a positive integer"
  before="$stage/.appcast-before.xml"
  candidate="$stage/appcast.xml"
  [ -s "$before" ] || die "staged source appcast is missing"
  [ -s "$candidate" ] || die "generated candidate appcast is missing"
  command -v /usr/bin/xsltproc >/dev/null || die "xsltproc is required"
  stylesheet="$(mktemp "${TMPDIR:-/tmp}/mechanician-preserve-feed.xslt.XXXXXX")"
  output="$(mktemp "${TMPDIR:-/tmp}/mechanician-preserve-feed.xml.XXXXXX")"
  cleanup_preserve_feed() { rm -f "$stylesheet" "$output"; }
  trap cleanup_preserve_feed RETURN
  /bin/cat > "$stylesheet" <<'XSLT'
<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <xsl:output method="xml" indent="yes"/>
  <xsl:param name="before"/>
  <xsl:param name="newBuild"/>
  <xsl:variable name="old" select="document($before)"/>
  <xsl:template match="@*|node()">
    <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
  </xsl:template>
  <xsl:template match="item">
    <xsl:variable name="build" select="string(sparkle:version)"/>
    <xsl:choose>
      <xsl:when test="$build != $newBuild and $old/rss/channel/item[sparkle:version = $build]">
        <xsl:copy-of select="$old/rss/channel/item[sparkle:version = $build]"/>
      </xsl:when>
      <xsl:otherwise><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:otherwise>
    </xsl:choose>
  </xsl:template>
</xsl:stylesheet>
XSLT
  /usr/bin/xsltproc --nonet --stringparam before "$before" --stringparam newBuild "$new_build" \
    "$stylesheet" "$candidate" > "$output" \
    || die "could not restore unaffected appcast items"
  /usr/bin/xmllint --nonet --noout "$output" 2>/dev/null \
    || die "restored candidate appcast is not well-formed XML"
  /bin/mv "$output" "$candidate"
  rm -f "$stylesheet"
  trap - RETURN

  # generate_appcast creates fresh deltas for every staged branch leader, even though the XSLT
  # just restored all unaffected items byte-for-byte. Delete only those newly generated root
  # deltas that the restored candidate no longer references; referenced new-build deltas remain.
  items="$(mktemp "${TMPDIR:-/tmp}/mechanician-preserve-items.tsv.XXXXXX")"
  deltas="$(mktemp "${TMPDIR:-/tmp}/mechanician-preserve-deltas.tsv.XXXXXX")"
  parse_feed "$candidate" "$items" "$deltas" "restored candidate appcast"
  shopt -s nullglob
  for root_delta in "$stage"/*.delta; do
    object="$(basename "$root_delta")"
    /usr/bin/awk -F '\t' -v object="$object" \
      '$3 == object { found=1 } END { exit !found }' "$deltas" \
      || rm -f "$root_delta"
  done
  rm -f "$items" "$deltas"
}

case "$URL_PREFIX" in */) ;; *) URL_PREFIX="$URL_PREFIX/" ;; esac
BUCKET="${BUCKET%/}"

[[ "$BUCKET" =~ ^gs://[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die "MECHANICIAN_UPDATE_BUCKET must be a canonical gs:// bucket or bucket path"
[[ "$URL_PREFIX" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/$ ]] \
  || die "MECHANICIAN_UPDATE_URL_PREFIX must be a canonical HTTPS directory URL"
[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "MECHANICIAN_ARTIFACT_NAME must be filesystem/URL safe"
xml_count() {
  "$XMLLINT" --nonet --xpath "count($2)" "$1" 2>/dev/null
}

xml_string() {
  "$XMLLINT" --nonet --xpath "string($2)" "$1" 2>/dev/null
}

require_single_node() {
  local feed="$1" xpath="$2" label="$3" count
  count="$(xml_count "$feed" "$xpath")" || die "cannot read $label"
  [ "$count" = "1" ] || die "$label must appear exactly once"
}

reject_control_characters() {
  local value="$1" label="$2"
  case "$value" in
    *$'\t'*|*$'\r'*|*$'\n'*) die "$label contains a control character" ;;
  esac
}

manifest_field() {
  printf '%s\n' "$1" | /usr/bin/cut -f"$2"
}

branch_from_line() {
  printf '%s\n' "$1" | /usr/bin/cut -f7-12
}

decode_url_path_segment() {
  # Sparkle derives delta names from the .app basename, which may be tenant-branded and contain
  # spaces. Decode its single URL path segment instead of guessing a prefix from release settings.
  /usr/bin/perl -MURI::Escape -e '
    use strict;
    use warnings;
    my $encoded = shift;
    exit 2 if !defined($encoded) || $encoded eq q{} || $encoded =~ /%(?![0-9A-Fa-f]{2})/;
    my $decoded = uri_unescape($encoded);
    exit 2 if $decoded =~ m{[/\\]} || $decoded =~ /[\x00-\x1F\x7F]/ || $decoded =~ /^\./;
    print $decoded;
  ' -- "$1"
}

# Writes one tab-separated item row per compatibility branch:
# build, short version, object, URL, length, signature, then Sparkle's exact
# six-field UpdateBranch tuple. The delta manifest uses the same shape, with
# deltaFrom in column 2.
parse_feed() {
  local feed="$1" items="$2" deltas="$3" label="$4"
  local item_count all_item_count i item direct_count delta_container_count
  local delta_count all_enclosure_count build short object url length signature expected_url
  local min_update min_os max_os min_auto hardware channel branch existing d from encoded_object suffix
  local feed_bytes

  [ -s "$feed" ] || die "$label is empty"
  feed_bytes="$(/usr/bin/stat -f '%z' "$feed")"
  [ "$feed_bytes" -le "$MAX_FEED_BYTES" ] || die "$label exceeds the $MAX_FEED_BYTES-byte safety limit"
  "$XMLLINT" --nonet --noout "$feed" 2>/dev/null || die "$label is not well-formed XML"
  [ "$(xml_count "$feed" '/rss/channel')" = "1" ] \
    || die "$label must contain exactly one RSS channel"
  item_count="$(xml_count "$feed" '/rss/channel/item')"
  all_item_count="$(xml_count "$feed" '//*[local-name()="item"]')"
  [[ "$item_count" =~ ^[1-9][0-9]*$ ]] && [ "$item_count" = "$all_item_count" ] \
    || die "$label must contain at least one direct channel item and no nested items"
  [ "$item_count" -le "$MAX_BRANCHES" ] \
    || die "$label exceeds the $MAX_BRANCHES-branch safety limit"

  : > "$items"
  : > "$deltas"
  i=1
  while [ "$i" -le "$item_count" ]; do
    item="(/rss/channel/item)[$i]"
    direct_count="$(xml_count "$feed" "$item/enclosure")"
    [ "$direct_count" = "1" ] || die "$label item $i must have exactly one direct enclosure"
    delta_container_count="$(xml_count "$feed" "$item/*[local-name()='deltas' and namespace-uri()='$SPARKLE_NS']")"
    [ "$delta_container_count" = "0" ] || [ "$delta_container_count" = "1" ] \
      || die "$label item $i has duplicate delta containers"
    delta_count="$(xml_count "$feed" "$item/*[local-name()='deltas' and namespace-uri()='$SPARKLE_NS']/enclosure")"
    [ "$delta_count" -le "$MAX_DELTAS_PER_ITEM" ] \
      || die "$label item $i exceeds the $MAX_DELTAS_PER_ITEM-delta safety limit"
    all_enclosure_count="$(xml_count "$feed" "$item//*[local-name()='enclosure']")"
    [ "$all_enclosure_count" = "$((1 + delta_count))" ] \
      || die "$label item $i contains an enclosure outside the supported locations"

    require_single_node "$feed" "$item/*[local-name()='version' and namespace-uri()='$SPARKLE_NS']" "$label item $i Sparkle build"
    require_single_node "$feed" "$item/*[local-name()='shortVersionString' and namespace-uri()='$SPARKLE_NS']" "$label item $i short version"
    require_single_node "$feed" "$item/*[local-name()='minimumSystemVersion' and namespace-uri()='$SPARKLE_NS']" "$label item $i minimum system version"
    require_single_node "$feed" "$item/enclosure/@url" "$label item $i enclosure URL"
    require_single_node "$feed" "$item/enclosure/@length" "$label item $i enclosure length"
    require_single_node "$feed" "$item/enclosure/@*[local-name()='edSignature' and namespace-uri()='$SPARKLE_NS']" "$label item $i enclosure EdDSA signature"

    build="$(xml_string "$feed" "$item/*[local-name()='version' and namespace-uri()='$SPARKLE_NS']")"
    short="$(xml_string "$feed" "$item/*[local-name()='shortVersionString' and namespace-uri()='$SPARKLE_NS']")"
    min_os="$(xml_string "$feed" "$item/*[local-name()='minimumSystemVersion' and namespace-uri()='$SPARKLE_NS']")"
    url="$(xml_string "$feed" "$item/enclosure/@url")"
    length="$(xml_string "$feed" "$item/enclosure/@length")"
    signature="$(xml_string "$feed" "$item/enclosure/@*[local-name()='edSignature' and namespace-uri()='$SPARKLE_NS']")"

    [[ "$build" =~ ^[1-9][0-9]*$ ]] || die "$label item $i has an invalid Sparkle build"
    [[ "$short" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$label item $i has an invalid short version"
    [[ "$min_os" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "$label item $i has an invalid minimum system version"
    [[ "$length" =~ ^[1-9][0-9]*$ ]] || die "$label item $i has an invalid enclosure length"
    [ "$length" -le "$MAX_ARCHIVE_BYTES" ] \
      || die "$label item $i enclosure exceeds the $MAX_ARCHIVE_BYTES-byte safety limit"
    [[ "$signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
      || die "$label item $i has an invalid EdDSA signature"
    object="$ARTIFACT_NAME-$short.zip"
    expected_url="$URL_PREFIX$object"
    [ "$url" = "$expected_url" ] \
      || die "$label item $i enclosure URL is not canonical: $url"

    min_update=""
    max_os=""
    min_auto=""
    hardware=""
    channel=""
    for branch in \
      "minimumUpdateVersion:min_update" \
      "maximumSystemVersion:max_os" \
      "minimumAutoupdateVersion:min_auto" \
      "hardwareRequirements:hardware" \
      "channel:channel"; do
      d="${branch%%:*}"
      existing="$(xml_count "$feed" "$item/*[local-name()='$d' and namespace-uri()='$SPARKLE_NS']")"
      [ "$existing" = "0" ] || [ "$existing" = "1" ] \
        || die "$label item $i has duplicate $d values"
      if [ "$existing" = "1" ]; then
        from="$(xml_string "$feed" "$item/*[local-name()='$d' and namespace-uri()='$SPARKLE_NS']")"
        [ -n "$from" ] || die "$label item $i has an empty $d value"
        reject_control_characters "$from" "$label item $i $d"
        case "${branch##*:}" in
          min_update) min_update="$from" ;;
          max_os) max_os="$from" ;;
          min_auto) min_auto="$from" ;;
          hardware) hardware="$from" ;;
          channel) channel="$from" ;;
        esac
      fi
    done

    if /usr/bin/awk -F '\t' -v build="$build" -v object="$object" -v url="$url" \
      -v a="$min_update" -v b="$min_os" -v c="$max_os" -v d="$min_auto" \
      -v e="$hardware" -v f="$channel" \
      '$1 == build || $3 == object || $4 == url || ($7 == a && $8 == b && $9 == c && $10 == d && $11 == e && $12 == f) { found=1 } END { exit !found }' \
      "$items"; then
      die "$label contains a duplicate build, object, URL, or compatibility branch"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$build" "$short" "$object" "$url" "$length" "$signature" \
      "$min_update" "$min_os" "$max_os" "$min_auto" "$hardware" "$channel" >> "$items"

    d=1
    while [ "$d" -le "$delta_count" ]; do
      branch="$item/*[local-name()='deltas' and namespace-uri()='$SPARKLE_NS']/enclosure[$d]"
      require_single_node "$feed" "$branch/@url" "$label item $i delta $d URL"
      require_single_node "$feed" "$branch/@length" "$label item $i delta $d length"
      require_single_node "$feed" "$branch/@*[local-name()='edSignature' and namespace-uri()='$SPARKLE_NS']" "$label item $i delta $d EdDSA signature"
      require_single_node "$feed" "$branch/@*[local-name()='deltaFrom' and namespace-uri()='$SPARKLE_NS']" "$label item $i delta $d source build"
      url="$(xml_string "$feed" "$branch/@url")"
      length="$(xml_string "$feed" "$branch/@length")"
      signature="$(xml_string "$feed" "$branch/@*[local-name()='edSignature' and namespace-uri()='$SPARKLE_NS']")"
      from="$(xml_string "$feed" "$branch/@*[local-name()='deltaFrom' and namespace-uri()='$SPARKLE_NS']")"
      [[ "$from" =~ ^[1-9][0-9]*$ ]] || die "$label item $i delta $d has an invalid source build"
      [ "$from" -lt "$build" ] || die "$label item $i delta $d source build must be older than its target"
      [[ "$length" =~ ^[1-9][0-9]*$ ]] || die "$label item $i delta $d has an invalid length"
      [ "$length" -le "$MAX_ARCHIVE_BYTES" ] \
        || die "$label item $i delta $d exceeds the $MAX_ARCHIVE_BYTES-byte safety limit"
      [[ "$signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
        || die "$label item $i delta $d has an invalid EdDSA signature"
      case "$url" in
        "$URL_PREFIX"*) encoded_object="${url#"$URL_PREFIX"}" ;;
        *) die "$label item $i delta $d URL is not on the configured update origin: $url" ;;
      esac
      case "$encoded_object" in
        *'/'*|*\\*|*'?'*|*'#'*|*[[:space:]]*)
          die "$label item $i delta $d URL is not a canonical root object: $url"
          ;;
      esac
      if ! object="$(decode_url_path_segment "$encoded_object")"; then
        die "$label item $i delta $d URL has an invalid encoded object name: $url"
      fi
      suffix="$build-$from.delta"
      case "$object" in
        ?*"$suffix") ;;
        *) die "$label item $i delta $d object does not match its build pair: $object" ;;
      esac
      if /usr/bin/awk -F '\t' -v object="$object" -v url="$url" \
        '$3 == object || $4 == url { found=1 } END { exit !found }' "$deltas" \
        || /usr/bin/awk -F '\t' -v object="$object" -v url="$url" \
          '$3 == object || $4 == url { found=1 } END { exit !found }' "$items"; then
        die "$label contains a duplicate enclosure object or URL"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$build" "$from" "$object" "$url" "$length" "$signature" \
        "$min_update" "$min_os" "$max_os" "$min_auto" "$hardware" "$channel" >> "$deltas"
      d=$((d + 1))
    done
    i=$((i + 1))
  done
}

verify_local_enclosure() {
  local archive="$1" length="$2" signature="$3" actual
  [ -f "$archive" ] || die "referenced update archive is missing locally: $archive"
  actual="$(/usr/bin/stat -f '%z' "$archive")"
  [ "$actual" = "$length" ] \
    || die "update archive length mismatch for $(basename "$archive"): expected $length, got $actual"
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$archive" "$signature" >/dev/null \
    || die "update archive signature verification failed for $(basename "$archive")"
}

stage_history() {
  local stage="$1" before generation_file items deltas generation_before generation_after
  local line object length signature archive_count total_bytes remote_size
  [ -d "$stage" ] || die "stage directory does not exist: $stage"
  [ -z "$(/usr/bin/find "$stage" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || die "stage directory must be empty before staging update history"
  command -v "$GCLOUD" >/dev/null || die "gcloud is required"
  [ -x "$XMLLINT" ] || die "xmllint is required at $XMLLINT"
  [ -x "$SIGN_UPDATE" ] || die "Sparkle sign_update is required at $SIGN_UPDATE"

  before="$stage/.appcast-before.xml"
  generation_file="$stage/.appcast-generation"
  items="$stage/.appcast-before-items.tsv"
  deltas="$stage/.appcast-before-deltas.tsv"
  generation_before="$("$GCLOUD" storage objects describe "$BUCKET/appcast.xml" "--format=value(generation)")"
  [[ "$generation_before" =~ ^[1-9][0-9]*$ ]] \
    || die "could not read the live appcast generation"
  "$GCLOUD" storage cp "$BUCKET/appcast.xml" "$before"
  generation_after="$("$GCLOUD" storage objects describe "$BUCKET/appcast.xml" "--format=value(generation)")"
  [ "$generation_before" = "$generation_after" ] \
    || die "the live appcast changed while it was being staged; retry from the new feed"
  printf '%s\n' "$generation_before" > "$generation_file"
  cp "$before" "$stage/appcast.xml"

  parse_feed "$before" "$items" "$deltas" "live appcast"
  archive_count=0
  total_bytes=0
  while IFS= read -r line; do
    object="$(manifest_field "$line" 3)"
    length="$(manifest_field "$line" 5)"
    signature="$(manifest_field "$line" 6)"
    if ! remote_size="$("$GCLOUD" storage objects describe "$BUCKET/$object" "--format=value(size)")"; then
      die "referenced update archive is missing: $BUCKET/$object"
    fi
    [ "$remote_size" = "$length" ] \
      || die "published archive length mismatch for $object: expected $length, got ${remote_size:-missing}"
    "$GCLOUD" storage cp "$BUCKET/$object" "$stage/$object"
    verify_local_enclosure "$stage/$object" "$length" "$signature"
    archive_count=$((archive_count + 1))
    total_bytes=$((total_bytes + length))
  done < "$items"
  echo "    staged $archive_count signed branch-head archive(s), $total_bytes bytes"
}

promotion_target_state() {
  local items="$1" target_build="$2" target_version="$3" label="$4"
  local count line actual_version channel
  count="$(/usr/bin/awk -F '\t' -v build="$target_build" '$1 == build { count++ } END { print count + 0 }' "$items")"
  [ "$count" = "1" ] \
    || die "$label must contain exactly one live item for promotion build $target_build; it may have been superseded"
  line="$(/usr/bin/awk -F '\t' -v build="$target_build" '$1 == build { print }' "$items")"
  actual_version="$(manifest_field "$line" 2)"
  [ "$actual_version" = "$target_version" ] \
    || die "$label build $target_build has version $actual_version, not requested version $target_version"
  channel="$(manifest_field "$line" 12)"
  case "$channel" in
    daily) printf '%s\n' "promotion-required" ;;
    '') printf '%s\n' "already-promoted" ;;
    *) die "$label build $target_build is on channel $channel, not Daily or default Stable" ;;
  esac
}

validate_promotion_source() {
  local items="$1" target_build="$2" target_version="$3" label="$4"
  local state target_line stable_lines stable_count stable_line stable_build global_stable_build
  if ! state="$(promotion_target_state "$items" "$target_build" "$target_version" "$label")"; then
    return 1
  fi
  global_stable_build="$(/usr/bin/awk -F '\t' '$12 == "" && $1 + 0 > highest { highest=$1 + 0 } END { print highest + 0 }' "$items")"
  if [ "$state" = "already-promoted" ]; then
    [ "$global_stable_build" = "$target_build" ] \
      || die "$label newer default-channel Stable head $global_stable_build blocks alias reconciliation for build $target_build"
    printf '%s\n' "$state"
    return
  fi
  [ "$global_stable_build" -lt "$target_build" ] \
    || die "$label default-channel Stable head $global_stable_build already supersedes Daily build $target_build"

  target_line="$(/usr/bin/awk -F '\t' -v build="$target_build" '$1 == build { print }' "$items")"
  stable_lines="$(/usr/bin/awk -F '\t' \
    -v a="$(manifest_field "$target_line" 7)" \
    -v b="$(manifest_field "$target_line" 8)" \
    -v c="$(manifest_field "$target_line" 9)" \
    -v d="$(manifest_field "$target_line" 10)" \
    -v e="$(manifest_field "$target_line" 11)" \
    '$7 == a && $8 == b && $9 == c && $10 == d && $11 == e && $12 == "" { print }' "$items")"
  stable_count="$(printf '%s\n' "$stable_lines" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
  [ "$stable_count" -le 1 ] \
    || die "$label has ambiguous Stable leaders for promotion build $target_build"
  if [ "$stable_count" = "1" ]; then
    stable_line="$(printf '%s\n' "$stable_lines" | /usr/bin/awk 'NF { print; exit }')"
    stable_build="$(manifest_field "$stable_line" 1)"
    [ "$stable_build" -lt "$target_build" ] \
      || die "$label Stable build $stable_build already supersedes Daily build $target_build"
  fi
  printf '%s\n' "$state"
}

write_promotion_candidate() {
  local before="$1" output="$2" target_build="$3" target_version="$4" state="$5"
  local stylesheet temporary
  temporary="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-feed.xml.XXXXXX")"
  if [ "$state" = "already-promoted" ]; then
    cp "$before" "$temporary"
  else
    stylesheet="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-feed.xslt.XXXXXX")"
    /bin/cat > "$stylesheet" <<'XSLT'
<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <xsl:output method="xml" indent="yes"/>
  <xsl:param name="targetBuild"/>
  <xsl:param name="targetVersion"/>
  <xsl:variable name="target" select="/rss/channel/item[
    sparkle:version = $targetBuild and
    sparkle:shortVersionString = $targetVersion and
    sparkle:channel = 'daily']"/>
  <xsl:template match="@*|node()">
    <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
  </xsl:template>
  <xsl:template match="item">
    <xsl:choose>
      <xsl:when test="generate-id() = generate-id($target)">
        <xsl:copy>
          <xsl:apply-templates select="@*|node()[not(self::sparkle:channel)]"/>
        </xsl:copy>
      </xsl:when>
      <xsl:when test="
        not(sparkle:channel) and
        string(sparkle:minimumUpdateVersion) = string($target/sparkle:minimumUpdateVersion) and
        string(sparkle:minimumSystemVersion) = string($target/sparkle:minimumSystemVersion) and
        string(sparkle:maximumSystemVersion) = string($target/sparkle:maximumSystemVersion) and
        string(sparkle:minimumAutoupdateVersion) = string($target/sparkle:minimumAutoupdateVersion) and
        string(sparkle:hardwareRequirements) = string($target/sparkle:hardwareRequirements)"/>
      <xsl:otherwise>
        <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>
</xsl:stylesheet>
XSLT
    if ! /usr/bin/xsltproc --nonet \
      --stringparam targetBuild "$target_build" \
      --stringparam targetVersion "$target_version" \
      "$stylesheet" "$before" > "$temporary"; then
      rm -f "$stylesheet" "$temporary"
      die "could not construct the exact Daily-to-Stable promotion feed"
    fi
    rm -f "$stylesheet"
  fi
  /usr/bin/xmllint --nonet --noout "$temporary" 2>/dev/null \
    || { rm -f "$temporary"; die "promotion candidate appcast is not well-formed XML"; }
  /bin/mv "$temporary" "$output"
}

canonicalize_promotion_semantics() {
  local feed="$1" output="$2" stylesheet extracted
  stylesheet="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-semantics.xslt.XXXXXX")"
  extracted="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-semantics.xml.XXXXXX")"
  /bin/cat > "$stylesheet" <<'XSLT'
<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <xsl:strip-space elements="*"/>
  <xsl:output method="xml" indent="no"/>
  <xsl:template match="@*|node()">
    <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
  </xsl:template>
  <xsl:template match="/comment()">
    <xsl:if test="
      not(starts-with(normalize-space(.), 'sparkle-sign-warning:')) and
      not(starts-with(normalize-space(.), 'sparkle-signatures:'))">
      <xsl:copy/>
    </xsl:if>
  </xsl:template>
</xsl:stylesheet>
XSLT
  if ! /usr/bin/xsltproc --nonet "$stylesheet" "$feed" > "$extracted" \
    || ! /usr/bin/xmllint --nonet --c14n "$extracted" > "$output" 2>/dev/null; then
    rm -f "$stylesheet" "$extracted" "$output"
    die "could not canonicalize promotion appcast items"
  fi
  rm -f "$stylesheet" "$extracted"
}

prepare_promotion() {
  local stage="$1" target_build="$2" target_version="$3"
  local before candidate items deltas state temporary state_file
  [[ "$target_build" =~ ^[1-9][0-9]*$ ]] || die "promotion build must be a positive integer"
  [[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "promotion version must be numeric semantic version"
  before="$stage/.appcast-before.xml"
  candidate="$stage/appcast.xml"
  items="$stage/.promotion-before-items.tsv"
  deltas="$stage/.promotion-before-deltas.tsv"
  state_file="$stage/.promotion-state"
  [ -s "$before" ] || die "staged source appcast is missing"
  command -v /usr/bin/xsltproc >/dev/null || die "xsltproc is required"
  rm -f "$state_file" "$stage/.appcast-candidate-objects.tsv"
  parse_feed "$before" "$items" "$deltas" "promotion source appcast"
  if ! state="$(validate_promotion_source "$items" "$target_build" "$target_version" "promotion source appcast")"; then
    return 1
  fi
  temporary="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-candidate.xml.XXXXXX")"
  write_promotion_candidate "$before" "$temporary" "$target_build" "$target_version" "$state"
  /bin/mv "$temporary" "$candidate"
  printf '%s\n' "$state" > "$state_file"
  printf '%s\n' "$state"
}

verify_promotion() {
  local stage="$1" target_build="$2" target_version="$3"
  local before candidate old_items old_deltas candidate_items candidate_deltas state state_file
  local expected expected_semantics actual_semantics expected_prior_deltas objects line object length signature archive prior_delta root_delta
  [[ "$target_build" =~ ^[1-9][0-9]*$ ]] || die "promotion build must be a positive integer"
  [[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "promotion version must be numeric semantic version"
  before="$stage/.appcast-before.xml"
  candidate="$stage/appcast.xml"
  old_items="$stage/.promotion-before-items.tsv"
  old_deltas="$stage/.promotion-before-deltas.tsv"
  candidate_items="$stage/.appcast-candidate-items.tsv"
  candidate_deltas="$stage/.appcast-candidate-deltas.tsv"
  state_file="$stage/.promotion-state"
  objects="$stage/.appcast-candidate-objects.tsv"
  rm -f "$objects"
  [ -s "$before" ] || die "staged source appcast is missing"
  [ -s "$candidate" ] || die "promotion candidate appcast is missing"
  [ -s "$state_file" ] || die "promotion state is missing; run prepare-promotion first"

  parse_feed "$before" "$old_items" "$old_deltas" "promotion source appcast"
  if ! state="$(validate_promotion_source "$old_items" "$target_build" "$target_version" "promotion source appcast")"; then
    return 1
  fi
  [ "$(tr -d '[:space:]' < "$state_file")" = "$state" ] \
    || die "promotion state does not match the staged source appcast"
  parse_feed "$candidate" "$candidate_items" "$candidate_deltas" "promotion candidate appcast"

  expected="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-expected.xml.XXXXXX")"
  expected_semantics="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-expected-semantics.xml.XXXXXX")"
  actual_semantics="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-actual-semantics.xml.XXXXXX")"
  write_promotion_candidate "$before" "$expected" "$target_build" "$target_version" "$state"
  canonicalize_promotion_semantics "$expected" "$expected_semantics"
  canonicalize_promotion_semantics "$candidate" "$actual_semantics"
  if ! /usr/bin/cmp -s "$expected_semantics" "$actual_semantics"; then
    rm -f "$expected" "$expected_semantics" "$actual_semantics"
    die "promotion candidate changed content other than the target channel, displaced Stable leader, or appcast signature comments"
  fi
  rm -f "$expected" "$expected_semantics" "$actual_semantics"

  # The promoted item's old deltas are still the exact published objects. Normalize only that
  # item's branch channel so they remain recognizable after Daily becomes default Stable.
  expected_prior_deltas="$(mktemp "${TMPDIR:-/tmp}/mechanician-promotion-prior-deltas.tsv.XXXXXX")"
  /usr/bin/awk -F '\t' -v OFS='\t' -v build="$target_build" \
    '$1 == build && $12 == "daily" { $12 = "" } { print }' "$old_deltas" > "$expected_prior_deltas"

  : > "$objects"
  while IFS= read -r line; do
    object="$(manifest_field "$line" 3)"
    length="$(manifest_field "$line" 5)"
    signature="$(manifest_field "$line" 6)"
    archive="$stage/$object"
    [ -f "$archive" ] || archive="$stage/old_updates/$object"
    verify_local_enclosure "$archive" "$length" "$signature"
    printf '%s\t%s\n' "$object" "$length" >> "$objects"
  done < "$candidate_items"

  while IFS= read -r line; do
    object="$(manifest_field "$line" 3)"
    length="$(manifest_field "$line" 5)"
    signature="$(manifest_field "$line" 6)"
    archive=""
    [ ! -f "$stage/$object" ] || archive="$stage/$object"
    [ -n "$archive" ] || [ ! -f "$stage/old_updates/$object" ] || archive="$stage/old_updates/$object"
    prior_delta=0
    /usr/bin/grep -Fqx -- "$line" "$expected_prior_deltas" && prior_delta=1
    if [ -n "$archive" ]; then
      verify_local_enclosure "$archive" "$length" "$signature"
    elif [ "$prior_delta" -ne 1 ]; then
      rm -f "$expected_prior_deltas"
      die "promotion candidate introduced a new or changed delta: $object"
    fi
    printf '%s\t%s\n' "$object" "$length" >> "$objects"
  done < "$candidate_deltas"
  rm -f "$expected_prior_deltas"
  LC_ALL=C /usr/bin/sort -u -o "$objects" "$objects"

  shopt -s nullglob
  for root_delta in "$stage"/*.delta; do
    object="$(basename "$root_delta")"
    /usr/bin/awk -F '\t' -v object="$object" '$1 == object { found=1 } END { exit !found }' "$objects" \
      || die "generated delta is not referenced by the promotion candidate appcast: $object"
  done
  echo "    $state: exact build $target_build is ready for Stable aliases"
}

verify_transition() {
  local stage="$1" new_build="$2" new_version="$3" requested_channel="$4"
  local before candidate old_items old_deltas candidate_items candidate_deltas
  local old_branches candidate_branches expected_branches new_line new_branch line old_branch
  local object length signature archive old_line objects local_delta prior_delta root_delta highest_old_build
  local old_build old_delta_count candidate_delta_count eligible_source_count new_a new_b new_c new_d new_e old_channel
  [[ "$new_build" =~ ^[1-9][0-9]*$ ]] || die "new build must be a positive integer"
  [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "new version must be numeric semantic version"
  [ "$requested_channel" = "stable" ] || [ "$requested_channel" = "daily" ] \
    || die "requested channel must be stable or daily"
  before="$stage/.appcast-before.xml"
  candidate="$stage/appcast.xml"
  old_items="$stage/.appcast-before-items.tsv"
  old_deltas="$stage/.appcast-before-deltas.tsv"
  candidate_items="$stage/.appcast-candidate-items.tsv"
  candidate_deltas="$stage/.appcast-candidate-deltas.tsv"
  old_branches="$stage/.appcast-before-branches.tsv"
  candidate_branches="$stage/.appcast-candidate-branches.tsv"
  expected_branches="$stage/.appcast-expected-branches.tsv"
  objects="$stage/.appcast-candidate-objects.tsv"
  [ -s "$before" ] || die "staged source appcast is missing"
  [ -s "$candidate" ] || die "generated candidate appcast is missing"
  [ -x "$SIGN_UPDATE" ] || die "Sparkle sign_update is required at $SIGN_UPDATE"

  highest_old_build="$(/usr/bin/cut -f1 "$old_items" | /usr/bin/sort -n | /usr/bin/tail -1)"
  [[ "$highest_old_build" =~ ^[1-9][0-9]*$ ]] || die "staged source appcast build manifest is invalid"
  [ "$new_build" -gt "$highest_old_build" ] \
    || die "new build $new_build must exceed staged feed build $highest_old_build"

  parse_feed "$candidate" "$candidate_items" "$candidate_deltas" "candidate appcast"
  new_line="$(/usr/bin/awk -F '\t' -v build="$new_build" '$1 == build { print }' "$candidate_items")"
  [ -n "$new_line" ] || die "candidate appcast does not contain build $new_build"
  [ "$(manifest_field "$new_line" 2)" = "$new_version" ] \
    || die "candidate build $new_build does not have version $new_version"
  [ "$(manifest_field "$new_line" 3)" = "$ARTIFACT_NAME-$new_version.zip" ] \
    || die "candidate build $new_build does not use the expected archive"
  if [ "$requested_channel" = "stable" ]; then
    [ -z "$(manifest_field "$new_line" 12)" ] \
      || die "candidate stable build $new_build must use Sparkle's default channel"
  elif [ "$requested_channel" = "daily" ]; then
    [ "$(manifest_field "$new_line" 12)" = "daily" ] \
      || die "candidate daily build $new_build does not declare the daily channel"
  fi

  /usr/bin/cut -f7-12 "$old_items" | LC_ALL=C /usr/bin/sort -u > "$old_branches"
  /usr/bin/cut -f7-12 "$candidate_items" | LC_ALL=C /usr/bin/sort -u > "$candidate_branches"
  new_branch="$(branch_from_line "$new_line")"
  new_a="$(manifest_field "$new_line" 7)"
  new_b="$(manifest_field "$new_line" 8)"
  new_c="$(manifest_field "$new_line" 9)"
  new_d="$(manifest_field "$new_line" 10)"
  new_e="$(manifest_field "$new_line" 11)"
  { /bin/cat "$old_branches"; printf '%s\n' "$new_branch"; } \
    | LC_ALL=C /usr/bin/sort -u > "$expected_branches"
  /usr/bin/cmp -s "$expected_branches" "$candidate_branches" \
    || die "candidate appcast lost or changed a Sparkle compatibility branch"

  # An old branch may change only when this release replaces its leader.
  while IFS= read -r old_line; do
    old_branch="$(branch_from_line "$old_line")"
    if [ "$old_branch" != "$new_branch" ]; then
      /usr/bin/grep -Fqx -- "$old_line" "$candidate_items" \
        || die "candidate appcast changed the leader of an unaffected compatibility branch"
      old_build="$(manifest_field "$old_line" 1)"
      old_delta_count="$(/usr/bin/awk -F '\t' -v build="$old_build" '$1 == build { count++ } END { print count + 0 }' "$old_deltas")"
      candidate_delta_count="$(/usr/bin/awk -F '\t' -v build="$old_build" '$1 == build { count++ } END { print count + 0 }' "$candidate_deltas")"
      [ "$old_delta_count" = "$candidate_delta_count" ] \
        || die "candidate appcast changed delta availability on an unaffected compatibility branch"
      /usr/bin/cmp -s \
        <(/usr/bin/awk -F '\t' -v build="$old_build" '$1 == build' "$old_deltas" | LC_ALL=C /usr/bin/sort) \
        <(/usr/bin/awk -F '\t' -v build="$old_build" '$1 == build' "$candidate_deltas" | LC_ALL=C /usr/bin/sort) \
        || die "candidate appcast changed an unaffected compatibility branch delta"
    fi
  done < "$old_items"

  # Stable and Daily share the same platform branch. The new item must have a direct delta from
  # every live Stable/Daily leader on that platform (at most two), so neither audience falls back
  # to the roughly 260 MB full archive merely because the other channel published most recently.
  eligible_source_count=0
  while IFS= read -r old_line; do
    old_channel="$(manifest_field "$old_line" 12)"
    if [ "$(manifest_field "$old_line" 7)" = "$new_a" ] \
      && [ "$(manifest_field "$old_line" 8)" = "$new_b" ] \
      && [ "$(manifest_field "$old_line" 9)" = "$new_c" ] \
      && [ "$(manifest_field "$old_line" 10)" = "$new_d" ] \
      && [ "$(manifest_field "$old_line" 11)" = "$new_e" ] \
      && { [ -z "$old_channel" ] || [ "$old_channel" = "daily" ]; }; then
      old_build="$(manifest_field "$old_line" 1)"
      eligible_source_count=$((eligible_source_count + 1))
      /usr/bin/awk -F '\t' -v target="$new_build" -v source="$old_build" \
        '$1 == target && $2 == source { found=1 } END { exit !found }' "$candidate_deltas" \
        || die "candidate build $new_build has no delta from live channel build $old_build"
    fi
  done < "$old_items"
  [ "$eligible_source_count" -le 2 ] \
    || die "candidate platform has more than two Stable/Daily leaders; increase the reviewed delta bound"

  : > "$objects"
  while IFS= read -r line; do
    object="$(manifest_field "$line" 3)"
    length="$(manifest_field "$line" 5)"
    signature="$(manifest_field "$line" 6)"
    archive="$stage/$object"
    [ -f "$archive" ] || archive="$stage/old_updates/$object"
    verify_local_enclosure "$archive" "$length" "$signature"
    printf '%s\t%s\n' "$object" "$length" >> "$objects"
  done < "$candidate_items"

  while IFS= read -r line; do
    object="$(manifest_field "$line" 3)"
    length="$(manifest_field "$line" 5)"
    signature="$(manifest_field "$line" 6)"
    local_delta=""
    [ ! -f "$stage/$object" ] || local_delta="$stage/$object"
    [ -n "$local_delta" ] || [ ! -f "$stage/old_updates/$object" ] || local_delta="$stage/old_updates/$object"
    prior_delta=0
    /usr/bin/grep -Fqx -- "$line" "$old_deltas" && prior_delta=1
    if [ -n "$local_delta" ]; then
      verify_local_enclosure "$local_delta" "$length" "$signature"
    elif [ "$prior_delta" -ne 1 ]; then
      die "candidate appcast introduced a delta that was neither generated nor previously published: $object"
    fi
    printf '%s\t%s\n' "$object" "$length" >> "$objects"
  done < "$candidate_deltas"
  LC_ALL=C /usr/bin/sort -u -o "$objects" "$objects"

  shopt -s nullglob
  for root_delta in "$stage"/*.delta; do
    object="$(basename "$root_delta")"
    /usr/bin/awk -F '\t' -v object="$object" '$1 == object { found=1 } END { exit !found }' "$objects" \
      || die "generated delta is not referenced by the candidate appcast: $object"
  done
  echo "    candidate feed preserves $(wc -l < "$candidate_branches" | tr -d ' ') compatibility branch(es)"
}

verify_remote() {
  local stage="$1" objects line object expected actual
  objects="$stage/.appcast-candidate-objects.tsv"
  [ -s "$objects" ] \
    || die "candidate object manifest is missing; run verify-transition or verify-promotion first"
  command -v "$GCLOUD" >/dev/null || die "gcloud is required"
  while IFS= read -r line; do
    object="$(manifest_field "$line" 1)"
    expected="$(manifest_field "$line" 2)"
    if ! actual="$("$GCLOUD" storage objects describe "$BUCKET/$object" "--format=value(size)")"; then
      die "candidate feed object is missing: $BUCKET/$object"
    fi
    [ "$actual" = "$expected" ] \
      || die "published object size mismatch for $object: expected $expected, got ${actual:-missing}"
  done < "$objects"
  echo "    every candidate feed object exists with its declared length"
}

publish_appcast() {
  local stage="$1" generation
  [ -s "$stage/appcast.xml" ] || die "candidate appcast is missing"
  [ -s "$stage/.appcast-generation" ] || die "source appcast generation is missing"
  generation="$(tr -d '[:space:]' < "$stage/.appcast-generation")"
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || die "source appcast generation is invalid"
  "$GCLOUD" storage cp --cache-control="no-cache, max-age=0" \
    "--if-generation-match=$generation" "$stage/appcast.xml" "$BUCKET/appcast.xml"
}

MODE="${1:-}"
case "$MODE" in
  stage)
    [ "$#" -eq 2 ] || { usage >&2; exit 64; }
    stage_history "$2"
    ;;
  preserve-unaffected)
    [ "$#" -eq 3 ] || { usage >&2; exit 64; }
    preserve_unaffected "$2" "$3"
    ;;
  prepare-promotion)
    [ "$#" -eq 4 ] || { usage >&2; exit 64; }
    prepare_promotion "$2" "$3" "$4"
    ;;
  verify-promotion)
    [ "$#" -eq 4 ] || { usage >&2; exit 64; }
    verify_promotion "$2" "$3" "$4"
    ;;
  verify-transition)
    [ "$#" -eq 5 ] || { usage >&2; exit 64; }
    verify_transition "$2" "$3" "$4" "$5"
    ;;
  verify-remote)
    [ "$#" -eq 2 ] || { usage >&2; exit 64; }
    verify_remote "$2"
    ;;
  publish)
    [ "$#" -eq 2 ] || { usage >&2; exit 64; }
    publish_appcast "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
