// SPDX-License-Identifier: Apache-2.0
// Test-only monotonic clock; never linked into the app.
#include <stdatomic.h>
static _Atomic long milliseconds;
static _Atomic long reads;
double ce_run_test_now(void) {
    long value = atomic_load(&milliseconds);
    atomic_fetch_add(&reads, 1);
    return value / 1000.0;
}
void ce_run_test_advance(long delta) { atomic_fetch_add(&milliseconds, delta); }
long ce_run_test_reads(void) { return atomic_load(&reads); }
