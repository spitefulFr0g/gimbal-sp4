/* Tests for the fold helper's parsing, publishing and event loop.
 *
 * The event loop runs in a child process against one end of a SOCK_SEQPACKET
 * pair, which keeps report boundaries the way hidraw does. GET_REPORT and the
 * suspend clock are fakes driven through shared memory. The production
 * binary's device checks are not used or weakened; only coverd.c is linked.
 *
 * Usage: test_coverd <path to typecover-045e-07e8.rdesc>
 *        test_coverd --serve-stdin <state dir>
 *
 * The second form runs the loop on standard input, under coverd_lockdown(),
 * with a real signalfd and a GET_REPORT that answers "folded". tests/coverd-sandbox.sh uses it to run
 * the loop under the service's seccomp and sandbox settings. */
#define _GNU_SOURCE
#include "coverd.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/hidraw.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        failures++; \
    } \
} while (0)

struct fake {
    volatile int64_t suspended;
    volatile unsigned char position; /* what GET_REPORT answers */
    volatile int get_errno;          /* nonzero: GET_REPORT fails with it */
    volatile int queries;
    volatile int published_before_query; /* state file existed at query 1 */
};

static struct fake *fake;
static int test_dirfd = -1;

static ssize_t fake_get_report(int fd, unsigned char *buf, size_t len)
{
    (void)fd;
    if (__atomic_add_fetch(&fake->queries, 1, __ATOMIC_SEQ_CST) == 1 && test_dirfd >= 0) {
        int f = openat(test_dirfd, COVERD_STATE_NAME, O_RDONLY | O_CLOEXEC);
        if (f >= 0) {
            fake->published_before_query = 1;
            close(f);
        }
    }
    if (fake->get_errno)
        return -fake->get_errno;
    if (len < 17)
        return -EINVAL;
    memset(buf, 0x5a, 17);
    buf[0] = COVERD_REPORT_ID;
    buf[1] = fake->position;
    return 17;
}

static int64_t fake_suspended_ns(void)
{
    return fake->suspended;
}

static const struct coverd_io fake_io = {
    .get_report = fake_get_report,
    .suspended_ns = fake_suspended_ns,
    .tick_ms = 20,
    .retry_ms = 20,
};

static void nap(void)
{
    struct timespec t = { 0, 10 * 1000 * 1000 };
    nanosleep(&t, NULL);
}

/* The published word, "" when there is no file. */
static void read_state(int dirfd, char *out, size_t size)
{
    int fd = openat(dirfd, COVERD_STATE_NAME, O_RDONLY | O_CLOEXEC);
    ssize_t n;

    out[0] = '\0';
    if (fd < 0)
        return;
    n = read(fd, out, size - 1);
    close(fd);
    out[n > 0 ? n : 0] = '\0';
}

static int wait_state(int dirfd, const char *want)
{
    char got[64];

    for (int i = 0; i < 300; i++) {
        read_state(dirfd, got, sizeof got);
        if (strcmp(got, want) == 0)
            return 1;
        nap();
    }
    fprintf(stderr, "  expected \"%s\", have \"%s\"\n", want, got);
    return 0;
}

static int wait_queries(int at_least)
{
    for (int i = 0; i < 300; i++) {
        if (fake->queries >= at_least)
            return 1;
        nap();
    }
    return 0;
}

static void send_report(int fd, const unsigned char *buf, size_t len)
{
    CHECK(send(fd, buf, len, 0) == (ssize_t)len);
}

static void send_fold(int fd, unsigned char position)
{
    unsigned char r[17];
    memset(r, 0xa5, sizeof r);
    r[0] = COVERD_REPORT_ID;
    r[1] = position;
    send_report(fd, r, sizeof r);
}

struct child {
    pid_t pid;
    int peer;  /* our end of the "device" */
    int sig;   /* write end standing in for the signalfd */
};

static struct child start(int dirfd)
{
    struct child c = { -1, -1, -1 };
    int dev[2], sig[2];

    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, dev) < 0 || pipe2(sig, O_CLOEXEC) < 0) {
        perror("socketpair/pipe");
        exit(1);
    }
    c.pid = fork();
    if (c.pid < 0) {
        perror("fork");
        exit(1);
    }
    if (c.pid == 0) {
        close(dev[0]);
        close(sig[1]);
        if (coverd_lockdown() < 0)
            _exit(99);
        _exit(coverd_serve(dev[1], dirfd, sig[0], &fake_io));
    }
    close(dev[1]);
    close(sig[0]);
    c.peer = dev[0];
    c.sig = sig[1];
    return c;
}

static int finish(struct child *c)
{
    int status = 0;

    close(c->peer);
    close(c->sig);
    if (waitpid(c->pid, &status, 0) < 0)
        return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void test_map_and_parse(void)
{
    enum coverd_fold f = COVERD_FOLDED;
    unsigned char r[17] = { 0x23, 0x22 };

    CHECK(coverd_map(0x22) == COVERD_TYPING);
    CHECK(coverd_map(0x33) == COVERD_BETWEEN);
    CHECK(coverd_map(0x43) == COVERD_FOLDED);
    for (int v = 0; v < 256; v++) {
        if (v != 0x22 && v != 0x33 && v != 0x43)
            CHECK(coverd_map((unsigned char)v) == COVERD_UNKNOWN);
    }
    CHECK(strcmp(coverd_word(COVERD_TYPING), "typing") == 0);
    CHECK(strcmp(coverd_word(COVERD_BETWEEN), "between") == 0);
    CHECK(strcmp(coverd_word(COVERD_FOLDED), "folded") == 0);
    CHECK(strcmp(coverd_word(COVERD_UNKNOWN), "unknown") == 0);
    CHECK(strcmp(coverd_word((enum coverd_fold)99), "unknown") == 0);

    CHECK(coverd_parse(r, sizeof r, &f) == 1 && f == COVERD_TYPING);
    CHECK(coverd_parse(r, 2, &f) == 1 && f == COVERD_TYPING);
    r[1] = 0x43;
    CHECK(coverd_parse(r, sizeof r, &f) == 1 && f == COVERD_FOLDED);
    r[1] = 0x7f;
    CHECK(coverd_parse(r, sizeof r, &f) == 1 && f == COVERD_UNKNOWN);

    /* Too short, another report ID, or nothing at all: not a fold report,
     * and the output is left alone. */
    f = COVERD_BETWEEN;
    CHECK(coverd_parse(r, 1, &f) == 0 && f == COVERD_BETWEEN);
    CHECK(coverd_parse(r, 0, &f) == 0 && f == COVERD_BETWEEN);
    CHECK(coverd_parse(NULL, 17, &f) == 0 && f == COVERD_BETWEEN);
    CHECK(coverd_parse(r, 17, NULL) == 0);
    for (int id = 0; id < 256; id++) {
        unsigned char k[17] = { (unsigned char)id, 0x43 };
        if (id != 0x23)
            CHECK(coverd_parse(k, sizeof k, &f) == 0 && f == COVERD_BETWEEN);
    }
}

static void test_descriptor(const char *path)
{
    unsigned char desc[4096];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t n;

    CHECK(fd >= 0);
    if (fd < 0)
        return;
    n = read(fd, desc, sizeof desc);
    close(fd);
    CHECK(n > 0);
    if (n <= 0)
        return;
    CHECK(coverd_descriptor_ok(desc, (size_t)n) == 1);
    CHECK(coverd_descriptor_ok(desc, 0) == 0);
    CHECK(coverd_descriptor_ok(NULL, (size_t)n) == 0);
    /* Truncated just before the report 35 item ends. */
    for (ssize_t i = 0; i + 8 <= n; i++) {
        if (desc[i] == 0x85 && desc[i + 1] == 0x23) {
            CHECK(coverd_descriptor_ok(desc, (size_t)i + 7) == 0);
            desc[i + 3] = 0x71; /* different usage */
            CHECK(coverd_descriptor_ok(desc, (size_t)n) == 0);
            break;
        }
    }
}

static void test_publish(int dirfd)
{
    char got[64];
    struct stat st;

    CHECK(coverd_publish(dirfd, COVERD_FOLDED) == 0);
    read_state(dirfd, got, sizeof got);
    CHECK(strcmp(got, "folded\n") == 0);
    CHECK(fstatat(dirfd, COVERD_STATE_NAME, &st, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK((st.st_mode & 07777) == 0644);
    CHECK(faccessat(dirfd, COVERD_STATE_TEMP, F_OK, 0) < 0);

    /* A symlink planted at the temporary name is not followed. */
    CHECK(symlinkat("/dev/null", dirfd, COVERD_STATE_TEMP) == 0);
    CHECK(coverd_publish(dirfd, COVERD_TYPING) == -ELOOP);
    read_state(dirfd, got, sizeof got);
    CHECK(strcmp(got, "folded\n") == 0);
    CHECK(unlinkat(dirfd, COVERD_STATE_TEMP, 0) == 0 || errno == ENOENT);

    coverd_clear(dirfd);
    CHECK(faccessat(dirfd, COVERD_STATE_NAME, F_OK, 0) < 0);
}

static void test_publish_to_removed_dir(const char *base)
{
    char path[512];
    int fd;

    snprintf(path, sizeof path, "%s/gone", base);
    CHECK(mkdir(path, 0755) == 0);
    fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    CHECK(fd >= 0);
    CHECK(rmdir(path) == 0);
    CHECK(coverd_publish(fd, COVERD_FOLDED) < 0);
    close(fd);
}

static void test_loop(int dirfd)
{
    static const unsigned char keystroke[] = { 0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
    static const unsigned char short35[] = { 0x23 };
    struct child c;
    char got[64];

    /* Initial GET_REPORT decides the first word; nothing is published
     * before it. The loop runs under coverd_lockdown() in every child. */
    fake->position = 0x43;
    fake->queries = 0;
    fake->published_before_query = 0;
    test_dirfd = dirfd;
    c = start(dirfd);
    CHECK(wait_state(dirfd, "folded\n"));
    CHECK(fake->queries == 1);
    CHECK(fake->published_before_query == 0);

    send_fold(c.peer, 0x33);
    CHECK(wait_state(dirfd, "between\n"));
    send_fold(c.peer, 0x22);
    CHECK(wait_state(dirfd, "typing\n"));

    /* Keystrokes and truncated reports never change or appear in the file. */
    for (int i = 0; i < 50; i++)
        send_report(c.peer, keystroke, sizeof keystroke);
    send_report(c.peer, short35, sizeof short35);
    send_fold(c.peer, 0x43);
    CHECK(wait_state(dirfd, "folded\n"));
    send_fold(c.peer, 0x99);
    CHECK(wait_state(dirfd, "unknown\n"));
    send_fold(c.peer, 0x43);
    CHECK(wait_state(dirfd, "folded\n"));

    /* No new query without a resume. */
    CHECK(fake->queries == 1);

    /* Folded back to typing during suspend with no report: the resume is
     * seen from the clocks and GET_REPORT is sent again. */
    fake->position = 0x22;
    fake->suspended += 30LL * 1000000000LL;
    CHECK(wait_queries(2));
    CHECK(wait_state(dirfd, "typing\n"));

    /* A GET_REPORT that fails after resume is retried, retry_ms apart
     * however many reports arrive meanwhile, and the word is left alone. */
    fake->get_errno = EPIPE;
    fake->position = 0x43;
    {
        int before = fake->queries, during;
        struct timespec t0, t1;
        long elapsed_ms;

        fake->suspended += 30LL * 1000000000LL;
        CHECK(wait_queries(before + 1));
        clock_gettime(CLOCK_MONOTONIC, &t0);
        during = fake->queries;
        for (int i = 0; i < 300; i++)
            send_report(c.peer, keystroke, sizeof keystroke);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
        CHECK(fake->queries - during <= elapsed_ms / fake_io.retry_ms + 2);
        CHECK(wait_queries(before + 4));
    }
    read_state(dirfd, got, sizeof got);
    CHECK(strcmp(got, "typing\n") == 0);
    fake->get_errno = 0;
    CHECK(wait_state(dirfd, "folded\n"));

    /* Unplugging (the peer closes) exits with the "gone" code and removes
     * the state file so no stale position lingers. */
    close(c.peer);
    c.peer = -1;
    {
        int status = 0;
        CHECK(waitpid(c.pid, &status, 0) == c.pid);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == COVERD_EXIT_GONE);
        close(c.sig);
    }
    CHECK(faccessat(dirfd, COVERD_STATE_NAME, F_OK, 0) < 0);
    CHECK(faccessat(dirfd, COVERD_STATE_TEMP, F_OK, 0) < 0);

    /* A stop request exits cleanly and removes the file. */
    fake->position = 0x43;
    c = start(dirfd);
    CHECK(wait_state(dirfd, "folded\n"));
    CHECK(write(c.sig, "x", 1) == 1);
    CHECK(finish(&c) == COVERD_EXIT_STOPPED);
    CHECK(faccessat(dirfd, COVERD_STATE_NAME, F_OK, 0) < 0);

    /* GET_REPORT failing with ENODEV at start means the cover is gone. */
    fake->get_errno = ENODEV;
    c = start(dirfd);
    CHECK(finish(&c) == COVERD_EXIT_GONE);
    CHECK(faccessat(dirfd, COVERD_STATE_NAME, F_OK, 0) < 0);

    /* GET_REPORT unsupported: still starts, says unknown (after the first
     * failed query, not before), follows reports. */
    fake->get_errno = EINVAL;
    fake->queries = 0;
    fake->published_before_query = 0;
    c = start(dirfd);
    CHECK(wait_state(dirfd, "unknown\n"));
    send_fold(c.peer, 0x43);
    CHECK(wait_state(dirfd, "folded\n"));
    CHECK(fake->published_before_query == 0);
    CHECK(write(c.sig, "x", 1) == 1);
    CHECK(finish(&c) == COVERD_EXIT_STOPPED);
    fake->get_errno = 0;
    test_dirfd = -1;
}

/* Run fn in a child under coverd_lockdown() with /dev/null as standard input
 * and return its wait status. */
static int locked(void (*fn)(void))
{
    pid_t pid = fork();
    int status = 0;

    if (pid < 0)
        return -1;
    if (pid == 0) {
        int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (null < 0 || dup2(null, STDIN_FILENO) < 0)
            _exit(98);
        if (coverd_lockdown() < 0)
            _exit(99);
        fn();
        _exit(0);
    }
    if (waitpid(pid, &status, 0) < 0)
        return -1;
    return status;
}

static int killed_by_sigsys(int status)
{
    return status >= 0 && WIFSIGNALED(status) && WTERMSIG(status) == SIGSYS;
}

static void do_get_report(void)
{
    unsigned char buf[COVERD_REPORT_MAX] = { COVERD_REPORT_ID };
    /* Allowed; /dev/null answers ENOTTY. */
    if (ioctl(STDIN_FILENO, HIDIOCGINPUT(COVERD_REPORT_MAX), buf) != -1 || errno != ENOTTY)
        _exit(1);
}

static void do_set_feature(void)
{
    unsigned char buf[2] = { 0x23, 0 };
    (void)ioctl(STDIN_FILENO, HIDIOCSFEATURE(2), buf);
}

static void do_set_output(void)
{
    unsigned char buf[2] = { 0x23, 0 };
    (void)ioctl(STDIN_FILENO, HIDIOCSOUTPUT(2), buf);
}

static void do_get_report_other_fd(void)
{
    unsigned char buf[COVERD_REPORT_MAX] = { COVERD_REPORT_ID };
    (void)ioctl(STDERR_FILENO, HIDIOCGINPUT(COVERD_REPORT_MAX), buf);
}

static void do_get_report_other_size(void)
{
    unsigned char buf[COVERD_REPORT_MAX] = { COVERD_REPORT_ID };
    (void)ioctl(STDIN_FILENO, HIDIOCGINPUT(17), buf);
}

static void do_getpid(void)
{
    (void)syscall(SYS_getpid);
}

static void do_socket(void)
{
    (void)syscall(SYS_socket, AF_UNIX, SOCK_STREAM, 0);
}

static void do_x32_getpid(void)
{
    (void)syscall(0x40000000 | SYS_getpid);
}

static void do_execve(void)
{
    char *argv[] = { (char *)"/bin/true", NULL };
    char *envp[] = { NULL };
    (void)syscall(SYS_execve, "/bin/true", argv, envp);
}

static void test_lockdown(void)
{
    CHECK(locked(do_get_report) == 0);
    CHECK(killed_by_sigsys(locked(do_set_feature)));
    CHECK(killed_by_sigsys(locked(do_set_output)));
    CHECK(killed_by_sigsys(locked(do_get_report_other_fd)));
    CHECK(killed_by_sigsys(locked(do_get_report_other_size)));
    CHECK(killed_by_sigsys(locked(do_getpid)));
    CHECK(killed_by_sigsys(locked(do_socket)));
    CHECK(killed_by_sigsys(locked(do_x32_getpid)));
    CHECK(killed_by_sigsys(locked(do_execve)));
}

static ssize_t folded_get_report(int fd, unsigned char *buf, size_t len)
{
    (void)fd;
    if (len < 17)
        return -EINVAL;
    memset(buf, 0, 17);
    buf[0] = COVERD_REPORT_ID;
    buf[1] = 0x43;
    return 17;
}

static int64_t no_suspend(void)
{
    return 0;
}

static int serve_stdin(const char *dir)
{
    static const struct coverd_io io = {
        .get_report = folded_get_report,
        .suspended_ns = no_suspend,
        .tick_ms = 2000,
        .retry_ms = 500,
    };
    sigset_t stop;
    int dirfd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int sigfd;

    if (dirfd < 0) {
        perror(dir);
        return 1;
    }
    sigemptyset(&stop);
    sigaddset(&stop, SIGTERM);
    sigaddset(&stop, SIGINT);
    sigaddset(&stop, SIGHUP);
    if (sigprocmask(SIG_BLOCK, &stop, NULL) < 0) {
        perror("sigprocmask");
        return 1;
    }
    sigfd = signalfd(-1, &stop, SFD_CLOEXEC | SFD_NONBLOCK);
    if (sigfd < 0) {
        perror("signalfd");
        return 1;
    }
    if (coverd_lockdown() < 0)
        return 1;
    return coverd_serve(STDIN_FILENO, dirfd, sigfd, &io);
}

int main(int argc, char **argv)
{
    char base[] = "/tmp/gimbal-sp4-coverd-test.XXXXXX";
    char cmd[128];
    int dirfd;

    if (argc == 3 && strcmp(argv[1], "--serve-stdin") == 0)
        return serve_stdin(argv[2]);
    if (argc != 2) {
        fprintf(stderr, "usage: test_coverd <report descriptor fixture>\n");
        return 2;
    }
    fake = mmap(NULL, sizeof *fake, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (fake == MAP_FAILED || mkdtemp(base) == NULL) {
        perror("setup");
        return 1;
    }
    memset((void *)fake, 0, sizeof *fake);
    dirfd = open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) {
        perror(base);
        return 1;
    }

    test_map_and_parse();
    test_descriptor(argv[1]);
    test_publish(dirfd);
    test_publish_to_removed_dir(base);
    test_loop(dirfd);
    test_lockdown();

    close(dirfd);
    snprintf(cmd, sizeof cmd, "rm -rf -- '%s'", base);
    if (system(cmd) != 0)
        fprintf(stderr, "could not remove %s\n", base);

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("coverd tests passed\n");
    return 0;
}
