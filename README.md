# bgrestore

bgrestore-auto.sh helps you automatically restore the last successful backup from bgbackup to another MariaDB server. This is very useful for verifying backups, refreshing development environments, etc. 

bgrestore connects to the backup_history table in mdbutil to gather information about the last successful full backup such as whether it's encrypted, compressed, etc. This information is then used to restore on the designated MariaDB server. 


## How to...

This all assumes the backup was taken with bgbackup (https://github.com/bstillman/bgbackup). This is necessary for the script to gather the required information. 

Copy bgrestore.cnf.dist to /etc/bgrestore.cnf and configure as needed (details below). 


### Current Limitations

Currently the script assumes the location of the backup on the source and the destination is the same. Ex: if the backup is in /backups on the server backed up, it should also reside in /backups on the server to be restored. 

The backup needs to already exist on the server to be restored. This can be handled in a few different ways:
* use run_after_success in bgbackup.cnf to run a script which SCPs the backup to the server to be restored
* share a disk at the same mount point on each server


## Configuration Options

### restorehost

The hostname or IP address of the MariaDB server to be restored. 

### restoreport

The port of the MariaDB server to be restored. 

### restoreuser

The database user on the MariaDB server to be restored. Needs the shutdown privilege.

### restorepass

The password for the restoreuser database user. 

### preppath

The path the backup will be copied to for decompression and decryption if necessary. Be sure this path has enough free space for the decompressed backup. 

### backuphisthost

The hostname or IP address of the MariaDB server with the backup_history table. 

### backuphistport

The port of the MariaDB server with the backup_history table. 

### backuphistuser

The database user with at least select privilege on the backup_history table. 

### backuphistpass

The password for the backuphistuser database user. 

### backuphistschema

The name of the schema/database which the backup_history table resides. 

### backuphost

The hostname of the server from which the backup was taken. Ex. If backing up server1 and restoring to server2, this is the hostname of server1 as found in backup_history. 

### datadir

The full path to the data directory on the MariaDB server to be restored. 

### datadirowner

The owner of the data directory. Usually mysql. 

### datadirgroup

The group of the data directory. Usually mysql. 

### logpath

The full path to where the log files should be written. 

### syslog

Setting to yes will log to file and syslog.

### threads

The number of threads innobackupex should use for decryption and/or decompression. 

### maillist

A comma separated list of email address to send the logfile to when complete. 

### mailsubpre

A prefix for email subject lines. 

### mailon

Set to all to email after each run successful or not. Set to failure to only email on failures. 
