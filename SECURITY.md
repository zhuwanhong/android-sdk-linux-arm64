# Security Policy

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository
(*Security* → *Report a vulnerability*). Please do not open a public issue for
anything exploitable.

Expect a first reply within a week. This is a spare-time project; there is no
paid on-call.

## What is in scope

This project distributes **binaries it compiled from third-party source**, so
the interesting questions are mostly about the supply chain:

- a released artifact that does not match what the recipes in this repository
  produce;
- a build script that fetches something over an unauthenticated channel, or
  from somewhere other than the upstream it claims;
- an installer step that writes outside the SDK root it was given, or that
  escalates privileges;
- a patch in `patches/` that changes upstream behaviour in a way its README
  does not describe.

## What is not in scope

- Vulnerabilities in AOSP, LLVM, Hermes or any other upstream project. Report
  those to the project concerned; if a fix requires a change here as well, an
  issue pointing at the upstream report is welcome.
- The `patches/adb/0001` mitigation, which disables bionic's fdsan for the
  host `adb`. That is documented, deliberate, and makes our build behave the
  way Google's glibc build already does. The underlying fd-ownership bug is
  upstream's; see `patches/UPSTREAM.md`.
- Anything requiring an attacker who already controls the machine that runs
  the build.

## Verifying a release yourself

Every release artifact can be rebuilt from source with the recipes here. Two
different claims are involved, and it matters which one you are checking:

- **Packaging is byte-for-byte reproducible.** Given the same compiled
  binaries, `tools/make-dist.sh` / `make-ndk-dist.sh` produce an archive with
  the checksum published in the release notes. `tools/check-reproducible.sh`
  packages twice — once with `SOURCE_DATE_EPOCH` set, once without, which is
  the path a third party takes — and compares. An archive that does not match
  its published checksum is worth reporting.
- **Compilation is not claimed to be reproducible.** Building LLVM, aapt2 and
  the rest from source may not yield bit-identical binaries (compiler
  nondeterminism, embedded paths). If the binaries you build differ from the
  released ones, compare behaviour and symbols — a difference there is worth
  reporting; a difference in bytes alone is expected.
