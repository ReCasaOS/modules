#!/usr/bin/env python3
"""Checks that a community archive carries its licence:

    scripts/license.py ARCHIVE

ARCHIVE is a .tar.gz of a module. It must hold, at its root beside module.json (the member is named exactly LICENSE, as module.json is), once, a regular file that
is not empty and not larger than 1 MiB. The archive is read in streaming mode, nothing is extracted, and an archive over 200 MiB is refused before it is opened. Which licence it is,
a human decides. Exit status: 0 fine, 1 refused (one sentence on the standard error), 2 usage.
"""
import os
import sys
import tarfile
import zlib

MAX_ARCHIVE_BYTES = 200 << 20
MAX_LICENSE_BYTES = 1 << 20
MAX_TOTAL_BYTES = 400 << 20  # the builder's bound on the content of an archive; MAX_ARCHIVE_BYTES is its bound on the file
MAX_ENTRIES = 5000  # the builder's bound on the entries of an archive


class Refused(Exception):
    pass


def check(path):
    try:
        size = os.path.getsize(path)
    except OSError:
        raise Refused("%s is not a readable file." % path)
    if size > MAX_ARCHIVE_BYTES:
        raise Refused("%s is larger than 200 MiB." % path)
    found, total = None, 0
    try:
        with tarfile.open(path, "r|gz") as tf:
            for i, member in enumerate(tf):
                if i >= MAX_ENTRIES:
                    raise Refused("%s has more than %d entries." % (path, MAX_ENTRIES))
                total += member.size
                if total > MAX_TOTAL_BYTES:
                    raise Refused("%s holds more than 400 MiB." % path)
                if member.name != "LICENSE":
                    continue
                if found is not None:
                    raise Refused("%s holds LICENSE twice." % path)
                found = member
                if not member.isreg():
                    raise Refused("%s: LICENSE is not a regular file." % path)
    except (tarfile.TarError, OSError, EOFError, zlib.error, MemoryError):
        raise Refused("%s is not a readable tarball." % path)
    if found is None:
        raise Refused("%s has no LICENSE at its root." % path)
    if found.size == 0:
        raise Refused("%s: LICENSE is empty." % path)
    if found.size > MAX_LICENSE_BYTES:
        raise Refused("%s: LICENSE is larger than 1 MiB." % path)


def main(argv):
    if len(argv) != 1:
        print("usage: scripts/license.py ARCHIVE", file=sys.stderr)
        return 2
    try:
        check(argv[0])
    except Refused as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
