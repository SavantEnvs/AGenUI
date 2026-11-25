#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

YOGA_DIR=/opt/toolchains/deps/yoga-2.0.0/src
# Upstream builds with libc++; with libstdc++ a few core sources miss transitive includes
# (<cstdarg> in agenui_logger_internal.cpp, <mutex>/<atomic> in stream/agenui_streaming_content_parser.*).
# Force-include them instead of editing upstream files.
COMPAT_FLAGS="-include cstdarg -include mutex -include atomic"
# Upstream's only host build is tests/cpp/CMakeLists.txt: it builds the core as the static
# library agenui_core_for_test (+ yogacore) and the gtest suite. Use it for both builds, with its
# own sanitizer switch off (we pass our flags) and yoga from the pinned in-image copy.
# CMAKE_BUILD_TYPE=None: no CMake-added -g (DWARF 5) / -O flags.
CMAKE_COMMON=(-S tests/cpp -G Ninja -DCMAKE_BUILD_TYPE=None
  -DAGENUI_TESTS_ENABLE_ASAN=OFF -DAGENUI_TESTS_ENABLE_TSAN=OFF
  -DAGENUI_TESTS_LOCAL_YOGA_DIR="$YOGA_DIR")

# 1) Sanitized + coverage-instrumented core and yoga for the fuzzers.
FUZZ_CXXFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 $COMPAT_FLAGS"
cmake "${CMAKE_COMMON[@]}" -B mayhem/build-fuzz -DCMAKE_CXX_FLAGS="$FUZZ_CXXFLAGS"
cmake --build mayhem/build-fuzz -j"$MAYHEM_JOBS" --target agenui_core_for_test yogacore
CORE_LIB=mayhem/build-fuzz/libagenui_core_for_test.a
YOGA_LIB=mayhem/build-fuzz/libyogacore.a

# 2) Harnesses: a libFuzzer binary and a run-once -standalone reproducer each.
INC=(-Icore/include -Icore/src -Icore/src/third_party -Icore/src/third_party/nlohmann -I"$YOGA_DIR" -Imayhem/harnesses)
HFLAGS="-std=c++17 -fexceptions -frtti $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $COMPAT_FLAGS"
OBJ=mayhem/build-fuzz/mayhem-obj
mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
for h in stream_fuzzer surface_messages_fuzzer color_parser_fuzzer edge_insets_parser_fuzzer theme_config_fuzzer; do
  $CXX $HFLAGS "${INC[@]}" -c "mayhem/harnesses/$h.cpp" -o "$OBJ/$h.o"
  $CXX $HFLAGS $LIB_FUZZING_ENGINE "$OBJ/$h.o" "$OBJ/lsan_off.o" "$CORE_LIB" "$YOGA_LIB" -lpthread -o "/mayhem/$h"
  $CXX $HFLAGS "$OBJ/standalone_main.o" "$OBJ/$h.o" "$OBJ/lsan_off.o" "$CORE_LIB" "$YOGA_LIB" -lpthread -o "/mayhem/$h-standalone"
done

# 2b) Go agent SDK parser target (agent_sdks/go/parser) via go-fuzz-build -libfuzzer. The harness
#     module mayhem/gofuzz points at ../../agent_sdks/go with a replace directive; its go.mod/go.sum
#     are committed, and modules resolve from the in-image cache first (file proxy) so the offline
#     re-run never needs the network. Go objects carry DWARF < 4 with GOEXPERIMENT=nodwarf5 (Go 1.25
#     defaults to DWARF 5). This go-fuzz version's archive defines LLVMFuzzerInitialize itself (it
#     waits for the Go runtime to initialise), so no separate init-ordering shim is linked.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOEXPERIMENT="${GOEXPERIMENT:-nodwarf5}"
( cd mayhem/gofuzz && go-fuzz-build -libfuzzer -func Fuzz -o "$SRC/$OBJ/sdk_parser_fuzzer.a" . )
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $DEBUG_FLAGS "$OBJ/lsan_off.o" \
  "$OBJ/sdk_parser_fuzzer.a" -lpthread -o /mayhem/sdk_parser_fuzzer
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" \
  "$OBJ/sdk_parser_fuzzer.a" -lpthread -o /mayhem/sdk_parser_fuzzer-standalone
# sdk_validator_fuzzer: the same module's FuzzValidate (schema validation of LLM A2UI output
# against the bundled basic catalog, agent_sdks/go/schema).
( cd mayhem/gofuzz && go-fuzz-build -libfuzzer -func FuzzValidate -o "$SRC/$OBJ/sdk_validator_fuzzer.a" . )
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $DEBUG_FLAGS "$OBJ/lsan_off.o" \
  "$OBJ/sdk_validator_fuzzer.a" -lpthread -o /mayhem/sdk_validator_fuzzer
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" \
  "$OBJ/sdk_validator_fuzzer.a" -lpthread -o /mayhem/sdk_validator_fuzzer-standalone
for g in sdk_parser_fuzzer sdk_validator_fuzzer; do
  nm "/mayhem/$g" | grep ' T LLVMFuzzerInitialize$' >/dev/null \
    || { echo "build.sh: LLVMFuzzerInitialize (Go runtime init) missing from /mayhem/$g" >&2; exit 1; }
done

# 3) Upstream's gtest suite (agenui_unit_tests) with normal flags, for mayhem/test.sh.
cmake "${CMAKE_COMMON[@]}" -B mayhem/build-tests -DCMAKE_CXX_FLAGS="-O1 $COMPAT_FLAGS $COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build mayhem/build-tests -j"$MAYHEM_JOBS" --target agenui_unit_tests
