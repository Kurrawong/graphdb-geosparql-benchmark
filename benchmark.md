# Benchmark methodology

## Objective

This benchmark compares the performance and query behaviour of two GeoSPARQL
implementations running in the same GraphDB 11.4.0 environment:

- **v1:** the GeoSPARQL plugin bundled with
  `ontotext/graphdb:11.4.0`;
- **v2:** the Jena-backed
  `Kurrawong/graphdb-geosparql-plugin` built from a recorded Git commit.

The comparison covers:

1. spatial index build time and size;
2. index-backed spatial predicate response time;
3. returned row counts and complete result multisets; and
4. behavioural differences such as failures or unequal results.

The primary suite uses the Maldives OSM dataset and tests the public
index-backed `geo:` property relations. Scalar `geof:` functions and controlled
fixtures for projected coordinate systems, geometry collections, Egenhofer,
RCC8, DE-9IM, and incremental updates are outside the primary suite and will be
considered separately.

## Controlled environment

Only one GraphDB variant runs at a time. Both variants use:

- GraphDB 11.4.0;
- the same repository configuration;
- the same downloaded `mdv.osm.ttl`;
- the same JVM options and Docker resource allocation;
- the same host port and HTTP client;
- a separate, freshly rebuilt `maldives` repository and spatial index; and
- the same data-normalisation updates.

Before indexing, both variants remove every `geo:asWKT` literal whose lexical
form contains `GEOMETRYCOLLECTION`. This gives both implementations the same
queryable geometry corpus because v1 cannot evaluate those values reliably.
Geometry-collection support is therefore not measured by the primary suite.

The v2 `master` branch is resolved to a Git commit before its suite starts. The
same commit is used for every v2 build and query in that run and is recorded in
the results.

Benchmark runs should be performed on an otherwise idle host. GraphDB, Docker,
JVM, CPU, memory, storage, operating-system, and benchmark revision details
should remain unchanged between the v1 and v2 suites.

## Suite lifecycle

A complete comparison runs the following ordered lifecycle:

1. Clear previous generated results for v1.
2. Delete and recreate the v1 repository.
3. Import and normalise the dataset.
4. build a new v1 spatial index.
5. Run the complete query suite against v1.
6. Stop v1.
7. Repeat the same process for v2.
8. Generate a report only after both suites complete successfully.

The benchmark must not reuse a repository or spatial index from a previous
suite. A failed suite must not be reported using stale measurements. Each
completed suite records a benchmark-definition fingerprint covering the
manifest, every referenced predicate query, and the geometry-corpus query. The
report rejects results when that fingerprint no longer matches the current
benchmark definition.

## Query construction

Primary queries use index-backed property relations such as:

```sparql
?geometry geo:sfWithin "POLYGON(...)"^^geo:wktLiteral .
```

They do not use an equivalent `FILTER(geof:sfWithin(...))`, because scalar
functions bypass the plugin's Lucene candidate-selection path and measure a
different execution mode.

Unless a query explicitly tests bound argument handling, its result shape is:

```sparql
PREFIX geo: <http://www.opengis.net/ont/geosparql#>

SELECT ?geometry ?wkt
WHERE {
  ?geometry geo:asWKT ?wkt .
  ?geometry geo:relation "QUERY GEOMETRY"^^geo:wktLiteral .
}
```

The primary predicate queries:

- do not use `DISTINCT`, `ORDER BY`, `OPTIONAL`, or unrelated RDF joins;
- return the complete geometry/WKT result multiset;
- use constants fixed before either variant is measured; and
- preserve subject/object order because that order can select a different
  candidate traversal path.

Sorting and hashing happen in the client after the timed HTTP request.

## Primary query matrix

| Query ID | Relation and shape | Intended coverage |
| --- | --- | --- |
| `sf-within-region` | `?geometry geo:sfWithin REGION` | Existing high-cardinality baseline |
| `sf-intersects-region` | `?geometry geo:sfIntersects REGION` | Envelope candidates followed by exact evaluation |
| `sf-disjoint-region` | `?geometry geo:sfDisjoint REGION` | High-cardinality disjoint evaluation with substantial result transfer |
| `sf-disjoint-cover` | `?geometry geo:sfDisjoint DATASET_COVER` | Zero-result disjoint evaluation with minimal response-transfer cost |
| `sf-contains-point` | `?geometry geo:sfContains INTERIOR_POINT` | Selective inverse relation |
| `sf-touches-vertex` | `?geometry geo:sfTouches VERTEX_POINT` | Boundary-sensitive exact evaluation |
| `sf-crosses-line` | `?geometry geo:sfCrosses CROSSING_LINE` | Behavioural comparison of asymmetric GeoSPARQL and symmetric JTS crossing semantics |
| `sf-crosses-line-compatible` | `CROSSING_LINE geo:sfCrosses ?geometry` | Matching `L/A` and `L/L` crossing results for performance comparison |
| `sf-overlaps-box` | `?geometry geo:sfOverlaps OVERLAP_BOX` | Polygon/polygon topology |
| `sf-equals-point` | `?geometry geo:sfEquals VERTEX_POINT` | Behavioural comparison of point equality semantics |
| `sf-equals-line` | `?geometry geo:sfEquals KNOWN_LINE` | Matching selective line equality for performance comparison |
| `subject-bound-within` | `KNOWN_NODE geo:sfWithin ?geometry` | Subject-bound candidate traversal and argument order |
| `bound-bound-within` | `KNOWN_NODE geo:sfWithin KNOWN_POLYGON` | Exact evaluation with Lucene bypassed |

The `sfDisjoint` cases are intentionally separate. `sf-disjoint-region`
measures a high-cardinality disjoint query together with a substantial result
transfer. `sf-disjoint-cover` uses a polygon that covers the retained dataset
and therefore returns no rows. This isolates the server-side candidate
selection and relation-evaluation cost from JSON serialisation and transfer
without assuming that either implementation uses a particular index strategy.

The original `sf-crosses-line` and `sf-equals-point` cases are retained as
behavioural comparisons because their outputs differ between the
implementations:

- GeoSPARQL 1.1 defines `sfCrosses` for `P/L`, `P/A`, `L/A`, and `L/L`.
  The original query places each candidate geometry on the left and the line
  on the right. v1 follows JTS's symmetric extension and also returns `A/L`
  polygon matches, while v2 follows the GeoSPARQL type directions.
- GeoSPARQL 1.1 prescribes the `TFFFTFFFT` matrix for `sfEquals`. v2 applies
  that matrix to the point case, while v1 follows JTS topological equality
  (`T*F**FFF*`).

Those two cases measure and document observable query behaviour, but their
latencies are not like-for-like performance comparisons because their outputs
differ. Each therefore has a companion query whose outputs are expected to
match:

- `sf-crosses-line-compatible` places `CROSSING_LINE` on the left, exercising
  the GeoSPARQL-defined `L/A` and `L/L` directions in both variants.
- `sf-equals-line` compares against an existing LineString. Equal non-empty
  lines satisfy both the GeoSPARQL matrix and JTS topological equality.

The generated report must only calculate cross-variant performance ratios for
queries whose complete canonical outputs match.

## Fixed query geometries

`REGION` is the polygon used by the original benchmark:

```text
POLYGON((
  71.71689397797601 7.419094102713061,
  72.27946321523228 -1.1898124287125,
  74.76601924390499 -1.2010613645552013,
  74.1471930829231 7.597572649973657,
  71.71689397797601 7.419094102713061
))
```

The validated `DATASET_COVER` is:

```text
POLYGON((49 -2, 81 -2, 81 27, 49 27, 49 -2))
```

All source WKT coordinates fall strictly inside this polygon. The calibrated
`sf-disjoint-cover` result is empty for both variants, while each implementation
still exercises its relation-specific candidate path.

The selective topology constants are:

```text
INTERIOR_POINT = POINT(73.5214547 1.8638413)
VERTEX_POINT   = POINT(73.5157973 1.8526223)
CROSSING_LINE  = LINESTRING(73.510 1.860, 73.530 1.860)
KNOWN_LINE     = LINESTRING(
  73.5195271 1.8601495,
  73.5188448 1.8587406
)
OVERLAP_BOX    = POLYGON((
  73.520 1.855,
  73.530 1.855,
  73.530 1.865,
  73.520 1.865,
  73.520 1.855
))
```

The bound resources are:

```text
KNOWN_NODE    = https://osm2rdf.cs.uni-freiburg.de/rdf/geom#osmnode_4707747257
KNOWN_POLYGON = https://osm2rdf.cs.uni-freiburg.de/rdf/geom#osmway_20108239
```

All constants must be checked during implementation to ensure that they
produce the intended non-empty, empty, boundary, crossing, or overlap
conditions. They must not be tuned independently for v1 and v2.

## Measurement protocol

Each query is run in a fixed order for both variants. The default protocol is:

1. one unmeasured warm-up execution; then
2. three measured executions.

The number of warm-ups and measured executions should be configurable, but the
same values must be used for both variants. The complete output is validated on
every measured execution.

The timed interval is the complete localhost HTTP request as observed by
`curl`, including GraphDB query execution, result serialisation, and response
transfer. It excludes client-side canonicalisation, sorting, hashing, and
report generation.

For every measured execution, record:

- query ID and iteration;
- variant, GraphDB version, and plugin revision;
- HTTP status;
- response time in seconds;
- returned row count; and
- SHA-256 of the sorted canonical result multiset.

For each query and variant, report all measured times and calculate the minimum,
median, maximum, and relative v1/v2 median. The median is the primary comparative
latency.

Index build time and on-disk index size are recorded once per fresh variant
suite and are not included in query response times.

## Output validation

Performance results are meaningful only when the implementations return
equivalent output.

For each query:

- every measured iteration for one variant must have the same row count and
  canonical hash;
- the v1 and v2 row counts must match;
- the v1 and v2 canonical hashes must match; and
- HTTP errors, truncated results, invalid JSON, or unstable output make the
  query comparison invalid.

The `sf-intersects-region` and `sf-disjoint-region` results provide an
additional invariant: for the eligible non-empty geometry corpus, the two
result sets must not overlap and together must cover the corpus. This invariant
should be checked by canonical geometry identifiers rather than inferred only
from counts.

Differences are reported rather than hidden. A report may describe a behavioural
difference, but it must not present unequal or incomplete outputs as a valid
performance comparison.

## Generated report

The final report should contain:

- environment and revision metadata;
- dataset and normalisation information;
- spatial index build time and size;
- one row per query with v1 and v2 timing statistics;
- row counts and output-match status;
- relative median performance;
- the intersects/disjoint partition check; and
- any failures or behavioural differences.

Raw JSON responses, canonical JSON Lines, per-iteration metrics, hashes, and the
generated Markdown report remain under `benchmark-results/` and are not
committed.

## Follow-up suites

The following are intentionally deferred:

- representative Egenhofer and RCC8 relations;
- caller-supplied DE-9IM `relate`;
- scalar `geof:` functions;
- projected and cross-CRS fixtures;
- controlled non-empty and empty `GEOMETRYCOLLECTION` fixtures;
- WKT/GML compatibility;
- incremental indexing and update propagation; and
- legacy-index rejection and forced reindex behaviour.
