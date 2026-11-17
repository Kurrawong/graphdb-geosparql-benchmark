#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 PLUGIN_CHECKOUT OUTPUT_DIRECTORY" >&2
  exit 1
fi

plugin_dir="$(CDPATH= cd -- "$1" && pwd)"
mkdir -p "$2"
output_dir="$(CDPATH= cd -- "$2" && pwd)"
source_commit="$(git -C "$plugin_dir" rev-parse HEAD)"
source_status="$(git -C "$plugin_dir" status --porcelain --untracked-files=normal)"
dirty=false
if [ -n "$source_status" ]; then
  dirty=true
fi

# Build from the working tree so tracked edits and new source files are included.
(cd "$plugin_dir" && mvn --batch-mode -DskipTests clean package)
archive="$plugin_dir/target/geosparql-plugin-graphdb-plugin.zip"
archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
java_command=java
if [ -n "${JAVA_HOME:-}" ]; then
  java_command="$JAVA_HOME/bin/java"
fi
build_java="$("$java_command" -version 2>&1)"
build_maven="$(mvn --version 2>&1)"

staging_dir="$(mktemp -d "$output_dir/.plugin.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT HUP INT TERM
cp "$archive" "$staging_dir/plugin.zip"
(cd "$staging_dir" && jar xf plugin.zip)
test -d "$staging_dir/geosparql-plugin"

revision="$source_commit"
if [ "$dirty" = true ]; then
  revision="$revision-dirty"
fi
revision="$revision:sha256:$archive_sha256"
printf '%s\n' "$revision" > "$staging_dir/source-commit.txt"
jq --null-input \
  --arg source_commit "$source_commit" \
  --argjson dirty "$dirty" \
  --arg source_status "$source_status" \
  --arg archive_sha256 "$archive_sha256" \
  --arg build_java "$build_java" \
  --arg build_maven "$build_maven" \
  '{source_commit: $source_commit, dirty: $dirty, source_status: $source_status,
    archive_sha256: $archive_sha256, build_java: $build_java, build_maven: $build_maven}' \
  > "$staging_dir/source.json"

rm -rf -- "$output_dir/geosparql-plugin"
mv "$staging_dir/geosparql-plugin" "$output_dir/geosparql-plugin"
mv "$staging_dir/plugin.zip" "$output_dir/plugin.zip"
mv "$staging_dir/source.json" "$output_dir/source.json"
mv "$staging_dir/source-commit.txt" "$output_dir/source-commit.txt"
echo "Prepared local plugin $revision"
