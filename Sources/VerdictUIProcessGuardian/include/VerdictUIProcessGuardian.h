#ifndef VERDICT_UI_PROCESS_GUARDIAN_H
#define VERDICT_UI_PROCESS_GUARDIAN_H
#include <sys/types.h>

/* No arbitrary PID adoption: only this launch returns a retained child. The
 * command leads a new session whose id is browser_pid; the guardian receives
 * that id at launch and sweeps the session when the caller dies. The caller
 * owns lifetime_fd and must retain BOTH returned children unreaped until
 * session cleanup. The caller observes browser exit and closes lifetime_fd;
 * the guardian independently detects caller death (including inherited writers).
 * Like public fork(), this requires async-signal-safe registered child handlers;
 * the controlled child path after fork returns calls only async-safe functions. */
typedef struct {
    pid_t guardian_pid;
    pid_t browser_pid; /* direct child; this number alone is not signal authority */
    int lifetime_fd;
    int group_ready;
    int error;
} vui_guardian_launch_result;

/* Each stdio descriptor is borrowed for this call; -1 opens /dev/null.
 * Other negative or closed descriptors fail before any child is launched.
 * Concurrently closing caller descriptors during launch is unsupported. */
int vui_guardian_launch(const char *executable, char *const argv[],
                        char *const environment[], const char *directory,
                        const int standard_descriptors[3], int handshake_ms, int grace_ms,
                        vui_guardian_launch_result *result);

/* TERM, then after grace_ms KILL, every live member of `session` until none
 * remain; ETIMEDOUT after grace_ms + timeout_ms. Authority comes only from the
 * caller: it must hold the session leader returned by vui_guardian_launch
 * unreaped, which keeps the id from being reallocated. */
int vui_session_sweep(pid_t session, int grace_ms, int timeout_ms);
#endif
