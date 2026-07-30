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
the [GraphDB license documentation](https://graphdb.ontotext.com/documentation/11.2/set-up-your-license.html)
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
7. Enables the GeoSPARQL spatial index and reports its build time and on-disk
   size.

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

## Run a complete comparison

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
5. Runs the benchmark query once and saves the response and measurements.
6. Stops the selected variant, including when the query fails.

The v2 suite resolves `master` to one commit before building and uses that same
commit throughout the run. Set `GEOSPARQL_V2_REF` to benchmark a chosen commit:

```sh
GEOSPARQL_V2_REF=<commit-sha> task benchmark:v2
```

`task benchmark:report` validates both metric files before comparing them. It
prints the report to standard output and saves it as
`benchmark-results/report.md`. The report contains each variant's response
time, row count, spatial indexing time and size, canonical output hash, plugin
revision, whether the outputs match, and the relative query execution speed.

These suites deliberately rebuild the repository and index for each variant,
so they take substantially longer than rerunning only the query. They measure
one cold query after initialization. For reliable comparisons, use the same
machine and Docker resource allocation and avoid concurrent workloads.

## Run only the benchmark query

With either variant running:

```sh
task benchmark-query
```

The query returns only the spatial result tuple: feature, geometry, and WKT.
The task detects the active variant and records its output under
`benchmark-results/v1/` or `benchmark-results/v2/`.

The HTTP status and response time cover query execution and transfer of the
complete JSON response. Canonicalization happens afterward and is not included
in the reported query time. The task prints the following to standard output
and persists the measurements in the variant's `metrics.json`:

- The HTTP status and response time in seconds.
- The number of result bindings.
- A SHA-256 of the sorted feature/geometry/WKT result multiset.
- The GraphDB version and plugin revision.
- The paths to the original JSON and canonical JSON Lines results.
- Whether the hash matches the other variant's latest saved result, when one is
  available.

A curl failure or invalid JSON fails the task without replacing the previous
successful result. The complete per-variant output layout is:

```text
benchmark-results/
├── v1/
│   ├── metrics.json
│   ├── index-metrics.json
│   ├── results.json
│   ├── results.canonical.jsonl
│   └── results.sha256
└── v2/
    ├── metrics.json
    ├── index-metrics.json
    ├── results.json
    ├── results.canonical.jsonl
    └── results.sha256
```

Run the query multiple times if both cold-cache and warm-cache performance are
of interest, and do not compare a first run from one variant with a warmed-up
run from the other.

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
