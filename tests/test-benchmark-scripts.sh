#!/bin/sh

set -eu

repository_dir="$(
  CDPATH= cd -- "$(dirname "$0")/.." &&
    pwd
)"
temporary_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

results_dir="$temporary_dir/results"
fake_path="$repository_dir/tests/fixtures/fake-bin:$PATH"

invalid_manifest="$temporary_dir/invalid-manifest.json"
jq '(.queries[] | select(.id == "geof-within-region") | .equivalent_to) = "missing-query"' \
  "$repository_dir/queries/manifest.json" > "$invalid_manifest"
if "$repository_dir/scripts/validate-query-manifest.sh" \
  "$invalid_manifest" "$repository_dir/queries" >/dev/null 2>&1; then
  echo "Manifest validation unexpectedly accepted a missing equivalent query" >&2
  exit 1
fi

malformed_manifest="$temporary_dir/malformed-manifest.json"
jq '(.queries[] | select(.id == "geof-within-region") | .equivalent_to) = false' \
  "$repository_dir/queries/manifest.json" > "$malformed_manifest"
if "$repository_dir/scripts/validate-query-manifest.sh" \
  "$malformed_manifest" "$repository_dir/queries" >/dev/null 2>&1; then
  echo "Manifest validation unexpectedly accepted a non-string equivalent query" >&2
  exit 1
fi

for variant in v1 v2; do
  mkdir -p "$results_dir/$variant"
  if [ "$variant" = "v1" ]; then
    fake_time="4.0"
    plugin_revision="bundled-with-graphdb-11.4.0"
    index_time="10.0"
    index_size="1000"
    scalar_time="8.0"
  else
    fake_time="2.0"
    plugin_revision="test-v2-commit"
    index_time="5.0"
    index_size="700"
    scalar_time="6.0"
  fi

  PATH="$fake_path" \
    FAKE_CURL_TIME="$fake_time" \
    FAKE_CURL_SCALAR_TIME="$scalar_time" \
    BENCHMARK_RESULTS_DIR="$results_dir" \
    BENCHMARK_WARMUPS=1 \
    BENCHMARK_RUNS=3 \
    "$repository_dir/scripts/run-benchmark-suite.sh" \
      "$variant" \
      "http://graphdb.invalid" \
      "maldives" \
      "$plugin_revision" >/dev/null

  jq --null-input \
    --arg variant "$variant" \
    --arg prefix_tree "QUAD" \
    --argjson precision "11" \
    --argjson indexing_time_seconds "$index_time" \
    --argjson index_size_bytes "$index_size" \
    '{
      schema_version: 2,
      variant: $variant,
      prefix_tree: $prefix_tree,
      precision: $precision,
      indexing_time_seconds: $indexing_time_seconds,
      index_size_bytes: $index_size_bytes
    }' > "$results_dir/$variant/index-metrics.json"
done

expected_definition_hash="$(
  "$repository_dir/scripts/benchmark-definition-sha256.sh" \
    "$repository_dir/queries/manifest.json" \
    "$repository_dir/queries"
)"
for suite_file in "$results_dir/v1/suite.json" "$results_dir/v2/suite.json"; do
  jq --exit-status \
    --arg expected_definition_hash "$expected_definition_hash" \
    '
      .schema_version == 2 and
      .benchmark_definition_sha256 == $expected_definition_hash
    ' "$suite_file" >/dev/null
done

report_file="$results_dir/report.md"
"$repository_dir/scripts/generate-benchmark-report.sh" \
  "$repository_dir/queries/manifest.json" \
  "$results_dir" \
  "$report_file" >/dev/null

assert_report_contains() {
  expected="$1"
  if ! grep -Fq "$expected" "$report_file"; then
    echo "Report does not contain: $expected" >&2
    cat "$report_file" >&2
    exit 1
  fi
}

assert_report_contains 'Overall comparison: **VALID**'
assert_report_contains \
  '| `sf-within-region` | 4.0 (4.0–4.0) | 2.0 (2.0–2.0) | 2× |'
assert_report_contains '| v1 | `sf-within-region` | `geof-within-region` | 4.0 | 8.0 | 2× | MATCH |'
assert_report_contains '| v2 | `sf-within-region` | `geof-within-region` | 2.0 | 6.0 | 3× | MATCH |'
assert_report_contains '| v1 | `sf-intersects-region` | `geof-intersects-region` | 4.0 | 8.0 | 2× | MATCH |'
assert_report_contains '| v1 | `bundled-with-graphdb-11.4.0` | QUAD | 11 | 10.0 | 1000 |'
assert_report_contains 'v1 intersects/disjoint partition: **PASS**'
assert_report_contains 'v2 intersects/disjoint partition: **PASS**'
assert_report_contains 'v1/v2 canonical geometry corpus: **MATCH** (2 / 2 rows)'

changed_queries_dir="$temporary_dir/changed-queries"
cp -R "$repository_dir/queries" "$changed_queries_dir"
printf '\n# Fingerprint regression test\n' \
  >> "$changed_queries_dir/sf-within-region.rq"
if "$repository_dir/scripts/generate-benchmark-report.sh" \
  "$changed_queries_dir/manifest.json" \
  "$results_dir" \
  "$report_file" >/dev/null 2>&1; then
  echo "Report unexpectedly accepted results from a changed query definition" >&2
  exit 1
fi

v1_scalar_summary="$results_dir/v1/queries/geof-within-region/summary.json"
v1_scalar_hash="$(jq --raw-output '.canonical_sha256' "$v1_scalar_summary")"
jq '.canonical_sha256 = ("0" * 64)' "$v1_scalar_summary" \
  > "$v1_scalar_summary.part"
mv "$v1_scalar_summary.part" "$v1_scalar_summary"

if "$repository_dir/scripts/generate-benchmark-report.sh" \
  "$repository_dir/queries/manifest.json" \
  "$results_dir" \
  "$report_file" >/dev/null; then
  echo "Report unexpectedly accepted unequal indexed/scalar output" >&2
  exit 1
fi
assert_report_contains '| v1 | `sf-within-region` | `geof-within-region` | 4.0 | 8.0 | n/a | DIFFER |'
jq --arg canonical_sha256 "$v1_scalar_hash" \
  '.canonical_sha256 = $canonical_sha256' "$v1_scalar_summary" \
  > "$v1_scalar_summary.part"
mv "$v1_scalar_summary.part" "$v1_scalar_summary"

v2_summary="$results_dir/v2/queries/sf-equals-point/summary.json"
jq '.canonical_sha256 = ("0" * 64)' "$v2_summary" \
  > "$v2_summary.part"
mv "$v2_summary.part" "$v2_summary"

if "$repository_dir/scripts/generate-benchmark-report.sh" \
  "$repository_dir/queries/manifest.json" \
  "$results_dir" \
  "$report_file" >/dev/null; then
  echo "Report unexpectedly accepted unequal output" >&2
  exit 1
fi
assert_report_contains 'Overall comparison: **INVALID**'

echo "Benchmark script tests passed"
