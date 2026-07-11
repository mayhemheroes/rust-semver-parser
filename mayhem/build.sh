#!/usr/bin/env bash
#
# rust-semver-parser/mayhem/build.sh — build steveklabnik/semver-parser's cargo-fuzz target as a
# sanitized libFuzzer binary, replicating OSS-Fuzz's Rust path (infra/base-images/base-builder/compile
# + projects/rust-semver-parser/build.sh, which runs `cargo fuzz build` then copies the `parse` binary).
#
# semver-parser is a pure-Rust crate that parses the semver spec (versions + version-range sets).
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem runs
#     it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Target (fuzz/fuzz_targets/parse.rs — bin name `parse` from fuzz/Cargo.toml):
#   parse — the OSS-Fuzz target. Feeds the raw bytes (as UTF-8) through proc_macro2 token parsing,
#           the semver Lexer, the Parser (version), and the Compat debug surface.
#
# The fuzz binary path is resolved from `cargo metadata` (target_directory) rather than hard-coded,
# so it stays correct regardless of workspace layout.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# The cargo-fuzz crate lives in fuzz/ (cargo-fuzz convention). One fuzz target / bin: `parse`.
FUZZ_TARGET=parse
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build profile (catches
# overflow/debug asserts during fuzzing). Use the image's DEFAULT toolchain (the Dockerfile pins it
# to the required nightly); a `+toolchain` override would make rustup try to install a different
# channel into the read-only shared /opt/rust. cargo-fuzz 0.12 has no --jobs flag; parallelism is
# controlled via CARGO_BUILD_JOBS in the environment (above).
echo "--- building fuzz target: $FUZZ_TARGET ---"
cargo fuzz build -O --debug-assertions "$FUZZ_TARGET"

# Resolve the cargo-fuzz target_directory via `cargo metadata` (the fuzz crate is in fuzz/).
FUZZ_TARGET_DIR="$(cd fuzz && cargo metadata --format-version 1 --no-deps \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])')"

bin="$FUZZ_TARGET_DIR/$TRIPLE/release/$FUZZ_TARGET"
if [ ! -x "$bin" ]; then
  # Fallback to the conventional fuzz/target path if metadata resolution missed it.
  alt="$SRC/fuzz/target/$TRIPLE/release/$FUZZ_TARGET"
  if [ -x "$alt" ]; then bin="$alt"; else
    echo "ERROR: expected fuzz binary not found at $bin (nor $alt)" >&2
    exit 1
  fi
fi
cp "$bin" "/mayhem/$FUZZ_TARGET"
echo "built /mayhem/$FUZZ_TARGET"

echo "build.sh complete:"
ls -la "/mayhem/$FUZZ_TARGET" 2>&1 || true
