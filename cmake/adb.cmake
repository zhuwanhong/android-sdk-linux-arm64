#
# adb 仓库自己的十个库 + 四组 protoc 代码生成。
#
# **必须在 cmake/adb-deps.cmake 之后 include**（要它的 libusb / libmdnssd /
# libcrypto_utils / libopenscreen-*）。
#
# 依赖清单照 packages/modules/adb 各处的 Android.bp：
#   Android.bp                     libadb_host libadb_sysdeps libfastdeploy_host
#   proto/Android.bp               libadb_protos libadb_host_protos
#                                  libapp_processes_protos_full
#   crypto/Android.bp              libadb_crypto
#   tls/Android.bp                 libadb_tls_connection
#   pairing_auth/Android.bp        libadb_pairing_auth
#   pairing_connection/Android.bp  libadb_pairing_connection
#
# adb_defaults 的 cflags 逐条抄过来，只去掉 -Werror（理由见 cmake/zipalign.cmake）。
# 其中两个 -D 不能漏：
#   ADB_HOST=1                                       决定编的是 client 还是 daemon
#   ANDROID_BASE_UNIQUE_FD_DISABLE_IMPLICIT_CONVERSION=1  少了它 libbase 的
#                                                    unique_fd 会隐式转成 int，
#                                                    adb 的代码是按「不能隐式转」写的
#

set(ADB ${SRC}/adb)

# 每个目标都要的 include 列表。**上游的 libbase / libcutils 等目标把 include
# 声明成 PRIVATE**，不会往下传，所以跟 cmake/fastboot.cmake 一样，这里自己列全。
# 少一条的症状是 `'android-base/logging.h' file not found` —— 第一版就是这么红的。
set(ADB_INCLUDES
    ${ADB}                                  # adb.h / sysdeps.h 等，源码里是 <adb.h>
    ${ADB}/crypto/include
    ${ADB}/pairing_auth/include
    ${ADB}/pairing_connection/include
    ${ADB}/tls/include
    ${CMAKE_SOURCE_DIR}/misc                # platform_tools_version.h
    ${SRC}/core/include
    ${SRC}/core/libcutils/include
    ${SRC}/core/libutils/include
    ${SRC}/core/diagnose_usb/include
    ${SRC}/core/libcrypto_utils/include
    ${SRC}/libbase/include
    ${SRC}/libziparchive/include
    ${SRC}/logging/liblog/include
    ${SRC}/boringssl/include
    ${SRC}/fmtlib/include                   # libbase 用 fmtlib
    ${SRC}/protobuf/src
    ${SRC}/mdnsresponder/mDNSShared
    ${SRC}/libusb                           # client/usb_libusb.cpp 写的是 <libusb/libusb.h>
    ${SRC}/libusb/libusb
    ${SRC}/libusb/android
    ${SRC}/openscreen
    ${SRC}/openscreen/third_party/abseil/src
    ${SRC}/base/libs/androidfw/include      # libandroidfw（libfastdeploy_host 要）
    ${SRC}/lz4/lib
    ${SRC}/brotli/c/include
    ${SRC}/zstd/lib
    ${SRC}/soong/cc/libbuildversion/include # adb.cpp 的 #include <build/version.h>
    ${SRC}/googletest/googletest/include    # zip_writer.h 里 #include <gtest/gtest_prod.h>
                                            # （跟 cmake/fastboot.cmake 那条同一个原因）
    )

set(ADB_CFLAGS
    -Wall -Wextra -Wexit-time-destructors -Wno-non-virtual-dtor
    -Wno-unused-parameter -Wno-missing-field-initializers -Wthread-safety -Wvla)

# **-fno-exceptions 不是为了消掉一个报错，是 ABI 上必须跟 openscreen 一致。**
#
# openscreen 的 platform/api/task_runner.h:26 是这样写的：
#
#     // Seem to get an error using clang when compiling with -fno-exceptions:
#     //   error: implicit instantiation of undefined template
#     //          'std::__1::packaged_task<void () noexcept>'
#     #if __has_feature(cxx_exceptions)
#       using Task = std::packaged_task<void() noexcept>;
#     #else
#       using Task = std::packaged_task<void()>;
#     #endif
#
# 也就是 TaskRunner::Task **是什么类型，取决于编译时开没开异常**。
# openscreen_defaults 里带着 -fno-exceptions，所以 libopenscreen-* 编出来的是
# 后一个；而 adb 的 client/openscreen/platform/task_runner.cpp 实现了那个接口，
# 编它的是 adb 自己这组 flag。NDK 的 cmake 工具链默认开异常，于是两边的
# Task 变成了两个不同的类型。
#
# 第一版就是这么红的（libc++ 没有 noexcept 那个特化）。**红在这里是运气好** ——
# 要是 libc++ 恰好有那个特化，两边就会各自编过，然后在链接期悄悄拼出一个
# 虚函数签名对不上的 vtable。AOSP 那边不会撞到，因为 Soong 编 C++ 默认就
# -fno-exceptions。
list(APPEND ADB_CFLAGS $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions>)
set(ADB_DEFS
    ADB_HOST=1
    ANDROID_BASE_UNIQUE_FD_DISABLE_IMPLICIT_CONVERSION=1
    _FILE_OFFSET_BITS=64)

# ---------------------------------------------------------------------------
# protoc 代码生成
#
# 跟 cmake/aapt2.cmake 一样在**配置期**跑 protoc（所以 --fetch 那步就要有 protoc，
# 见 tools/build-common.sh 的 common_need_protoc）。跟那边不同的是**生成到
# build 目录**，不往源码树里写 —— 源码树是 git 检出的，往里写生成物，下次
# --fetch 的哨兵判断和 git status 都会变得不可信。
#
# lite 还是 full 照 Android.bp 的 proto.type：
#   libadb_protos                 lite
#   libapp_processes_protos_full  full
#   libadb_host_protos            full
#   libfastdeploy_host 的 ApkEntry lite
# 混用没问题：full 运行时包含 lite 那一半，而 adb 链的是 libprotobuf-cpp-full。
set(ADB_PB_DIR ${CMAKE_CURRENT_BINARY_DIR}/adb-proto)
file(MAKE_DIRECTORY ${ADB_PB_DIR})

# gen_pb(<变量名> <lite|full> <proto 所在目录> <proto 文件名>...)
function(gen_pb OUTVAR MODE PROTO_DIR)
    set(_out "")
    foreach(p ${ARGN})
        get_filename_component(base ${p} NAME_WE)
        # **生成物要保留 proto 相对 --proto_path 的目录结构**，因为源码是按那个
        # 路径 include 的：fastdeploy 那几个 .h 写的是
        # <fastdeploy/proto/ApkEntry.pb.h>，不是 <ApkEntry.pb.h>。
        # protoc 自己会建子目录，我们只要按同样的规则算出文件名。
        get_filename_component(sub ${p} DIRECTORY)
        if(sub STREQUAL "")
            set(cc ${ADB_PB_DIR}/${base}.pb.cc)
        else()
            set(cc ${ADB_PB_DIR}/${sub}/${base}.pb.cc)
        endif()
        if(${MODE} STREQUAL lite)
            set(cpp_out "lite:${ADB_PB_DIR}")
        else()
            set(cpp_out "${ADB_PB_DIR}")
        endif()
        execute_process(
            COMMAND ${Protobuf_PROTOC_EXECUTABLE} ${p}
                    --proto_path=${PROTO_DIR} --cpp_out=${cpp_out}
            RESULT_VARIABLE rc WORKING_DIRECTORY ${PROTO_DIR})
        if(NOT rc EQUAL 0)
            message(FATAL_ERROR "protoc 生成 ${p} 失败（rc=${rc}）")
        endif()
        if(NOT EXISTS ${cc})
            message(FATAL_ERROR "protoc 说成功了，但 ${cc} 不在")
        endif()
        list(APPEND _out ${cc})
    endforeach()
    set(${OUTVAR} ${_out} PARENT_SCOPE)
endfunction()

gen_pb(ADB_PROTOS_SRC      lite ${ADB}/proto adb_known_hosts.proto key_type.proto pairing.proto)
gen_pb(APP_PROC_PROTOS_SRC full ${ADB}/proto app_processes.proto)
gen_pb(ADB_HOST_PROTOS_SRC full ${ADB}/proto adb_host.proto)
# proto_path 给 adb 根目录、文件名带上相对路径 —— 这样生成出来的头文件在
# ${ADB_PB_DIR}/fastdeploy/proto/ 底下，跟源码的 #include 对得上。
gen_pb(FASTDEPLOY_PB_SRC   lite ${ADB} fastdeploy/proto/ApkEntry.proto)

add_library(libadb_protos STATIC ${ADB_PROTOS_SRC})
target_include_directories(libadb_protos PUBLIC ${ADB_PB_DIR} ${ADB_INCLUDES})
target_link_libraries(libadb_protos libprotobuf)

add_library(libapp_processes_protos_full STATIC ${APP_PROC_PROTOS_SRC})
target_include_directories(libapp_processes_protos_full PUBLIC ${ADB_PB_DIR} ${ADB_INCLUDES})
target_link_libraries(libapp_processes_protos_full libprotobuf)

add_library(libadb_host_protos STATIC ${ADB_HOST_PROTOS_SRC})
target_include_directories(libadb_host_protos PUBLIC ${ADB_PB_DIR} ${ADB_INCLUDES})
target_link_libraries(libadb_host_protos libprotobuf)

# ---------------------------------------------------------------------------
# libadb_sysdeps —— Android.bp，export_include_dirs 是 adb 根目录
add_library(libadb_sysdeps STATIC ${ADB}/sysdeps/env.cpp)
target_include_directories(libadb_sysdeps PUBLIC ${ADB} ${ADB_INCLUDES})
target_compile_definitions(libadb_sysdeps PRIVATE ${ADB_DEFS})
target_compile_options(libadb_sysdeps PRIVATE ${ADB_CFLAGS})
target_link_libraries(libadb_sysdeps libbase liblog)

# ---------------------------------------------------------------------------
# libadb_crypto —— crypto/Android.bp
add_library(libadb_crypto STATIC
    ${ADB}/crypto/key.cpp
    ${ADB}/crypto/rsa_2048_key.cpp
    ${ADB}/crypto/x509_generator.cpp
    )
target_include_directories(libadb_crypto PUBLIC ${ADB}/crypto/include PRIVATE ${ADB} ${ADB_INCLUDES})
target_compile_definitions(libadb_crypto PRIVATE ${ADB_DEFS})
target_compile_options(libadb_crypto PRIVATE ${ADB_CFLAGS})
target_link_libraries(libadb_crypto libadb_protos libadb_sysdeps libbase liblog crypto libcrypto_utils)

# ---------------------------------------------------------------------------
# libadb_tls_connection —— tls/Android.bp
add_library(libadb_tls_connection STATIC
    ${ADB}/tls/adb_ca_list.cpp
    ${ADB}/tls/tls_connection.cpp
    )
target_include_directories(libadb_tls_connection PUBLIC ${ADB}/tls/include PRIVATE ${ADB} ${ADB_INCLUDES})
target_compile_definitions(libadb_tls_connection PRIVATE ${ADB_DEFS})
target_compile_options(libadb_tls_connection PRIVATE ${ADB_CFLAGS})
target_link_libraries(libadb_tls_connection libbase crypto liblog ssl)

# ---------------------------------------------------------------------------
# libadb_pairing_auth —— pairing_auth/Android.bp
#
# Android.bp 里有 version_script（.map.txt）—— 那是给**共享库**导出符号表用的。
# 我们全静态，用不上，不带。
add_library(libadb_pairing_auth STATIC
    ${ADB}/pairing_auth/aes_128_gcm.cpp
    ${ADB}/pairing_auth/pairing_auth.cpp
    )
target_include_directories(libadb_pairing_auth PUBLIC ${ADB}/pairing_auth/include PRIVATE ${ADB} ${ADB_INCLUDES})
target_compile_definitions(libadb_pairing_auth PRIVATE ${ADB_DEFS})
target_compile_options(libadb_pairing_auth PRIVATE ${ADB_CFLAGS})
target_link_libraries(libadb_pairing_auth libbase crypto liblog)

# ---------------------------------------------------------------------------
# libadb_pairing_connection —— pairing_connection/Android.bp
add_library(libadb_pairing_connection STATIC
    ${ADB}/pairing_connection/pairing_connection.cpp
    )
target_include_directories(libadb_pairing_connection
    PUBLIC ${ADB}/pairing_connection/include PRIVATE ${ADB} ${ADB_INCLUDES})
target_compile_definitions(libadb_pairing_connection PRIVATE ${ADB_DEFS})
target_compile_options(libadb_pairing_connection PRIVATE ${ADB_CFLAGS})
target_link_libraries(libadb_pairing_connection
    libadb_protos libadb_tls_connection libadb_pairing_auth libbase ssl crypto liblog libprotobuf)

# ---------------------------------------------------------------------------
# libadb_host —— Android.bp 的 libadb_host
#
# srcs = libadb_srcs(16) + client/ 那 14 个 + target.linux 的
# （client/usb_linux.cpp 和 libadb_linux_srcs 的 fdevent_epoll.cpp）
# + target.not_windows 的 libadb_posix_srcs（2 个）。
#
# generated_headers: platform_tools_version —— 上游那棵树里已经有现成的
# misc/platform_tools_version.h（写着 PLATFORM_TOOLS_VERSION "35.0.2"），
# 不用自己生成，把 misc/ 加进 include 路径就行。
add_library(libadb_host STATIC
    # libadb_srcs
    ${ADB}/adb.cpp
    ${ADB}/adb_io.cpp
    ${ADB}/adb_listeners.cpp
    ${ADB}/adb_mdns.cpp
    ${ADB}/adb_trace.cpp
    ${ADB}/adb_unique_fd.cpp
    ${ADB}/adb_utils.cpp
    ${ADB}/fdevent/fdevent.cpp
    ${ADB}/services.cpp
    ${ADB}/sockets.cpp
    ${ADB}/socket_spec.cpp
    ${ADB}/sysdeps/env.cpp
    ${ADB}/sysdeps/errno.cpp
    ${ADB}/transport.cpp
    ${ADB}/transport_fd.cpp
    ${ADB}/types.cpp
    # libadb_host 自己加的
    ${ADB}/client/openscreen/mdns_service_info.cpp
    ${ADB}/client/openscreen/mdns_service_watcher.cpp
    ${ADB}/client/openscreen/platform/logging.cpp
    ${ADB}/client/openscreen/platform/task_runner.cpp
    ${ADB}/client/openscreen/platform/udp_socket.cpp
    ${ADB}/client/auth.cpp
    ${ADB}/client/adb_wifi.cpp
    ${ADB}/client/usb_libusb.cpp
    ${ADB}/client/transport_local.cpp
    ${ADB}/client/mdnsresponder_client.cpp
    ${ADB}/client/mdns_utils.cpp
    ${ADB}/client/transport_mdns.cpp
    ${ADB}/client/transport_usb.cpp
    ${ADB}/client/pairing/pairing_client.cpp
    # target.linux
    ${ADB}/client/usb_linux.cpp
    ${ADB}/fdevent/fdevent_epoll.cpp
    # target.not_windows（libadb_posix_srcs）
    ${ADB}/sysdeps_unix.cpp
    ${ADB}/sysdeps/posix/network.cpp
    )
target_include_directories(libadb_host PUBLIC ${ADB} PRIVATE ${CMAKE_SOURCE_DIR}/misc ${ADB_INCLUDES})
target_compile_definitions(libadb_host PRIVATE ${ADB_DEFS})
target_compile_options(libadb_host PRIVATE ${ADB_CFLAGS})
# Android.bp 的 static_libs 里没写 libbuildversion，但 adb.cpp 直接
# #include <build/version.h> 调 build::GetBuildNumber() —— 在 Soong 那边它由
# cc_defaults 的 use_version_lib 隐式带进来（libadb_sysdeps 那条注释
# "This library doesn't use build::GetBuildNumber()" 就是在说这件事）。
# 跟 fastboot 一样，这个构建号我们是空的，属于第五节第 6 条那张表里的「运行环境」。
target_link_libraries(libadb_host
    libadb_crypto libadb_host_protos libadb_pairing_connection libadb_protos
    libadb_tls_connection libbase crypto libcrypto_utils libcutils libdiagnose_usb
    liblog libmdnssd libopenscreen-discovery libopenscreen-platform-impl
    libprotobuf libusb libutils libbuildversion)

# ---------------------------------------------------------------------------
# libfastdeploy_host —— Android.bp
#
# srcs 里那个 fastdeploy/proto/ApkEntry.proto 是 Soong 的写法：把 .proto 直接
# 列进 srcs，它自己去生成。我们上面已经生成好了，这里用生成出来的 .pb.cc。
add_library(libfastdeploy_host STATIC
    ${ADB}/fastdeploy/deploypatchgenerator/apk_archive.cpp
    ${ADB}/fastdeploy/deploypatchgenerator/deploy_patch_generator.cpp
    ${ADB}/fastdeploy/deploypatchgenerator/patch_utils.cpp
    ${FASTDEPLOY_PB_SRC}
    )
target_include_directories(libfastdeploy_host PUBLIC ${ADB} ${ADB_PB_DIR} ${ADB_INCLUDES})
target_compile_definitions(libfastdeploy_host PRIVATE ${ADB_DEFS})
target_compile_options(libfastdeploy_host PRIVATE ${ADB_CFLAGS})
target_link_libraries(libfastdeploy_host
    libadb_host libandroidfw libbase crypto libcrypto_utils libcutils
    libdiagnose_usb liblog libmdnssd libusb libutils z libziparchive libprotobuf)

# ---------------------------------------------------------------------------
# adb 本身 —— Android.bp 的 cc_binary_host{name:"adb"} + adb_binary_host_defaults
#
# generated_headers 那两项（bin2c_fastdeployagent / bin2c_fastdeployagentscript）
# 由 tools/gen-deployagent.sh 生成到 ${CMAKE_BINARY_DIR}/adb-gen/，
# client/fastdeploy.cpp 里是 #include "deployagent.inc"，所以那个目录要在
# include 路径上。**cmake 不负责生成它们** —— 里面要跑 protoc/javac/d8，
# 是个 Java 子构建，放脚本里比塞进 cmake 清楚。
# 没跑那个脚本就编，会在 fastdeploy.cpp 上报 'deployagent.inc' file not found，
# 是条清楚的错，不会静悄悄编出一个没有 agent 的 adb。
add_executable(adb
    ${ADB}/client/adb_client.cpp
    ${ADB}/client/bugreport.cpp
    ${ADB}/client/commandline.cpp
    ${ADB}/client/file_sync_client.cpp
    ${ADB}/client/main.cpp
    ${ADB}/client/console.cpp
    ${ADB}/client/adb_install.cpp
    ${ADB}/client/line_printer.cpp
    ${ADB}/client/fastdeploy.cpp
    ${ADB}/client/fastdeploycallbacks.cpp
    ${ADB}/client/incremental.cpp
    ${ADB}/client/incremental_server.cpp
    ${ADB}/client/incremental_utils.cpp
    ${ADB}/shell_service_protocol.cpp
    )
target_include_directories(adb PRIVATE ${CMAKE_BINARY_DIR}/adb-gen ${ADB_INCLUDES})
target_compile_definitions(adb PRIVATE ${ADB_DEFS})
target_compile_options(adb PRIVATE ${ADB_CFLAGS})
# static_libs 那 30 项（liblog 重复一次）逐条对过来。名字不一样的三个：
#   libcrypto            -> crypto              （上游 add_subdirectory 的 boringssl）
#   libssl               -> ssl                 （同上）
#   libprotobuf-cpp-full -> libprotobuf         （上游 add_subdirectory 的 protobuf）
# 另加 fmt::fmt 和 c++_static：libbase 用 fmtlib，全静态链要显式带上
# （跟 cmake/fastboot.cmake 一样）。
target_link_libraries(adb
    libadb_crypto
    libadb_host
    libadb_host_protos
    libadb_pairing_auth
    libadb_pairing_connection
    libadb_protos
    libadb_sysdeps
    libadb_tls_connection
    libandroidfw
    libapp_processes_protos_full
    libbase
    libbrotli
    crypto
    libcrypto_utils
    libcutils
    libdiagnose_usb
    libfastdeploy_host
    liblog
    liblz4
    libmdnssd
    libopenscreen-discovery
    libopenscreen-platform-impl
    libprotobuf
    ssl
    libusb
    libutils
    z
    libziparchive
    libzstd
    libbuildversion
    # Android.bp 的 static_libs 里没有 libincfs，但链接期少
    # android::incfs::IncFsFileMap::Verify —— client/incremental_utils.cpp 用的。
    # 在 Soong 那边它由 libandroidfw 的依赖带进来；上游这套 cmake 里
    # libandroidfw 只 PUBLIC 了 fmt::fmt，libincfs 得自己显式加。
    libincfs
    fmt::fmt
    c++_static
    )
target_link_options(adb PRIVATE "-Wl,-z,max-page-size=16384")
