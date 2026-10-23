#!/bin/bash

# test_mail_log.sh
#
# Fixture-based test for mail_log() in bgrestore.sh: the one-line function
# that shells out to `mail -s "<subject>" "$maillist" < "$logfile"`.
#
# There's no real MTA in this environment, so `mail` itself is replaced on
# $PATH with tests/docker/mail-stub.sh (the same stub the live-Docker E2E
# tests use against a real container -- reused here since this part of the
# behavior needs no database or container at all, just a $PATH override).
#
# This also pins down a gap worth knowing about: mail_log() has no
# $mailon gating of its own, and grepping bgrestore.sh turns up no other
# "mailon" check anywhere -- every call to mail_log() sends mail
# unconditionally, regardless of whether $mailon is "all", "failure", or
# anything else. README.md documents `mailon` as if it gates sending
# ("Set to all to email after each run successful or not. Set to failure to
# only email on failures."), and bgbackup.sh (bgrestore's sibling script,
# same repo family) *does* implement that gating for its own mail sending
# -- so this looks like a real, if currently harmless-in-the-success-case,
# gap in bgrestore.sh rather than intentional design. Not fixed here (out
# of scope for a test-coverage task -- see the final report instead); this
# test instead characterizes the current, actual behavior.
#
# Run: ./tests/test_mail_log.sh

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bgrestore_sh="$script_dir/../bgrestore.sh"

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

bash -n "$bgrestore_sh" || { echo "FAIL: $bgrestore_sh has a syntax error"; exit 1; }

func_src=$(awk '
    /^function mail_log[[:space:]]*\{/ { found = 1 }
    found { print; if ($0 == "}") exit }
' "$bgrestore_sh")

if [[ -z "$func_src" ]]; then
    echo "FAIL: could not extract mail_log() out of $bgrestore_sh -- has it been renamed?"
    exit 1
fi
eval "$func_src"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# --- Stub `mail` on PATH ---
stub_bin_dir="$work_dir/bin"
mkdir -p "$stub_bin_dir"
cp "$script_dir/docker/mail-stub.sh" "$stub_bin_dir/mail"
chmod +x "$stub_bin_dir/mail"
export PATH="$stub_bin_dir:$PATH"
export MAIL_STUB_LOG="$work_dir/mail-stub.log"

# === Case A: mail_log sends the expected subject/recipient/body ===
: > "$MAIL_STUB_LOG"
logfile="$work_dir/the_actual_log.log"
printf 'line one\nline two\n' > "$logfile"
mailsubpre="[BGRestoreTest]"
HOSTNAME="restorehost42"
log_status="SUCCEEDED"
mdate="10/06/26"
maillist="dba-team@example.com"

mail_log

call_line=$(head -n1 "$MAIL_STUB_LOG")
assert_eq "invokes mail with -s <subject>" \
    "CALL|-s|[BGRestoreTest] restorehost42 Restore SUCCEEDED 10/06/26|dba-team@example.com" \
    "$call_line"
body=$(sed -n '2,/^-----MAIL-STUB-END-----$/p' "$MAIL_STUB_LOG" | sed '$d')
assert_eq "mail body is the logfile's own content, verbatim" \
    "$(printf 'line one\nline two')" "$body"

# === Case B: subject tracks log_status (FAILED run) ===
: > "$MAIL_STUB_LOG"
log_status="FAILED"
mail_log
call_line=$(head -n1 "$MAIL_STUB_LOG")
assert_eq "subject reflects log_status=FAILED" \
    "CALL|-s|[BGRestoreTest] restorehost42 Restore FAILED 10/06/26|dba-team@example.com" \
    "$call_line"

# === Case C: characterize the mailon gap -- sends regardless of mailon's value ===
for mailon_value in all failure none bogus-garbage; do
    : > "$MAIL_STUB_LOG"
    mailon="$mailon_value"
    log_status="SUCCEEDED"
    mail_log
    assert_eq "mailon='$mailon_value': mail_log still sends (no gating exists)" \
        "1" "$(grep -c '^CALL|' "$MAIL_STUB_LOG")"
done

# Confirm by inspection, not just by behavior, that this isn't a case of
# gating living somewhere this test failed to trigger: mail_log's own
# extracted source never references $mailon, and bgrestore.sh has no other
# "mailon" check anywhere outside of sourcing the config file that sets it.
assert_eq "mail_log()'s own body never references \$mailon" \
    "0" "$(grep -c 'mailon' <<< "$func_src")"
other_mailon_refs=$(grep -n 'mailon' "$bgrestore_sh" | grep -v '^[0-9]*:mailon=')
assert_eq "no other \$mailon check exists anywhere in bgrestore.sh" \
    "" "$other_mailon_refs"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
