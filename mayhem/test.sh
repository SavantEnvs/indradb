#!/usr/bin/env bash
#
# indradb/mayhem/test.sh — RUN the project's own inline unit tests (the
# `test-suite` feature's shared macro test suite, run against MemoryDatastore)
# and emit a CTRF summary. exit 0 iff nothing failed. This script only RUNS
# things; build.sh did the building.
#
# `cargo test -p indradb-lib --lib --features test-suite` runs the project's
# own hand-written assertion suite (`lib/src/tests/*` — real assertions on
# vertex/edge/property/query/index/bulk-insert behavior, not fixture-driven)
# against the in-memory MemoryDatastore backend.
#
# PATCH-grade oracle (SPEC §6.3): the compiled `cargo test` binary is a normal
# dynamically-linked Rust executable (Rust binaries dynamically link libc by
# default on Linux), so verify-repo's LD_PRELOAD sabotage shim (a constructor
# that _exit(0)s every non-system executable) neuters it directly — a
# sabotaged run prints no `test result:` line at all, which the parsing below
# already treats as a FAIL, so no separate KAT probe is needed on this branch.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/rust/cargo/bin:$PATH"
: "${SRC:=/mayhem}"
: "${RUST_STABLE:=stable}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-lib" 0 1 0; exit 2
fi

# ── 1) upstream's own inline unit tests (in-memory backend, no rocksdb) ────────
OUT="$SRC/mayhem/mayhem-build/cargotest-indradb-lib.out"
mkdir -p "$SRC/mayhem/mayhem-build"
echo "=== running: cargo +$RUST_STABLE test -p indradb-lib --lib --features test-suite ==="
cargo "+$RUST_STABLE" test -p indradb-lib --lib --features test-suite --no-fail-fast --jobs "$MAYHEM_JOBS" >"$OUT" 2>&1
rc=$?
tail -20 "$OUT"

line="$(grep -m1 '^test result:' "$OUT" || true)"
if [ -z "$line" ]; then
  echo "FAIL: no 'test result:' summary from cargo test" >&2
  FAILED=$(( FAILED + 1 ))
else
  p=$(printf '%s\n' "$line" | grep -oE '[0-9]+ passed'  | grep -oE '[0-9]+' || echo 0)
  f=$(printf '%s\n' "$line" | grep -oE '[0-9]+ failed'  | grep -oE '[0-9]+' || echo 0)
  s=$(printf '%s\n' "$line" | grep -oE '[0-9]+ ignored' | grep -oE '[0-9]+' || echo 0)
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + s ))
  echo "  indradb-lib: $line"
fi
[ "$rc" -eq 0 ] || [ -n "$line" ] || { echo "cargo test exited $rc with no summary" >&2; FAILED=$(( FAILED + 1 )); }

if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "FAIL: no unit tests were counted at all — the suite did not run" >&2
  FAILED=$(( FAILED + 1 ))
fi

emit_ctrf "cargo-lib" "$PASSED" "$FAILED" "$SKIPPED"
