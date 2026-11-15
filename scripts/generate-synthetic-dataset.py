#!/usr/bin/env python3
"""Generate repeatable GeoSPARQL data and paired indexed/scalar queries."""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import random

CRS84 = 'http://www.opengis.net/def/crs/OGC/1.3/CRS84'
PROJECTED = 'http://www.opengis.net/def/crs/EPSG/0/3857'
RADIUS = 6378137.0
ORIGIN = (RADIUS * math.radians(20), RADIUS * math.asinh(math.tan(math.radians(60))))
PREFIXES = ('PREFIX geo: <http://www.opengis.net/ont/geosparql#>\n'
            'PREFIX geof: <http://www.opengis.net/def/function/geosparql/>\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def coordinate(point, projected):
    """Map a local 10 km square near 20 E, 60 N into source coordinates.

    EPSG:3857 inverse spherical Mercator: longitude=x/R, latitude=atan(sinh(y/R)).
    This constructs fixture coordinates only; it is outside benchmark timings.
    """
    x, y = (ORIGIN[i] + point[i] for i in range(2))
    if projected:
        return f'{x:.9f} {y:.9f}'
    return f'{math.degrees(x / RADIUS):.12f} {math.degrees(math.atan(math.sinh(y / RADIUS))):.12f}'


def ring(points, projected):
    return '(' + ', '.join(coordinate(p, projected) for p in points + [points[0]]) + ')'


def polygon(points, projected, holes=()):
    rings = [ring(points, projected)] + [ring(h, projected) for h in holes]
    return 'POLYGON(' + ', '.join(rings) + ')'


def rectangle(low, high):
    return [(low, low), (high, low), (high, high), (low, high)]


def circle(x, y, radius, vertices):
    return [(x + radius * math.cos(2 * math.pi * i / vertices),
             y + radius * math.sin(2 * math.pi * i / vertices)) for i in range(vertices)]


def literal(wkt, projected):
    crs = PROJECTED if projected else CRS84
    return json.dumps(f'<{crs}> {wkt}') + '^^geo:wktLiteral'


def source_geometry(index, x, y, projected):
    kind = index % 3
    if kind == 0:
        return 'point', 'POINT(' + coordinate((x, y), projected) + ')'
    if kind == 1:
        points = [(x - 5, y - 5), (x, y + 4), (x + 5, y - 3)]
        return 'line', 'LINESTRING(' + ', '.join(coordinate(p, projected) for p in points) + ')'
    variant = (index // 3) % 4
    if variant == 0:
        points = [(x-5, y-5), (x+5, y-5), (x+5, y+5), (x-5, y+5)]
        return 'rectangle', polygon(points, projected)
    if variant == 1:
        points = [(x-5, y-5), (x+5, y-5), (x+5, y), (x, y), (x, y+5), (x-5, y+5)]
        return 'concave', polygon(points, projected)
    if variant == 2:
        outer = [(x-8, y-8), (x+8, y-8), (x+8, y+8), (x-8, y+8)]
        hole = [(x-3, y-3), (x-3, y+3), (x+3, y+3), (x+3, y-3)]
        return 'holed', polygon(outer, projected, [hole])
    return 'complex', polygon(circle(x, y, 8, 64), projected)


def generate(output, profile, distribution, count, seed):
    if output.exists():
        raise ValueError(f'Output already exists: {output}')
    minimum = 24 if profile == 'mixed' else 12
    if count < minimum:
        raise ValueError(f'At least {minimum} geometries are required to exercise all source types and CRSs')
    output.mkdir(parents=True)
    queries = output / 'queries'
    queries.mkdir()
    rng = random.Random(seed)
    types, crs_counts = Counter(), Counter()
    with (output / 'data.ttl').open('w') as stream:
        stream.write('@prefix geo: <http://www.opengis.net/ont/geosparql#> .\n'
                     '@prefix ex: <https://example.org/synthetic/> .\n')
        for index in range(count):
            if distribution == 'uniform':
                x, y = rng.uniform(50, 9950), rng.uniform(50, 9950)
            else:
                cx, cy = rng.choice([(2500, 2500), (7500, 2500), (7500, 7500)])
                x, y = (min(9950, max(50, rng.gauss(c, 400))) for c in (cx, cy))
            # Alternate blocks, independently of geometry type, so every type occurs in both CRSs.
            projected = profile == 'projected' or (profile == 'mixed' and (index // 12) % 2 == 1)
            kind, wkt = source_geometry(index, x, y, projected)
            types[kind] += 1
            crs_counts[PROJECTED if projected else CRS84] += 1
            stream.write(f'ex:f{index:09d} a geo:Feature; geo:hasDefaultGeometry ex:g{index:09d} .\n')
            stream.write(f'ex:g{index:09d} a geo:Geometry; geo:asWKT {literal(wkt, projected)} .\n')

    manifest = {'schema_version': 1, 'canonical_variables': ['result', 'wkt'], 'queries': []}
    known_rows = {}

    def add(query_id, relation, bound_wkt, projected, description, reverse=False, rows=None):
        bound = literal(bound_wkt, projected)
        indexed = f'{bound} geo:{relation} ?result' if reverse else f'?result geo:{relation} {bound}'
        arguments = f'{bound}, ?wkt' if reverse else f'?wkt, {bound}'
        scalar_id = query_id.replace('sf-', 'geof-', 1)
        for name, clause in [(query_id, indexed + ' .'),
                             (scalar_id, f'FILTER(geof:{relation}({arguments}))')]:
            text = PREFIXES + 'SELECT ?result ?wkt WHERE {\n  ?result geo:asWKT ?wkt .\n  ' + clause + '\n}\n'
            (queries / (name + '.rq')).write_text(text)
            entry = {'id': name, 'file': name + '.rq', 'description': description}
            if name == scalar_id:
                entry['equivalent_to'] = query_id
            manifest['queries'].append(entry)
            if rows is not None:
                known_rows[name] = rows

    projected = profile == 'projected'
    region = polygon(rectangle(-20, 7000), projected)
    selective = polygon(rectangle(2300, 2700), projected)
    add('sf-within-region', 'sfWithin', region, projected, 'Broad containment')
    add('sf-intersects-region', 'sfIntersects', region, projected, 'Broad intersection')
    add('sf-disjoint-region', 'sfDisjoint', region, projected, 'Complement of broad intersection')
    add('sf-within-selective-region', 'sfWithin', selective, projected, 'Selective containment')
    add('sf-disjoint-cover', 'sfDisjoint', polygon(rectangle(-20, 10020), projected),
        projected, 'All sources are strictly inside this rectangle', rows=0)
    add('sf-within-cover', 'sfWithin', polygon(rectangle(-20, 10020), projected),
        projected, 'Known full-corpus containment', rows=count)
    add('sf-disjoint-outside', 'sfDisjoint', polygon(rectangle(11000, 12000), projected),
        projected, 'Known full-corpus disjoint result', rows=count)
    for label, fraction in [('thin', .10), ('middle', .30), ('wide', .90)]:
        cut = 10000 * fraction
        points = [(-20, -20), (10020, -20), (10020, cut), (cut, cut), (cut, 10020), (-20, 10020)]
        add('sf-disjoint-' + label, 'sfDisjoint', polygon(points, projected), projected,
            'Concave bound with ' + label + ' interior coverage; actual pruning reduction is not prescribed')
    holed = polygon(rectangle(-20, 10020), projected, [list(reversed(rectangle(2000, 8000)))])
    add('sf-intersects-hole', 'sfIntersects', holed, projected, 'Bound polygon with a large interior hole')
    complex_bound = polygon(circle(5000, 5000, 4500, 300), projected)
    add('sf-disjoint-complex', 'sfDisjoint', complex_bound, projected,
        'Bound exceeds the certified-rectangle coordinate limit')
    add('sf-within-reversed', 'sfContains', region, projected,
        'Literal subject with the original exact-evaluation argument order', reverse=True)
    if profile == 'mixed':
        for label, is_projected in [('native', False), ('projected', True)]:
            for name, relation in [('within', 'sfWithin'), ('intersects', 'sfIntersects'), ('disjoint', 'sfDisjoint')]:
                add(f'sf-{name}-{label}-bound', relation,
                    polygon(rectangle(-20, 7000), is_projected), is_projected,
                    f'Mixed source CRSs and an explicitly {label} bound')
    (queries / 'geometry-corpus.rq').write_text(
        PREFIXES + 'SELECT ?result ?wkt WHERE { ?result geo:asWKT ?wkt . }\n')
    write_json(queries / 'manifest.json', manifest)
    write_json(output / 'known-results.json', known_rows)
    template = Path(__file__).resolve().parent.parent / 'maldives-config.ttl'
    config = template.read_text()
    assert config.count('rep:repositoryID "maldives"') == 1
    (output / 'repository-config.ttl').write_text(config.replace('rep:repositoryID "maldives"', 'rep:repositoryID "synthetic"'))
    metadata = {
        'schema_version': 1, 'repository_id': 'synthetic', 'profile': profile,
        'distribution': distribution, 'geometries': count, 'seed': seed,
        'source_types': dict(types), 'source_crs': dict(crs_counts),
        'generator_sha256': digest(Path(__file__)),
        'files_sha256': {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob('*')) if p.is_file()},
        'limits': ['EPSG:3857 is the only projected CRS in this suite',
                   'Transformed vertices preserve source literals; cross-CRS edge equivalence is not assumed',
                   'No empty, collection, antimeridian or polar performance workload'],
    }
    write_json(output / 'dataset.json', metadata)
    return metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--profile', choices=['native', 'projected', 'mixed'], default='native')
    parser.add_argument('--distribution', choices=['uniform', 'clustered'], default='uniform')
    parser.add_argument('--count', type=int, default=100000)
    parser.add_argument('--seed', type=int, default=40)
    args = parser.parse_args()
    try:
        value = generate(args.output, args.profile, args.distribution, args.count, args.seed)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(value, indent=2))
