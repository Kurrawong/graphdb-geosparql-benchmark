#!/usr/bin/env python3
"""Exercise dataset reproducibility and failures in synthetic result validation."""

import hashlib
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

    def generate(self, name='dataset', profile='native', distribution='uniform', seed=40, extent=10000):
        path = self.root / name
        generator.generate(path, profile, distribution, 48, seed, extent)
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

    def test_original_profiles_keep_their_generated_files(self):
        expected = {'native': 'e0171b54351150a8e21d6e06c3e3e293f608e8f4b9a93dc889261050b438cd4e',
                    'projected': '506275265a68a301530baf0f81621c71c1c65e461dc3eba5df9a36a6adeb5718',
                    'mixed': '5fc269efb8fd18c92f9bb0b6cba8a8176f60ef53b89822a74559effca3d1a56b'}
        for profile, digest in expected.items():
            path = self.generate(profile, profile)
            combined = hashlib.sha256()
            for file in sorted(path.rglob('*')):
                # dataset.json records the generator checksum, which changes with any generator edit.
                if file.is_file() and file.name != 'dataset.json':
                    combined.update(str(file.relative_to(path)).encode())
                    combined.update(file.read_bytes())
            self.assertEqual(combined.hexdigest(), digest, profile)
            self.assertNotIn('extent', json.loads((path / 'dataset.json').read_text()))

    def test_other_source_crs_profiles_label_and_order_their_coordinates(self):
        # Latitude comes first in the two geographic CRSs; the MGA grid writes easting then northing.
        cases = {'epsg4326': ('EPSG/0/4326', (60, 60.1), (20, 20.1)),
                 'gda2020': ('EPSG/0/7844', (-27.5, -27.4), (153, 153.1)),
                 'mga56': ('EPSG/0/7856', (400000, 410000), (6900000, 6910000))}
        for profile, (crs, first, second) in cases.items():
            path = self.generate(profile, profile)
            value = json.loads((path / 'dataset.json').read_text())
            self.assertEqual(list(value['source_crs']), ['http://www.opengis.net/def/crs/' + crs])
            point = next(line for line in (path / 'data.ttl').read_text().splitlines() if 'POINT(' in line)
            x, y = (float(part) for part in point.split('POINT(')[1].split(')')[0].split())
            self.assertTrue(first[0] <= x < first[1] and second[0] <= y < second[1], (profile, x, y))
            query = (path / 'queries/sf-within-native-bound.rq').read_text()
            self.assertIn('OGC/1.3/CRS84', query)
            self.assertIn(crs, (path / 'queries/sf-within-region.rq').read_text())

    def test_mga_grid_converts_to_longitude_and_latitude(self):
        longitude, latitude = generator.mga56_to_geographic(500000, 6957918)
        self.assertAlmostEqual(longitude, 153.0, places=9)
        self.assertAlmostEqual(latitude, -27.5024, places=4)
        path = self.generate('mixed-mga', 'mixed-mga56')
        value = json.loads((path / 'dataset.json').read_text())
        self.assertEqual(sorted(value['source_crs'].values()), [24, 24])
        native = next(line for line in (path / 'data.ttl').read_text().splitlines() if 'CRS84> POINT(' in line)
        x, y = (float(part) for part in native.split('POINT(')[1].split(')')[0].split())
        self.assertTrue(151.9 < x < 152.2 and -28.1 < y < -27.9, (x, y))

    def test_extent_scales_placement_and_bounds_and_is_recorded(self):
        narrow, wide = self.generate('narrow'), self.generate('wide', extent=500000)
        self.assertEqual(json.loads((wide / 'dataset.json').read_text())['extent'], 500000)
        self.assertNotEqual((narrow / 'data.ttl').read_bytes(), (wide / 'data.ttl').read_bytes())
        self.assertNotEqual((narrow / 'queries/sf-within-selective-region.rq').read_text(),
                            (wide / 'queries/sf-within-selective-region.rq').read_text())
        self.assertEqual(json.loads((narrow / 'known-results.json').read_text()),
                         json.loads((wide / 'known-results.json').read_text()))
        with self.assertRaises(ValueError):
            generator.generate(self.root / 'invalid-extent', 'native', 'uniform', 48, 40, 550)
        self.assertFalse((self.root / 'invalid-extent').exists())

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
