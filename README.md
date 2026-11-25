# ReCasaOS modules

The catalogue of ReCasaOS's optional modules: services such as virtual machines or the
vulnerability scan that a box installs only from this list. A module is pinned to one release
of its repository, by tag, commit and SHA-256 of its archives. Modules written by other people
can be proposed here by a pull request (below).

`modules.env` is the list. When a change to it is merged on `main`, the archives of the new
versions are copied into releases of this repository and the catalogue is rebuilt and
published as a release `c<serial>` with two files, which every box reads:

- `catalogue-2.json`: the modules of ReCasaOS, in the format that boxes have always read, at
  `https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json`;
- `catalogue-3.json`: every module, those of other authors too, plus the versions that are
  withdrawn, at
  `https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-3.json`.

A box that reads only `catalogue-2.json` never sees a module of another author. A merge here
reaches every box, without an installer release.

## What an author provides

A module is kept in a public GitHub repository of its author. It provides:

- a module that follows the module contract:
  [docs/modules.md](https://github.com/ReCasaOS/CasaOS-Install/blob/main/docs/modules.md) in
  ReCasaOS/CasaOS-Install (`module.json`, what an archive may write, the two archives);
- a tag `v<number>.<number>.<number>`, without a leading zero in a number (`v0.2.0`);
- a GitHub release of that tag with the two archives (amd64 and arm64) and a `checksums.txt`
  that lists them;
- a `LICENSE` file at the root of each archive, beside `module.json`: a free licence that
  allows redistribution, because a copy of the archives is republished here. The file is not
  empty and not larger than 1 MiB. Which licence it is, a person reads;
- a provenance attestation of each archive, made by a GitHub Actions workflow of the author's
  own repository, run on the tagged commit.

### The attestation

GitHub documents how to make one in
[Using artifact attestations to establish provenance for builds](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds).
At the time of writing, that page uses the action `actions/attest@v4`, with these permissions
on the job:

```yaml
permissions:
  id-token: write
  contents: read
  attestations: write
```

and a step such as

```yaml
- name: Generate artifact attestation
  uses: actions/attest@v4
  with:
    subject-path: 'PATH/TO/ARTIFACT'
```

run once for each archive, in the workflow that builds the archives for the tag. Follow the
page for the version and options it gives when you write the workflow.

What is checked: each archive must verify against `<owner>/<repo>`, the tag and the pinned
commit, from a GitHub-hosted runner. `scripts/attest.sh` runs, for each archive,

```
gh attestation verify ARCHIVE --repo <owner>/<repo> --source-digest <commit> \
    --source-ref refs/tags/<tag> --deny-self-hosted-runners
```

An archive that does not verify stops the check, with the repository and the archive named.

## Propose a version

Open a pull request that edits the lines of the module in `modules.env`. For a module of
ReCasaOS they are four:

```
MODULE_VIRT_TAG=v0.2.6
MODULE_VIRT_COMMIT=5d1c179d8ecf6119caf9b8e0d0a385e45a113ba3
MODULE_VIRT_COMPONENT=CasaOS-VirtManagement
MODULE_VIRT_TIER=core
```

For a module of another owner they are seven, the four above and three more. A worked example
for an imaginary module, `example-author/example-module`, which is `example-module` on a
box:

```
MODULE_EXAMPLE_MODULE_TAG=v1.0.0
MODULE_EXAMPLE_MODULE_COMMIT=0123456789abcdef0123456789abcdef01234567
MODULE_EXAMPLE_MODULE_COMPONENT=example-module
MODULE_EXAMPLE_MODULE_TIER=community
MODULE_EXAMPLE_MODULE_OWNER=example-author
MODULE_EXAMPLE_MODULE_SHA256_AMD64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MODULE_EXAMPLE_MODULE_SHA256_ARM64=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

- `TAG`: the tag of the module's release, `v<number>.<number>.<number>`.
- `COMMIT`: the full commit that tag names: `git rev-parse <tag>^{commit}` in the module's
  repository, or the commit shown on its release page. The check refuses a tag that names
  another commit.
- `COMPONENT`: the module's repository. For a module of ReCasaOS it is in the ReCasaOS
  organisation; for another owner it is the repository of that owner (`OWNER`).
- `TIER`: `core` or `community` (below). A module of another owner is `community`.
- `OWNER`: the GitHub owner of the repository: letters, digits and inner hyphens, 39 at most.
  A module of ReCasaOS has no `OWNER` line.
- `SHA256_AMD64` and `SHA256_ARM64`: the SHA-256 of each archive, 64 lower case hexadecimal
  digits, both required for a module of another owner and refused for one of ReCasaOS. These
  are the digests of the archives that were reviewed: compute them (`sha256sum`) on the
  archives of the release. Each archive must have both the SHA-256 its `checksums.txt` lists
  and the one written here.

A new module is its lines added; the comment at the top of `modules.env` gives the exact
format. A `modules.env` with no module is refused: a catalogue with no module is not
published.

A version already published cannot be republished or lowered: a correction is a new, higher
tag. Changing only the tier of a published version is allowed.

## What the check does

`.github/workflows/check.yml` runs on every pull request, read only. It runs every test of
`tests/`, then `scripts/build.sh`:

1. fetches the installer (`ReCasaOS/CasaOS-Install`) and the core (`ReCasaOS/CasaOS`) at the
   two commits of `refs.env`, never by a branch name, and requires each commit to be in the
   history of that repository's `main`;
2. downloads each module's `checksums.txt` and archives and checks every archive against the
   SHA-256 its `checksums.txt` lists, and for another owner against the digests of
   `modules.env`; a file larger than 200 MiB stops the build; a release that is gone, or
   whose archives do not match, fails here, with the module named. A module of another
   owner that the published catalogue already offers at the same tag is not fetched again;
3. builds both catalogues with the installer's `build-modules-catalogue.py`, which checks the
   tag against the commit, the module's `module.json` against its repository, and everything a
   box would refuse;
4. for a module of another owner, checks the attestation of both archives
   (`scripts/attest.sh`) and that each archive carries a `LICENSE` (`scripts/license.py`);
5. checks each new catalogue against the published one of the same name
   (`scripts/compare.py`): a module at a tag already published must keep the same commit,
   archives and manifest, no tag may be lower than the published one, and a module never
   changes repository; and checks that no retired name, unit or route is taken, and that no
   published module has disappeared without a line in `retired.env` (`scripts/names.py`; that
   last check applies once a `catalogue-3.json` is published);
6. builds the core and has it read each catalogue as a box does; it must take it and list
   every module it should, at its pinned tag and tier.

Any failure stops the check with one sentence saying which. The summary of the run, which the
reviewer reads, shows what the change does to the published catalogue: each module added,
removed, updated or with its tier changed, with tag and tier before and after; for each module
added or updated its repository, packages, unit and route, and a link to what changed in its
repository; the versions newly withdrawn or no longer withdrawn; and the SHA-256 of both files
that were built.

`refs.env` pins the installer and the core used by the check. Changing either commit is a
pull request like any other.

## What ReCasaOS reviews, and what it does not guarantee

When a module enters the catalogue, and at each new version, a maintainer reads in the pull
request: the module's repository and the diff of the version, `module.json`, what the archive
writes on the box and the service it runs, its packages, its `LICENSE`, and the summary of the
check. The digests in `modules.env` are those of the archives that were reviewed.

The tier `community` means: written outside ReCasaOS, reviewed when it enters the catalogue,
not tested by us. A box says so before it installs the module, whose service runs as root like
the other ReCasaOS services. The tier `core` is for modules maintained by ReCasaOS and proven
on a real machine.

The check proves that the archives are the ones that were reviewed, that they were built by the
author's own workflow from the tagged commit, and that a box can read the catalogue. It does
not prove that the module does what it says.

## The copy

At the merge, the archives of each version that is new are copied into a release of this
repository named `m-<name>-<tag>` (`<name>` is the name of the module on a box), with the two
archives and `checksums.txt` under the names the author gave them. `catalogue-3.json` gives
that address for every archive, and boxes download only that copy.

Why: what a box installs is what was reviewed. A version already published is never fetched
from its author again, so deleting or changing the original repository, tag or release changes
nothing for the boxes, and the catalogue still builds.

A published version never changes: a release `m-<name>-<tag>` is never replaced or edited,
and a new release of a module needs a new tag.

## Leaving the catalogue

- To remove a module, remove its lines from `modules.env` and add its line to `retired.env`:
  `<name> <unit> <route>`, with `-` for a module that had no route. The check refuses a
  published module that disappears without that line. Its name, unit and route stay reserved:
  a pull request that takes one of them is refused. Boxes that have the module keep it.
- A module never moves to another repository or another owner. A module that is published
  keeps its repository, and the check refuses a change of it. To move a module, retire it and
  enter another name.
- Removing a line of `retired.env` frees its name, unit and route. It is a maintainer's
  decision, stated as such in the pull request.

## Flagging a version

`withdrawn.txt` lists the versions that must no longer be offered, one line each:

```
<name> <tag> <reason>
```

`<name>` and `<tag>` are those of the module and the version; the reason is the rest of the
line, the text a person reads on a box. Blank lines and lines that start with `#` are ignored.
It is published in `catalogue-3.json`. A box is told once, by an alert, that a version it has
is withdrawn; the version is no longer offered and cannot be installed. Nothing is
uninstalled.

## Reviewing a pull request

The check of a pull request runs the workflow and the scripts of that pull request itself.

- A green check means something only when the pull request changes `modules.env` alone.
- Any change to `refs.env`, `scripts/`, `tests/`, `.github/`, `retired.env` or
  `withdrawn.txt` changes what is published to every box, or how: review it as code.
  `scripts/mirror.sh`, `scripts/publish.sh` and `.github/workflows/publish.yml` run with the
  right to publish.
- A new commit in `refs.env` must be on the `main` of its repository.
- Read the summary of the run for removed modules: a merge removes them from every box.

## Publication

Each push on `main` runs `.github/workflows/publish.yml`. Its first job builds and checks the
catalogues exactly as the check does, read only, and hands its whole output on. Its second job
holds the right to publish and runs only scripts of this repository, in this order:

1. `scripts/mirror.sh` copies the archives that are not yet in a release of this repository
   into releases `m-<name>-<tag>`. It first re-checks every archive against the SHA-256 of
   `catalogue-3.json` (and, for another owner, against `modules.env`), and creates nothing if
   one differs. Each release is created as a draft on the commit being published, its three
   files are downloaded back and compared byte for byte, and only then is it published, not
   as the latest release;
2. `scripts/publish.sh` creates the release `c<serial>` as a draft, attaches `catalogue-2.json`
   and `catalogue-3.json`, downloads both back and requires the same bytes, and only then
   publishes it as the latest release;
3. the workflow reads the two addresses that boxes read and requires the files it published.

The copies come first, the catalogue after: a catalogue never names an archive that is not
there. A failure before step 2 publishes nothing in `c<serial>`, and the published catalogue
is unchanged. Two publications never run at once.

The serial is the run number of the publication workflow, and it only goes up: `publish.sh`
refuses a serial that is not above the one published. Both files of a release have the same
serial and the same `generated` time.

A published release is never deleted or edited by hand, and its assets are never replaced: a
correction is a new merge.

To see what is published: the latest release of this repository, or

```
curl -sSL https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-2.json
curl -sSL https://github.com/ReCasaOS/modules/releases/latest/download/catalogue-3.json
```

The summary of each publication run shows what it changed and the SHA-256 of both files.

## The two tiers

- `core`: maintained by ReCasaOS and proven on a real machine.
- `community`: written outside ReCasaOS, reviewed when it enters the catalogue, not tested by
  us. A box says so before it installs the module, whose service runs as root like the other
  ReCasaOS services.

## Run it locally

On Linux, with bash, git, curl, Python 3.12 and Go, as a user that is not root:

```
for t in tests/*.sh; do bash "$t"; done      # offline tests, with fake gh and curl
for t in tests/*.py; do python3 "$t"; done
GITHUB_REPOSITORY=ReCasaOS/modules GH_TOKEN="$(gh auth token)" bash scripts/published.sh published  # what is published now
bash scripts/build.sh 1 out published        # OUTDIR must not exist
python3 scripts/summary.py published out
```

`scripts/build.sh SERIAL OUTDIR [PUBLISHED_DIR]` writes `out/catalogue-2.json`,
`out/catalogue-3.json` and `out/mirror/`. Each script says its usage at its top.

## For the maintainer

- **A published release is final.** Never delete one, never edit one by hand, never
  replace its file: boxes keep the highest serial they have seen. A correction is a new
  merge, which publishes the next serial.
- **A Publish run shown as cancelled** was replaced by a newer one waiting behind it. The
  newer run publishes everything `main` holds, so nothing is lost. If no run followed,
  start *Publish* by hand on `main`.
- **A publication that does not go as planned** stopped at one of two places, and its log
  says which.
  - In the copies (`mirror.sh`): some `m-<name>-<tag>` releases may be published and the
    catalogue `c<serial>` is not. The copies already published stay: never delete them. A
    draft `m-<name>-<tag>` left by the failed run is the one the log names: delete that
    draft, then start *Publish* by hand on `main`; the new run copies what is missing and
    publishes. A release `m-<name>-<tag>` that exists with other files or other digests than
    the catalogue stops the run: that is a decision for a maintainer, not something to
    replace.
  - In the catalogue (`publish.sh`): a draft `c<serial>` is left, with the published
    catalogue unchanged. Delete the draft, then start *Publish* by hand on `main`: the new
    run takes a new serial.
- **Running the publish job again** with the same serial, after a failed copy or after
  deleting a left draft, finishes the work: `mirror.sh` skips the copies that are
  published and checked. What `publish.sh` refuses is a `c<serial>` that already exists,
  draft or not.
- **A release `m-<name>-<tag>` is never marked latest.** If one ever is, the address every
  box reads answers nothing until the last `c<serial>` release is marked latest again: do
  that first, then publish.
- **The serial only goes up.** It is the number of the Publish run. If a file with too high
  a serial was ever served, boxes that read it keep it and refuse lower ones: the way out
  is to publish a serial above it, never to go back.
- **`refs.env` moves forward.** Pin commits that are on `main` of their repository, and
  newer than the ones they replace.
- **Removing a line of `retired.env`** frees a name, a unit and a route for good: do it only
  as a stated decision in the pull request.
