/*
 * This file is auto-generated. Modifications will be lost.
 *
 * See https://android.googlesource.com/platform/bionic/+/master/libc/kernel/
 * for more information.
 */
#ifndef _UAPI_LINUX_BINDERFS_H
#define _UAPI_LINUX_BINDERFS_H
// Modified from the auto-generated original for musl, as in binder.h: the
// vendored binder.h is included on any Linux (it defines the __uN types for
// musl itself), but the kernel uapi headers are gated on glibc or Bionic.
#if __linux__
#include <linux/android/binder.h>
#endif
#if defined(__linux__) && (defined(__GLIBC__) || defined(__BIONIC__))
#include <linux/types.h>
#include <linux/ioctl.h>
#endif
#define BINDERFS_MAX_NAME 255
struct binderfs_device {
  char name[BINDERFS_MAX_NAME + 1];
  __u32 major;
  __u32 minor;
};
#define BINDER_CTL_ADD _IOWR('b', 1, struct binderfs_device)
#endif
