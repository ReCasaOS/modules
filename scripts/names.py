#!/usr/bin/env python3
"""Keeps the names of retired modules reserved for ever:

    scripts/names.py NEW3 RETIRED [PUBLISHED3]

NEW3 is the schema 3 catalogue about to be published, RETIRED the retired.env of this repository, PUBLISHED3 the schema 3 catalogue published now.
It refuses (one sentence on the standard error, exit 1):

- a module of NEW3 whose name, unit or route is in RETIRED;
- with PUBLISHED3, a published module that is not in NEW3 and has no line in RETIRED with its own name, unit and route.

retired.env: `#` comments and empty lines are ignored; any other line is `<name> <unit> <route>` (`-` for no route), each in the catalogue's pattern, and a
name, a unit or a route appears at most once in the file. The unit and the route of a module are the `unit` and `gateway_route` of its manifest.
Exit status: 0 fine, 1 refused, 2 usage.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare  # noqa: E402

# the patterns of the builder (build-modules-catalogue.py): a catalogue never holds anything else
NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")
UNIT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9:_.@-]{0,63}\.service")
ROUTE_RE = re.compile(r"/v[0-9]{1,2}/[a-z][a-z0-9_]{0,39}")


def read_retired(path):
    """{name: (unit, route)} of retired.env, with "-" for no route."""
    def bad(why):
        return compare.Refused("%s is not a retired.env (%s)." % (path, why))

    try:
        with open(path, "rb") as f:
            raw = f.read(compare.MAX_BYTES + 1)
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        raise bad("it cannot be read")
    if len(raw) > compare.MAX_BYTES:
        raise bad("larger than 1 MiB")
    retired, units, routes = {}, set(), set()
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        words = line.split()
        if len(words) != 3:
            raise bad("line %d is not a name, a unit and a route" % n)
        name, unit, route = words
        if not (NAME_RE.fullmatch(name) and UNIT_RE.fullmatch(unit) and (route == "-" or ROUTE_RE.fullmatch(route))):
            raise bad("line %d has a name, a unit or a route out of the catalogue's patterns" % n)
        if name in retired or unit in units or (route != "-" and route in routes):
            raise bad("line %d repeats a name, a unit or a route" % n)
        retired[name] = (unit, route)
        units.add(unit)
        routes.add(route)
    return retired


def unit_route(entry):
    m = entry["manifest"]
    return m.get("unit"), m.get("gateway_route", "-")


def check(new, retired, published):
    units = {u: n for n, (u, _) in retired.items()}
    routes = {r: n for n, (_, r) in retired.items() if r != "-"}
    for name, e in sorted(new.items()):
        unit, route = unit_route(e)
        if name in retired:
            raise compare.Refused("Module %s: the name belongs to a retired module, and stays reserved." % name)
        if unit in units:
            raise compare.Refused("Module %s: the unit %s belongs to the retired module %s, and stays reserved." % (name, unit, units[unit]))
        if route in routes:
            raise compare.Refused("Module %s: the route %s belongs to the retired module %s, and stays reserved." % (name, route, routes[route]))
    for name, e in sorted(published.items()):
        if name in new:
            continue
        unit, route = unit_route(e)
        if name not in retired:
            raise compare.Refused("Module %s was published and is no longer listed: add its line to retired.env (%s %s %s), its name stays reserved." % (name, name, unit, route))
        if retired[name] != (unit, route):
            raise compare.Refused("Module %s: retired.env has the unit and route %s %s, the published module had %s %s." % (name, *retired[name], unit, route))


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: scripts/names.py NEW3 RETIRED [PUBLISHED3]", file=sys.stderr)
        return 2
    try:
        check(compare.load(argv[0], 3), read_retired(argv[1]), compare.load(argv[2], 3) if len(argv) == 3 else {})
    except compare.Refused as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
