#!/usr/bin/env python3
"""Offline tests of scripts/license.py: a community archive carries its LICENSE at the root.

    python3 tests/test-license.py
"""
import io
import os
import subprocess
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LICENSE = os.path.join(ROOT, "scripts", "license.py")
T = tempfile.mkdtemp()
failures = 0
counter = [0]


def check(name, ok, detail=""):
    global failures
    print("%s - %s" % ("ok  " if ok else "FAIL", name))
    if not ok:
        failures += 1
        if detail:
            print(detail)


def archive(*members):
    """members: (name, bytes) for a file, (name, None) for a directory, (name, 'link:<target>') for a symbolic link, (name, 'dev') for a device."""
    counter[0] += 1
    path = os.path.join(T, "a%d.tar.gz" % counter[0])
    with tarfile.open(path, "w:gz") as tf:
        for name, content in members:
            ti = tarfile.TarInfo(name)
            if content is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            elif content == "dev":
                ti.type = tarfile.CHRTYPE
                tf.addfile(ti)
            elif isinstance(content, str):
                ti.type = tarfile.SYMTYPE
                ti.linkname = content[5:]
                tf.addfile(ti)
            else:
                ti.size = len(content)
                tf.addfile(ti, io.BytesIO(content))
    return path


def run(*args):
    p = subprocess.run([sys.executable, "-I", LICENSE, *args], capture_output=True, text=True)
    return p.returncode, p.stderr.strip()


M = ("module.json", b"{}")
text = b"MIT License\n"

rc, err = run(archive(M, ("LICENSE", text)))
check("a LICENSE at the root passes", rc == 0 and err == "", err)

rc, err = run(archive(M, ("bin/", None), ("bin/tool", b"x"), ("LICENSE", text)))
check("a LICENSE among other files passes", rc == 0, err)

rc, err = run(archive(M))
check("no LICENSE is refused", rc == 1 and "LICENSE" in err, err)

rc, err = run(archive(M, ("LICENSE", b"")))
check("an empty LICENSE is refused", rc == 1 and "empty" in err, err)

rc, err = run(archive(M, ("LICENSE", b"x" * (1 << 20))))
check("a LICENSE of exactly 1 MiB passes", rc == 0, err)

rc, err = run(archive(M, ("LICENSE", b"x" * ((1 << 20) + 1))))
check("a LICENSE over 1 MiB is refused", rc == 1 and "1 MiB" in err, err)

rc, err = run(archive(M, ("LICENSE", "link:/etc/passwd")))
check("a symbolic link is not a licence", rc == 1 and "regular" in err, err)

rc, err = run(archive(M, ("LICENSE", None)))
check("a directory is not a licence", rc == 1 and "regular" in err, err)

rc, err = run(archive(M, ("LICENSE", "dev")))
check("a device is not a licence", rc == 1 and "regular" in err, err)

rc, err = run(archive(M, ("docs/LICENSE", text)))
check("a LICENSE in a sub-folder only is refused", rc == 1 and "LICENSE" in err, err)

rc, err = run(archive(M, ("LICENSE", text), ("LICENSE", text)))
check("a LICENSE twice is refused", rc == 1 and "twice" in err, err)

rc, err = run(archive(M, ("license", text)))
check("another case is not the file", rc == 1, err)

# bigger than 256 MiB: refused before it is opened (a sparse file, never read)
big = os.path.join(T, "big.tar.gz")
with open(big, "wb") as f:
    f.truncate((256 << 20) + 1)
rc, err = run(big)
check("an archive over 256 MiB is refused unread", rc == 1 and "256 MiB" in err, err)

bad = os.path.join(T, "bad.tar.gz")
open(bad, "wb").write(b"not a tarball")
rc, err = run(bad)
check("a file that is no tarball is refused", rc == 1 and "readable" in err, err)

rc, err = run(os.path.join(T, "missing.tar.gz"))
check("a missing file is refused", rc == 1, err)

rc, err = run()
check("no argument is usage", rc == 2 and "usage" in err, err)

sys.exit(1 if failures else 0)
