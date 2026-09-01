#!/usr/bin/env bash
# 查一件事：**每个 cmake/<工具>.cmake 引用的源码树，是不是都有人负责取。**
#
# 为什么要有这个：源码树有三个来源 —— 上游 clone 时自带的 18 个子模块、
# 脚本自己 common_fetch_tree 取的、以及**开发的人手动 clone 过一次的**。
# 第三种在自己机器上永远能跑，换台干净的机器就红。真发生过：
# tools/build-fastboot.sh 引用 lz4，但没有任何脚本取它 —— 我这边有，
# 是因为探路时手动 clone 过；到别人机器上第一步就死。
#
# 这个脚本只读文件、不联网、不编译，随时可以跑：
#     tools/check-fetch-coverage.sh
# 退出码 0 = 每棵树都有出处；1 = 有树没人取（会指名道姓）。

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(readlink -f "$0")")")"

python3 - <<'PY'
import glob, io, os, re, sys

# 上游 ReVanced/aapt2 clone 时自带的 18 个子模块（.gitmodules 里那批）
BASE = set("""expat fmtlib boringssl incremental_delivery libbase libpng pcre protobuf
              logging selinux core base libziparchive soong unwinding jsoncpp
              googletest native""".split())

scripts = {}
for sh in sorted(glob.glob("tools/build-*.sh")):
    s = io.open(sh, encoding="utf8").read()
    tool = re.search(r'^TOOL=(\S+)', s, re.M)
    if not tool:                      # build-common.sh / build-aapt2.sh 不是这个格式
        continue
    cmake_files = re.search(r'^CMAKE_FILES=\((.*?)\)', s, re.M)
    scripts[sh] = {
        "tool": tool.group(1),
        # 这个脚本会装进上游树的 cmake 文件（可能不止自己那份）
        "cmake": (cmake_files.group(1).split() if cmake_files else []),
        # ^\s* 是必须的：注释里也会出现 common_fetch_tree 这几个字，
        # 不锚到行首就会把注释里的词当成取过的树（实测踩过）
        "fetch": set(re.findall(r'^\s*common_fetch_tree\s+(\S+)', s, re.M)),
    }

bad = 0
for sh, info in scripts.items():
    need = set()
    for c in info["cmake"]:
        p = f"cmake/{c}.cmake"
        if not os.path.exists(p):
            print(f"✗ {sh}: CMAKE_FILES 里的 {p} 不存在"); bad = 1; continue
        need |= set(re.findall(r'\$\{SRC\}/([a-zA-Z0-9_-]+)/', io.open(p, encoding="utf8").read()))
    missing = need - BASE - info["fetch"]
    if missing:
        bad = 1
        print(f"✗ {os.path.basename(sh)} 用到这些树，但没人取："
              f" {' '.join(sorted(missing))}")
        print(f"    它装的 cmake：{' '.join(info['cmake'])}")
        print(f"    它取的树：  {' '.join(sorted(info['fetch'])) or '（无）'}")
        print(f"    修法：在它的 --fetch 段里加 common_fetch_tree")
    else:
        print(f"✓ {os.path.basename(sh):26} 用到 {len(need)} 棵树，来源都清楚")
print(f"\n查了 {len(scripts)} 个脚本"
      f"（tools/build-*.sh 里带 TOOL= 的；build-common.sh 不算）。"
      f"{'全部有出处。' if not bad else '**有树没人取，见上面的 ✗**'}")
# build-llvm.sh 没有 TOOL=，所以不在上面那批里 —— 它不走 cmake/<工具>.cmake
# 那套，只取一棵树（llvm-project），而且自己 --fetch 时就核对 commit pin。
# 这里说一句，免得「每棵树都有人取」这条不变量被悄悄缩小了范围。
print("build-llvm.sh 不在此列：它只取 llvm-project 一棵树，pin 由它自己核对。")
sys.exit(bad)
PY
