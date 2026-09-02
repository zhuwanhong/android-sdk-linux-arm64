# Contributing

The unusual thing about this repository is not the build recipes, it is the
**evidence discipline**. Most review comments you will get are about that, so
it is worth reading this first.

## Before you start

```bash
tools/setup-hooks.sh    # required once per clone; git cannot install hooks for you
tools/ci-checks.sh      # ~15 seconds: syntax, CRLF, exec bits, doc consistency, links
```

`ci-checks.sh` being green does not mean anything works — that is what `tests/`
is for — but if it is red, stop there.

## The rules

**1. "It compiled on x86" proves nothing.** Any claim about an artifact must
come from running it on an ARM64 Linux machine.

**2. Adding a tool means adding a check that fails when that tool breaks.**
Not a file-existence check. The stock `aapt2` was present, executable, and
exited 126 on ARM64 — presence proves nothing.

**3. Prove your check can go red.** Remove the fix, run the check, watch it
fail, put the fix back. A test that cannot fail is decoration. Check that your
mutation is a real mutation, too: `[ 1 = 1 ;` looks broken but is valid shell,
so `bash -n` stays green on it.

**4. Three outcomes, three exit codes.**

| | |
|---|---|
| `0` | verified |
| `1` | real failure |
| `2` | **could not be verified** — no device attached, no tunnel, missing prerequisite |

Never collapse `2` into `1` or `0`. In CI, treat it as *skipped*: as failure it
makes "untested" look like "broken"; as success it makes "untested" look like
"tested".

**5. Say what you did not check.** "No `ar(1)` on this machine, zero static
libraries were checked" is a useful line. Silence is not.

**6. Don't edit a script while it is running.** bash reads incrementally; you
will corrupt the log and the exit code of a run in progress.

## Where things go

| | |
|---|---|
| `tools/build-<tool>.sh` | one tool; shared scaffolding is in `tools/build-common.sh`, don't copy it |
| `cmake/<tool>.cmake` | target definition; **copy the dependency list from that tool's own `Android.bp`**, not from somebody else's CMake |
| `patches/<project>/` | one directory per upstream project, plus a `README.md` saying why each patch exists |
| `tests/` | sample apps, built both by hand and through AGP — both paths must work |
| `docs/` | English; Chinese originals live in `docs/zh/` and should be kept in step |
| `docs/RELEASING.md` | how a release is cut and why the steps are in that order — read it before tagging |
| `.github/workflows/` | `checks.yml` (fast, every push), `smoke-build.yml`, `release-build.yml` (manual; produces the release artifacts) |

Anything that produces a release archive goes through `repro_tar` in
`tools/repro.sh` — never a bare `tar -czf`. Published checksums are only
meaningful if a third party can regenerate them, and a plain `tar` records
readdir order, filesystem mtimes and the packager's uid/gid. Verify with
`tools/check-reproducible.sh`, which packages twice and compares.

Anything that downloads a package Google publishes goes through
`tools/fetch-google-package.sh` — do not write another manifest parser. The
download URL must be looked up in Google's `repository2-3.xml`, never
hardcoded (package revisions change: `platform-36_r02.zip` will expire), and
the archive must be selected by `host-os`, or you get the Windows zip.

`tools/build-llvm.sh` deliberately does **not** use the shared scaffolding: it
builds host tools, not Android-target binaries, so none of the scaffolding's
assumptions (NDK toolchain file, `ANDROID_ABI`, "assert the artifact is
aarch64") apply.

## Patches

Every patch has to answer three questions, recorded in
[`patches/UPSTREAM.md`](patches/UPSTREAM.md): does upstream have this problem,
has upstream fixed it, and should we send it upstream?

```bash
tools/check-upstream-patches.sh    # exit 10 = upstream changed, go update that file
```

Written-down conclusions rot; a script that fetches the file from upstream and
looks for the fix does not. If upstream has already fixed something, the right
move is to bump the tag and **delete** our patch, not to maintain it.

## Documentation

`docs/PARITY.md` is the project's promise: what you can and cannot do, by
scenario, **with a runnable command in every row**. If your change adds or
removes a capability, update it and `docs/parity.json` together —
`tools/check-parity.sh` fails if they drift apart, and it checks the Chinese
copy too.

If you learn something the hard way, add it to [`docs/LESSONS.md`](docs/LESSONS.md).
That file is more valuable than any individual build recipe here.

## Commits

Small commits, and **say why, not what** — the diff already says what. Where a
number appears (sizes, timings, exit codes), it should be one you measured.

Write commit messages in **English**. The rest of the repository is
deliberately bilingual — comments in `tools/` and `cmake/` and the originals in
`docs/zh/` are Chinese, because that is where the reasoning was worked out — but
the commit log is a public surface (it is what GitHub shows first, and what
`git log` gives anyone who clones), so it stays in one language.

## License

By contributing you agree your contributions are licensed under Apache-2.0,
the same as the rest of the repository.
