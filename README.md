# GraphDB GeoSPARQL benchmark

This project compares the bundled GraphDB GeoSPARQL plugin (v1) with the
Kurrawong GeoSPARQL plugin (v2) on GraphDB 11.4.0.

Only one variant runs at a time. Both variants are available at
<http://localhost:7200> and use separate persistent GraphDB home directories.

## Prerequisites

- Docker with Docker Compose
- [Task](https://taskfile.dev/)
- `curl`
- `bzip2`
- `git`
- `jq`

The GraphDB containers are configured with a 10 GB maximum JVM heap. Ensure
Docker has enough memory available.

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
6. Enables the GeoSPARQL spatial index.

The v1 task also configures the plugin to ignore unsupported geometries before
enabling its index because v1 does not support the `GEOMETRYCOLLECTION` values
in the dataset.

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

## Run the benchmark query

With either variant running:

```sh
task benchmark-query
```

The task prints the number of result bindings to standard output. The HTTP
status and total request time are printed to standard error so they do not
interfere with the JSON result processing.

Run the query multiple times if both cold-cache and warm-cache performance are
of interest, and do not compare a first run from one variant with a warmed-up
run from the other.

## Stop a variant

Stop and remove the selected container while preserving its GraphDB home:

```sh
task v1:down
task v2:down
```

Stop the selected container and remove its GraphDB home:

```sh
task v1:down-clean
task v2:down-clean
```

The clean tasks permanently remove that variant's repository data and spatial
index. The downloaded source dataset is preserved.

## Other tasks

List all public tasks:

```sh
task --list
```

Enable the spatial index manually on whichever variant is running:

```sh
task enable-spatial-index
```
