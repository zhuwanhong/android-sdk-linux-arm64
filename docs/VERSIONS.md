# Which versions this project tracks

Google publishes **67 NDK versions** across 15 major releases (r16 … r30) and
**82 build-tools revisions**. Chasing that matrix is not possible; picking from
it needs a stated rule, or the choice quietly becomes "whatever was newest the
day someone looked".

## The rule

**Track what the ecosystem actually pins, not what is newest.**

- **Three LTS releases** — Google marks only five NDK releases LTS (r21e, r23,
  r25, r26, r27); we follow the three most recent: **r25, r26, r27**.
- **Plus the current default** — the version AGP and the big frameworks default
  to, which today is **r28**, *not* the newest release (r30).
- **One patch release per major**, chosen by what projects pin — see below.

Newness is a bad criterion on its own: r29 and r30 exist, but almost nothing
uses them yet, while r28 is what every project that does not pin `ndkVersion`
gets from AGP 9.3.

## Which patch release, and why it is not always the newest

Projects pin **exact** versions, so the patch release matters:

| Who | Pins exactly | That is | Newest in its major? |
|---|---|---|---|
| React Native | `27.1.12297006` | r27**b** | **No** — newest r27 is 27.3.13750724 (r27d) |
| Flutter, and AGP 9.3's default | `28.2.13676358` | r28**c** | Yes |
| Godot (master) | `29.0.14206865` | latest r29 | Yes |

So "keep only the newest patch" would drop `27.1.12297006` — and then **every
React Native project has to edit `ndkVersion` by hand**. If they don't, AGP
downloads the version they pinned, which is x86_64-only. Measured 2026-08-31:
with no pin at all, AGP 9.3.2 silently installed a 2.2 GB x86_64 NDK whose
`clang` cannot exec on ARM64.

Hence: **one patch release per major, and it is the one the ecosystem pins.**

## Status

| Major | Version we build | Why | Built? |
|---|---|---|---|
| r27 (LTS) | `27.1.12297006` | Current LTS; React Native pins it | **yes** |
| r28 | `28.2.13676358` | AGP 9.3 default; Flutter pins it | **yes** |
| r26 (LTS) | `26.3.11579264` | older LTS, on request | no |
| r25 (LTS) | `25.2.9519653` | older LTS, on request | no |
| r29, r30 | — | newer, but neither is LTS and nothing defaults to them | no |

Checked 2026-09-04, because upstream having r30 out looks like a reason to move
and is not one:

- Google's NDK revision history marks **r21e, r23, r25, r26, r27** as LTS and
  nothing newer — r29 and r30 are ordinary releases.
- The newest stable AGP, **9.4.0**, still defaults to `28.2.13676358` — read out
  of the constant in its own jar, same value as 9.3.1.

`tools/check-upstream-versions.sh` now tests those two conditions rather than
"is there something newer", and runs monthly from `smoke-build`. Its first
version compared against the newest release and would have gone yellow every
month for a version we deliberately do not ship — a check nobody would read
after the third time.

## I want a version you do not ship

Any NDK version can be built from these recipes; the shipped set is a default,
not a limit.

**Build it yourself** — one command, and it works out which LLVM branch that NDK
needs rather than making you find out:

```bash
tools/build-ndk-version.sh 29.0.14206865      # or any version in the manifest
tools/fetch-google-package.sh --list-stable ndk   # what upstream has
```

Expect roughly 90 minutes for LLVM plus packaging, and see the notes on clang
version skew below — a release whose declared compiler version has moved on
needs `ALLOW_CLANG_VER_SKEW=1`, and you should check what ended up in the
package afterwards.

**Or ask for it.** Open an issue saying which version and why. Publishing one
into an existing release is a documented, mostly unattended operation — the
`ndk_only` mode in [RELEASING.md](RELEASING.md), which is exactly how r28 was
added next to r27.

Both NDKs are attached to the same release. r28 package: `android-ndk-28.2.13676358-linux-aarch64-ours.tar.gz`, 340 MB,
sha256 `4c0b810194744c7b542e72a0daf456c0b3eb460b565d83ab032ceb59e5735c39`.

`build-tools` is a different story: our binaries come from AOSP source and are
not tied to a build-tools revision, so `tools/install.sh --build-tools <rev>`
covers **any** of the 82 revisions by fetching Google's files for that revision
and layering ours on top.

## What one more version costs

Roughly **88 minutes of LLVM build** (measured, 4-core ARM64), a **349 MB**
package, and a full verification pass. Four NDK versions means about six hours
of machine time per release cycle and 1.4 GB of artifacts.

## Adding one

```bash
tools/build-ndk-version.sh 28.2.13676358            # or --ndk /path/to/an/NDK
tools/build-ndk-version.sh --ndk /path/to/NDK --dry-run   # just resolve, don't build
```

It reads the target NDK's own `AndroidVersion.txt` (which states the Clang
version and the `rXXXXXX<letter>` revision), derives the LLVM branch, and
**verifies that branch exists upstream** before building anything. Calibrated
against r27.1, where it derives exactly the values this repository has pinned.

The build then cross-checks the other direction too: the NDK's
`clang_source_info.md` declares the upstream base revision of its Clang, and
that commit must appear in the LLVM tree we built from. Otherwise you can ship
a compiler stamped with a revision it was not built from.

**Older majors**: `patches/ndk/` was written against r27's build scripts. They
**apply cleanly to r28** (verified). r25 and r26 are from 2022–2023 and have not
been tried.

## The r28 build carries a one-patch version skew

Our clang for r28 reports **19.0.2**; the NDK declares **19.0.1**. Both come
from Google's `llvm-r530567` branch — we build the branch tip, and the branch
moved on after Google cut r28c. (For r27 the tip happened to still sit on the
release point; that was luck, not design.)

Building anyway requires `ALLOW_CLANG_VER_SKEW=1` — the check fails loudly by
default, because a silently mismatched compiler stamp is exactly the kind of
thing this repository refuses to ship.

What the skew was measured to mean (2026-09-01):

- clang's resource directory is keyed by **major** version (`lib/clang/19`), so
  grafting r28c's runtime onto our 19.0.2 compiler resolves correctly;
- `ndk-build` and the CMake toolchain file both produce working aarch64 `.so`s;
- an APK built with it **runs on a real phone** (Android 16, arm64-v8a):
  `RESULT native ok: 64-bit … 20+22=42`, and the APK pulled back off the device
  is byte-identical (sha256) to the one built here;
- the resulting `.so` carries **both** `clang version 19.0.1` and `19.0.2` in
  `.comment` — our compiler's code linked against the NDK's runtime objects.

One acceptance step cannot be run for r28 on this machine: the **golden driver
comparison** (`build-llvm.sh` step 3/6) was recorded against clang 18.0.2, and
clang 19 expands AArch64 target features differently. Recording a clang 19
golden needs a machine that can execute the official x86_64 clang. The step now
says "not verified" for other versions instead of failing — untested is not
the same as broken, and neither is the same as fine.

Chinese: [zh/VERSIONS.md](zh/VERSIONS.md).
