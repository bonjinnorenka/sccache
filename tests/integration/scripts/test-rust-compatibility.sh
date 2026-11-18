#!/usr/bin/env bash
set -euo pipefail

# Rust/Cargo compatibility regression suite reusing a pre-built sccache binary.
# Tests Cold, L0 Warm, Cross-root + dep-info, env!/option_env! unset vs empty,
# and compiler-version cache key isolation against TARGET_TOOLCHAIN (+ optional ALT_TOOLCHAIN).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE_SRC="$REPO_ROOT/tests/fixtures/tokio-small"
VERIFY_PY="$SCRIPT_DIR/verify_stats.py"

SCCACHE_BIN="${SCCACHE_BIN:-$REPO_ROOT/target/debug/sccache}"
TARGET_TOOLCHAIN="${TARGET_TOOLCHAIN:-}"
ALT_TOOLCHAIN="${ALT_TOOLCHAIN:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --toolchain)
            TARGET_TOOLCHAIN="${2:-}"
            shift 2
            ;;
        --alt-toolchain)
            ALT_TOOLCHAIN="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ ! -x "$SCCACHE_BIN" ]; then
    echo "ERROR: pre-built SCCACHE_BIN not executable: $SCCACHE_BIN" >&2
    exit 1
fi

TC_LABEL="${TARGET_TOOLCHAIN:-active}"
REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/target/regression-reports/compat/$TC_LABEL}"
mkdir -p "$REPORT_DIR"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sccache-compat-${TC_LABEL}-XXXXXX")"
mkdir -p "$WORK_ROOT/logs"

cleanup() {
    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    for lf in "$WORK_ROOT"/logs/*.log; do
        [ -f "$lf" ] || continue
        local base
        base="$(basename "$lf")"
        python3 "$VERIFY_PY" sanitize-log "$lf" "$REPORT_DIR/$base" || true
    done
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

run_with_toolchain() {
    local tc="$1"
    shift
    if [ -n "$tc" ]; then
        RUSTUP_TOOLCHAIN="$tc" "$@"
    else
        "$@"
    fi
}

RUSTC_VER="$(run_with_toolchain "$TARGET_TOOLCHAIN" rustc --version)"
CARGO_VER="$(run_with_toolchain "$TARGET_TOOLCHAIN" cargo --version)"
echo "Testing pre-built $SCCACHE_BIN against $RUSTC_VER / $CARGO_VER"

export CARGO_INCREMENTAL=0
export SCCACHE_IDLE_TIMEOUT=0

start_disk_server() {
    local phase="$1"
    local l0_dir="$2"

    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    export SCCACHE_SERVER_UDS="$WORK_ROOT/${phase}.sock"
    export SCCACHE_DIR="$l0_dir"
    unset SCCACHE_MULTILEVEL_CHAIN SCCACHE_GHA_ENABLED SCCACHE_GHA_VERSION || true
    export SCCACHE_ERROR_LOG="$WORK_ROOT/logs/${phase}.log"
    mkdir -p "$l0_dir"
    SCCACHE_LOG="sccache=debug" "$SCCACHE_BIN" --start-server >/dev/null
}

SLOT_A="$WORK_ROOT/slot-a"
SLOT_B="$WORK_ROOT/slot-b"
mkdir -p "$SLOT_A" "$SLOT_B"
cp -a "$FIXTURE_SRC" "$SLOT_A/project"
cp -a "$FIXTURE_SRC" "$SLOT_B/project"

t_f0="$(python3 -c 'import time; print(time.monotonic())')"
(cd "$SLOT_A/project" && run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER cargo fetch --locked)
t_f1="$(python3 -c 'import time; print(time.monotonic())')"
FETCH_SEC="$(python3 -c "print(round($t_f1 - $t_f0, 3))")"

L0_MAIN="$WORK_ROOT/l0-main"
LEG_FILES=()

run_compat_build() {
    local leg="$1"
    local tc="$2"
    local slot="$3"
    local proj_dir="$4"
    local target="$5"
    local fetch_sec="$6"
    shift 6

    rm -rf "$target"
    "$SCCACHE_BIN" --zero-stats >/dev/null
    local t0 t1 elapsed
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    (
        cd "$proj_dir"
        if [ -n "$slot" ]; then
            export SCCACHE_BASEDIRS="$slot"
            export RUSTFLAGS="--remap-path-prefix=$slot=/topsrc"
        else
            unset SCCACHE_BASEDIRS || true
            unset RUSTFLAGS || true
        fi
        RUSTC_WRAPPER="$SCCACHE_BIN" \
        CARGO_TARGET_DIR="$target" \
        run_with_toolchain "$tc" cargo build --locked --offline
    )
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    elapsed="$(python3 -c "print($t1 - $t0)")"

    "$SCCACHE_BIN" --show-stats --stats-format json > "$WORK_ROOT/${leg}.stats.json"
    python3 "$VERIFY_PY" verify \
        --stats-file "$WORK_ROOT/${leg}.stats.json" \
        --leg-name "$leg" \
        --elapsed-sec "$elapsed" \
        --fetch-sec "$fetch_sec" \
        --output-json "$REPORT_DIR/leg_${leg}.json" \
        "$@"
}

verify_slot() {
    local slot="$1"
    local forbidden="$2"
    local target="$3"
    local out
    out="$(
        cd "$slot/project" && \
        RUSTFLAGS="--remap-path-prefix=$slot=/topsrc" \
        run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$target" \
        cargo run --locked --offline -q -p small-app
    )"
    local expected_manifest actual_manifest
    expected_manifest="$(cd "$slot/project/small-manifest" && pwd -P)"
    actual_manifest="${out#*|}"
    [ "$actual_manifest" = "$expected_manifest" ] || {
        echo "FALSE HIT DETECTED: expected manifest $expected_manifest, got $actual_manifest" >&2
        exit 1
    }
    (
        cd "$slot/project" && \
        RUSTFLAGS="--remap-path-prefix=$slot=/topsrc" \
        run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$target" \
        cargo test --locked --offline -p small-manifest
    )
    if [ -n "$forbidden" ]; then
        python3 - "$forbidden" "$slot" "$target/debug" <<'PY'
import pathlib, sys
forbidden, expected, debug_dir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
d_files = sorted(debug_dir.rglob("*.d"))
assert d_files, f"no .d files found under {debug_dir}"
for p in d_files:
    raw = p.read_bytes()
    assert b"\x01" not in raw and b"\x02" not in raw, f"raw depinfo marker left in {p}"
    txt = raw.decode("utf-8", errors="strict")
    assert forbidden not in txt, f"foreign root {forbidden} leaked into {p}"
safe_d = [p for p in d_files if "small_core" in p.name or "small-core" in p.name]
assert safe_d, f"no small_core .d files found under {debug_dir}"
for p in safe_d:
    assert expected in p.read_text(encoding="utf-8"), f"expected root {expected} missing in {p}"
print(f"COMPAT_DEPINFO_OK files={len(safe_d)} total={len(d_files)}")
PY
    fi
}

# 1. Cold build on TARGET_TOOLCHAIN
start_disk_server "compat_main" "$L0_MAIN"
run_compat_build "compat_${TC_LABEL}_cold" "$TARGET_TOOLCHAIN" "$SLOT_A" "$SLOT_A/project" "$SLOT_A/project/target" "$FETCH_SEC" \
    --min-compile-requests 40 \
    --exact-rust-hits 0 \
    --min-rust-misses 20 \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_cold.json")
C_COUNT="$(python3 -c "import json; print(json.load(open('$REPORT_DIR/leg_compat_${TC_LABEL}_cold.json'))['rust_misses'])")"
verify_slot "$SLOT_A" "" "$SLOT_A/project/target"

# 2. L0 Warm build on TARGET_TOOLCHAIN
run_compat_build "compat_${TC_LABEL}_l0_warm" "$TARGET_TOOLCHAIN" "$SLOT_A" "$SLOT_A/project" "$SLOT_A/project/target" "0" \
    --min-compile-requests 40 \
    --exact-rust-hits "$C_COUNT" \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_l0_warm.json")

# 3. Cross-root build on TARGET_TOOLCHAIN
run_compat_build "compat_${TC_LABEL}_cross_root" "$TARGET_TOOLCHAIN" "$SLOT_B" "$SLOT_B/project" "$SLOT_B/project/target" "0" \
    --min-compile-requests 40 \
    --min-rust-hits 18 \
    --min-rust-misses 1 \
    --max-rust-misses 10 \
    --exact-rust-total "$C_COUNT" \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_cross_root.json")
verify_slot "$SLOT_B" "$SLOT_A" "$SLOT_B/project/target"

# 4. env! / option_env! unset vs empty distinction on TARGET_TOOLCHAIN
ENV_SLOT="$WORK_ROOT/env-slot"
mkdir -p "$ENV_SLOT/proj/env_lib/src" "$ENV_SLOT/proj/env_app/src"
cat > "$ENV_SLOT/proj/Cargo.toml" <<'TOML'
[workspace]
members = ["env_lib", "env_app"]
resolver = "2"
TOML
cat > "$ENV_SLOT/proj/env_lib/Cargo.toml" <<'TOML'
[package]
name = "env_lib"
version = "0.1.0"
edition = "2021"
TOML
cat > "$ENV_SLOT/proj/env_lib/src/lib.rs" <<'RS'
pub fn report() -> String {
    let opt = match option_env!("COMPAT_OPT") {
        None => "UNSET".to_string(),
        Some("") => "EMPTY".to_string(),
        Some(v) => format!("SET:{v}"),
    };
    format!("{}|{}", opt, env!("COMPAT_REQ"))
}
RS
cat > "$ENV_SLOT/proj/env_app/Cargo.toml" <<'TOML'
[package]
name = "env_app"
version = "0.1.0"
edition = "2021"
[dependencies]
env_lib = { path = "../env_lib" }
TOML
cat > "$ENV_SLOT/proj/env_app/src/main.rs" <<'RS'
fn main() {
    println!("{}", env_lib::report());
}
RS

run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER cargo generate-lockfile --offline --manifest-path "$ENV_SLOT/proj/Cargo.toml"

L0_ENV="$WORK_ROOT/l0-env"
start_disk_server "compat_env" "$L0_ENV"

export COMPAT_REQ="req1"
unset COMPAT_OPT || true
run_compat_build "compat_${TC_LABEL}_env_unset" "$TARGET_TOOLCHAIN" "$ENV_SLOT" "$ENV_SLOT/proj" "$ENV_SLOT/proj/target" "0" \
    --min-compile-requests 2 \
    --exact-rust-hits 0 \
    --exact-rust-misses 1 \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_env_unset.json")
out_u="$(cd "$ENV_SLOT/proj" && run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$ENV_SLOT/proj/target" cargo run --locked --offline -q -p env_app)"
[ "$out_u" = "UNSET|req1" ] || { echo "Expected UNSET|req1, got $out_u" >&2; exit 1; }

export COMPAT_REQ="req1"
export COMPAT_OPT=""
run_compat_build "compat_${TC_LABEL}_env_empty" "$TARGET_TOOLCHAIN" "$ENV_SLOT" "$ENV_SLOT/proj" "$ENV_SLOT/proj/target" "0" \
    --min-compile-requests 2 \
    --exact-rust-hits 0 \
    --exact-rust-misses 1 \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_env_empty.json")
out_e="$(cd "$ENV_SLOT/proj" && run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$ENV_SLOT/proj/target" cargo run --locked --offline -q -p env_app)"
[ "$out_e" = "EMPTY|req1" ] || { echo "Expected EMPTY|req1, got $out_e" >&2; exit 1; }

export COMPAT_REQ="req1"
unset COMPAT_OPT || true
run_compat_build "compat_${TC_LABEL}_env_unset_hit" "$TARGET_TOOLCHAIN" "$ENV_SLOT" "$ENV_SLOT/proj" "$ENV_SLOT/proj/target" "0" \
    --min-compile-requests 2 \
    --exact-rust-hits 1 \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_env_unset_hit.json")
out_uh="$(cd "$ENV_SLOT/proj" && run_with_toolchain "$TARGET_TOOLCHAIN" env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$ENV_SLOT/proj/target" cargo run --locked --offline -q -p env_app)"
[ "$out_uh" = "UNSET|req1" ] || { echo "Expected cached UNSET|req1, got $out_uh" >&2; exit 1; }

# 5. Compiler-version cache key isolation if an alternate toolchain is available
if [ -n "$ALT_TOOLCHAIN" ]; then
    ALT_VER="$(run_with_toolchain "$ALT_TOOLCHAIN" rustc --version 2>/dev/null || true)"
    if [ -n "$ALT_VER" ] && [ "$ALT_VER" != "$RUSTC_VER" ]; then
        echo "Verifying compiler-version isolation: $RUSTC_VER vs $ALT_VER"
        export COMPAT_REQ="req1"
        unset COMPAT_OPT || true
        run_compat_build "compat_${TC_LABEL}_iso_alt" "$ALT_TOOLCHAIN" "$ENV_SLOT" "$ENV_SLOT/proj" "$ENV_SLOT/proj/target" "0" \
            --min-compile-requests 2 \
            --exact-rust-hits 0 \
            --exact-rust-misses 1 \
            --exact-read-errors 0 \
            --exact-write-errors 0
        LEG_FILES+=("$REPORT_DIR/leg_compat_${TC_LABEL}_iso_alt.json")
    else
        echo "Skipping compiler isolation check (alt toolchain '$ALT_TOOLCHAIN' unavailable or matches '$RUSTC_VER')"
    fi
fi

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCCACHE_VER="$("$SCCACHE_BIN" --version)"

python3 "$VERIFY_PY" report \
    --title "sccache Rust Compatibility ($TC_LABEL)" \
    --commit-sha "$COMMIT_SHA" \
    --sccache-version "$SCCACHE_VER" \
    --rustc-version "$RUSTC_VER" \
    --cargo-version "$CARGO_VER" \
    --backend "disk (prebuilt sccache)" \
    --fixture "tokio-small + env_probe" \
    --leg-files "${LEG_FILES[@]}" \
    --report-json "$REPORT_DIR/compat-report.json" \
    ${GITHUB_STEP_SUMMARY:+--summary-md "$GITHUB_STEP_SUMMARY"}
