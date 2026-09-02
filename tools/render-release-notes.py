#!/usr/bin/env python3
"""把 docs/RELEASE-NOTES.md 里的产物表换成**这次真打出来的**数字。

为什么需要：发布页上的表如果沿用上一次的值，就是错的 —— CI 编出来的二进制跟
开发机编的不是同一批（可复现的是**打包**，不是编译），校验和必然不同。让机器
按实际产物填，就不会出现「文档说 A、附件是 B」。

**按文件名合并，不是整表替换。** 一个 Release 上可以并列多个 NDK 版本
（r27 是 React Native 钉的，r28 是 AGP 9.3 默认、Flutter 钉的），而只编 NDK 的
那种运行不会重新产出 SDK 包和 hermesc —— 整表替换会把它们从表里抹掉，
而附件还挂在那儿，于是表和附件对不上。

还会写一份 `<输出文件>.assets`：合并后表里所有文件名，一行一个。publish 用它
决定「这个 Release 应该有哪些附件」—— 多出来的（比如内部中转物 toolchain.tar.gz）
删掉，别的版本的包留着。

用法：
    tools/render-release-notes.py <tag> <commit> <输出文件> <包1> [包2 ...]

两处替换（那行 "Built from tag" 和表体）必须都真的匹配上，否则**退出码 1** ——
悄悄不改会让发布页挂着旧数字。
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
    archives = argv[4:]

    doc = SRC.read_text(encoding="utf-8")

    # 先把现有的表读成 {文件名: (字节数, sha256)}，再用这次的产物覆盖/插入。
    rows = {}
    for m in re.finditer(r"^\| `([^`]+)` \| ([\d,]+) \| `([0-9a-f]{64})` \|$", doc, re.M):
        rows[m.group(1)] = (m.group(2), m.group(3))
    before = len(rows)

    for f in archives:
        data = pathlib.Path(f).read_bytes()
        rows[os.path.basename(f)] = (f"{len(data):,}", hashlib.sha256(data).hexdigest())

    table = "\n".join("| `%s` | %s | `%s` |" % (n, rows[n][0], rows[n][1])
                      for n in sorted(rows))

    doc, n_line = re.subn(
        r"Built from tag `[^`]*` \(`[^`]*`\)[^\n]*",
        f"Built from tag `{tag}` (`{commit}`), by .github/workflows/release-build.yml.",
        doc, count=1)
    if n_line != 1:
        sys.exit(f"{SRC}: 找不到 'Built from tag `x` (`y`)' 那一行，没法改")

    doc, n_tbl = re.subn(
        r"(\|---\|---:\|---\|\n)(?:\|.*\n)+",
        lambda m: m.group(1) + table + "\n", doc, count=1)
    if n_tbl != 1:
        sys.exit(f"{SRC}: 找不到产物表（表头应当是 |---|---:|---|），没法改")

    pathlib.Path(out).write_text(doc, encoding="utf-8")
    # publish 拿它决定该留哪些附件
    pathlib.Path(out + ".assets").write_text("\n".join(sorted(rows)) + "\n", encoding="utf-8")

    print(table)
    print(f"\n表里 {before} 行 -> {len(rows)} 行；这次更新了 {len(archives)} 个",
          file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
