## What this changes, and why

<!-- The diff says what. Say why. -->

## Evidence

<!-- Paste the output of whatever proves this works. On ARM64 hardware —
     "it compiled on x86" proves nothing here. -->

```
```

## Checklist

- [ ] Ran `tools/ci-checks.sh` (green)
- [ ] If this adds or changes a tool: there is a check that **fails** when that
      tool breaks, and I proved it goes red (removed the fix, watched it fail,
      put it back)
- [ ] If this adds or removes a capability: `docs/PARITY.md`,
      `docs/zh/PARITY.md` and `docs/parity.json` updated together
      (`tools/check-parity.sh` passes)
- [ ] If I learned something the hard way: added to `docs/LESSONS.md`
- [ ] Numbers in the commit message and comments are measured, not estimated
