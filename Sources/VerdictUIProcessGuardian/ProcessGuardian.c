#include "VerdictUIProcessGuardian.h"
#include <Availability.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
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

/* Parent-only: one slot per possible process plus headroom, so a full listing
 * is a failure rather than a silently truncated session. */
static int pid_capacity(void) {
    int limit = 0;
    size_t length = sizeof(limit);
    if (sysctlbyname("kern.maxproc", &limit, &length, NULL, 0) != 0) return -1;
    if (limit < 1 || limit > 1048576) { errno = E2BIG; return -1; }
    return limit + 1024;
}

/* POST-FORK AUDIT: after libc fork returns, these routines use only stack
 * storage, the parent-allocated PID buffer, and direct system calls
 * (proc_listpids is a __proc_info wrapper that never allocates). No allocator,
 * Swift, Foundation, logging, dispatch, second fork or posix_spawn runs in
 * this child.
 *
 * Session membership is the launch-time authority: the command is spawned as
 * the leader of a new session, so its PID is the session id, and XNU never
 * allocates a PID equal to a live session id. getsid(p) == session therefore
 * names only processes that inherited our session; setpgid() cannot leave it.
 * A descendant that calls setsid() itself leaves this contract. Zombies no
 * longer resolve through getsid and are not counted as live members. */
static int signal_session(pid_t session, int number, pid_t *pids, int capacity) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, capacity * (int)sizeof(pid_t));
    if (bytes <= 0 || bytes >= capacity * (int)sizeof(pid_t)) return -1;
    int live = 0;
    for (int index = 0; index < bytes / (int)sizeof(pid_t); ++index) {
        pid_t pid = pids[index];
        if (pid <= 0 || getsid(pid) != session) continue;
        ++live;
        if (number) (void)kill(pid, number);
    }
    return live;
}

/* TERM every live member, KILL whatever remains after the grace, and repeat
 * until the session has no live member. Never returns success while a live
 * member could remain. */
static int sweep_session(pid_t session, int grace_ms, int timeout_ms, pid_t *pids, int capacity) {
    if (session <= 0) return 0;
    int64_t start = now_ms();
    if (start < 0) return EINVAL;
    int live = signal_session(session, grace_ms > 0 ? SIGTERM : SIGKILL, pids, capacity);
    for (;;) {
        if (live == 0) return 0;
        int64_t now = now_ms();
        if (now < 0 || now - start >= (int64_t)grace_ms + timeout_ms) return ETIMEDOUT;
        (void)poll(NULL, 0, 10);
        live = signal_session(session, now - start >= grace_ms ? SIGKILL : 0, pids, capacity);
    }
}

static _Noreturn void dispose_session(pid_t session, int grace_ms, pid_t *pids, int capacity) {
    _exit(sweep_session(session, grace_ms, 5000, pids, capacity) == 0 ? 125 : 124);
}

/* The owner writes exactly one pid_t record (the session it launched) and
 * otherwise only closes its writer. Pending bytes are consumed before death is
 * acted on, so a record written just before the owner died is never lost. */
static int owner_gone(int lifetime, pid_t parent, pid_t *session, unsigned char *record, size_t *received) {
    int parent_changed = getppid() != parent;
    for (;;) {
        struct pollfd descriptor = { lifetime, POLLIN | POLLHUP, 0 };
        int result = poll(&descriptor, 1, 0);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return 1;
        if (result == 0 || !descriptor.revents) return parent_changed;
        unsigned char scratch;
        int complete = *received == sizeof(pid_t);
        ssize_t count = complete ? read(lifetime, &scratch, 1)
                                 : read(lifetime, record + *received, sizeof(pid_t) - *received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 1;
        if (!complete) {
            *received += (size_t)count;
            if (*received == sizeof(pid_t)) memcpy(session, record, sizeof(pid_t));
        }
    }
}

static _Noreturn void child_main(int lifetime, int output, int descriptor_limit,
                                pid_t parent, int grace_ms, pid_t *pids, int capacity) {
    struct sigaction defaults = {0}, ignored = {0};
    defaults.sa_handler = SIG_DFL; ignored.sa_handler = SIG_IGN;
    sigemptyset(&defaults.sa_mask); sigemptyset(&ignored.sa_mask);
    for (int number = 1; number < NSIG; ++number) {
        if (number != SIGKILL && number != SIGSTOP) (void)sigaction(number, &defaults, NULL);
    }
    (void)sigaction(SIGTERM, &ignored, NULL);
    (void)sigaction(SIGINT, &ignored, NULL);
    (void)sigaction(SIGPIPE, &ignored, NULL);
    // A private group lets the owner signal this guardian without its command.
    if (setpgid(0, 0) != 0) _exit(126);
    sigset_t empty; sigemptyset(&empty); (void)sigprocmask(SIG_SETMASK, &empty, NULL);
    for (int fd = 0; fd < descriptor_limit; ++fd) {
        if (fd != lifetime && fd != output) (void)close(fd);
    }
    pid_t session = 0;
    unsigned char record[sizeof(pid_t)];
    size_t received = 0;
    if (owner_gone(lifetime, parent, &session, record, &received)) dispose_session(session, 0, pids, capacity);
    handshake value = {0, getpid()};
    ssize_t written;
    do { written = write(output, &value, sizeof(value)); } while (written < 0 && errno == EINTR);
    if (written != (ssize_t)sizeof(value)) dispose_session(session, grace_ms, pids, capacity);
    close(output);
    for (;;) {
        if (owner_gone(lifetime, parent, &session, record, &received))
            dispose_session(session, grace_ms, pids, capacity);
        struct pollfd descriptor = { lifetime, POLLIN | POLLHUP, 0 };
        (void)poll(&descriptor, 1, 20);
    }
}

static int working_directory(posix_spawn_file_actions_t *actions, const char *directory) {
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 260000
    return posix_spawn_file_actions_addchdir(actions, directory);
#elif __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (__builtin_available(macOS 26.0, *)) return posix_spawn_file_actions_addchdir(actions, directory);
    else return posix_spawn_file_actions_addchdir_np(actions, directory);
#else
    return posix_spawn_file_actions_addchdir_np(actions, directory);
#endif
}

/* Parent-only: posix_spawn reports exec failure synchronously and its CLOEXEC
 * default prevents the browser inheriting either pipe (or any caller fd).
 * SETSID makes the command the leader of a session created by this launch. */
static int spawn_command(const char *executable, char *const argv[], char *const environment[],
                         const char *directory, const int descriptors[3], pid_t *child) {
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int error = posix_spawnattr_init(&attributes);
    if (error) return error;
    error = posix_spawn_file_actions_init(&actions);
    if (error) { posix_spawnattr_destroy(&attributes); return error; }
    sigset_t defaults, mask; sigfillset(&defaults); sigemptyset(&mask);
    if (!(error = posix_spawnattr_setsigdefault(&attributes, &defaults)) &&
        !(error = posix_spawnattr_setsigmask(&attributes, &mask)) &&
        !(error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF |
                                         POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))) {
        error = working_directory(&actions, directory);
        for (int fd = 0; fd <= 2 && !error; ++fd) {
            if (descriptors[fd] >= 0)
                error = posix_spawn_file_actions_adddup2(&actions, descriptors[fd], fd);
            else error = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0);
        }
        if (!error) error = posix_spawn(child, executable, &actions, &attributes, argv, environment);
    }
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    return error;
}

int vui_guardian_launch(const char *executable, char *const argv[], char *const environment[],
                        const char *directory, const int standard_descriptors[3],
                        int handshake_ms, int grace_ms, vui_guardian_launch_result *result) {
    *result = (vui_guardian_launch_result){ -1, -1, -1, 0, 0 };
    if (!executable || !argv || !environment || !directory || !standard_descriptors) return EINVAL;
    if (handshake_ms < 1 || handshake_ms > 10000 || grace_ms < 0 || grace_ms > 5000) return EINVAL;
    int lifetime[2] = {-1,-1}, output[2] = {-1,-1}, error;
    int descriptors[3] = {-1,-1,-1};
    pid_t *pids = NULL;
    /* Parent-only snapshots avoid aliasing stdio actions (including 0/1/2 swaps).
     * Capture before creating any pipe so a closed caller fd cannot be reused by
     * our own setup. The guardian closes every snapshot before READY. */
    for (int fd = 0; fd <= 2; ++fd) {
        if (standard_descriptors[fd] < -1) { error = EBADF; goto failed; }
        if (standard_descriptors[fd] >= 0 && fcntl(standard_descriptors[fd], F_GETFD) < 0) {
            error = errno; goto failed;
        }
    }
    for (int fd = 0; fd <= 2; ++fd) {
        if (standard_descriptors[fd] >= 0) {
            descriptors[fd] = fcntl(standard_descriptors[fd], F_DUPFD_CLOEXEC, 3);
            if (descriptors[fd] < 0) { error = errno; goto failed; }
        }
    }
    if ((error = cloexec_pipe(lifetime)) || (error = cloexec_pipe(output))) goto failed;
    /* A dead guardian must surface as EPIPE from the session record, not kill the owner. */
    if (fcntl(lifetime[1], F_SETNOSIGPIPE, 1) < 0) { error = errno; goto failed; }
    int capacity = pid_capacity();
    if (capacity < 0) { error = errno; goto failed; }
    pids = malloc((size_t)capacity * sizeof(pid_t));
    if (!pids) { error = ENOMEM; goto failed; }
    int descriptor_limit = descriptor_ceiling();
    if (descriptor_limit < 0) { error = errno; goto failed; }
    int64_t start = now_ms();
    if (start < 0) { error = errno; goto failed; }
    sigset_t blocked, original; sigfillset(&blocked);
    error = pthread_sigmask(SIG_SETMASK, &blocked, &original);
    if (error) goto failed;
    pid_t parent = getpid();
    pid_t guardian = fork();
    if (guardian == 0) child_main(lifetime[0], output[1], descriptor_limit, parent, grace_ms, pids, capacity);
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
    result->error = spawn_command(executable, argv, environment, directory, descriptors, &result->browser_pid);
    if (!result->error) {
        /* An owner killed between posix_spawn returning and this write leaves
         * the guardian without the session: the one uncovered launch window. */
        pid_t session = result->browser_pid;
        ssize_t written;
        do { written = write(lifetime[1], &session, sizeof(session)); } while (written < 0 && errno == EINTR);
        if (written != (ssize_t)sizeof(session)) {
            result->error = written < 0 ? errno : EPIPE;
            /* The unreaped command still pins the session id here. */
            (void)sweep_session(session, 0, 2000, pids, capacity);
        }
    }
completed:
    for (int fd = 0; fd <= 2; ++fd) if (descriptors[fd] >= 0) close(descriptors[fd]);
    close(output[0]);
    free(pids);
    return 0; /* Failed handshakes also return retained children for cleanup. */
failed:
    for (int fd = 0; fd <= 2; ++fd) if (descriptors[fd] >= 0) close(descriptors[fd]);
    for (int i = 0; i < 2; ++i) { if (lifetime[i] >= 0) close(lifetime[i]); if (output[i] >= 0) close(output[i]); }
    free(pids);
    return error;
}

int vui_session_sweep(pid_t session, int grace_ms, int timeout_ms) {
    if (session <= 0 || grace_ms < 0 || grace_ms > 60000 || timeout_ms < 0 || timeout_ms > 60000) return EINVAL;
    int capacity = pid_capacity();
    if (capacity < 0) return errno;
    pid_t *pids = malloc((size_t)capacity * sizeof(pid_t));
    if (!pids) return ENOMEM;
    int error = sweep_session(session, grace_ms, timeout_ms, pids, capacity);
    free(pids);
    return error;
}
