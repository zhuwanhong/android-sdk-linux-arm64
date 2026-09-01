# Release notes — v1.0.0

Draft text for the GitHub release. Artifacts, checksums and the numbers below
are measured on the machine that built them; rebuild and re-measure before
publishing a different set.

---

## android-sdk-linux-arm64 v1.0.0

Android SDK and NDK build tools for **ARM64 Linux**, compiled from AOSP and
LLVM source. Google publishes these for `linux-x86_64` only.

### Artifacts

Built from tag `v1.0.0` (`0111b18`). Packaging is reproducible — see below.

| File | Bytes | sha256 |
|---|---:|---|
| `android-sdk-linux-arm64-36.0.0-ours.tar.gz` | 37,990,299 | `6863d7aef7cd6e65722d082a84c365123355c76c2fdf9f207436d593ebeeafb6` |
| `android-ndk-27.1.12297006-linux-aarch64-ours.tar.gz` | 349,774,896 | `347f1f6df579f90e1b43644eabaeeb062d69c4feaeceeebecc7d4f52b69e839e` |
| `hermesc-250829098.0.17-linux-aarch64.tar.gz` | 1,664,158 | `c774978153b2ea719a15c5c7a86b6b0753c07d33a40f86afbf6fd979ddc5efb0` |

### Reproducing these archives

Packaging is **byte-for-byte reproducible**: the same inputs produce the same
`.tar.gz`, so the checksums above are something you can check independently
rather than something you have to take on trust.

```bash
git checkout v1.0.0          # the tag the artifacts were built from
tools/make-dist.sh --ours-only     # needs the compiled binaries in $WORK/out
sha256sum work/android-sdk-linux-arm64-36.0.0-ours.tar.gz
```

Note what that requires: the packaging step consumes binaries that are already
built, so this reproduces the archive **given the same binaries**, not from a
bare checkout.

`SOURCE_DATE_EPOCH` defaults to the commit date of `HEAD`, so **checking out the
release tag is what makes the checksum match** — building from a later commit
produces a different (but equally reproducible) archive. Override it explicitly
with `SOURCE_DATE_EPOCH=<unix time>` if you need to. The
project checks this itself — `tools/check-reproducible.sh` packages twice, from
a directory rebuilt in between, and compares the two checksums.

What is reproducible is the **packaging** step: given the same compiled
binaries, the archive is identical. Bit-for-bit reproducibility of the compilers
themselves (LLVM, and the tools built with it) is a separate problem and is
**not** claimed here.

### Install

```bash
git clone https://github.com/zhuwanhong/android-sdk-linux-arm64
cd android-sdk-linux-arm64
tools/install.sh --sdk-root ~/Android/Sdk \
    --sdk-tgz  ../android-sdk-linux-arm64-36.0.0-ours.tar.gz \
    --ndk-tgz  ../android-ndk-27.1.12297006-linux-aarch64-ours.tar.gz \
    --platform 36
```

The installer finishes by building an APK with a native library in it, so exit
code 0 means the install actually works. Full instructions:
[INSTALL.md](INSTALL.md).

### What these archives contain

**Only binaries compiled from third-party source by this project.** Files that
Google distributes — `d8.jar`, `apksigner`, the wrapper scripts, the NDK's
`sysroot` and `build/` — are **not** redistributed here; `tools/install.sh`
fetches them from Google at install time, under Google's own terms.

- **SDK**: `aapt`, `aapt2`, `aidl`, `dexdump`, `split-select`, `zipalign`,
  `lld`, `adb`, `etc1tool`, `fastboot`, `hprof-conv`, `make_f2fs`,
  `make_f2fs_casefold`, `mke2fs`, `sqlite3` — from AOSP `platform-tools-35.0.2`
- **NDK**: `clang` 18.0.2, `lld`, `llvm-*` from LLVM `llvm-r522817`; a
  self-contained CPython 3.11.4; the host half of `simpleperf` (Google ships
  x86_64 only)
- **hermesc**: the Hermes bytecode compiler React Native needs for release
  builds; npm ships win64 / macOS / linux-x86_64 only

### Requirements

aarch64 Linux with **glibc 2.35 or newer** — Ubuntu 22.04, Debian 12 and
anything newer. Measured per binary, not assumed from the build host: the SDK
needs 2.34, the NDK 2.35. Host tools are built inside an `ubuntu:22.04`
container to keep that floor.

Also needs a JDK (17 or 21), `curl`, `unzip` and `tar`.

### Verified on ARM64 hardware

- Both sample projects build APKs through Gradle/AGP, including a CMake native
  build; APK contents checked, not just the exit status
- A React Native release APK built end to end with no qemu, installed on a
  phone (Android 16, arm64-v8a) and running
- `lldb` attached to that phone over adb through `adb forward`: stopped, read
  `pc`, continued to a clean exit — three runs, same result
- `simpleperf` recorded 1,368 samples locally and read them back
- `sqlite3` matches Google's build on both ICU probes, byte for byte in the
  error text
- Our packages install through `sdkmanager` from a locally served repository,
  and the installed binaries run

What is **not** possible on ARM64 Linux — the emulator, Layout Inspector,
Android Auto's DHU, Android Studio itself — is listed with reasons and
alternatives in [PARITY.md](PARITY.md).

### Known gaps

- `libsimpleperf_report.so` is missing, so simpleperf's Python reporting does
  not work (a CPython process cannot mix bionic and glibc). The command-line
  `record`/`report` does.
- Reading a `perf.data` recorded *on a device* is not yet verified.
- Builds are not bit-for-bit reproducible.

### Licence

Apache-2.0. Built artifacts keep their upstream licences: AOSP components
Apache-2.0, LLVM Apache-2.0 with LLVM Exceptions, Hermes MIT, CPython PSF.
Not affiliated with Google. Android is a trademark of Google LLC.
