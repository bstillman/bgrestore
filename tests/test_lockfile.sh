#!/bin/bash

# test_lockfile.sh
#
# Live-Docker test for bgrestore.sh's lockfile (/tmp/bgrestore[-$service_name]
# .lock) -- item 2 of the test-coverage plan: a real safety mechanism meant
# to stop two overlapping restores from corrupting each other.
#
# Three cases, run against a real MariaDB server + mariabackup in a
# container (tests/docker/lib.sh):
#
#   1. A lockfile already exists (another instance "is running") ->
#      the new invocation refuses immediately, without touching anything.
#   2. Two REAL invocations genuinely overlap (the first is actually mid-
#      restore, not just simulated) -> the second is refused while the
#      first is still in flight, and the lock is removed on the first's
#      normal successful exit.
#   3. A restore fails partway through (fgrestore itself fails) -> the
#      lock is still removed, via the EXIT trap, despite the explicit
#      `exit 1`.
#
# Run: ./tests/test_lockfile.sh
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

container_name="bgrestore_test_lockfile"
lockfile_path="/tmp/bgrestore-mariadb.lock"
trap 'bgr_stop "$container_name"' EXIT

bgr_build_image || { echo "FAIL: could not build the test image"; exit 1; }
bgr_start "$container_name" || { echo "FAIL: could not start the test container"; exit 1; }
bgr_init_mariadb "$container_name" || { echo "FAIL: could not provision MariaDB in the test container"; exit 1; }
bgr_write_restore_my_cnf "$container_name" /etc/bgrestore-test-my.cnf
bgr_write_bgrestore_cnf "$container_name" /etc/bgrestore.cnf "skipcopy=no" "mailon=all"

################################################################################
# Case 1: a lockfile already exists -> refuses immediately, untouched state
################################################################################

bgr_exec "$container_name" "rm -f $lockfile_path"
bgr_exec "$container_name" "touch $lockfile_path"
pid_before_case1=$(bgr_exec "$container_name" "pidof mariadbd")

case1_output=$(docker exec "$container_name" bash -c "bgrestore -c /etc/bgrestore.cnf; echo CASE1_EXIT=\$?" 2>&1)
case1_exit=$(grep -o 'CASE1_EXIT=[0-9]*' <<< "$case1_output" | cut -d= -f2)

assert_eq "case 1: refuses with exit code 1" "1" "${case1_exit:-<none>}"
assert_contains "case 1: logs/prints the 'already running' message" \
    "$case1_output" "Another instance of $lockfile_path is already running. Exiting."

pid_after_case1=$(bgr_exec "$container_name" "pidof mariadbd")
assert_eq "case 1: never touched the running server (pid unchanged)" \
    "$pid_before_case1" "$pid_after_case1"

lock_still_there=$(bgr_exec "$container_name" "test -f $lockfile_path && echo yes || echo no")
assert_eq "case 1: the pre-existing lock is left exactly as it was (not the blocked run's to remove)" \
    "yes" "$lock_still_there"

bgr_exec "$container_name" "rm -f $lockfile_path"

################################################################################
# Case 2: two REAL invocations genuinely overlap
################################################################################

backup_uuid_2="33333333-3333-3333-3333-333333333333"
backup_dir_2="/backups/raw-full-2"
bgr_exec "$container_name" "mysql -uroot -e 'DELETE FROM mdbutil.backup_history;'"
bgr_insert_backup_history "$container_name" "$backup_uuid_2" "test-backup-host" "$backup_dir_2"
bgr_make_full_backup "$container_name" "$backup_dir_2" >/dev/null 2>&1 || { echo "FAIL: could not take case 2's fixture backup"; fail=$((fail+1)); }

bgr_exec "$container_name" "rm -f /tmp/case2-first.exit /tmp/case2-first.out"
docker exec -d -e MAIL_STUB_LOG=/tmp/mail-stub-case2.log "$container_name" \
    bash -c 'bgrestore -c /etc/bgrestore.cnf > /tmp/case2-first.out 2>&1; echo $? > /tmp/case2-first.exit'

# Wait for the first (real, in-the-background) invocation to actually reach
# and create the lock -- it needs to get through preflight first.
lock_appeared=no
for _i in $(seq 1 40); do
    if [[ "$(bgr_exec "$container_name" "test -f $lockfile_path && echo yes || echo no")" == "yes" ]]; then
        lock_appeared=yes
        break
    fi
    sleep 0.25
done
assert_eq "case 2: the first (real) invocation creates the lock" "yes" "$lock_appeared"

case2_second_output=$(docker exec "$container_name" bash -c "bgrestore -c /etc/bgrestore.cnf; echo CASE2_SECOND_EXIT=\$?" 2>&1)
case2_second_exit=$(grep -o 'CASE2_SECOND_EXIT=[0-9]*' <<< "$case2_second_output" | cut -d= -f2)

assert_eq "case 2: the second, overlapping invocation is refused" "1" "${case2_second_exit:-<none>}"
assert_contains "case 2: refusal message names the lockfile" \
    "$case2_second_output" "Another instance of $lockfile_path is already running. Exiting."

# The rejection above only means something if the first run genuinely
# hadn't finished yet -- confirm it was still actually holding the lock
# at the moment the second one got refused.
lock_held_during_rejection=$(bgr_exec "$container_name" "test -f $lockfile_path && echo yes || echo no")
assert_eq "case 2: the first run was still genuinely in flight when the second was refused" \
    "yes" "$lock_held_during_rejection"

# Now wait for the first (real) run to actually finish on its own.
first_done=no
for _i in $(seq 1 120); do
    if [[ "$(bgr_exec "$container_name" "test -f /tmp/case2-first.exit && echo yes || echo no")" == "yes" ]]; then
        first_done=yes
        break
    fi
    sleep 0.5
done
assert_eq "case 2: the first (real) invocation eventually completes" "yes" "$first_done"

first_exit=$(bgr_exec "$container_name" "cat /tmp/case2-first.exit" 2>/dev/null)
assert_eq "case 2: the first invocation itself succeeded" "0" "${first_exit:-<none>}"

lock_after_first_done=$(bgr_exec "$container_name" "test -f $lockfile_path && echo yes || echo no")
assert_eq "case 2: the lock is removed once the first run exits normally" \
    "no" "$lock_after_first_done"

bgr_wait_mysql_ready "$container_name" || echo "FAIL: mariadb did not come back up after case 2"

################################################################################
# Case 3: a restore that fails partway through still removes the lock
################################################################################

backup_uuid_3="44444444-4444-4444-4444-444444444444"
backup_dir_3="/backups/raw-broken-3"
bgr_exec "$container_name" "rm -f $lockfile_path"
bgr_exec "$container_name" "mysql -uroot -e 'DELETE FROM mdbutil.backup_history;'"
bgr_insert_backup_history "$container_name" "$backup_uuid_3" "test-backup-host" "$backup_dir_3"
bgr_make_broken_backup "$container_name" "$backup_dir_3"

case3_output=$(docker exec "$container_name" bash -c "bgrestore -c /etc/bgrestore.cnf; echo CASE3_EXIT=\$?" 2>&1)
case3_exit=$(grep -o 'CASE3_EXIT=[0-9]*' <<< "$case3_output" | cut -d= -f2)

assert_eq "case 3: the failing restore itself exits 1" "1" "${case3_exit:-<none>}"

case3_log=$(bgr_exec "$container_name" "cat /var/log/bgrestore/bgrestore_*.log" 2>/dev/null)
assert_contains "case 3: the failure is the fgrestore step, not something else" \
    "$case3_log" "Something went wrong. fgrestore failed."

lock_after_failure=$(bgr_exec "$container_name" "test -f $lockfile_path && echo yes || echo no")
assert_eq "case 3: the lock is removed even though the run failed mid-way (EXIT trap, not a success-only cleanup)" \
    "no" "$lock_after_failure"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
