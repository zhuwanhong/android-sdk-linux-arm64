#
# hprof-conv 的构建目标 —— M3 里最小的一个。
#
# 照 AOSP 自己的 dalvik/tools/hprof-conv/Android.bp（cc_binary_host hprof-conv）：
# **一个源文件，一个库都不链。** lzhiyong 那份链了 dl 和 z —— 上游没列，不跟。
#
# 它干什么：把 Android 的 HPROF 1.0.3 转成标准 Java 的 1.0.2 —— 改版本头，
# 并把 Android 专有的根记录（INTERNED_STRING / FINALIZING / DEBUGGER ...）
# 改写成 ROOT_UNKNOWN，好让 MAT、jhat 这些标准工具读得懂。
#
# 源码在 platform/dalvik，上游那 18 个子模块里没有，由 tools/build-hprof-conv.sh 另取。
#

add_executable(hprof-conv ${SRC}/dalvik/tools/hprof-conv/HprofConv.c)
target_compile_options(hprof-conv PRIVATE -Wall)   # -Werror 不带，理由见 cmake/zipalign.cmake
target_link_options(hprof-conv PRIVATE "-Wl,-z,max-page-size=16384")
