# What you can and cannot do

**This file is the promise this project makes, and the standard it is held to.**

The question is never "which binaries do you ship". It is **"the thing I do on
a Mac or an x86 box — can I do it here?"** So this is organised by scenario.

Three states, kept distinct:

| | Meaning |
|---|---|
| ✅ | **Same.** Same command, same result, with evidence you can reproduce |
| ⚠️ | **Partial.** The main path works; something specific is missing, named below |
| ❌ | **Not possible.** Why (usually: upstream ships only certain platforms), and what to use instead |

**Every row carries a command you can run.** A row without evidence is not ✅.

---

## The table

<!-- parity-table-start -->

| Scenario | State | Evidence (run it yourself) |
|---|---|---|
| Build a debug/release APK with Gradle / AGP | ✅\* | `tests/gradle-build.sh` |
| Build native code with `ndk-build` | ✅ | `tests/hello-native/build.sh` |
| Build native code with CMake (NDK toolchain file) | ✅ | `tools/make-ndk-dist.sh` check 9 |
| AGP + `externalNativeBuild` (CMake) | ✅ | `tests/gradle-build.sh` (`hello-native` uses CMake) |
| React Native (Hermes bytecode) | ✅ | `tools/build-hermesc.sh --verify` |
| Install to a phone, read logcat | ✅ | `tests/hello-native/build.sh --install` |
| Run a local `adb` server | ✅ | `tools/build-adb.sh --verify` (step 6/7) |
| **Debug native code (lldb to a device)** | ✅ | `tools/verify-lldb-device.sh` |
| Static analysis (`clang-tidy` / `clangd`) | ✅ | `tools/link-system-tools.sh` |
| Vulkan shaders (`glslc` / `spirv-*`) | ✅ | same |
| Inspect an app's SQLite database | ✅ | `tools/build-sqlite3.sh --verify` |
| Sign and dex (`apksigner`, `d8`) | ✅ | `tests/hello-jvm/build.sh` (pure Java, unmodified from Google) |
| Analyse an APK (`apkanalyzer`) | ✅ | pure Java; verified against an APK we built |
| Convert heap dumps (`hprof-conv`) | ✅ | `tools/build-hprof-conv.sh --verify` (byte-compared to Google's output) |
| Install our packages via `sdkmanager` | ✅ | `tools/make-repo.sh --verify` |
| **Profiling with `simpleperf`** | ⚠️ | see below |
| **IDE: Android Studio** | ❌ | see below |
| Emulator | ❌ | see below |
| Layout Inspector | ❌ | see below |
| Android Auto desktop head unit | ❌ | see below |
| RenderScript | ❌ | deprecated upstream since Android 12; deliberately not done |

<!-- parity-table-end -->

\* **Gradle has one precondition.** AGP does **not** use the `aapt2` in your
SDK — it resolves `com.android.tools.build:aapt2:<ver>:linux` from Maven, which
is an x86_64 ELF, and dies with `AAPT2 …-linux Daemon #0: Daemon startup
failed`. Point it at ours:

```properties
# ~/.gradle/gradle.properties — applies to every project
android.aapt2FromMavenOverride=/path/to/sdk/build-tools/36.0.0/aapt2
```

`tools/install.sh` writes that line for you (`--no-gradle-props` to skip).

**And pin `ndkVersion` in every module with native code.** We ship NDK
27.1.12297006 (the LTS one, which React Native pins); AGP 9.3 defaults to
28.2.13676358 (so does Flutter). Measured: without the pin, AGP silently
downloads that 2.2 GB **x86_64-only** NDK, whose `clang` cannot run here.
Measured: with it, a plain `./gradlew assembleRelease` — no `-P` flags —
reaches `BUILD SUCCESSFUL`.

---

## ⚠️ simpleperf: records and reports, but the Python path is out

- **Present**: `simpleperf/bin/linux/aarch64/simpleperf`, the host half, which
  Google ships for x86_64 only. Measured locally: recorded 1,368 samples and
  `report` read them back (`Samples: 1368`).
- **Missing**: `libsimpleperf_report.so`, which simpleperf's Python scripts
  load via `ctypes` to generate reports. It would have to live inside a CPython
  process, and **one process cannot mix bionic and glibc**. Separate problem.
- **Unverified**: reading a `perf.data` recorded *on a device* (locally
  recorded files are verified). Needs hardware.
- **Workaround**: the command-line `record`/`report` is enough for most work;
  for the graphical reports, copy `perf.data` to an x86 box.

## ❌ Android Studio: Google has no Linux ARM64 build

Checked 2026-08-30 on developer.android.com/studio: the downloads are
`Windows (64-bit)`, `Mac (64-bit)`, `Mac (64-bit, ARM)`, `Linux (64-bit)` and
ChromeOS. **Mac gets ARM; Linux does not.** Same pattern as the emulator and
skiaparser.

We cannot fix this — Studio is an IDE product, not an SDK component. Instead:

- **IntelliJ IDEA Community ships `linuxARM64`** (verified against JetBrains'
  releases API, 2025.3). The Android plugin installs; the Gradle path is the
  one this project already verifies.
- Or any editor plus the command line: **every ✅ row above is a command-line
  path** and needs no IDE.

## ❌ Emulator

Google ships `emulator` for `linux/x64`, `macosx/aarch64` and `windows/x64` —
no `linux/aarch64`. Deliberately not done, for three reasons:

1. it was on the roadmap as a *verification vehicle*, and the real-device path
   now works (see the lldb and install rows above);
2. a cloud ARM VM usually has no `/dev/kvm`, so an ARM-on-ARM emulator falls
   back to full software emulation — unusable for a phone image;
3. it is a QEMU fork with a Qt UI and its own build system — a different class
   of work from "one source tree plus a CMake file".

If you need CI without a phone, the path is **Cuttlefish** (AOSP's own virtual
device, which does ship arm64 host packages) — but it needs KVM.

## ❌ Layout Inspector / Android Auto DHU

`skiaparser` and `extras;google;auto` are **closed source** and published for a
fixed set of platforms — including macOS ARM64, but not Linux ARM64. No source
was found to build from.

---

## Rechecking this table

```bash
tools/verify-claims.sh          # the premise: what Google does and does not ship
tests/gradle-build.sh           # the AGP path end to end
tests/hello-native/build.sh     # the manual pipeline (--install needs a phone)
tools/verify-lldb-device.sh     # device debugging (exit 2 = no device, not a failure)
tools/check-parity.sh           # this file and parity.json have not drifted apart
```

**Exit code convention**: `0` verified, `1` real failure, `2` **could not be
verified** (missing device, missing tunnel). Treating `2` as failure makes
"untested" look like "broken"; treating it as success is worse.

The machine-readable copy is [parity.json](parity.json); the fields match this
table one to one, and `tools/check-parity.sh` fails if they diverge.

Chinese original: [zh/PARITY.md](zh/PARITY.md).
