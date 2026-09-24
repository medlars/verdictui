#include "VerdictUIProcessGuardian.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct { int error; pid_t pid; } handshake;

static int64_t now_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int cloexec_pipe(int fd[2]) {
    if (pipe(fd) != 0) return errno;
    for (int index = 0; index < 2; ++index) {
        if (fd[index] < 3) {
            int replacement = fcntl(fd[index], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) goto failed;
            close(fd[index]); fd[index] = replacement;
        }
        if (fcntl(fd[index], F_SETFD, FD_CLOEXEC) < 0) goto failed;
    }
    return 0;
failed: {
    int error = errno; close(fd[0]); close(fd[1]); fd[0] = fd[1] = -1;
    return error;
}}

/* Parent-only inventory covers descriptors surviving a lowered soft limit.
 * The kernel allocation ceiling also covers concurrent ordinary opens between
 * inventory and fork. A caller concurrently changing process-wide limits is
 * outside this launch contract. Never allocate or query libproc in the child. */
static int descriptor_ceiling(void) {
    int ceiling = getdtablesize(), kernel_limit = 0;
    size_t length = sizeof(kernel_limit);
    if (sysctlbyname("kern.maxfilesperproc", &kernel_limit, &length, NULL, 0) != 0) return -1;
    if (kernel_limit > ceiling) ceiling = kernel_limit;
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 16 * 1024 * 1024) { errno = E2BIG; return -1; }
    int capacity = bytes + 4096;
    struct proc_fdinfo *descriptors = malloc((size_t)capacity);
    if (!descriptors) return -1;
    int count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, descriptors, capacity);
    if (count <= 0 || count >= capacity) { free(descriptors); errno = E2BIG; return -1; }
    for (int index = 0; index < count / (int)sizeof(*descriptors); ++index) {
        int fd = descriptors[index].proc_fd;
        if (fd >= 1048576) { free(descriptors); errno = E2BIG; return -1; }
        if (fd >= ceiling) ceiling = fd + 1;
    }
    free(descriptors);
    if (ceiling < 3 || ceiling > 1048576) { errno = E2BIG; return -1; }
    return ceiling;
}

/* POST-FORK AUDIT: after libc fork returns, these routines use only stack
 * storage and async-signal-safe calls. No allocator, Swift, Foundation,
 * logging, dispatch, second fork or posix_spawn runs in this child. */
static _Noreturn void dispose_group(int grace_ms) {
    /* The guardian is alive and is this group's leader for both signals. */
    (void)kill(0, SIGTERM);
    int64_t start = now_ms(), deadline = start + grace_ms;
    for (;;) {
        int64_t now = now_ms();
        if (now < 0 || now >= deadline) break;
        (void)poll(NULL, 0, 10);
    }
    (void)kill(0, SIGKILL);
    _exit(125);
}

static int owner_gone(int lifetime, pid_t parent) {
    if (getppid() != parent) return 1;
    struct pollfd descriptor = { lifetime, POLLIN | POLLHUP, 0 };
    int result = poll(&descriptor, 1, 0);
    if (result < 0 && errno != EINTR) return 1;
    if (result > 0 && descriptor.revents) {
        char byte;
        return read(lifetime, &byte, 1) <= 0;
    }
    return 0;
}

static _Noreturn void child_main(int lifetime, int output, int descriptor_limit,
                                pid_t parent, int grace_ms) {
    struct sigaction defaults = {0}, ignored = {0};
    defaults.sa_handler = SIG_DFL; ignored.sa_handler = SIG_IGN;
    sigemptyset(&defaults.sa_mask); sigemptyset(&ignored.sa_mask);
    for (int number = 1; number < NSIG; ++number) {
        if (number != SIGKILL && number != SIGSTOP) (void)sigaction(number, &defaults, NULL);
    }
    (void)sigaction(SIGTERM, &ignored, NULL);
    (void)sigaction(SIGINT, &ignored, NULL);
    (void)sigaction(SIGPIPE, &ignored, NULL);
    // Remain in the owner's session so its posix_spawn can join this group.
    if (setpgid(0, 0) != 0) _exit(126);
    sigset_t empty; sigemptyset(&empty); (void)sigprocmask(SIG_SETMASK, &empty, NULL);
    for (int fd = 0; fd < descriptor_limit; ++fd) {
        if (fd != lifetime && fd != output) (void)close(fd);
    }
    if (owner_gone(lifetime, parent)) dispose_group(0);
    handshake value = {0, getpid()};
    ssize_t written;
    do { written = write(output, &value, sizeof(value)); } while (written < 0 && errno == EINTR);
    if (written != (ssize_t)sizeof(value)) dispose_group(grace_ms);
    close(output);
    for (;;) {
        if (owner_gone(lifetime, parent)) dispose_group(grace_ms);
        struct pollfd descriptor = { lifetime, POLLIN | POLLHUP, 0 };
        (void)poll(&descriptor, 1, 20);
    }
}

/* Parent-only: posix_spawn reports exec failure synchronously and its CLOEXEC
 * default prevents the browser inheriting either pipe (or any caller fd). */
static int spawn_browser(const char *executable, char *const argv[], char *const environment[],
                         pid_t guardian, pid_t *browser) {
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int error = posix_spawnattr_init(&attributes);
    if (error) return error;
    error = posix_spawn_file_actions_init(&actions);
    if (error) { posix_spawnattr_destroy(&attributes); return error; }
    sigset_t defaults, mask; sigfillset(&defaults); sigemptyset(&mask);
    if (!(error = posix_spawnattr_setpgroup(&attributes, guardian)) &&
        !(error = posix_spawnattr_setsigdefault(&attributes, &defaults)) &&
        !(error = posix_spawnattr_setsigmask(&attributes, &mask)) &&
        !(error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |
                                         POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))) {
        for (int fd = 0; fd <= 2 && !error; ++fd)
            error = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0);
        if (!error) error = posix_spawn(browser, executable, &actions, &attributes, argv, environment);
    }
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    return error;
}

int vui_guardian_launch(const char *executable, char *const argv[], char *const environment[],
                        int handshake_ms, int grace_ms, vui_guardian_launch_result *result) {
    *result = (vui_guardian_launch_result){ -1, -1, -1, 0, 0 };
    if (handshake_ms < 1 || handshake_ms > 10000 || grace_ms < 0 || grace_ms > 5000) return EINVAL;
    int lifetime[2] = {-1,-1}, output[2] = {-1,-1}, error;
    if ((error = cloexec_pipe(lifetime)) || (error = cloexec_pipe(output))) goto failed;
    int descriptor_limit = descriptor_ceiling();
    if (descriptor_limit < 0) { error = errno; goto failed; }
    int64_t start = now_ms();
    if (start < 0) { error = errno; goto failed; }
    sigset_t blocked, original; sigfillset(&blocked);
    error = pthread_sigmask(SIG_SETMASK, &blocked, &original);
    if (error) goto failed;
    pid_t parent = getpid();
    pid_t guardian = fork();
    if (guardian == 0) child_main(lifetime[0], output[1], descriptor_limit, parent, grace_ms);
    error = errno;
    int restored = pthread_sigmask(SIG_SETMASK, &original, NULL);
    if (guardian < 0) goto failed;
    close(lifetime[0]); close(output[1]);
    result->guardian_pid = guardian; result->lifetime_fd = lifetime[1];
    if (restored) { result->error = restored; goto completed; }
    int64_t deadline = start + handshake_ms;
    handshake value; size_t received = 0;
    while (received < sizeof(value)) {
        int64_t now = now_ms(), remaining = deadline - now;
        if (now < 0 || remaining <= 0) { result->error = ETIMEDOUT; goto completed; }
        struct pollfd descriptor = { output[0], POLLIN | POLLHUP, 0 };
        int ready = poll(&descriptor, 1, (int)remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) { result->error = ready == 0 ? ETIMEDOUT : errno; goto completed; }
        ssize_t count = read(output[0], (char *)&value + received, sizeof(value) - received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { result->error = EPIPE; goto completed; }
        received += (size_t)count;
    }
    if (value.error || value.pid != guardian || getpgid(guardian) != guardian) {
        result->error = EPROTO; goto completed;
    }
    result->group_ready = 1;
    result->error = spawn_browser(executable, argv, environment, guardian, &result->browser_pid);
completed:
    close(output[0]);
    return 0; /* Failed handshakes also return retained children for cleanup. */
failed:
    for (int i = 0; i < 2; ++i) { if (lifetime[i] >= 0) close(lifetime[i]); if (output[i] >= 0) close(output[i]); }
    return error;
}
