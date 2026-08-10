#!/bin/sh

set -eu

manifest="${1:-queries/manifest.json}"
results_root="${2:-benchmark-results}"
report_file="${3:-$results_root/report.md}"
script_dir="$(dirname "$0")"
queries_dir="$(dirname "$manifest")"

"$script_dir/validate-query-manifest.sh" "$manifest" "$queries_dir"

benchmark_definition_hash="$(
  "$script_dir/benchmark-definition-sha256.sh" "$manifest" "$queries_dir"
)"
v1_suite="$results_root/v1/suite.json"
v2_suite="$results_root/v2/suite.json"
v1_index="$results_root/v1/index-metrics.json"
v2_index="$results_root/v2/index-metrics.json"
v1_corpus_summary="$results_root/v1/corpus/summary.json"
v2_corpus_summary="$results_root/v2/corpus/summary.json"

for required_file in \
  "$v1_suite" "$v2_suite" \
  "$v1_index" "$v2_index" \
  "$v1_corpus_summary" "$v2_corpus_summary"; do
  if [ ! -f "$required_file" ]; then
    echo "Missing benchmark artifact: $required_file" >&2
    exit 1
  fi
done

expected_queries="$(jq --compact-output '[.queries[].id] | sort' "$manifest")"
for suite_file in "$v1_suite" "$v2_suite"; do
  jq --exit-status \
    --arg benchmark_definition_sha256 "$benchmark_definition_hash" \
    --argjson expected_queries "$expected_queries" \
    '
      .schema_version == 2 and
      .graphdb_version == "11.4.0" and
      .benchmark_definition_sha256 == $benchmark_definition_sha256 and
      (.warmups | type == "number") and
      (.measured_runs | type == "number" and . > 0) and
      .queries == $expected_queries
    ' "$suite_file" >/dev/null
done
for index_file in "$v1_index" "$v2_index"; do
  jq --exit-status '
    .schema_version == 2 and
    (.variant == "v1" or .variant == "v2") and
    (.prefix_tree | type == "string" and length > 0) and
    (.precision | type == "number" and . > 0) and
    (.indexing_time_seconds | type == "number" and . >= 0) and
    (.index_size_bytes | type == "number" and . > 0)
  ' "$index_file" >/dev/null
done
for corpus_summary in "$v1_corpus_summary" "$v2_corpus_summary"; do
  jq --exit-status '
    .schema_version == 1 and
    (.variant == "v1" or .variant == "v2") and
    (.row_count | type == "number" and . >= 0) and
    (.canonical_sha256 | type == "string" and length == 64)
  ' "$corpus_summary" >/dev/null
done

v1_warmups="$(jq '.warmups' "$v1_suite")"
v2_warmups="$(jq '.warmups' "$v2_suite")"
v1_runs="$(jq '.measured_runs' "$v1_suite")"
v2_runs="$(jq '.measured_runs' "$v2_suite")"
if [ "$v1_warmups" != "$v2_warmups" ] || [ "$v1_runs" != "$v2_runs" ]; then
  echo "v1 and v2 used different warm-up or measured-run counts" >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
report_part="$report_file.part"
comparison_valid=true
cleanup() {
  rm -rf -- "$temporary_dir"
  rm -f "$report_part"
}
trap cleanup EXIT HUP INT TERM

rows_file="$temporary_dir/query-rows.md"
: > "$rows_file"

for query_id in $(jq --raw-output '.queries[].id' "$manifest"); do
  v1_summary="$results_root/v1/queries/$query_id/summary.json"
  v2_summary="$results_root/v2/queries/$query_id/summary.json"
  for summary_file in "$v1_summary" "$v2_summary"; do
    if [ ! -f "$summary_file" ]; then
      echo "Missing query summary: $summary_file" >&2
      exit 1
    fi
    jq --exit-status --arg query_id "$query_id" '
      .schema_version == 1 and
      .query_id == $query_id and
      .stable_output == true and
      (.minimum_seconds | type == "number" and . > 0) and
      (.median_seconds | type == "number" and . > 0) and
      (.maximum_seconds | type == "number" and . > 0) and
      (.row_count | type == "number") and
      (.canonical_sha256 | type == "string" and length == 64)
    ' "$summary_file" >/dev/null
  done

  v1_min="$(jq --raw-output '.minimum_seconds' "$v1_summary")"
  v1_median="$(jq --raw-output '.median_seconds' "$v1_summary")"
  v1_max="$(jq --raw-output '.maximum_seconds' "$v1_summary")"
  v2_min="$(jq --raw-output '.minimum_seconds' "$v2_summary")"
  v2_median="$(jq --raw-output '.median_seconds' "$v2_summary")"
  v2_max="$(jq --raw-output '.maximum_seconds' "$v2_summary")"
  v1_rows="$(jq --raw-output '.row_count' "$v1_summary")"
  v2_rows="$(jq --raw-output '.row_count' "$v2_summary")"
  v1_hash="$(jq --raw-output '.canonical_sha256' "$v1_summary")"
  v2_hash="$(jq --raw-output '.canonical_sha256' "$v2_summary")"

  if [ "$v1_rows" = "$v2_rows" ] && [ "$v1_hash" = "$v2_hash" ]; then
    output_status="MATCH"
    speed_ratio="$(
      jq --null-input --raw-output \
        --argjson v1 "$v1_median" \
        --argjson v2 "$v2_median" \
        '($v1 / $v2 * 1000 | round) / 1000'
    )×"
  else
    output_status="DIFFER"
    speed_ratio="n/a"
    comparison_valid=false
  fi

  printf '| `%s` | %s (%s–%s) | %s (%s–%s) | %s | %s / %s | %s |\n' \
    "$query_id" \
    "$v1_median" "$v1_min" "$v1_max" \
    "$v2_median" "$v2_min" "$v2_max" \
    "$speed_ratio" \
    "$v1_rows" "$v2_rows" \
    "$output_status" >> "$rows_file"
done

equivalence_rows_file="$temporary_dir/equivalence-rows.md"
equivalence_pairs_file="$temporary_dir/equivalence-pairs.tsv"
: > "$equivalence_rows_file"
jq --raw-output '
  .queries[] |
  select(.equivalent_to != null) |
  [.id, .equivalent_to] |
  @tsv
' "$manifest" > "$equivalence_pairs_file"

tab="$(printf '\t')"
while IFS="$tab" read -r scalar_query indexed_query; do
  for variant in v1 v2; do
    scalar_summary="$results_root/$variant/queries/$scalar_query/summary.json"
    indexed_summary="$results_root/$variant/queries/$indexed_query/summary.json"
    scalar_rows="$(jq --raw-output '.row_count' "$scalar_summary")"
    indexed_rows="$(jq --raw-output '.row_count' "$indexed_summary")"
    scalar_hash="$(jq --raw-output '.canonical_sha256' "$scalar_summary")"
    indexed_hash="$(jq --raw-output '.canonical_sha256' "$indexed_summary")"
    scalar_median="$(jq --raw-output '.median_seconds' "$scalar_summary")"
    indexed_median="$(jq --raw-output '.median_seconds' "$indexed_summary")"

    if [ "$scalar_rows" = "$indexed_rows" ] &&
      [ "$scalar_hash" = "$indexed_hash" ]; then
      equivalence_status="MATCH"
      index_speedup="$(
        jq --null-input --raw-output \
          --argjson scalar "$scalar_median" \
          --argjson indexed "$indexed_median" \
          '($scalar / $indexed * 1000 | round) / 1000'
      )×"
    else
      equivalence_status="DIFFER"
      index_speedup="n/a"
      comparison_valid=false
    fi

    printf '| %s | `%s` | `%s` | %s | %s | %s | %s |\n' \
      "$variant" \
      "$indexed_query" \
      "$scalar_query" \
      "$indexed_median" \
      "$scalar_median" \
      "$index_speedup" \
      "$equivalence_status" >> "$equivalence_rows_file"
  done
done < "$equivalence_pairs_file"

partition_statuses=""
for variant in v1 v2; do
  intersects="$results_root/$variant/queries/sf-intersects-region/run-1/results.canonical.jsonl"
  disjoint="$results_root/$variant/queries/sf-disjoint-region/run-1/results.canonical.jsonl"
  corpus="$results_root/$variant/corpus/results.canonical.jsonl"
  for partition_file in "$intersects" "$disjoint" "$corpus"; do
    if [ ! -f "$partition_file" ]; then
      echo "Missing partition artifact: $partition_file" >&2
      exit 1
    fi
  done

  overlap_file="$temporary_dir/$variant-overlap"
  union_file="$temporary_dir/$variant-union"
  LC_ALL=C comm -12 "$intersects" "$disjoint" > "$overlap_file"
  LC_ALL=C sort --merge "$intersects" "$disjoint" > "$union_file"

  if [ ! -s "$overlap_file" ] && cmp --silent "$union_file" "$corpus"; then
    partition_status="PASS"
  else
    partition_status="FAIL"
    comparison_valid=false
  fi
  partition_statuses="$partition_statuses $variant=$partition_status"
done

v1_corpus_rows="$(jq --raw-output '.row_count' "$v1_corpus_summary")"
v2_corpus_rows="$(jq --raw-output '.row_count' "$v2_corpus_summary")"
v1_corpus_hash="$(jq --raw-output '.canonical_sha256' "$v1_corpus_summary")"
v2_corpus_hash="$(jq --raw-output '.canonical_sha256' "$v2_corpus_summary")"
if [ "$v1_corpus_rows" = "$v2_corpus_rows" ] &&
  [ "$v1_corpus_hash" = "$v2_corpus_hash" ]; then
  corpus_status="MATCH"
else
  corpus_status="DIFFER"
  comparison_valid=false
fi

v1_revision="$(jq --raw-output '.plugin_revision' "$v1_suite")"
v2_revision="$(jq --raw-output '.plugin_revision' "$v2_suite")"
v1_index_time="$(jq --raw-output '.indexing_time_seconds' "$v1_index")"
v2_index_time="$(jq --raw-output '.indexing_time_seconds' "$v2_index")"
v1_index_size="$(jq --raw-output '.index_size_bytes' "$v1_index")"
v2_index_size="$(jq --raw-output '.index_size_bytes' "$v2_index")"
v1_prefix_tree="$(jq --raw-output '.prefix_tree' "$v1_index")"
v2_prefix_tree="$(jq --raw-output '.prefix_tree' "$v2_index")"
v1_precision="$(jq --raw-output '.precision' "$v1_index")"
v2_precision="$(jq --raw-output '.precision' "$v2_index")"

mkdir -p "$(dirname "$report_file")"
{
  echo "# GeoSPARQL benchmark report"
  echo
  echo "GraphDB: 11.4.0"
  echo
  echo "Warm-up executions per query: $v1_warmups"
  echo
  echo "Measured executions per query: $v1_runs"
  echo
  echo "| Variant | Plugin revision | Prefix tree | Precision | Index build (s) | Index size (bytes) |"
  echo "| --- | --- | --- | ---: | ---: | ---: |"
  echo "| v1 | \`$v1_revision\` | $v1_prefix_tree | $v1_precision | $v1_index_time | $v1_index_size |"
  echo "| v2 | \`$v2_revision\` | $v2_prefix_tree | $v2_precision | $v2_index_time | $v2_index_size |"
  echo
  echo "## Query results"
  echo
  echo "Times are median seconds with the measured minimum–maximum in parentheses."
  echo "The ratio is v1 median divided by v2 median; values above 1 favour v2."
  echo
  echo "| Query | v1 median (range) | v2 median (range) | v1/v2 | Rows v1/v2 | Output |"
  echo "| --- | ---: | ---: | ---: | ---: | --- |"
  cat "$rows_file"
  echo
  echo "## Index effectiveness"
  echo
  echo "The speedup is scalar-function median divided by indexed-property median."
  echo "Values above 1 mean the spatial index was faster than the full scan."
  echo "A speedup is only reported when the complete canonical outputs match."
  echo
  echo "| Variant | Indexed query | Scalar query | Indexed median (s) | Scalar median (s) | Index speedup | Output |"
  echo "| --- | --- | --- | ---: | ---: | ---: | --- |"
  cat "$equivalence_rows_file"
  echo
  echo "## Correctness checks"
  echo
  for partition_entry in $partition_statuses; do
    partition_variant="${partition_entry%%=*}"
    partition_status="${partition_entry#*=}"
    echo "- $partition_variant intersects/disjoint partition: **$partition_status**"
  done
  echo "- v1/v2 canonical geometry corpus: **$corpus_status** ($v1_corpus_rows / $v2_corpus_rows rows)"
  echo
  if [ "$comparison_valid" = true ]; then
    echo "Overall comparison: **VALID**"
  else
    echo "Overall comparison: **INVALID**"
  fi
} > "$report_part"
mv "$report_part" "$report_file"

cat "$report_file"
echo
echo "Saved benchmark report to $report_file"

if [ "$comparison_valid" != true ]; then
  exit 1
fi
