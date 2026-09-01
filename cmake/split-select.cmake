#
# split-select 的构建目标。
#
# 源码清单和依赖照抄 AOSP 自己的 frameworks/base/tools/split-select/Android.bp
# （cc_defaults split-select_defaults + cc_library_host_static libsplit-select
# + cc_binary_host split-select）。上游把六个 .cpp 拆成 libsplit-select 是为了
# 给单元测试复用，这里合成一个可执行目标。
#
# 它干什么：给一组 split APK 和一个目标设备配置，算出该装哪几个。
# Gradle 做 ABI／密度分包时用。
#
# **必须在 cmake/aapt.cmake 之后 include** —— 它链 libaapt，那个静态库定义在
# 那边（Android.bp 的 split-select_defaults 里 static_libs 第一个就是 libaapt）。
# tools/build-split-select.sh 会按这个顺序装。
#
# 跟 aapt 一样：一棵新源码树都不用取，源码在 submodules/base/tools/split-select/。
#

add_executable(split-select
    ${SRC}/base/tools/split-select/Abi.cpp
    ${SRC}/base/tools/split-select/Grouper.cpp
    ${SRC}/base/tools/split-select/Main.cpp
    ${SRC}/base/tools/split-select/Rule.cpp
    ${SRC}/base/tools/split-select/RuleGenerator.cpp
    ${SRC}/base/tools/split-select/SplitDescription.cpp
    ${SRC}/base/tools/split-select/SplitSelector.cpp
    )

target_compile_options(split-select PRIVATE -Wall)   # -Werror 不带，理由见 cmake/zipalign.cmake

target_include_directories(split-select PRIVATE
    ${SRC}/base/tools                       # 它 #include "aapt/..." 是从这层往下找的
    ${SRC}/base/libs/androidfw/include
    ${SRC}/base/libs/androidfw/include_pathutils
    ${SRC}/core/libutils/include
    ${SRC}/core/libsystem/include
    ${SRC}/logging/liblog/include
    ${SRC}/libbase/include
    ${SRC}/fmtlib/include
    ${SRC}/incremental_delivery/incfs/util/include
    )

# 跟 aapt 同一份清单，理由也一样：多出来的那些是 libandroidfw 的传递依赖，
# 而 libprocessgroup 特意没有 —— 见 cmake/aapt.cmake 里那段。
target_link_libraries(split-select
    libaapt
    libandroidfw
    libincfs
    libutils
    libcutils
    libselinux
    libsepol
    libziparchive
    libpackagelistparser
    libbase
    liblog
    expat
    crypto
    pcre2-8
    jsoncpp_static
    png_static
    c++_static
    dl
    z
    )

target_link_options(split-select PRIVATE "-Wl,-z,max-page-size=16384")
