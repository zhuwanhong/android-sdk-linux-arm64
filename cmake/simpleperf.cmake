#
# simpleperf 的构建目标 —— **这一轮只到依赖那一层**，libsimpleperf 本体和
# simpleperf 可执行文件在下一轮（照 adb 那次分轮的做法）。
#
# 源码清单全部照抄各自的 Android.bp，**一个都不是手敲的**（脚本抽出来的）：
#
#     external/lzma/Android.bp        liblzma（7-Zip SDK 那套，38 个 .c）
#     external/libevent/Android.bp    libevent
#     system/libprocinfo/Android.bp   libprocinfo
#     external/OpenCSD/Android.bp     libopencsd_decoder（bp 里就是 glob，这里照样 glob）
#
# 这四棵树由 tools/build-simpleperf.sh --fetch 取，见那个脚本开头。
#
# 还没在这里的（下一轮）：libunwindstack、art 的 libdexfile_support、
# libsimpleperf 本体（52 个源文件 + 3 个 .proto + 1 个 genrule）、
# 以及交叉编到 aarch64-linux-android 的 LLVM Object/Support。
#

# ---------------------------------------------------------------- liblzma
# 名字容易记错：AOSP 的 liblzma 是 **7-Zip SDK**（external/lzma），
# 不是 XZ Utils —— googlesource 上根本没有 external/xz 这个仓库。
# Z7_ST：单线程，照 bp 里的 cflags。
set(LZMA ${SRC}/lzma)
add_library(liblzma STATIC
    ${LZMA}/C/7zAlloc.c
    ${LZMA}/C/7zArcIn.c
    ${LZMA}/C/7zBuf2.c
    ${LZMA}/C/7zBuf.c
    ${LZMA}/C/7zCrc.c
    ${LZMA}/C/7zCrcOpt.c
    ${LZMA}/C/7zDec.c
    ${LZMA}/C/7zFile.c
    ${LZMA}/C/7zStream.c
    ${LZMA}/C/Aes.c
    ${LZMA}/C/AesOpt.c
    ${LZMA}/C/Alloc.c
    ${LZMA}/C/Bcj2.c
    ${LZMA}/C/Bra86.c
    ${LZMA}/C/Bra.c
    ${LZMA}/C/BraIA64.c
    ${LZMA}/C/CpuArch.c
    ${LZMA}/C/Delta.c
    ${LZMA}/C/LzFind.c
    ${LZMA}/C/Lzma2Dec.c
    ${LZMA}/C/Lzma2Enc.c
    ${LZMA}/C/Lzma86Dec.c
    ${LZMA}/C/Lzma86Enc.c
    ${LZMA}/C/LzmaDec.c
    ${LZMA}/C/LzmaEnc.c
    ${LZMA}/C/LzmaLib.c
    ${LZMA}/C/Ppmd7.c
    ${LZMA}/C/Ppmd7Dec.c
    ${LZMA}/C/Ppmd7Enc.c
    ${LZMA}/C/Sha256.c
    ${LZMA}/C/Sha256Opt.c
    ${LZMA}/C/Sort.c
    ${LZMA}/C/Xz.c
    ${LZMA}/C/XzCrc64.c
    ${LZMA}/C/XzCrc64Opt.c
    ${LZMA}/C/XzDec.c
    ${LZMA}/C/XzEnc.c
    ${LZMA}/C/XzIn.c
    )
target_compile_definitions(liblzma PRIVATE Z7_ST)
target_include_directories(liblzma PUBLIC ${LZMA}/C)
target_compile_options(liblzma PRIVATE
    -Wno-empty-body -Wno-enum-conversion -Wno-logical-op-parentheses -Wno-self-assign)

# ---------------------------------------------------------------- libevent
# bp 里 kqueue.c 是 darwin 那一支的，Linux/Android 不编 —— 抽清单的脚本把
# 各 target 的 srcs 合在一起了，这里按平台去掉。
set(LIBEVENT ${SRC}/libevent)
add_library(libevent STATIC
    ${LIBEVENT}/buffer.c
    ${LIBEVENT}/bufferevent.c
    ${LIBEVENT}/bufferevent_filter.c
    ${LIBEVENT}/bufferevent_pair.c
    ${LIBEVENT}/bufferevent_ratelim.c
    ${LIBEVENT}/bufferevent_sock.c
    ${LIBEVENT}/epoll.c
    ${LIBEVENT}/evdns.c
    ${LIBEVENT}/event.c
    ${LIBEVENT}/event_tagging.c
    ${LIBEVENT}/evmap.c
    ${LIBEVENT}/evrpc.c
    ${LIBEVENT}/evthread.c
    ${LIBEVENT}/evthread_pthread.c
    ${LIBEVENT}/evutil.c
    ${LIBEVENT}/evutil_rand.c
    ${LIBEVENT}/evutil_time.c
    ${LIBEVENT}/http.c
    ${LIBEVENT}/listener.c
    ${LIBEVENT}/log.c
    ${LIBEVENT}/poll.c
    ${LIBEVENT}/select.c
    ${LIBEVENT}/signal.c
    ${LIBEVENT}/strlcpy.c
    )
target_include_directories(libevent PUBLIC ${LIBEVENT}/include)
target_include_directories(libevent PRIVATE ${LIBEVENT} ${LIBEVENT}/compat)
target_compile_definitions(libevent PRIVATE _BSD_SOURCE)
target_compile_options(libevent PRIVATE
    -O3 -Wno-implicit-function-declaration -Wno-strict-aliasing -Wno-unused-parameter)

# ---------------------------------------------------------------- libprocinfo
set(PROCINFO ${SRC}/libprocinfo)
add_library(libprocinfo STATIC ${PROCINFO}/process.cpp)
target_include_directories(libprocinfo PUBLIC ${PROCINFO}/include)
target_include_directories(libprocinfo PRIVATE
    ${SRC}/libbase/include ${SRC}/logging/liblog/include)

# ---------------------------------------------------------------- libopencsd_decoder
# ARM CoreSight ETM 的解码器。**ETM 是 ARM 上 simpleperf 最有用的部分**，
# 所以这个不砍（取舍见 README 第三节第 4 条）。
# bp 里的 srcs 本来就是 glob，这里照样 glob —— 手敲一份清单只会跟上游漂移。
set(OCSD ${SRC}/OpenCSD/decoder)
file(GLOB OCSD_SRCS
    ${OCSD}/source/*.cpp
    ${OCSD}/source/etmv3/*.cpp
    ${OCSD}/source/etmv4/*.cpp
    ${OCSD}/source/ete/*.cpp
    ${OCSD}/source/i_dec/*.cpp
    ${OCSD}/source/mem_acc/*.cpp
    ${OCSD}/source/pkt_printers/*.cpp
    ${OCSD}/source/ptm/*.cpp
    ${OCSD}/source/stm/*.cpp
    )
list(LENGTH OCSD_SRCS OCSD_N)
# 下限 40 不是拍的：platform-tools-35.0.2 那版这九个目录底下**数出来是 44 个**
# （source 15 / etmv3 5 / etmv4 5 / ete 1 / i_dec 2 / mem_acc 6 / pkt_printers 3
# / ptm 4 / stm 3）。头一版这里写「该有一百多个」，纯属想当然，配置阶段当场红。
# glob 出 0 个文件时 add_library 报的错很难懂，而「树没取全」跟「上游挪了目录」
# 又是两回事 —— 所以这里自己判、自己说清楚。
if(OCSD_N LESS 40)
    message(FATAL_ERROR "OpenCSD 只 glob 到 ${OCSD_N} 个源文件（pin 的这版该是 44）——"
                        " submodules/OpenCSD 没取全，或者上游挪了目录")
endif()
add_library(libopencsd_decoder STATIC ${OCSD_SRCS})
target_include_directories(libopencsd_decoder PUBLIC ${OCSD}/include)
target_compile_options(libopencsd_decoder PRIVATE
    -Wno-ignored-qualifiers -Wno-unused-parameter -Wno-switch
    -Wno-unused-private-field -Wno-implicit-fallthrough
    -Wno-constant-logical-operand -fexceptions)
set_target_properties(libopencsd_decoder PROPERTIES CXX_RTTI ON)

# ===========================================================================
# 第二轮：libunwindstack、libdexfile_support、libsimpleperf 本体、simpleperf
# ===========================================================================
#
# 清单同样照抄 Android.bp：
#     unwinding/libunwindstack/Android.bp   libunwindstack_common_src_files（29）
#                                           + 模块自己的 DexFile.cpp / LogAndroid.cpp
#     art/libdexfile/Android.bp             libdexfile_support（就一个 .cc，
#                                           运行时 dlopen libdexfile，所以不用整棵 ART）
#     bionic/libc/async_safe/Android.bp      libasync_safe（LogAndroid.cpp 要它）
#     extras/simpleperf/Android.bp          libsimpleperf_srcs：公共 26 + linux 20
#
# **android 那一支的 cmd_boot_record.cpp 也要编** —— 这条一开始判反了。
# 当时的理由是「我们对标的是官方 bin/linux/<host>/ 那一份，它是 host 构建
# （common + linux），不含 android 那支」。理由本身没错，**但决定编什么的不是
# 我们想对标哪份产物，是 `__ANDROID__` 这个宏**：command.cpp:213 那里写着
#
#     #if defined(__ANDROID__)
#       RegisterAPICommands();
#       RegisterBootRecordCommand();
#     #endif
#
# 我们编的是 Android 目标（静态 bionic），这个宏成立，于是链接期直接报
# `undefined symbol: simpleperf::RegisterBootRecordCommand()`。
#
# **后果要写明**：我们这份比官方的 host 二进制多两组子命令（api-*、boot-record）。
# 那是选了静态 bionic 带来的，不是漏改，PROVENANCE 里要说。

# ---------------------------------------------------------------- 路径从哪来
# tools/build-simpleperf.sh 在配置之前把这个文件写进树里。
# **为什么不用 -D 传**：build-common.sh 那组 cmake flag 必须几个工具逐字一致
# （同一个 build 目录，配置一变就全树重编）。多一个 -D 就破了这条。
include(${CMAKE_CURRENT_LIST_DIR}/simpleperf-paths.cmake OPTIONAL)

# ---------------------------------------------------------------- 外部传进来的三样
# 这三样不在这棵树里编，由 tools/build-simpleperf.sh 先做好再 -D 传进来。
# **缺了就直接报错，不给默认值** —— 默认值会让「没传」和「传对了」编出两种
# 不一样的产物，而且都报成功。
if(NOT SIMPLEPERF_RUSTC_DEMANGLE OR NOT EXISTS ${SIMPLEPERF_RUSTC_DEMANGLE})
    message(FATAL_ERROR
        "要 -DSIMPLEPERF_RUSTC_DEMANGLE=<librustc_demangle.a 的路径>。"
        " 跑 tools/build-simpleperf.sh --build 会先把它编出来。"
        " 这个符号是硬需求：libunwindstack/Demangle.cpp 和 simpleperf/dso.cpp 都无条件调用。")
endif()
if(NOT SIMPLEPERF_LLVM_DIR OR NOT EXISTS ${SIMPLEPERF_LLVM_DIR}/lib/libLLVMObject.a)
    message(FATAL_ERROR
        "要 -DSIMPLEPERF_LLVM_DIR=<交叉编到 aarch64-linux-android 的 LLVM 构建目录>。"
        " **不能用 tools/build-llvm.sh 那份** —— 那是 host（glibc）工具链，"
        " 静态 bionic 的目标二进制链不了它。")
endif()
if(NOT SIMPLEPERF_LLVM_SRC OR NOT EXISTS ${SIMPLEPERF_LLVM_SRC}/include/llvm/Object/ELFObjectFile.h)
    # 头一版这里写 ${SRC}/../llvm/... 去拼路径 —— SRC 是 submodules 目录，
    # 拼出来的是 <树>/aapt2/llvm，而 llvm-project 在 WORK 底下，不在树里。
    # **路径别在 cmake 里猜，让脚本传。**
    message(FATAL_ERROR "要 -DSIMPLEPERF_LLVM_SRC=<llvm-project/llvm 的路径>（放头文件的那棵源码树）")
endif()
set(SP_RUSTC_DEMANGLE ${SIMPLEPERF_RUSTC_DEMANGLE})
set(SP_LLVM_INCLUDE ${SIMPLEPERF_LLVM_SRC}/include ${SIMPLEPERF_LLVM_DIR}/include)
set(SP_LLVM_LIBS
    ${SIMPLEPERF_LLVM_DIR}/lib/libLLVMObject.a
    ${SIMPLEPERF_LLVM_DIR}/lib/libLLVMBinaryFormat.a
    ${SIMPLEPERF_LLVM_DIR}/lib/libLLVMTargetParser.a
    ${SIMPLEPERF_LLVM_DIR}/lib/libLLVMSupport.a
    ${SIMPLEPERF_LLVM_DIR}/lib/libLLVMDemangle.a)

find_program(SP_PYTHON NAMES python3 python)
if(NOT SP_PYTHON)
    message(FATAL_ERROR "没有 python3 —— Android.bp 的 genrule simpleperf_event_table 要它")
endif()

# protoc 生成。**不复用 cmake/adb.cmake 里的 gen_pb** —— 那会让 simpleperf 的
# 构建依赖「adb 先编过」，而这两个工具之间没有任何关系。
set(SP_PB_DIR ${CMAKE_CURRENT_BINARY_DIR}/simpleperf-proto)
file(MAKE_DIRECTORY ${SP_PB_DIR})

# **生成物要落在 system/extras/simpleperf/ 底下**，因为源码是按 AOSP 的全路径
# include 的：#include "system/extras/simpleperf/branch_list.pb.h"。
# AOSP 那边 proto_path 是仓库根，我们这棵树里 simpleperf 在 submodules/extras/
# 底下，路径对不上 —— 所以在 build 目录里搭一层软链，让 protoc 看到它要的形状。
# 跟 cmake/adb.cmake 里 fastdeploy 那段是同一个道理。
set(SP_PB_ROOT ${CMAKE_CURRENT_BINARY_DIR}/simpleperf-proto-root)

function(sp_gen_pb OUTVAR)
    # 软链在这里建，不在函数外面 —— ${SP} 是在下面的 libsimpleperf 那一节才定义的，
    # 放外面会拿一个空路径去建链，protoc 报「Could not make proto path relative」。
    if(NOT SP)
        message(FATAL_ERROR "sp_gen_pb 调用时 SP 还没定义")
    endif()
    file(MAKE_DIRECTORY ${SP_PB_ROOT}/system/extras)
    file(REMOVE ${SP_PB_ROOT}/system/extras/simpleperf)
    file(CREATE_LINK ${SP} ${SP_PB_ROOT}/system/extras/simpleperf SYMBOLIC)
    set(_out "")
    foreach(pf ${ARGN})
        get_filename_component(base ${pf} NAME_WE)
        set(rel system/extras/simpleperf/${base})
        set(cc ${SP_PB_DIR}/${rel}.pb.cc)
        execute_process(
            COMMAND ${Protobuf_PROTOC_EXECUTABLE} ${rel}.proto
                    --proto_path=${SP_PB_ROOT} --cpp_out=lite:${SP_PB_DIR}
            RESULT_VARIABLE rc WORKING_DIRECTORY ${SP_PB_ROOT})
        if(NOT rc EQUAL 0)
            message(FATAL_ERROR "protoc 生成 ${pf} 失败（rc=${rc}）")
        endif()
        if(NOT EXISTS ${cc})
            message(FATAL_ERROR "protoc 说成功了，但 ${cc} 不在")
        endif()
        list(APPEND _out ${cc})
    endforeach()
    set(${OUTVAR} ${_out} PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------- libzstd
# ZstdUtil.cpp 要它。cmake/adb-deps.cmake 里也定义了同名目标，而那份要 adb 的
# 几棵树 —— simpleperf 不该依赖「adb 先编过」，所以这里自己定义，重复时让路。
if(NOT TARGET libzstd)
    file(GLOB SP_ZSTD_SRCS ${SRC}/zstd/lib/*/*.c)
    list(LENGTH SP_ZSTD_SRCS SP_ZSTD_N)
    if(SP_ZSTD_N LESS 30)
        message(FATAL_ERROR "zstd 只 glob 到 ${SP_ZSTD_N} 个源文件，源码树不完整？")
    endif()
    add_library(libzstd STATIC ${SP_ZSTD_SRCS})
    target_include_directories(libzstd PUBLIC ${SRC}/zstd/lib PRIVATE ${SRC}/zstd/lib/common)
    target_compile_definitions(libzstd PRIVATE ZSTD_HAVE_WEAK_SYMBOLS=0 ZSTD_TRACE=0)
endif()

# ---------------------------------------------------------------- -llog 从哪来
# protobuf 的 CMake 在 Android 上给自己加了 `log`（链接行上就是 -llog）。
# 我们整棵树是 **-static** 链的，而 NDK sysroot 里只有 liblog.so 没有 .a，
# 于是 `unable to find library -llog`。
#
# 试过 add_library(log ALIAS liblog)：**不行**。protobuf 有 install(EXPORT)，
# CMake 会报「libprotobuf-lite 依赖的 liblog 不在任何 export set 里」。
# 起 IMPORTED 目标同理会绕到别的坑上。
#
# 所以走最直白的一条：在链接路径上摆一个名叫 liblog.a 的软链，指向上游
# 那份静态 liblog。配置期它是断的（那时还没编出来），链接期一定在 ——
# 因为 simpleperf 同时显式链了 liblog 这个 target，ninja 会先把它编出来。
set(SP_LINKDIR ${CMAKE_CURRENT_BINARY_DIR}/sp-link)
file(MAKE_DIRECTORY ${SP_LINKDIR})
file(CREATE_LINK ${CMAKE_BINARY_DIR}/lib/libliblog.a ${SP_LINKDIR}/liblog.a SYMBOLIC)

# ---------------------------------------------------------------- libasync_safe
set(BIONIC ${SRC}/bionic)
add_library(libasync_safe STATIC ${BIONIC}/libc/async_safe/async_safe_log.cpp)
target_include_directories(libasync_safe PUBLIC ${BIONIC}/libc/async_safe/include
    PRIVATE ${BIONIC}/libc ${BIONIC}/libc/platform ${BIONIC}/libc/private)

# ---------------------------------------------------------------- libdexfile_support
set(ART ${SRC}/art)
add_library(libdexfile_support STATIC ${ART}/libdexfile/external/dex_file_supp.cc)
target_include_directories(libdexfile_support PUBLIC ${ART}/libdexfile/external/include
    PRIVATE ${SRC}/logging/liblog/include)
target_link_libraries(libdexfile_support liblog)

# ---------------------------------------------------------------- libunwindstack
set(UNW ${SRC}/unwinding/libunwindstack)
add_library(libunwindstack STATIC
    ${UNW}/AndroidUnwinder.cpp
    ${UNW}/ArmExidx.cpp
    ${UNW}/Demangle.cpp
    ${UNW}/DexFiles.cpp
    ${UNW}/DwarfCfa.cpp
    ${UNW}/DwarfEhFrameWithHdr.cpp
    ${UNW}/DwarfMemory.cpp
    ${UNW}/DwarfOp.cpp
    ${UNW}/DwarfSection.cpp
    ${UNW}/Elf.cpp
    ${UNW}/ElfInterface.cpp
    ${UNW}/ElfInterfaceArm.cpp
    ${UNW}/Global.cpp
    ${UNW}/JitDebug.cpp
    ${UNW}/MapInfo.cpp
    ${UNW}/Maps.cpp
    ${UNW}/Memory.cpp
    ${UNW}/MemoryMte.cpp
    ${UNW}/MemoryXz.cpp
    ${UNW}/Regs.cpp
    ${UNW}/RegsArm.cpp
    ${UNW}/RegsArm64.cpp
    ${UNW}/RegsX86.cpp
    ${UNW}/RegsX86_64.cpp
    ${UNW}/RegsRiscv64.cpp
    ${UNW}/Symbols.cpp
    ${UNW}/ThreadEntry.cpp
    ${UNW}/ThreadUnwinder.cpp
    ${UNW}/Unwinder.cpp
    ${UNW}/DexFile.cpp
    ${UNW}/LogAndroid.cpp
    )
target_include_directories(libunwindstack PUBLIC ${UNW}/include
    PRIVATE ${UNW} ${SRC}/libbase/include ${SRC}/logging/liblog/include
            ${SRC}/core/libcutils/include ${SRC}/lzma/C
            # rustc_demangle.h 在 capi 那个 crate 的 include/ 里（Demangle.cpp 要）
            ${SRC}/rustc-demangle-capi/include
            # bionic/reserved_signals.h 在 libc/platform 底下（AndroidUnwinder.cpp 要）
            ${SRC}/bionic/libc/platform)
target_compile_definitions(libunwindstack PRIVATE DEXFILE_SUPPORT)
# -Werror 不带（理由见 cmake/zipalign.cmake）。-Wno-* 照抄 libunwindstack_flags。
target_compile_options(libunwindstack PRIVATE -Wno-deprecated-volatile -Wno-reorder-init-list)
target_link_libraries(libunwindstack
    libprocinfo liblzma libdexfile_support libasync_safe libzstd libbase liblog
    ${SP_RUSTC_DEMANGLE})

# ---------------------------------------------------------------- libsimpleperf
set(SP ${SRC}/extras/simpleperf)

# cc_defaults "simpleperf_cflags" 的 host 那一支，逐条照抄：
#     cflags: ["-DUSE_BIONIC_UAPI_HEADERS", "-fvisibility=hidden"]
#     include_dirs: ["bionic/libc/kernel"]
# **套这组 defaults 的不止 libsimpleperf**，libsimpleperf_etm_decoder 也套
# （ETMDecoder.cpp 间接 include perf_regs.h）。头一版只给了 libsimpleperf，
# 结果 etm_decoder 走进 perf_regs.h 的 #else 分支去找 <asm-arm/...>，
# 那条路径是给不带 uapi 前缀的树用的，我们这棵没有 —— 报「文件不存在」。
# 抽成变量就不会再漏一个。
set(SP_CFLAGS_DEFINES USE_BIONIC_UAPI_HEADERS)
set(SP_CFLAGS_INCLUDE ${SRC}/bionic/libc/kernel)

# genrule simpleperf_event_table：Android.bp 里是
#     cmd: "$(location event_table_generator) $(in) $(out)"
# 那个 tool 就是同目录的 event_table_generator.py。生成到 build 目录，
# **不往源码树里写**（理由见 cmake/adb.cmake 里那段）。
set(SP_GEN ${CMAKE_CURRENT_BINARY_DIR}/simpleperf-gen)
file(MAKE_DIRECTORY ${SP_GEN})
add_custom_command(
    OUTPUT ${SP_GEN}/event_table.cpp
    COMMAND ${SP_PYTHON} ${SP}/event_table_generator.py ${SP}/event_table.json ${SP_GEN}/event_table.cpp
    DEPENDS ${SP}/event_table_generator.py ${SP}/event_table.json
    COMMENT "生成 event_table.cpp（照 Android.bp 的 genrule simpleperf_event_table）")

# 三个 .proto，proto.type 是 lite（见 libsimpleperf 那个模块）
sp_gen_pb(SP_PROTOS_SRC cmd_report_sample.proto branch_list.proto record_file.proto)

add_library(libsimpleperf STATIC
    ${SP}/cmd_dumprecord.cpp
    ${SP}/cmd_help.cpp
    ${SP}/cmd_inject.cpp
    ${SP}/cmd_kmem.cpp
    ${SP}/cmd_merge.cpp
    ${SP}/cmd_report.cpp
    ${SP}/cmd_report_sample.cpp
    ${SP}/command.cpp
    ${SP}/dso.cpp
    ${SP}/BranchListFile.cpp
    ${SP}/event_attr.cpp
    ${SP}/event_type.cpp
    ${SP}/kallsyms.cpp
    ${SP}/perf_regs.cpp
    ${SP}/read_apk.cpp
    ${SP}/read_elf.cpp
    ${SP}/read_symbol_map.cpp
    ${SP}/record.cpp
    ${SP}/RecordFilter.cpp
    ${SP}/record_file_reader.cpp
    ${SP}/record_file_writer.cpp
    ${SP}/report_utils.cpp
    ${SP}/thread_tree.cpp
    ${SP}/tracing.cpp
    ${SP}/utils.cpp
    ${SP}/ZstdUtil.cpp
    ${SP}/CallChainJoiner.cpp
    ${SP}/cmd_api.cpp
    ${SP}/cmd_debug_unwind.cpp
    ${SP}/cmd_list.cpp
    ${SP}/cmd_monitor.cpp
    ${SP}/cmd_record.cpp
    ${SP}/cmd_stat.cpp
    ${SP}/cmd_trace_sched.cpp
    ${SP}/environment.cpp
    ${SP}/ETMRecorder.cpp
    ${SP}/event_fd.cpp
    ${SP}/event_selection_set.cpp
    ${SP}/IOEventLoop.cpp
    ${SP}/JITDebugReader.cpp
    ${SP}/MapRecordReader.cpp
    ${SP}/OfflineUnwinder.cpp
    ${SP}/ProbeEvents.cpp
    ${SP}/read_dex_file.cpp
    ${SP}/RecordReadThread.cpp
    ${SP}/workload.cpp
    ${SP}/cmd_boot_record.cpp   # android 那支，理由见本文件开头
    ${SP_GEN}/event_table.cpp
    ${SP_PROTOS_SRC}
    )
# main.cpp 在 AOSP 里跟 libsimpleperf 套同一组 defaults，所以 include 也一样。
# 抽成变量，免得两边各写一份、然后一个一个「file not found」地补。
set(SP_INCLUDES
    ${SP_GEN} ${SP_PB_DIR}
            ${SRC}/libbase/include ${SRC}/logging/liblog/include
            ${SRC}/core/libcutils/include ${SRC}/core/include
            ${SRC}/libziparchive/include ${SRC}/native/libs/utils/include
            ${SRC}/unwinding/libunwindstack/include
            ${SRC}/OpenCSD/decoder/include
            ${SRC}/lzma/C ${SRC}/libevent/include ${SRC}/libprocinfo/include
            ${SRC}/art/libdexfile/external/include
            # libbuildversion（bp 里 libsimpleperf 的 static_libs 就写着它）
            ${SRC}/soong/cc/libbuildversion/include
            # gtest_prod.h：只是 FRIEND_TEST 宏，源码里无条件 include，
            # 不链 gtest 也要这个头
            ${SRC}/googletest/googletest/include
            ${SP_CFLAGS_INCLUDE}
            ${SP_LLVM_INCLUDE}
    )

target_include_directories(libsimpleperf PUBLIC ${SP} PRIVATE ${SP_INCLUDES})
target_compile_definitions(libsimpleperf PRIVATE ${SP_CFLAGS_DEFINES})
target_compile_options(libsimpleperf PRIVATE -fvisibility=hidden -Wno-unused-parameter)
target_link_libraries(libsimpleperf
    libsimpleperf_etm_decoder libsimpleperf_regex
    libbase liblog liblzma libutils libprotobuf-lite libopencsd_decoder
    libziparchive libzstd libunwindstack libcutils libprocinfo libevent
    libdexfile_support libbuildversion ${SP_RUSTC_DEMANGLE} ${SP_LLVM_LIBS})

# ---------------------------------------------------------------- 两个小库
add_library(libsimpleperf_regex STATIC ${SP}/RegEx.cpp)
target_include_directories(libsimpleperf_regex PUBLIC ${SP} PRIVATE ${SRC}/libbase/include)
target_compile_options(libsimpleperf_regex PRIVATE -fexceptions)

add_library(libsimpleperf_etm_decoder STATIC ${SP}/ETMDecoder.cpp)
target_include_directories(libsimpleperf_etm_decoder PUBLIC ${SP}
    PRIVATE ${SRC}/OpenCSD/decoder/include ${SRC}/libbase/include
            ${SRC}/logging/liblog/include ${SRC}/unwinding/libunwindstack/include
            ${SP_CFLAGS_INCLUDE} ${SP_LLVM_INCLUDE})
target_compile_definitions(libsimpleperf_etm_decoder PRIVATE ${SP_CFLAGS_DEFINES})
target_compile_options(libsimpleperf_etm_decoder PRIVATE
    -Wno-ignored-qualifiers -Wno-unused-parameter -Wno-switch
    -Wno-unused-private-field -Wno-implicit-fallthrough -fexceptions)
target_link_libraries(libsimpleperf_etm_decoder libopencsd_decoder libbase liblog)

# ---------------------------------------------------------------- simpleperf
add_executable(simpleperf ${SP}/main.cpp)
# main.cpp 自己也要几个头（libsimpleperf 那堆 include 是 PRIVATE，不外传）
target_include_directories(simpleperf PRIVATE ${SP} ${SP_INCLUDES})
target_compile_definitions(simpleperf PRIVATE ${SP_CFLAGS_DEFINES})
target_link_directories(simpleperf PRIVATE ${SP_LINKDIR})
# z：ziparchive/protobuf 那边要 zlib（NDK sysroot 里有 libz.a）
# dl：libdexfile_support 运行时 dlopen libdexfile
target_link_libraries(simpleperf libsimpleperf liblog z dl)
