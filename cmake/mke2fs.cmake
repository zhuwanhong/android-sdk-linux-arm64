#
# mke2fs 的构建目标 —— M3 里源文件最多的一个（146 + 6 + 4）。
#
# 源码清单和依赖全部照抄 AOSP 自己的 Android.bp，**一个都不是手敲的**
# （用脚本从 external/e2fsprogs/*/Android.bp 和 system/core/libsparse/Android.bp
# 里抽出来的）：
#
#     misc/Android.bp          cc_binary mke2fs + cc_defaults mke2fs_defaults + libext2_misc
#     lib/{et,uuid,e2p,blkid,ext2fs,support}/Android.bp   六个 libext2_*
#     core/libsparse/Android.bp                           libsparse
#
# **只多取一棵树**：external/e2fsprogs。libsparse 在 system/core 里，
# 那棵本来就是上游 18 个子模块之一。
#
# 注意 mke2fs 跑起来要一个 mke2fs.conf（`MKE2FS_CONFIG` 指过去，或装到
# /etc/mke2fs.conf）。没有它会直接 abort：
#     Your mke2fs.conf file does not define the ext4 filesystem type.
# 官方的 platform-tools 里就带着一份 —— M4 做分发包时别忘了这个文件。
#

set(E2FS ${SRC}/e2fsprogs)

set(E2FS_INCLUDES
    ${E2FS}/lib                     # config.h、ext2fs/*.h、et/*.h 都在这层底下
    ${E2FS}/misc                    # create_inode.h
    ${E2FS}/e2fsck                  # mke2fs_defaults 的 include_dirs 明写了这个
    ${SRC}/core/libsparse/include
    ${SRC}/libbase/include
    ${SRC}/logging/liblog/include
    )

# e2fsprogs-defaults 的 cflags。**-Werror 不带**（理由见 cmake/zipalign.cmake）；
# 剩下那几个 -Wno-* 照带 —— 上游注释里写明了它们是「Android 默认开、但上游
# e2fsprogs 不支持」的警告，去掉会淹在噪音里。
set(E2FS_CFLAGS -Wno-pointer-arith -Wno-sign-compare -Wno-type-limits
                -Wno-typedef-redefinition -Wno-unused-parameter)

add_library(libext2_com_err STATIC
    ${SRC}/e2fsprogs/lib/et/error_message.c
    ${SRC}/e2fsprogs/lib/et/et_name.c
    ${SRC}/e2fsprogs/lib/et/init_et.c
    ${SRC}/e2fsprogs/lib/et/com_err.c
    ${SRC}/e2fsprogs/lib/et/com_right.c
    )
target_include_directories(libext2_com_err PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2_com_err PRIVATE ${E2FS_CFLAGS})

add_library(libext2_uuid STATIC
    ${SRC}/e2fsprogs/lib/uuid/clear.c
    ${SRC}/e2fsprogs/lib/uuid/compare.c
    ${SRC}/e2fsprogs/lib/uuid/copy.c
    ${SRC}/e2fsprogs/lib/uuid/gen_uuid.c
    ${SRC}/e2fsprogs/lib/uuid/isnull.c
    ${SRC}/e2fsprogs/lib/uuid/pack.c
    ${SRC}/e2fsprogs/lib/uuid/parse.c
    ${SRC}/e2fsprogs/lib/uuid/unpack.c
    ${SRC}/e2fsprogs/lib/uuid/unparse.c
    ${SRC}/e2fsprogs/lib/uuid/uuid_time.c
    )
target_include_directories(libext2_uuid PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2_uuid PRIVATE ${E2FS_CFLAGS})

add_library(libext2_e2p STATIC
    ${SRC}/e2fsprogs/lib/e2p/encoding.c
    ${SRC}/e2fsprogs/lib/e2p/errcode.c
    ${SRC}/e2fsprogs/lib/e2p/feature.c
    ${SRC}/e2fsprogs/lib/e2p/fgetflags.c
    ${SRC}/e2fsprogs/lib/e2p/fsetflags.c
    ${SRC}/e2fsprogs/lib/e2p/fgetproject.c
    ${SRC}/e2fsprogs/lib/e2p/fsetproject.c
    ${SRC}/e2fsprogs/lib/e2p/fgetversion.c
    ${SRC}/e2fsprogs/lib/e2p/fsetversion.c
    ${SRC}/e2fsprogs/lib/e2p/getflags.c
    ${SRC}/e2fsprogs/lib/e2p/getversion.c
    ${SRC}/e2fsprogs/lib/e2p/hashstr.c
    ${SRC}/e2fsprogs/lib/e2p/iod.c
    ${SRC}/e2fsprogs/lib/e2p/ljs.c
    ${SRC}/e2fsprogs/lib/e2p/ls.c
    ${SRC}/e2fsprogs/lib/e2p/mntopts.c
    ${SRC}/e2fsprogs/lib/e2p/parse_num.c
    ${SRC}/e2fsprogs/lib/e2p/pe.c
    ${SRC}/e2fsprogs/lib/e2p/pf.c
    ${SRC}/e2fsprogs/lib/e2p/ps.c
    ${SRC}/e2fsprogs/lib/e2p/setflags.c
    ${SRC}/e2fsprogs/lib/e2p/setversion.c
    ${SRC}/e2fsprogs/lib/e2p/uuid.c
    ${SRC}/e2fsprogs/lib/e2p/ostype.c
    ${SRC}/e2fsprogs/lib/e2p/percent.c
    )
target_include_directories(libext2_e2p PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2_e2p PRIVATE ${E2FS_CFLAGS})

add_library(libext2_blkid STATIC
    ${SRC}/e2fsprogs/lib/blkid/cache.c
    ${SRC}/e2fsprogs/lib/blkid/dev.c
    ${SRC}/e2fsprogs/lib/blkid/devname.c
    ${SRC}/e2fsprogs/lib/blkid/devno.c
    ${SRC}/e2fsprogs/lib/blkid/getsize.c
    ${SRC}/e2fsprogs/lib/blkid/llseek.c
    ${SRC}/e2fsprogs/lib/blkid/probe.c
    ${SRC}/e2fsprogs/lib/blkid/read.c
    ${SRC}/e2fsprogs/lib/blkid/resolve.c
    ${SRC}/e2fsprogs/lib/blkid/save.c
    ${SRC}/e2fsprogs/lib/blkid/tag.c
    ${SRC}/e2fsprogs/lib/blkid/version.c
    )
target_include_directories(libext2_blkid PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2_blkid PRIVATE ${E2FS_CFLAGS})

add_library(libext2fs STATIC
    ${SRC}/e2fsprogs/lib/ext2fs/ext2_err.c
    ${SRC}/e2fsprogs/lib/ext2fs/alloc.c
    ${SRC}/e2fsprogs/lib/ext2fs/alloc_sb.c
    ${SRC}/e2fsprogs/lib/ext2fs/alloc_stats.c
    ${SRC}/e2fsprogs/lib/ext2fs/alloc_tables.c
    ${SRC}/e2fsprogs/lib/ext2fs/atexit.c
    ${SRC}/e2fsprogs/lib/ext2fs/badblocks.c
    ${SRC}/e2fsprogs/lib/ext2fs/bb_inode.c
    ${SRC}/e2fsprogs/lib/ext2fs/bitmaps.c
    ${SRC}/e2fsprogs/lib/ext2fs/bitops.c
    ${SRC}/e2fsprogs/lib/ext2fs/blkmap64_ba.c
    ${SRC}/e2fsprogs/lib/ext2fs/blkmap64_rb.c
    ${SRC}/e2fsprogs/lib/ext2fs/blknum.c
    ${SRC}/e2fsprogs/lib/ext2fs/block.c
    ${SRC}/e2fsprogs/lib/ext2fs/bmap.c
    ${SRC}/e2fsprogs/lib/ext2fs/check_desc.c
    ${SRC}/e2fsprogs/lib/ext2fs/crc16.c
    ${SRC}/e2fsprogs/lib/ext2fs/crc32c.c
    ${SRC}/e2fsprogs/lib/ext2fs/csum.c
    ${SRC}/e2fsprogs/lib/ext2fs/closefs.c
    ${SRC}/e2fsprogs/lib/ext2fs/dblist.c
    ${SRC}/e2fsprogs/lib/ext2fs/dblist_dir.c
    ${SRC}/e2fsprogs/lib/ext2fs/digest_encode.c
    ${SRC}/e2fsprogs/lib/ext2fs/dirblock.c
    ${SRC}/e2fsprogs/lib/ext2fs/dirhash.c
    ${SRC}/e2fsprogs/lib/ext2fs/dir_iterate.c
    ${SRC}/e2fsprogs/lib/ext2fs/dupfs.c
    ${SRC}/e2fsprogs/lib/ext2fs/expanddir.c
    ${SRC}/e2fsprogs/lib/ext2fs/ext_attr.c
    ${SRC}/e2fsprogs/lib/ext2fs/extent.c
    ${SRC}/e2fsprogs/lib/ext2fs/fallocate.c
    ${SRC}/e2fsprogs/lib/ext2fs/fileio.c
    ${SRC}/e2fsprogs/lib/ext2fs/finddev.c
    ${SRC}/e2fsprogs/lib/ext2fs/flushb.c
    ${SRC}/e2fsprogs/lib/ext2fs/freefs.c
    ${SRC}/e2fsprogs/lib/ext2fs/gen_bitmap.c
    ${SRC}/e2fsprogs/lib/ext2fs/gen_bitmap64.c
    ${SRC}/e2fsprogs/lib/ext2fs/get_num_dirs.c
    ${SRC}/e2fsprogs/lib/ext2fs/get_pathname.c
    ${SRC}/e2fsprogs/lib/ext2fs/getsize.c
    ${SRC}/e2fsprogs/lib/ext2fs/getsectsize.c
    ${SRC}/e2fsprogs/lib/ext2fs/hashmap.c
    ${SRC}/e2fsprogs/lib/ext2fs/i_block.c
    ${SRC}/e2fsprogs/lib/ext2fs/icount.c
    ${SRC}/e2fsprogs/lib/ext2fs/imager.c
    ${SRC}/e2fsprogs/lib/ext2fs/ind_block.c
    ${SRC}/e2fsprogs/lib/ext2fs/initialize.c
    ${SRC}/e2fsprogs/lib/ext2fs/inline.c
    ${SRC}/e2fsprogs/lib/ext2fs/inline_data.c
    ${SRC}/e2fsprogs/lib/ext2fs/inode.c
    ${SRC}/e2fsprogs/lib/ext2fs/io_manager.c
    ${SRC}/e2fsprogs/lib/ext2fs/ismounted.c
    ${SRC}/e2fsprogs/lib/ext2fs/link.c
    ${SRC}/e2fsprogs/lib/ext2fs/llseek.c
    ${SRC}/e2fsprogs/lib/ext2fs/lookup.c
    ${SRC}/e2fsprogs/lib/ext2fs/mmp.c
    ${SRC}/e2fsprogs/lib/ext2fs/mkdir.c
    ${SRC}/e2fsprogs/lib/ext2fs/mkjournal.c
    ${SRC}/e2fsprogs/lib/ext2fs/namei.c
    ${SRC}/e2fsprogs/lib/ext2fs/native.c
    ${SRC}/e2fsprogs/lib/ext2fs/newdir.c
    ${SRC}/e2fsprogs/lib/ext2fs/nls_utf8.c
    ${SRC}/e2fsprogs/lib/ext2fs/openfs.c
    ${SRC}/e2fsprogs/lib/ext2fs/progress.c
    ${SRC}/e2fsprogs/lib/ext2fs/punch.c
    ${SRC}/e2fsprogs/lib/ext2fs/qcow2.c
    ${SRC}/e2fsprogs/lib/ext2fs/rbtree.c
    ${SRC}/e2fsprogs/lib/ext2fs/read_bb.c
    ${SRC}/e2fsprogs/lib/ext2fs/read_bb_file.c
    ${SRC}/e2fsprogs/lib/ext2fs/res_gdt.c
    ${SRC}/e2fsprogs/lib/ext2fs/rw_bitmaps.c
    ${SRC}/e2fsprogs/lib/ext2fs/sha256.c
    ${SRC}/e2fsprogs/lib/ext2fs/sha512.c
    ${SRC}/e2fsprogs/lib/ext2fs/swapfs.c
    ${SRC}/e2fsprogs/lib/ext2fs/symlink.c
    ${SRC}/e2fsprogs/lib/ext2fs/undo_io.c
    ${SRC}/e2fsprogs/lib/ext2fs/unix_io.c
    ${SRC}/e2fsprogs/lib/ext2fs/sparse_io.c
    ${SRC}/e2fsprogs/lib/ext2fs/unlink.c
    ${SRC}/e2fsprogs/lib/ext2fs/valid_blk.c
    ${SRC}/e2fsprogs/lib/ext2fs/version.c
    ${SRC}/e2fsprogs/lib/ext2fs/test_io.c
    )
target_include_directories(libext2fs PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2fs PRIVATE ${E2FS_CFLAGS})

add_library(libext2_quota STATIC
    ${SRC}/e2fsprogs/lib/support/devname.c
    ${SRC}/e2fsprogs/lib/support/dict.c
    ${SRC}/e2fsprogs/lib/support/mkquota.c
    ${SRC}/e2fsprogs/lib/support/parse_qtype.c
    ${SRC}/e2fsprogs/lib/support/plausible.c
    ${SRC}/e2fsprogs/lib/support/profile.c
    ${SRC}/e2fsprogs/lib/support/profile_helpers.c
    ${SRC}/e2fsprogs/lib/support/prof_err.c
    ${SRC}/e2fsprogs/lib/support/quotaio.c
    ${SRC}/e2fsprogs/lib/support/quotaio_tree.c
    ${SRC}/e2fsprogs/lib/support/quotaio_v2.c
    )
target_include_directories(libext2_quota PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2_quota PRIVATE ${E2FS_CFLAGS})

add_library(libext2_misc STATIC
    ${SRC}/e2fsprogs/misc/create_inode.c
    )
target_include_directories(libext2_misc PRIVATE ${E2FS_INCLUDES})
target_compile_options(libext2_misc PRIVATE ${E2FS_CFLAGS})

add_library(libsparse STATIC
    ${SRC}/core/libsparse/backed_block.cpp
    ${SRC}/core/libsparse/output_file.cpp
    ${SRC}/core/libsparse/sparse.cpp
    ${SRC}/core/libsparse/sparse_crc32.cpp
    ${SRC}/core/libsparse/sparse_err.cpp
    ${SRC}/core/libsparse/sparse_read.cpp
    )
target_include_directories(libsparse PRIVATE ${E2FS_INCLUDES})
target_compile_options(libsparse PRIVATE ${E2FS_CFLAGS})

add_executable(mke2fs
    ${SRC}/e2fsprogs/misc/mke2fs.c
    ${SRC}/e2fsprogs/misc/util.c
    ${SRC}/e2fsprogs/misc/mk_hugefiles.c
    ${SRC}/e2fsprogs/misc/default_profile.c
    )
target_include_directories(mke2fs PRIVATE ${E2FS_INCLUDES})
target_compile_options(mke2fs PRIVATE ${E2FS_CFLAGS})

# misc/Android.bp 里 mke2fs 的 host 变体 static_libs，原样照搬（顺序按静态链接
# 的依赖方向排过：用的人在前，被用的在后）。
target_link_libraries(mke2fs
    libext2_misc
    libext2_blkid
    libext2_quota
    libext2_e2p
    libext2fs
    libext2_com_err
    libext2_uuid
    libsparse
    libbase
    c++_static
    z
    )
target_link_options(mke2fs PRIVATE "-Wl,-z,max-page-size=16384")
