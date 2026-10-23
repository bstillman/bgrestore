#!/bin/bash

# Stand-in for the real `mail` binary (bsd-mailx / mailutils), which isn't
# installed in this test image -- there is no MTA here, and bgrestore.sh's
# mail_log() shells out to `mail` unconditionally. This stub never actually
# sends anything; it just durably records that it was called and with what,
# so tests can assert on bgrestore.sh's mail-sending behavior without a real
# mail transport.
#
# bgrestore.sh invokes it as:
#   mail -s "$mailsubpre $HOSTNAME Restore $log_status $mdate" "$maillist" < "$logfile"
# i.e. args are `-s <subject> <recipient>`, body on stdin.
#
# Each call appends one record to $MAIL_STUB_LOG (set by the test harness)
# as a block of lines: one "CALL argv[0]|argv[1]|..." line (args joined with
# '|', since the subject itself contains spaces) followed by the stdin body,
# followed by a line of the literal delimiter "-----MAIL-STUB-END-----" so a
# test can split the log back into individual calls.

set -u

log="${MAIL_STUB_LOG:-/tmp/mail-stub.log}"

{
    printf 'CALL'
    for arg in "$@"; do
        printf '|%s' "$arg"
    done
    printf '\n'
    cat
    printf -- '-----MAIL-STUB-END-----\n'
} >> "$log"
