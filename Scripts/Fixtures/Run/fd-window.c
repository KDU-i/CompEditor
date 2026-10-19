// SPDX-License-Identifier: Apache-2.0
// Test-only gate deliberately exposes the fallback creation/CLOEXEC window.
#include <stdatomic.h>
#include <time.h>
static _Atomic int arrivals, released;
void ce_run_test_descriptors_created(void) {
    if (atomic_fetch_add(&arrivals, 1) == 0) {
        while (!atomic_load(&released)) {
            struct timespec delay = {0, 1000000}; nanosleep(&delay, NULL);
        }
    }
}
int ce_run_test_fd_arrivals(void) { return atomic_load(&arrivals); }
void ce_run_test_release_fds(void) { atomic_store(&released, 1); }
