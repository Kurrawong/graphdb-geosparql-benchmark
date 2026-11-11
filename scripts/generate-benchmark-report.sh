#!/bin/sh

set -eu

manifest="${1:-queries/manifest.json}"
results_root="${2:-benchmark-results}"
report_file="${3:-$results_root/report.md}"
script_dir="$(dirname "$0")"
queries_dir="$(dirname "$manifest")"
comparison="${BENCHMARK_COMPARISON:-migration}"
case "$comparison" in
  migration) baseline_label=v1; candidate_label=v2 ;;
  identical) baseline_label=baseline; candidate_label=candidate ;;
  *) echo "BENCHMARK_COMPARISON must be migration or identical" >&2; exit 1 ;;
esac
baseline_dir="${BENCHMARK_BASELINE_RESULTS:-$results_root/v1}"
candidate_dir="${BENCHMARK_CANDIDATE_RESULTS:-$results_root/v2}"
variant_results_dir() {
  case "$1" in
    v1) printf '%s\n' "$baseline_dir" ;;
    v2) printf '%s\n' "$candidate_dir" ;;
  esac
}
variant_label() {
  case "$1" in
    v1) printf '%s\n' "$baseline_label" ;;
    v2) printf '%s\n' "$candidate_label" ;;
  esac
}

"$script_dir/validate-query-manifest.sh" "$manifest" "$queries_dir"

benchmark_definition_hash="$(
  "$script_dir/benchmark-definition-sha256.sh" "$manifest" "$queries_dir"
)"
v1_suite="$baseline_dir/suite.json"
v2_suite="$candidate_dir/suite.json"
v1_index="$baseline_dir/index-metrics.json"
v2_index="$candidate_dir/index-metrics.json"
v1_corpus_summary="$baseline_dir/corpus/summary.json"
v2_corpus_summary="$candidate_dir/corpus/summary.json"

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
      (.graphdb_version | type == "string" and length > 0) and
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

graphdb_version="$(jq --raw-output '.graphdb_version' "$v1_suite")"
if [ "$graphdb_version" != "$(jq --raw-output '.graphdb_version' "$v2_suite")" ]; then
  echo "Cannot compare different GraphDB versions" >&2
  exit 1
fi
if [ "$comparison" = identical ]; then
  for suite_file in "$v1_suite" "$v2_suite"; do
    jq --exit-status '
      (.runtime.runtime_image_id | type == "string" and length > 0) and
      (.runtime.java | type == "string" and length > 0) and
      (.plugin_source.source_commit | type == "string" and length > 0) and
      (.plugin_source.dirty | type == "boolean") and
      (.plugin_source.archive_sha256 | test("^[0-9a-f]{64}$"))
    ' "$suite_file" >/dev/null
  done
  baseline_runtime="$(jq --compact-output '.runtime | {runtime_image_id, java}' "$v1_suite")"
  candidate_runtime="$(jq --compact-output '.runtime | {runtime_image_id, java}' "$v2_suite")"
  if [ "$baseline_runtime" != "$candidate_runtime" ]; then
    echo "Cannot compare local builds with different GraphDB images or Java runtimes" >&2
    exit 1
  fi
fi
if [ "$(jq -c '[.prefix_tree, .precision]' "$v1_index")" != \
     "$(jq -c '[.prefix_tree, .precision]' "$v2_index")" ]; then
  echo "Cannot compare different prefix trees or index precisions" >&2
  exit 1
fi

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
correctness_valid=true
matching_outputs=0
expected_differences=0
unexpected_results=0
cleanup() {
  rm -rf -- "$temporary_dir"
  rm -f "$report_part"
}
trap cleanup EXIT HUP INT TERM

rows_file="$temporary_dir/query-rows.md"
: > "$rows_file"

for query_id in $(jq --raw-output '.queries[].id' "$manifest"); do
  v1_summary="$baseline_dir/queries/$query_id/summary.json"
  v2_summary="$candidate_dir/queries/$query_id/summary.json"
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
  expected_output="$(
    jq --raw-output --arg query_id "$query_id" '
      .queries[] |
      select(.id == $query_id) |
      (.cross_variant_output // "match")
    ' "$manifest"
  )"

  if [ "$comparison" = identical ]; then
    expected_output=match
  fi

  if [ "$v1_rows" = "$v2_rows" ] && [ "$v1_hash" = "$v2_hash" ]; then
    speed_ratio="$(
      jq --null-input --raw-output \
        --argjson v1 "$v1_median" \
        --argjson v2 "$v2_median" \
        '($v1 / $v2 * 1000 | round) / 1000'
    )×"
    if [ "$expected_output" = "match" ]; then
      output_status="MATCH"
      matching_outputs=$((matching_outputs + 1))
    else
      output_status="UNEXPECTED MATCH"
      unexpected_results=$((unexpected_results + 1))
      correctness_valid=false
    fi
  else
    speed_ratio="n/a"
    if [ "$expected_output" = "different" ]; then
      output_status="EXPECTED DIFFERENCE"
      expected_differences=$((expected_differences + 1))
    else
      output_status="UNEXPECTED DIFFERENCE"
      unexpected_results=$((unexpected_results + 1))
      correctness_valid=false
    fi
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
    scalar_summary="$(variant_results_dir "$variant")/queries/$scalar_query/summary.json"
    indexed_summary="$(variant_results_dir "$variant")/queries/$indexed_query/summary.json"
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
      correctness_valid=false
    fi

    printf '| %s | `%s` | `%s` | %s | %s | %s | %s |\n' \
      "$(variant_label "$variant")" \
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
  intersects="$(variant_results_dir "$variant")/queries/sf-intersects-region/run-1/results.canonical.jsonl"
  disjoint="$(variant_results_dir "$variant")/queries/sf-disjoint-region/run-1/results.canonical.jsonl"
  corpus="$(variant_results_dir "$variant")/corpus/results.canonical.jsonl"
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
    correctness_valid=false
  fi
  partition_statuses="$partition_statuses $(variant_label "$variant")=$partition_status"
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
  correctness_valid=false
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
  echo "GraphDB: $graphdb_version"
  echo
  echo "Comparison: $comparison"
  echo
  echo "Warm-up executions per query: $v1_warmups"
  echo
  echo "Measured executions per query: $v1_runs"
  echo
  echo "| Variant | Plugin revision | Prefix tree | Precision | Index build (s) | Index size (bytes) |"
  echo "| --- | --- | --- | ---: | ---: | ---: |"
  echo "| $baseline_label | \`$v1_revision\` | $v1_prefix_tree | $v1_precision | $v1_index_time | $v1_index_size |"
  echo "| $candidate_label | \`$v2_revision\` | $v2_prefix_tree | $v2_precision | $v2_index_time | $v2_index_size |"
  echo
  echo "## Query results"
  echo
  echo "Times are median seconds with the measured minimum–maximum in parentheses."
  echo "The ratio is $baseline_label median divided by $candidate_label median; values above 1 favour $candidate_label."
  if [ "$comparison" = identical ]; then
    echo "Every query must return identical canonical output; migration exceptions do not apply."
    echo
    echo "Runtime image: $(jq --raw-output '.runtime.runtime_image_id' "$v1_suite")"
    echo
    echo "| Build | Source commit | Dirty | Plugin ZIP SHA-256 |"
    echo "| --- | --- | --- | --- |"
    for variant in v1 v2; do
      suite="$(variant_results_dir "$variant")/suite.json"
      printf '| %s | `%s` | %s | `%s` |\n' "$(variant_label "$variant")" \
        "$(jq -r '.plugin_source.source_commit' "$suite")" \
        "$(jq -r '.plugin_source.dirty' "$suite")" \
        "$(jq -r '.plugin_source.archive_sha256' "$suite")"
    done
    echo
  else
    echo "Output expectations default to matching; declared behavioural differences are labelled EXPECTED DIFFERENCE."
  fi
  echo "UNEXPECTED DIFFERENCE and UNEXPECTED MATCH both fail the correctness expectations."
  echo
  echo "| Query | $baseline_label median (range) | $candidate_label median (range) | $baseline_label/$candidate_label | Rows $baseline_label/$candidate_label | Output |"
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
  echo "- $baseline_label/$candidate_label canonical geometry corpus: **$corpus_status** ($v1_corpus_rows / $v2_corpus_rows rows)"
  echo
  echo "Benchmark execution: **COMPLETE**"
  if [ "$correctness_valid" = true ]; then
    echo "Correctness expectations: **PASS**"
  else
    echo "Correctness expectations: **FAIL**"
  fi
  echo "Cross-variant outputs: **$matching_outputs matching, $expected_differences expected differences, $unexpected_results unexpected results**"
} > "$report_part"
mv "$report_part" "$report_file"

cat "$report_file"
echo
echo "Saved benchmark report to $report_file"

if [ "$correctness_valid" != true ]; then
  exit 1
fi
