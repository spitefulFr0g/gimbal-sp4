/* Type Cover fold helper: report parsing, publishing and the event loop.
 * See coverd.h. Nothing here opens a device or reads the environment. */
#define _GNU_SOURCE
#include "coverd.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/hidraw.h>
#include <linux/seccomp.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#if !defined(__x86_64__) || defined(__ILP32__)
#error "gimbal-sp4-coverd's seccomp filter is written for x86_64 (the Surface Pro 4) only"
#endif

/* A GET_REPORT that fails right after resume is retried this many times,
 * io->retry_ms apart. */
#define QUERY_TRIES 10
/* More time than this spent suspended between two wakeups is a resume. */
#define RESUME_NS 1000000000LL

enum coverd_fold coverd_map(unsigned char position)
{
    switch (position) {
    case 0x22: return COVERD_TYPING;
    case 0x33: return COVERD_BETWEEN;
    case 0x43: return COVERD_FOLDED;
    default: return COVERD_UNKNOWN;
    }
}

int coverd_parse(const unsigned char *buf, size_t len, enum coverd_fold *fold)
{
    if (buf == NULL || fold == NULL || len < 2 || buf[0] != COVERD_REPORT_ID)
        return 0;
    *fold = coverd_map(buf[1]);
    return 1;
}

const char *coverd_word(enum coverd_fold fold)
{
    switch (fold) {
    case COVERD_TYPING: return "typing";
    case COVERD_BETWEEN: return "between";
    case COVERD_FOLDED: return "folded";
    case COVERD_UNKNOWN: break;
    }
    return "unknown";
}

int coverd_descriptor_ok(const unsigned char *desc, size_t len)
{
    /* Report ID (35), Usage Minimum (0x72), Usage Maximum (0x75), Input
     * (Data,Var,Abs), preceded somewhere by Usage Page (0xff05). */
    static const unsigned char page[] = { 0x06, 0x05, 0xff };
    static const unsigned char report[] = { 0x85, 0x23, 0x19, 0x72, 0x29, 0x75, 0x81, 0x02 };
    size_t first_page = len;

    if (desc == NULL)
        return 0;
    for (size_t i = 0; i + sizeof page <= len; i++) {
        if (memcmp(desc + i, page, sizeof page) == 0) {
            first_page = i;
            break;
        }
    }
    for (size_t i = first_page; i + sizeof report <= len; i++) {
        if (memcmp(desc + i, report, sizeof report) == 0)
            return 1;
    }
    return 0;
}

static void report_error(const char *what, int err)
{
    fprintf(stderr, "gimbal-sp4-coverd: %s: %s\n", what, strerror(err));
}

static int write_all(int fd, const char *text, size_t len)
{
    while (len > 0) {
        ssize_t n = write(fd, text, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -errno;
        }
        if (n == 0)
            return -EIO;
        text += n;
        len -= (size_t)n;
    }
    return 0;
}

int coverd_publish(int dirfd, enum coverd_fold fold)
{
    char line[16];
    const char *word = coverd_word(fold);
    size_t len = strlen(word);
    int fd, err;

    if (len + 1 >= sizeof line)
        return -EOVERFLOW;
    memcpy(line, word, len);
    line[len++] = '\n';

    fd = openat(dirfd, COVERD_STATE_TEMP,
                O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0)
        return -errno;
    err = fchmod(fd, 0644) < 0 ? -errno : 0;
    if (err == 0)
        err = write_all(fd, line, len);
    if (close(fd) < 0 && err == 0 && errno != EINTR)
        err = -errno;
    if (err == 0 && renameat(dirfd, COVERD_STATE_TEMP, dirfd, COVERD_STATE_NAME) < 0)
        err = -errno;
    /* A directory removed under us (its unit stopped) fails the openat
     * above with ENOENT, so a write is never silently lost. */
    if (err < 0) {
        (void)unlinkat(dirfd, COVERD_STATE_TEMP, 0);
        return err;
    }
    return 0;
}

/* Low and high 32 bits of a syscall argument (x86_64 is little-endian). */
#define ARG_LO(i) (offsetof(struct seccomp_data, args) + 8 * (i))
#define ARG_HI(i) (offsetof(struct seccomp_data, args) + 8 * (i) + 4)
#define ALLOW(nr) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
#define KILL BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS)

int coverd_lockdown(void)
{
    static struct sock_filter filter[] = {
        /* Native x86_64 calls only: no i386 or x32 entry points. */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        KILL,
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, __X32_SYSCALL_BIT, 0, 1),
        KILL,

        /* Measured with SECCOMP_RET_LOG over the tests: read, poll, openat,
         * fchmod, write, close, renameat, unlinkat, exit_group. ppoll and
         * renameat2 are what another glibc may use for poll() and
         * renameat(); clock_gettime is the vDSO's fallback; restart_syscall
         * resumes a poll interrupted by a stop signal. */
        ALLOW(__NR_read),
        ALLOW(__NR_poll),
        ALLOW(__NR_ppoll),
        ALLOW(__NR_clock_gettime),
        ALLOW(__NR_restart_syscall),
        ALLOW(__NR_openat),
        ALLOW(__NR_fchmod),
        ALLOW(__NR_write),
        ALLOW(__NR_close),
        ALLOW(__NR_renameat),
        ALLOW(__NR_renameat2),
        ALLOW(__NR_unlinkat),
        ALLOW(__NR_exit_group),

        /* ioctl only as GET_REPORT on standard input. hidraw does not check
         * the descriptor's access mode, so this is what stops a feature or
         * output report from ever being sent to the cover. */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_ioctl, 1, 0),
        KILL,
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, ARG_LO(0)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, STDIN_FILENO, 1, 0),
        KILL,
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, ARG_HI(0)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 1, 0),
        KILL,
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, ARG_LO(1)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, HIDIOCGINPUT(COVERD_REPORT_MAX), 1, 0),
        KILL,
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, ARG_HI(1)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 1, 0),
        KILL,
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    static const struct sock_fprog prog = {
        .len = (unsigned short)(sizeof filter / sizeof filter[0]),
        .filter = filter,
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0
        || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0) < 0) {
        report_error("cannot install the seccomp filter", errno);
        return -1;
    }
    return 0;
}

void coverd_clear(int dirfd)
{
    if (unlinkat(dirfd, COVERD_STATE_NAME, 0) < 0 && errno != ENOENT)
        report_error("cannot remove the fold state", errno);
    (void)unlinkat(dirfd, COVERD_STATE_TEMP, 0);
}

struct state {
    int dirfd;
    int shown;             /* whether anything has been published */
    enum coverd_fold fold; /* what was published */
};

static int show(struct state *s, enum coverd_fold fold)
{
    int err;

    if (s->shown && s->fold == fold)
        return 0;
    err = coverd_publish(s->dirfd, fold);
    if (err < 0) {
        report_error("cannot publish the fold state", -err);
        return -1;
    }
    s->shown = 1;
    s->fold = fold;
    fprintf(stderr, "gimbal-sp4-coverd: cover is %s\n", coverd_word(fold));
    return 0;
}

static int is_gone(int err)
{
    return err == ENODEV || err == EIO || err == ENXIO;
}

static int64_t monotonic_ms(void)
{
    struct timespec t;

    if (clock_gettime(CLOCK_MONOTONIC, &t) < 0)
        return 0;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Send GET_REPORT once. Returns 0 to go on, or an exit code. */
static int query(int devfd, const struct coverd_io *io, struct state *s, int *left,
                 int64_t *next)
{
    unsigned char buf[COVERD_REPORT_MAX];
    enum coverd_fold fold = COVERD_UNKNOWN;
    ssize_t n;
    int parsed = 0;

    memset(buf, 0, sizeof buf);
    buf[0] = COVERD_REPORT_ID;
    n = io->get_report(devfd, buf, sizeof buf);
    if (n >= 0 && (size_t)n <= sizeof buf)
        parsed = coverd_parse(buf, (size_t)n, &fold);
    explicit_bzero(buf, sizeof buf);

    if (n == -ENODEV)
        return COVERD_EXIT_GONE;
    if (parsed) {
        *left = 0;
    } else {
        *next = monotonic_ms() + io->retry_ms;
        if (--*left == 0)
            report_error("cannot query the fold position", n < 0 ? (int)-n : EPROTO);
    }
    /* The first answer, or the first failure, is published at once; after
     * that a failed query leaves the published word alone. */
    if ((parsed || !s->shown) && show(s, fold) < 0)
        return COVERD_EXIT_FAILED;
    return 0;
}

static int run(int devfd, int sigfd, const struct coverd_io *io, struct state *s)
{
    unsigned char buf[COVERD_REPORT_MAX];
    int query_left = QUERY_TRIES;
    int64_t query_at = monotonic_ms();
    int64_t suspended = io->suspended_ns();

    for (;;) {
        struct pollfd fds[2];
        nfds_t nfds = 1;
        enum coverd_fold fold;
        int64_t now;
        ssize_t n;
        int ready, rc, timeout = io->tick_ms;

        if (query_left > 0) {
            int64_t wait = query_at - monotonic_ms();
            if (wait <= 0) {
                rc = query(devfd, io, s, &query_left, &query_at);
                if (rc != 0)
                    return rc;
                wait = io->retry_ms;
            }
            if (query_left > 0 && wait < timeout)
                timeout = (int)wait;
        }

        fds[0] = (struct pollfd){ .fd = devfd, .events = POLLIN };
        if (sigfd >= 0) {
            fds[1] = (struct pollfd){ .fd = sigfd, .events = POLLIN };
            nfds = 2;
        }
        ready = poll(fds, nfds, timeout);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            report_error("poll", errno);
            return COVERD_EXIT_FAILED;
        }

        /* A fold change during suspend may send no report, so ask again. */
        now = io->suspended_ns();
        if (now - suspended > RESUME_NS) {
            query_left = QUERY_TRIES;
            query_at = monotonic_ms();
        }
        suspended = now;

        if (nfds == 2 && fds[1].revents != 0)
            return COVERD_EXIT_STOPPED;

        if (fds[0].revents & POLLNVAL)
            return COVERD_EXIT_FAILED;
        if (fds[0].revents & POLLIN) {
            /* One report per read. It may be a keystroke: only the fold
             * byte of report 35 is ever looked at, and the buffer is wiped. */
            n = read(devfd, buf, sizeof buf);
            if (n > 0) {
                int parsed = coverd_parse(buf, (size_t)n, &fold);
                explicit_bzero(buf, sizeof buf);
                if (parsed && show(s, fold) < 0)
                    return COVERD_EXIT_FAILED;
                continue;
            }
            explicit_bzero(buf, sizeof buf);
            if (n == 0)
                return COVERD_EXIT_GONE;
            if (errno == EINTR || errno == EAGAIN)
                continue;
            if (is_gone(errno))
                return COVERD_EXIT_GONE;
            report_error("read", errno);
            return COVERD_EXIT_FAILED;
        }
        if (fds[0].revents & (POLLERR | POLLHUP))
            return COVERD_EXIT_GONE;
    }
}

int coverd_serve(int devfd, int dirfd, int sigfd, const struct coverd_io *io)
{
    struct state s = { .dirfd = dirfd, .shown = 0, .fold = COVERD_UNKNOWN };
    int rc = run(devfd, sigfd, io, &s);

    coverd_clear(dirfd);
    if (rc == COVERD_EXIT_GONE)
        fprintf(stderr, "gimbal-sp4-coverd: the Type Cover went away\n");
    return rc;
}
