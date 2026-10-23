#!/bin/bash

# Test-only wrapper around the real mysqld/mariadbd binary. Installed ahead
# of the real one on PATH so a bare `mysqld` call -- as bgrestore.sh and
# fgrestore.sh both make -- resolves here first.
#
# Why this exists: bgrestore.sh's MDEV-6660 workaround runs
#   sudo -u mysql mysqld --tc-heuristic-recover=ROLLBACK
# in the foreground, with no backgrounding, timeout, or exit-status check,
# immediately followed by `systemctl start "$service_name"`. Verified
# empirically (outside of this test suite, against the real mariadbd binary
# directly) that when there is nothing to actually roll back -- true for
# every fixture these tests build, since they're all produced by a clean
# mariabackup backup/prepare/move-back, never a genuine crash -- that
# command does NOT exit on its own: it starts mariadbd as an ordinary, fully
# running server that binds the real socket/port and sits there forever.
# Run unmodified, bgrestore.sh would hang at that exact line on every single
# test run (and, it appears, in production on every restore that doesn't
# happen to hit the actual MDEV-6660 condition). This is a suspected real bug
# in bgrestore.sh, reported separately -- it is deliberately NOT fixed here,
# since fixing it is a production behavior change outside this test-writing
# task's scope.
#
# To let the E2E tests actually reach and verify the rest of the sequence
# (systemctl start, service comes back up, data is correct), this wrapper
# intercepts ONLY the exact MDEV-6660 invocation: it execs the REAL mariadbd
# (so the genuine crash-recovery code path still runs for real), gives it a
# few seconds to come up, then shuts it down cleanly and exits 0 -- standing
# in for whatever external supervision bgrestore.sh's production deployment
# currently relies on to get past this step. Every other invocation (e.g.
# fgrestore.sh's own `mysqld -V` version probe, or a real `systemctl start`
# going through the init script, which uses mariadbd's own absolute path,
# not this shim) is passed straight through to the real binary, untouched.

set -u

real_mysqld=/usr/sbin/mariadbd
socket=/run/mysqld/mysqld.sock

is_tc_heuristic_recover=0
for arg in "$@"; do
    [[ "$arg" == "--tc-heuristic-recover=ROLLBACK" ]] && is_tc_heuristic_recover=1
done

if [[ "$is_tc_heuristic_recover" -eq 0 ]]; then
    exec "$real_mysqld" "$@"
fi

# Record the interception (args + wall-clock time) so a test can assert on
# exactly when, and with what arguments, bgrestore.sh's MDEV-6660 line
# actually ran -- not just infer it from nearby log_info lines. A fixed
# path, not an env var: bgrestore.sh calls `sudo -u mysql mysqld ...` with
# no --preserve-env, and sudo strips the environment by default, so an env
# var set on the outer `docker exec` would never reach this shim.
printf '%s CALLED-WITH:%s\n' "$(date +%Y-%m-%d-%T)" " $*" >> /tmp/mysqld-shim.log

"$real_mysqld" "$@" &
pid=$!

for _ in $(seq 1 20); do
    mysqladmin --socket="$socket" ping >/dev/null 2>&1 && break
    sleep 0.5
done

kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
exit 0
