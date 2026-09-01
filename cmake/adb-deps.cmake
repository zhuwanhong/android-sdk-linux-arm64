#
# adb 的第三方依赖：六个要自己照 Android.bp 写的目标。
#
# adb 的 static_libs 有 29 项，分五类（详见 README 第四节 M3）：
#   8 个已经有目标        libbase libcutils liblog libutils libziparchive
#                         libandroidfw libdiagnose_usb liblz4
#   3 个上游 cmake 在编   libcrypto->crypto、libssl->ssl、
#                         libprotobuf-cpp-full->libprotobuf
#                         （顶层 CMakeLists.txt 就 add_subdirectory 了
#                           submodules/boringssl 和 submodules/protobuf）
#   2 个第三方自带 CMake  libbrotli（顶层 CMakeLists.txt）、libzstd（build/cmake）
#   **6 个在这个文件里**
#   10 个 adb 仓库自己的  在 cmake/adb.cmake
#
# 每个目标的依赖清单**照抄该库自己的 Android.bp**，不抄别人的 CMake。
# -Werror 一律不带，理由见 cmake/zipalign.cmake。
#

# ---------------------------------------------------------------------------
# libcrypto_utils —— system/core/libcrypto_utils/Android.bp
#
# 一个源文件。它是 adb 校验设备公钥用的（android_pubkey）。
# Android.bp 里 shared_libs 是 libcrypto —— 就是 boringssl，上游那套 cmake
# 里叫 crypto。
add_library(libcrypto_utils STATIC
    ${SRC}/core/libcrypto_utils/android_pubkey.cpp
    )
target_include_directories(libcrypto_utils PUBLIC ${SRC}/core/libcrypto_utils/include)
target_link_libraries(libcrypto_utils crypto)
target_compile_options(libcrypto_utils PRIVATE -Wall -Wextra)

# ---------------------------------------------------------------------------
# libusb —— external/libusb/Android.bp
#
# 六个通用源文件 + target.linux 的四个。**Soong 的 target.linux 覆盖 android**，
# 所以编 Android ABI 时这四个要带上（events_posix / linux_usbfs /
# threads_posix / linux_netlink）。
#
# include 目录三个：libusb、libusb/os 来自 local_include_dirs，
# android/ 来自 target.android.local_include_dirs —— 那里面是 config.h，
# 少了它编不过。
add_library(libusb STATIC
    ${SRC}/libusb/libusb/core.c
    ${SRC}/libusb/libusb/descriptor.c
    ${SRC}/libusb/libusb/hotplug.c
    ${SRC}/libusb/libusb/io.c
    ${SRC}/libusb/libusb/sync.c
    ${SRC}/libusb/libusb/strerror.c
    ${SRC}/libusb/libusb/os/events_posix.c
    ${SRC}/libusb/libusb/os/linux_usbfs.c
    ${SRC}/libusb/libusb/os/threads_posix.c
    ${SRC}/libusb/libusb/os/linux_netlink.c
    )
target_include_directories(libusb PUBLIC
    ${SRC}/libusb/libusb
    ${SRC}/libusb/libusb/os
    ${SRC}/libusb/android          # config.h 在这儿
    )
target_compile_definitions(libusb PRIVATE ENABLE_LOGGING=1)
target_compile_options(libusb PRIVATE
    -Wall -Wno-error=sign-compare -Wno-error=switch
    -Wno-error=unused-function -Wno-unused-parameter)

# ---------------------------------------------------------------------------
# libmdnssd —— external/mdnsresponder/Android.bp
#
# 三个源文件（客户端那半，不是 mdnsd 守护进程）。cflags 抄
# mdnsresponder_default_cflags。Android.bp 里 static_libs 是 libcutils、
# shared_libs 是 liblog —— 我们全静态，两个都当静态链。
add_library(libmdnssd STATIC
    ${SRC}/mdnsresponder/mDNSShared/dnssd_clientlib.c
    ${SRC}/mdnsresponder/mDNSShared/dnssd_clientstub.c
    ${SRC}/mdnsresponder/mDNSShared/dnssd_ipc.c
    )
target_include_directories(libmdnssd PUBLIC ${SRC}/mdnsresponder/mDNSShared)
target_compile_definitions(libmdnssd PRIVATE
    _GNU_SOURCE
    HAVE_IPV6
    NOT_HAVE_SA_LEN
    PLATFORM_NO_RLIMIT
    MDNS_DEBUGMSGS=0
    MDNS_UDS_SERVERPATH="/dev/socket/mdnsd"
    MDNS_USERNAME="mdnsr"
    )
target_compile_options(libmdnssd PRIVATE
    -O2 -fno-strict-aliasing -fwrapv -W -Wall -Wextra
    -Wno-address-of-packed-member -Wno-array-bounds -Wno-pointer-sign
    -Wno-unused -Wno-unused-but-set-variable -Wno-unused-parameter)
target_link_libraries(libmdnssd libcutils liblog)

# ---------------------------------------------------------------------------
# openscreen 三个目标 —— external/openscreen/Android.bp
#
# **abseil 不需要第六棵树**：源码就在 openscreen/third_party/abseil/src/，
# 而且 Android.bp 里只挑了 22 个 .cc（它是从 openscreen 的
# third_party/abseil/BUILD.gn 抄过去的一个子集，不是整个 abseil）。
#
# openscreen_defaults 里那条
#     -DOPENSCREEN_TEST_DATA_DIR="$ANDROID_BUILD_TOP/external/openscreen/test/data/"
# **故意不带**：它只有测试用得上，而且里面是 Soong 的环境变量。
# 万一有非测试代码引用它，编译期会报「未定义」直接红，不会静悄悄错。
set(OSP_ABSL ${SRC}/openscreen/third_party/abseil)

add_library(libopenscreen_absl STATIC
    ${OSP_ABSL}/src/absl/base/internal/raw_logging.cc
    ${OSP_ABSL}/src/absl/base/internal/throw_delegate.cc
    ${OSP_ABSL}/src/absl/hash/internal/city.cc
    ${OSP_ABSL}/src/absl/hash/internal/hash.cc
    ${OSP_ABSL}/src/absl/numeric/int128.cc
    ${OSP_ABSL}/src/absl/strings/ascii.cc
    ${OSP_ABSL}/src/absl/strings/charconv.cc
    ${OSP_ABSL}/src/absl/strings/escaping.cc
    ${OSP_ABSL}/src/absl/strings/internal/charconv_bigint.cc
    ${OSP_ABSL}/src/absl/strings/internal/charconv_parse.cc
    ${OSP_ABSL}/src/absl/strings/internal/escaping.cc
    ${OSP_ABSL}/src/absl/strings/internal/memutil.cc
    ${OSP_ABSL}/src/absl/strings/internal/utf8.cc
    ${OSP_ABSL}/src/absl/strings/match.cc
    ${OSP_ABSL}/src/absl/strings/numbers.cc
    ${OSP_ABSL}/src/absl/strings/str_cat.cc
    ${OSP_ABSL}/src/absl/strings/str_replace.cc
    ${OSP_ABSL}/src/absl/strings/str_split.cc
    ${OSP_ABSL}/src/absl/strings/string_view.cc
    ${OSP_ABSL}/src/absl/strings/substitute.cc
    ${OSP_ABSL}/src/absl/types/bad_optional_access.cc
    ${OSP_ABSL}/src/absl/types/bad_variant_access.cc
    )
target_include_directories(libopenscreen_absl PUBLIC ${OSP_ABSL}/src)

# openscreen_defaults 里的 cflags / cppflags，逐条抄过来（去掉 -Werror 那类）
set(OSP_CFLAGS -O2 -fno-strict-aliasing -W -Wall -Wextra
    -Wno-address-of-packed-member -Wno-array-bounds -Wno-pointer-sign
    -Wno-unused -Wno-unused-but-set-variable -Wno-unused-parameter
    -Wno-missing-field-initializers)
set(OSP_CXXFLAGS -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables)

add_library(libopenscreen-platform-impl STATIC
    ${SRC}/openscreen/platform/impl/time.cc
    ${SRC}/openscreen/platform/impl/network_interface.cc
    ${SRC}/openscreen/platform/impl/network_interface_linux.cc   # target.linux
    )
target_include_directories(libopenscreen-platform-impl PUBLIC ${SRC}/openscreen)
target_compile_definitions(libopenscreen-platform-impl PRIVATE _DEBUG)
target_compile_options(libopenscreen-platform-impl PRIVATE
    ${OSP_CFLAGS} $<$<COMPILE_LANGUAGE:CXX>:${OSP_CXXFLAGS}>)
target_link_libraries(libopenscreen-platform-impl libopenscreen_absl)

add_library(libopenscreen-discovery STATIC
    # osp_platform_api_srcs
    ${SRC}/openscreen/platform/api/udp_socket.cc
    # osp_platform_base_srcs
    ${SRC}/openscreen/platform/base/error.cc
    ${SRC}/openscreen/platform/base/interface_info.cc
    ${SRC}/openscreen/platform/base/ip_address.cc
    ${SRC}/openscreen/platform/base/udp_packet.cc
    # osp_util_srcs
    ${SRC}/openscreen/util/alarm.cc
    ${SRC}/openscreen/util/big_endian.cc
    # osp_discovery_srcs
    ${SRC}/openscreen/discovery/dnssd/impl/conversion_layer.cc
    ${SRC}/openscreen/discovery/dnssd/impl/dns_data_graph.cc
    ${SRC}/openscreen/discovery/dnssd/impl/instance_key.cc
    ${SRC}/openscreen/discovery/dnssd/impl/network_interface_config.cc
    ${SRC}/openscreen/discovery/dnssd/impl/publisher_impl.cc
    ${SRC}/openscreen/discovery/dnssd/impl/querier_impl.cc
    ${SRC}/openscreen/discovery/dnssd/impl/service_dispatcher.cc
    ${SRC}/openscreen/discovery/dnssd/impl/service_instance.cc
    ${SRC}/openscreen/discovery/dnssd/impl/service_key.cc
    ${SRC}/openscreen/discovery/dnssd/public/dns_sd_instance.cc
    ${SRC}/openscreen/discovery/dnssd/public/dns_sd_instance_endpoint.cc
    ${SRC}/openscreen/discovery/dnssd/public/dns_sd_txt_record.cc
    ${SRC}/openscreen/discovery/mdns/mdns_probe.cc
    ${SRC}/openscreen/discovery/mdns/mdns_probe_manager.cc
    ${SRC}/openscreen/discovery/mdns/mdns_publisher.cc
    ${SRC}/openscreen/discovery/mdns/mdns_querier.cc
    ${SRC}/openscreen/discovery/mdns/mdns_reader.cc
    ${SRC}/openscreen/discovery/mdns/mdns_receiver.cc
    ${SRC}/openscreen/discovery/mdns/mdns_records.cc
    ${SRC}/openscreen/discovery/mdns/mdns_responder.cc
    ${SRC}/openscreen/discovery/mdns/mdns_sender.cc
    ${SRC}/openscreen/discovery/mdns/mdns_service_impl.cc
    ${SRC}/openscreen/discovery/mdns/mdns_trackers.cc
    ${SRC}/openscreen/discovery/mdns/mdns_writer.cc
    ${SRC}/openscreen/discovery/mdns/public/mdns_service.cc
    )
target_include_directories(libopenscreen-discovery PUBLIC ${SRC}/openscreen)
target_compile_definitions(libopenscreen-discovery PRIVATE _DEBUG)
target_compile_options(libopenscreen-discovery PRIVATE
    ${OSP_CFLAGS} $<$<COMPILE_LANGUAGE:CXX>:${OSP_CXXFLAGS}>)
# Android.bp 里是 whole_static_libs: libopenscreen_absl
target_link_libraries(libopenscreen-discovery libopenscreen_absl)

# ---------------------------------------------------------------------------
# libbrotli / libzstd —— external/brotli/Android.bp、external/zstd/Android.bp
#
# 这两棵树各自带着上游的 CMakeLists（brotli 有顶层的，zstd 在 build/cmake/），
# **但没走那条路**：上游 CMake 编出来的目标名、开关跟 Android.bp 未必一样，
# 而权威是 Android.bp。这两个的 srcs 本来就是 glob：
#     libbrotli   c/common/*.c  c/dec/*.c  c/enc/*.c
#     libzstd     lib/*/*.c
# 所以这里用 file(GLOB) **不是偷懒，是照抄**。（CMake 一般不建议 glob，理由是
# 加了新文件不会自动重配；这里源码树是 pin 死的 tag，不会变。）
file(GLOB BROTLI_SRCS
    ${SRC}/brotli/c/common/*.c ${SRC}/brotli/c/dec/*.c ${SRC}/brotli/c/enc/*.c)
list(LENGTH BROTLI_SRCS n)
if(n LESS 20)
    message(FATAL_ERROR "brotli 只 glob 到 ${n} 个源文件，源码树不完整？")
endif()
add_library(libbrotli STATIC ${BROTLI_SRCS})
target_include_directories(libbrotli PUBLIC ${SRC}/brotli/c/include)
target_compile_options(libbrotli PRIVATE -O2)

file(GLOB ZSTD_SRCS ${SRC}/zstd/lib/*/*.c)
list(LENGTH ZSTD_SRCS n)
if(n LESS 30)
    message(FATAL_ERROR "zstd 只 glob 到 ${n} 个源文件，源码树不完整？")
endif()
add_library(libzstd STATIC ${ZSTD_SRCS})
target_include_directories(libzstd PUBLIC ${SRC}/zstd/lib PRIVATE ${SRC}/zstd/lib/common)
target_compile_definitions(libzstd PRIVATE ZSTD_HAVE_WEAK_SYMBOLS=0 ZSTD_TRACE=0)
