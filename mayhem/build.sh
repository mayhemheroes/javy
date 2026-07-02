#!/usr/bin/env bash
#
# javy/mayhem/build.sh — build bytecodealliance/javy's cargo-fuzz target as a libFuzzer binary,
# replicating OSS-Fuzz's projects/javy/build.sh.
#
# OSS-Fuzz build.sh does exactly:
#   CFLAGS="$CFLAGS -fno-sanitize=all" RUSTFLAGS="-C link-arg=-fno-sanitize=all" \
#       cargo fuzz build --sanitizer none
#   cp target/x86_64-unknown-linux-gnu/release/json-differential $OUT/json-differential
#
# project.yaml pins `sanitizers: none` ("other sanitizers seem to cause out of memory errors")
# so we build WITHOUT a sanitizer. cargo-fuzz still produces a self-contained libFuzzer binary
# (Mayhem runs it directly via `libfuzzer: true`). nightly is required for cargo-fuzz's `-Z`.
#
# Target (fuzz/fuzz_targets/json_differential.rs, bin name `json-differential`):
#   json-differential — decodes an arbitrary_json::ArbitraryValue from the libFuzzer input,
#                        renders it to a JSON string, then runs `JSON.stringify(JSON.parse(INPUT))`
#                        through javy's SIMD-JSON runtime AND a reference QuickJS-native runtime and
#                        asserts the two outputs are equal (differential oracle).
#
# The fuzz target builds for the HOST triple (x86_64-unknown-linux-gnu); it embeds the `javy` crate
# (QuickJS via rquickjs+bindgen, host build) and needs no wasm runtime to build or run.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# The build context is the full repo copied to /mayhem. Use SRC if the base set it, else /mayhem.
SRC="${SRC:-/mayhem}"
cd "$SRC"

FUZZ_TARGET="json-differential"
TRIPLE="x86_64-unknown-linux-gnu"

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (debuginfo=2 for compact, -Z dwarf-version=3 for
# the Rust user CUs). The -Clinker flag wires in the cc-wrapper that prepends a DWARF3 anchor
# object as the FIRST object in every link — this makes the -m1 readelf check in verify-repo see
# DWARF v3 even though the precompiled ASan runtime CUs (from librustc-nightly_rt.asan.a) remain
# DWARF v5 deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

# Replicate OSS-Fuzz's exact flags: build WITHOUT a sanitizer (project.yaml `sanitizers: none`),
# and disable any inherited sanitization at link time. `--cfg fuzzing` matches libfuzzer-sys.
# Thread RUST_DEBUG_FLAGS for DWARF < 4 symbols (§6.2 item 10).
export CFLAGS="${CFLAGS:-} -fno-sanitize=all"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -C link-arg=-fno-sanitize=all $RUST_DEBUG_FLAGS"

echo "=== cargo fuzz build --sanitizer none (pinned nightly) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "CFLAGS=$CFLAGS"

# cargo-fuzz reads the target list from fuzz/Cargo.toml. -O = release/optimized (OSS-Fuzz builds
# the release binary). Use the image's DEFAULT toolchain (Dockerfile pins it to the required
# nightly) — no `+toolchain` override, which would try to install another channel into read-only
# /opt/rust.
cargo fuzz build --sanitizer none -O "$FUZZ_TARGET"

# Resolve the cargo-fuzz output dir robustly via `cargo metadata` (the fuzz crate's target dir),
# falling back to the well-known cargo-fuzz path. cargo-fuzz emits into fuzz/target/<triple>/release.
FUZZ_TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path fuzz/Cargo.toml \
  2>/dev/null | grep -o '"target_directory":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
[ -n "$FUZZ_TARGET_DIR" ] || FUZZ_TARGET_DIR="$SRC/fuzz/target"

bin="$FUZZ_TARGET_DIR/$TRIPLE/release/$FUZZ_TARGET"
if [ ! -x "$bin" ]; then
  # last-resort fallback to the canonical cargo-fuzz layout
  bin="$SRC/fuzz/target/$TRIPLE/release/$FUZZ_TARGET"
fi
if [ ! -x "$bin" ]; then
  echo "ERROR: expected fuzz binary not found at $bin" >&2
  echo "searched target dir: $FUZZ_TARGET_DIR" >&2
  find "$SRC/fuzz/target" -name "$FUZZ_TARGET" -type f 2>/dev/null >&2 || true
  exit 1
fi

OUT="${OUT:-/mayhem}"
cp "$bin" "$OUT/$FUZZ_TARGET"
echo "built $OUT/$FUZZ_TARGET"
ls -la "$OUT/$FUZZ_TARGET"
