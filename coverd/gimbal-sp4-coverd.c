/* gimbal-sp4-coverd: publish the Surface Pro 4 Type Cover's fold position.
 *
 * Usage: gimbal-sp4-coverd < /dev/hidrawN
 *
 * The cover's hidraw node is opened by systemd (StandardInput=file:) and
 * handed over as standard input, so this program runs as an unprivileged
 * user that cannot open any device itself. That node also carries every
 * keystroke and touchpad report. The program reads only the first data byte
 * of vendor report 35 and writes one of four words to
 * /run/gimbal-sp4-cover/fold. Nothing else from the device is stored,
 * logged or forwarded, and read buffers are wiped after each report.
 *
 * It refuses to run unless standard input is a read-only hidraw node for
 * USB device 045e:07e8 interface 0 whose report descriptor has report 35
 * where it was measured. It takes no arguments and reads no environment
 * variables. After these checks it installs its own seccomp filter
 * (coverd_lockdown): hidraw ignores the access mode for ioctls, so a
 * read-only descriptor alone would not stop a feature or output report
 * being sent; the filter allows ioctl only as GET_REPORT on standard input. */
#define _GNU_SOURCE
#include "coverd.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/hidraw.h>
#include <linux/input.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define COVERD_STATE_DIR "/run/gimbal-sp4-cover"

#define COVER_VENDOR 0x045e
#define COVER_PRODUCT 0x07e8
#define DEVICE_FD STDIN_FILENO

static void fail(const char *what)
{
    fprintf(stderr, "gimbal-sp4-coverd: %s\n", what);
}

static void fail_errno(const char *what, int err)
{
    fprintf(stderr, "gimbal-sp4-coverd: %s: %s\n", what, strerror(err));
}

static ssize_t hid_get_report(int fd, unsigned char *buf, size_t len)
{
    int n;

    /* The ioctl size is fixed at compile time; the buffer must match it. */
    if (len != COVERD_REPORT_MAX)
        return -EINVAL;
    n = ioctl(fd, HIDIOCGINPUT(COVERD_REPORT_MAX), buf);
    return n < 0 ? -errno : n;
}

static int64_t suspended_ns(void)
{
    struct timespec boot, mono;

    if (clock_gettime(CLOCK_BOOTTIME, &boot) < 0 || clock_gettime(CLOCK_MONOTONIC, &mono) < 0)
        return 0;
    return ((int64_t)boot.tv_sec - (int64_t)mono.tv_sec) * 1000000000LL
        + ((int64_t)boot.tv_nsec - (int64_t)mono.tv_nsec);
}

static int ends_with(const char *text, size_t len, const char *suffix)
{
    size_t n = strlen(suffix);
    return len >= n && memcmp(text + len - n, suffix, n) == 0;
}

/* Everything that makes this fd the Type Cover's interface 0. */
static int check_device(int fd)
{
    static struct hidraw_report_descriptor desc;
    struct hidraw_devinfo info;
    char phys[256];
    struct stat st;
    int size, n;

    if (fstat(fd, &st) < 0) {
        fail_errno("standard input", errno);
        return -1;
    }
    if (!S_ISCHR(st.st_mode)) {
        fail("standard input is not a character device");
        return -1;
    }
    memset(&info, 0, sizeof info);
    if (ioctl(fd, HIDIOCGRAWINFO, &info) < 0) {
        fail_errno("standard input is not a hidraw device", errno);
        return -1;
    }
    if (info.bustype != BUS_USB || (unsigned short)info.vendor != COVER_VENDOR
        || (unsigned short)info.product != COVER_PRODUCT) {
        fail("standard input is not the Surface Type Cover (USB 045e:07e8)");
        return -1;
    }

    memset(phys, 0, sizeof phys);
    n = ioctl(fd, HIDIOCGRAWPHYS(sizeof phys - 1), phys);
    if (n < 0) {
        fail_errno("cannot read the device's physical path", errno);
        return -1;
    }
    phys[sizeof phys - 1] = '\0';
    if (!ends_with(phys, strnlen(phys, sizeof phys), "/input0")) {
        fail("standard input is not the Type Cover's interface 0");
        return -1;
    }

    if (ioctl(fd, HIDIOCGRDESCSIZE, &size) < 0) {
        fail_errno("cannot read the report descriptor size", errno);
        return -1;
    }
    /* hidraw itself refuses sizes of HID_MAX_DESCRIPTOR_SIZE and above. */
    if (size <= 0 || size >= HID_MAX_DESCRIPTOR_SIZE) {
        fail("the report descriptor size is out of range");
        return -1;
    }
    memset(&desc, 0, sizeof desc);
    desc.size = (unsigned int)size;
    if (ioctl(fd, HIDIOCGRDESC, &desc) < 0) {
        fail_errno("cannot read the report descriptor", errno);
        return -1;
    }
    if (!coverd_descriptor_ok(desc.value, desc.size < HID_MAX_DESCRIPTOR_SIZE ? desc.size : 0)) {
        fail("the report descriptor has no fold report where it was measured");
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    static const struct coverd_io io = {
        .get_report = hid_get_report,
        .suspended_ns = suspended_ns,
        .tick_ms = 2000,
        .retry_ms = 500,
    };
    sigset_t stop;
    int flags, dirfd, sigfd;

    (void)argv;
    if (argc != 1) {
        fail("usage: gimbal-sp4-coverd < /dev/hidrawN (no arguments)");
        return COVERD_EXIT_USAGE;
    }
    /* No core dumps or ptrace by the same user: memory may hold a keystroke. */
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) < 0) {
        fail_errno("prctl", errno);
        return COVERD_EXIT_FAILED;
    }
    if (check_device(DEVICE_FD) < 0)
        return COVERD_EXIT_USAGE;

    flags = fcntl(DEVICE_FD, F_GETFL);
    if (flags < 0) {
        fail_errno("fcntl", errno);
        return COVERD_EXIT_FAILED;
    }
    /* Nothing is ever written to the cover. The seccomp filter below is what
     * stops ioctls that send reports; this refuses write(2) as well. */
    if ((flags & O_ACCMODE) != O_RDONLY) {
        fail("standard input must be opened read-only");
        return COVERD_EXIT_USAGE;
    }
    if (fcntl(DEVICE_FD, F_SETFL, flags | O_NONBLOCK) < 0) {
        fail_errno("fcntl", errno);
        return COVERD_EXIT_FAILED;
    }

    dirfd = open(COVERD_STATE_DIR, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0) {
        fail_errno(COVERD_STATE_DIR, errno);
        return COVERD_EXIT_FAILED;
    }

    if (sigemptyset(&stop) < 0 || sigaddset(&stop, SIGTERM) < 0 || sigaddset(&stop, SIGINT) < 0
        || sigaddset(&stop, SIGHUP) < 0 || sigprocmask(SIG_BLOCK, &stop, NULL) < 0) {
        fail_errno("sigprocmask", errno);
        return COVERD_EXIT_FAILED;
    }
    sigfd = signalfd(-1, &stop, SFD_CLOEXEC | SFD_NONBLOCK);
    if (sigfd < 0) {
        fail_errno("signalfd", errno);
        return COVERD_EXIT_FAILED;
    }

    if (coverd_lockdown() < 0)
        return COVERD_EXIT_FAILED;
    return coverd_serve(DEVICE_FD, dirfd, sigfd, &io);
}
