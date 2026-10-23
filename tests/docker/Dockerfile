# Test-only image for bgrestore.sh's live-Docker test suite (tests/test_*_e2e.sh,
# tests/test_lockfile.sh, etc). Not part of the shipped product -- this just
# provisions an OS with a real MariaDB server, mariabackup, and a couple of
# small shims so the rest of bgrestore.sh's runtime environment (systemd's
# `systemctl`, and a mail transport agent) exists in a plain container.
#
# bgrestore.sh / fgrestore.sh themselves are NOT baked into this image -- the
# test harness (tests/docker/lib.sh) `docker cp`s them into a running
# container fresh for each test run, so tests always exercise the exact
# files currently on disk, never a stale baked-in copy.
FROM debian:12-slim

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        mariadb-server \
        mariadb-backup \
        mariadb-client \
        sudo \
        procps \
        zstd \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Minimal `systemctl` shim: this container has no systemd (no PID 1 init),
# so bgrestore.sh's `systemctl start "$service_name"` call is forwarded to
# the real SysV /etc/init.d/<service> wrapper via `service`, which Debian's
# mariadb-server package ships alongside its systemd unit for exactly this
# kind of non-systemd environment. Only 'start' is called by bgrestore.sh
# itself; 'stop'/'status' are included too since the test harness's own
# setup/teardown finds it convenient to use the same verb set.
COPY systemctl-shim.sh /usr/local/bin/systemctl

# Mail stub: stands in for the real `mail` (mailutils/bsd-mailx) binary,
# which isn't installed here (no MTA in this environment). Records every
# invocation (args + stdin body) so tests can assert on what bgrestore.sh's
# mail_log() actually sent, instead of needing a real mail transport.
COPY mail-stub.sh /usr/local/bin/mail

# Test-only mysqld wrapper, placed ahead of the real /usr/sbin/mysqld on
# PATH -- see the comment inside for why this exists. It is NOT a stand-in
# for mysqld in general: every invocation other than bgrestore.sh's own
# MDEV-6660 workaround line is exec'd straight through to the real binary,
# unmodified (e.g. fgrestore.sh's own `mysqld -V` version probe).
COPY mysqld-shim.sh /usr/local/bin/mysqld
RUN chmod 755 /usr/local/bin/systemctl /usr/local/bin/mail /usr/local/bin/mysqld

CMD ["sleep", "infinity"]
