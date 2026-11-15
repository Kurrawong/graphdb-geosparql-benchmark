#!/usr/bin/env python3
"""Check targeted fixtures, entity references, and known-result validation."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


targeted = load('targeted', 'scripts/generate-targeted-dataset.py')
validator = load('validator', 'scripts/validate-synthetic-results.py')


class TargetedDatasetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def generate(self, workload, name=None, profile='native'):
        count = None if workload == 'guardrails' else 1500 if workload == 'paging' else 100
        output = self.root / (name or workload)
        targeted.generate(output, workload, count, profile)
        return output

    def test_every_workload_is_reproducible_and_all_queries_have_references(self):
        for workload in targeted.WORKLOADS:
            first, second = self.generate(workload, workload + '-a'), self.generate(workload, workload + '-b')
            for path in first.rglob('*'):
                if path.is_file():
                    self.assertEqual(path.read_bytes(), (second / path.relative_to(first)).read_bytes())
            manifest = json.loads((first / 'queries/manifest.json').read_text())
            references = [entry for entry in manifest['queries'] if 'equivalent_to' in entry]
            self.assertEqual(2 * len(references), len(manifest['queries']))

    def test_feature_reference_checks_any_source_without_filtering_the_output_source(self):
        path = self.generate('paging')
        query = (path / 'queries/geof-within-page-below.rq').read_text()
        self.assertIn('FILTER EXISTS', query)
        self.assertIn('geof:sfWithin(?sourceWkt,', query)
        self.assertNotIn('geof:sfWithin(?wkt,', query)
        known = json.loads((path / 'known-results.json').read_text())
        self.assertEqual(known['sf-within-page-below'], 1001)
        meta = json.loads((path / 'dataset.json').read_text())
        self.assertEqual([meta['lookup_expectations']['sf-within-page-' + label]['candidate_documents']
                          for label in ['below', 'at', 'above']], [998, 1000, 1002])

    def test_pruning_fixture_has_known_counts_on_each_side_of_strict_half(self):
        path = self.generate('pruning')
        meta = json.loads((path / 'dataset.json').read_text())
        expectations = [meta['lookup_expectations']['sf-disjoint-pruning-' + label]
                        for label in ['below', 'at', 'above']]
        self.assertEqual([item['certified_excluded_documents'] for item in expectations], [98, 100, 102])
        self.assertEqual([item['pruning_selected'] for item in expectations], [False, False, True])

    def test_known_result_counts_and_full_hashes_are_both_required(self):
        dataset = self.generate('equality')
        meta = json.loads((dataset / 'dataset.json').read_text())
        manifest = json.loads((dataset / 'queries/manifest.json').read_text())
        known = json.loads((dataset / 'known-results.json').read_text())
        results = self.root / 'results'
        (results / 'corpus').mkdir(parents=True)
        targeted.geometry.write_json(results / 'corpus/summary.json', {'row_count': 100, 'canonical_sha256': 'c' * 64})
        targeted.geometry.write_json(results / 'suite.json', {
            'dataset': meta, 'queries': sorted(entry['id'] for entry in manifest['queries']),
            'warmups': 1, 'measured_runs': 3})
        for entry in manifest['queries']:
            directory = results / 'queries' / entry['id']
            directory.mkdir(parents=True)
            targeted.geometry.write_json(directory / 'summary.json', {
                'query_id': entry['id'], 'stable_output': True, 'warmups': 1, 'measured_runs': 3,
                'row_count': known[entry['id']], 'canonical_sha256': str(known[entry['id']]).zfill(64)})
        self.assertEqual(validator.validate(dataset, results)['indexed_scalar_pairs'], 3)
        path = results / 'queries/sf-equals-polygon/summary.json'
        value = json.loads(path.read_text())
        value['canonical_sha256'] = 'f' * 64
        targeted.geometry.write_json(path, value)
        with self.assertRaisesRegex(ValueError, 'Indexed/scalar outputs differ'):
            validator.validate(dataset, results)

    def test_mixed_queries_preserve_both_argument_orders(self):
        path = self.generate('mixed-crs')
        query = (path / 'queries/geof-disjoint-projected-subject-bound.rq').read_text()
        self.assertIn('geof:sfDisjoint("<http://www.opengis.net/def/crs/EPSG/0/3857>', query)
        self.assertIn(', ?wkt)', query)

    def test_guardrails_are_fixed_small_and_preserve_empty_and_collection_sources(self):
        path = self.generate('guardrails')
        meta = json.loads((path / 'dataset.json').read_text())
        self.assertEqual(meta['geometries'], 13)
        self.assertTrue(meta['preserve_geometry_collections'])
        text = (path / 'data.ttl').read_text()
        self.assertIn('POINT EMPTY', text)
        self.assertIn('GEOMETRYCOLLECTION EMPTY', text)
        self.assertIn('EPSG/0/3031', text)

    def test_batches_bind_both_geometry_arguments_before_the_relation(self):
        path = self.generate('bound-batch')
        query = (path / 'queries/sf-batch-within.rq').read_text()
        self.assertIn('VALUES (?result ?wkt ?bound)', query)
        self.assertIn('?wkt geo:sfWithin ?bound', query)
        self.assertNotIn('geo:asWKT', query)

    def test_invalid_parameters_are_rejected_without_creating_output(self):
        for workload, count, profile in [('paging', 100, 'native'), ('pruning', 100, 'projected'),
                                         ('equality', 101, 'native'), ('bound-batch', 10100, 'native'),
                                         ('guardrails', 100, 'native')]:
            path = self.root / workload
            with self.assertRaises(ValueError):
                targeted.generate(path, workload, count, profile)
            self.assertFalse(path.exists())

    def test_projected_equality_and_topology_use_explicit_projected_literals(self):
        for workload in ['equality', 'topology', 'large-geometries']:
            path = self.generate(workload, profile='projected')
            meta = json.loads((path / 'dataset.json').read_text())
            self.assertEqual(meta['source_crs'], {targeted.geometry.PROJECTED: 100})


if __name__ == '__main__':
    unittest.main()
