#
# aidl 的构建目标。
#
# 源码清单和依赖照抄 AOSP 自己的 system/tools/aidl/Android.bp
# （cc_library_static libaidl-common + cc_binary_host aidl + cc_defaults aidl_defaults）。
#
# 跟 zipalign 那次不同的三处，都值得先知道：
#
# 1. **整棵源码树都不在上游那 18 个子模块里** —— aidl 自成一个仓库
#    （platform/system/tools/aidl，21 MB），由 tools/build-aidl.sh 另取。
#
# 2. **要先跑 flex 和 bison。** Android.bp 的 srcs 里直接列着 aidl_language_l.ll
#    和 aidl_language_y.yy —— Soong 认得这两种扩展名，会自己调 lex/yacc。
#    CMake 不会，得像下面这样显式声明。
#
# 3. **它链 gtest，而且不是为了跑测试。** aidl_defaults 里 static_libs 有 libgtest，
#    aidl_checkapi.cpp（正经产品代码）直接 #include <gtest/gtest.h>。看着怪，
#    但那是上游的事实，照做。
#

find_package(BISON REQUIRED)
find_package(FLEX  REQUIRED)

# 生成物放构建目录，**不落回源码树**。那棵树是 build-aapt2.sh 取来给几个工具共用的，
# 还打过上游的 patch.sh，不该再被生成物弄脏（lzhiyong 那份是写回源码目录的，
# 好处是省掉下面那条 include 路径，代价是源码树不再干净）。
set(AIDL_GEN ${CMAKE_CURRENT_BINARY_DIR}/aidl-gen)
file(MAKE_DIRECTORY ${AIDL_GEN})

# aidl_language_y.yy 里是 %skeleton "glr.cc" + %locations —— C++ 的 GLR 骨架。
# 这个骨架除了 .cpp/.h，**还会自己额外吐 location.hh 和 position.hh 到头文件旁边**
# （bison 3.8 实测），而生成的头会去 include 它们。所以 AIDL_GEN 必须进 include
# 路径，不然报 'location.hh' file not found —— 而你在源码里 grep 不到这个文件名，
# 因为它是生成的，不是写出来的。
bison_target(AidlParser
    ${SRC}/aidl/aidl_language_y.yy ${AIDL_GEN}/aidl_language_y.cpp
    DEFINES_FILE ${AIDL_GEN}/aidl_language_y.h)
flex_target(AidlScanner
    ${SRC}/aidl/aidl_language_l.ll ${AIDL_GEN}/aidl_language_l.cpp
    DEFINES_FILE ${AIDL_GEN}/aidl_language_l.h)
add_flex_bison_dependency(AidlScanner AidlParser)

# Android.bp 把它拆成 libaidl-common（32 个 .cpp）+ aidl（main.cpp）。
# 这里合成一个可执行目标 —— 那层拆分是给 aidl-cpp / 单元测试复用的，我们不编那些。
add_executable(aidl
    ${SRC}/aidl/aidl.cpp
    ${SRC}/aidl/aidl_checkapi.cpp
    ${SRC}/aidl/aidl_const_expressions.cpp
    ${SRC}/aidl/aidl_dumpapi.cpp
    ${SRC}/aidl/aidl_language.cpp
    ${SRC}/aidl/aidl_to_common.cpp
    ${SRC}/aidl/aidl_to_cpp.cpp
    ${SRC}/aidl/aidl_to_cpp_common.cpp
    ${SRC}/aidl/aidl_to_java.cpp
    ${SRC}/aidl/aidl_to_ndk.cpp
    ${SRC}/aidl/aidl_to_rust.cpp
    ${SRC}/aidl/aidl_typenames.cpp
    ${SRC}/aidl/ast_java.cpp
    ${SRC}/aidl/check_valid.cpp
    ${SRC}/aidl/code_writer.cpp
    ${SRC}/aidl/comments.cpp
    ${SRC}/aidl/diagnostics.cpp
    ${SRC}/aidl/generate_aidl_mappings.cpp
    ${SRC}/aidl/generate_cpp.cpp
    ${SRC}/aidl/generate_cpp_analyzer.cpp
    ${SRC}/aidl/generate_java.cpp
    ${SRC}/aidl/generate_java_binder.cpp
    ${SRC}/aidl/generate_ndk.cpp
    ${SRC}/aidl/generate_rust.cpp
    ${SRC}/aidl/import_resolver.cpp
    ${SRC}/aidl/io_delegate.cpp
    ${SRC}/aidl/location.cpp
    ${SRC}/aidl/logging.cpp
    ${SRC}/aidl/main.cpp
    ${SRC}/aidl/options.cpp
    ${SRC}/aidl/parser.cpp
    ${SRC}/aidl/permission.cpp
    ${SRC}/aidl/preprocess.cpp
    ${BISON_AidlParser_OUTPUTS}
    ${FLEX_AidlScanner_OUTPUTS}
    )

target_include_directories(aidl PRIVATE
    ${SRC}/aidl                             # 它自己的头
    ${AIDL_GEN}                             # 生成的 aidl_language_y.h 和 location.hh
    ${SRC}/libbase/include
    ${SRC}/logging/liblog/include
    ${SRC}/fmtlib/include
    ${SRC}/googletest/googletest/include    # 见文件开头第 3 条
    )

# options.cpp 里这个宏只影响 `aidl --version` 打印的那行；没定义会退到
# "<UNKNOWN>"。35 取自源码 pin 的 tag platform-tools-35.0.2 的大版本。
target_compile_definitions(aidl PRIVATE PLATFORM_SDK_VERSION=35)

# Android.bp 给的是 -Wall -Werror -Wextra，另外 host 变体加 -O0 -g。
# **-Werror 不带**（薄壳用发行版 clang，版本不同警告集就不同，理由同 zipalign）；
# -O0 -g 也不带 —— 那是 AOSP 给 host 开发调试用的，我们要的是能发的产物。
target_compile_options(aidl PRIVATE -Wall -Wextra)

target_link_libraries(aidl
    libbase
    liblog
    gtest          # Android.bp 写的是 libgtest
    fmt::fmt
    c++_static
    dl
    )

target_link_options(aidl PRIVATE "-Wl,-z,max-page-size=16384")
