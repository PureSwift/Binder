/*
 * This file is auto-generated. Modifications will be lost.
 *
 * See https://android.googlesource.com/platform/bionic/+/master/libc/kernel/
 * for more information.
 */

#include <stdint.h>
#include <sys/types.h>

#ifdef __BIONIC__

#include <android/api-level.h>
#include <android/log.h>
#include <android/looper.h>
#include <android/choreographer.h>
#include <android/native_activity.h>

#include <linux/android/binder.h>

// needed for AndroidSystem
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/sysinfo.h>
#include <sys/timerfd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>

#endif

// The kernel uapi headers (<linux/types.h>, <linux/ioctl.h>) ship with glibc
// and Bionic but not with musl, and never on Apple. So a libc without them —
// Apple, or a Linux libc that is neither glibc nor Bionic, which in practice
// means musl — gets the kernel integer types defined here, and takes the ioctl
// macros from <sys/ioctl.h> instead. glibc and Bionic keep using the real
// kernel headers.
#if defined(__APPLE__) || (defined(__linux__) && !defined(__GLIBC__) && !defined(__BIONIC__))

typedef uint8_t   __u8;
typedef uint16_t  __u16;
typedef uint32_t  __u32;
typedef uint64_t  __u64;

typedef int8_t    __s8;
typedef int16_t   __s16;
typedef int32_t   __s32;
typedef int64_t   __s64;

typedef pid_t     __kernel_pid_t;
typedef uid_t     __kernel_uid32_t;

#if !defined(__APPLE__)
// musl: _IOW / _IOR / _IOWR come from here rather than <linux/ioctl.h>.
#include <sys/ioctl.h>
#endif

#else

#include <linux/types.h>
#include <linux/ioctl.h>

#endif

// Kernel header, present in NDK but not found by default

#include "linux/android/binder.h"
#include "linux/android/binderfs.h"
