#!/usr/bin/env bash
set -euo pipefail

# Cross-job GitHub Actions Cache (GHAC) L0+L1 multilevel regression script.
# Usage:
#   test-ghac-regression.sh --role seed --meta-file <path>
#   test-ghac-regression.sh --role verify --meta-file <path>
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE_SRC="$REPO_ROOT/tests/fixtures/tokio-small"
VERIFY_PY="$SCRIPT_DIR/verify_stats.py"

ROLE=""
META_FILE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --role)
            ROLE="${2:-}"
            shift 2
            ;;
        --meta-file)
            META_FILE="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$ROLE" != "seed" ] && [ "$ROLE" != "verify" ]; then
    echo "ERROR: --role must be 'seed' or 'verify'" >&2
    exit 2
fi
if [ -z "$META_FILE" ]; then
    echo "ERROR: --meta-file is required" >&2
    exit 2
fi

SCCACHE_BIN="${SCCACHE_BIN:-$REPO_ROOT/target/debug/sccache}"
REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/target/regression-reports/ghac}"
mkdir -p "$REPORT_DIR" "$(dirname "$META_FILE")"

# Verify required GHAC credentials without printing their values.
if [ -z "${ACTIONS_RUNTIME_TOKEN:-}" ]; then
    echo "ERROR: ACTIONS_RUNTIME_TOKEN is unset or empty; GHAC backend cannot run." >&2
    exit 1
fi
if [ -z "${ACTIONS_RESULTS_URL:-}" ] && [ -z "${ACTIONS_CACHE_URL:-}" ]; then
    echo "ERROR: neither ACTIONS_RESULTS_URL nor ACTIONS_CACHE_URL is set." >&2
    exit 1
fi
if [ -z "${SCCACHE_GHA_VERSION:-}" ]; then
    echo "ERROR: SCCACHE_GHA_VERSION must be explicitly set for isolated GHAC regression runs." >&2
    exit 1
fi
export SCCACHE_GHA_ENABLED="${SCCACHE_GHA_ENABLED:-on}"
export CARGO_INCREMENTAL=0
export SCCACHE_IDLE_TIMEOUT=0

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sccache-ghac-${ROLE}-XXXXXX")"
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

start_ghac_server() {
    local phase="$1"
    local l0_dir="$2"

    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    export SCCACHE_SERVER_UDS="$WORK_ROOT/${phase}.sock"
    export SCCACHE_DIR="$l0_dir"
    export SCCACHE_MULTILEVEL_CHAIN="disk,gha"
    export SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY="all"
    export SCCACHE_ERROR_LOG="$WORK_ROOT/logs/${phase}.log"
    mkdir -p "$l0_dir"
    SCCACHE_LOG="sccache=debug" "$SCCACHE_BIN" --start-server >/dev/null
}

wait_for_stat_condition() {
    local py_cond="$1"
    local timeout_sec="${2:-60}"
    python3 - "$SCCACHE_BIN" "$py_cond" "$timeout_sec" <<'PY'
import json, subprocess, sys, time
bin_path, cond, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
deadline = time.monotonic() + timeout_s
while True:
    raw = subprocess.check_output([bin_path, "--show-stats", "--stats-format", "json"], text=True)
    doc = json.loads(raw)
    stats = doc["stats"]
    ml = stats.get("multi_level") or []
    if eval(cond, {"stats": stats, "ml": ml}):
        break
    if time.monotonic() >= deadline:
        raise SystemExit(f"Timed out waiting for stat condition `{cond}`: {raw}")
    time.sleep(0.1)
PY
}

verify_slot_runtime_and_depinfo() {
    local expected_slot="$1"
    local forbidden_slot="$2"
    local target="$3"

    local out
    out="$(
        cd "$expected_slot/project" && \
        env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$target" \
        cargo run --locked --offline -q -p small-app
    )"
    echo "Runtime output ($expected_slot): $out"
    local expected_manifest actual_manifest payload
    expected_manifest="$(cd "$expected_slot/project/small-manifest" && pwd -P)"
    payload="${out%%|*}"
    actual_manifest="${out#*|}"
    echo "$payload" | grep -q "tokio-small" || {
        echo "ERROR: unexpected runtime payload '$payload'" >&2
        exit 1
    }
    [ "$actual_manifest" = "$expected_manifest" ] || {
        echo "FALSE HIT DETECTED: expected manifest $expected_manifest, got $actual_manifest" >&2
        exit 1
    }

    (
        cd "$expected_slot/project" && \
        env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$target" \
        cargo test --locked --offline -p small-manifest
    )

    if [ -n "$forbidden_slot" ]; then
        python3 - "$forbidden_slot" "$expected_slot" "$target/debug" <<'PY'
import pathlib, sys
forbidden, expected, debug_dir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
d_files = sorted(debug_dir.rglob("*.d"))
assert d_files, f"no .d files found under {debug_dir}"
for p in d_files:
    raw = p.read_bytes()
    assert b"\x01" not in raw and b"\x02" not in raw, f"raw depinfo marker left in {p}"
    txt = raw.decode("utf-8", errors="strict")
    assert forbidden not in txt, f"foreign root {forbidden} leaked into {p}:\n{txt}"
safe_d = [p for p in d_files if "small_core" in p.name or "small-core" in p.name]
assert safe_d, f"no small_core .d files found under {debug_dir}"
for p in safe_d:
    txt = p.read_text(encoding="utf-8", errors="strict")
    assert expected in txt, f"expected root {expected} missing in {p}:\n{txt}"
print(f"DEPINFO_CHECK_OK small_core_files={len(safe_d)} total_d={len(d_files)}")
PY
    fi
}

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCCACHE_VER="$("$SCCACHE_BIN" --version)"
RUSTC_VER="$(rustc --version)"
CARGO_VER="$(cargo --version)"

if [ "$ROLE" = "seed" ]; then
    SLOT_A="$WORK_ROOT/slot-a"
    L0_SEED="$WORK_ROOT/l0-seed"
    mkdir -p "$SLOT_A"
    cp -a "$FIXTURE_SRC" "$SLOT_A/project"

    t_f0="$(python3 -c 'import time; print(time.monotonic())')"
    (cd "$SLOT_A/project" && env -u RUSTC_WRAPPER cargo fetch --locked)
    t_f1="$(python3 -c 'import time; print(time.monotonic())')"
    FETCH_SEC="$(python3 -c "print(round($t_f1 - $t_f0, 3))")"

    start_ghac_server "ghac_seed" "$L0_SEED"
    rm -rf "$SLOT_A/project/target"
    "$SCCACHE_BIN" --zero-stats >/dev/null
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    (
        cd "$SLOT_A/project" && \
        RUSTC_WRAPPER="$SCCACHE_BIN" \
        SCCACHE_BASEDIRS="$SLOT_A" \
        RUSTFLAGS="--remap-path-prefix=$SLOT_A=/topsrc" \
        CARGO_TARGET_DIR="$SLOT_A/project/target" \
        cargo build --locked --offline
    )
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    elapsed="$(python3 -c "print($t1 - $t0)")"

    "$SCCACHE_BIN" --show-stats --stats-format json > "$WORK_ROOT/ghac_seed.stats.json"
    python3 "$VERIFY_PY" verify \
        --stats-file "$WORK_ROOT/ghac_seed.stats.json" \
        --leg-name "ghac_seed" \
        --elapsed-sec "$elapsed" \
        --fetch-sec "$FETCH_SEC" \
        --expect-multilevel \
        --min-compile-requests 40 \
        --exact-rust-hits 0 \
        --min-rust-misses 20 \
        --exact-read-errors 0 \
        --exact-write-errors 0 \
        --output-json "$REPORT_DIR/leg_ghac_seed.json"

    C_COUNT="$(python3 -c "import json; print(json.load(open('$REPORT_DIR/leg_ghac_seed.json'))['rust_misses'])")"
    python3 "$VERIFY_PY" verify \
        --stats-file "$WORK_ROOT/ghac_seed.stats.json" \
        --leg-name "ghac_seed" \
        --elapsed-sec "$elapsed" \
        --fetch-sec "$FETCH_SEC" \
        --expect-multilevel \
        --level-check "0:disk:writes==${C_COUNT}" \
        --level-check "1:gha:writes==${C_COUNT}" \
        --output-json "$REPORT_DIR/leg_ghac_seed.json" >/dev/null

    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true

    python3 - "$META_FILE" "$C_COUNT" "$SCCACHE_GHA_VERSION" "$SLOT_A" "$FETCH_SEC" "$RUSTC_VER" "$CARGO_VER" <<'PY'
import json, sys
meta_path, expected_c, gha_ver, slot_a, fetch_sec, rustc_ver, cargo_ver = sys.argv[1:8]
with open(meta_path, "w", encoding="utf-8") as fh:
    json.dump({
        "expected_cacheable": int(expected_c),
        "gha_version": gha_ver,
        "rustc_version": rustc_ver,
        "cargo_version": cargo_ver,
        "slot_a_root": slot_a,
        "fetch_sec": float(fetch_sec),
    }, fh, indent=2)
PY

    python3 "$VERIFY_PY" report \
        --title "sccache GHAC Seed (Job A)" \
        --commit-sha "$COMMIT_SHA" \
        --sccache-version "$SCCACHE_VER" \
        --rustc-version "$RUSTC_VER" \
        --cargo-version "$CARGO_VER" \
        --backend "disk,gha (seed)" \
        --fixture "tokio-small" \
        --leg-files "$REPORT_DIR/leg_ghac_seed.json" \
        --report-json "$REPORT_DIR/ghac-seed-report.json" \
        ${GITHUB_STEP_SUMMARY:+--summary-md "$GITHUB_STEP_SUMMARY"}
    exit 0
fi

# ROLE = verify (Job B: separate job, different build root, fresh L0)
EXPECTED_C="$(python3 -c "import json; print(json.load(open('$META_FILE'))['expected_cacheable'])")"
SEED_GHA_VER="$(python3 -c "import json; print(json.load(open('$META_FILE'))['gha_version'])")"
FORBIDDEN_SLOT_A="$(python3 -c "import json; print(json.load(open('$META_FILE'))['slot_a_root'])")"

if [ "$SCCACHE_GHA_VERSION" != "$SEED_GHA_VER" ]; then
    echo "ERROR: SCCACHE_GHA_VERSION mismatch (verify=$SCCACHE_GHA_VERSION seed=$SEED_GHA_VER)" >&2
    exit 1
fi

# Fail before any compilation if the seed and verify runners selected different Rust toolchains.
python3 - "$META_FILE" "$RUSTC_VER" "$CARGO_VER" <<'PY'
import json, sys
meta_path, current_rustc, current_cargo = sys.argv[1:]
with open(meta_path, encoding="utf-8") as fh:
    meta = json.load(fh)
for key, current in (("rustc_version", current_rustc), ("cargo_version", current_cargo)):
    seeded = meta.get(key)
    if seeded != current:
        raise SystemExit(
            f"ERROR: GHAC toolchain mismatch ({key}): seed={seeded!r}, verify={current!r}; "
            "cross-job cache verification requires identical Rust and Cargo versions."
        )
PY

SLOT_B="$WORK_ROOT/cross-verify/slot-b"
L0_B="$WORK_ROOT/l0-verify"
mkdir -p "$SLOT_B"
cp -a "$FIXTURE_SRC" "$SLOT_B/project"

t_f0="$(python3 -c 'import time; print(time.monotonic())')"
(cd "$SLOT_B/project" && env -u RUSTC_WRAPPER cargo fetch --locked)
t_f1="$(python3 -c 'import time; print(time.monotonic())')"
FETCH_SEC="$(python3 -c "print(round($t_f1 - $t_f0, 3))")"

# Leg 1: Fresh L0 + fresh target in slot-b -> must hit GHAC L1 cross-job & cross-root, and backfill L0.
start_ghac_server "ghac_cross_job" "$L0_B"
rm -rf "$SLOT_B/project/target"
"$SCCACHE_BIN" --zero-stats >/dev/null
t0="$(python3 -c 'import time; print(time.monotonic())')"
(
    cd "$SLOT_B/project" && \
    RUSTC_WRAPPER="$SCCACHE_BIN" \
    SCCACHE_BASEDIRS="$SLOT_B" \
    RUSTFLAGS="--remap-path-prefix=$SLOT_B=/topsrc" \
    CARGO_TARGET_DIR="$SLOT_B/project/target" \
    cargo build --locked --offline
)
t1="$(python3 -c 'import time; print(time.monotonic())')"
elapsed_l1="$(python3 -c "print($t1 - $t0)")"

wait_for_stat_condition "len(ml)>=2 and ml[0]['backfills_to']>=ml[1]['backfills_from']" 60
"$SCCACHE_BIN" --show-stats --stats-format json > "$WORK_ROOT/ghac_cross_job.stats.json"
python3 "$VERIFY_PY" verify \
    --stats-file "$WORK_ROOT/ghac_cross_job.stats.json" \
    --leg-name "ghac_cross_job_cross_root" \
    --elapsed-sec "$elapsed_l1" \
    --fetch-sec "$FETCH_SEC" \
    --expect-multilevel \
    --min-compile-requests 40 \
    --min-rust-hits 20 \
    --min-rust-misses 1 \
    --max-rust-misses 6 \
    --exact-rust-total "$EXPECTED_C" \
    --exact-read-errors 0 \
    --exact-write-errors 0 \
    --level-check "0:disk:hits==0" \
    --level-check "1:gha:hits>=20" \
    --level-check "0:disk:backfills_to>=20" \
    --level-check "1:gha:backfills_from>=20" \
    --output-json "$REPORT_DIR/leg_ghac_cross_job_cross_root.json"

verify_slot_runtime_and_depinfo "$SLOT_B" "$FORBIDDEN_SLOT_A" "$SLOT_B/project/target"

l0_files="$(find "$L0_B" -type f | wc -l)"
[ "$l0_files" -gt 0 ] || {
    echo "ERROR: L0 backfill directory $L0_B is empty after GHAC hit" >&2
    exit 1
}
echo "Verified L0 backfill files from GHAC: count=$l0_files"

# Leg 2: Restart server preserving L0_B, delete target, rebuild -> must hit L0 100% with 0 GHAC hits.
start_ghac_server "ghac_l0_backfill" "$L0_B"
rm -rf "$SLOT_B/project/target"
"$SCCACHE_BIN" --zero-stats >/dev/null
t0="$(python3 -c 'import time; print(time.monotonic())')"
(
    cd "$SLOT_B/project" && \
    RUSTC_WRAPPER="$SCCACHE_BIN" \
    SCCACHE_BASEDIRS="$SLOT_B" \
    RUSTFLAGS="--remap-path-prefix=$SLOT_B=/topsrc" \
    CARGO_TARGET_DIR="$SLOT_B/project/target" \
    cargo build --locked --offline
)
t1="$(python3 -c 'import time; print(time.monotonic())')"
elapsed_l0="$(python3 -c "print($t1 - $t0)")"

"$SCCACHE_BIN" --show-stats --stats-format json > "$WORK_ROOT/ghac_l0_backfill.stats.json"
python3 "$VERIFY_PY" verify \
    --stats-file "$WORK_ROOT/ghac_l0_backfill.stats.json" \
    --leg-name "ghac_l0_backfill_hit" \
    --elapsed-sec "$elapsed_l0" \
    --fetch-sec "0" \
    --expect-multilevel \
    --min-compile-requests 40 \
    --exact-rust-hits "$EXPECTED_C" \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0 \
    --level-check "0:disk:hits==${EXPECTED_C}" \
    --level-check "1:gha:hits==0" \
    --output-json "$REPORT_DIR/leg_ghac_l0_backfill_hit.json"

LEG_FILES=()
if [ -f "$REPORT_DIR/leg_ghac_seed.json" ]; then
    LEG_FILES+=("$REPORT_DIR/leg_ghac_seed.json")
fi
LEG_FILES+=(
    "$REPORT_DIR/leg_ghac_cross_job_cross_root.json"
    "$REPORT_DIR/leg_ghac_l0_backfill_hit.json"
)

python3 "$VERIFY_PY" report \
    --title "sccache GHAC Cross-Job Regression (Job B)" \
    --commit-sha "$COMMIT_SHA" \
    --sccache-version "$SCCACHE_VER" \
    --rustc-version "$RUSTC_VER" \
    --cargo-version "$CARGO_VER" \
    --backend "disk,gha" \
    --fixture "tokio-small" \
    --leg-files "${LEG_FILES[@]}" \
    --report-json "$REPORT_DIR/ghac-regression-report.json" \
    ${GITHUB_STEP_SUMMARY:+--summary-md "$GITHUB_STEP_SUMMARY"}
