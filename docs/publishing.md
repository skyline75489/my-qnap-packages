# Publishing a package

How a built `.qpkg` becomes a downloadable GitHub release, and what has to be true
before that is allowed to happen.

A QPKG release is not a special format: GitHub releases are just downloadable
assets, so a `.qpkg` is uploaded as a file. The interesting parts are the gates
around it.

## The rules

1. **Never publish what the harness has not verified.** `scripts/release.sh` runs the
   package's harness first and aborts on failure. A release is public and permanent;
   a broken package is a support burden for whoever installs it.
2. **Publish the digest of the artifact, never a claim of reproducibility.** QPKG
   builds are not reproducible — two builds of identical inputs differ by a couple of
   bytes, because a temp directory's mtime lands in the tar. So the published
   `.sha256` identifies *that file*, not a canonical build of the sources. Say so in
   the release notes; a digest presented as reproducible is a lie that ages badly.
3. **Redistribution has obligations.** OpenList is AGPL-3.0 and Backrest is GPL-3.0.
   The package therefore ships the upstream `LICENSE` text and a `SOURCE.txt` naming
   the exact upstream version it was built from. `release.sh` refuses to publish a
   package that is missing either.
4. **Ask before making something public.** The script prompts before it creates or
   replaces a release; `--yes` skips the prompt for unattended runs.

## Usage

```sh
gh auth login                                    # once
scripts/build-qpkg.sh backrest                   # build first
scripts/release.sh backrest --dry-run            # show what would be published
scripts/release.sh backrest                      # publish, with a prompt
```

| Option | Effect |
|---|---|
| `--repo owner/name` | Target repository. Defaults to the `origin` remote. |
| `--tag TAG` | Release tag. Defaults to `<package>-<version>`, e.g. `backrest-1.14.1`. |
| `--title TITLE` | Release title. Defaults to `<Name> <version> — QPKG for QNAP QTS`. |
| `--notes FILE` | Use your own release notes instead of the generated ones. |
| `--dry-run` | Do everything except touch the network: runs the harness, prints the notes. |
| `--yes` | Skip the confirmation prompt. |

The version, port and licence in the release notes are read from the package's own
`qpkg.cfg`, and the upstream project, version and source URL from
`packages/<name>/shared/SOURCE.txt` — so the notes cannot drift from what was
actually packaged.

Re-running the script for the same tag replaces the assets (`--clobber`) and updates
the notes, rather than failing.

## What a release contains

| Asset | Purpose |
|---|---|
| `<Name>_<version>_x86_64.qpkg` | The package itself |
| `<Name>_<version>_x86_64.qpkg.sha256` | Digest of that exact file, in `sha256sum` format |
| `<Name>_<version>_x86_64.qpkg.md5` | The MD5 QTS itself writes next to a built package. Not published — it is a build-time artifact, and a second checksum of the same file adds confusion rather than trust. |

## Keeping the source pointer honest

`packages/<name>/shared/SOURCE.txt` names the upstream version the package was
built from. When the upstream version is bumped:

1. update the version in the fetch script (`BACKREST_VERSION`, `OPENLIST_VERSION`,
   `ZOT_VERSION`);
2. update `packages/<name>/shared/SOURCE.txt` to match;
3. refresh `packages/<name>/shared/LICENSE` from the new upstream release;
4. rebuild, re-run the harness, and publish under the new tag.

The licence text is vendored rather than fetched, so it is reviewable in a diff —
but that also means it can go stale. It is the one thing in the package that is not
verified by the harness.

## Signing

These packages are **unsigned**. QTS requires *App Center → Settings → Allow
installation of applications without a valid digital signature* before it will
install one, and the release notes say so. `qbuild --sign` can sign with a GPG key,
but a QNAP-signed package needs QNAP's signing service; that is a separate piece of
work, not a flag to flip.

## What publishing does not do

- It does not publish the payload sources. The upstream source is public and
  `SOURCE.txt` points at the exact release tag.
- It does not make the build reproducible. See rule 2.
- It does not install anything on a NAS. Installing remains the user's call.
