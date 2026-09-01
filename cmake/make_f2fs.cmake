#
# make_f2fs 的构建目标。
#
# 照 AOSP 自己的 external/f2fs-tools/Android.bp：
#   cc_defaults libf2fs_src_files   -> libf2fs_fmt 的五个源文件
#   cc_defaults make_f2fs_src_files -> 可执行文件的两个
#   cc_defaults f2fs-tools-defaults -> 那批 -D 和 local_include_dirs
#   cc_binary   make_f2fs
#
# **只多取一棵树**（external/f2fs-tools，2 MB）：libext2_uuid 由 cmake/mke2fs.cmake
# 提供，libsparse / libbase 在上游那棵树里。README 原来估的是「三棵」，
# 后来 mke2fs 做完少一棵，实际查下来 **lz4 也不需要** —— 那是 sload_f2fs 用的，
# 不是 make_f2fs。估算和实查的差别，又一次。
#
# **必须在 cmake/mke2fs.cmake 之后 include**（要它的 libext2_uuid）。
# tools/build-make_f2fs.sh 会按顺序装。
#
# 一个读 Android.bp 时容易看错的地方：make_f2fs_defaults 里的
# -DANDROID_WINDOWS_HOST 和 external/e2fsprogs/include/mingw **是 windows 变体
# 专属**的，包在 target.windows 里。按缩进层级读，别按 grep 的输出读。
#

set(F2FS ${SRC}/f2fs-tools)

set(F2FS_INCLUDES
    ${F2FS}/include
    ${F2FS}/mkfs
    ${F2FS}/fsck
    ${SRC}/e2fsprogs/lib          # uuid/uuid.h
    ${SRC}/core/libsparse/include
    ${SRC}/libbase/include
    )

add_library(libf2fs_fmt STATIC
    ${F2FS}/lib/libf2fs.c
    ${F2FS}/lib/libf2fs_zoned.c
    ${F2FS}/lib/nls_utf8.c
    ${F2FS}/mkfs/f2fs_format.c
    ${F2FS}/mkfs/f2fs_format_utils.c
    )
target_include_directories(libf2fs_fmt PRIVATE ${F2FS_INCLUDES})
target_compile_definitions(libf2fs_fmt PRIVATE
    F2FS_MAJOR_VERSION=1
    F2FS_MINOR_VERSION=16
    F2FS_TOOLS_VERSION=\"1.16.0\"
    F2FS_TOOLS_DATE=\"2023-04-11\"
    WITH_ANDROID
    _FILE_OFFSET_BITS=64
    WITH_BLKDISCARD              # libf2fs_src_files 单独加的
    )
target_compile_options(libf2fs_fmt PRIVATE
    -Wall -Wno-macro-redefined -Wno-missing-field-initializers
    -Wno-pointer-arith -Wno-sign-compare)   # -Werror 不带，见 cmake/zipalign.cmake

add_executable(make_f2fs
    ${F2FS}/lib/libf2fs_io.c
    ${F2FS}/mkfs/f2fs_format_main.c
    )
target_include_directories(make_f2fs PRIVATE ${F2FS_INCLUDES})
target_compile_definitions(make_f2fs PRIVATE
    F2FS_MAJOR_VERSION=1
    F2FS_MINOR_VERSION=16
    F2FS_TOOLS_VERSION=\"1.16.0\"
    F2FS_TOOLS_DATE=\"2023-04-11\"
    WITH_ANDROID
    _FILE_OFFSET_BITS=64
    )
target_compile_options(make_f2fs PRIVATE
    -Wall -Wno-macro-redefined -Wno-missing-field-initializers
    -Wno-pointer-arith -Wno-sign-compare)

# Android.bp 里 android 变体链 libf2fs_fmt + libext2_uuid/libsparse/libbase；
# host 变体链的是 libf2fs_fmt_host（那个只是多了 windows 的 include 路径）。
# 我们编的是 Android ABI 的二进制，取 android 那组。
target_link_libraries(make_f2fs
    libf2fs_fmt
    libext2_uuid      # 来自 cmake/mke2fs.cmake
    libsparse         # 同上
    libbase
    c++_static
    z
    )
target_link_options(make_f2fs PRIVATE "-Wl,-z,max-page-size=16384")

# ---------------------------------------------------------------------------
# make_f2fs_casefold
#
# 官方 platform-tools 里是**两个**二进制：make_f2fs 和 make_f2fs_casefold。
# 原来漏了后面这个 —— 是照 M4 的目标目录一个个数文件时才发现的，
# 「十一个工具的产物已经齐了」这句话当时不成立。
#
# Android.bp（external/f2fs-tools/Android.bp:188）里它跟 make_f2fs 共用
# make_f2fs_defaults，只多两个 -D：
#
#     cc_binary_host {
#         name: "make_f2fs_casefold",
#         defaults: ["make_f2fs_defaults"],
#         target: { host: { cflags: ["-DCONF_CASEFOLD", "-DCONF_PROJID"] }, ... },
#     }
#
# 那两个宏只被 mkfs/f2fs_format_main.c:156-165 用到，作用是往超级块里多写几位：
#     CONF_CASEFOLD  s_encoding = F2FS_ENC_UTF8_12_1，feature |= CASEFOLD(0x1000)
#     CONF_PROJID    feature |= QUOTA_INO(0x80) | PRJQUOTA(0x10) | EXTRA_ATTR(0x8)
# 实测两边造出来的镜像：plain 的 feature=0x00000000 / s_encoding=0，
# casefold 的 feature=0x00001098 / s_encoding=1。这就是验收时的判别依据。
#
# 注意宏只加在**可执行文件自己的两个源文件**上，不加在 libf2fs_fmt 上 ——
# Android.bp 里 cflags 是这个 cc_binary_host 模块的，静态库是另一个模块。
# 加错了会连带改掉 make_f2fs（共用同一个 libf2fs_fmt），两个产物一起错。

add_executable(make_f2fs_casefold
    ${F2FS}/lib/libf2fs_io.c
    ${F2FS}/mkfs/f2fs_format_main.c
    )
target_include_directories(make_f2fs_casefold PRIVATE ${F2FS_INCLUDES})
target_compile_definitions(make_f2fs_casefold PRIVATE
    F2FS_MAJOR_VERSION=1
    F2FS_MINOR_VERSION=16
    F2FS_TOOLS_VERSION=\"1.16.0\"
    F2FS_TOOLS_DATE=\"2023-04-11\"
    WITH_ANDROID
    _FILE_OFFSET_BITS=64
    CONF_CASEFOLD
    CONF_PROJID
    )
target_compile_options(make_f2fs_casefold PRIVATE
    -Wall -Wno-macro-redefined -Wno-missing-field-initializers
    -Wno-pointer-arith -Wno-sign-compare)
target_link_libraries(make_f2fs_casefold
    libf2fs_fmt
    libext2_uuid
    libsparse
    libbase
    c++_static
    z
    )
target_link_options(make_f2fs_casefold PRIVATE "-Wl,-z,max-page-size=16384")
