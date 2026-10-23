#!/bin/bash

# test_log_cleanup.sh
#
# Fixture-based test for log_cleanup() in bgrestore.sh: deletes bgrestore's
# own rotated log files down to the newest $keeplognum, but only after a
# SUCCEEDED run -- a failed run's logs are left alone entirely so they're
# available for troubleshooting.
#
# Pure filesystem logic, no database needed, so the function is extracted
# live out of bgrestore.sh rather than hand-copied (same rationale as
# test_find_in_preppath_by_basename.sh and test_preflight.sh). log_info is
# a recording test double so log_cleanup's own log_info calls (one per
# deleted file, or the "not deleting" notice on failure) can be asserted on
# directly.
#
# Run: ./tests/test_log_cleanup.sh

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
    /^function log_cleanup[[:space:]]*\{/ { found = 1 }
    found { print; if ($0 == "}") exit }
' "$bgrestore_sh")

if [[ -z "$func_src" ]]; then
    echo "FAIL: could not extract log_cleanup() out of $bgrestore_sh -- has it been renamed?"
    exit 1
fi
eval "$func_src"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

log_info_log="$work_dir/log_info.calls"
log_info() { printf '%s\n' "$*" >> "$log_info_log"; }
log_info_output() { cat "$log_info_log" 2>/dev/null; }

# Builds a fresh $logpath containing 5 bgrestore_* log files (oldest to
# newest: 01..05) plus one unrelated file that must never be touched
# (log_cleanup's own `grep bgrestore` is the only thing protecting other
# logpath tenants). Echoes the directory.
make_logpath_fixture() {
    local dir="$work_dir/logs_$RANDOM"
    mkdir -p "$dir"
    local i
    for i in 1 2 3 4 5; do
        : > "$dir/bgrestore_0${i}.log"
        touch -d "2026-09-0${i} 00:00:00" "$dir/bgrestore_0${i}.log"
    done
    : > "$dir/other-app.log"
    touch -d "2026-09-06 00:00:00" "$dir/other-app.log"
    : > "$log_info_log"
    echo "$dir"
}

# === Case A: SUCCEEDED, keeplognum=2 -- keeps the 2 newest, deletes the rest ===
logpath=$(make_logpath_fixture)
log_status=SUCCEEDED
keeplognum=2
log_cleanup

assert_eq "keeplognum=2: newest (05) survives" "yes" "$([[ -e "$logpath/bgrestore_05.log" ]] && echo yes || echo no)"
assert_eq "keeplognum=2: 2nd-newest (04) survives" "yes" "$([[ -e "$logpath/bgrestore_04.log" ]] && echo yes || echo no)"
assert_eq "keeplognum=2: 3rd-newest (03) is deleted" "no" "$([[ -e "$logpath/bgrestore_03.log" ]] && echo yes || echo no)"
assert_eq "keeplognum=2: oldest (01) is deleted" "no" "$([[ -e "$logpath/bgrestore_01.log" ]] && echo yes || echo no)"
assert_eq "keeplognum=2: unrelated file in \$logpath is never touched" "yes" \
    "$([[ -e "$logpath/other-app.log" ]] && echo yes || echo no)"
assert_eq "keeplognum=2: logs exactly the 3 deletions" "3" "$(log_info_output | grep -c '^Deleted log file ')"
assert_eq "keeplognum=2: deletion log line names the right path" "yes" \
    "$(log_info_output | grep -qF "Deleted log file $logpath/bgrestore_01.log" && echo yes || echo no)"
# log_cleanup's own `tail -n +$((keeplognum+=1))` looks at a glance like it
# mutates $keeplognum in the caller's scope as a side effect, but it
# doesn't: that arithmetic expansion happens while building `tail`'s
# argument inside `delloglist=$( ... | tail ... )`, and the whole pipeline
# runs in the subshell `$(...)` always creates -- so the increment is
# confined to that subshell and never survives back out. Pinned down here
# so it isn't mistaken for a real mutation on a future read.
assert_eq "keeplognum is NOT mutated in the caller's scope (the += is confined to \$(...)'s subshell)" \
    "2" "$keeplognum"

# === Case B: SUCCEEDED, keeplognum >= file count -- nothing to delete ===
logpath=$(make_logpath_fixture)
log_status=SUCCEEDED
keeplognum=10
log_cleanup

assert_eq "keeplognum >= count: all 5 bgrestore logs survive" "5" \
    "$(find "$logpath" -maxdepth 1 -name 'bgrestore_*.log' | wc -l | tr -d ' ')"
assert_eq "keeplognum >= count: no deletions logged" "0" "$(log_info_output | grep -c '^Deleted log file ')"

# === Case C: FAILED run -- no file is deleted, regardless of keeplognum ===
logpath=$(make_logpath_fixture)
log_status=FAILED
keeplognum=0
log_cleanup

assert_eq "failed run: all 5 bgrestore logs survive even with keeplognum=0" "5" \
    "$(find "$logpath" -maxdepth 1 -name 'bgrestore_*.log' | wc -l | tr -d ' ')"
assert_eq "failed run: logs the 'not deleting' notice instead" "1" \
    "$(log_info_output | grep -cF 'Restore failed. Not deleting any log files at this time.')"
assert_eq "failed run: no deletions logged" "0" "$(log_info_output | grep -c '^Deleted log file ')"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
