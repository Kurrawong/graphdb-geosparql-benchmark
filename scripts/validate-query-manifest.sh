#!/bin/sh

set -eu

manifest="${1:-queries/manifest.json}"
queries_dir="${2:-queries}"

jq --exit-status '
  .schema_version == 1 and
  .canonical_variables == ["result", "wkt"] and
  (.queries | type == "array" and length > 0) and
  ([.queries[].id] | length == (unique | length)) and
  ([.queries[].file] | length == (unique | length)) and
  (.queries | map(.id)) as $query_ids |
  all(
    .queries[];
    .id as $query_id |
    .equivalent_to as $equivalent_to |
    (.id | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.file | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*[.]rq$")) and
    (.description | type == "string" and length > 0) and
    (
      $equivalent_to == null or
      (
        ($equivalent_to | type == "string") and
        $equivalent_to != $query_id and
        ($query_ids | index($equivalent_to)) != null
      )
    )
  )
' "$manifest" >/dev/null

for query_file in $(jq --raw-output '.queries[].file' "$manifest"); do
  path="$queries_dir/$query_file"
  if [ ! -f "$path" ]; then
    echo "Manifest query file does not exist: $path" >&2
    exit 1
  fi
  if ! grep -Eq 'SELECT[[:space:]]+\?result[[:space:]]+\?wkt' "$path"; then
    echo "Query must project ?result and ?wkt in that order: $path" >&2
    exit 1
  fi
done

if [ ! -f "$queries_dir/geometry-corpus.rq" ]; then
  echo "Missing corpus validation query: $queries_dir/geometry-corpus.rq" >&2
  exit 1
fi

echo "Validated $(jq '.queries | length' "$manifest") benchmark queries"
