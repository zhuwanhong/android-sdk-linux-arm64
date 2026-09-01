# android-sdk-linux-arm64

**Android SDK and NDK build tools for ARM64 Linux.**

Google publishes Android's build tools for `linux-x86_64` only. That means an
ARM64 Linux machine — Ampere, Graviton, a Raspberry Pi, the cheapest instance
on most clouds, or an ARM laptop running Linux — **cannot build Android apps**.

The source is open (AOSP + LLVM). What was missing is somebody compiling it.

This project compiles it, and packages the result so you can install it into
`$ANDROID_HOME` and use the normal Android toolchain on ARM64 Linux.

> **Not affiliated with Google.** Android is a trademark of Google LLC. This is
> an independent rebuild from public source. It redistributes no Google-signed
> or Google-branded artifacts — see [What the release contains](#what-the-release-contains).

## Is the premise still true?

Everything here rests on one claim: *Google ships no `linux/aarch64` packages.*
That can change, so it is a script, not a sentence in a README:

```bash
tools/verify-claims.sh
#  0  premise still holds
# 10  Google now ships linux/aarch64 — this project can be retired (good news)
#  1  an assertion could not be verified
```

As of 2026-08-30 it exits 0. Google's own `repository2-3.xml` lists
`linux/x64`, `macosx/aarch64` and `windows/x64` for the emulator, and
`linux/x64` for build-tools and platform-tools. macOS gets ARM64 builds;
Linux does not.

## Install

```bash
git clone https://github.com/zhuwanhong/android-sdk-linux-arm64
cd android-sdk-linux-arm64

tools/install.sh --sdk-root ~/Android/Sdk \
    --sdk-tgz  /path/to/android-sdk-linux-arm64-36.0.0-ours.tar.gz \
    --ndk-tgz  /path/to/android-ndk-27.1.12297006-linux-aarch64-ours.tar.gz \
    --platform 36
```

The installer does four things, **each of which the SDK is unusable without**:

1. unpacks our binaries;
2. links in the distro's `cmake` / `ninja` / `lldb` / `clangd` / `glslc` —
   skip this and AGP silently downloads an **x86_64** cmake into your SDK;
3. fetches the parts we do not redistribute (see below) from Google, and
   deletes any x86_64 host binary it brought along that we do not replace;
4. writes `android.aapt2FromMavenOverride` into `~/.gradle/gradle.properties` —
   **AGP does not use the `aapt2` in your SDK**, it resolves an x86_64 one from
   Maven and dies with `AAPT2 …-linux Daemon #0: Daemon startup failed`.

Then it **proves the install works** rather than asking you to believe it: runs
`aapt2`, starts a real `adb` server, runs the NDK's `clang`, and builds an APK
with a native library in it. Exit code 0 means all of that passed.

Details and the manual step-by-step: [docs/INSTALL.md](docs/INSTALL.md).
Which SDK/NDK versions this project tracks, and why those:
[docs/VERSIONS.md](docs/VERSIONS.md).

## What works, what doesn't

Organised by **scenario**, not by binary — the question is never "do you ship
`split-select`", it is "can I debug native code". Every row carries a command
you can run yourself:

**[docs/PARITY.md](docs/PARITY.md)** — 21 scenarios: 15 ✅, 1 ⚠️, 5 ❌.
Machine-readable copy in [docs/parity.json](docs/parity.json).

Highlights: building release APKs through Gradle/AGP, `ndk-build` and CMake
native builds, React Native (we build `hermesc`), installing to a device,
**native debugging with lldb against a real phone**, `clang-tidy`, `simpleperf`
(partly), and installing our packages through `sdkmanager`.

Not possible: the emulator, Layout Inspector and Android Auto's DHU (Google
ships those for macOS ARM64 but not Linux ARM64, and they are closed source),
RenderScript (deprecated upstream), and **Android Studio itself** — Google has
no Linux ARM64 build of it. IntelliJ IDEA Community does ship `linuxARM64`.

## What the release contains

**Only binaries this project compiled from third-party source.** Nothing that
was copied out of Google's SDK or NDK downloads.

| Package | Contents |
|---|---|
| `android-sdk-linux-arm64-<rev>-ours.tar.gz` (37 MB) | 15 binaries built from AOSP `platform-tools-35.0.2`: `aapt`, `aapt2`, `aidl`, `dexdump`, `split-select`, `zipalign`, `lld`, `adb`, `etc1tool`, `fastboot`, `hprof-conv`, `make_f2fs`, `make_f2fs_casefold`, `mke2fs`, `sqlite3` |
| `android-ndk-<ver>-linux-aarch64-ours.tar.gz` (349 MB) | `clang` 18.0.2 / `lld` / `llvm-*` built from LLVM `llvm-r522817`, a self-contained CPython 3.11.4, and the host half of `simpleperf` |
| `hermesc-<ver>-linux-aarch64.tar.gz` (1.6 MB) | Hermes bytecode compiler for React Native |

Everything else — `d8.jar`, `apksigner`, the wrapper scripts, the NDK's
`sysroot`, `build/`, `sources/` — is fetched from Google by the installer, so
**you** accept Google's terms for their files, and we redistribute none of them.

glibc floor is measured per binary, not assumed from the build host:
**SDK 2.34, NDK 2.35**. Ubuntu 22.04 and Debian 12 both work; the host tools
are built inside an `ubuntu:22.04` container to keep it that way.

## How this is verified

The distinguishing feature of this repository is not the binaries, it is the
evidence discipline. Four rules, all of them learned the hard way:

1. **"It compiled on x86" proves nothing.** Artifacts must run on a real ARM64
   machine before any claim is made.
2. **Every artifact needs a command that fails when it breaks** — not a file
   existence check. `aapt2` was present and executable in the stock SDK and
   still exited 126 on ARM64.
3. **New check? Prove it goes red.** Remove the fix, watch the test fail, put
   it back. A green test that cannot fail is decoration.
4. **Exit codes distinguish three outcomes**: `0` verified, `1` real failure,
   `2` **could not be verified** (no device, no tunnel). Treating `2` as failure
   makes "untested" look like "broken"; treating it as success is worse.

Roughly forty specific mistakes — silent failures, self-matching greps, false
greens — are written down in [docs/LESSONS.md](docs/LESSONS.md), because the
binaries are reproducible and those are not.

## Repository layout

```
tools/          build recipes, one per tool, plus packaging and install
cmake/          CMake targets mirroring each upstream Android.bp
patches/        our patches, each with why it exists and its upstream status
tests/          two sample apps, built twice: by hand and through AGP
docs/           PARITY, INSTALL, LESSONS; docs/zh/ has the Chinese originals
.github/        CI
```

## Status

The toolchain is complete enough to build and ship real apps: a React Native
release APK was built end to end on ARM64 Linux with no qemu, installed on a
phone, and debugged with `lldb` over adb.

Remaining work and explicit non-goals are in
[docs/zh/README.md](docs/zh/README.md) (roadmap section, Chinese).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first — it is mostly about the
verification rules above. Patches that add a tool without adding a check that
fails when that tool breaks will be asked for the check.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Built artifacts keep their upstream licenses: AOSP components Apache-2.0,
LLVM Apache-2.0 with LLVM Exceptions, Hermes MIT, CPython PSF.
