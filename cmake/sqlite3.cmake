#
# sqlite3 的构建目标。
#
# 源码和编译选项照 AOSP 自己的 external/sqlite/dist/Android.bp：
#   cc_defaults sqlite-minimal-defaults  （主要那批 -D）
#   cc_defaults sqlite-defaults          （android 变体再加 5 个）
#   sqlite3 的 host 变体                  （-DNO_ANDROID_FUNCS=1）
#
# 源文件用 dist/sqlite-default/ 那份（Android.bp 里 release_package_libsqlite3
# 的 conditions_default 就是它）。dist/ 下还有个 sqlite-autoconf-3440300，
# 两份都是 3.44.3。
#
# ================================== ICU ===================================
#
# **开着**：-DSQLITE_ENABLE_ICU + 链 libicui18n / libicuuc / libicuuc_stubdata，
# 跟 dist/Android.bp 里 libsqlite 的 host 变体一样。三个库怎么编见 cmake/icu.cmake
# （那里记着两个非编不可的坑：NDK 的 uconfig_local.h，和裸 ANDROID 宏）。
#
# 2026-08-29 之前这里没有 ICU，注释是「已知缺口」。补上以后拿当初记的官方实测值
# 逐条对：
#
#     SELECT icu_load_collation('en_US','en');
#       官方 -> ICU error: ucol_open(): U_FILE_ACCESS_ERROR
#       我们 -> ICU error: ucol_open(): U_FILE_ACCESS_ERROR   一致
#     SELECT upper('äöü');
#       官方 -> ÄÖÜ        我们 -> ÄÖÜ                        一致
#
# --- 「照官方」也包括：官方同样**没带 ICU 数据** ---
#
# ucol_open() 报 U_FILE_ACCESS_ERROR 不是我们缺东西，是 stubdata 的正常表现，
# 官方那份也一样。这不是从注释推的，是查出来的（不用跑 x86_64 二进制，
# 拆它就行 —— qemu 已经卸了）：
#   * llvm-readelf -d 官方 sqlite3：NEEDED 里**没有** libicuuc.so —— ICU 是静态链的
#   * 整个 platform-tools 里没有任何 *.dat，也没有 ICU 的 .so
#   * 官方二进制才 3.6 MB —— 真数据光 icudt##l.dat 就 28 MB，装不下
#   * strings 官方二进制：有 `icudt78_dat` 和 `U_FILE_ACCESS_ERROR`
#     —— 那正是 stubdata 的入口符号名和它必然报的错
#
# 顺带查出来的一处真差别：**官方是 ICU 78，我们这棵树是 ICU 75**
# （external/icu 的 platform-tools-35.0.2 tag）。数据文件名跟版本绑死
# （icudt78l.dat / icudt75l.dat），哪天要挂真数据，别拿错版本。
#
# --- upper() 不靠数据也对，为什么 ---
#
# 大小写属性是**编译进 libicuuc 的**（common/ucase_props_data.h，67 KB），
# 排序规则才在 .dat 里。所以 stubdata 下 upper() 正常、ucol_open() 失败，
# 这两件事不矛盾 —— 一开始我以为「没数据 = 什么都不灵」，是错的。
#
# --- 真数据：决定不做（2026-08-29） ---
#
# 技术上不难：走 udata_setCommonData() 或环境变量 ICU_DATA 指到 icudt75l.dat
# （27,956,384 字节，就在 submodules/icu/icu4c/source/stubdata/ 里），
# 库这边不用重编。**不做的理由不是难，是方向**：二进制会从 3.3 MB 涨到 30 MB+，
# 而官方没这么做 —— 那就成了「比官方好用，但跟官方不一样」。
# 这个项目的判据一直是**跟官方行为一致**。同理，FTS5 / RTREE 也不开（官方没开）。
# 想反悔，先推翻那条判据，不是加个开关。
#
# tools/build-sqlite3.sh 的 4/4 盯着上面两条探针：**任何一条跟官方不一样都会红**，
# 包括「有人挂了真数据」这种好事 —— 好事也得先改这段注释。
# ==========================================================================
#

set(SQLITE_SRC ${SRC}/sqlite/dist/sqlite-default)

add_executable(sqlite3
    ${SQLITE_SRC}/sqlite3.c
    ${SQLITE_SRC}/shell.c
    )

target_compile_definitions(sqlite3 PRIVATE
    # ---- sqlite-minimal-defaults ----
    -DNDEBUG=1
    -DHAVE_USLEEP=1
    -DSQLITE_HAVE_ISNAN
    -DSQLITE_DEFAULT_JOURNAL_SIZE_LIMIT=1048576
    -DSQLITE_THREADSAFE=2
    -DSQLITE_TEMP_STORE=3
    -DSQLITE_POWERSAFE_OVERWRITE=1
    -DSQLITE_DEFAULT_FILE_FORMAT=4
    -DSQLITE_DEFAULT_AUTOVACUUM=1
    -DSQLITE_ENABLE_MEMORY_MANAGEMENT=1
    -DSQLITE_ENABLE_FTS3
    -DSQLITE_ENABLE_FTS3_BACKWARDS
    -DSQLITE_ENABLE_FTS4
    -DSQLITE_OMIT_BUILTIN_TEST
    -DSQLITE_OMIT_COMPILEOPTION_DIAGS
    -DSQLITE_OMIT_LOAD_EXTENSION
    -DSQLITE_DEFAULT_FILE_PERMISSIONS=0600
    -DSQLITE_SECURE_DELETE
    -DSQLITE_ENABLE_BATCH_ATOMIC_WRITE
    -DBIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD
    -DSQLITE_DEFAULT_LEGACY_ALTER_TABLE
    # 这两个是 35.0.2 那份 Android.bp 里有、别人的 CMake 里没有的 ——
    # 照 Android.bp 抄就不会漏
    -DSQLITE_ALLOW_ROWID_IN_VIEW
    -DSQLITE_ENABLE_BYTECODE_VTAB
    # ---- sqlite-defaults 的 android 变体 ----
    # 取 android 那组不是随手选的：这几个描述的是 **libc**（pread64、
    # malloc_usable_size 都是 bionic 的），而我们就是拿 NDK 编的 bionic 二进制。
    # 这跟 dexdump 那边「取 host 组」的判断不冲突 —— 那几个描述的是工具的用途。
    -DUSE_PREAD64
    -Dfdatasync=fdatasync
    -DHAVE_MALLOC_H=1
    -DHAVE_MALLOC_USABLE_SIZE
    -DSQLITE_ENABLE_DBSTAT_VTAB
    # ---- sqlite3 可执行文件的 host 变体 ----
    # 不去调 libsqlite3_android 里那批 Android 专用函数
    -DNO_ANDROID_FUNCS=1
    # ---- ICU ----
    # Android.bp 里 libsqlite 的 host 变体写着 -DSQLITE_ENABLE_ICU + libicui18n/libicuuc。
    -DSQLITE_ENABLE_ICU
    )

# Android.bp 给的是 -Wno-unused-parameter -Werror -ftrivial-auto-var-init=pattern。
# -Werror 不带（理由见 cmake/zipalign.cmake）；另外两个照带 ——
# **-ftrivial-auto-var-init=pattern 会改变未初始化变量的内容**，去掉它编出来的
# 就不是同一个东西了，而验收里有一条要跟官方产物比字节。
target_compile_options(sqlite3 PRIVATE -Wno-unused-parameter -ftrivial-auto-var-init=pattern)

# 顺序照 Android.bp：i18n 依赖 uc，uc 依赖 stubdata 里那个 icudt##_dat 符号。
target_link_libraries(sqlite3 libicui18n libicuuc libicuuc_stubdata z)
target_link_options(sqlite3 PRIVATE "-Wl,-z,max-page-size=16384")
