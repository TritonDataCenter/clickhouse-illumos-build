#!/bin/bash
#
# Re-export the submodule-internal patches from the working checkout into
# patches/. Run this after you've fixed up submodule conflicts by hand
# (e.g. while porting to a new ClickHouse release): edit the files inside
# $CH_SRC/contrib/<name>/, then run this to capture the diffs.
#
# Parent-repo patches are NOT handled here -- those live as commits on the
# fork branch ($CH_REF); manage them with git rebase/cherry-pick.

set -o errexit
set -o pipefail
set -o nounset

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/lib/common.sh"
. "$ROOT/config.env"

PATCH_DIR="$ROOT/patches"

# Submodules we carry patches for. Add to this list if you patch a new one.
SUBMODULES=(
	abseil-cpp
	azure
	datasketches-cpp
	llvm-project
	miniselect
	rocksdb
	s2geometry
)

[[ -d "$CH_SRC/.git" ]] || fatal "$CH_SRC is not a git checkout"

tmp=$(mktemp -d)
trap "rm -rf $tmp" EXIT

wrote=0
for sm in "${SUBMODULES[@]}"; do
	d="contrib/$sm"
	[[ -d "$CH_SRC/$d" ]] || { info "skip $sm (no such submodule)"; continue; }
	if git -C "$CH_SRC/$d" diff --quiet HEAD 2>/dev/null; then
		info "$sm: no changes"
		continue
	fi
	out="$tmp/contrib-$sm.diff"
	git -C "$CH_SRC/$d" diff HEAD \
	    | sed -E "s#^(diff --git a/)(.*)( b/)(.*)#\1$d/\2\3$d/\4#; \
	              s#^--- a/#--- a/$d/#; \
	              s#^\+\+\+ b/#+++ b/$d/#" > "$out"
	mv "$out" "$PATCH_DIR/contrib-$sm.diff"
	info "$sm: wrote patches/contrib-$sm.diff ($(wc -l < "$PATCH_DIR/contrib-$sm.diff") lines)"
	wrote=$((wrote+1))
done

info "re-exported $wrote submodule patch(es)"
