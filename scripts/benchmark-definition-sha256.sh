#!/bin/sh

set -eu

manifest="${1:-queries/manifest.json}"
queries_dir="${2:-$(dirname "$manifest")}"

{
  manifest_execution_hash="$(
    sed '/^[[:space:]]*"cross_variant_output":[[:space:]]/d' "$manifest" |
      sha256sum |
      awk '{print $1}'
  )"
  printf 'manifest\t%s\n' "$manifest_execution_hash"

  jq --raw-output '.queries[].file' "$manifest" |
    LC_ALL=C sort |
    while IFS= read -r query_file; do
      printf 'query:%s\t%s\n' \
        "$query_file" \
        "$(sha256sum "$queries_dir/$query_file" | awk '{print $1}')"
    done

  printf 'corpus:geometry-corpus.rq\t%s\n' \
    "$(sha256sum "$queries_dir/geometry-corpus.rq" | awk '{print $1}')"
} | sha256sum | awk '{print $1}'
