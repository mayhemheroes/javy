#!/usr/bin/env bash
#
# javy/mayhem/test.sh — RUN bytecodealliance/javy's OWN host-buildable crate tests and emit a CTRF
# summary. exit 0 iff no test failed.
#
# We run the `javy` crate's LIB tests + its `misc` integration test
# (`cargo test -p javy --features json,messagepack --lib --test misc`). This is the crate the fuzz
# target embeds (the QuickJS-based JS runtime, built for the host via rquickjs+bindgen) — it is fully
# self-contained and needs NO wasm runtime / wasmtime to compile or run. The `json` feature pulls in
# the same SIMD-JSON path the differential fuzzer exercises.
#
# These are real behavioral tests: crates/javy/tests/misc.rs runs actual JS through the runtime and
# asserts outputs (JSON round-trips, ref-counting, the stringify-cycle case), and crates/javy/src/*
# carry inline #[test]s. A no-op / output-altering patch to the runtime CANNOT pass. This script
# only RUNS the suite via `cargo test`; it never builds fuzz targets.
#
# We deliberately EXCLUDE the `262` integration test (crates/javy/tests/262.rs): it expands a
# proc-macro that reads the tc39/test262 git SUBMODULE (crates/javy/test262) at compile time, which
# is not vendored into the commit image, so it cannot even compile here. (Selecting --lib --test misc
# scopes cargo to only the targets we want and skips 262.rs entirely.)
#
# We deliberately do NOT run `cargo test --workspace`: the cli/codegen/plugin/runner crates depend
# on wasmtime + a built wasm plugin and exercise the wasm32 toolchain, which is out of scope for a
# fast, self-contained build-time oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-/mayhem}"
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test -p javy --features json,messagepack --lib --test misc ==="
# Use the image's DEFAULT toolchain (Dockerfile pins it to the same nightly the fuzz build uses), so
# no `+toolchain` override. --no-fail-fast so we count every test; RUSTFLAGS cleared so it inherits
# nothing from any sanitizer build.
out="$(RUSTFLAGS="" cargo test -p javy --features json,messagepack --lib --test misc --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
