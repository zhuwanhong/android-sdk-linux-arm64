#!/usr/bin/env python3
"""把 docs/RELEASE-NOTES.md 里的产物表换成**这次真打出来的**数字。

为什么需要：发布页上的表如果沿用上一次的值，就是错的 —— CI 编出来的二进制跟
开发机编的不是同一批（可复现的是**打包**，不是编译），校验和必然不同。让机器
按实际产物填，就不会出现「文档说 A、附件是 B」。

用法：
    tools/render-release-notes.py <tag> <commit> <输出文件> <包1> [包2 ...]

它同时改两处：
  - "Built from tag `x` (`y`)." 那一行；
  - 产物表的表体（表头 |---|---:|---| 之后连续的 | 开头的行）。
两处都必须真的匹配上，否则**退出码 1** —— 悄悄不改会让发布页挂着旧数字。
"""
import hashlib
import os
import pathlib
import re
import sys

SRC = pathlib.Path("docs/RELEASE-NOTES.md")


def main(argv):
    if len(argv) < 5:
        sys.exit(__doc__)
    tag, commit, out = argv[1], argv[2], argv[3]
    archives = sorted(argv[4:], key=os.path.basename)

    rows = []
    for f in archives:
        data = pathlib.Path(f).read_bytes()
        rows.append("| `%s` | %s | `%s` |" % (
            os.path.basename(f), f"{len(data):,}", hashlib.sha256(data).hexdigest()))

    doc = SRC.read_text(encoding="utf-8")

    doc, n_line = re.subn(
        r"Built from tag `[^`]*` \(`[^`]*`\)[^\n]*",
        f"Built from tag `{tag}` (`{commit}`), by .github/workflows/release-build.yml.",
        doc, count=1)
    if n_line != 1:
        sys.exit(f"{SRC}: 找不到 'Built from tag `x` (`y`)' 那一行，没法改")

    doc, n_tbl = re.subn(
        r"(\|---\|---:\|---\|\n)(?:\|.*\n)+",
        lambda m: m.group(1) + "\n".join(rows) + "\n", doc, count=1)
    if n_tbl != 1:
        sys.exit(f"{SRC}: 找不到产物表（表头应当是 |---|---:|---|），没法改")

    pathlib.Path(out).write_text(doc, encoding="utf-8")
    print("\n".join(rows))


if __name__ == "__main__":
    main(sys.argv)
