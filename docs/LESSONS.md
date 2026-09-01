# Lessons

Specific mistakes made while building this, kept because the binaries are
reproducible and these are not. Every entry is something that actually
happened, with the symptom that gave it away.

The common shape of most of them: **the failure path and the success path
shared an exit code.** When you write a check, ask first — *when this command
fails, can I tell which kind of failure it was?*

Chinese original, with more detail: [zh/LESSONS.md](zh/LESSONS.md).

## Checks that cannot fail

| What was written | What happened |
|---|---|
| `[ -x "$aapt2" ]` treated as "it runs" | The stock SDK's `aapt2` is x86_64: file present, executable bit set, `exec` returns **126**, output empty — and the check read that as "the two implementations disagree". Fix: actually run it and look at the exit code (`runs()` in `tests/common.sh`). |
| `readelf -n "$so" \| grep -qi build \|\| echo "no build-id"` | When the file does not exist, `grep` also fails, so it printed "no build-id — consistent". Three outcomes (missing / present / absent) must be distinguished. |
| `strings -a "$bin" \| grep -q X` under `set -o pipefail` | `grep -q` exits on first match, `strings` gets SIGPIPE, `pipefail` marks the pipeline failed — **a hit is reported as a miss**. Grep the file directly, no pipe. Hit twice: once with `llvm-nm`, once with `cat /proc/net/tcp` while polling for a listener. |
| Architecture check for static libs, on a machine with no `ar` | The whole check was skipped and packaging still reported success. Now it says explicitly "no `ar(1)` here, **zero** static libraries were checked" — not checked is not the same as checked and fine. |
| `ok "$n host static libs, all correct"` with `$n` = 0 | "Nothing was found" printed identically to "everything checked out". Zero needs its own branch. |
| Adding a flag to make a check "cleaner" | `clang-tidy --checks=-*` was meant to disable checks and only exercise parsing. It actually prints `Error: no checks enabled.` and exits — **the file was never compiled**. The usage message says `Error` capitalised, the check grepped for clang's lowercase `error:`, and the step became a silent no-op that reported green. |
| `command -v docker` as the gate | Client installed, daemon not running: every image quietly printed "(skipped)" and it looked like it had run. Check `docker info`. Same shape as the `aapt2` one: **installed ≠ usable**. |
| Exit code `< 126` as "it started" | True for *static* binaries, false for dynamically linked ones: with a too-old glibc, `ld.so` prints ``version `GLIBC_2.38' not found`` and exits **1**. So a clang that could not start on 22.04 was reported ok. Look for a positive trace that it ran (`clang version` in the output), do not expect failure to be well-behaved. |
| Treating "build succeeded" as "artifact is correct" | AGP calls `aapt2 optimize … --resource-path-shortening-map=<path>`; our `aapt2` rejected the `=` form and exited 1 — **AGP swallowed that failure**, reported `BUILD SUCCESSFUL`, and the APK had no `AndroidManifest.xml` and no `resources.arsc`. `tests/gradle-build.sh` now unpacks the APK and checks its contents instead of trusting the exit status. |
| Hiding the exit code, reading "it did not run" as "results match" | While byte-comparing our `hermesc` against Google's, the control step redirected everything to `/dev/null` and then ran `cmp`. qemu had just been removed, so Google's x86_64 build **never ran** (rc=126, no output file), `cmp` compared a stale file, and the conclusion was "this check is decorative" — when in fact it was fine. **The precondition of a check (did the tool even start?) needs checking too.** |
| `case "$(file -b "$f")" in *ELF*)` as the gate, with `file(1)` not installed | The substitution is empty, every file hits `continue`, and **both** of the packager's acceptance steps ("no x86 binaries in host positions", "the host binaries actually run") pass without inspecting anything. Reproduced: put a genuine x86-64 binary in the package and run the same loop inside `ubuntu:22.04` (which ships no `file`) — it printed "all ELFs in host positions are ARM aarch64". Two fixes, because a precheck alone is not enough: `command -v file || die`, **and** treat zero-coverage as a failure (`n_elf`/`n_ran` of 0 is not a pass — same shape as the `$n` = 0 row above, which `make-ndk-dist.sh` already handled and `make-dist.sh` did not). `ci-checks.sh` now fails any script that judges architecture with `file` without checking for it first. |
| A red check that is not actually red | Testing "the bundled python3 is self-contained": hide it, put a failing `python3` on `PATH`, expect the build to break. **It did not.** Our own patch comment explains why: the fake exists and is executable, so `HOST_PYTHON` gets set, `$(error)` never fires, and `$(shell)` just returns empty strings. Fix was to change the criterion, not the force: put a probe on `PATH` that records being called and then `exec`s the real one, and assert on **call counts** (0 when the bundled one is present, >0 when hidden). |

## The criterion included itself

| | |
|---|---|
| `pgrep -f 'gradlew\|bash ./build.sh'` | `pgrep -f` matches full command lines — **including its own**, which contains the pattern. It reported "a build is running" every time. Assemble the pattern at runtime (`p="grad""lew"`) or filter out the matcher itself. Fooled twice; the second time the script printed "stopping" and then continued anyway, because `&&`/`\|\|` do not abort. |
| `D=$(command -v sqlite3)` as "the distro's sqlite3" | It resolved to `/opt/android-sdk/platform-tools/sqlite3` — **our own**, because it is on `PATH`. The "distro" column of the comparison was printing our old build's behaviour. Comparisons need absolute paths on both sides. |
| A readiness probe that consumed the thing | `lldb-server gdbserver` accepts **exactly one** client. The probe connected to check the port was reachable, disconnected, and the server exited; the real `lldb` then got `Connection shut down by remote side while waiting for reply to initial handshake packet`. Moved the probe before the server starts. For anything single-use (one-shot servers, tokens, a pipe you can only read once) ask: **does looking at it use it up?** |

## Cross-architecture traps

| | |
|---|---|
| `qemu-user-static` on the verification machine | With binfmt registered, x86_64 binaries "run" on ARM64 — and several checks here are precisely "run it and look at the exit code". Measured both ways on the same binary: a **statically linked** x86_64 tool exits **0** with qemu installed (false green) and **126** without. Dynamically linked ones fail either way. **The dangerous case is static binaries — and everything this project builds is static.** Do not install it on a verification machine. |
| bionic's fdsan turning an invisible upstream bug fatal | `adb start-server` aborted 6 times out of 6 with `fdsan: failed to exchange ownership of file descriptor`. Not our bug: fdsan is **bionic-only**, Google's Linux `adb` is glibc, so upstream never sees it. An fd owned by a `unique_fd` is closed raw somewhere, the tag survives, `inotify_init1` reuses the number, and `fdevent_create` aborts. Taking Android-target binaries to Linux **activates checks upstream never runs in that combination**. Separate "we built it wrong" from "we exposed a latent upstream bug" before writing a patch. |
| A header in the sysroot with the same name as the one you are building | Building ICU produced `use of undeclared identifier 'Appendable'` everywhere. `uconfig.h` includes `uconfig_local.h` when `__ANDROID__` is defined, and cross-compiling picks up **the NDK sysroot's copy**, which sets `U_SHOW_CPLUSPLUS_API 0` — that file is for apps *using* the platform's ICU, not for *building* ICU. Shadow it with an empty header earlier on the include path. **"Building this library" and "using this library" need opposite settings, and they share a filename.** |
| Guessing what a macro means from its name | Next failure was a missing `androidicuinit/android_icu_init.h`, triggered by the bare `ANDROID` macro. Its definition site says: `// if using the AOSP build system, e.g. Soong`. It means *Soong is driving this build*, not *the target is Android* (that is `__ANDROID__`) — and the NDK toolchain file always adds `-DANDROID`. **A macro's meaning lives at its definition, not in its name.** |
| A probe that works on the reference but not on your own artifact | Grepping the binary for the `icudt<ver>_dat` symbol name to prove stubdata was linked — **verified against Google's binary, where it works**. Ours is statically linked and stripped, so the name is not there at all. Replaced with behavioural probes. **"Validated against the reference" does not mean "valid for our artifact".** |

## Verification that never exercised the thing

| | |
|---|---|
| Six green checks that never started the server | `build-adb.sh` verified the version string, unknown-flag handling, the subcommand list, strings embedded in the binary, and the error message when no server is reachable — **all green, all local parsing**. Meanwhile that `adb` could not start a server at all, which is the entire job of `adb`. Added a step that starts a real server on a non-default port; the pre-fix binary passes the first five steps and fails that one. **Verify the reason the tool exists, not the parts that are easy to verify.** |
| Deleting something without checking who referenced it | The first NDK packaging dropped `prebuilt/` entirely — and the top-level `ndk-stack` / `ndk-gdb` / `ndk-which` / `ndk-lldb` all hard-code a forward into `prebuilt/linux-x86_64/bin/`. Four entry points became `127 not found`, and none of six checks noticed, because none of them asked "does this reference still resolve?". After removing or replacing anything, sweep for references — counting only **executable** text files; a path mentioned in documentation is documentation, not a reference. |
| Porting a criterion to a new tree without recalibrating | In the SDK, target artifacts live under ABI directories (`arm64-v8a`); in the NDK they live under **triple** directories (`x86_64-linux-android`). Reusing the SDK's `is_abi_path()` for the NDK would classify a thousand sysroot libraries as "foreign-architecture files in host positions". Calibrate a borrowed criterion on a tree whose answer you already know — for the NDK that was Google's own x86_64 package: 133 host ELFs, all x86-64, zero missed. |

## Reasoning traps

| | |
|---|---|
| "It does not support X" when the argument was wrong | "sdkmanager ignores `SDK_TEST_BASE_URL` — local server, zero requests" stood for a long time. It does support it; **the base URL must end with `/`**, because the pattern is `%srepository2-%d.xml`. Without the slash the URL is invalid, sdkmanager logs `Ignoring invalid SDK_TEST_BASE_URL` and makes no request — indistinguishable from "unsupported". **Zero requests explained both hypotheses and only one was considered.** |
| Concluding from the local machine about the target architecture | `apt-cache show glslc` reported `Architecture: amd64` — that is *this* machine's index and says nothing about the arm64 archive. Checking the distro's package database showed arm64 builds exist. Deciding what to build for ARM64 from x86_64 metadata is exactly the failure this project exists to fix. |
| A rule written down is not a rule applied | After `cmake` was wrongly filed under "only we can build this" (`apt install cmake` gets you one) and the criterion was documented, `lldb` was filed under the same heading the very next time — while `apt install lldb` works and the device-side `lldb-server` was already in the package. Ask "did I actually check this?" before each conclusion, not once per document. |
| Editing a script while it is running | bash reads scripts **incrementally**. Editing a `tools/build-*.sh` two hours into a build makes it read the new bytes at the old offset: syntax errors appear at the end, or a block runs twice. Happened twice; the artifacts were fine but the log and exit code — the things you judge by — were not. |

## Rules that came out of the above

1. **"It compiled on x86" proves nothing.** Artifacts must run on real ARM64 hardware.
2. **Every artifact needs a check that fails when it breaks** — not a file-existence test.
3. **New check? Prove it goes red.** Remove the fix, watch it fail, put it back. (And check the mutation is real: `[ 1 = 1 ;` is not a syntax error, so `bash -n` stays green.)
4. **Three outcomes, three exit codes**: `0` verified, `1` failed, `2` could not be verified. Collapsing the third into either of the others is how "untested" starts looking like "tested".
5. **Scope is "what Google ships for x86_64", not "enough to build an APK".** Asking "is this needed to package an APK?" once turned `adb`, `sqlite3` and `mke2fs` into "not needed".
6. **A checksum only the author can regenerate is not verification.** Packaging
   used to embed a build timestamp and inherit readdir order, mtimes and uid/gid,
   so re-running the packager produced a different sha256 from the one already
   published — the binaries were identical, but nobody outside could establish
   that without unpacking and diffing. Packaging now goes through `repro_tar`
   (`SOURCE_DATE_EPOCH`, `--sort=name`, fixed owner) and
   `tools/check-reproducible.sh` packages twice and compares. Note what the
   claim covers: the *packaging* is reproducible, the compilers are not claimed
   to be.
7. **Normalising `tar` fixes only half of reproducibility; the other half is
   inside the files.** The SDK archive went reproducible with `--sort=name`,
   `--mtime` and a fixed owner — the NDK archive did not, and the diff was
   entirely `.pyc` files from the bundled Python: byte 9 differs because the
   default invalidation mode records the source's mtime, and byte 222 differs
   because the compiled path is embedded. Fixed by recompiling with
   `--invalidation-mode unchecked-hash -d <fixed path>`. Those `.pyc` files were
   not copied in — **our own verification steps created them by running that
   interpreter**, so verifying changed the artifact being verified. A related
   one the same day: a provenance line used `date -u '+%H:%M'`, so three
   consecutive runs matched and it looked reproducible — a sampling interval
   shorter than the period of change measures nothing.
8. **"Google ships it" does not mean "we must build it".** Ask whether it is Google-only or a standard open-source tool with an ARM64 build in your distro — that question shrank the "only we can build this" column to one entry.
