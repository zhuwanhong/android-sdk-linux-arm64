---
name: Something does not work
about: A tool crashes, a build fails, or a check disagrees with reality
labels: bug
---

## What happened

<!-- Paste the actual output, not a summary of it. Exit codes matter here:
     0 = verified, 1 = real failure, 2 = could not be verified. -->

```
$ your command here
```

## What you expected

## Environment

- Distribution and version:
- `uname -m`:
- `ldd --version | head -1`:
- How you installed (`tools/install.sh`, `sdkmanager`, manual):
- Package file names, or `git rev-parse HEAD` if you built from source:

## Does the repository's own check see it?

<!-- If there is a check for this area, run it and paste the output. If there
     isn't one, say so — that itself is useful, because a capability without a
     check that fails when it breaks is a gap in this project. -->

```
$ tools/ci-checks.sh
```
