#!/usr/bin/env bash
# 自己编一份 sqlite3。
#
# 公共骨架在 tools/build-common.sh。只差一棵树（platform/external/sqlite，
# 稀疏 checkout 只要 dist）。**先跑 tools/build-aapt2.sh（至少 --fetch）。**
#
# ================================ 关于 ICU ================================
# **有了。** 2026-08-29 补上：cmake/icu.cmake 编 libicuuc / libicui18n /
# libicuuc_stubdata 三个静态库，sqlite3 开 -DSQLITE_ENABLE_ICU 链上去 ——
# 跟官方那份 host sqlite3 的做法一样（dist/Android.bp 里 host 变体就是这么写的）。
#
# **注意「照官方」包含「官方也没带数据」这一半。** 官方那份同样只链 stubdata，
# 所以 ucol_open() 会报 U_FILE_ACCESS_ERROR —— 这不是我们缺了什么，是原样。
# 证据和取舍在 cmake/sqlite3.cmake 开头。
# 下面 4/4 现在是**正向断言**：两条探针都要跟官方实测值对上。
# ==========================================================================
#
# 用法：
#   tools/build-sqlite3.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-sqlite3.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=sqlite3
CMAKE_FILES=(icu sqlite3)   # 顺序要紧：sqlite3 要链 icu 那三个目标
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 sqlite 的源码"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree sqlite external/sqlite dist/sqlite-default/sqlite3.c dist

  # ICU：官方那份 host sqlite3 静态链 libicui18n + libicuuc + libicuuc_stubdata
  # （dist/Android.bp 里 host 那一支写着）。只要 icu4c/source 底下那三块，
  # 稀疏取 —— 整棵 external/icu 很大，data/ 那一层用不上。
  common_fetch_tree icu external/icu \
      icu4c/source/common/unicode/uversion.h \
      "icu4c/source/common icu4c/source/i18n icu4c/source/stubdata"
  # 版本号得记下来：数据文件必须跟库同版本（icudt<版本>l.dat）。
  icuv=$(sed -n 's/^#define U_ICU_VERSION_MAJOR_NUM \([0-9]*\)/\1/p' \
         "$SRC/submodules/icu/icu4c/source/common/unicode/uvernum.h" 2>/dev/null)
  [ -n "$icuv" ] || die "读不出 ICU 大版本号（uvernum.h 挪窝了？）"
  ok "ICU $icuv（数据文件要配套的 icudt${icuv}l.dat，别拿别的版本混）"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/sqlite/dist/sqlite-default/sqlite3.c" ] || die "源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  T="$WORK/verify-sqlite3"; rm -rf "$T"; mkdir -p "$T"

  step "1/4  版本必须跟官方那份**一模一样**"
  # 同一份源码编出来的，版本行连同 SQLITE_SOURCE_ID 都该一致。
  # 这串是拿 Google 官方 platform-tools r35.0.2（x86_64）问出来的。
  want_ver='3.44.3 2024-03-24 21:15:01 d68fb8b5dbb8305e00d2dd14d8fe6b3d9f67e2459102ff160d956a6b75ddc18e'
  got_ver=$(run_tool --version 2>&1 | sed 's/ (64-bit)//' | tr -d '\r')
  [ "$got_ver" = "$want_ver" ] || die "版本行跟官方对不上
    期望 $want_ver
    实际 $got_ver
    源码版本不一样，后面几条比对就都不作数了。"
  ok "$got_ver"

  step "2/4  先确认这条测试会红：不是数据库的文件必须被拒"
  printf 'SQLite format 3\x00 这不是数据库，只是开头几个字节像\n' > "$T/notadb.db"
  [ -s "$T/notadb.db" ] || die "样本没造出来"
  if run_tool "$T/notadb.db" "SELECT count(*) FROM sqlite_master;" >/dev/null 2>&1; then
    die "拿一个假数据库喂它，居然读成功了 —— 那这条测试测不出东西。
    （样本开头是故意写成 'SQLite format 3' 的，就是要试它有没有真在校验。）
    先修测试，别信结果。"
  fi
  ok "假数据库被拒了（测试有效）"

  step "3/4  **建库的字节跟官方产物完全一致**"
  # 官方那个是确定性的：同样的 SQL 跑两遍，库文件哈希一样（实测过）。
  # 所以能拿它当黄金值 —— 第五节第 6 条。
  # 这条同时验了一堆 -D 有没有抄对：DEFAULT_AUTOVACUUM / DEFAULT_FILE_FORMAT /
  # PAGE 相关的选项只要错一个，页布局就变，哈希立刻对不上。
  SQL="CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t VALUES(1,'one'),(2,'two'),(3,'three'); CREATE INDEX i ON t(b);"
  rm -f "$T/probe.db"
  run_tool "$T/probe.db" "$SQL" || die "建库失败"
  [ -s "$T/probe.db" ] || die "建完了但库文件是空的"
  sz=$(stat -c%s "$T/probe.db")
  [ "$sz" = 16384 ] || die "库文件 $sz 字节，官方那份是 16384"
  want_db=98eea7c88ea4db0522e62fd1d6506f0c1a43effb4d01cfbe42164cf498777b32
  got_db=$(sha256sum "$T/probe.db" | cut -d' ' -f1)
  [ "$got_db" = "$want_db" ] || die "库文件哈希跟官方对不上
    期望 $want_db
    实际 $got_db
    多半是 cmake/sqlite3.cmake 里某个 -D 抄错或漏了 —— 页布局受它们影响。"
  ok "16384 字节，sha256 跟官方那份完全一致"
  rows=$(run_tool "$T/probe.db" "SELECT * FROM t ORDER BY a;" | tr '\n' ' ')
  [ "$rows" = "1|one 2|two 3|three " ] || die "读回来的数据不对：$rows"
  ok "数据读回来也对：$rows"

  step "4/4  **ICU：跟官方那份对齐**"
  # 这两条以前断言的是「缺口还在」（icu_load_collation 不存在、upper 原样返回）。
  # ICU 补上以后它们如约变红，于是照约定改成正向断言 —— **判据没变，只是翻了面**：
  # 期望值就是当初拿官方 platform-tools r35.0.2（x86_64）实测记下来的那两个。
  #
  # **这两条的红是实测过的**：留一份补 ICU 前的 sqlite3（1,895,464 字节），
  # 拿它当 $WORK/out/sqlite3 跑 --verify —— 4/4 红、退出码 1。
  # 想自己重造那份靶子：把 cmake/sqlite3.cmake 里的 -DSQLITE_ENABLE_ICU
  # 和那三个 icu 库去掉重编即可。
  #
  # 判据选 icu_load_collation 和 upper() 对非 ASCII 的行为，不是 REGEXP ——
  # **REGEXP 是 sqlite 的 shell.c 自带的，跟 ICU 无关**，两边都有。
  # 第一版就是拿 REGEXP 当判据写的，这条测试当场把那个错误结论逮住了。
  out=$(run_tool ":memory:" "SELECT icu_load_collation('en_US','en');" 2>&1)
  case "$out" in
    *"no such function: icu_load_collation"*)
      die "icu_load_collation 又没了 —— ICU 没链上？
    看 cmake/sqlite3.cmake 里的 -DSQLITE_ENABLE_ICU 和 target_link_libraries。" ;;
    *"ucol_open(): U_FILE_ACCESS_ERROR"*)
      ok "icu_load_collation 在，报 U_FILE_ACCESS_ERROR —— 跟官方逐字一致" ;;
    *"ICU error"*)
      # 别把「不一样」当成「好了」：真数据挂上去 ucol_open 就该成功，
      # 那是好事，但**得先改文档再改这条**，不能让它悄悄溜过去。
      die "ICU 报的错跟官方不是同一个：「$out」
    官方（也是 stubdata）给的是 ucol_open(): U_FILE_ACCESS_ERROR。
    如果是有人把真数据挂上了（udata_setCommonData / ICU_DATA）：
    **那是 2026-08-29 明确决定不做的事**（理由在 cmake/sqlite3.cmake 开头和
    README 第四节第 6 条）。要推翻这个决定可以，但得连那两处一起改。" ;;
    *) die "icu_load_collation 的反应不认识：「$out」" ;;
  esac
  # 官方给 ÄÖÜ。**不靠数据也对**：大小写属性编译在 libicuuc 里
  # （common/ucase_props_data.h，67 KB），排序规则才在 .dat 里 —— 所以
  # 「stubdata」下 upper() 正常、ucol_open() 失败，两者不矛盾。
  # ICU 大版本号从源码树读。
  # **本来想从二进制里 grep `icudt<版本>_dat` 那个符号名**，理由是「读到它就说明
  # stubdata 真链进去了」—— 写完一跑就红：我们这份是**静态链 + strip** 的，
  # 符号名根本不在里面。（官方那份读得到，是因为它是 PIE，符号留在 .dynsym。）
  # 所以「stubdata 到底链没链上」由上面两条**行为**探针来证，不是靠符号名：
  # 没链上 -> icu_load_collation 不存在；链了真数据 -> ucol_open 不会失败。
  linked_icuv=$(sed -n 's/^#define U_ICU_VERSION_MAJOR_NUM \([0-9]*\)/\1/p' \
      "$SRC/submodules/icu/icu4c/source/common/unicode/uvernum.h" 2>/dev/null)
  [ -n "$linked_icuv" ] || linked_icuv="NN（读不到 uvernum.h）"
  note "编进去的是 ICU $linked_icuv；官方那份是 78 —— 版本不同，上面两条行为一致"

  up=$(run_tool ":memory:" "SELECT upper('äöü');" 2>&1)
  case "$up" in
    "ÄÖÜ") ok "upper('äöü') = ÄÖÜ —— 跟官方一致" ;;
    "äöü") die "upper() 又不认非 ASCII 了 —— ICU 没真链进去，只是没报错。
    （静态库链了但符号没被引用也会这样，别只看链接成功。）" ;;
    *) die "upper('äöü') 的结果不认识：「$up」" ;;
  esac

  common_verify_done "  用它：
    $BIN foo.db 'SELECT * FROM t;'
  带 ICU（跟官方一样是 stubdata，没有 icudt${linked_icuv}l.dat）：
    upper('äöü') 给 ÄÖÜ；ucol_open() 报 U_FILE_ACCESS_ERROR —— 官方也是这个。
    要真排序规则得另外挂数据，见 cmake/sqlite3.cmake 开头。"
fi
