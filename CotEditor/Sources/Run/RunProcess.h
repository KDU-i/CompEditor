// SPDX-License-Identifier: Apache-2.0
// Small, owned process-group runner. No shell and no global signal handlers.
#ifndef CE_RUN_PROCESS_H
#define CE_RUN_PROCESS_H
#include <stddef.h>
typedef struct CERunProcess CERunProcess;
CERunProcess *ce_run_create(void);
void ce_run_destroy(CERunProcess *run);
// Synchronous worker operation. argv includes executable; envp is explicit.
// Return: 0 launched/reaped, errno on launch failure, ECANCELED before launch.
int ce_run_execute(CERunProcess *run, const char *executable, char *const argv[],
                   char *const envp[], const char *cwd, const void *initial, size_t initial_count, int keep_open, int *status);
void ce_run_stop(CERunProcess *run);
int ce_run_accepts_input(CERunProcess *run);
void ce_run_wait_stopped(CERunProcess *run);
// Nonblocking; returns bytes written or negative errno. Early close is safe.
long ce_run_send(CERunProcess *run, const void *bytes, size_t count);
void ce_run_eof(CERunProcess *run);
// Copies retained bytes. Both pipes continue draining after the retention limit.
size_t ce_run_read(CERunProcess *run, int stream, size_t offset, void *bytes, size_t capacity, size_t *omitted);
size_t ce_run_copy(CERunProcess *run, int stream, void *bytes, size_t capacity, size_t *omitted);
#endif
