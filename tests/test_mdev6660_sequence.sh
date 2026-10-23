#!/bin/bash

# test_mdev6660_sequence.sh
#
# Live-Docker test for bgrestore.sh's MDEV-6660 workaround (item 3 of the
# test-coverage plan): confirms
#   sudo -u mysql mysqld --tc-heuristic-recover=ROLLBACK
# actually runs, with the right arguments, in the right place in the
# sequence -- strictly after a successful fgrestore, strictly before
# `systemctl start` -- and does NOT run at all when fgrestore fails first.
#
# A full live reproduction of the underlying MDEV bug itself (a datadir
# left with a genuinely unresolved prepared transaction) is NOT attempted
# here, per the test-coverage plan -- every fixture these tests build is a
# clean mariabackup backup, never a real crash, so there is never anything
# to actually roll back. What this test confirms is that the line executes,
# with the right arguments, in the right place; see tests/docker/
# mysqld-shim.sh's own comment, and the final test-coverage report, for a
# related finding: that command does not exit on its own once started
# (verified empirically against the real binary), making the production
# line -- as currently written, with no backgrounding/timeout/exit-status
# check -- a suspected hang on every restore that doesn't hit the real
# MDEV-6660 condition. The shim exists specifically so this test (and the
# other E2E tests) can get past that line and keep asserting on the rest
# of the sequence.
#
# Run: ./tests/test_mdev6660_sequence.sh
# Requires: docker.

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/docker/lib.sh
source "$script_dir/docker/lib.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected to find '$needle' in: $haystack)"
        fail=$((fail + 1))
    fi
}

container_name="bgrestore_test_mdev6660"
trap 'bgr_stop "$container_name"' EXIT

bgr_build_image || { echo "FAIL: could not build the test image"; exit 1; }
bgr_start "$container_name" || { echo "FAIL: could not start the test container"; exit 1; }
bgr_init_mariadb "$container_name" || { echo "FAIL: could not provision MariaDB in the test container"; exit 1; }
bgr_write_restore_my_cnf "$container_name" /etc/bgrestore-test-my.cnf
bgr_write_bgrestore_cnf "$container_name" /etc/bgrestore.cnf "skipcopy=no" "mailon=all"

################################################################################
# Successful run: the workaround must run, with the right args, strictly
# between "fgrestore completed successfully" and "Starting MariaDB".
################################################################################

backup_uuid="55555555-5555-5555-5555-555555555555"
backup_dir="/backups/raw-full-mdev"
bgr_insert_backup_history "$container_name" "$backup_uuid" "test-backup-host" "$backup_dir"
bgr_make_full_backup "$container_name" "$backup_dir" >/dev/null 2>&1 || { echo "FAIL: could not take the fixture backup"; exit 1; }

bgr_exec "$container_name" "rm -f /tmp/mysqld-shim.log"
success_exit=$(docker exec "$container_name" bash -c 'bgrestore -c /etc/bgrestore.cnf >/dev/null 2>&1; echo $?')
assert_eq "successful run exits 0" "0" "$success_exit"

shim_log=$(bgr_exec "$container_name" "cat /tmp/mysqld-shim.log" 2>/dev/null)
assert_eq "the workaround is invoked exactly once" "1" "$(grep -c 'CALLED-WITH' <<< "$shim_log")"
assert_contains "it's invoked with exactly the documented flag" \
    "$shim_log" "CALLED-WITH: --tc-heuristic-recover=ROLLBACK"

logfile_content=$(bgr_exec "$container_name" "cat /var/log/bgrestore/bgrestore_*.log")
line_fgrestore_ok=$(grep -n 'fgrestore completed successfully\.' <<< "$logfile_content" | head -n1 | cut -d: -f1)
line_mdev=$(grep -n 'Fixing unfinished transactions. MDEV-6660 workaround\.' <<< "$logfile_content" | head -n1 | cut -d: -f1)
line_starting=$(grep -n 'Starting MariaDB\.' <<< "$logfile_content" | head -n1 | cut -d: -f1)

if [[ -n "$line_fgrestore_ok" && -n "$line_mdev" && -n "$line_starting" \
      && "$line_fgrestore_ok" -lt "$line_mdev" && "$line_mdev" -lt "$line_starting" ]]; then
    echo "PASS: sequence order is fgrestore-ok ($line_fgrestore_ok) < MDEV workaround ($line_mdev) < starting MariaDB ($line_starting)"
    pass=$((pass + 1))
else
    echo "FAIL: expected fgrestore-ok < MDEV workaround < starting MariaDB, got lines ($line_fgrestore_ok, $line_mdev, $line_starting)"
    fail=$((fail + 1))
fi

################################################################################
# Failing run: fgrestore itself fails -> the workaround must NOT run at all.
################################################################################

backup_uuid_broken="66666666-6666-6666-6666-666666666666"
backup_dir_broken="/backups/raw-broken-mdev"
bgr_exec "$container_name" "mysql -uroot -e 'DELETE FROM mdbutil.backup_history;'"
bgr_insert_backup_history "$container_name" "$backup_uuid_broken" "test-backup-host" "$backup_dir_broken"
bgr_make_broken_backup "$container_name" "$backup_dir_broken"
bgr_exec "$container_name" "rm -f /tmp/mysqld-shim.log"

failing_exit=$(docker exec "$container_name" bash -c 'bgrestore -c /etc/bgrestore.cnf >/dev/null 2>&1; echo $?')
assert_eq "failing run (broken fgrestore) exits 1" "1" "$failing_exit"

shim_log_after_failure=$(bgr_exec "$container_name" "cat /tmp/mysqld-shim.log" 2>/dev/null)
assert_eq "the workaround is never invoked when fgrestore fails first" \
    "" "$shim_log_after_failure"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
