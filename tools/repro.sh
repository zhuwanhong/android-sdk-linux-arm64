# 被 make-dist.sh / make-ndk-dist.sh / build-hermesc.sh source，不单独执行。
#
# 打包要**可复现**：同样的输入，谁在什么时候打，出来的 .tar.gz 都逐字节一样。
# 这样发布页上的 sha256 才是个能被第三方独立核对的东西，而不是「我这次打出来
# 碰巧是这个数」。
#
# 起因：改完打包脚本重跑了一次 make-dist.sh，新包的 sha256 跟 docs/RELEASE-NOTES.md
# 里已经公布的对不上。逐文件比过，差别只有 PROVENANCE.txt 里那行生成时间 ——
# 二进制一模一样，但**没人能从外部证明这一点**，只能自己解开来比。
#
# 不可复现的来源有四个，漏掉任何一个都白做：
#   1. 文件内容里写的时间戳（PROVENANCE.txt 的「生成时间」）
#   2. tar 记的 mtime —— 跟着文件系统走，每次拷贝都变
#   3. tar 里的文件顺序 —— readdir 顺序，跟目录的创建/删除历史有关，
#      同一台机器上重建一次目录就可能换个顺序
#   4. gzip 头里的时间戳。**这一项在这条管道里其实是防御性的** —— 变异测试时
#      把 -n 摘掉，两次的 sha256 仍然一样：gzip 压 stdin 时没有输入文件名和
#      mtime 可写，头里的 MTIME 本来就是 0。留着 -n 是为了防「哪天改成
#      gzip 直接压文件」，那时候它就承重了。真正承重的是 --mtime 和
#      --sort=name（把 --mtime 换成每次取当前时间，检查立刻红）。
# 另外 uid/gid/用户名也会进 tar 头，换台机器打就不一样。
#
# **归一化 tar 只解决元数据那一半。** 另一半在文件内容里，repro_tar 管不着，
# 得各打包脚本自己处理，实测踩到过两处：
#   - build-hermesc.sh 的 PROVENANCE 写着 date -u '+%H:%M'（分钟精度：同一分钟内
#     重打看着一致，跨分钟就变）—— 改用 $REPRO_STAMP；
#   - NDK 包里自带 python 的 .pyc：默认判据是源文件 mtime（差在第 9 字节），
#     而且 .pyc 里嵌着编译时的绝对路径（差在第 222 字节）—— 打包前用
#     `compileall --invalidation-mode unchecked-hash -d <固定路径>` 重编一遍。
# ci-checks 第 10 步守着第一类（打包脚本里不许出现 $(date）。
#
# 时间基准取 SOURCE_DATE_EPOCH（reproducible-builds.org 的通用约定），没设就用
# HEAD 的提交时间 —— 于是「同一个 commit + 同样的产物」打出来的包是固定的。
#
# **注意这条声明的边界**：可复现的是**打包**这一步，不是从源码到二进制的整条链。
# LLVM 那种编译产物本身是否逐字节可复现，是另一件事，我们没有声称。

repro_init() {
  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    REPRO_EPOCH="$SOURCE_DATE_EPOCH"; REPRO_SRC="SOURCE_DATE_EPOCH"
  else
    REPRO_EPOCH=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || true)
    REPRO_SRC="HEAD 的提交时间"
  fi
  case "$REPRO_EPOCH" in
    ''|*[!0-9]*)
      # 拿不到就退回当前时间，但**说清楚这个包不可复现**，别让它冒充可复现的。
      REPRO_EPOCH=$(date -u +%s); REPRO_SRC="当前时间（不在 git 里，**这个包不可复现**）" ;;
  esac
  REPRO_STAMP=$(date -u -d "@$REPRO_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) \
    || REPRO_STAMP=$(date -u -r "$REPRO_EPOCH" '+%Y-%m-%d %H:%M:%S')
  # **只往 stdout 打，绝不写进包**。同一个时间值，「设了环境变量」和「从 HEAD
  # 推出来」这两句话不一样，写进包里就让两种打法出不同的 sha256 —— 而文档教的
  # 正是后一种。踩过，见 docs/zh/LESSONS.md。
  printf '  \033[2m时间基准 %s UTC（%s）\033[0m\n' "$REPRO_STAMP" "$REPRO_SRC"
}

# $1 = 打包根目录（进去之后打 .）  $2 = 输出的 .tar.gz  $3（可选）= 只打这个子路径
repro_tar() {
  local root="$1" out="$2" what="${3:-.}"
  # --sort=name 要 GNU tar >= 1.28（Ubuntu 22.04 是 1.34）。少了它，
  # 顺序跟着 readdir 走，同样的目录重建一次就可能换个 sha256。
  tar --sort=name \
      --mtime="@$REPRO_EPOCH" \
      --owner=0 --group=0 --numeric-owner \
      --format=gnu \
      -C "$root" -cf - "$what" \
    | gzip -9n > "$out"
  # set -o pipefail 在各调用脚本里都开着，这里的返回值能反映 tar 或 gzip 的失败
}
