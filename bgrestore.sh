#!/bin/bash

# bgrestore - Automate the restore of backups taken with bgbackup script. Great for backup verification, development refreshes, etc.
#
# Authors: Ben Stillman <ben@mariadb.com>
# License: GNU General Public License, version 3.
# Redistribution/Reuse of this code is permitted under the GNU v3 license.
# As an additional term ALL code must carry the original Author(s) credit in comment form.
# See LICENSE in this directory for the integral text.



# Functions



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
    lastfulluuid=$($mysqlhistcommand "select uuid from $backuphistschema.backup_history where butype = 'Full' and status = 'SUCCEEDED' and hostname = '$backuphost' and deleted_at = 0 order by end_time desc limit 1")
    lastfullbulocation=$($mysqlhistcommand "select bulocation from $backuphistschema.backup_history where uuid = '$lastfulluuid' ")
    if [ "$lastfullbulocation" == '' ] ; then
        log_info "Backup location not set successfully."
        log_status=FAILED
        mail_log
        exit 2
    fi
    if [ ! -d "$lastfullbulocation" ] ; then
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
	if [ "$lastfullencrypted" == "yes" ] ; then
		log_info "Backup is encrypted."
        $innocommand --decrypt=AES256 --encrypt-key="$(cat "$lastfullcryptkey")" --parallel="$threads" "$lastfullbulocation"
        for i in `find $lastfullbulocation -iname "*\.xbcrypt"`; do rm -f $i; done
        log_info "Backup now decrypted."
    fi 
    if [ "$lastfullcompressed" == "yes" ] ; then
    	log_info "Backup is compressed."
        $innocommand --decompress --parallel="$threads" "$lastfullbulocation"
        for i in `find $lastfullbulocation -iname "*\.qp"`; do rm -f $i; done
        log_info "Backup is now decompressed."
    fi
    $innocommand --apply-log "$lastfullbulocation"
    log_info "Backup has been prepared for restore."
}

# Function to restore
function restoreit {
	log_info "Shutting down MariaDB to restore. "
	mysqlshutdowncreate
#    $mysqlshutdowncommand "shutdown"
    service mysql stop
    log_info "Deleting the data directory."
    rm -Rf "${datadir:?}"/*
    log_info "Copying the backup to the data directory."
    $innocommand --copy-back "$lastfullbulocation"
    log_info "Fixing privileges."
    chown -R "$datadirowner":"$datadirgroup" "$datadir"
    log_info "Starting MariaDB."
    service mysql start
    log_status=SUCCEEDED
    log_info "MariaDB successfully restored and restarted."
}





##### Begin script

# we trap control-c
trap sigint INT

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
    exit 2
fi

# Check for xtrabackup
if command -v innobackupex >/dev/null; then
    innobackupex=$(command -v innobackupex)
else
    log_info "xtrabackup/innobackupex does not appear to be installed. Please install and try again."
    log_status=FAILED
    mail_log
    exit 1
fi

if [ "$datadir" == '' ] ; then
    log_info "Datadir location not set correctly."
    log_status=FAILED
    mail_log
    exit 2
fi

# Set some specific variables
starttime=$(date +"%Y-%m-%d %H:%M:%S")
mdate=$(date +%m/%d/%y)    # Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/bgrestore_$(date +%Y-%m-%d-%T).log    # logfile
mysqlcommand=$(command -v mysql)
innocommand=$(command -v innobackupex)

# do the work
lastfullinfo
prepit
restoreit

# email the log
mail_log
