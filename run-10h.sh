#!/bin/bash
# Start only the reviewed, locally installed systemd template. No installation/cleanup.
set -euo pipefail
if [[ -n "$(systemctl list-units --no-legend --plain --state=running 'msi-burnin*')" ]]; then
    echo 'A burn-in service is already running; refusing concurrent stress tests.' >&2
    exit 1
fi
instance=$(date -u +%Y%m%dT%H%M%SZ)
unit="msi-burnin@${instance}.service"
sudo systemctl start "$unit"
printf 'Service: %s\nReports: /home/e/acceptance/burnin-runs/10h-%s/\nStop: sudo systemctl stop %s\nHourly output: journalctl -fu %s\n' "$unit" "$instance" "$unit" "$unit"
