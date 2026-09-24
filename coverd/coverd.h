/* Type Cover fold helper: the parts that do not touch a real device.
 *
 * The daemon (gimbal-sp4-coverd.c) checks that its standard input is the
 * Surface Pro 4 Type Cover and then hands it to coverd_serve(). The tests
 * (test_coverd.c) hand the same function a socket pair instead, so every line
 * below runs under test while the device checks stay in the production
 * binary only. */
#ifndef GIMBAL_SP4_COVERD_H
#define GIMBAL_SP4_COVERD_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* Vendor input report carrying the fold position in its first data byte. */
#define COVERD_REPORT_ID 0x23
/* Every report on this interface fits; hidraw truncates anything longer. */
#define COVERD_REPORT_MAX 64

/* The one file published, relative to the state directory. */
#define COVERD_STATE_NAME "fold"
#define COVERD_STATE_TEMP "fold.tmp"

#define COVERD_EXIT_STOPPED 0 /* SIGTERM, SIGINT or SIGHUP */
#define COVERD_EXIT_FAILED 1  /* anything unexpected */
#define COVERD_EXIT_USAGE 2   /* wrong arguments or not the Type Cover */
#define COVERD_EXIT_GONE 69   /* the cover went away (EX_UNAVAILABLE) */

enum coverd_fold {
    COVERD_UNKNOWN = 0,
    COVERD_TYPING,
    COVERD_BETWEEN,
    COVERD_FOLDED,
};

/* 0x22 typing, 0x33 part-way, 0x43 folded back; anything else is unknown. */
enum coverd_fold coverd_map(unsigned char position);

/* Returns 1 and sets *fold when buf is report 35 with a position byte;
 * returns 0 for every other report, which the caller must discard. */
int coverd_parse(const unsigned char *buf, size_t len, enum coverd_fold *fold);

/* "typing", "between", "folded" or "unknown". */
const char *coverd_word(enum coverd_fold fold);

/* Returns 1 when the report descriptor declares report 35 as four input
 * usages 0xff050072..75, the layout this program was measured against. */
int coverd_descriptor_ok(const unsigned char *desc, size_t len);

/* Atomically replace <dir>/fold with the word and a newline, mode 0644.
 * Returns 0 or -errno. */
int coverd_publish(int dirfd, enum coverd_fold fold);

/* Remove <dir>/fold so no stale position outlives the daemon. */
void coverd_clear(int dirfd);

/* Install a seccomp filter allowing only the syscalls coverd_serve() needs,
 * with ioctl limited to GET_REPORT (HIDIOCGINPUT(64)) on standard input.
 * Anything else kills the process. Call after all setup. Returns 0 or -1. */
int coverd_lockdown(void);

struct coverd_io {
    /* Ask the device for report 35 (GET_REPORT). buf[0] is preset to the
     * report ID. Returns the report length or -errno. Only called with
     * len == COVERD_REPORT_MAX. */
    ssize_t (*get_report)(int fd, unsigned char *buf, size_t len);
    /* Time spent suspended so far, in nanoseconds; grows across a suspend. */
    int64_t (*suspended_ns)(void);
    /* Poll timeout while idle; a resume is noticed within this long. */
    int tick_ms;
    /* Poll timeout while a GET_REPORT is being retried. */
    int retry_ms;
};

/* Publish the fold position read from devfd until the device goes away or a
 * signal arrives on sigfd (-1 for none). Removes the state file on return.
 * Returns one of the COVERD_EXIT_* codes. */
int coverd_serve(int devfd, int dirfd, int sigfd, const struct coverd_io *io);

#endif
