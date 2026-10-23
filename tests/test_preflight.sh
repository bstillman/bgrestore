#!/bin/bash

# test_preflight.sh
#
# Fixture-based test for preflight() in bgrestore.sh: the config-file lookup
# (explicit -c/--config path, falling back to $scriptdir/bgrestore.cnf) and
# the datadir / preppath sanity checks that must block a restore before it
# touches anything live.
#
# Pure filesystem logic -- no database needed -- so, like
# test_find_in_preppath_by_basename.sh, the function is extracted live out
# of bgrestore.sh by name rather than hand-copied, and run directly. Its
# two collaborators (log_info, mail_log) are stubbed with recording test
# doubles rather than the real ones, since the real log_info/mail_log need
# $verbose/$syslog/$maillist/a real `mail` binary that preflight's own job
# is to validate the config *before* anything downstream relies on them.
#
# Each case runs preflight in a subshell (it calls `exit` directly on
# failure, same as the real script) and inspects the subshell's exit code
# plus what, if anything, got logged/mailed.
#
# Run: ./tests/test_preflight.sh

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

bash -n "$bgrestore_sh" || { echo "FAIL: $bgrestore_sh has a syntax error"; exit 1; }

func_src=$(awk '
    /^function preflight[[:space:]]*\{/ { found = 1 }
    found { print; if ($0 == "}") exit }
' "$bgrestore_sh")

if [[ -z "$func_src" ]]; then
    echo "FAIL: could not extract preflight() out of $bgrestore_sh -- has it been renamed?"
    exit 1
fi
eval "$func_src"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# --- Test doubles for preflight's collaborators ---
# Recording stubs, not the real functions: preflight's own job is to
# validate the config before anything that relies on $logfile/$maillist/a
# real mail transport would be safe to call.
#
# Every failing case below runs preflight() inside a subshell (it calls
# `exit` directly, same as the real script, so there's no other way to let
# the test script survive it) -- which means these stubs must record to
# FILES, not bash arrays/counters: a subshell's in-memory variable changes
# never propagate back to the parent shell, but file writes do.
log_info_log="$work_dir/log_info.calls"
mail_log_count_file="$work_dir/mail_log.calls"
log_info() { printf '%s\n' "$*" >> "$log_info_log"; }
mail_log() { printf 'call\n' >> "$mail_log_count_file"; }

reset_doubles() {
    : > "$log_info_log"
    : > "$mail_log_count_file"
}
log_info_output() { cat "$log_info_log" 2>/dev/null; }
mail_log_call_count() { wc -l < "$mail_log_count_file" 2>/dev/null | tr -d ' '; }

# Runs preflight with the given $etccnf/$scriptdir already set in the
# caller's environment, in a subshell so preflight's own `exit` on failure
# doesn't kill the test script. Echoes the subshell's exit code.
run_preflight() {
    (
        set +e
        preflight
        echo 0
    )
}

# === Case A: neither $etccnf nor $scriptdir/bgrestore.cnf exists ===
reset_doubles
etccnf="$work_dir/does-not-exist.cnf"
scriptdir="$work_dir/empty-scriptdir"
mkdir -p "$scriptdir"
stdout_a=$(run_preflight 2>&1)
rc_a=$?
assert_eq "no config anywhere: exits non-zero" "1" "$rc_a"
assert_contains "no config anywhere: prints the expected error to stdout" \
    "$stdout_a" "bgrestore.cnf configuration file not found"
assert_eq "no config anywhere: never reaches log_info/mail_log (logfile isn't set yet)" \
    "0" "$(mail_log_call_count)"

# === Case B: $etccnf missing, but $scriptdir/bgrestore.cnf exists (fallback) ===
reset_doubles
good_cnf_dir="$work_dir/good"
mkdir -p "$good_cnf_dir/preppath"
cat > "$good_cnf_dir/bgrestore.cnf" <<EOF
datadir=/var/lib/mysql
preppath=$good_cnf_dir/preppath
logpath=$work_dir
EOF
etccnf="$work_dir/does-not-exist.cnf"
scriptdir="$good_cnf_dir"
rc_b=$(run_preflight >/dev/null 2>&1; echo $?)
assert_eq "falls back to \$scriptdir/bgrestore.cnf and passes with a valid config" "0" "$rc_b"

# === Case C: config sources fine, but datadir is empty ===
reset_doubles
cnf_dir="$work_dir/case_c"
mkdir -p "$cnf_dir/preppath"
cat > "$cnf_dir/bgrestore.cnf" <<EOF
datadir=
preppath=$cnf_dir/preppath
logpath=$work_dir
EOF
etccnf="$cnf_dir/bgrestore.cnf"
scriptdir="$work_dir"
rc_c=$(run_preflight >/dev/null 2>&1; echo $?)
assert_eq "empty datadir: exits non-zero" "1" "$rc_c"
assert_contains "empty datadir: logs the expected message" \
    "$(log_info_output)" "Datadir location not set correctly."
assert_eq "empty datadir: mails the failure" "1" "$(mail_log_call_count)"

# === Case D: datadir set, but preppath directory doesn't exist ===
reset_doubles
cnf_dir="$work_dir/case_d"
mkdir -p "$cnf_dir"
cat > "$cnf_dir/bgrestore.cnf" <<EOF
datadir=/var/lib/mysql
preppath=$cnf_dir/does-not-exist
logpath=$work_dir
EOF
etccnf="$cnf_dir/bgrestore.cnf"
scriptdir="$work_dir"
rc_d=$(run_preflight >/dev/null 2>&1; echo $?)
assert_eq "missing preppath directory: exits non-zero" "1" "$rc_d"
assert_contains "missing preppath directory: logs the expected message" \
    "$(log_info_output)" "directory not found"
assert_eq "missing preppath directory: mails the failure" "1" "$(mail_log_call_count)"

# === Case E: preppath exists but isn't writable ===
reset_doubles
cnf_dir="$work_dir/case_e"
mkdir -p "$cnf_dir/preppath"
chmod 500 "$cnf_dir/preppath"
cat > "$cnf_dir/bgrestore.cnf" <<EOF
datadir=/var/lib/mysql
preppath=$cnf_dir/preppath
logpath=$work_dir
EOF
etccnf="$cnf_dir/bgrestore.cnf"
scriptdir="$work_dir"
if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: preppath-not-writable case can't be exercised as root (root ignores the write-permission bit)"
else
    rc_e=$(run_preflight >/dev/null 2>&1; echo $?)
    assert_eq "non-writable preppath: exits non-zero" "1" "$rc_e"
    assert_contains "non-writable preppath: logs the expected message" \
        "$(log_info_output)" "directory is not writable"
    assert_eq "non-writable preppath: mails the failure" "1" "$(mail_log_call_count)"
fi
chmod 700 "$cnf_dir/preppath"

# === Case F: fully valid config -- preflight returns normally, no exit ===
reset_doubles
cnf_dir="$work_dir/case_f"
mkdir -p "$cnf_dir/preppath"
cat > "$cnf_dir/bgrestore.cnf" <<EOF
datadir=/var/lib/mysql
preppath=$cnf_dir/preppath
logpath=$work_dir
EOF
etccnf="$cnf_dir/bgrestore.cnf"
scriptdir="$work_dir"
# Deliberately NOT run in a subshell this time (unlike the failing cases
# above): preflight's own variable assignment to $logfile needs to survive
# into this script to be asserted on below, and a subshell's assignments
# never propagate back out. If preflight unexpectedly called exit here,
# this script would simply stop -- which the missing PASS/FAIL lines below
# would make obvious.
case_f_reached=no
preflight >/dev/null 2>&1
case_f_reached=yes
assert_eq "fully valid config: execution continues past preflight (no exit)" \
    "yes" "$case_f_reached"
assert_eq "fully valid config: logfile is derived from logpath" \
    "$work_dir/bgrestore_$(date +%Y-%m-%d-%T).log" "$logfile"
assert_eq "fully valid config: no failure logged" "0" "$(mail_log_call_count)"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
