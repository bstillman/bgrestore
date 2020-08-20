#!/bin/bash

# bgrestore - Automate the restore of backups taken with bgbackup script. Great for backup verification, development refreshes, etc.
#
# Authors: Ben Stillman <ben@mariadb.com>
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

# Preflight checks
function preflight {
    # find and source the config file
    etccnf=$( find /etc -name bgrestore.cnf )
    scriptdir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

    # Check for mariabackup or xtrabackup
    if [ "$backuptool" == "1" ] && command -v mariabackup >/dev/null; then
        innobackupex=$(command -v mariabackup)
        # mariabackup does not have encryption support
        encrypt="no"
    elif [ "$backuptool" == "2" ] && command -v innobackupex >/dev/null; then
        innobackupex=$(command -v innobackupex)
    else
        echo "The backuptool does not appear to be installed. Please check that a valid backuptool is chosen in bgbackup.cnf and that it's installed."
        log_info "The backuptool does not appear to be installed. Please check that a valid backuptool is chosen in bgbackup.cnf and that it's installed."
        log_status=FAILED
        mail_log
        exit 1
    fi

    innocommand="$innobackupex"
    if [ "$backuptool" == "1" ] ; then innocommand=$innocommand" --innobackupex"; fi


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

# Function to get directory and other info from last full backup
function lastfullinfo {
    mysqlhistcreate
    lastfulluuid=$($mysqlhistcommand "select uuid from $backuphistschema.backup_history where butype = 'Full' and status = 'SUCCEEDED' and hostname = '$backuphost' and (deleted_at IS NULL OR deleted_at = 0) order by end_time desc limit 1")
    lastfullbulocation=$($mysqlhistcommand "select bulocation from $backuphistschema.backup_history where uuid = '$lastfulluuid' ")
    if [ "$lastfullbulocation" == '' ] ; then
        log_info "Backup location not set successfully."
        log_status=FAILED
        mail_log
        exit 2
    fi
    if [ ! -d "$lastfullbulocation" ] && [ "$skipcopy" != "yes" ] ; then

        log_info "Error: $lastfullbulocation directory not found"
        log_info "The directory for the last full backup cannot be found on this server."
        log_status=FAILED
        mail_log
        exit 1
    fi
    lastfullbktype=$($mysqlhistcommand "select bktype from $backuphistschema.backup_history where uuid = '$lastfulluuid' ")
    if [ "$lastfullbktype" != "directory" ] ; then
        log_info "$lastfullbktype not yet supported."
        log_status=FAILED
        mail_log
        exit 2
    fi
    lastfullcompressed=$($mysqlhistcommand "select compressed from $backuphistschema.backup_history where uuid = '$lastfulluuid' ")
    lastfullencrypted=$($mysqlhistcommand "select encrypted from $backuphistschema.backup_history where uuid = '$lastfulluuid' ")
    if [ "$lastfullencrypted" == "yes" ] ; then
    	lastfullcryptkey=$($mysqlhistcommand "select cryptkey from $backuphistschema.backup_history where uuid = '$lastfulluuid' ")
    fi
    log_info "Last full backup to restore: $lastfullbulocation "
}

# Function to prepare backup for restore
function prepit {
    if [ "$skipcopy" != "yes"]; then
        cp -R "$lastfullbulocation" "$preppath"/
        buname=$(basename "$lastfullbulocation")
        bufullpath="$preppath"/"$buname"
    else
        bufullpath="$preppath"
    fi

	if [ "$lastfullencrypted" == "yes" ] ; then
		log_info "Backup is encrypted."
        $innocommand --decrypt=AES256 --encrypt-key="$(cat "$lastfullcryptkey")" --parallel="$threads" "$bufullpath"
        for i in `find $bufullpath -iname "*\.xbcrypt"`; do rm -f $i; done
        log_info "Backup now decrypted."
    fi 
    if [ "$lastfullcompressed" == "yes" ] ; then
    	log_info "Backup is compressed."
        $innocommand --decompress --parallel="$threads" "$bufullpath"
        for i in `find $bufullpath -iname "*\.qp"`; do rm -f $i; done
        log_info "Backup is now decompressed."
    fi
    $innocommand --apply-log "$bufullpath"
    log_info "Backup has been prepared for restore."
}

# Function to restore
function restoreit {

	log_info "Shutting down MariaDB to restore. "
	mysqlshutdowncreate
    $mysqlshutdowncommand "shutdown"

    log_info "More shutdown commands to make sure MariaDB is down."
    systemctl stop mariadb
    pkill -9 mysqld
    systemctl stop mariadb

    log_info "Deleting the data directory."
    rm -Rf "${datadir:?}"/*

    log_info "Moving the prepared backup to the data directory."
    $innocommand --move-back "$bufullpath"

    log_info "Fixing privileges."
    chown -R "$datadirowner":"$datadirgroup" "$datadir"

    log_info "Starting MariaDB."
    systemctl start mariadb

    startstatus=$?
    if [ "$startstatus" -eq 0 ] ; then
        log_status=SUCCEEDED
        log_info "MariaDB succussfully restored and restarted."
    else
        log_status=FAILED
        log_info "Something went wrong. MariaDB did not start. Check error log."
        exit 1
    fi
}

# Cleanup the decompressed/decrypted backup copy
function cleanup {
	if [ "$log_status" == "SUCCEEDED" ] ; then 
	    log_info "Cleaning up."
        if [ "$skipcopy" != "yes" ]; then
	        rm -Rf "${bufullpath:?}"
        else # Clean up prep directory instead of deleting the full backup path (which is also prep directory)
	        rm -Rf "${preppath}/"*
        fi
            
	    log_info "Complete."
	fi
}



##### Begin script

# we trap control-c
trap sigint INT

# Set some specific variables
starttime=$(date +"%Y-%m-%d %H:%M:%S")
mdate=$(date +%m/%d/%y)    # Date for mail subject. Not in function so set at script start time, not when backup is finished.
mysqlcommand=$(command -v mysql)

# do the work
preflight
lastfullinfo
prepit
restoreit
cleanup

# email the log
mail_log

