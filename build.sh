#!/bin/bash
#
# Build ClickHouse on illumos (SmartOS pkgsrc).
#
# Model:
#   - Parent-repo illumos patches live as commits on the fork branch
#     $CH_REF (github.com/nwilkens/ClickHouse, branch illumos/<line>).
#   - Submodule-internal patches live as plain diffs in patches/ and are
#     applied here after `git submodule update`.
#
# Each run: fetch + checkout $CH_REF, sync submodules, apply the submodule
# patch series, configure with cmake, build with ninja, stage a tarball.
#
# Originally adapted from oxidecomputer/garbage-compactor's clickhouse build,
# stripped of Helios IPS packaging and CTF dependencies, rewired for SmartOS
# pkgsrc, and ported from ClickHouse 23.8 to 26.3.

set -o errexit
set -o pipefail
set -o nounset

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/lib/common.sh"
. "$ROOT/config.env"

PATCH_DIR="$ROOT/patches"
CACHE="$ROOT/cache"
ARTEFACT="$ROOT/artefact"
WORK="$ROOT/work"
STAMPS="$WORK/.stamps"
mkdir -p "$CACHE" "$ARTEFACT" "$WORK" "$STAMPS"

# ---------------------------------------------------------------------------
# 1. Tooling check.
# ---------------------------------------------------------------------------
header "checking build environment"

for cmd in "$CLANG" "$CLANGXX" cmake ninja nasm git "$GPATCH" "$GTAR" python3; do
	require_cmd "$cmd"
done

CLANG_VER=$("$CLANG" --version | awk '/clang version/ {print $3; exit}')
info "clang: $CLANG_VER ($CLANG)"
info "cmake: $(cmake --version | head -1)"
info "ninja: $(ninja --version)"
[[ -x "$PKGSRC_PREFIX/bin/ld.lld" ]] || info "warning: ld.lld not found; circular static-lib deps may fail to link"

if ! "$CLANG" --version | grep -q solaris; then
	fatal "clang at $CLANG is not configured for solaris/illumos"
fi
case "$CLANG_VER" in
	2[1-9].*|[3-9][0-9].*) : ;;
	*) fatal "ClickHouse 26.x needs clang >= 21; found $CLANG_VER (need pkgsrc trunk)" ;;
esac

# ---------------------------------------------------------------------------
# 2. Source: fetch + checkout the fork branch, sync submodules.
# ---------------------------------------------------------------------------
header "preparing source tree at $CH_SRC ($CH_REF from $CH_REPO)"

if [[ ! -d "$CH_SRC/.git" ]]; then
	info "cloning $CH_REPO @ $CH_REF (shallow, with submodules)..."
	git clone --branch "$CH_REF" --depth 1 "$CH_REPO" "$CH_SRC"
	git -C "$CH_SRC" submodule update --init --recursive --depth 1 --jobs 8
else
	info "resetting existing checkout..."
	git -C "$CH_SRC" am --abort 2>/dev/null || true
	git -C "$CH_SRC" reset --hard --quiet
	# Drop any leftover patch detritus, but keep the build dir and submodules.
	git -C "$CH_SRC" clean -fd --quiet -e build -e contrib

	# Make sure the fork + upstream remotes exist.
	if ! git -C "$CH_SRC" remote get-url fork >/dev/null 2>&1; then
		git -C "$CH_SRC" remote add fork "$CH_REPO"
	fi
	if ! git -C "$CH_SRC" remote get-url upstream >/dev/null 2>&1; then
		git -C "$CH_SRC" remote add upstream "$CH_UPSTREAM"
	fi

	info "fetching $CH_REF..."
	git -C "$CH_SRC" fetch --depth 1 fork "$CH_REF"
	git -C "$CH_SRC" checkout --quiet --detach FETCH_HEAD
	git -C "$CH_SRC" submodule update --init --recursive --depth 1 --jobs 8
fi

git -C "$CH_SRC" config user.name "ClickHouse illumos build"
git -C "$CH_SRC" config user.email "clickhouse-illumos-build@localhost"

# ---------------------------------------------------------------------------
# 3. Apply submodule patches.
# ---------------------------------------------------------------------------
# These touch files inside submodules, which a superproject branch can't
# carry. We apply them with gpatch (tolerating a little fuzz) after the
# submodules are checked out. Skip any that already reverse-apply cleanly
# (in case a future submodule bump absorbs one).
header "applying submodule patches ($PATCH_DIR)"

shopt -s nullglob
patches=( "$PATCH_DIR"/*.diff "$PATCH_DIR"/*.patch )
shopt -u nullglob

applied=()
skipped=()
failed=()

for f in "${patches[@]}"; do
	name=$(basename "$f")
	# Already applied? (reverse-applies cleanly). git apply --reverse can't
	# see paths inside submodules, so use gpatch's dry-run reverse instead.
	if "$GPATCH" --directory="$CH_SRC" --dry-run --reverse --batch \
	    --strip=1 --silent < "$f" >/dev/null 2>&1; then
		skipped+=( "$name" )
		continue
	fi
	if "$GPATCH" --directory="$CH_SRC" --batch --forward --fuzz=5 \
	    --strip=1 --silent --reject-file=- < "$f" >/dev/null 2>&1; then
		applied+=( "$name" )
		continue
	fi
	failed+=( "$name" )
done

info "submodule patches applied:        ${#applied[@]}"
info "submodule patches already present: ${#skipped[@]}"
info "submodule patches needing rework:  ${#failed[@]}"
for n in ${skipped[@]+"${skipped[@]}"}; do info "  SKIP   $n"; done
for n in ${applied[@]+"${applied[@]}"}; do info "  APPLY  $n"; done
for n in ${failed[@]+"${failed[@]}"};  do info "  FAIL   $n"; done
if (( ${#failed[@]} > 0 )) && [[ "${CH_STRICT_PATCHES:-0}" == "1" ]]; then
	fatal "CH_STRICT_PATCHES=1; aborting due to submodule patch failures"
fi

# ---------------------------------------------------------------------------
# 4. Configure with cmake.
# ---------------------------------------------------------------------------
header "configuring with cmake"

njobs=$(psrinfo -t)
mem_mb=$(/usr/sbin/prtconf -m)
njobs_mem=$(( mem_mb / 1024 / 3 ))
if (( njobs_mem < njobs )); then
	info "memory-bound: $mem_mb MB / 3 GB per job => $njobs_mem jobs (was $njobs)"
	njobs=$njobs_mem
fi
(( njobs > 0 )) || njobs=1
info "using $njobs compile job(s)"

export PATH="$PKGSRC_PREFIX/bin:/usr/bin:/usr/sbin:/sbin"

BUILD="$CH_SRC/build"

# pkgsrc ships clang and gcc as separate packages with no auto-linkage:
# clang's default search dirs don't include gcc's crtbegin.o / libgcc_s.
# (--gcc-toolchain is silently ignored by pkgsrc's clang on the SmartOS
# layout; -B for startup files + -L for runtime libs is the working combo.)
GCC_PREFIX="${GCC_PREFIX:-/opt/local/gcc13}"
GCC_TRIPLE="${GCC_TRIPLE:-x86_64-sun-solaris2.11}"
GCC_VER="${GCC_VER:-$(ls -1d "$GCC_PREFIX/lib/gcc/$GCC_TRIPLE"/[0-9]* 2>/dev/null | tail -1 | xargs -n1 basename)}"
[[ -n "$GCC_VER" ]] || fatal "could not detect gcc version under $GCC_PREFIX/lib/gcc/$GCC_TRIPLE"
GCC_LIBDIR="$GCC_PREFIX/lib/gcc/$GCC_TRIPLE/$GCC_VER"
GCC_AMD64="$GCC_PREFIX/lib/amd64"
for d in "$GCC_LIBDIR" "$GCC_AMD64"; do [[ -d "$d" ]] || fatal "missing gcc dir: $d"; done
info "gcc toolchain: $GCC_PREFIX (gcc $GCC_VER)"

GCC_FLAGS="-B$GCC_LIBDIR -B$GCC_PREFIX/$GCC_TRIPLE/lib/amd64 -L$GCC_LIBDIR -L$GCC_AMD64"

CFLAGS="$GCC_FLAGS"
CFLAGS+=' -D_REENTRANT -D_POSIX_PTHREAD_SEMANTICS -D__EXTENSIONS__ -m64'
CFLAGS+=' -DHAVE_STRERROR_R -DSTRERROR_R_INT'
# Helios's clang predefines __illumos__; pkgsrc clang does not. Several
# contribs (curl, ...) gate their illumos branches on it.
CFLAGS+=' -D__illumos__'
# illumos guards POSIX-2008 functions (dprintf, ...) behind
# _POSIX_C_SOURCE >= 200809L; some contribs include feature_tests.h in a way
# that clobbers __EXTENSIONS__, so set this too.
CFLAGS+=' -D_POSIX_C_SOURCE=200809L'
CFLAGS+=' -fno-use-cxa-atexit '
CXXFLAGS="$CFLAGS -fcxx-exceptions -fexceptions -frtti "

stamp="$STAMPS/cmake.stamp"
if [[ ! -f "$stamp" ]]; then
	# Don't wipe the build dir: cmake reconfigures incrementally and ninja
	# only rebuilds what a patch actually touched. (A full wipe forces a
	# multi-hour recompile every iteration.) For a truly clean build, rm -rf
	# the build dir by hand first.
	mkdir -p "$BUILD"

	CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" cmake \
	    -G Ninja \
	    -DCMAKE_BUILD_TYPE=Release \
	    -DCOMPILER_CACHE=disabled \
	    -DCMAKE_INSTALL_PREFIX="$CH_PREFIX" \
	    -DCMAKE_C_COMPILER="$CLANG" \
	    -DCMAKE_CXX_COMPILER="$CLANGXX" \
	    -DCMAKE_C_FLAGS="$CFLAGS" \
	    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
	    -DABSL_CXX_STANDARD=20 \
	    -DENABLE_LDAP=off \
	    -DENABLE_HDFS=off \
	    -DENABLE_AMQPCPP=off \
	    -DENABLE_AVRO=off \
	    -DENABLE_CAPNP=off \
	    -DENABLE_MSGPACK=off \
	    -DENABLE_MYSQL=off \
	    -DENABLE_PARQUET=off \
	    -DENABLE_S3=off \
	    -DENABLE_ORC=off \
	    -DENABLE_WASMEDGE=off \
	    -DENABLE_EMBEDDED_COMPILER=off \
	    -DENABLE_DWARF_PARSER=off \
	    -DENABLE_ROCKSDB=off \
	    -DENABLE_CASSANDRA=off \
	    -DENABLE_NURAFT=off \
	    -DENABLE_GRPC=off \
	    -DENABLE_AZURE_BLOB_STORAGE=off \
	    -DUSE_MONGODB=off \
	    -DENABLE_KAFKA=off \
	    -DENABLE_NATS=off \
	    -DENABLE_LIBPQXX=off \
	    -DENABLE_CHDIG=off \
	    -DENABLE_CLIENT_AI=off \
	    -DENABLE_RUST=off \
	    -DWERROR=off \
	    -DUSE_SENTRY=off \
	    -DENABLE_SENTRY=off \
	    -DENABLE_CLICKHOUSE_ODBC_BRIDGE=off \
	    -DENABLE_CLICKHOUSE_BENCHMARK=off \
	    -DENABLE_TESTS=off \
	    -DCMAKE_BUILD_WITH_INSTALL_RPATH=on \
	    -DPARALLEL_COMPILE_JOBS="$njobs" \
	    -DPARALLEL_LINK_JOBS=1 \
	    -S "$CH_SRC" \
	    -B "$BUILD" \
	    2>&1 | tee "$WORK/cmake.log"

	touch "$stamp"
else
	info "cmake already configured (rm $stamp to redo)"
fi

# ---------------------------------------------------------------------------
# 5. Build with ninja.
# ---------------------------------------------------------------------------
header "building with ninja"

stamp="$STAMPS/ninja.stamp"
if [[ ! -f "$stamp" ]]; then
	jobs=$njobs
	while :; do
		info "ninja -j $jobs"
		if ninja -k 0 -C "$BUILD" -j "$jobs" 2>&1 | tee "$WORK/ninja.log"; then
			info "ninja build succeeded"
			break
		fi
		if [[ "${CH_LINK_RECOVERY:-0}" != "1" ]] || (( jobs <= 1 )); then
			fatal "ninja build failed; see $WORK/ninja.log"
		fi
		jobs=$(( jobs / 2 )); (( jobs < 1 )) && jobs=1
		info "retrying with -j $jobs (memory pressure suspected)..."
	done
	touch "$stamp"
else
	info "ninja already built (rm $stamp to redo)"
fi

# ---------------------------------------------------------------------------
# 6. Stage stripped binaries + tar them up.
# ---------------------------------------------------------------------------
header "staging artifact"

rm -rf "$CACHE"
mkdir -p "$CACHE/bin" "$CACHE/etc"

install -m 0755 "$BUILD/programs/clickhouse" "$CACHE/bin/clickhouse"
/usr/bin/strip -x "$CACHE/bin/clickhouse"

shopt -s nullglob
for f in "$BUILD/programs/"clickhouse-*; do
	base=$(basename "$f")
	if [[ -L "$f" ]]; then
		cp -P "$f" "$CACHE/bin/$base"
	else
		install -m 0755 "$f" "$CACHE/bin/$base"
		/usr/bin/strip -x "$CACHE/bin/$base" || true
	fi
done
shopt -u nullglob

for f in config.xml users.xml; do
	[[ -f "$CH_SRC/programs/server/$f" ]] && install -m 0644 "$CH_SRC/programs/server/$f" "$CACHE/etc/$f"
done

OUT="$ARTEFACT/clickhouse-${CH_VER}-illumos-amd64.tar.gz"
rm -f "$OUT"
"$GTAR" -C "$CACHE" -czf "$OUT" bin etc
info "wrote $OUT"
info "  size: $(ls -lh "$OUT" | awk '{print $5}')"
info "  sha256: $(digest -a sha256 "$OUT")"

header "build complete"
