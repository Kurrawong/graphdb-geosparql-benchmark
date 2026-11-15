#!/usr/bin/env python3
"""Exercise dataset reproducibility and failures in synthetic result validation."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


generator = load('generator', 'generate-synthetic-dataset.py')
validator = load('validator', 'validate-synthetic-results.py')


class SyntheticDatasetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def generate(self, name='dataset', profile='native', distribution='uniform', seed=40):
        path = self.root / name
        generator.generate(path, profile, distribution, 48, seed)
        return path

    def summaries(self, dataset):
        results = self.root / 'results'
        manifest = json.loads((dataset / 'queries/manifest.json').read_text())
        known = json.loads((dataset / 'known-results.json').read_text())
        results.mkdir()
        generator.write_json(results / 'suite.json', {
            'dataset': json.loads((dataset / 'dataset.json').read_text()),
            'queries': sorted(item['id'] for item in manifest['queries']),
            'warmups': 1, 'measured_runs': 3,
        })
        for entry in manifest['queries']:
            directory = results / 'queries' / entry['id']
            directory.mkdir(parents=True)
            count = known.get(entry['id'], 10)
            generator.write_json(directory / 'summary.json', {
                'query_id': entry['id'], 'stable_output': True,
                'warmups': 1, 'measured_runs': 3,
                'row_count': count, 'canonical_sha256': str(count).zfill(64),
            })
        (results / 'corpus').mkdir()
        generator.write_json(results / 'corpus/summary.json', {
            'row_count': 48, 'canonical_sha256': str(48).zfill(64),
        })
        return results

    def change_summary(self, results, query, **changes):
        path = results / 'queries' / query / 'summary.json'
        value = json.loads(path.read_text())
        value.update(changes)
        generator.write_json(path, value)

    def test_same_seed_reproduces_every_generated_file(self):
        for profile in ['native', 'projected', 'mixed']:
            for distribution in ['uniform', 'clustered']:
                first = self.generate(profile + distribution + 'a', profile, distribution)
                second = self.generate(profile + distribution + 'b', profile, distribution)
                for path in first.rglob('*'):
                    if path.is_file():
                        self.assertEqual(path.read_bytes(), (second / path.relative_to(first)).read_bytes())

    def test_profiles_include_every_geometry_type_and_expected_crs(self):
        for profile in ['native', 'projected', 'mixed']:
            path = self.generate(profile, profile)
            value = json.loads((path / 'dataset.json').read_text())
            self.assertEqual(sum(value['source_types'].values()), 48)
            self.assertEqual(set(value['source_types']), {'point', 'line', 'rectangle', 'concave', 'holed', 'complex'})
            self.assertEqual(len(value['source_crs']), 2 if profile == 'mixed' else 1)
            self.assertIn('rep:repositoryID "synthetic"', (path / 'repository-config.ttl').read_text())
            manifest = json.loads((path / 'queries/manifest.json').read_text())
            self.assertEqual(sum('equivalent_to' in entry for entry in manifest['queries']) * 2, len(manifest['queries']))

    def test_seed_changes_the_corpus(self):
        self.assertNotEqual((self.generate('first') / 'data.ttl').read_bytes(),
                            (self.generate('second', seed=41) / 'data.ttl').read_bytes())

    def test_existing_dataset_is_never_overwritten(self):
        path = self.generate()
        with self.assertRaises(ValueError):
            generator.generate(path, 'native', 'uniform', 48, 40)

    def test_small_dataset_is_rejected_before_creating_output(self):
        path = self.root / 'invalid'
        with self.assertRaises(ValueError):
            generator.generate(path, 'native', 'uniform', 1, 40)
        self.assertFalse(path.exists())

    def test_mixed_profile_requires_both_source_crs_blocks(self):
        path = self.root / 'invalid-mixed'
        with self.assertRaises(ValueError):
            generator.generate(path, 'mixed', 'uniform', 12, 40)
        self.assertFalse(path.exists())

    def test_validated_results_cover_every_query(self):
        dataset = self.generate(profile='mixed')
        result = validator.validate(dataset, self.summaries(dataset))
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['indexed_scalar_pairs'], 19)

    def test_same_row_count_with_a_different_result_set_is_rejected(self):
        dataset = self.generate()
        results = self.summaries(dataset)
        self.change_summary(results, 'sf-disjoint-thin', canonical_sha256='f' * 64)
        with self.assertRaisesRegex(ValueError, 'Indexed/scalar outputs differ'):
            validator.validate(dataset, results)

    def test_known_result_rejects_agreeing_but_wrong_evaluators(self):
        dataset = self.generate()
        results = self.summaries(dataset)
        for name in ['sf-disjoint-cover', 'geof-disjoint-cover']:
            self.change_summary(results, name, row_count=1)
        with self.assertRaisesRegex(ValueError, 'Known result differs'):
            validator.validate(dataset, results)

    def test_modified_input_is_rejected(self):
        dataset = self.generate()
        results = self.summaries(dataset)
        (dataset / 'data.ttl').write_text('')
        with self.assertRaisesRegex(ValueError, 'Dataset file changed'):
            validator.validate(dataset, results)

    def test_wrong_dataset_identity_is_rejected(self):
        dataset = self.generate()
        results = self.summaries(dataset)
        path = results / 'suite.json'
        value = json.loads(path.read_text())
        value['dataset']['seed'] = 41
        generator.write_json(path, value)
        with self.assertRaisesRegex(ValueError, 'exact generated dataset'):
            validator.validate(dataset, results)


if __name__ == '__main__':
    unittest.main()
