#!/usr/bin/env bash
#
# indradb/mayhem/build.sh — build the `compare` cargo-fuzz target (sanitized)
# plus the KAT probe (clean) used by mayhem/test.sh.
#
# This is a BACKPORT branch (repro-11c1c04a — RFD 0001 / BACKPORT.md), not the
# live port: the live `mayhem` branch deliberately drops upstream's own
# lib/fuzz/ differential harness in favor of file-I/O-free MemoryDatastore-only
# targets (ops/identifier). This branch instead reproduces mayhemheroes run 26
# verbatim, so it restores that original harness instead:
#
# Targets produced (one Mayhemfile each):
#   /mayhem/compare      — upstream's own differential MemoryDatastore-vs-
#                          RocksdbDatastore fuzzer (a tempdir()-backed Rocksdb
#                          instance), copied from mayhemheroes/indradb@010f8f8
#                          verbatim as mayhem/fuzz/fuzz_targets/compare.rs.
#   /mayhem/kat          — dynamically-linked known-answer probe used by
#                          mayhem/test.sh.
#
# The fuzz crate lives under mayhem/fuzz/ (own empty [workspace], per
# docs/netnew-worker-prompt.md §6 — never a member of the upstream root
# workspace that lists lib/proto/server/client/plugins/*), and depends on
# indradb-lib with the rocksdb-datastore feature enabled (needed by `compare`).
#
# TOOLCHAIN: unlike some fleet repos, indradb ships NO rust-toolchain(.toml)
# at all, so there is no hijack trap to route around — but every cargo
# invocation below is still explicit +$RUST_NIGHTLY / +$RUST_STABLE, both for
# consistency with the rest of the fleet and so a future upstream commit that
# DOES add one can't silently change what toolchain this script runs on.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under
#     $CARGO_HOME=/opt/toolchains/rust/cargo (pinned, $HOME-independent).
#   - The rlenv runtime exports CARGO_NET_OFFLINE=true for the PATCH re-run, so
#     do NOT hard-code --offline here (it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
: "${RUST_NIGHTLY:=nightly-2025-06-01}"
: "${RUST_STABLE:=stable}"
# The org base image sets $SANITIZER_FLAGS as a *clang* ASan+UBSan flag string
# (for C/C++ builds); it doesn't apply to rustc. Rust's OSS-Fuzz sanitizer path
# instruments via `-Zsanitizer=address` in $RUSTFLAGS instead (below), so we
# don't consume $SANITIZER_FLAGS directly — just acknowledge/pass it through so
# an explicit `--build-arg SANITIZER_FLAGS=` (no-sanitizer build request) is at
# least visible here rather than silently ignored.
: "${SANITIZER_FLAGS:=}"
echo "SANITIZER_FLAGS (clang-flavored, informational only for this Rust build): $SANITIZER_FLAGS"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"
echo "=== toolchains ==="
cargo "+$RUST_NIGHTLY" --version
cargo "+$RUST_STABLE" --version

mkdir -p "$SRC/mayhem/mayhem-build"

# ── DWARF3 anchor (SPEC §6.2 item 10) ───────────────────────────────────────
# rustc/LLVM has no stable flag to pin the emitted DWARF version, and Mayhem's
# triage can't read DWARF >= 4 (clang-19/current rustc emit DWARF5 by default).
# verify-repo only reads the FIRST compile unit's DWARF version, so we prepend
# (never append — the anchor's CU must land at .debug_info offset 0) a small
# clang -gdwarf-3 object ahead of every other linker input, via a -C linker
# cc-wrapper that always execs it first.
cat > "$SRC/mayhem/mayhem-build/dwarf3_anchor.c" <<'EOF'
int __mayhem_dwarf3_anchor;
EOF
clang -gdwarf-3 -c "$SRC/mayhem/mayhem-build/dwarf3_anchor.c" -o "$SRC/mayhem/mayhem-build/dwarf3_anchor.o"
cat > "$SRC/mayhem/mayhem-build/dwarf3-cc-wrapper.sh" <<EOF
#!/bin/sh
exec clang "$SRC/mayhem/mayhem-build/dwarf3_anchor.o" "\$@"
EOF
chmod +x "$SRC/mayhem/mayhem-build/dwarf3-cc-wrapper.sh"

# ── fuzz targets (pinned nightly, ASan via RUSTFLAGS — the OSS-Fuzz Rust path) ─
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# ONLY when no lockfile is committed yet: `generate-lockfile` hits the crates.io
# index over the network, which breaks the AIR-GAPPED PATCH re-run (SPEC §6.5,
# `docker run --network none ... bash mayhem/build.sh`). The committed
# mayhem/fuzz/Cargo.lock (from the first, online build) makes a normal
# `cargo fuzz build` against it need no network at all — this block is a
# one-time bootstrap, not a per-run step.
if [ ! -f "$SRC/$FUZZ_DIR/Cargo.lock" ]; then
  ( cd "$SRC/$FUZZ_DIR" && cargo "+$RUST_NIGHTLY" generate-lockfile )
fi

# RUST_DEBUG_FLAGS is the Rust half of the DWARF-debug-info contract (§6.2 item
# 10; the DWARF3 anchor above is what actually pins the version verify-repo
# reads, but this flag still carries real debug info into the Rust-compiled CUs).
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=1}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS -Cforce-frame-pointers -C linker=$SRC/mayhem/mayhem-build/dwarf3-cc-wrapper.sh"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo +$RUST_NIGHTLY fuzz build (ASan via RUSTFLAGS, DWARF3 anchor linker) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo "+$RUST_NIGHTLY" fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── The KAT probe used by mayhem/test.sh (stable toolchain, NORMAL flags — it
#    is a functional oracle, not a triage artifact, so no sanitizer/fuzz
#    instrumentation here). ───────────────────────────────────────────────────
echo "=== building /mayhem/kat (KAT probe, +$RUST_STABLE, normal flags) ==="
unset RUSTFLAGS
if [ ! -f "$SRC/mayhem/kat/Cargo.lock" ]; then
  ( cd "$SRC/mayhem/kat" && cargo "+$RUST_STABLE" generate-lockfile )
fi
cargo "+$RUST_STABLE" build --manifest-path mayhem/kat/Cargo.toml --release
kat_bin="$SRC/mayhem/kat/target/release/kat"
[ -x "$kat_bin" ] || { echo "ERROR: kat binary not found at $kat_bin" >&2; exit 1; }
cp "$kat_bin" /mayhem/kat
# Rust binaries dynamically link libc by default (unlike Go's static default), so
# no cgo-equivalent trick is needed — but assert it as a regression guard so a
# future toolchain/target change can't silently turn the probe static and make
# it unreachable by verify-repo's LD_PRELOAD sabotage shim (SPEC §6.3).
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# `cargo test` compiles on demand, so there is no separate test-suite precompile
# step here; mayhem/test.sh runs it directly with the SAME +$RUST_STABLE
# toolchain used above, so it never silently rebuilds under a different
# toolchain at test time.

echo "build.sh complete:"
ls -la /mayhem/compare /mayhem/kat
