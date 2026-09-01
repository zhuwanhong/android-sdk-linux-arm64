#
# zipalign 的构建目标。
#
# 上游那套 CMake（ReVanced/aapt2）**只编 aapt2，没有 zipalign 目标**——
# 这个文件把它补出来。依赖清单不是猜的，照抄 AOSP 自己的
# build/tools/zipalign/Android.bp 里 libzipalign 的 whole_static_libs：
#
#     libutils  libcutils  liblog  libziparchive  libz  libbase  libzopfli
#
# 前五个上游的 cmake/ 里已经有了（libz 由 NDK sysroot 提供）。**后两个上游没有**：
#
#     libzopfli          external/zopfli          ← ZipFile.cpp 直接 #include "zopfli/deflate.h"
#     zipalign 源码本身   platform/build           ← build/tools/zipalign/，不在 frameworks/base
#
# 这两棵树由 tools/build-zipalign.sh 另外取，pin 在跟上游子模块同一个 tag
# （platform-tools-35.0.2），落到 submodules/zopfli 和 submodules/build。
#
# 装法：拷进 <上游源码树>/cmake/，并在 cmake/CMakeLists.txt 末尾追加
#       include(zipalign.cmake)。build-zipalign.sh 会做，而且是幂等的。
#

# ---------------------------------------------------------------- libzopfli
#
# 源文件清单照抄 external/zopfli/Android.bp 的 cc_library libzopfli：12 个 .c。
# **不含 zopfli_bin.c** —— 那是 zopfli 命令行工具的 main()，链进来会跟
# ZipAlignMain.cpp 的 main 撞成重复符号。
#
# 上游 zopfli 自带 CMakeLists.txt，本来可以 add_subdirectory 直接用。没用，
# 两个理由：它会一并定义 zopflipng / 安装规则 / 各种 option，而我们只要一个静态库；
# 而且 Android.bp 才是 AOSP 实际编 zipalign 时用的那份清单，照它抄少一层猜测。
#
add_library(libzopfli STATIC
    ${SRC}/zopfli/src/zopfli/blocksplitter.c
    ${SRC}/zopfli/src/zopfli/cache.c
    ${SRC}/zopfli/src/zopfli/deflate.c
    ${SRC}/zopfli/src/zopfli/gzip_container.c
    ${SRC}/zopfli/src/zopfli/hash.c
    ${SRC}/zopfli/src/zopfli/katajainen.c
    ${SRC}/zopfli/src/zopfli/lz77.c
    ${SRC}/zopfli/src/zopfli/squeeze.c
    ${SRC}/zopfli/src/zopfli/tree.c
    ${SRC}/zopfli/src/zopfli/util.c
    ${SRC}/zopfli/src/zopfli/zlib_container.c
    ${SRC}/zopfli/src/zopfli/zopfli_lib.c
    )

# Android.bp 的 export_include_dirs: ["src"] —— 所以 #include "zopfli/deflate.h"
# 找的是 src/zopfli/deflate.h。PUBLIC 让链它的目标自动继承。
target_include_directories(libzopfli PUBLIC ${SRC}/zopfli/src)

# Android.bp 给的是 -O2 -Wno-unused-parameter -Werror。**-Werror 不带**：
# 薄壳工具链用的是发行版 clang，版本跟 Google 那份对不上，警告集就不一样，
# -Werror 会把「新版编译器多报了一条警告」变成构建失败。这不是我们要验的东西。
target_compile_options(libzopfli PRIVATE -O2 -Wno-unused-parameter)

# ---------------------------------------------------------------- zipalign
#
# Android.bp 把它拆成 libzipalign（三个 .cpp）+ zipalign（ZipAlignMain.cpp）。
# 这里合成一个可执行目标 —— 那层拆分是给 zipalign_tests 复用的，我们没编测试。
#
add_executable(zipalign
    ${SRC}/build/tools/zipalign/ZipAlign.cpp
    ${SRC}/build/tools/zipalign/ZipEntry.cpp
    ${SRC}/build/tools/zipalign/ZipFile.cpp
    ${SRC}/build/tools/zipalign/ZipAlignMain.cpp
    )

target_include_directories(zipalign PRIVATE
    ${SRC}/build/tools/zipalign/include
    ${SRC}/core/include
    ${SRC}/core/libutils/include
    ${SRC}/core/libcutils/include
    ${SRC}/logging/liblog/include
    ${SRC}/libbase/include
    ${SRC}/libziparchive/include
    ${SRC}/zopfli/src
    )

target_compile_options(zipalign PRIVATE -Wall)   # -Werror 同样不带，理由见上

# c++_static 是上游 cmake 的惯例（见 cmake/aapt2.cmake）。注意它只是一半：
# libc++.a 是个链接脚本 INPUT(-lc++_static -lc++abi)，显式链了 c++_static
# 就绕过了脚本，另一半得自己补。build-zipalign.sh 用
# -DCMAKE_CXX_STANDARD_LIBRARIES 在链接命令末尾补 -lc++abi，跟 aapt2 那边同一个坑。
target_link_libraries(zipalign
    libutils
    libcutils
    libziparchive
    libbase
    liblog
    libzopfli
    c++_static
    z
    dl
    )

target_link_options(zipalign PRIVATE "-Wl,-z,max-page-size=16384")
