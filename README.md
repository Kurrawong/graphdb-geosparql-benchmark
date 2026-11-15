# GraphDB GeoSPARQL benchmark

This project compares the bundled GraphDB GeoSPARQL plugin (v1) with the
Kurrawong GeoSPARQL plugin (v2) on GraphDB 11.4.0.

Only one variant runs at a time. Both variants are available at
<http://localhost:7200> and use separate persistent GraphDB home directories.
See [benchmark.md](benchmark.md) for the benchmark methodology, query matrix,
measurement protocol, and output-validation rules.

## Prerequisites

- Docker with Docker Compose
- [Task](https://taskfile.dev/)
- `curl`
- `bzip2`
- `git`
- `jq`
- Python 3.9 or newer for synthetic datasets

The GraphDB containers are configured with a 10 GB maximum JVM heap. Ensure
Docker has enough memory available.

## Configure the GraphDB license

GraphDB 11 requires a license. The first `up` attempt for each variant may stop
when it reaches the GeoSPARQL configuration step and report that no license is
set.

With the selected variant still running, open <http://localhost:7200> and use
**Setup → License → Set new license** to upload or paste your license. Then run
the same `up` task again:

```sh
task v1:up
# or
task v2:up
```

The v1 and v2 services use separate GraphDB homes, so configure the license once
for each variant. The clean tasks preserve those homes and their licenses. See
the [GraphDB 11.4 license documentation](https://graphdb.ontotext.com/documentation/11.4/set-up-your-license.html)
for the Workbench and file-based installation options.

## Start a benchmark variant

Start GraphDB with the bundled GeoSPARQL v1 plugin:

```sh
task v1:up
```

Start GraphDB with the Kurrawong GeoSPARQL v2 plugin:

```sh
task v2:up
```

Each `up` task:

1. Downloads and decompresses the Maldives OSM dataset when it is not already
   present under `downloads/`.
2. Stops the other GraphDB variant.
3. Starts the selected variant.
4. Creates the `maldives` repository when necessary.
5. Imports the dataset when the repository is empty.
6. Removes `geo:asWKT` literals containing `GEOMETRYCOLLECTION`, reporting the
   number removed and the update time.
7. Enables the GeoSPARQL spatial index and reports its build time, on-disk
   size, prefix-tree type, and precision.

The same unsupported WKT values are removed from both repositories so the
variants are benchmarked against equivalent data. The v1 task also configures
the plugin to ignore any other unsupported geometries before enabling its
index.

The v2 image is built from the current `master` revision of
<https://github.com/Kurrawong/graphdb-geosparql-plugin>. To benchmark a specific
revision instead:

```sh
GEOSPARQL_V2_REF=<commit-sha> task v2:up
```

The resolved commit is recorded in the image at
`/opt/graphdb/geosparql-v2-source-commit.txt`.

To rebuild the v2 image from scratch after upstream plugin changes, bypassing
all Docker build cache layers:

```sh
task v2:build-no-cache
```

The regular cached image build is also available separately:

```sh
task v2:build
```

## Synthetic datasets

Generate a reproducible workload with points, lines and four polygon forms
(rectangular, concave, holed and 64-vertex). Sources are split approximately
equally between points, lines and polygons. Choose `native` (CRS84), `projected`
(EPSG:3857), or `mixed`, with `uniform` or `clustered` placement:

```sh
python3 scripts/generate-synthetic-dataset.py \
  .local-benchmarks/datasets/mixed-uniform-100k \
  --profile mixed --distribution uniform --count 100000 --seed 40

BENCHMARK_DATASET_DIR="$PWD/.local-benchmarks/datasets/mixed-uniform-100k" \
  task benchmark:local PLUGIN_DIR=../graphdb-projects/graphdb-geosparql-plugin \
  RUN_NAME=mixed-uniform-baseline
```

Supply the compatible runtime, license and build environment described under
the local workflow below. The dataset switch does not change plugin build
dependencies; use the established GraphDB 11 SDK/compiler overrides when
building a checkout whose default dependency targets GraphDB 12.

Projected and mixed profiles require external Apache SIS EPSG reference data.
Set `GRAPHDB_SIS_DATA=/opt/graphdb/sis-data` and `GRAPHDB_SIS_DIR` to the host
directory containing `Databases/SpatialMetadata`. For a writable Derby database,
use a dedicated copy for each process with `GRAPHDB_SIS_MODE=rw`. The default
mount is read-only and is suitable only for CRS data prepared for read-only use.
Record the EPSG data version with comparisons. These settings configure the
runtime; they do not add reference data or dependencies to the plugin package.

The generator refuses existing output directories. It records the seed,
geometry/CRS counts, generator checksum, and hashes of the data, repository
configuration and queries in `dataset.json`. All profiles use a square spanning
10,000 EPSG:3857 map units near 20 E, 60 N. Fixture generation uses spherical Mercator formulas outside
the timed interval. Cross-CRS equivalence of straight polygon edges is not
assumed.

Every indexed query has a scalar counterpart using the same source geometry
literals and argument order. The scalar path bypasses Lucene; in the Jena-backed
plugin it provides the exact-evaluation reference. Queries include broad and
selective bounds, rectangular covers, concave interiors, holes, a bound above
the certified-rectangle coordinate limit, and reversed binding direction. Mixed
data additionally uses both CRS84 and projected bounds. Concave-bound names
describe shape dimensions; they do not promise particular pruning percentages.

The local runner records the dataset metadata and checks all indexed/scalar
result hashes, known zero/full results, and corpus size. Recheck a saved run:

```sh
python3 scripts/validate-synthetic-results.py \
  .local-benchmarks/datasets/mixed-uniform-100k \
  benchmark-results/local/mixed-uniform-baseline/v2

BENCHMARK_MANIFEST="$PWD/.local-benchmarks/datasets/mixed-uniform-100k/queries/manifest.json" \
  task benchmark:compare-local BASELINE=benchmark-results/local/mixed-uniform-baseline \
  CANDIDATE=benchmark-results/local/mixed-uniform-candidate

python3 tests/test-synthetic-datasets.py
```

Start with a small dataset (for example `--count 1200`) before timing 100,000
geometries. Compare the same generated dataset, query definitions, runtime,
index settings and measurement protocol across builds. Baseline output
differences must be reported as correctness differences; timings for different
outputs are not like-for-like speedups. Synthetic coverage supplements the
Maldives real-world workload. It does not establish universal CRS correctness.
The distribution profiles use EPSG:3857 as their only projected CRS.

### Targeted query workloads

Use separate controlled fixtures to exercise specific lookup and evaluation
paths without changing the distribution-profile baselines:

```sh
python3 scripts/generate-targeted-dataset.py \
  .local-benchmarks/datasets/paging-10k --workload paging --count 10000

BENCHMARK_DATASET_DIR="$PWD/.local-benchmarks/datasets/paging-10k" \
  task benchmark:local PLUGIN_DIR=../graphdb-projects/graphdb-geosparql-plugin \
  RUN_NAME=paging-baseline
```

| `--workload` | Coverage |
| --- | --- |
| `paging` | 998/1000/1002 native candidate documents, broad traversal, and a Feature with 1001 source geometries spanning a page |
| `pruning` | Native CRS84 disjoint queries with 49%, 50% and 51% certified exclusions around the strict-half selection threshold |
| `equality` | Matching lines and polygons, equal-envelope nonmatches, and unrelated envelopes |
| `large-geometries` | Dense polygons with thousands of vertices, hull-rejectable envelope false positives, holes, and true intersections |
| `mixed-crs` | CRS84/EPSG:3857 source mixtures with native and projected bounds in both argument orders |
| `bound-batch` | Fully bound literal relations and scalar references batched with `VALUES`, avoiding index traversal |
| `topology` | Controlled shared-edge touches, line/line and line/area crosses, and polygon overlaps |
| `guardrails` | Fixed 13-source checks for empties, collections, antimeridian and near-pole geometry, including EPSG:3031 |

Counts are geometry resources, each with one source geometry literal. Features
are separate entities. The paging workload associates several Geometry
resources with each Feature; its scalar reference uses `FILTER EXISTS` over
all default geometries. This preserves existential entity semantics and returns
every projected geometry row for a matching Feature, including a source that
does not itself satisfy the relation. Comparing only the displayed WKT would
give an incorrect reference.

Use counts divisible by 100, at least 1500 for `paging` and 100 for other
scalable workloads. Defaults are 10000, or 1000 for `bound-batch`; batches are
limited to 10000 pairs per HTTP request. `guardrails` has a fixed small corpus:
omit `--count`. The large-geometry fixture caps its complex-source cohort at 64
and increases the simple background when the count grows. Increasing its count
does not increase every source's vertex count.

`--profile projected` is available for paging, equality, large geometries,
topology and bound batches. Paging's 998/1000/1002 candidate counts apply only to
native lookup; projected prefix-cell lookup can retain more candidates.
Pruning requires `native`; mixed-CRS and guardrail fixtures select their own
source CRSs. Source and query literals retain their CRS and argument order.

The local runner preserves collections when the dataset requests it. The
Maldives workflow keeps its existing collection-removal policy. To initialise
a guardrail dataset manually through `benchmark:initialise-local`, pass
`PRESERVE_GEOMETRY_COLLECTIONS=true`; its corpus check rejects a run that loses
the collection sources. Guardrails measure a small supported fixture, not
collection or polar performance at large scale.

Validate these runs with the same `validate-synthetic-results.py` command.
Known row counts supplement complete indexed/reference result hashes. Keep
the fixed guardrails small while scaling the distribution and relevant
targeted workloads. Check generation and validation logic with:

```sh
python3 tests/test-synthetic-datasets.py
python3 tests/test-targeted-datasets.py
```

## Run a complete comparison

For comparisons between two builds of the Jena-backed plugin, use the local
workflow below. The original v1/v2 workflow compares the bundled implementation
with the replacement plugin and retains its declared semantic differences.

Configure the license for both variants before beginning. Then run these
commands in order:

```sh
task benchmark:v1
task benchmark:v2
task benchmark:report
```

Alternatively, run the same ordered workflow with one command:

```sh
task benchmark:all
```

Do not run other GraphDB workloads while a benchmark suite is in progress.
Each variant suite performs the same lifecycle:

1. Deletes that variant's previous saved benchmark result.
2. Stops the other variant.
3. Starts the selected variant temporarily and deletes its existing
   `maldives` repository and GeoSPARQL index.
4. Recreates the repository, imports the dataset, removes the same unsupported
   `GEOMETRYCOLLECTION` WKT literals, and builds a new spatial index.
5. Runs all queries listed in
   [`queries/manifest.json`](queries/manifest.json), with one warm-up and three
   measured executions of each query by default.
6. Captures the complete canonical geometry corpus for correctness checks.
7. Saves every response, canonical result multiset, hash, and measurement.
8. Verifies that each query produces stable output across measured executions.
9. Stops the selected variant, including when the query suite fails.

The v2 suite resolves `master` to one commit before building and uses that same
commit throughout the run. Set `GEOSPARQL_V2_REF` to benchmark a chosen commit:

```sh
GEOSPARQL_V2_REF=<commit-sha> task benchmark:v2
```

The repetition counts are configurable, but must be identical for v1 and v2:

```sh
BENCHMARK_WARMUPS=1 BENCHMARK_RUNS=5 task benchmark:all
```

## Benchmark a local plugin working tree

The local workflow builds the plugin from its working tree, including
uncommitted edits and new source files. Neither repository needs to be committed
or pushed. Maven may still download dependencies from its configured repositories.

In addition to the prerequisites above, install Maven and the JDK required by
the plugin checkout, including `jar` on `PATH`. Current plugin master targets
Java 25 and the GraphDB 12 SDK. Configure authorized Maven access for any restricted
SDK dependencies, and select a GraphDB runtime image that supports the resulting
plugin and Java bytecode. SDK version strings do not necessarily name published
Docker images.

From this benchmark checkout, configure the runtime and build tools. Replace
the example image and license paths with your available inputs:

```sh
export JAVA_HOME="$HOME/.jdks/openjdk-25.0.1"
export PATH="$JAVA_HOME/bin:$PATH"
export GRAPHDB_IMAGE=your-registry/graphdb:12-java25
export BENCHMARK_GRAPHDB_VERSION=12.0.0
export GRAPHDB_LICENSE_FILE=/path/to/graphdb.license
export BENCHMARK_WARMUPS=2
export BENCHMARK_RUNS=5
```

`GRAPHDB_IMAGE` and `BENCHMARK_GRAPHDB_VERSION` are required for local runs. The
version must identify the GraphDB distribution in that image. The workflow also
records the actual runtime image ID, plugin image ID and `java -version` output.
`GRAPHDB_LICENSE_FILE` is optional when the selected runtime supplies its license
or does not require one. When supplied, the file is copied into the run's GraphDB
home without displaying its contents.

First use an unchanged plugin checkout for the baseline:

```sh
task benchmark:local \
  PLUGIN_DIR=../graphdb-projects/graphdb-geosparql-plugin \
  RUN_NAME=master-baseline
```

After making local plugin changes, run the same command with a new name:

```sh
task benchmark:local \
  PLUGIN_DIR=../graphdb-projects/graphdb-geosparql-plugin \
  RUN_NAME=envelope-filter

task benchmark:compare-local \
  BASELINE=benchmark-results/local/master-baseline \
  CANDIDATE=benchmark-results/local/envelope-filter
```

Each run builds one plugin ZIP and one container image, creates a separate
GraphDB home, and imports and indexes a fresh repository. It saves results under
`benchmark-results/local/RUN_NAME/v2/`, then stops its container on success or
failure. Existing run names are rejected to preserve the baseline, including
partial runs. Use a new name when retrying a failed run. The original migration
results under `benchmark-results/v1` and `benchmark-results/v2` are preserved.

Plugin archives, source metadata and GraphDB homes live under the ignored
`.local-benchmarks/` directory. `BENCHMARK_LOCAL_DIR` can relocate these files;
`BENCHMARK_RESULTS_DIR` can relocate the parent directory containing named local
results. Each result records the source commit, dirty status, ZIP SHA-256 and
build-tool versions. A ZIP checksum identifies the built artifact, including
changes not represented by the commit alone. Maven runs `clean package` with
tests skipped; run the plugin's relevant correctness tests separately.

The local comparison requires identical canonical output for **every** query.
Migration exceptions for crossing and equality do not apply. It also rejects
different GraphDB versions, runtime image IDs, Java runtimes, prefix trees,
precisions, repetition counts, query definitions or geometry corpora. The report
is saved as `CANDIDATE/comparison.md` and labels the builds baseline/candidate.

Both workflows use localhost port 7200 by default; stop other services using
that port before running. Set `GRAPHDB_PORT` to use another local port for a
local run. Local tasks do not stop containers belonging to the migration workflow.

## Migration report validation

`task benchmark:report` refuses incomplete, stale, or differently configured
suites. Staleness is detected from a fingerprint covering the manifest, every
referenced benchmark query, and the geometry-corpus query. Report-only
`cross_variant_output` expectations are excluded because changing them does not
change query execution. The task prints the report to standard output and saves
it as
`benchmark-results/report.md`. For each query, the report contains minimum,
median, and maximum response times, row counts, output equality, and the
relative v1/v2 median. It also reports spatial indexing time, size, prefix tree,
and precision; plugin revisions; corpus equality; and the
`sfIntersects`/`sfDisjoint` partition check.
Cross-variant outputs are expected to match unless a query declares
`"cross_variant_output": "different"` in the manifest. Expected differences
are written with an unavailable performance ratio and do not fail the report.
An undeclared difference, or a declared difference that unexpectedly
disappears, fails the correctness check and makes the report task exit
unsuccessfully.

The suite includes full-scan `geof:sfWithin` and `geof:sfIntersects` scalar
baselines for the same large and selective Maldives regions as their indexed
`geo:` property queries. The report verifies that each indexed/scalar pair has
identical canonical output before reporting its index speedup:

```text
index speedup = scalar-function median / indexed-property median
```

Values above 1 mean the spatial index was faster; values below 1 mean the
full scan was faster. The large and selective regions show how index
effectiveness changes with result selectivity.

The `sf-crosses-line` and `sf-equals-point` queries deliberately expose known
behavioural differences and declare those differences in the query manifest.
They are reported as `EXPECTED DIFFERENCE`, while the final summary can still
report `Benchmark execution: COMPLETE` and `Correctness expectations: PASS`.
Use their matching-output companion queries,
`sf-crosses-line-compatible` and `sf-equals-line`, for like-for-like performance
comparisons. See [benchmark.md](benchmark.md#primary-query-matrix) for the
semantic rationale.

These suites deliberately rebuild the repository and index for each variant,
so they take substantially longer than rerunning only a query. Every query is
warmed independently before its measured executions. For reliable comparisons,
use the same machine and Docker resource allocation and avoid concurrent
workloads.

## Run queries against an existing variant

With either variant running:

```sh
task benchmark-query
```

This runs the complete query manifest without rebuilding the repository or
index. Run one selected query with:

```sh
BENCHMARK_QUERY_ID=sf-disjoint-region \
BENCHMARK_WARMUPS=0 \
BENCHMARK_RUNS=1 \
task benchmark-query
```

A selected-query run invalidates the variant's complete-suite metadata, so a
final report cannot accidentally combine it with older suite results.

The HTTP status and response time cover query execution and transfer of the
complete JSON response. Canonicalization happens afterward and is not included
in the reported query time. Each measured execution prints:

- The HTTP status and response time in seconds.
- The number of result bindings.
- A SHA-256 of the sorted geometry/WKT result multiset.

A curl failure, invalid JSON, missing projected binding, or unstable output
fails the query without replacing its previous successful result. The
per-variant output layout is:

```text
benchmark-results/
├── v1/
│   ├── index-metrics.json
│   ├── suite.json
│   ├── corpus/
│   │   ├── curl.txt
│   │   ├── results.json
│   │   ├── results.canonical.jsonl
│   │   ├── results.sha256
│   │   └── summary.json
│   └── queries/
│       └── <query-id>/
│           ├── summary.json
│           └── run-<n>/
│               ├── curl.txt
│               ├── metrics.json
│               ├── results.json
│               ├── results.canonical.jsonl
│               └── results.sha256
└── v2/
    └── ...
```

Run the static validation and deterministic fake-GraphDB tests without starting
GraphDB:

```sh
task benchmark:validate
```

## Stop a variant

Stop and remove the selected container while preserving its GraphDB home:

```sh
task v1:down
task v2:down
```

Delete the selected variant's `maldives` repository through the GraphDB REST API
and then stop its container:

```sh
task v1:down-clean
task v2:down-clean
```

The selected service must be running when its clean task begins. The clean tasks
permanently remove that variant's repository data through the REST API and
explicitly delete its `storage/GeoSPARQL` configuration and spatial index
directory. They preserve the surrounding GraphDB home, license, and downloaded
source dataset.

## Other tasks

List all public tasks:

```sh
task --list
```

Enable the spatial index manually on whichever variant is running:

```sh
task enable-spatial-index \
  SPATIAL_INDEX_DIR=graphdb-home-geosparql-v1/data/repositories/maldives/storage/GeoSPARQL
```

Use `graphdb-home-geosparql-v2` in the path when the v2 variant is running.
