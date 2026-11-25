# ReCasaOS modules

The catalogue of ReCasaOS's optional modules: services such as virtual machines or the
vulnerability scan that a box installs only from this list. Each module is pinned to one
release of its own repository, by tag, commit and SHA-256 of its archives.

`modules.env` is the list. When a change to it is merged on `main`, the catalogue is
rebuilt and published at
`https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json`,
which **every box reads**. A merge here reaches every box, without an installer release.

## Propose a version

Open a pull request that edits the four lines of the module in `modules.env`:

```
MODULE_VIRT_TAG=v0.2.6
MODULE_VIRT_COMMIT=5d1c179d8ecf6119caf9b8e0d0a385e45a113ba3
MODULE_VIRT_COMPONENT=CasaOS-VirtManagement
MODULE_VIRT_TIER=core
```

- `TAG`: the tag of the module's release, `v<number>.<number>.<number>`. That release must
  publish a `checksums.txt` and the two archives (amd64 and arm64) it names.
- `COMMIT`: the full commit that tag names: `git rev-parse <tag>^{commit}` in the module's
  repository, or the commit shown on its release page. The check refuses a tag that names
  another commit.
- `COMPONENT`: the module's repository in the ReCasaOS organisation.
- `TIER`: `core` or `community` (below).

A new module is four new lines; removing a module is removing its four lines. The comment at
the top of `modules.env` gives the exact format. A `modules.env` with no module is refused:
a catalogue with no module is not published.

A release may not change under a tag that is already published: a new release needs a new tag.
Changing only the tier of a published version is allowed.

## What the check does

`.github/workflows/check.yml` runs on every pull request, read only. `scripts/build.sh`:

1. fetches the installer (`ReCasaOS/CasaOS-Install`) and the core (`ReCasaOS/CasaOS`) at the
   two commits of `refs.env`, never by a branch name;
2. downloads each module's `checksums.txt` and archives and checks every archive against the
   SHA-256 its `checksums.txt` lists; a release that is gone, or whose archives do not match,
   fails here, with the module named;
3. builds the catalogue with the installer's `build-modules-catalogue.py`, which checks the tag
   against the commit, the module's `module.json` against its repository, and everything a box
   would refuse;
4. checks the new catalogue against the published one (`scripts/compare.py`): a module at a
   tag already published must keep the same commit, archives and manifest;
5. builds the core and has it read the catalogue as a box does; it must take it and list
   every module at its pinned tag and tier.

Any failure stops the check with one sentence saying which. The run's summary then shows what
the change does to the published catalogue (each module added, removed or updated, with tag
and tier before and after), and the SHA-256 of the file that was built.

`refs.env` pins the installer and the core used by the check. Changing either commit is a
pull request like any other.

## The two tiers

- `core`: maintained by ReCasaOS and proven on a real machine.
- `community`: proven in CI against a test double only. A box says so before it installs the
  module, whose service runs as root like the other ReCasaOS services.

## Run it locally

On Linux, with bash, git, curl, Python 3.12 and Go, as a user that is not root:

```
bash tests/test-build.sh                  # offline tests
bash scripts/build.sh 1 out/catalogue-2.json
```
