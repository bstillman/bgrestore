#!/bin/bash

# Minimal `systemctl` replacement for containers with no systemd/PID 1 init.
# bgrestore.sh only ever calls `systemctl start "$service_name"` (the
# shutdown half of a restore goes through a SQL `shutdown` command instead),
# but this forwards any verb so the test harness's own setup/teardown can
# use the same systemctl-shaped calls bgrestore.sh itself would make.
#
# Debian's mariadb-server package ships a SysV /etc/init.d/<service> wrapper
# alongside its systemd unit for exactly this situation; `service` is the
# standard way to drive it directly, bypassing the need for a running
# systemd.

set -u

action="$1"
service_name="$2"

exec service "$service_name" "$action"
