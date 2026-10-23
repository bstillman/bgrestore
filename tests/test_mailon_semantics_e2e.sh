#!/bin/bash

# test_mailon_semantics_e2e.sh
#
# Live-Docker end-to-end confirmation of the mailon gap already
# characterized at the unit level in test_mail_log.sh: mail_log() has no
# $mailon gating anywhere in bgrestore.sh, so it sends on every single
# invocation regardless of whether $mailon is "all", "failure", or "none".
#
# test_mail_log.sh already proves this by calling mail_log() directly and
# by grep'ing bgrestore.sh for any other "mailon" check; this test instead
# drives the real, full script end-to-end (real MariaDB, real fgrestore)
# so the finding holds for the whole program, not just the isolated
# function. Deliberately NOT a full cross-product of all mailon values x
# success/failure -- that would just re-prove the same already-proven fact
# more times for little extra confidence. Two cases cover the ground that
# matters:
#
#   1. mailon=all, a successful run -- the "normal", expected-to-mail case
#      (also covered incidentally by test_skipcopy_no_e2e.sh; repeated
#      here so this file stands on its own).
#   2. mailon=none, a FAILING run -- the standout case: "none" reads as
#      "never email", and the run also fails, yet mail still goes out.
#
# Run: ./tests/test_mailon_semantics_e2e.sh
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

container_name="bgrestore_test_mailon_e2e"
trap 'bgr_stop "$container_name"' EXIT

bgr_build_image || { echo "FAIL: could not build the test image"; exit 1; }
bgr_start "$container_name" || { echo "FAIL: could not start the test container"; exit 1; }
bgr_init_mariadb "$container_name" || { echo "FAIL: could not provision MariaDB in the test container"; exit 1; }
bgr_write_restore_my_cnf "$container_name" /etc/bgrestore-test-my.cnf

################################################################################
# Case 1: mailon=all, success -- the expected-to-mail case
################################################################################

bgr_write_bgrestore_cnf "$container_name" /etc/bgrestore.cnf "skipcopy=no" "mailon=all"
backup_uuid="77777777-7777-7777-7777-777777777777"
backup_dir="/backups/raw-full-mailon"
bgr_insert_backup_history "$container_name" "$backup_uuid" "test-backup-host" "$backup_dir"
bgr_make_full_backup "$container_name" "$backup_dir" >/dev/null 2>&1 || { echo "FAIL: could not take case 1's fixture backup"; exit 1; }

bgr_exec "$container_name" "rm -f /tmp/mail-stub.log"
exit1=$(docker exec -e MAIL_STUB_LOG=/tmp/mail-stub.log "$container_name" bash -c 'bgrestore -c /etc/bgrestore.cnf >/dev/null 2>&1; echo $?')
assert_eq "case 1 (mailon=all, success): run succeeds" "0" "$exit1"
mail_count_1=$(bgr_exec "$container_name" "grep -c '^CALL|' /tmp/mail-stub.log 2>/dev/null || echo 0")
assert_eq "case 1 (mailon=all, success): mail is sent" "1" "$mail_count_1"

################################################################################
# Case 2: mailon=none, FAILURE -- the standout case: still mails anyway
################################################################################

bgr_write_bgrestore_cnf "$container_name" /etc/bgrestore.cnf "skipcopy=no" "mailon=none"
backup_uuid_broken="88888888-8888-8888-8888-888888888888"
backup_dir_broken="/backups/raw-broken-mailon"
bgr_exec "$container_name" "mysql -uroot -e 'DELETE FROM mdbutil.backup_history;'"
bgr_insert_backup_history "$container_name" "$backup_uuid_broken" "test-backup-host" "$backup_dir_broken"
bgr_make_broken_backup "$container_name" "$backup_dir_broken"

bgr_exec "$container_name" "rm -f /tmp/mail-stub.log"
exit2=$(docker exec -e MAIL_STUB_LOG=/tmp/mail-stub.log "$container_name" bash -c 'bgrestore -c /etc/bgrestore.cnf >/dev/null 2>&1; echo $?')
assert_eq "case 2 (mailon=none, failure): run fails as expected" "1" "$exit2"
mail_count_2=$(bgr_exec "$container_name" "grep -c '^CALL|' /tmp/mail-stub.log 2>/dev/null || echo 0")
assert_eq "case 2 (mailon=none, FAILED run): mail still sends -- confirms the gap end-to-end, not just at the unit level" \
    "1" "$mail_count_2"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
