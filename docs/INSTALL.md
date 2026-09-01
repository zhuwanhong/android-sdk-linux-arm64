# Install

You need an **aarch64 Linux** machine with `tar`, `curl`, `unzip` and a JDK
(17 or 21). Ubuntu 22.04 / Debian 12 or newer — the binaries need glibc 2.34+,
measured per binary, not assumed.

## One command

```bash
git clone https://github.com/zhuwanhong/android-sdk-linux-arm64
cd android-sdk-linux-arm64

tools/install.sh --sdk-root ~/Android/Sdk \
    --sdk-tgz  /path/to/android-sdk-linux-arm64-36.0.0-ours.tar.gz \
    --ndk-tgz  /path/to/android-ndk-27.1.12297006-linux-aarch64-ours.tar.gz \
    --platform 36
```

`--build-tools 36.1.0` installs our binaries under a different build-tools
revision. Google publishes 82 of them and projects pin one; our binaries come
from AOSP source and are not tied to the revision label, so the installer just
fetches Google's files for that revision and layers ours on top. Measured
2026-08-31 with `36.1.0`: the full AGP path builds both sample APKs.

> **AGP also has a default `buildToolsVersion`** (36.0.0 for AGP 9.3.2). A
> module that does not pin one asks for that default, and if it is not
> installed you get `Failed to install … some licences have not been accepted:
> build-tools;36.0.0` — **which is misleading: the real cause is that the
> revision is not installed.** So if you use `--build-tools`, pin the same
> revision in every module.

Options: `--platform-from /path/to/another/sdk` (offline — copy `platforms/`
from an SDK you already have), `--no-gradle-props` (do not touch
`~/.gradle/gradle.properties`), `--no-verify`, `--yes`.

Exit codes: `0` installed and self-verified, `1` error, `2` a prerequisite is
missing (and it tells you which).

## What it does, and why each step is not optional

**1. Unpacks our binaries.** These are the only files we redistribute:
everything in them was compiled from AOSP or LLVM source by this project.

**2. Fetches the rest from Google.** `d8.jar`, `apksigner`, the wrapper
scripts, the NDK's `sysroot` and `build/` — we do not redistribute those, so
the installer downloads them from `dl.google.com` (URLs resolved from Google's
own `repository2-3.xml`, never hard-coded). **You accept Google's terms at that
step, not ours.** Our binaries are then layered on top, and any x86_64 host
binary that came along and that we do not replace is deleted — leaving a broken
binary in place is worse than not having it. (Measured: 8 files, all
RenderScript-related, which upstream deprecated in Android 12.)

**3. Links in the distro's tools.** `cmake`, `ninja`, `lldb`, `clangd`,
`glslc`, `spirv-*` all have ARM64 builds in your distribution, so this project
does not rebuild them. Skip this step and **AGP will silently download an
x86_64 cmake into your SDK.**

**4. Adds `platforms/android-XX`.** `android.jar` is pure Java and
architecture-independent, so we do not redistribute Google's copy. The
installer fetches it (`--platform 36`) or copies it from an SDK you already
have (`--platform-from`). Note that the zip's directory is named after the
codename, not the API level — the installer renames it using the
`source.properties` inside.

**5. Points Gradle at our `aapt2`.** AGP does not use the `aapt2` in your SDK;
it resolves an x86_64 one from Maven. Without the override you get:

```
AAPT2 aapt2-…-linux Daemon #0: Daemon startup failed
```

so the installer appends to `~/.gradle/gradle.properties`:

```properties
android.aapt2FromMavenOverride=<sdk>/build-tools/36.0.0/aapt2
```

Global on purpose: your own projects then need no changes.

**Then it proves the install works.** Runs `aapt2`, starts a real `adb`
server on a non-default port, runs the NDK's `clang`, and builds an APK
containing a native library. Only then does it print success.

> ### Pin `ndkVersion`, or AGP will download an x86_64 NDK
>
> We ship **NDK 27.1.12297006** (the LTS release, and the one React Native
> pins). AGP has its own default — **28.2.13676358** for AGP 9.3, which is also
> what Flutter pins — and a module that does not pin `ndkVersion` gets that one.
>
> Measured 2026-08-31: with the pin removed, AGP 9.3.2 **silently downloaded and
> installed NDK 28.2.13676358** (2.2 GB) into the SDK. It contains only
> `linux-x86_64` binaries; its `clang` cannot exec on ARM64 at all.
>
> ```gradle
> android {
>     ndkVersion '27.1.12297006'   // in every module that has native code
> }
> ```
>
> Building a different NDK version yourself: `tools/build-ndk-version.sh`
> resolves the Clang revision that NDK ships and pins the LLVM build to it.

## Use it

```bash
export ANDROID_HOME=~/Android/Sdk
export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

What works and what does not: [PARITY.md](PARITY.md).

## Alternative: an internal `sdkmanager` mirror

`tools/make-repo.sh` turns a complete SDK tree into an **sdkmanager-compatible
repository**, so `sdkmanager` and Android Studio's *SDK Update Sites* install
from it the way they install from Google — **no changes to your projects**.
This is how you roll the ARM64 tools out to a fleet of machines.

> **This is for internal distribution, not for public release**, for two
> measured reasons:
>
> 1. **The packages necessarily contain Google's files.** An sdkmanager package
>    is a self-contained unit with its own `source.properties`, so the zip has
>    to include `d8.jar`, `apksigner`, the wrapper scripts and so on. Building
>    it from the `--ours-only` tree does not work either — that tree has no
>    `source.properties`, and the script stops with "cannot read Pkg.Revision".
> 2. **It only installs into an SDK root that does not already have the
>    package.** Measured 2026-08-31: pointed at a root with Google's
>    `build-tools;36.0.0` already installed, `sdkmanager` fetched our
>    `repository2-3.xml`, decided the same revision was already present, and
>    **did nothing** — our `aapt2` never landed. It is not an "overwrite the
>    official one" mechanism.
>
> So: build it inside an organisation that already has the official SDK, serve
> it internally. For public distribution use the tarballs plus
> `tools/install.sh`, which redistributes only what this project compiled.

```bash
# serve the repo directory over any static HTTP server
(cd /path/to/repo && python3 -m http.server 8099)

# then point at it. The trailing slash is not optional
export SDK_TEST_BASE_URL=http://127.0.0.1:8099/
sdkmanager --sdk_root=$ANDROID_HOME "build-tools;36.0.0" "platform-tools"
```

> **Without the trailing slash it fails silently.** `sdkmanager` builds the URL
> as `%srepository2-%d.xml`; without the slash that becomes
> `http://127.0.0.1:8099repository2-3.xml`, which it rejects and then makes
> **zero requests**. Measured: no slash → `Warning: Ignoring invalid
> SDK_TEST_BASE_URL`, 0 requests; with slash → our packages listed, 6 requests.

> **Do not install `build-tools` or `platform-tools` from Google's own
> repository.** That replaces our binaries with x86_64 ones.

The repository is produced by `tools/make-repo.sh`, which verifies two things
for real: the generated `repository2-3.xml` validates against **Google's own
XSD** (after first calibrating the validator on Google's own XML — if that
fails, the validator is wrong, not our file), and `--verify` actually serves
it over HTTP, has `sdkmanager` install from it, and then runs the installed
binaries.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `cannot execute binary file: Exec format error` | An x86_64 binary. Run step 2's sweep, or check you did not install build-tools from Google's repo afterwards. |
| `AAPT2 …-linux Daemon #0: Daemon startup failed` | Missing `android.aapt2FromMavenOverride` (step 5). |
| `Failed to find Build Tools revision …` | Your project pins a version you have not installed. |
| `version 'GLIBC_2.xx' not found` | Distro older than the binary's floor (SDK 2.34, NDK 2.35). Ubuntu 22.04 and Debian 12 are fine. |
| `adb` cannot see a device over an SSH tunnel | Bind IPv4 explicitly on both ends: `ssh -R 127.0.0.1:5037:127.0.0.1:5037 …`, and kill the local `adb` server first, or the forward cannot bind. |

Chinese original, with more background: [zh/INSTALL.md](zh/INSTALL.md).
