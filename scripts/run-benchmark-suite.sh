#!/bin/sh

set -eu

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 VARIANT GRAPHDB_URL REPOSITORY_ID PLUGIN_REVISION" >&2
  exit 1
fi

variant="$1"
graphdb_url="$2"
repository_id="$3"
plugin_revision="$4"

case "$variant" in
  v1|v2)
    ;;
  *)
    echo "Unexpected benchmark variant: $variant" >&2
    exit 1
    ;;
esac

manifest="${BENCHMARK_MANIFEST:-queries/manifest.json}"
queries_dir="${BENCHMARK_QUERIES_DIR:-queries}"
results_root="${BENCHMARK_RESULTS_DIR:-benchmark-results}"
warmups="${BENCHMARK_WARMUPS:-1}"
runs="${BENCHMARK_RUNS:-3}"
selected_query="${BENCHMARK_QUERY_ID:-}"
results_dir="$results_root/$variant"
queries_results_dir="$results_dir/queries"
suite_file="$results_dir/suite.json"

case "$warmups" in
  ''|*[!0-9]*)
    echo "BENCHMARK_WARMUPS must be a non-negative integer" >&2
    exit 1
    ;;
esac
case "$runs" in
  ''|*[!0-9]*|0)
    echo "BENCHMARK_RUNS must be a positive integer" >&2
    exit 1
    ;;
esac

"$(dirname "$0")/validate-query-manifest.sh" "$manifest" "$queries_dir"

if [ -n "$selected_query" ]; then
  if ! jq --exit-status --arg id "$selected_query" \
    '.queries[] | select(.id == $id)' "$manifest" >/dev/null; then
    echo "Unknown BENCHMARK_QUERY_ID: $selected_query" >&2
    exit 1
  fi
  query_ids="$selected_query"
else
  query_ids="$(jq --raw-output '.queries[].id' "$manifest")"
fi

mkdir -p "$queries_results_dir"
rm -f "$suite_file"

current_work_dir=""
cleanup() {
  if [ -n "$current_work_dir" ] && [ -d "$current_work_dir" ]; then
    rm -rf -- "$current_work_dir"
  fi
}
trap cleanup EXIT HUP INT TERM

canonicalize_response() {
  response_file="$1"
  canonical_file="$2"
  canonical_unsorted="$3"

  jq --exit-status '
    (.results.bindings | type == "array") and
    all(
      .results.bindings[];
      (.result.value | type == "string") and
      (.wkt.type | type == "string") and
      (.wkt.value | type == "string")
    )
  ' "$response_file" >/dev/null
  jq --compact-output '
    .results.bindings[] |
    [
      .result.value,
      .wkt.type,
      (.wkt.datatype // null),
      (.wkt["xml:lang"] // null),
      .wkt.value
    ]
  ' "$response_file" > "$canonical_unsorted"
  LC_ALL=C sort "$canonical_unsorted" > "$canonical_file"
  rm -f "$canonical_unsorted"
}

execute_request() {
  query_file="$1"
  response_file="$2"
  transfer_file="$3"

  if ! curl --fail-with-body --silent --show-error \
    --write-out '%{http_code}\t%{time_total}\n' \
    --request POST \
    "$graphdb_url/repositories/$repository_id" \
    --header "Content-Type: application/sparql-query" \
    --header "Accept: application/sparql-results+json" \
    --output "$response_file" \
    --data-binary "@$query_file" > "$transfer_file"; then
    echo "Benchmark query request failed: $query_file" >&2
    return 1
  fi
}

for query_id in $query_ids; do
  query_file_name="$(
    jq --raw-output --arg id "$query_id" \
      '.queries[] | select(.id == $id) | .file' "$manifest"
  )"
  query_file="$queries_dir/$query_file_name"
  target_dir="$queries_results_dir/$query_id"
  current_work_dir="$queries_results_dir/.$query_id.part.$$"
  rm -rf -- "$current_work_dir"
  mkdir -p "$current_work_dir"

  echo "Benchmark query: $query_id"

  warmup_iteration=1
  while [ "$warmup_iteration" -le "$warmups" ]; do
    warmup_response="$current_work_dir/warmup-response.json"
    warmup_transfer="$current_work_dir/warmup-curl.txt"
    echo "  Warm-up $warmup_iteration/$warmups"
    execute_request "$query_file" "$warmup_response" "$warmup_transfer"
    jq --exit-status '
      (.results.bindings | type == "array") and
      all(
        .results.bindings[];
        (.result.value | type == "string") and
        (.wkt.value | type == "string")
      )
    ' "$warmup_response" >/dev/null
    rm -f "$warmup_response" "$warmup_transfer"
    warmup_iteration=$((warmup_iteration + 1))
  done

  expected_rows=""
  expected_hash=""
  iteration=1
  while [ "$iteration" -le "$runs" ]; do
    run_dir="$current_work_dir/run-$iteration"
    response_file="$run_dir/results.json"
    transfer_file="$run_dir/curl.txt"
    canonical_file="$run_dir/results.canonical.jsonl"
    canonical_unsorted="$run_dir/results.canonical.unsorted"
    hash_file="$run_dir/results.sha256"
    metrics_file="$run_dir/metrics.json"

    mkdir -p "$run_dir"
    echo "  Measured run $iteration/$runs"
    execute_request "$query_file" "$response_file" "$transfer_file"

    tab="$(printf '\t')"
    IFS="$tab" read -r http_status response_time < "$transfer_file"
    if [ "$http_status" != "200" ]; then
      echo "$query_id run $iteration returned HTTP $http_status" >&2
      exit 1
    fi

    canonicalize_response \
      "$response_file" "$canonical_file" "$canonical_unsorted"
    row_count="$(wc -l < "$canonical_file" | tr -d ' ')"
    result_hash="$(sha256sum "$canonical_file" | awk '{print $1}')"
    printf '%s\n' "$result_hash" > "$hash_file"

    jq --null-input \
      --arg query_id "$query_id" \
      --arg variant "$variant" \
      --arg plugin_revision "$plugin_revision" \
      --argjson iteration "$iteration" \
      --argjson http_status "$http_status" \
      --argjson response_time_seconds "$response_time" \
      --argjson row_count "$row_count" \
      --arg canonical_sha256 "$result_hash" \
      '{
        schema_version: 1,
        query_id: $query_id,
        variant: $variant,
        graphdb_version: "11.4.0",
        plugin_revision: $plugin_revision,
        iteration: $iteration,
        http_status: $http_status,
        response_time_seconds: $response_time_seconds,
        row_count: $row_count,
        canonical_sha256: $canonical_sha256
      }' > "$metrics_file"

    if [ -z "$expected_rows" ]; then
      expected_rows="$row_count"
      expected_hash="$result_hash"
    elif [ "$row_count" != "$expected_rows" ] ||
      [ "$result_hash" != "$expected_hash" ]; then
      echo "$query_id produced unstable output on run $iteration" >&2
      echo "Expected $expected_rows rows with SHA-256 $expected_hash" >&2
      echo "Received $row_count rows with SHA-256 $result_hash" >&2
      exit 1
    fi

    echo "    HTTP $http_status"
    echo "    Response time: ${response_time}s"
    echo "    Rows returned: $row_count"
    echo "    Canonical SHA-256: $result_hash"
    iteration=$((iteration + 1))
  done

  jq --slurp \
    --arg query_id "$query_id" \
    --arg variant "$variant" \
    --arg plugin_revision "$plugin_revision" \
    --argjson warmups "$warmups" \
    '
      def median:
        sort as $sorted |
        ($sorted | length) as $length |
        if $length % 2 == 1 then
          $sorted[($length / 2 | floor)]
        else
          (
            $sorted[$length / 2 - 1] +
            $sorted[$length / 2]
          ) / 2
        end;

      sort_by(.iteration) as $runs |
      ($runs | map(.response_time_seconds)) as $times |
      {
        schema_version: 1,
        query_id: $query_id,
        variant: $variant,
        graphdb_version: "11.4.0",
        plugin_revision: $plugin_revision,
        warmups: $warmups,
        measured_runs: ($runs | length),
        response_times_seconds: $times,
        minimum_seconds: ($times | min),
        median_seconds: ($times | median),
        maximum_seconds: ($times | max),
        row_count: $runs[0].row_count,
        canonical_sha256: $runs[0].canonical_sha256,
        stable_output: (
          ($runs | map(.row_count) | unique | length) == 1 and
          ($runs | map(.canonical_sha256) | unique | length) == 1
        )
      }
    ' "$current_work_dir"/run-*/metrics.json > "$current_work_dir/summary.json"

  backup_dir="$queries_results_dir/.$query_id.backup.$$"
  rm -rf -- "$backup_dir"
  if [ -d "$target_dir" ]; then
    mv "$target_dir" "$backup_dir"
  fi
  if mv "$current_work_dir" "$target_dir"; then
    current_work_dir=""
    rm -rf -- "$backup_dir"
  else
    if [ -d "$backup_dir" ]; then
      mv "$backup_dir" "$target_dir"
    fi
    exit 1
  fi
done

if [ -z "$selected_query" ]; then
  corpus_target="$results_dir/corpus"
  current_work_dir="$results_dir/.corpus.part.$$"
  rm -rf -- "$current_work_dir"
  mkdir -p "$current_work_dir"

  echo "Capturing the canonical geometry corpus for partition validation"
  execute_request \
    "$queries_dir/geometry-corpus.rq" \
    "$current_work_dir/results.json" \
    "$current_work_dir/curl.txt"
  canonicalize_response \
    "$current_work_dir/results.json" \
    "$current_work_dir/results.canonical.jsonl" \
    "$current_work_dir/results.canonical.unsorted"
  corpus_rows="$(
    wc -l < "$current_work_dir/results.canonical.jsonl" | tr -d ' '
  )"
  corpus_hash="$(
    sha256sum "$current_work_dir/results.canonical.jsonl" | awk '{print $1}'
  )"
  printf '%s\n' "$corpus_hash" > "$current_work_dir/results.sha256"
  jq --null-input \
    --arg variant "$variant" \
    --argjson row_count "$corpus_rows" \
    --arg canonical_sha256 "$corpus_hash" \
    '{
      schema_version: 1,
      variant: $variant,
      row_count: $row_count,
      canonical_sha256: $canonical_sha256
    }' > "$current_work_dir/summary.json"

  corpus_backup="$results_dir/.corpus.backup.$$"
  rm -rf -- "$corpus_backup"
  if [ -d "$corpus_target" ]; then
    mv "$corpus_target" "$corpus_backup"
  fi
  if mv "$current_work_dir" "$corpus_target"; then
    current_work_dir=""
    rm -rf -- "$corpus_backup"
  else
    if [ -d "$corpus_backup" ]; then
      mv "$corpus_backup" "$corpus_target"
    fi
    exit 1
  fi

  benchmark_definition_hash="$(
    "$(dirname "$0")/benchmark-definition-sha256.sh" "$manifest" "$queries_dir"
  )"
  jq --slurp \
    --arg variant "$variant" \
    --arg plugin_revision "$plugin_revision" \
    --arg benchmark_definition_sha256 "$benchmark_definition_hash" \
    --argjson warmups "$warmups" \
    --argjson measured_runs "$runs" \
    '{
      schema_version: 2,
      variant: $variant,
      graphdb_version: "11.4.0",
      plugin_revision: $plugin_revision,
      benchmark_definition_sha256: $benchmark_definition_sha256,
      warmups: $warmups,
      measured_runs: $measured_runs,
      queries: (sort_by(.query_id) | map(.query_id))
    }' "$queries_results_dir"/*/summary.json > "$suite_file.part"
  mv "$suite_file.part" "$suite_file"
  echo "Completed the GeoSPARQL $variant benchmark suite"
  echo "Saved suite metadata to $suite_file"
else
  echo "Completed standalone query $selected_query"
  echo "Suite metadata was invalidated; run the complete suite before reporting"
fi
