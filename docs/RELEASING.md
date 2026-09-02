# Releasing

Two different things live here: the **one-time** work of making this repository
public, and the **repeatable** procedure for cutting a release. The repeatable
part is what matters — every release must be able to say "these are the exact
bytes our recipes produce", and that claim is only as good as the steps below.

The rule the whole procedure turns on:

> `SOURCE_DATE_EPOCH` defaults to **the commit date of `HEAD`**. Packages embed
> that timestamp. So the artifacts belong to one specific commit, and anything
> that changes `HEAD` between building and publishing invalidates the published
> checksums.

That single fact explains steps 3, 5 and 6.

---

## 0. First publication only

On github.com, in this repository:

1. **Settings → General → Danger Zone → Change repository visibility → Public.**
2. **About** (top right of the file list) → set the description and topics.
   Suggested description: *Android SDK and NDK build tools for ARM64 Linux,
   compiled from AOSP and LLVM source. Google publishes these for linux-x86_64
   only.*

   Topics — **enter them one at a time, pressing Enter after each** so that each
   becomes its own chip. Pasting the whole list in one go makes GitHub treat it
   as a single topic and reject it ("topics must start with a lowercase letter
   or number, consist of 50 characters or less"), because a topic cannot contain
   spaces:

   `android` `android-sdk` `android-ndk` `arm64` `aarch64` `linux` `aosp`
   `llvm` `cross-compilation` `reproducible-builds`

   Then **Save changes** — and check the result from outside, not from the
   settings dialog:

   ```bash
   curl -s https://api.github.com/repos/<owner>/<repo>/topics
   ```
3. **Settings → Actions → General → Allow all actions and reusable workflows.**
   Nothing here needs a secret; the workflows only fetch public downloads.
4. **Settings → Code security → Private vulnerability reporting → Enable.**
   `SECURITY.md` tells people to use it, so it has to be on.

## 1. Preconditions

```bash
git switch main && git status --short          # clean
tools/ci-checks.sh                             # all 12 green (last two need network)
```

You also need, on the build machine:

- the compiled binaries in `$WORK/out` (packaging consumes them; it does not
  build them);
- a patched NDK tree for `make-ndk-dist.sh` — the one produced by
  `tools/patch-ndk.sh` with our toolchain grafted in.

## 2. Tag

```bash
git tag -a v1.2.3 -m "v1.2.3 — <one line>"
```

Do not push it yet. If step 5 has to amend the commit, the tag moves with it.

## 3. Build the artifacts from the tag

**Do not commit anything while this runs.** A commit changes `HEAD`, which
changes `SOURCE_DATE_EPOCH`, which changes every package built afterwards — you
would end up with two halves of a release that disagree.

```bash
export WORK=/path/to/work
tools/check-reproducible.sh                        # SDK
tools/check-reproducible.sh --ndk /path/to/patched/ndk
tools/build-hermesc.sh --build
```

`check-reproducible.sh` packages **twice** and compares: once with
`SOURCE_DATE_EPOCH` exported, once without it — the second is the path a third
party takes when they check out the tag and run the packager. Both must produce
identical bytes. It leaves the archive in `$WORK`, so this step produces the
release artifacts and their proof at the same time.

## 4. Smoke-install exactly what you are about to publish

Not the working tree, not yesterday's tarball — the files from step 3.

```bash
tools/install.sh --sdk-root /tmp/rc \
    --sdk-tgz  "$WORK"/android-sdk-linux-arm64-*-ours.tar.gz \
    --ndk-tgz  "$WORK"/android-ndk-*-linux-aarch64-ours.tar.gz \
    --platform 36 --no-gradle-props --yes
```

Exit code 0 means it ran `aapt2`, started an `adb` server, ran the NDK's
`clang`, and built an APK with a native library in it. Anything less is not a
release.

## 5. Record the checksums

```bash
sha256sum "$WORK"/*.tar.gz
$EDITOR docs/RELEASE-NOTES.md      # table: file, bytes, sha256; and the tag/commit line
```

Then commit. **If the history is a single commit** (this repository keeps it
that way), amend it and keep the commit date, or the artifacts stop matching
the tag:

```bash
D=$(git log -1 --format=%cI)
git add -A
GIT_COMMITTER_DATE="$D" git commit --amend --no-edit --date="$D"
git tag -f -a v1.2.3 -m "…"        # the tag must follow the rewritten commit
git push --force-with-lease && git push --force origin v1.2.3
```

Verify the amend did not disturb anything — the packages must still reproduce:

```bash
tools/check-reproducible.sh        # same checksum as the table you just wrote
```

## 6. Create the release on GitHub

**Releases → Draft a new release**, choose the existing tag `v1.2.3`, title
`v1.2.3`, body = the contents of `docs/RELEASE-NOTES.md`, attach the three
archives from `$WORK`, publish.

## 7. Verify from the published URLs

The point of a checksum is that it survives the round trip:

```bash
curl -fL -o /tmp/dl.tgz https://github.com/<owner>/<repo>/releases/download/v1.2.3/<file>
sha256sum /tmp/dl.tgz              # must equal the table
```

Then run step 4 again against the downloaded files. A release nobody has
installed from its own download URL has not been tested.
