#!/usr/bin/env python3
"""Generate controlled GeoSPARQL workloads with paired Jena reference queries."""

import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('synthetic', Path(__file__).with_name('generate-synthetic-dataset.py'))
geometry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(geometry)
WORKLOADS = ('paging', 'pruning', 'equality', 'large-geometries', 'mixed-crs',
             'bound-batch', 'topology', 'guardrails')


def source(wkt, projected=False):
    return f'<{geometry.PROJECTED if projected else geometry.CRS84}> {wkt}'


def term(value):
    return json.dumps(value) + '^^geo:wktLiteral'


def box(x1, y1, x2, y2, projected=False):
    return source(geometry.polygon([(x1, y1), (x2, y1), (x2, y2), (x1, y2)], projected), projected)


def point(x, y, projected=False):
    return source('POINT(' + geometry.coordinate((x, y), projected) + ')', projected)


class Dataset:
    def __init__(self, output, workload, profile):
        self.output, self.workload, self.profile = output, workload, profile
        output.mkdir(parents=True)
        (output / 'queries').mkdir()
        self.stream = (output / 'data.ttl').open('w')
        self.stream.write('@prefix geo: <http://www.opengis.net/ont/geosparql#> .\n'
                          '@prefix ex: <https://example.org/targeted/> .\n')
        self.manifest = {'schema_version': 1, 'canonical_variables': ['result', 'wkt'], 'queries': []}
        self.known, self.lookup = {}, {}
        self.count, self.features = 0, set()
        self.crs, self.types = Counter(), Counter()

    def add_geometry(self, value, feature=None):
        index = self.count
        self.count += 1
        feature = str(index) if feature is None else str(feature)
        self.features.add(feature)
        self.stream.write(f'ex:f{feature} a geo:Feature; geo:hasDefaultGeometry ex:g{index} .\n'
                          f'ex:g{index} a geo:Geometry; geo:asWKT {term(value)} .\n')
        crs = value[1:value.index('>')] if value.startswith('<') else geometry.CRS84
        self.crs[crs] += 1
        self.types[value.split('>')[-1].strip().split('(')[0].strip().lower()] += 1
        return f'ex:g{index}'

    def queries(self, name, indexed, scalar, description, rows=None):
        reference = name.replace('sf-', 'geof-', 1)
        for query_id, body in [(name, indexed), (reference, scalar)]:
            (self.output / 'queries' / (query_id + '.rq')).write_text(
                geometry.PREFIXES + 'PREFIX ex: <https://example.org/targeted/>\n'
                'SELECT ?result ?wkt WHERE {\n' + body + '\n}\n')
            entry = {'id': query_id, 'file': query_id + '.rq', 'description': description}
            if query_id == reference:
                entry['equivalent_to'] = name
            self.manifest['queries'].append(entry)
            if rows is not None:
                self.known[query_id] = rows

    def pair(self, name, relation, bound, description, rows=None, reverse=False, feature=False):
        bound = term(bound)
        base = ('  ?result geo:hasDefaultGeometry ?geometry .\n  ?geometry geo:asWKT ?wkt .\n'
                if feature else '  ?result geo:asWKT ?wkt .\n')
        indexed = f'{bound} geo:{relation} ?result' if reverse else f'?result geo:{relation} {bound}'
        candidate = '?sourceWkt' if feature else '?wkt'
        arguments = f'{bound}, {candidate}' if reverse else f'{candidate}, {bound}'
        scalar = f'FILTER(geof:{relation}({arguments}))'
        if feature:
            scalar = ('FILTER EXISTS { ?result geo:hasDefaultGeometry ?sourceGeometry .\n'
                      '    ?sourceGeometry geo:asWKT ?sourceWkt . ' + scalar + ' }')
        self.queries(name, base + '  ' + indexed + ' .', base + '  ' + scalar, description, rows)

    def finish(self, requested_count):
        self.stream.close()
        (self.output / 'queries/geometry-corpus.rq').write_text(
            geometry.PREFIXES + 'SELECT ?result ?wkt WHERE { ?result geo:asWKT ?wkt . }\n')
        geometry.write_json(self.output / 'queries/manifest.json', self.manifest)
        geometry.write_json(self.output / 'known-results.json', self.known)
        config = Path(__file__).resolve().parent.parent / 'maldives-config.ttl'
        (self.output / 'repository-config.ttl').write_text(config.read_text().replace(
            'rep:repositoryID "maldives"', 'rep:repositoryID "synthetic"'))
        metadata = {
            'schema_version': 1, 'repository_id': 'synthetic', 'workload': self.workload,
            'profile': self.profile, 'distribution': 'controlled', 'requested_count': requested_count,
            'geometries': self.count, 'feature_entities': len(self.features),
            'source_crs': dict(self.crs), 'source_types': dict(self.types),
            'corpus_equivalent_queries': [], 'preserve_geometry_collections': self.workload == 'guardrails',
            'lookup_expectations': self.lookup,
            'generator_sha256': geometry.digest(Path(__file__)),
            'geometry_helpers_sha256': geometry.digest(Path(geometry.__file__)),
            'files_sha256': {str(p.relative_to(self.output)): geometry.digest(p)
                             for p in sorted(self.output.rglob('*')) if p.is_file()},
            'limits': ['Controlled fixtures supplement the standard spatial distribution workloads',
                       'Known counts apply to each query, not to equivalent geometry edges across CRSs'],
        }
        geometry.write_json(self.output / 'dataset.json', metadata)
        return metadata


def paging(data, count, projected):
    for index in range(count):
        # One feature has enough sources to span a complete candidate page.
        feature = 'wide' if index < 1001 else 'group' + str((index - 1001) // 3)
        data.add_geometry(point(100 + index, 100, projected), feature)
    for label, selected in [('below', 499), ('at', 500), ('above', 501), ('broad', count)]:
        rows = 1001 if selected <= 1001 else count
        name = 'sf-within-page-' + label
        data.pair(name, 'sfWithin', box(0, 0, 99 + selected + .25, 200, projected),
                  'Feature-level containment with grouped sources around a candidate page boundary', rows,
                  feature=True)
        if not projected:
            data.lookup[name] = {'candidate_documents': 2 * selected}


def pruning(data, count, projected):
    positions = [(1, 1)] * 49 + [(6, 6), (8, 8)] + [(9.5, 9.5)] * 49
    for index in range(count):
        x, y = positions[index % 100]
        data.add_geometry(source(f'POINT({x} {y})'))
    for label, cut, fraction in [('below', 2, 49), ('at', 7, 50), ('above', 9, 51)]:
        bound = source(f'POLYGON((0 0,10 0,10 {cut},{cut} {cut},{cut} 10,0 10,0 0))')
        name = 'sf-disjoint-pruning-' + label
        data.pair(name, 'sfDisjoint', bound, 'Native eligible-source exclusion around the strict-half threshold',
                  count * (100 - fraction) // 100)
        data.lookup[name] = {'eligible_documents': 2 * count,
                             'certified_excluded_documents': 2 * count * fraction // 100,
                             'pruning_selected': fraction > 50}


def equality(data, count, projected):
    rectangle = box(100, 100, 200, 200, projected)
    triangle = source(geometry.polygon([(100, 100), (200, 100), (100, 200)], projected), projected)
    line = source('LINESTRING(' + ','.join(geometry.coordinate(p, projected)
                                         for p in [(100, 100), (200, 200)]) + ')', projected)
    distant = box(1000, 1000, 1100, 1100, projected)
    for index in range(count):
        data.add_geometry([rectangle, triangle, line, distant][index % 4])
    missing = source(geometry.polygon([(100, 100), (200, 100), (200, 200), (100, 200)], projected,
                                     [[(120, 120), (120, 180), (180, 180), (180, 120)]]), projected)
    for label, bound, rows in [('polygon', rectangle, count // 4), ('line', line, count // 4),
                               ('same-envelope-absent', missing, 0)]:
        data.pair('sf-equals-' + label, 'sfEquals', bound,
                  'Equality with equal-envelope nonmatches and unrelated envelopes', rows)


def dense_ring(points, vertices=4096):
    result = []
    for index in range(vertices):
        segment = index * len(points) / vertices
        edge = int(segment)
        t = segment - edge
        a, b = points[edge], points[(edge + 1) % len(points)]
        result.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return result


def large_geometries(data, count, projected):
    complex_count = min(64, max(2, count // 10)) // 2 * 2
    triangle = source(geometry.polygon(dense_ring([(0, 0), (1000000, 0), (0, 1000000)], 4095),
                                      projected), projected)
    holed = source(geometry.polygon(dense_ring([(2000000, 0), (3000000, 0),
                                              (3000000, 1000000), (2000000, 1000000)]), projected,
                                    [[(2200000, 200000), (2200000, 800000),
                                      (2800000, 800000), (2800000, 200000)]]), projected)
    for index in range(count):
        value = triangle if index < complex_count // 2 else holed
        if index >= complex_count:
            value = point(4000000 + index, 100000, projected)
        data.add_geometry(value)
    for label, bound, rows in [
            ('outside-hull', box(880000, 880000, 920000, 920000, projected), 0),
            ('inside-hole', box(2450000, 450000, 2550000, 550000, projected), 0),
            ('true-intersection', box(90000, 90000, 110000, 110000, projected), complex_count // 2)]:
        data.pair('sf-intersects-large-' + label, 'sfIntersects', bound,
                  'Large dense polygon payloads with envelope or hull false positives', rows)


def mixed_crs(data, count, projected):
    for index in range(count):
        inside = index % 4 < 2
        data.add_geometry(point(1000 + index % 100 if inside else 9000 + index % 100,
                                1000 if inside else 9000, index % 2 == 1))
    for crs_name, crs in [('native', False), ('projected', True)]:
        bound = box(500, 500, 4000, 4000, crs)
        for direction, reverse in [('object-bound', False), ('subject-bound', True)]:
            relations = ['sfContains' if reverse else 'sfWithin', 'sfIntersects', 'sfDisjoint']
            for relation in relations:
                name = 'sf-' + relation[2:].lower() + '-' + crs_name + '-' + direction
                data.pair(name, relation, bound, 'Mixed source CRSs with preserved argument order',
                          count // 2, reverse)


def bound_batch(data, count, projected):
    bound = box(0, 0, 1000, 1000, projected)
    values = []
    for index in range(count):
        value = point(100 + index / count if index % 2 == 0 else 2000 + index / count,
                      100, projected)
        entity = data.add_geometry(value)
        values.append(f'    ({entity} {term(value)} {term(bound)})')
    table = '  VALUES (?result ?wkt ?bound) {\n' + '\n'.join(values) + '\n  }\n'
    for relation in ['sfWithin', 'sfIntersects', 'sfDisjoint']:
        data.queries('sf-batch-' + relation[2:].lower(), table + f'  ?wkt geo:{relation} ?bound .',
                     table + f'  FILTER(geof:{relation}(?wkt, ?bound))',
                     'Batched fully bound literal relations and scalar evaluation without index traversal', count // 2)


def topology(data, count, projected):
    values = [box(100, 100, 200, 200, projected),
              source('LINESTRING(' + ','.join(geometry.coordinate(p, projected)
                                             for p in [(150, 0), (150, 400)]) + ')', projected),
              box(1000, 1000, 1100, 1100, projected), point(150, 150, projected)]
    for index in range(count):
        data.add_geometry(values[index % 4])
    line = source('LINESTRING(' + ','.join(geometry.coordinate(p, projected)
                                         for p in [(0, 150), (400, 150)]) + ')', projected)
    for name, relation, bound in [
            ('touches-edge', 'sfTouches', box(200, 100, 300, 200, projected)),
            ('crosses-line', 'sfCrosses', line),
            ('crosses-area', 'sfCrosses', box(100, 100, 200, 200, projected)),
            ('overlaps-area', 'sfOverlaps', box(150, 150, 250, 250, projected))]:
        data.pair('sf-' + name, relation, bound, 'Controlled boundary and dimensional topology', count // 4)


def guardrails(data, count, projected):
    polar = '<http://www.opengis.net/def/crs/EPSG/0/3031> POLYGON((0 -200,10 -200,10 -0.5,0 -0.5,0 -200))'
    meridian = '<http://www.opengis.net/def/crs/EPSG/0/3031> POLYGON((0 -2000000,100000 -2000000,100000 -1000000,0 -1000000,0 -2000000))'
    values = [polar, 'POINT(-179.999998 -89.99999)', 'POINT(-179.99999 -89.99999)',
              'POINT(-179.999 -89.99999)', meridian,
              'POLYGON((-180 -75,-175 -75,-175 -72,-180 -72,-180 -75))',
              '<http://www.opengis.net/def/crs/EPSG/0/3031> POINT(-0.0 -1500000)',
              'POINT EMPTY', 'POLYGON EMPTY', 'GEOMETRYCOLLECTION EMPTY',
              'GEOMETRYCOLLECTION(POINT(1 1),LINESTRING(0 0,2 2))',
              'POINT(1 1)', 'POLYGON((0 0,3 0,3 3,0 3,0 0))']
    for value in values:
        data.add_geometry(value)
    for name, bound in [('near-pole', polar), ('antimeridian', meridian),
                        ('empty-point', 'POINT EMPTY'), ('empty-collection', 'GEOMETRYCOLLECTION EMPTY'),
                        ('collection', values[10])]:
        for relation in ['sfIntersects', 'sfDisjoint']:
            for suffix, reverse in [('object-bound', False), ('subject-bound', True)]:
                data.pair('sf-' + relation[2:].lower() + '-' + name + '-' + suffix,
                          relation, bound, 'Small CRS and geometry-type candidate guardrail', reverse=reverse)


def generate(output, workload, count=None, profile='native'):
    if output.exists():
        raise ValueError(f'Output already exists: {output}')
    if workload not in WORKLOADS or profile not in ('native', 'projected'):
        raise ValueError('Unsupported workload or CRS profile')
    if workload == 'guardrails' and count is not None:
        raise ValueError('Guardrails use a fixed small corpus; omit --count')
    if workload == 'pruning' and profile != 'native':
        raise ValueError('The certified-pruning threshold workload requires native CRS84')
    count = count if count is not None else (1000 if workload == 'bound-batch' else 10000)
    if count < (1500 if workload == 'paging' else 100) or count % 100:
        raise ValueError('Count must be a multiple of 100, at least 1500 for paging and 100 otherwise')
    if workload == 'bound-batch' and count > 10000:
        raise ValueError('Bound batches are limited to 10000 pairs per request')
    effective = 'mixed' if workload in ('mixed-crs', 'guardrails') else profile
    data = Dataset(output, workload, effective)
    try:
        globals()[workload.replace('-', '_')](data, count, profile == 'projected')
        return data.finish(None if workload == 'guardrails' else count)
    finally:
        data.stream.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--workload', choices=WORKLOADS, required=True)
    parser.add_argument('--count', type=int)
    parser.add_argument('--profile', choices=['native', 'projected'], default='native')
    args = parser.parse_args()
    try:
        print(json.dumps(generate(args.output, args.workload, args.count, args.profile), indent=2))
    except ValueError as error:
        parser.error(str(error))
