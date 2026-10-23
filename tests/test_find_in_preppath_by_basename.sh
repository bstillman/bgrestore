#!/bin/bash

# test_find_in_preppath_by_basename.sh
#
# Fixture-based regression test for find_in_preppath_by_basename() in
# bgrestore.sh, used by skipcopy=yes mode to pick the restore target that
# backup_history actually designates as the latest successful backup,
# matched under $preppath by directory basename -- not by filesystem mtime
# (an earlier version picked whichever member had the newest bgbackup.cnf
# mtime, which could restore a stale or otherwise-unrecorded directory that
# happened to be newest).
#
# The function is extracted live out of bgrestore.sh by name below, rather
# than hand-copied into this file, so the test always exercises the exact
# function currently shipped and can't quietly drift out of sync with it.
# Sourcing bgrestore.sh directly isn't an option: everything after the
# function definitions is top-level script (argument parsing, preflight,
# a shutdown/restore/mail sequence) that runs unconditionally on source and
# needs a live bgrestore.cnf and MariaDB instance to even get through
# preflight.
#
# Run: ./tests/test_find_in_preppath_by_basename.sh

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

# Pull the function body out of bgrestore.sh verbatim (from its "function
# NAME {" line through the first column-0 "}").
func_src=$(awk '
    /^function find_in_preppath_by_basename[[:space:]]*\{/ { found = 1 }
    found { print; if ($0 == "}") exit }
' "$bgrestore_sh")

if [[ -z "$func_src" ]]; then
    echo "FAIL: could not extract find_in_preppath_by_basename() out of $bgrestore_sh -- has it been renamed?"
    exit 1
fi
eval "$func_src"

# --- Fixture setup ---
preppath=$(mktemp -d)
trap 'rm -rf "$preppath"' EXIT

# (a) the correct, backup_history-designated backup -- deliberately given the
# OLDER mtime, so a correct implementation must ignore mtime entirely.
correct_dir="$preppath/full-2026-09-01_02-00-00"
mkdir -p "$correct_dir"
: > "$correct_dir/bgbackup.cnf"
touch -d '2026-09-01 02:00:00' "$correct_dir/bgbackup.cnf" "$correct_dir"

# (b) a second, newer-mtime directory that must NOT be selected despite being
# newer -- simulates a stale or otherwise-unrecorded leftover under preppath.
stale_dir="$preppath/full-2026-09-15_02-00-00"
mkdir -p "$stale_dir"
: > "$stale_dir/bgbackup.cnf"
touch -d '2026-09-20 02:00:00' "$stale_dir/bgbackup.cnf" "$stale_dir"

# Sanity-check the fixture itself before trusting what it proves.
if [[ ! "$stale_dir/bgbackup.cnf" -nt "$correct_dir/bgbackup.cnf" ]]; then
    echo "FAIL: fixture setup broken -- stale_dir is not actually newer than correct_dir"
    exit 1
fi

# --- Case 1: basename match selects (a), ignoring that (b) is newer ---
result=$(find_in_preppath_by_basename "/original/backup/host/path/full-2026-09-01_02-00-00")
assert_eq "selects backup_history's designated basename, not the newer leftover" \
    "$correct_dir" "$result"

# --- Case 2: a basename with no matching directory under preppath returns empty ---
result=$(find_in_preppath_by_basename "/original/backup/host/path/full-2026-12-25_02-00-00")
assert_eq "no matching basename under preppath returns empty (caller's job to fail loud)" \
    "" "$result"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
