#!/usr/bin/env python3
"""Check a complete synthetic run against its scalar reference and known results."""

import argparse
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text())


def validate(dataset, results):
    metadata = read(dataset / 'dataset.json')
    for name, expected in metadata['files_sha256'].items():
        path = dataset / name
        if not path.resolve().is_relative_to(dataset.resolve()):
            raise ValueError('Dataset file escapes dataset directory')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'Dataset file changed: {name}')
    suite = read(results / 'suite.json')
    if suite.get('dataset') != metadata:
        raise ValueError('Suite does not identify this exact generated dataset')
    manifest = read(dataset / 'queries/manifest.json')
    known = read(dataset / 'known-results.json')
    records = {}
    for entry in manifest['queries']:
        item = read(results / 'queries' / entry['id'] / 'summary.json')
        if item['query_id'] != entry['id'] or item['stable_output'] is not True:
            raise ValueError(f'Incomplete or unstable query: {entry["id"]}')
        if item['measured_runs'] != suite['measured_runs'] or item['warmups'] != suite['warmups']:
            raise ValueError(f'Measurement protocol differs: {entry["id"]}')
        records[entry['id']] = item
        if entry['id'] in known and item['row_count'] != known[entry['id']]:
            raise ValueError(f'Known result differs: {entry["id"]}')
    if suite['queries'] != sorted(records):
        raise ValueError('Incomplete suite query inventory')
    pairs = 0
    for entry in manifest['queries']:
        if 'equivalent_to' not in entry:
            continue
        scalar, indexed = records[entry['id']], records[entry['equivalent_to']]
        if (scalar['row_count'], scalar['canonical_sha256']) != (indexed['row_count'], indexed['canonical_sha256']):
            raise ValueError(f'Indexed/scalar outputs differ: {entry["equivalent_to"]}')
        pairs += 1
    corpus = read(results / 'corpus/summary.json')
    if corpus['row_count'] != metadata['geometries']:
        raise ValueError('Corpus does not contain the generated geometry count')
    for query_id in metadata.get('corpus_equivalent_queries', ['geof-within-cover', 'geof-disjoint-outside']):
        item = records[query_id]
        if (item['row_count'], item['canonical_sha256']) != (corpus['row_count'], corpus['canonical_sha256']):
            raise ValueError(f'Known full-corpus query does not return the complete corpus: {query_id}')
    return {'queries': len(records), 'indexed_scalar_pairs': pairs, 'known_results': len(known),
            'corpus_rows': corpus['row_count'], 'profile': metadata['profile'],
            'distribution': metadata['distribution'], 'status': 'pass'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset', type=Path)
    parser.add_argument('results', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.dataset, args.results), indent=2))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f'Synthetic validation failed: {error}\n')
