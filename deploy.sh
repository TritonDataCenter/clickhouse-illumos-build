#!/bin/bash
#
# Sync this harness up to a SmartOS build host.
#
# Set HOST (and optionally SSH_KEY / REMOTE) for your environment:
#   HOST=root@build-host.example ./deploy.sh
#   HOST=root@build-host SSH_KEY=~/.ssh/id_ed25519 ./deploy.sh
#   HOST=root@build-host REMOTE=/opt/clickhouse-build ./deploy.sh
#
# Excludes macOS metadata (confuses gtar on the far end) and the on-host
# build scratch dirs.

set -o errexit
set -o pipefail
set -o nounset

ROOT=$(cd "$(dirname "$0")" && pwd)

: "${HOST:?set HOST=user@build-host (the SmartOS build zone)}"
: "${REMOTE:=/opt/clickhouse-build}"
: "${SSH_KEY:=$HOME/.ssh/id_rsa}"

ssh_opts=( -o ControlMaster=auto -o ControlPath=/tmp/.ssh-ch-%r@%h:%p -o ControlPersist=60s )
[[ -f "$SSH_KEY" ]] && ssh_opts=( -i "$SSH_KEY" "${ssh_opts[@]}" )

rsync -av --delete \
	-e "ssh ${ssh_opts[*]}" \
	--exclude='._*' --exclude='.DS_Store' --exclude='.git/' \
	--exclude='work/' --exclude='cache/' --exclude='artefact/' \
	"$ROOT/" "$HOST:$REMOTE/"

echo "deployed $ROOT -> $HOST:$REMOTE"
