#!/bin/bash

# test_skipcopy_no_e2e.sh
#
# Live-Docker end-to-end test for bgrestore.sh's skipcopy=no (shared-
# storage) code path -- item 1 of the test-coverage plan, and previously
# zero coverage of any kind. In this mode bgrestore.sh has fgrestore itself
# copy the chain from backup_history's recorded location into $preppath
# via '-D' (see bgrestore.sh's non-skipcopy branch), rather than something
# else (copy-last-backup.sh, in skipcopy=yes mode) having pre-delivered it.
#
# This drives the real script against a real MariaDB server + mariabackup
# in a container (tests/docker/lib.sh): a real backup_history row pointing
# at a real backup directory on disk, taken with mariabackup against data
# that's then changed before the restore, so a correct restore has to
# visibly revert it.
#
# Run: ./tests/test_skipcopy_no_e2e.sh
# Requires: docker. Builds/uses the bgrestore-test:latest image and a
# container named by $container_name below; always torn down on exit.

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
        echo "FAIL: $desc (expected to find '$needle')"
        fail=$((fail + 1))
    fi
}

container_name="bgrestore_test_skipcopy_no_e2e"
trap 'bgr_stop "$container_name"' EXIT

bgr_build_image || { echo "FAIL: could not build the test image"; exit 1; }
bgr_start "$container_name" || { echo "FAIL: could not start the test container"; exit 1; }
bgr_init_mariadb "$container_name" || { echo "FAIL: could not provision MariaDB in the test container"; exit 1; }

bgr_write_restore_my_cnf "$container_name" /etc/bgrestore-test-my.cnf

backup_uuid="22222222-2222-2222-2222-222222222222"
backup_dir="/backups/raw-full-1"
# Insert the backup_history row BEFORE taking the backup: fgrestore's
# restore is a full physical restore of the whole datadir, mdbutil schema
# included, so a row inserted *after* the backup would simply vanish again
# on restore -- that's expected (it's genuinely not in the snapshot), not a
# bug, but it would make a misleading assertion later if the row were
# inserted the other way around.
bgr_insert_backup_history "$container_name" "$backup_uuid" "test-backup-host" "$backup_dir"
bgr_make_full_backup "$container_name" "$backup_dir" || { echo "FAIL: could not take the fixture backup"; exit 1; }

pid_before=$(bgr_exec "$container_name" "pidof mariadbd")
bgr_exec "$container_name" "mysql -uroot -e \"UPDATE restoretestdb.canary SET val='modified-after-backup' WHERE id=1;\""

bgr_write_bgrestore_cnf "$container_name" /etc/bgrestore.cnf \
    "skipcopy=no" "mailon=all"

run_output=$(docker exec -e MAIL_STUB_LOG=/tmp/mail-stub.log "$container_name" \
    bash -c 'bgrestore -c /etc/bgrestore.cnf; echo "BGRESTORE_EXIT=$?"' 2>&1)
run_exit=$(grep -o 'BGRESTORE_EXIT=[0-9]*' <<< "$run_output" | cut -d= -f2)

assert_eq "bgrestore exits 0" "0" "${run_exit:-<none>}"

logfile_content=$(bgr_exec "$container_name" "cat /var/log/bgrestore/bgrestore_*.log")

assert_contains "log shows the skipcopy=no (shared-storage) branch was taken" \
    "$logfile_content" "before copying the backup to it (shared-storage mode)"
assert_contains "log shows fgrestore completed successfully" \
    "$logfile_content" "fgrestore completed successfully."
assert_contains "log shows the service was restarted successfully" \
    "$logfile_content" "MariaDB succussfully restored and restarted."
assert_contains "log shows the final SUCCEEDED cleanup ran" \
    "$logfile_content" "Cleaning up."

# fgrestore prints its own resolved configuration -- confirm bgrestore
# invoked it in -D (copy into preppath) mode, not -I (in-place, the
# skipcopy=yes shape), and pointed -S at backup_history's own bulocation.
assert_contains "fgrestore ran in -D (copy into preppath) mode, not -I (in_place=0)" \
    "$logfile_content" "in_place='0'"
assert_contains "fgrestore's -S was backup_history's bulocation" \
    "$logfile_content" "backup_path='$backup_dir'"
assert_contains "fgrestore's -D targeted preppath" \
    "$logfile_content" "restore_path='/preppath'"

canary_val=$(bgr_exec "$container_name" "mysql -uroot -N -e \"select val from restoretestdb.canary where id=1;\"")
assert_eq "restore actually reverted the live data to the backed-up value" \
    "original-data" "$canary_val"

history_row=$(bgr_exec "$container_name" "mysql -uroot -N -e \"select uuid,status,bulocation from mdbutil.backup_history where uuid='$backup_uuid';\"")
assert_eq "the backup_history row that drove the restore survives intact" \
    "$(printf '%s\t%s\t%s' "$backup_uuid" "SUCCEEDED" "$backup_dir")" "$history_row"

pid_after=$(bgr_exec "$container_name" "pidof mariadbd")
if [[ -n "$pid_before" && -n "$pid_after" && "$pid_before" != "$pid_after" ]]; then
    echo "PASS: mariadbd was actually stopped and restarted (pid changed: $pid_before -> $pid_after)"
    pass=$((pass + 1))
else
    echo "FAIL: mariadbd pid did not change across the restore (before='$pid_before' after='$pid_after') -- was it really stopped?"
    fail=$((fail + 1))
fi

ping_result=$(bgr_exec "$container_name" "mysqladmin ping" 2>&1)
assert_contains "the restarted service actually answers queries" "$ping_result" "mysqld is alive"

preppath_leftovers=$(bgr_exec "$container_name" "find /preppath -mindepth 1" 2>&1)
assert_eq "preppath is fully cleaned up after a SUCCEEDED run" "" "$preppath_leftovers"

lock_leftovers=$(bgr_exec "$container_name" "ls /tmp/*.lock 2>/dev/null")
assert_eq "no lockfile left behind after a normal exit" "" "$lock_leftovers"

mail_calls=$(bgr_exec "$container_name" "grep -c '^CALL|' /tmp/mail-stub.log 2>/dev/null || echo 0")
assert_eq "mail_log sent exactly one mail (mailon=all, success)" "1" "$mail_calls"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
