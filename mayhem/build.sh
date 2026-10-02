#!/usr/bin/env bash
#
# indradb/mayhem/build.sh — build the single cargo-fuzz target used by this
# BACKPORT branch (BACKPORT.md): compare-buggy-mhh-run-23.
#
# Target produced:
#   /mayhem/compare — upstream's OWN differential MemoryDatastore-vs-
#                      RocksdbDatastore comparison fuzzer
#                      (lib/fuzz/fuzz_targets/compare.rs at UPSTREAM, copied
#                      verbatim into mayhem/fuzz/fuzz_targets/compare.rs), the
#                      harness that found the mayhemheroes/indradb compare/23
#                      CWE-617 reachable-assertion bug. The live `mayhem`
#                      branch deliberately drops this target (file-I/O-free
#                      porting brief); this backport exists specifically to
#                      reproduce the bug it found, so it is reconstructed here
#                      with its RocksdbDatastore side (and the
#                      rocksdb-datastore feature) intact.
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
# zerocopy >= 0.8.5x (pulled in transitively by ahash's `--cfg fuzzing` path,
# active below) hits an E0658 stdarch_x86_avx512 unstable-feature error on
# nightly-2025-06-01 (docs/netnew-worker-prompt.md, the zerocopy/AVX-512
# nightly trap) — pin it down in the lockfile.
if [ ! -f "$SRC/$FUZZ_DIR/Cargo.lock" ]; then
  ( cd "$SRC/$FUZZ_DIR" && cargo "+$RUST_NIGHTLY" generate-lockfile && cargo "+$RUST_NIGHTLY" update -p zerocopy --precise 0.8.26 )
fi

# RUST_DEBUG_FLAGS is the Rust half of the DWARF-debug-info contract (§6.2 item
# 10; the DWARF3 anchor above is what actually pins the version verify-repo
# reads, but this flag still carries real debug info into the Rust-compiled CUs).
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=1}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS -Cforce-frame-pointers -C linker=$SRC/mayhem/mayhem-build/dwarf3-cc-wrapper.sh"

# librocksdb-sys@0.8.3 bundles rocksdb 7.4.4's C++ sources (2022-era), which lean
# on <cstdint>/<cinttypes> reaching them transitively through older libstdc++
# header chains; the clang++ in this base image doesn't pull them in that way,
# so uint8_t/uint32_t/uint64_t come back "unknown type name". Force them in.
export CXXFLAGS="${CXXFLAGS:-} -include cstdint -include cinttypes"

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

# `cargo test` compiles on demand, so there is no separate test-suite precompile
# step here; mayhem/test.sh runs it directly with the SAME +$RUST_STABLE
# toolchain (indradb-lib's own `test-suite` feature tests — real dynamically
# linked binaries, reachable by the sabotage shim same as any other Rust
# binary, so no separate KAT probe is needed here).

echo "build.sh complete:"
ls -la /mayhem/compare
