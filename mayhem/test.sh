#!/usr/bin/env bash
#
# indradb/mayhem/test.sh — RUN the project's own inline unit tests (the
# `test-suite` feature's shared macro test suite, run against MemoryDatastore)
# plus the KAT probe, and emit a CTRF summary. exit 0 iff nothing failed. This
# script only RUNS things; build.sh did the building.
#
# Why not the rocksdb-backed test-suite instance too? `indradb-lib`'s
# rocksdb-datastore feature is entirely unused elsewhere in this port (the fuzz
# targets and the KAT probe are deliberately file-I/O-free, per the porting
# brief), so building the `rocksdb` crate here would add a heavy C++
# dependency purely to test a backend nothing else in this integration
# exercises. `cargo test -p indradb-lib --lib --features test-suite` runs the
# SAME shared assertion suite (`lib/src/tests/*` — hand-written, real
# assertions on vertex/edge/property/query/index/bulk-insert behavior, not
# fixture-driven) against the in-memory backend instead.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `cargo test -p indradb-lib --lib --features test-suite`: real
#     hand-written assertions across vertex/edge/property/query/bulk-insert/
#     indexing behavior (lib/src/tests/*.rs), run against MemoryDatastore.
#
#  2) The KAT probe /mayhem/kat — Rust test binaries ARE dynamically linked on
#     Linux by default, so verify-repo's LD_PRELOAD sabotage shim (a
#     constructor that _exit(0)s every non-system executable) can already
#     neuter part (1) in principle. /mayhem/kat is the explicit, always-run
#     belt-and-suspenders check: it prints exact `KEY=VALUE` lines for a fixed
#     sequence of vertex/edge/property/bulk-insert/Identifier operations;
#     test.sh grep -x's each one verbatim. A neutered /mayhem/kat prints
#     nothing and every kat_expect below fails.
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
  emit_ctrf "cargo-lib+kat" 0 1 0; exit 2
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

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "create vertex v1"                    'KAT_CREATE_V1=true'
kat_expect "create vertex v2"                     'KAT_CREATE_V2=true'
kat_expect "duplicate vertex id rejected"         'KAT_CREATE_V1_DUP=false'
kat_expect "create edge v1->v2"                   'KAT_CREATE_EDGE=true'
kat_expect "SpecificVertexQuery returns both"     'KAT_QUERY_VERTEX_COUNT=2'
kat_expect "SpecificEdgeQuery returns the edge"   'KAT_QUERY_EDGE_COUNT=1'
kat_expect "vertex property round-trip"           'KAT_VERTEX_PROPERTY_AGE=30'
kat_expect "bulk insert succeeds"                 'KAT_BULK_INSERT_OK=true'
kat_expect "vertex count after bulk insert"       'KAT_TOTAL_VERTEX_COUNT=3'
kat_expect "256-char identifier rejected"         'KAT_IDENTIFIER_TOO_LONG_REJECTED=true'
kat_expect "invalid-character identifier rejected" 'KAT_IDENTIFIER_INVALID_CHAR_REJECTED=true'
kat_expect "valid identifier accepted"            'KAT_IDENTIFIER_VALID_ACCEPTED=true'

emit_ctrf "cargo-lib+kat" "$PASSED" "$FAILED" "$SKIPPED"
