#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 INDEX_DIR VARIANT INDEXING_TIME_SECONDS" >&2
  exit 1
fi

index_dir="${1%/}"
variant="$2"
indexing_time="$3"
results_root="${BENCHMARK_RESULTS_DIR:-benchmark-results}"
repository_id="${BENCHMARK_REPOSITORY_ID:-maldives}"

case "$variant" in
  v1)
    compose_profile="v1"
    compose_service="graphdb-geosparql-v1"
    ;;
  v2)
    compose_profile="v2"
    compose_service="graphdb-geosparql-v2"
    ;;
  *)
    echo "Unexpected benchmark variant: $variant" >&2
    exit 1
    ;;
esac

if [ ! -d "$index_dir" ]; then
  echo "GeoSPARQL index directory was not created at $index_dir" >&2
  exit 1
fi

index_size="$(du --summarize --human-readable "$index_dir" | cut -f1)"
index_bytes="$(du --summarize --block-size=1 "$index_dir" | cut -f1)"

index_configs="$(
  find "$index_dir" -maxdepth 2 -type f -name config.properties \
    -print | LC_ALL=C sort
)"
index_config_count="$(
  printf '%s\n' "$index_configs" |
    awk 'NF { count++ } END { print count + 0 }'
)"
if [ "$index_config_count" -eq 0 ]; then
  echo "GeoSPARQL index configuration was not found under $index_dir" >&2
  exit 1
fi
if [ "$index_config_count" -ne 1 ]; then
  echo "Expected one GeoSPARQL index configuration under $index_dir; found $index_config_count" >&2
  printf '%s\n' "$index_configs" >&2
  exit 1
fi
index_config="$index_configs"
index_config_relative="${index_config#"$index_dir"/}"
if [ "$index_config_relative" = "$index_config" ]; then
  echo "GeoSPARQL index configuration is outside $index_dir: $index_config" >&2
  exit 1
fi
container_index_dir="/opt/graphdb/home/data/repositories/$repository_id/storage/GeoSPARQL"
container_index_config="$container_index_dir/$index_config_relative"
if ! index_config_contents="$(
  docker compose --profile "$compose_profile" exec --no-TTY \
    "$compose_service" cat "$container_index_config"
)"; then
  echo \
    "Could not read GeoSPARQL index configuration from $compose_service: $container_index_config" \
    >&2
  exit 1
fi

prefix_tree="$(
  printf '%s\n' "$index_config_contents" |
    awk -F= '$1 == "prefixtree.current" { print $2 }' |
    tr -d '\r'
)"
if [ -z "$prefix_tree" ]; then
  prefix_tree="$(
    printf '%s\n' "$index_config_contents" |
      awk -F= '$1 == "prefixtree" { print $2 }' |
      tr -d '\r'
  )"
fi
precision="$(
  printf '%s\n' "$index_config_contents" |
    awk -F= '$1 == "precision.current" { print $2 }' |
    tr -d '\r'
)"
if [ -z "$precision" ]; then
  precision="$(
    printf '%s\n' "$index_config_contents" |
      awk -F= '$1 == "precision" { print $2 }' |
      tr -d '\r'
  )"
fi

if [ -z "$prefix_tree" ]; then
  echo "GeoSPARQL prefix tree is missing from $index_config" >&2
  exit 1
fi
case "$precision" in
  ''|*[!0-9]*)
    echo "Invalid GeoSPARQL precision in $index_config: $precision" >&2
    exit 1
    ;;
esac

echo "GeoSPARQL spatial indexing completed successfully in ${indexing_time}s"
echo "GeoSPARQL spatial index size: $index_size ($index_bytes bytes)"
echo "GeoSPARQL spatial index configuration: $prefix_tree, precision $precision"

index_metrics="$results_root/$variant/index-metrics.json"
index_metrics_part="$index_metrics.part"
mkdir -p "$results_root/$variant"
trap 'rm -f "$index_metrics_part"' EXIT HUP INT TERM
jq --null-input \
  --arg variant "$variant" \
  --arg prefix_tree "$prefix_tree" \
  --argjson precision "$precision" \
  --argjson indexing_time_seconds "$indexing_time" \
  --argjson index_size_bytes "$index_bytes" \
  '{
    schema_version: 2,
    variant: $variant,
    prefix_tree: $prefix_tree,
    precision: $precision,
    indexing_time_seconds: $indexing_time_seconds,
    index_size_bytes: $index_size_bytes
  }' > "$index_metrics_part"
mv "$index_metrics_part" "$index_metrics"
echo "Saved spatial index metrics to $index_metrics"
