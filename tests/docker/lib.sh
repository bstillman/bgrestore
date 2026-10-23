#!/bin/bash

# Shared Docker test harness for bgrestore.sh's live-coverage tests
# (skipcopy=no end-to-end, the lockfile, the MDEV-6660 workaround's place in
# the sequence). Sourced by tests/test_*.sh; not a standalone script.
#
# Design: the image (tests/docker/Dockerfile) only provisions the OS -- a
# real MariaDB server, mariabackup, and the systemctl/mail/mysqld shims
# tests/docker/*.sh describe. bgrestore.sh and fgrestore.sh (+ its
# timing.bash/chain_resolve.bash helpers) are `docker cp`'d into each
# container fresh by bgr_start(), straight out of the working tree and its
# fgrestore sibling repo, so every test run exercises exactly what's on disk
# right now -- never a baked-in, possibly-stale copy.
#
# Every function assumes `set -u`-safe callers and that the caller traps
# cleanup (bgr_stop) itself; this library never registers its own trap,
# since a test script may create more than one container.

set -u

bgr_image=bgrestore-test:latest

bgr_repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bgr_docker_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# fgrestore.sh lives in a sibling repo, not this one -- see README.md's
# link to ../mysql-mariadb-physical-backup/files/fgrestore.sh. Resolved
# relative to this repo's own parent directory, same layout the README
# assumes; overridable via FGRESTORE_REPO_DIR for a different checkout.
bgr_fgrestore_repo_dir=${FGRESTORE_REPO_DIR:-$(cd "$bgr_repo_dir/../mysql-mariadb-physical-backup" 2>/dev/null && pwd)}

# Build (or refresh) the shared test image. Cheap to call repeatedly --
# Docker's own layer cache makes a no-op rebuild near-instant.
bgr_build_image() {
    docker build -q -t "$bgr_image" "$bgr_docker_dir" >/dev/null
}

# Start a fresh, named container from the image and copy in the current
# bgrestore.sh / fgrestore.sh / helpers. Does NOT start MariaDB -- call
# bgr_init_mariadb for that once the container is up.
bgr_start() {
    local name="$1"

    if [[ -z "$bgr_fgrestore_repo_dir" || ! -f "$bgr_fgrestore_repo_dir/files/fgrestore.sh" ]]; then
        echo "FAIL: can't find fgrestore.sh (looked under '${bgr_fgrestore_repo_dir:-<unresolved>}/files') -- set FGRESTORE_REPO_DIR to the mysql-mariadb-physical-backup checkout" >&2
        return 1
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" "$bgr_image" sleep infinity >/dev/null

    docker cp "$bgr_repo_dir/bgrestore.sh" "$name:/usr/local/bin/bgrestore"
    docker cp "$bgr_fgrestore_repo_dir/files/fgrestore.sh" "$name:/usr/local/bin/fgrestore"
    docker cp "$bgr_fgrestore_repo_dir/files/timing.bash" "$name:/usr/local/bin/timing.bash"
    docker cp "$bgr_fgrestore_repo_dir/files/chain_resolve.bash" "$name:/usr/local/bin/chain_resolve.bash"
    docker exec "$name" chmod +x /usr/local/bin/bgrestore /usr/local/bin/fgrestore
}

# Unconditional teardown -- safe to call even if bgr_start never succeeded
# or the container is already gone.
bgr_stop() {
    local name="$1"
    docker rm -f "$name" >/dev/null 2>&1 || true
}

bgr_exec() {
    local name="$1"; shift
    docker exec "$name" bash -c "$*"
}

# Run bgrestore itself inside the container. Always invoked with an
# explicit -c so every test controls exactly which config it exercises.
bgr_run_bgrestore() {
    local name="$1" cnf_path="$2"
    docker exec "$name" bash -c "bgrestore -c '$cnf_path'"
}

bgr_wait_mysql_ready() {
    local name="$1" tries="${2:-40}"
    for ((_i = 0; _i < tries; _i++)); do
        docker exec "$name" mysqladmin ping >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

# Start MariaDB (via the systemctl shim, same path bgrestore.sh's own
# `systemctl start` goes through) and provision everything a restore needs:
# the bgbackup/backuphist user, the mdbutil.backup_history table, and a
# small table of real data in a schema of its own so a restore's result can
# be verified by querying it back afterward.
bgr_init_mariadb() {
    local name="$1"
    docker exec "$name" systemctl start mariadb
    bgr_wait_mysql_ready "$name" || { echo "FAIL: mariadb did not come up in $name" >&2; return 1; }

    docker exec "$name" mysql -uroot -e "
        CREATE USER IF NOT EXISTS 'bgbackup'@'localhost' IDENTIFIED BY 'password';
        GRANT SHUTDOWN, SELECT, RELOAD, INSERT, UPDATE, CREATE ON *.* TO 'bgbackup'@'localhost';
        FLUSH PRIVILEGES;
        CREATE DATABASE IF NOT EXISTS mdbutil;
        CREATE TABLE IF NOT EXISTS mdbutil.backup_history (
            uuid varchar(40) NOT NULL,
            hostname varchar(100) DEFAULT NULL,
            start_time timestamp NULL DEFAULT NULL,
            end_time timestamp NULL DEFAULT NULL,
            bulocation varchar(255) DEFAULT NULL,
            logfile varchar(255) DEFAULT NULL,
            status varchar(25) DEFAULT NULL,
            butype varchar(20) DEFAULT NULL,
            based_on_uuid varchar(40) DEFAULT NULL,
            weekly tinyint UNSIGNED NOT NULL DEFAULT 0,
            monthly tinyint UNSIGNED NOT NULL DEFAULT 0,
            yearly tinyint UNSIGNED NOT NULL DEFAULT 0,
            compressed varchar(5) DEFAULT NULL,
            encrypted varchar(5) DEFAULT NULL,
            cryptkey varchar(255) DEFAULT NULL,
            galera varchar(5) DEFAULT NULL,
            slave varchar(5) DEFAULT NULL,
            threads tinyint(2) DEFAULT NULL,
            xtrabackup_version varchar(120) DEFAULT NULL,
            server_version varchar(120) DEFAULT NULL,
            backup_size varchar(20) DEFAULT NULL,
            deleted_at timestamp NULL DEFAULT NULL,
            PRIMARY KEY (uuid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8;
        CREATE DATABASE IF NOT EXISTS restoretestdb;
        CREATE TABLE IF NOT EXISTS restoretestdb.canary (id INT PRIMARY KEY, val VARCHAR(50));
        REPLACE INTO restoretestdb.canary VALUES (1, 'original-data');
    "
}

# Write the minimal my.cnf fgrestore's -C uses to find datadir/socket/user
# for its --move-back step. Deliberately doesn't set tmpdir: fgrestore's
# move-back clears whatever directory tmpdir points to (see
# check_restore_path_not_cleared's whole reason for existing), and if that
# were /tmp, it would also wipe the lockfile and the mail-stub/mysqld-shim
# logs these tests depend on living in /tmp across a restore run.
bgr_write_restore_my_cnf() {
    local name="$1" path="$2"
    docker exec "$name" bash -c "cat > '$path' <<'EOF'
[mysqld]
datadir = /var/lib/mysql
socket = /run/mysqld/mysqld.sock
user = mysql
EOF"
}

# Take a real Full backup of whatever's currently running in the container
# via mariabackup, landing it at $raw_dir with the bgbackup.cnf fgrestore
# needs to resolve and restore it (see bgbackup.sh's own backup_write_config
# for the format this mirrors).
bgr_make_full_backup() {
    local name="$1" raw_dir="$2"
    docker exec "$name" bash -c "
        set -e
        mkdir -p '$raw_dir'
        mariabackup --backup --target-dir='$raw_dir' --user=root
        cat > '$raw_dir/bgbackup.cnf' <<EOF
butype=\"Full\"
backuptool=\"1\"
xtrabackup_version=\"test\"
server_version=\"test\"
compress=\"no\"
encrypt=\"no\"
galera=\"no\"
slave=\"no\"
stop_slave_sql_thread=\"no\"
end_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"
EOF
    "
}

# Writes a deliberately-broken 'backup': a bgbackup.cnf that looks valid
# but a target directory containing none of the real InnoDB/mariabackup
# metadata mariabackup --prepare needs. Used to simulate a restore failing
# partway through -- fast and deterministic, without needing to corrupt a
# real backup after the fact.
bgr_make_broken_backup() {
    local name="$1" raw_dir="$2"
    docker exec "$name" bash -c "
        mkdir -p '$raw_dir'
        : > '$raw_dir/not_a_real_backup_file'
        cat > '$raw_dir/bgbackup.cnf' <<EOF
butype=\"Full\"
backuptool=\"1\"
xtrabackup_version=\"test\"
server_version=\"test\"
compress=\"no\"
encrypt=\"no\"
galera=\"no\"
slave=\"no\"
stop_slave_sql_thread=\"no\"
end_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"
EOF
    "
}

bgr_insert_backup_history() {
    local name="$1" uuid="$2" hostname="$3" bulocation="$4"
    local status="${5:-SUCCEEDED}" butype="${6:-Full}" end_time="${7:-}"
    [[ -z "$end_time" ]] && end_time=$(docker exec "$name" date '+%Y-%m-%d %H:%M:%S')
    docker exec "$name" mysql -uroot -e "
        INSERT INTO mdbutil.backup_history
            (uuid, hostname, start_time, end_time, bulocation, logfile, status, butype, compressed, encrypted, galera, slave)
        VALUES
            ('$uuid', '$hostname', '$end_time', '$end_time', '$bulocation', '/var/log/fakebackup.log', '$status', '$butype', 'no', 'no', 'no', 'no');
    "
}

# Writes a full bgrestore.cnf with sane test defaults, overridable by
# passing additional VAR=VALUE arguments (each becomes one line, appended
# after -- and so taking precedence over, per bash 'source' semantics where
# later assignments win -- the defaults block).
bgr_write_bgrestore_cnf() {
    local name="$1" path="$2"; shift 2
    local body
    body=$(cat <<'EOF'
restore_my_cnf_file=/etc/bgrestore-test-my.cnf
service_name=mariadb
restorehost=localhost
restoreport=3306
restoreuser=bgbackup
restorepass=password
preppath=/preppath
backuphisthost=localhost
backuphistport=3306
backuphistuser=bgbackup
backuphistpass=password
backuphistschema=mdbutil
backuphost=test-backup-host
skipcopy=no
datadir=/var/lib/mysql
logpath=/var/log/bgrestore
keeplognum=1000
syslog=no
threads=2
maillist=test@example.com
mailsubpre=[BGRestoreTest]
mailon=all
EOF
    )
    local override
    for override in "$@"; do
        body="$body"$'\n'"$override"
    done
    docker exec "$name" bash -c "mkdir -p /preppath /var/log/bgrestore && cat > '$path' <<'BGRCNFEOF'
$body
BGRCNFEOF"
}
