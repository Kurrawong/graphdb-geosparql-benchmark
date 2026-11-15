#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 PLUGIN_CHECKOUT RUN_NAME" >&2
  exit 1
fi

plugin_dir="$(CDPATH= cd -- "$1" && pwd)"
run_name="$2"
case "$run_name" in
  ''|*[!a-z0-9_-]*)
    echo "RUN_NAME must contain only lowercase letters, digits, underscores, or hyphens" >&2
    exit 1
    ;;
esac
: "${GRAPHDB_IMAGE:?Set GRAPHDB_IMAGE to a compatible GraphDB/JDK runtime image}"
: "${BENCHMARK_GRAPHDB_VERSION:?Set BENCHMARK_GRAPHDB_VERSION to the GraphDB version in that image}"
if [ -n "${GRAPHDB_LICENSE_FILE:-}" ] && [ ! -r "$GRAPHDB_LICENSE_FILE" ]; then
  echo "GRAPHDB_LICENSE_FILE does not name a readable license file" >&2
  exit 1
fi

repository_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$repository_dir"
repository_id=maldives
dataset_dir=""
if [ -n "${BENCHMARK_DATASET_DIR:-}" ]; then
  dataset_dir="$(CDPATH= cd -- "$BENCHMARK_DATASET_DIR" && pwd)"
  repository_id="$(jq --exit-status --raw-output '
    select(.schema_version == 1 and .repository_id == "synthetic") | .repository_id
  ' "$dataset_dir/dataset.json")"
  export BENCHMARK_DATASET_METADATA="$dataset_dir/dataset.json"
  export BENCHMARK_MANIFEST="$dataset_dir/queries/manifest.json"
  export BENCHMARK_QUERIES_DIR="$dataset_dir/queries"
  "$repository_dir/scripts/validate-query-manifest.sh" "$BENCHMARK_MANIFEST" "$BENCHMARK_QUERIES_DIR"
fi
results_root="${BENCHMARK_RESULTS_DIR:-$repository_dir/benchmark-results/local}"
mkdir -p "$results_root"
results_root="$(CDPATH= cd -- "$results_root" && pwd)"
run_dir="$results_root/$run_name"
if [ -e "$run_dir" ]; then
  echo "Results already exist at $run_dir; choose a new RUN_NAME" >&2
  exit 1
fi
local_root="${BENCHMARK_LOCAL_DIR:-$repository_dir/.local-benchmarks}"
mkdir -p "$local_root"
local_root="$(CDPATH= cd -- "$local_root" && pwd)"
build_dir="$local_root/build/$run_name"
export GEOSPARQL_BUILD_CONTEXT="$build_dir"
export GEOSPARQL_V2_DOCKERFILE="$repository_dir/Dockerfile.local"
export GEOSPARQL_V2_IMAGE="graphdb-geosparql-local:$run_name"
export GRAPHDB_V2_CONTAINER="graphdb-geosparql-local-$run_name"
export GRAPHDB_V2_HOME="$local_root/homes/$run_name"
export COMPOSE_PROJECT_NAME="geosparql-local-$run_name"
export BENCHMARK_RESULTS_DIR="$run_dir"
graphdb_url="http://localhost:${GRAPHDB_PORT:-7200}"
index_dir="$GRAPHDB_V2_HOME/data/repositories/$repository_id/storage/GeoSPARQL"
if [ -e "$GRAPHDB_V2_HOME" ]; then
  echo "GraphDB home already exists at $GRAPHDB_V2_HOME; choose a new RUN_NAME" >&2
  exit 1
fi

scripts/build-local-plugin.sh "$plugin_dir" "$build_dir"
docker compose --profile v2 build graphdb-geosparql-v2
mkdir -p "$run_dir/v2"
cp "$build_dir/source.json" "$run_dir/v2/plugin-source.json"
export BENCHMARK_PLUGIN_METADATA="$run_dir/v2/plugin-source.json"
if [ -n "${GRAPHDB_LICENSE_FILE:-}" ]; then
  mkdir -p "$GRAPHDB_V2_HOME/conf"
  cp "$GRAPHDB_LICENSE_FILE" "$GRAPHDB_V2_HOME/conf/graphdb.license"
fi
cleanup() {
  status="$?"
  trap - EXIT HUP INT TERM
  if ! docker compose --profile v2 down graphdb-geosparql-v2; then
    if [ "$status" -eq 0 ]; then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
docker compose --profile v2 up --detach graphdb-geosparql-v2

container_id="$(docker compose --profile v2 ps --quiet graphdb-geosparql-v2)"
image_id="$(docker inspect --format '{{.Image}}' "$container_id")"
runtime_image_id="$(docker image inspect --format '{{.Id}}' "$GRAPHDB_IMAGE")"
runtime_java="$(docker compose --profile v2 exec --no-TTY graphdb-geosparql-v2 java -version 2>&1)"
export BENCHMARK_RUNTIME_METADATA="$run_dir/v2/runtime.json"
jq --null-input --arg image "$GRAPHDB_IMAGE" --arg image_id "$image_id" \
  --arg runtime_image_id "$runtime_image_id" \
  --arg java "$runtime_java" \
  '{image: $image, runtime_image_id: $runtime_image_id, image_id: $image_id, java: $java}' \
  > "$BENCHMARK_RUNTIME_METADATA"

if [ -n "$dataset_dir" ]; then
  task benchmark:initialise-local GRAPHDB_URL="$graphdb_url" SPATIAL_INDEX_DIR="$index_dir" \
    REPOSITORY_ID="$repository_id" REPOSITORY_CONFIG="$dataset_dir/repository-config.ttl" \
    DATA_DIR="$dataset_dir" DATA_FILE=data.ttl
else
  task download-data
  task benchmark:initialise-local GRAPHDB_URL="$graphdb_url" SPATIAL_INDEX_DIR="$index_dir"
fi
revision="$(cat "$build_dir/source-commit.txt")"
scripts/run-benchmark-suite.sh v2 "$graphdb_url" "$repository_id" "$revision"
if [ -n "$dataset_dir" ]; then
  python3 scripts/validate-synthetic-results.py "$dataset_dir" "$run_dir/v2" \
    > "$run_dir/synthetic-validation.json"
fi
echo "Saved local benchmark to $run_dir/v2"
