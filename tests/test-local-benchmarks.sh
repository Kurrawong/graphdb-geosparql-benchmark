#!/bin/sh

set -eu

repository_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT HUP INT TERM
real_task="$(command -v task)"
(cd "$repository_dir" && "$real_task" --dry benchmark:initialise-local \
  GRAPHDB_URL=http://graphdb.invalid SPATIAL_INDEX_DIR=/tmp/index) \
  > "$temporary_dir/task-plan.log" 2>&1
grep -Fq 'initialise' "$temporary_dir/task-plan.log"
grep -Fq 'remove-geometry-collection-wkts' "$temporary_dir/task-plan.log"
grep -Fq 'enable-spatial-index' "$temporary_dir/task-plan.log"
fixture="$temporary_dir/plugin checkout"
fake_bin="$temporary_dir/bin"
mkdir -p "$fixture" "$fake_bin"
git -C "$fixture" init --quiet
printf 'target/\n' > "$fixture/.gitignore"
printf 'original\n' > "$fixture/source.txt"
git -C "$fixture" add .
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit --quiet -m 'test: create build input'

cat > "$fake_bin/mvn" <<'SH'
#!/bin/sh
set -eu
if [ "$1" = --version ]; then
  echo 'Fixture Maven, Java 25'
  exit 0
fi
if [ "${FAKE_MAVEN_FAIL:-false}" = true ]; then exit 1; fi
test "$*" = '--batch-mode -DskipTests clean package'
mkdir -p target/archive/geosparql-plugin
cp source.txt target/archive/geosparql-plugin/
if [ -f extra.txt ]; then cp extra.txt target/archive/geosparql-plugin/; fi
jar cf target/geosparql-plugin-graphdb-plugin.zip -C target/archive geosparql-plugin
SH
cat > "$fake_bin/java" <<'SH'
#!/bin/sh
echo 'Fixture Java 25' >&2
SH
chmod +x "$fake_bin/mvn" "$fake_bin/java"
export PATH="$fake_bin:$repository_dir/tests/fixtures/fake-bin:$PATH"

clean_build="$temporary_dir/clean"
"$repository_dir/scripts/build-local-plugin.sh" "$fixture" "$clean_build" >/dev/null
commit="$(git -C "$fixture" rev-parse HEAD)"
archive_hash="$(sha256sum "$clean_build/plugin.zip" | awk '{print $1}')"
jq -e --arg commit "$commit" --arg hash "$archive_hash" '
  .source_commit == $commit and .dirty == false and .archive_sha256 == $hash
' "$clean_build/source.json" >/dev/null
cmp "$fixture/source.txt" "$clean_build/geosparql-plugin/source.txt"

printf 'edited\n' > "$fixture/source.txt"
printf 'new source\n' > "$fixture/extra.txt"
dirty_build="$temporary_dir/dirty"
"$repository_dir/scripts/build-local-plugin.sh" "$fixture" "$dirty_build" >/dev/null
jq -e '.dirty == true and (.source_status | contains("extra.txt"))' \
  "$dirty_build/source.json" >/dev/null
cmp "$fixture/source.txt" "$dirty_build/geosparql-plugin/source.txt"
cmp "$fixture/extra.txt" "$dirty_build/geosparql-plugin/extra.txt"
if cmp -s "$clean_build/plugin.zip" "$dirty_build/plugin.zip"; then
  echo "Working tree changes did not change the plugin archive" >&2
  exit 1
fi
if FAKE_MAVEN_FAIL=true "$repository_dir/scripts/build-local-plugin.sh" \
  "$fixture" "$clean_build" >/dev/null 2>&1; then
  echo "A failed Maven build was accepted" >&2
  exit 1
fi
test "$archive_hash" = "$(sha256sum "$clean_build/plugin.zip" | awk '{print $1}')"

cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$LOCAL_CALLS_FILE"
case "$*" in
  'image inspect --format {{.Id}} fixture/graphdb:12') echo 'sha256:base-runtime' ;;
  'inspect --format {{.Image}} fixture-container') echo "sha256:$GRAPHDB_V2_CONTAINER" ;;
  'compose --profile v2 build graphdb-geosparql-v2')
    test -d "$GEOSPARQL_BUILD_CONTEXT/geosparql-plugin"
    test -f "$GEOSPARQL_V2_DOCKERFILE"
    ;;
  'compose --profile v2 up --detach graphdb-geosparql-v2') mkdir -p "$GRAPHDB_V2_HOME" ;;
  'compose --profile v2 ps --quiet graphdb-geosparql-v2') echo fixture-container ;;
  'compose --profile v2 exec --no-TTY graphdb-geosparql-v2 java -version') echo 'Fixture Java 25' >&2 ;;
  'compose --profile v2 down graphdb-geosparql-v2') ;;
  *) echo "Unexpected Docker invocation: $*" >&2; exit 1 ;;
esac
SH
cat > "$fake_bin/task" <<'SH'
#!/bin/sh
set -eu
printf 'task %s\n' "$*" >> "$LOCAL_CALLS_FILE"
case "$1" in
  download-data) ;;
  benchmark:initialise-local)
    mkdir -p "$BENCHMARK_RESULTS_DIR/v2"
    printf '%s\n' '{"schema_version":2,"variant":"v2","prefix_tree":"QUAD","precision":11,"indexing_time_seconds":1,"index_size_bytes":1000}' \
      > "$BENCHMARK_RESULTS_DIR/v2/index-metrics.json"
    ;;
  *) echo "Unexpected task invocation: $*" >&2; exit 1 ;;
esac
if [ "$1" = "${FAKE_TASK_FAIL:-}" ]; then exit 1; fi
SH
chmod +x "$fake_bin/docker" "$fake_bin/task"
export GRAPHDB_IMAGE=fixture/graphdb:12
export BENCHMARK_GRAPHDB_VERSION=12-test
export BENCHMARK_LOCAL_DIR="$temporary_dir/local-builds"
export BENCHMARK_RESULTS_DIR="$temporary_dir/local-results"
export BENCHMARK_WARMUPS=0
export BENCHMARK_RUNS=1
export FAKE_VARIANT=v2
export LOCAL_CALLS_FILE="$temporary_dir/local-calls"

for run_name in baseline candidate; do
  (cd "$temporary_dir" && "$repository_dir/scripts/run-local-benchmark.sh" \
    'plugin checkout' "$run_name") >/dev/null
  jq -e '
    .graphdb_version == "12-test" and .plugin_source.dirty == true and
    .runtime.runtime_image_id == "sha256:base-runtime" and
    .runtime.java == "Fixture Java 25"
  ' "$BENCHMARK_RESULTS_DIR/$run_name/v2/suite.json" >/dev/null
done
grep -Fq 'compose --profile v2 down graphdb-geosparql-v2' "$LOCAL_CALLS_FILE"
calls_hash="$(sha256sum "$LOCAL_CALLS_FILE" | awk '{print $1}')"
if "$repository_dir/scripts/run-local-benchmark.sh" "$fixture" baseline >/dev/null 2>&1; then
  echo "An existing run was overwritten" >&2
  exit 1
fi
test "$calls_hash" = "$(sha256sum "$LOCAL_CALLS_FILE" | awk '{print $1}')"
if BENCHMARK_RESULTS_DIR="$temporary_dir/another-results" \
  "$repository_dir/scripts/run-local-benchmark.sh" "$fixture" baseline >/dev/null 2>&1; then
  echo "An existing GraphDB home was reused for a new result directory" >&2
  exit 1
fi
test "$calls_hash" = "$(sha256sum "$LOCAL_CALLS_FILE" | awk '{print $1}')"
if FAKE_TASK_FAIL=benchmark:initialise-local "$repository_dir/scripts/run-local-benchmark.sh" \
  "$fixture" failed >/dev/null 2>&1; then
  echo "A failed initialization was accepted" >&2
  exit 1
fi
test "$(tail -1 "$LOCAL_CALLS_FILE")" = 'compose --profile v2 down graphdb-geosparql-v2'

export BENCHMARK_COMPARISON=identical
export BENCHMARK_BASELINE_RESULTS="$BENCHMARK_RESULTS_DIR/baseline/v2"
export BENCHMARK_CANDIDATE_RESULTS="$BENCHMARK_RESULTS_DIR/candidate/v2"
report="$temporary_dir/local-report.md"
generate_report() {
  "$repository_dir/scripts/generate-benchmark-report.sh" \
    "$repository_dir/queries/manifest.json" "$BENCHMARK_RESULTS_DIR" "$report"
}
generate_report >/dev/null
grep -Fq '21 matching, 0 expected differences, 0 unexpected results' "$report"
grep -Fq '| Query | baseline median (range) | candidate median (range)' "$report"
grep -Fq 'GraphDB: 12-test' "$report"

candidate_suite="$BENCHMARK_CANDIDATE_RESULTS/suite.json"
cp "$candidate_suite" "$temporary_dir/suite.json"
jq '.runtime.runtime_image_id = "sha256:another-runtime"' "$temporary_dir/suite.json" > "$candidate_suite"
if generate_report >/dev/null 2>&1; then
  echo "Different runtime images were accepted" >&2
  exit 1
fi
jq '.runtime.java = "Different Java"' "$temporary_dir/suite.json" > "$candidate_suite"
if generate_report >/dev/null 2>&1; then
  echo "Different Java runtimes were accepted" >&2
  exit 1
fi
jq '.graphdb_version = "different"' "$temporary_dir/suite.json" > "$candidate_suite"
if generate_report >/dev/null 2>&1; then
  echo "Different GraphDB versions were accepted" >&2
  exit 1
fi
cp "$temporary_dir/suite.json" "$candidate_suite"
candidate_index="$BENCHMARK_CANDIDATE_RESULTS/index-metrics.json"
cp "$candidate_index" "$temporary_dir/index.json"
jq '.precision = 12' "$temporary_dir/index.json" > "$candidate_index"
if generate_report >/dev/null 2>&1; then
  echo "Different index precision was accepted" >&2
  exit 1
fi
cp "$temporary_dir/index.json" "$candidate_index"

changed_summary="$BENCHMARK_CANDIDATE_RESULTS/queries/sf-equals-point/summary.json"
jq '.row_count = 1 | .canonical_sha256 = ("0" * 64)' "$changed_summary" > "$temporary_dir/summary.json"
mv "$temporary_dir/summary.json" "$changed_summary"
if generate_report >/dev/null; then
  echo "A migration exception hid a local output regression" >&2
  exit 1
fi
grep -Fq 'UNEXPECTED DIFFERENCE' "$report"
grep -Fq 'Correctness expectations: **FAIL**' "$report"

echo "Local benchmark tests passed (archive provenance, lifecycle, identical outputs, runtime checks)"
