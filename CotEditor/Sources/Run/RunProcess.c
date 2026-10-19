// SPDX-License-Identifier: Apache-2.0
#define _GNU_SOURCE
#include "RunProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CE_LIMIT (10u * 1024u * 1024u)
struct CERunProcess {
    pthread_mutex_t lock;
    pid_t group;
    int input;
    bool stopped, initial_sent;
    unsigned char *output[2];
    size_t count[2], omitted[2];
};
#ifdef CE_RUN_TEST_CLOCK
extern double ce_run_test_now(void);
#define now ce_run_test_now
#else
static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
#endif
CERunProcess *ce_run_create(void) {
    CERunProcess *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    pthread_mutex_init(&r->lock, NULL); r->input = -1;
    for (int i = 0; i < 2; i++) {
        r->output[i] = malloc(CE_LIMIT);
        if (!r->output[i]) { ce_run_destroy(r); return NULL; }
    }
    return r;
}
void ce_run_eof(CERunProcess *r) {
    pthread_mutex_lock(&r->lock);
    if (r->input >= 0) { close(r->input); r->input = -1; }
    pthread_mutex_unlock(&r->lock);
}
void ce_run_stop(CERunProcess *r) {
    pthread_mutex_lock(&r->lock);
    r->stopped = true;
    if (r->input >= 0) { close(r->input); r->input = -1; }
    // The group leader is never reaped until group cleanup finishes, preventing
    // PID/group-ID reuse while this ownership token is signalable.
    if (r->group > 0) kill(-r->group, SIGTERM);
    pthread_mutex_unlock(&r->lock);
}
int ce_run_accepts_input(CERunProcess *r) {
    pthread_mutex_lock(&r->lock);
    int ready = r->input >= 0 && !r->stopped && r->initial_sent;
    pthread_mutex_unlock(&r->lock);
    return ready;
}
void ce_run_wait_stopped(CERunProcess *r) {
    ce_run_stop(r);
    // The worker performs TERM/KILL and reaps; the caller only waits on ownership.
    for (;;) {
        pthread_mutex_lock(&r->lock); bool active = r->group > 0; pthread_mutex_unlock(&r->lock);
        if (!active) return;
        struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL);
    }
}
void ce_run_destroy(CERunProcess *r) {
    if (!r) return;
    ce_run_eof(r);
    for (int i = 0; i < 2; i++) free(r->output[i]);
    pthread_mutex_destroy(&r->lock); free(r);
}
long ce_run_send(CERunProcess *r, const void *bytes, size_t count) {
    pthread_mutex_lock(&r->lock);
    long result = -EPIPE;
    if (r->input >= 0 && !r->stopped) {
#ifdef MSG_NOSIGNAL
        result = send(r->input, bytes, count, MSG_NOSIGNAL);
#else
        result = send(r->input, bytes, count, 0); // SO_NOSIGPIPE below on Darwin.
#endif
        if (result < 0) {
            int error = errno;
            if (error == EPIPE || error == ECONNRESET) { close(r->input); r->input = -1; }
            result = -error;
        }
    }
    pthread_mutex_unlock(&r->lock);
    return result;
}
size_t ce_run_read(CERunProcess *r, int stream, size_t offset, void *bytes, size_t capacity, size_t *omitted) {
    if (stream < 0 || stream > 1) return 0;
    pthread_mutex_lock(&r->lock);
    size_t available = offset <= r->count[stream] ? r->count[stream] - offset : 0;
    size_t n = available < capacity ? available : capacity;
    if (n) memcpy(bytes, r->output[stream] + offset, n);
    if (omitted) *omitted = r->omitted[stream];
    pthread_mutex_unlock(&r->lock); return n;
}
size_t ce_run_copy(CERunProcess *r, int stream, void *bytes, size_t capacity, size_t *omitted) {
    return ce_run_read(r, stream, 0, bytes, capacity, omitted);
}
static void retain(CERunProcess *r, int stream, unsigned char *bytes, size_t n) {
    pthread_mutex_lock(&r->lock);
    size_t keep = CE_LIMIT - r->count[stream]; if (keep > n) keep = n;
    memcpy(r->output[stream] + r->count[stream], bytes, keep);
    r->count[stream] += keep; r->omitted[stream] += n - keep;
    pthread_mutex_unlock(&r->lock);
}
int ce_run_execute(CERunProcess *r, const char *executable, char *const argv[],
                   char *const envp[], const char *cwd, const void *initial, size_t initial_count, int keep_open, int *status) {
    int input[2] = {-1, -1}, pipes[2][2] = {{-1, -1}, {-1, -1}};
    int error = 0; pid_t pid = 0;
    posix_spawn_file_actions_t actions; posix_spawnattr_t attrs;
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attrs);
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, input) || pipe(pipes[0]) || pipe(pipes[1])) { error = errno; goto cleanup; }
    // Mark every parent/child endpoint close-on-exec before spawning.
    for (int i = 0; i < 2; i++) {
        fcntl(input[i], F_SETFD, FD_CLOEXEC);
        for (int j = 0; j < 2; j++) fcntl(pipes[i][j], F_SETFD, FD_CLOEXEC);
    }
#ifdef SO_NOSIGPIPE
    int one = 1; setsockopt(input[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    fcntl(input[0], F_SETFL, O_NONBLOCK);
    for (int i = 0; i < 2; i++) fcntl(pipes[i][0], F_SETFL, O_NONBLOCK);
#define CE_ACTION(call) do { error = (call); if (error) goto cleanup; } while (0)
    CE_ACTION(posix_spawn_file_actions_adddup2(&actions, input[1], STDIN_FILENO));
    CE_ACTION(posix_spawn_file_actions_adddup2(&actions, pipes[0][1], STDOUT_FILENO));
    CE_ACTION(posix_spawn_file_actions_adddup2(&actions, pipes[1][1], STDERR_FILENO));
    CE_ACTION(posix_spawn_file_actions_addchdir_np(&actions, cwd));
    sigset_t empty, defaults; sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    CE_ACTION(posix_spawnattr_setsigmask(&attrs, &empty));
    CE_ACTION(posix_spawnattr_setsigdefault(&attrs, &defaults));
    CE_ACTION(posix_spawnattr_setpgroup(&attrs, 0));
    CE_ACTION(posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    pthread_mutex_lock(&r->lock);
    if (r->stopped) error = ECANCELED;
    else error = posix_spawn(&pid, executable, &actions, &attrs, argv, envp);
    if (!error) { r->group = pid; r->initial_sent = false; r->input = input[0]; input[0] = -1; }
    pthread_mutex_unlock(&r->lock);
    if (error) goto cleanup;
    close(input[1]); input[1] = -1;
    for (int i = 0; i < 2; i++) { close(pipes[i][1]); pipes[i][1] = -1; }
    bool exited = false; double deadline = 0; size_t sent = 0;
    while (true) {
        if (sent < initial_count) {
            long n = ce_run_send(r, (const char *)initial + sent, initial_count - sent);
            if (n > 0) sent += (size_t)n;
            else if (n != -EAGAIN && n != -EWOULDBLOCK && n != -EINTR) sent = initial_count;
        }
        if (sent == initial_count) {
            pthread_mutex_lock(&r->lock); r->initial_sent = true; pthread_mutex_unlock(&r->lock);
            if (!keep_open) ce_run_eof(r);
        }
        siginfo_t info; memset(&info, 0, sizeof(info));
        if (!exited && waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid) exited = true;
        pthread_mutex_lock(&r->lock); bool stopped = r->stopped; pthread_mutex_unlock(&r->lock);
        if ((exited || stopped) && !deadline) {
            ce_run_eof(r); kill(-pid, SIGTERM); deadline = now() + 0.3;
        }
        if (deadline && now() >= deadline) {
            // Also clean ordinary descendants after a naturally exiting leader.
            kill(-pid, SIGKILL);
            if (exited) break;
        }
        struct pollfd fds[2] = {{pipes[0][0], POLLIN, 0}, {pipes[1][0], POLLIN, 0}};
        poll(fds, 2, 15);
        for (int i = 0; i < 2; i++) {
            unsigned char bytes[16384]; ssize_t n;
            // Bound each turn so one flooding stream cannot starve the other or Stop.
            for (int chunk = 0; chunk < 16; chunk++) {
                n = read(pipes[i][0], bytes, sizeof(bytes));
                if (n <= 0) break;
                retain(r, i, bytes, (size_t)n);
            }
        }
    }
    // Last bounded drain after group KILL (do not wait for escaped daemons).
    for (int i = 0; i < 2; i++) {
        unsigned char bytes[16384]; ssize_t n;
        for (int chunk = 0; chunk < 64; chunk++) {
            n = read(pipes[i][0], bytes, sizeof(bytes));
            if (n <= 0) break;
            retain(r, i, bytes, (size_t)n);
        }
    }
    pthread_mutex_lock(&r->lock);
    while (waitpid(pid, status, 0) < 0 && errno == EINTR) {}
    r->group = 0;
    pthread_mutex_unlock(&r->lock);
cleanup:
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs);
    for (int i = 0; i < 2; i++) {
        if (input[i] >= 0) close(input[i]);
        for (int j = 0; j < 2; j++) if (pipes[i][j] >= 0) close(pipes[i][j]);
    }
    return error;
}
