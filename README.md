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

A version already published cannot be republished or lowered: a correction is a new, higher
tag. Changing only the tier of a published version is allowed.

## What the check does

`.github/workflows/check.yml` runs on every pull request, read only. `scripts/build.sh`:

1. fetches the installer (`ReCasaOS/CasaOS-Install`) and the core (`ReCasaOS/CasaOS`) at the
   two commits of `refs.env`, never by a branch name, and requires each commit to be in the
   history of that repository's `main`;
2. downloads each module's `checksums.txt` and archives and checks every archive against the
   SHA-256 its `checksums.txt` lists; a release that is gone, or whose archives do not match,
   fails here, with the module named;
3. builds the catalogue with the installer's `build-modules-catalogue.py`, which checks the tag
   against the commit, the module's `module.json` against its repository, and everything a box
   would refuse;
4. checks the new catalogue against the published one (`scripts/compare.py`): a module at a
   tag already published must keep the same commit, archives and manifest, and no tag may be
   lower than the published one;
5. builds the core and has it read the catalogue as a box does; it must take it and list
   every module at its pinned tag and tier.

Any failure stops the check with one sentence saying which. The run's summary then shows what
the change does to the published catalogue (each module added, removed, updated or with its
tier changed, with tag and tier before and after), and the SHA-256 of the file that was built.

`refs.env` pins the installer and the core used by the check. Changing either commit is a
pull request like any other.

## Reviewing a pull request

The check of a pull request runs the workflow and the scripts of that pull request itself.

- A green check means something only when the pull request changes `modules.env` alone.
- Any change to `refs.env`, `scripts/`, `tests/` or `.github/` changes what is published to
  every box, or how: review it as code. `scripts/publish.sh` and `.github/workflows/publish.yml`
  run with the right to publish.
- A new commit in `refs.env` must be on the `main` of its repository.
- Read the summary of the run for removed modules: a merge removes them from every box.

## Publication

Each push on `main` runs `.github/workflows/publish.yml`. Its first job builds and checks the
catalogue exactly as the check does, read only. Its second job runs `scripts/publish.sh`, which
creates the release `c<serial>` as a draft, attaches `catalogue-2.json`, downloads it back and
requires the same bytes, and only then publishes it as the latest release. A failure before that
point leaves at most a draft, and the published catalogue unchanged. Two publications never run at
once.

The serial is the run number of the publication workflow, and it only goes up: `publish.sh`
refuses a serial that is not above the one published.

A published release is never deleted or edited by hand, and its assets are never replaced: a
correction is a new merge.

To see what is published: the latest release of this repository, or

```
curl -sSL https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json
```

The summary of each publication run shows what it changed and the SHA-256 of the file.

## The two tiers

- `core`: maintained by ReCasaOS and proven on a real machine.
- `community`: proven in CI against a test double only. A box says so before it installs the
  module, whose service runs as root like the other ReCasaOS services.

## Run it locally

On Linux, with bash, git, curl, Python 3.12 and Go, as a user that is not root:

```
bash tests/test-build.sh                  # offline tests
bash tests/test-publish.sh                # offline tests, with a fake gh
bash tests/test-published.sh              # offline tests, with a fake gh and a fake curl
bash scripts/build.sh 1 out/catalogue-2.json
```

## For the maintainer

- **A published release is final.** Never delete one, never edit one by hand, never
  replace its file: boxes keep the highest serial they have seen. A correction is a new
  merge, which publishes the next serial.
- **A Publish run shown as cancelled** was replaced by a newer one waiting behind it. The
  newer run publishes everything `main` holds, so nothing is lost. If no run followed,
  start *Publish* by hand on `main`.
- **A draft left behind** means a publication stopped after creating it; its log names the
  draft. Nothing was published. Delete the draft, then start *Publish* by hand on `main`:
  the new run takes a new serial.
- **Re-running a failed run** is refused: a run keeps its serial. Start a new one.
- **The serial only goes up.** It is the number of the Publish run. If a file with too high
  a serial was ever served, boxes that read it keep it and refuse lower ones: the way out
  is to publish a serial above it, never to go back.
- **`refs.env` moves forward.** Pin commits that are on `main` of their repository, and
  newer than the ones they replace.
