# Building ClickHouse on illumos (SmartOS)

This repo builds [ClickHouse](https://github.com/ClickHouse/ClickHouse) for
illumos / SmartOS. It produces a stripped multi-call `clickhouse` binary
(`clickhouse-server`, `clickhouse-client`, `clickhouse-local`, ... as
symlinks) plus the default `config.xml` / `users.xml`, tarred up under
`artefact/`.

Current target: **ClickHouse 26.3.10.60-lts** (the March-2026 LTS line).
Confirmed working: MergeTree / ReplicatedMergeTree, INSERT / SELECT /
aggregations, `OPTIMIZE ... FINAL`, the Native (TCP) and HTTP protocols.

## How the patching is organised

ClickHouse needs a fair number of changes to build on illumos. They live in
two places:

1. **Parent-repo patches** — changes to `cmake/`, `src/`, `utils/`,
   `base/poco/`, `contrib/*-cmake/`, etc. These are commits on the
   `smartos/<line>` branch of the fork
   **[github.com/TritonDataCenter/ClickHouse](https://github.com/TritonDataCenter/ClickHouse)**
   (currently `smartos/26.3`). Manage them with normal git
   (`rebase` / `cherry-pick`).

2. **Submodule-internal patches** — changes to files *inside* git
   submodules (`contrib/llvm-project` libcxx, `contrib/abseil-cpp`,
   `contrib/datasketches-cpp`, `contrib/miniselect`, `contrib/s2geometry`,
   ...). A superproject branch can't carry these, so they live here as plain
   diffs in `patches/contrib-<name>.diff` and are applied at build time
   after `git submodule update`. `extract-submodule-patches.sh` re-exports
   them from a working checkout.

The bulk of upstream's churn lands in the parent repo, which `git rebase`
handles with proper 3-way merges; the submodule diffs are small and change
rarely.

## Prerequisites (build host)

A SmartOS zone with **pkgsrc trunk** (not the 2024Q4 quarterly — ClickHouse
26.x needs clang ≥ 21 and C++23, which only trunk has). To switch:

```sh
echo "https://pkgsrc.smartos.org/packages/SmartOS/trunk/x86_64/All" \
    > /opt/local/etc/pkgin/repositories.conf
pkgin -y update
pkgin -y install clang-21.1.8 lld
```

That cascades a fair number of upgrades (gcc13 → 13.4, cmake → 4.x,
libxml2, python313, ...). After it settles you should have:

| tool          | minimum            | provided by pkgsrc trunk |
|---------------|--------------------|--------------------------|
| `clang` / `clang++` | 21               | `clang-21.1.8` (target `x86_64-pc-solaris2.11`) |
| `ld.lld`      | 21                 | `lld-21.1.8` (optional but recommended) |
| `gcc13`       | 13.4               | `gcc13-13.4.0` (clang links its crt/runtime) |
| `cmake`       | 4.x                | `cmake-4.3.2` |
| `ninja`       | any recent         | `ninja-build` |
| `nasm`        | any recent         | `nasm` |
| `git`, `python3`, `gtar`, `gpatch`, `gfind`, `ggrep` | — | pkgsrc base |
| `rustup` + nightly-2025-08-07 illumos toolchain | — | only needed if you re-enable Rust features (currently `-DENABLE_RUST=off`) |

You also need:
- ~30 GB free on the build host (`/opt`).
- ~64 GB RAM is comfortable; the harness caps ninja jobs at `mem / 3 GB`
  because some TUs hit 3–4 GB resident.
- GitHub SSH access for the user that owns the fork (to fetch `CH_REF` and,
  for upgrades, to push the rebased branch).

## Building

```sh
# 1. (first time) put this directory on the build host, e.g.:
HOST=root@your-smartos-build-host ./deploy.sh

# 2. on the build host:
cd /opt/clickhouse-build
bash build.sh        # ~1h cold; minutes on a rebuild (build dir is kept)
```

`build.sh`:
1. clones / fetches `$CH_REF` from `$CH_REPO` into `$CH_SRC` (default
   `/opt/ClickHouse`) and runs `git submodule update --recursive --depth 1`;
2. applies `patches/contrib-*.diff` (skipping any that already
   reverse-apply, e.g. after a submodule bump);
3. configures with cmake (lots of optional contribs disabled — see below);
4. builds with `ninja -k 0`, halving the job count on memory-pressure
   link failures;
5. strips the binary and writes `artefact/clickhouse-<ver>-illumos-amd64.tar.gz`.

Output: `artefact/clickhouse-<ver>-illumos-amd64.tar.gz` containing
`bin/clickhouse` (+ the `clickhouse-*` symlinks) and `etc/config.xml`,
`etc/users.xml`.

### Prebuilt binaries

Tagged builds are published as
[GitHub releases](https://github.com/TritonDataCenter/clickhouse-illumos-build/releases)
with the tarball + a `.sha256`:

```sh
gh release download -R TritonDataCenter/clickhouse-illumos-build --pattern '*.tar.gz*'
shasum -a 256 -c clickhouse-*.tar.gz.sha256
tar xzf clickhouse-*-illumos-amd64.tar.gz
./bin/clickhouse --version
```

### Smoke test

```sh
tar xzf clickhouse-26.3.10.60-illumos-amd64.tar.gz
./bin/clickhouse --version
./bin/clickhouse local --query "SELECT version(), count() FROM numbers(1e6)"

mkdir -p /tmp/ch/data
./bin/clickhouse server --config-file=etc/config.xml -- \
    --path=/tmp/ch/data/ --tcp_port=19000 --http_port=18123 \
    --listen_host=127.0.0.1 &
./bin/clickhouse client --port 19000 --query "
  CREATE TABLE t (a UInt64, b String) ENGINE=MergeTree ORDER BY a;
  INSERT INTO t SELECT number, toString(number) FROM numbers(100000);
  SELECT count(), sum(a) FROM t; OPTIMIZE TABLE t FINAL;"
curl -s 'http://127.0.0.1:18123/?query=SELECT+1%2B1'
```

## Bumping to a new ClickHouse release

```sh
# in a ClickHouse checkout with `upstream` = ClickHouse/ClickHouse and
# `origin` = TritonDataCenter/ClickHouse:
git fetch upstream
git checkout -b smartos/26.4 v26.4.x.y-lts
git submodule update --init --recursive --depth 1
git rebase --onto v26.4.x.y-lts v26.3.10.60-lts smartos/26.3   # carry the parent patches
# resolve conflicts; build; if a submodule patch no longer applies cleanly,
# fix the file inside contrib/<name>/ by hand, then in this repo:
#   CH_SRC=<that checkout> ./extract-submodule-patches.sh
git push -u origin smartos/26.4
```

Then edit `config.env` (`CH_REF=smartos/26.4`, `CH_VER=26.4.x.y`) and run
`build.sh` again.

## Continuous integration

`.github/workflows/illumos-build.yml` runs this harness on a self-hosted
illumos builder, modelled on TritonDataCenter/mariana-trench's illumos leg:
a Linux self-hosted runner checks out the harness, rsyncs it to the builder,
runs `build.sh` over ssh, and scp's the tarball back as an Actions artifact
(and, on `v*` tags, a GitHub release with a `.sha256` sidecar).

Triggers: push to `main`, `v*` tags, and manual `workflow_dispatch`. One
physical builder, so runs are serialized by a `concurrency` group.

One-time setup (operator):

1. **Builder zone** — a SmartOS zone on pkgsrc **trunk** (clang>=21, lld,
   cmake>=4, ninja, nasm, gcc13>=13.4, gpatch, gtar, python3). Keep it
   separate from the mariana-trench gcc13/quarterly Rust builder: the
   quarterly->trunk switch cascades upgrades that can break that toolchain.
2. **SSH** — authorize the Linux runner's key for `root@<zone>` (the runner
   ssh's in to build).
3. **Runner** — register the self-hosted Linux runner so this repo can use
   it (org-level runner shared with mariana-trench, or a repo-scoped runner).
4. **Repo variable** — set `CLICKHOUSE_BUILDER` to `root@<zone-ip>`.

The workflow fails fast with a clear message if `CLICKHOUSE_BUILDER` is unset.

## What's disabled (and why)

To keep the build tractable on illumos, `build.sh` turns off a pile of
optional contribs. None of these are needed for the MergeTree data store +
Native/HTTP protocols. Re-enable any of them by dropping the corresponding
`-DENABLE_*=off` from `build.sh` — expect to write more illumos patches.

| flag | what it gives up |
|---|---|
| `ENABLE_LDAP` | LDAP auth + dictionary source |
| `ENABLE_HDFS` | HDFS table engine / disk |
| `ENABLE_AMQPCPP` | RabbitMQ table engine |
| `ENABLE_AVRO`, `ENABLE_CAPNP`, `ENABLE_MSGPACK`, `ENABLE_PARQUET`, `ENABLE_ORC` | those input/output formats |
| `ENABLE_MYSQL` | MySQL table engine / dictionary source |
| `ENABLE_S3`, `ENABLE_AZURE_BLOB_STORAGE` | S3 / Azure object storage backends |
| `ENABLE_WASMEDGE` | WebAssembly UDFs |
| `ENABLE_EMBEDDED_COMPILER` | LLVM-based JIT for expressions |
| `ENABLE_DWARF_PARSER` | DWARF input format (also trims the LLVM build to just `LLVMSupport` for BLAKE3) |
| `ENABLE_ROCKSDB` | `EmbeddedRocksDB` table engine |
| `ENABLE_CASSANDRA` | Cassandra dictionary source |
| `ENABLE_NURAFT` | ClickHouse Keeper (server side) |
| `ENABLE_GRPC` | gRPC client protocol |
| `USE_MONGODB` | MongoDB dictionary source |
| `ENABLE_KAFKA`, `ENABLE_NATS` | Kafka / NATS table engines |
| `ENABLE_LIBPQXX` | PostgreSQL dictionary source + `MaterializedPostgreSQL` |
| `ENABLE_CHDIG` | `chdig` terminal UI (separate Rust tool) |
| `ENABLE_CLIENT_AI` | AI SDK for SQL generation |
| `ENABLE_RUST` | all in-tree Rust crates (`prql`, `skim`, `polyglot`, `wasmtime`) |
| `WERROR` | warnings-as-errors (a number of contribs don't compile cleanly under clang-21 on illumos) |

Still **on**: MergeTree family, Native + HTTP protocols, lz4/zstd/snappy/bzip2
compression, vectorscan (regex), ICU, jemalloc, OpenSSL, protobuf, SQLite
engine, bcrypt, jwt-cpp, s2geometry, BLAKE3, replxx (interactive client).

## Files in this repo

| file | purpose |
|---|---|
| `build.sh` | the build driver |
| `config.env` | version / fork / toolchain knobs |
| `deploy.sh` | `rsync` this dir to the build host |
| `extract-submodule-patches.sh` | re-export `patches/contrib-*.diff` from a working checkout |
| `lib/common.sh` | shell helpers (`info`, `header`, `fatal`, GNU tool paths) |
| `patches/contrib-*.diff` | submodule-internal illumos patches |
| `work/`, `cache/`, `artefact/` | build scratch / staged binaries / output tarball (gitignored) |

## Notable illumos gotchas (for whoever maintains this)

- pkgsrc clang and gcc are separate packages; clang needs `-B`/`-L` pointing
  at `/opt/local/gcc13/...` to find `crtbegin.o` / `libgcc_s`.
- pkgsrc clang does **not** predefine `__illumos__` (Helios's does); curl and
  a few others gate illumos branches on it, so the harness passes
  `-D__illumos__`.
- `dprintf` and friends need `_POSIX_C_SOURCE >= 200809L`; some contribs
  clobber `__EXTENSIONS__`, so the harness also passes `-D_POSIX_C_SOURCE`.
- illumos `struct lconv` lacks the XPG7 `int_*` currency fields; libcxx's
  `moneypunct_byname` is patched to use the plain forms (like it does for
  MSVCRT).
- illumos doesn't expose `strtof_l` / `strtod_l` / `strtold_l`; libcxx's
  `musl.h` shim is extended with locale-less fallbacks.
- The illumos link-editor scans archives strictly left-to-right and
  ClickHouse's static-lib graph has an undeclared cycle
  (`clickhouse_common_zookeeper_base` ↔ `clickhouse_common_zookeeper`);
  `cmake/sunos/default_libs.cmake` is patched to add `-Wl,-z,rescan`.
- `utils/list-licenses/list-licenses.sh` uses `xargs … bash -c` relying on
  exported bash functions, which illumos's bash 4.3 drops; it's rewritten to
  use serial loops and `gfind`/`ggrep`.
- `libarchive` is skipped on illumos (its GLOB'd sources include
  `<lz4.h>`/`<openssl/*.h>`/`<zlib.h>` unconditionally and the cmake linkage
  doesn't propagate those includes); ClickHouse's archive code is gated on
  `USE_LIBARCHIVE` so the rest builds fine.

## Credit

The illumos port started from
[oxidecomputer/garbage-compactor](https://github.com/oxidecomputer/garbage-compactor/tree/master/clickhouse)
(which built ClickHouse 23.8 for Helios). This repo carries that forward to
26.3 on SmartOS pkgsrc — most of the original 62-patch series is now either
upstream or obsolete; what remains is the parent-repo branch + the handful of
`patches/contrib-*.diff` here.
