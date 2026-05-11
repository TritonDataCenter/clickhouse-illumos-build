#
# Shared helpers for the ClickHouse illumos build harness.
# Adapted from oxidecomputer/garbage-compactor/lib/common.sh, but with the
# Helios/IPS packaging and CTF tooling dependencies removed because this
# runs on stock SmartOS pkgsrc.
#

unset HARDLINK_TARGETS

# Resolve GNU tool names (pkgsrc ships them prefixed with 'g').
GTAR="${GTAR:-/opt/local/bin/gtar}"
GPATCH="${GPATCH:-/opt/local/bin/gpatch}"
GFIND="${GFIND:-/opt/local/bin/gfind}"
GGREP="${GGREP:-/opt/local/bin/ggrep}"

function info {
	printf 'INFO: %s\n' "$*"
}

function header {
	printf -- '\n'
	printf -- '----------------------------------------------------------\n'
	printf -- 'INFO: %s\n' "$*"
	printf -- '----------------------------------------------------------\n'
	printf -- '\n'
}

function fatal {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

function require_cmd {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || fatal "missing required command: $cmd"
}
