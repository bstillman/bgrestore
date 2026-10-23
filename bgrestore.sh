#!/bin/bash

# bgrestore - Automate the restore of backups taken with bgbackup script. Great for backup verification, development refreshes, etc.
#
# Authors: Ben Stillman <ben@mariadb.com>, Michaël de Groot
# License: GNU General Public License, version 3.
# Redistribution/Reuse of this code is permitted under the GNU v3 license.
# As an additional term ALL code must carry the original Author(s) credit in comment form.
# See LICENSE in this directory for the integral text.



# Functions

# Handle control-c
function sigint {
  echo "User has canceled with control-c."
  # 130 is the standard exit code for SIGINT
  exit 130
}

# Mail function
function mail_log {
    mail -s "$mailsubpre $HOSTNAME Restore $log_status $mdate" "$maillist" < "$logfile"
}

# Logging function
function log_info() {
    if [ "$verbose" == "no" ] ; then
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    else
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" | tee -a "$logfile"
    fi
    if [ "$syslog" = yes ] ; then
        logger -p local0.notice -t bgrestore "$*"
    fi
}

# Error function
function  log_error() {
    if [ "$syslog" = yes ] ; then
        logger -p local0.notice -t bgrestore "$*"
    fi
    printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" 1>&2
    exit 1
}


# Preflight checks
function preflight {
    # source the config file (path resolved by CLI arg parsing / default, see "Begin script")
    if [ -e "$etccnf" ]; then
        source "$etccnf"
    elif [ -e "$scriptdir"/bgrestore.cnf ]; then
        source "$scriptdir"/bgrestore.cnf
    else
        echo "Error: bgrestore.cnf configuration file not found"
        echo "The configuration file must exist somewhere in /etc or"
        echo "in the same directory where the script is located"
        log_status=FAILED
        exit 1
    fi
    # set logfile
    logfile=$logpath/bgrestore_$(date +%Y-%m-%d-%T).log    # logfile

    if [ "$datadir" == '' ] ; then
        log_info "Datadir location not set correctly."
        log_status=FAILED
        mail_log
        exit 1
    fi
    # verify the backup prep directory exists
    if [ ! -d "$preppath" ]
    then
        log_info "Error: $preppath directory not found"
        log_info "The configured directory for backup prep does not exist."
        log_status=FAILED
        mail_log
        exit 1
    fi
    # verify user running script has permissions needed to write to backup prep directory
    if [ ! -w "$preppath" ]; then
        log_info "Error: $preppath directory is not writable."
        log_info "Verify the user running this script has write access to the configured backup prep directory."
        log_status=FAILED
        mail_log
        exit 1
    fi
}

# Function to build mysql command
function mysqlhistcreate {
    mysql=$(command -v mysql)
    mysqlhistcommand="$mysqlcommand"
    mysqlhistcommand=$mysqlhistcommand" -u $backuphistuser"
    mysqlhistcommand=$mysqlhistcommand" -p$backuphistpass"
    mysqlhistcommand=$mysqlhistcommand" -h $backuphisthost"
    [ -n "$backuphistport" ] && mysqlhistcommand=$mysqlhistcommand" -P $backuphistport"
    mysqlhistcommand=$mysqlhistcommand" -Bse "
}

# Function to build mysql command
function mysqlshutdowncreate {
    mysqlshutdowncommand="$mysqlcommand"
    mysqlshutdowncommand=$mysqlshutdowncommand" -u $restoreuser"
    mysqlshutdowncommand=$mysqlshutdowncommand" -p$restorepass"
    mysqlshutdowncommand=$mysqlshutdowncommand" -h $restorehost"
    [ -n "$restoreport" ] && mysqlshutdowncommand=$mysqlshutdowncommand" -P $restoreport"
    mysqlshutdowncommand=$mysqlshutdowncommand" -Bse "
}

# Function to get directory and other info from the last backup (any type -- fgrestore
# is chain-aware, so a Differential/Incremental gets trickled back to its Full automatically)
function lastbackupinfo {
    mysqlhistcreate
    lastbuuuid=$($mysqlhistcommand "select uuid from $backuphistschema.backup_history where status = 'SUCCEEDED' and hostname = '$backuphost' and (deleted_at IS NULL OR deleted_at = 0) order by end_time desc limit 1")
    lastbulocation=$($mysqlhistcommand "select bulocation from $backuphistschema.backup_history where uuid = '$lastbuuuid' ")
    if [ "$lastbulocation" == '' ] ; then
        log_info "Backup location not set successfully."
        log_status=FAILED
        mail_log
        exit 2
    fi
    if [ ! -d "$lastbulocation" ] && [ "$skipcopy" != "yes" ] ; then

        log_info "Error: $lastbulocation directory not found"
        log_info "The directory for the last backup cannot be found on this server."
        log_status=FAILED
        mail_log
        exit 1
    fi

    log_info "Last backup to restore: $lastbulocation "
}

# Clears fgrestore chain-staging siblings ('<preppath>.inc.*') left behind by
# a run that failed mid-prepare -- cleanup() below only runs on success, so a
# retry after a failure could otherwise find and reuse stale partial state.
# Called unconditionally, early, before either skipcopy mode's own copy step.
function cleanup_stale_prepare_state {
    log_info "Clearing any stale chain-staging directories left by a previous failed run."
    rm -Rf "${preppath:?}".inc.* 2>/dev/null
}

# Locates backup_history's most recent SUCCEEDED backup (lastbulocation,
# from lastbackupinfo) under $preppath for skipcopy=yes mode. lastbulocation
# itself is a backup-host absolute path that generally does not exist here,
# but copy-last-backup.sh preserves each chain member's own directory
# basename when it transfers it, so match on that instead of trusting
# filesystem mtimes -- mtime-based selection could pick up whatever happens
# to be newest under $preppath regardless of whether backup_history actually
# considers it the latest successful backup.
function find_in_preppath_by_basename {
    local wanted_basename
    wanted_basename=$(basename "$1")
    find "$preppath" -mindepth 2 -maxdepth 2 -name bgbackup.cnf -printf '%h\n' 2>/dev/null \
      | while read -r d; do [ "$(basename "$d")" = "$wanted_basename" ] && echo "$d"; done \
      | head -n1
}

# Cleanup the decompressed/decrypted backup copy
# Regardless of skipcopy, fgrestore always ends up with the prepared backup flattened
# directly into $preppath (skipcopy=yes: prepared in place there via '-I'; skipcopy=no:
# fgrestore itself copies into it via '-D') -- so cleanup is now the same either way.
# Also sweeps fgrestore's chain-staging dirs ('<restore_path>.inc.*') -- bgrestore now
# restores the latest backup of any type, so a Differential/Incremental chain of more
# than one member does create these; -M's --move-back only moves $preppath itself back,
# not the per-member staging dirs.
function cleanup {
	if [ "$log_status" == "SUCCEEDED" ] ; then
	    log_info "Cleaning up."
	    rm -Rf "${preppath:?}"/*
	    rm -Rf "${preppath:?}".inc.*
	    log_info "Complete."
	fi
}

# Function to cleanup logs
function log_cleanup {
    if [ $log_status = "SUCCEEDED" ]; then
        delloglist=$(ls -tp "$logpath" | grep bgrestore | tail -n +$((keeplognum+=1)))
        for logtodelete in $delloglist; do
            rm -f "$logpath"/"$logtodelete"
            log_info "Deleted log file $logpath/$logtodelete"
        done
    else
        log_info "Restore failed. Not deleting any log files at this time."
    fi
}

##### Begin script

# we trap control-c
trap sigint INT

scriptdir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
etccnf="/etc/bgrestore.cnf"

# Function to display usage
usage() {
    echo "Usage: $0 [-c config_file | --config config_file]"
    exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c|--config)
            if [[ -n "${2:-}" ]]; then
                etccnf="$2"
                shift
            else
                echo "Error: --config requires a non-empty option argument."
                usage
            fi
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
    shift
done

# Set some specific variables
starttime=$(date +"%Y-%m-%d %H:%M:%S")
mdate=$(date +%m/%d/%y)    # Date for mail subject. Not in function so set at script start time, not when backup is finished.
mysqlcommand=$(command -v mysql)

# do the work
preflight

# Check that we are not already running. Scoped per service_name so separately
# configured instances on the same restore host (multi-instance restore testing) can
# run concurrently, while two runs against the same instance still can't overlap.
lockfile=/tmp/bgrestore
[ -n "$service_name" ] && lockfile=$lockfile"-$service_name"
lockfile=$lockfile".lock"

if [ -f $lockfile ]
then
    log_error "Another instance of $lockfile is already running. Exiting."
fi
trap 'rm -f $lockfile' 0
touch $lockfile

cleanup_stale_prepare_state

lastbackupinfo

log_info "Shutting down MariaDB to restore."
mysqlshutdowncreate
$mysqlshutdowncommand "shutdown"

# Decrypt/decompress/prepare/move-back are all handled by fgrestore, chain-aware
# (Full/Differential/Incremental). '-r' always removes compressed originals after
# decompression. skipcopy=yes means copy-last-backup.sh already rsynced the backup
# straight into preppath, so '-I' (in-place) prepares it there directly -- a second
# copy would double disk usage. Otherwise fgrestore copies from lastbulocation
# into preppath itself via '-D'.
if [ "$skipcopy" == "yes" ]; then
    restore_source=$(find_in_preppath_by_basename "$lastbulocation")
    if [ -z "$restore_source" ]; then
        log_info "Error: backup_history's most recent successful backup ($lastbulocation) was not found under $preppath"
        log_info "Did copy-last-backup.sh transfer it yet? Nothing to restore."
        log_status=FAILED
        mail_log
        exit 1
    fi
    fgrestore -S "$restore_source" -C "$restore_my_cnf_file" -M -N -r -I \
      $( [ "$run_restorecon" == "yes" ] && echo -R ) >> "$logfile" 2>&1
else
    log_info "Clearing $preppath before copying the backup to it (shared-storage mode)."
    rm -Rf "${preppath:?}"/*
    fgrestore -S "$lastbulocation" -D "$preppath" -C "$restore_my_cnf_file" -M -N -r \
      $( [ "$run_restorecon" == "yes" ] && echo -R ) >> "$logfile" 2>&1
fi
fgrestorestatus=$?
if [ "$fgrestorestatus" -eq 0 ] ; then
    log_info "fgrestore completed successfully."
else
    log_status=FAILED
    log_info "Something went wrong. fgrestore failed. See $logfile for details."
    mail_log
    exit 1
fi

log_info "Fixing unfinished transactions. MDEV-6660 workaround."
# This starts a full mysqld instance; the heuristic XA rollback itself
# happens during InnoDB's own crash-recovery startup, complete well before
# the instance is ready for connections -- but the instance then just
# keeps running as an ordinary server and never exits on its own. Verified
# against the real binary: run unmodified (foreground, no backgrounding/
# timeout/kill), this line hangs forever on every restore that doesn't
# happen to hit the actual MDEV-6660 condition. Background it, give crash
# recovery a moment to finish, then stop it (matching both the sudo
# wrapper and its mysqld child, since sudo's own forking behavior for
# signal delivery to the child varies) so the socket/port are free again
# for the real startup below.
sudo -u mysql mysqld --tc-heuristic-recover=ROLLBACK &
sleep 5
pkill -TERM -f "mysqld --tc-heuristic-recover=ROLLBACK" 2>/dev/null
wait 2>/dev/null

log_info "Starting MariaDB."
systemctl start "$service_name"
startstatus=$?
if [ "$startstatus" -eq 0 ] ; then
    log_status=SUCCEEDED
    log_info "MariaDB succussfully restored and restarted."
else
    log_status=FAILED
    log_info "Something went wrong. MariaDB did not start. Check error log."
    mail_log
    exit 1
fi

cleanup

# email the log
mail_log

# clean old log ifles
log_cleanup
