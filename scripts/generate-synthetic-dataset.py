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
# Source CRSs by key: URI, and whether coordinates are written latitude first.
SOURCE_CRS = {
    'crs84': (CRS84, False),
    'epsg3857': (PROJECTED, False),
    'epsg4326': ('http://www.opengis.net/def/crs/EPSG/0/4326', True),
    'gda2020': ('http://www.opengis.net/def/crs/EPSG/0/7844', True),
    'mga56': ('http://www.opengis.net/def/crs/EPSG/0/7856', False),
}
RADIUS = 6378137.0
ORIGIN = (RADIUS * math.radians(20), RADIUS * math.asinh(math.tan(math.radians(60))))
BRISBANE = (RADIUS * math.radians(153), RADIUS * math.asinh(math.tan(math.radians(-27.5))))
# Local grid origin in MGA2020 zone 56 (EPSG:7856), about 100 km west of Brisbane's central meridian.
MGA56_ORIGIN = (400000.0, 6900000.0)
PREFIXES = ('PREFIX geo: <http://www.opengis.net/ont/geosparql#>\n'
            'PREFIX geof: <http://www.opengis.net/def/function/geosparql/>\n')
# Profile: local grid, source CRSs in alternating blocks of twelve, and CRS of the unlabelled bounds.
PROFILES = {
    'native': ('mercator', ORIGIN, ['crs84'], 'crs84'),
    'projected': ('mercator', ORIGIN, ['epsg3857'], 'epsg3857'),
    'mixed': ('mercator', ORIGIN, ['crs84', 'epsg3857'], 'crs84'),
    'epsg4326': ('mercator', ORIGIN, ['epsg4326'], 'epsg4326'),
    'gda2020': ('mercator', BRISBANE, ['gda2020'], 'gda2020'),
    'mga56': ('mga56', MGA56_ORIGIN, ['mga56'], 'mga56'),
    'mixed-mga56': ('mga56', MGA56_ORIGIN, ['crs84', 'mga56'], 'crs84'),
}
# Profiles whose outputs predate the CRS and extent options; their files must not change.
ORIGINAL_PROFILES = ('native', 'projected', 'mixed')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def crs_key(crs):
    """Accept the original projected flag as well as a source CRS key."""
    if crs is True:
        return 'epsg3857'
    if crs is False:
        return 'crs84'
    return crs


def mga56_to_geographic(easting, northing):
    """Inverse transverse Mercator for MGA2020 zone 56 (GRS80), Krueger series to the third order.

    Returns longitude and latitude in degrees. This constructs fixture coordinates only.
    """
    flattening = 1 / 298.257222101
    n = flattening / (2 - flattening)
    rectifying = RADIUS / (1 + n) * (1 + n * n / 4 + n ** 4 / 64) * 0.9996
    beta = (n / 2 - 2 * n * n / 3 + 37 * n ** 3 / 96, n * n / 48 + n ** 3 / 15, 17 * n ** 3 / 480)
    delta = (2 * n - 2 * n * n / 3 - 2 * n ** 3, 7 * n * n / 3 - 8 * n ** 3 / 5, 56 * n ** 3 / 15)
    xi = (northing - 10000000.0) / rectifying
    eta = (easting - 500000.0) / rectifying
    xi_prime = xi - sum(b * math.sin(2 * j * xi) * math.cosh(2 * j * eta) for j, b in enumerate(beta, 1))
    eta_prime = eta - sum(b * math.cos(2 * j * xi) * math.sinh(2 * j * eta) for j, b in enumerate(beta, 1))
    chi = math.asin(math.sin(xi_prime) / math.cosh(eta_prime))
    latitude = chi + sum(d * math.sin(2 * j * chi) for j, d in enumerate(delta, 1))
    longitude = math.radians(153) + math.atan2(math.sinh(eta_prime), math.cos(xi_prime))
    return math.degrees(longitude), math.degrees(latitude)


class Frame:
    """A local metre grid that writes its points in a source CRS."""

    def __init__(self, kind, origin):
        self.kind, self.origin = kind, origin

    def coordinate(self, point, crs):
        """Map a local point into source coordinates.

        A Mercator grid uses EPSG:3857 map units and its inverse spherical formulas:
        longitude=x/R, latitude=atan(sinh(y/R)). An MGA grid uses EPSG:7856 metres.
        This constructs fixture coordinates only; it is outside benchmark timings.
        """
        crs = crs_key(crs)
        x, y = (self.origin[i] + point[i] for i in range(2))
        if crs == ('epsg3857' if self.kind == 'mercator' else 'mga56'):
            return f'{x:.9f} {y:.9f}'
        if crs in ('epsg3857', 'mga56'):
            raise ValueError(f'{crs} is not available on a {self.kind} grid')
        if self.kind == 'mercator':
            longitude, latitude = math.degrees(x / RADIUS), math.degrees(math.atan(math.sinh(y / RADIUS)))
        else:
            longitude, latitude = mga56_to_geographic(x, y)
        if SOURCE_CRS[crs][1]:
            return f'{latitude:.12f} {longitude:.12f}'
        return f'{longitude:.12f} {latitude:.12f}'


DEFAULT_FRAME = Frame('mercator', ORIGIN)


def coordinate(point, projected, frame=DEFAULT_FRAME):
    """Map a local 10 km square near 20 E, 60 N into source coordinates."""
    return frame.coordinate(point, projected)


def ring(points, projected, frame=DEFAULT_FRAME):
    return '(' + ', '.join(coordinate(p, projected, frame) for p in points + [points[0]]) + ')'


def polygon(points, projected, holes=(), frame=DEFAULT_FRAME):
    rings = [ring(points, projected, frame)] + [ring(h, projected, frame) for h in holes]
    return 'POLYGON(' + ', '.join(rings) + ')'


def rectangle(low, high):
    return [(low, low), (high, low), (high, high), (low, high)]


def circle(x, y, radius, vertices):
    return [(x + radius * math.cos(2 * math.pi * i / vertices),
             y + radius * math.sin(2 * math.pi * i / vertices)) for i in range(vertices)]


def literal(wkt, projected):
    return json.dumps(f'<{SOURCE_CRS[crs_key(projected)][0]}> {wkt}') + '^^geo:wktLiteral'


def source_geometry(index, x, y, projected, frame=DEFAULT_FRAME):
    kind = index % 3
    if kind == 0:
        return 'point', 'POINT(' + coordinate((x, y), projected, frame) + ')'
    if kind == 1:
        points = [(x - 5, y - 5), (x, y + 4), (x + 5, y - 3)]
        return 'line', 'LINESTRING(' + ', '.join(coordinate(p, projected, frame) for p in points) + ')'
    variant = (index // 3) % 4
    if variant == 0:
        points = [(x-5, y-5), (x+5, y-5), (x+5, y+5), (x-5, y+5)]
        return 'rectangle', polygon(points, projected, frame=frame)
    if variant == 1:
        points = [(x-5, y-5), (x+5, y-5), (x+5, y), (x, y), (x, y+5), (x-5, y+5)]
        return 'concave', polygon(points, projected, frame=frame)
    if variant == 2:
        outer = [(x-8, y-8), (x+8, y-8), (x+8, y+8), (x-8, y+8)]
        hole = [(x-3, y-3), (x-3, y+3), (x+3, y+3), (x+3, y-3)]
        return 'holed', polygon(outer, projected, [hole], frame)
    return 'complex', polygon(circle(x, y, 8, 64), projected, frame=frame)


def generate(output, profile, distribution, count, seed, extent=10000):
    if output.exists():
        raise ValueError(f'Output already exists: {output}')
    if profile not in PROFILES:
        raise ValueError(f'Unsupported profile: {profile}')
    if extent < 1000 or extent % 100:
        raise ValueError('Extent must be a multiple of 100 map units, at least 1000')
    grid, origin, source_crs, bound_crs = PROFILES[profile]
    frame = Frame(grid, origin)
    minimum = 12 * len(source_crs)
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
                x, y = rng.uniform(50, extent - 50), rng.uniform(50, extent - 50)
            else:
                cx, cy = rng.choice([(extent / 4, extent / 4), (extent * 3 / 4, extent / 4),
                                     (extent * 3 / 4, extent * 3 / 4)])
                x, y = (min(extent - 50, max(50, rng.gauss(c, extent * 4 / 100))) for c in (cx, cy))
            # Alternate blocks, independently of geometry type, so every type occurs in each source CRS.
            crs = source_crs[(index // 12) % len(source_crs)]
            kind, wkt = source_geometry(index, x, y, crs, frame)
            types[kind] += 1
            crs_counts[SOURCE_CRS[crs][0]] += 1
            stream.write(f'ex:f{index:09d} a geo:Feature; geo:hasDefaultGeometry ex:g{index:09d} .\n')
            stream.write(f'ex:g{index:09d} a geo:Geometry; geo:asWKT {literal(wkt, crs)} .\n')

    manifest = {'schema_version': 1, 'canonical_variables': ['result', 'wkt'], 'queries': []}
    known_rows = {}

    def add(query_id, relation, points, crs, description, reverse=False, rows=None, holes=()):
        bound = literal(polygon(points, crs, holes, frame), crs)
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

    cover = rectangle(-20, extent + 20)
    region = rectangle(-20, extent * 7 // 10)
    add('sf-within-region', 'sfWithin', region, bound_crs, 'Broad containment')
    add('sf-intersects-region', 'sfIntersects', region, bound_crs, 'Broad intersection')
    add('sf-disjoint-region', 'sfDisjoint', region, bound_crs, 'Complement of broad intersection')
    add('sf-within-selective-region', 'sfWithin', rectangle(extent * 23 // 100, extent * 27 // 100),
        bound_crs, 'Selective containment')
    add('sf-disjoint-cover', 'sfDisjoint', cover, bound_crs,
        'All sources are strictly inside this rectangle', rows=0)
    add('sf-within-cover', 'sfWithin', cover, bound_crs, 'Known full-corpus containment', rows=count)
    add('sf-disjoint-outside', 'sfDisjoint', rectangle(extent * 11 // 10, extent * 12 // 10),
        bound_crs, 'Known full-corpus disjoint result', rows=count)
    for label, fraction in [('thin', .10), ('middle', .30), ('wide', .90)]:
        cut = extent * fraction
        points = [(-20, -20), (extent + 20, -20), (extent + 20, cut), (cut, cut), (cut, extent + 20),
                  (-20, extent + 20)]
        add('sf-disjoint-' + label, 'sfDisjoint', points, bound_crs,
            'Concave bound with ' + label + ' interior coverage; actual pruning reduction is not prescribed')
    add('sf-intersects-hole', 'sfIntersects', cover, bound_crs, 'Bound polygon with a large interior hole',
        holes=[list(reversed(rectangle(extent * 2 // 10, extent * 8 // 10)))])
    add('sf-disjoint-complex', 'sfDisjoint', circle(extent // 2, extent // 2, extent * 45 // 100, 300), bound_crs,
        'Bound exceeds the certified-rectangle coordinate limit')
    add('sf-within-reversed', 'sfContains', region, bound_crs,
        'Literal subject with the original exact-evaluation argument order', reverse=True)
    if len(source_crs) == 2:
        for label, crs in zip(('native', 'projected'), source_crs):
            for name, relation in [('within', 'sfWithin'), ('intersects', 'sfIntersects'), ('disjoint', 'sfDisjoint')]:
                add(f'sf-{name}-{label}-bound', relation, region, crs,
                    f'Mixed source CRSs and an explicitly {label} bound')
    elif profile not in ORIGINAL_PROFILES:
        for name, relation in [('within', 'sfWithin'), ('intersects', 'sfIntersects'), ('disjoint', 'sfDisjoint')]:
            add(f'sf-{name}-native-bound', relation, region, 'crs84',
                'Sources in another CRS and a CRS84 bound')
    (queries / 'geometry-corpus.rq').write_text(
        PREFIXES + 'SELECT ?result ?wkt WHERE { ?result geo:asWKT ?wkt . }\n')
    write_json(queries / 'manifest.json', manifest)
    write_json(output / 'known-results.json', known_rows)
    template = Path(__file__).resolve().parent.parent / 'maldives-config.ttl'
    config = template.read_text()
    assert config.count('rep:repositoryID "maldives"') == 1
    (output / 'repository-config.ttl').write_text(config.replace('rep:repositoryID "maldives"', 'rep:repositoryID "synthetic"'))
    limits = ['EPSG:3857 is the only projected CRS in this suite',
              'Transformed vertices preserve source literals; cross-CRS edge equivalence is not assumed',
              'No empty, collection, antimeridian or polar performance workload']
    if profile not in ORIGINAL_PROFILES:
        limits[0] = 'Each profile uses the source CRSs recorded in source_crs'
    metadata = {
        'schema_version': 1, 'repository_id': 'synthetic', 'profile': profile,
        'distribution': distribution, 'geometries': count, 'seed': seed,
        'source_types': dict(types), 'source_crs': dict(crs_counts),
        'generator_sha256': digest(Path(__file__)),
        'limits': limits,
    }
    if extent != 10000:
        metadata['extent'] = extent
    metadata['files_sha256'] = {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob('*')) if p.is_file()}
    write_json(output / 'dataset.json', metadata)
    return metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--profile', choices=sorted(PROFILES), default='native')
    parser.add_argument('--distribution', choices=['uniform', 'clustered'], default='uniform')
    parser.add_argument('--count', type=int, default=100000)
    parser.add_argument('--seed', type=int, default=40)
    parser.add_argument('--extent', type=int, default=10000,
                        help='side of the square holding the sources, in map units of the local grid')
    args = parser.parse_args()
    try:
        value = generate(args.output, args.profile, args.distribution, args.count, args.seed, args.extent)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(value, indent=2))
