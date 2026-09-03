# Adding, replacing and removing an NDK in an existing SDK root

`tools/install.sh` lays down a complete SDK root. This is the other job: an SDK
root already exists, is in use, and you want to change **one** NDK inside it
without disturbing anything else.

The reason it needs writing down: `install.sh` **requires both packages**
(`--sdk-tgz` *and* `--ndk-tgz`), so pointing it at a live `$ANDROID_HOME` would
re-lay `build-tools/` and `platform-tools/` as well — the parts a running build
is actually reading. Every procedure below is therefore two stages: install into
a scratch root, verify it there, then move **one directory**.

Throughout, `$SDK` is the live SDK root (`/opt/android-sdk` on the build
machine) and `$V` is an NDK version like `27.1.12297006`.

## Before touching a live SDK root, always

```bash
sudo lsof +D "$SDK" 2>/dev/null | head        # who has files open in there
pgrep -af gradle | head                       # daemons may be idle or building
```

An idle Gradle daemon is fine. A daemon with `platforms/android-36/android.jar`
open is a build in flight — either wait, or stick strictly to the additive
procedure below, which never touches what such a build reads.

## Stage 1 — install to a scratch root and verify (all cases)

```bash
cd /path/to/android-sdk-linux-arm64
REL=https://github.com/zhuwanhong/android-sdk-linux-arm64/releases/download/v1.0.0
curl -fLO "$REL/android-ndk-$V-linux-aarch64-ours.tar.gz"
curl -fLO "$REL/android-sdk-linux-arm64-36.0.0-ours.tar.gz"   # install.sh insists on both

sha256sum android-ndk-$V-linux-aarch64-ours.tar.gz            # must match docs/RELEASE-NOTES.md

tools/install.sh --sdk-root /tmp/ndk-verify \
    --sdk-tgz android-sdk-linux-arm64-36.0.0-ours.tar.gz \
    --ndk-tgz android-ndk-$V-linux-aarch64-ours.tar.gz \
    --platform 36 --no-gradle-props --yes
```

Exit code 0 means it fetched Google's half, patched the host tag, and built an
APK with a native library. Then check the parts that matter, without trusting
the log:

```bash
N=/tmp/ndk-verify/ndk/$V/toolchains/llvm/prebuilt/linux-aarch64
$N/bin/clang --version | head -1          # the "based on rXXXXXX" must match this NDK
printf 'int main(void){return 0;}\n' > /tmp/t.c
$N/bin/clang --target=aarch64-linux-android24 -c /tmp/t.c -o /tmp/t.o && file -b /tmp/t.o
```

## Stage 2a — add an NDK, leaving everything else alone

```bash
SRC=/tmp/ndk-verify/ndk/$V
STAGE="$SDK/ndk/.staging-$V"
sudo rm -rf "$STAGE"
sudo cp -a "$SRC" "$STAGE"

# Copying takes minutes, and a build starting meanwhile must not see a
# half-populated NDK directory. So copy under a dot-name, then rename — a
# rename within one filesystem is atomic.
[ "$(find "$SRC" | wc -l)" = "$(sudo find "$STAGE" | wc -l)" ] || echo "counts differ, stop"
sudo mv "$STAGE" "$SDK/ndk/$V"
```

## Stage 2b — replace an NDK, keeping the old one

```bash
BK=/opt/android-sdk.ndk-backup          # deliberately OUTSIDE the SDK tree:
sudo mkdir -p "$BK"                     # a backup inside ndk/ looks like an NDK to AGP

sudo cp -a "$SRC" "$SDK/ndk/.staging-$V"
[ "$(find "$SRC" | wc -l)" = "$(sudo find "$SDK/ndk/.staging-$V" | wc -l)" ] || echo "stop"
sudo mv "$SDK/ndk/$V" "$BK/$V-$(date +%Y%m%d)"     # old out
sudo mv "$SDK/ndk/.staging-$V" "$SDK/ndk/$V"       # new in
```

Two renames back to back: the window where that version does not exist is
microseconds, instead of the minutes a copy would take.

## Stage 2c — remove an NDK

```bash
sudo mv "$SDK/ndk/$V" "$SDK/ndk/.removing-$V"   # out of the scan path first
sudo rm -rf "$SDK/ndk/.removing-$V"
```

Deleting in place leaves a half-deleted NDK visible to anything scanning `ndk/`
for as long as the delete takes.

## Which build is this NDK from?

`clang --version` **cannot tell you**: two builds of the same NDK version print
the same string. Use these instead.

```bash
grep 生成时间 "$SDK/ndk/$V/PROVENANCE.txt"
```

- Built by CI, current packaging: `（SOURCE_DATE_EPOCH=…）` — a pinned value.
- Built locally before 2026-09-01: a live wall-clock timestamp, no epoch.

```bash
P="$SDK/ndk/$V/toolchains/llvm/prebuilt/linux-aarch64/python3"
"$P/bin/python3" - "$P" <<'PY'
import glob, struct, sys, os
fs = glob.glob(os.path.join(sys.argv[1], "**", "*.pyc"), recursive=True)
bad = sum(1 for f in fs if not (struct.unpack("<I", open(f,"rb").read(8)[4:8])[0] & 1))
print(f"{len(fs)} .pyc, {bad} timestamp-based")
PY
```

Current packaging normalises these: **0 timestamp-based**. An older package has
every one of them timestamp-based. See `docs/zh/LESSONS.md` for why that
mattered.

## After any change

```bash
for v in "$SDK"/ndk/*/; do
  c="$v/toolchains/llvm/prebuilt/linux-aarch64/bin/clang"
  "$c" --target=aarch64-linux-android24 -c /tmp/t.c -o /tmp/t.o &&
    echo "$(basename "$v") ok: $("$c" --version | head -1 | grep -oE 'clang version [0-9.]+')"
done
"$SDK/build-tools/36.0.0/aapt2" version | head -1     # untouched, but confirm
```

## The one consequence to remember

AGP 9.3's default `ndkVersion` is **28.2.13676358**. With that NDK present, a
module that pins nothing silently uses it; with it absent, AGP tries to download
it and gets Google's x86_64 build, which cannot run here. Removing r28 from a
machine where some module relies on the default will break that module — pin
`ndkVersion` in every module with native code and the question never arises.
