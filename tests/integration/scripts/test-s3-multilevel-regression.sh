#!/usr/bin/env bash
set -euo pipefail

# S01..S10 L0 (disk) + L1 (Silo S3) multilevel integration regression suite.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/tests/integration/docker-compose.yml"
FIXTURE_SRC="$REPO_ROOT/tests/fixtures/tokio-small"
VERIFY_PY="$SCRIPT_DIR/verify_stats.py"

SCCACHE_BIN="${SCCACHE_BIN:-$REPO_ROOT/target/debug/sccache}"
REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/target/regression-reports/s3}"
SKIP_SILO_SETUP="${SKIP_SILO_SETUP:-0}"
KEEP_SILO="${KEEP_SILO:-0}"
SCENARIOS="${SCENARIOS:-all}"
mkdir -p "$REPORT_DIR"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sccache-s3-reg-XXXXXX")"
mkdir -p "$WORK_ROOT/logs"

cleanup() {
    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    for lf in "$WORK_ROOT"/logs/*.log; do
        [ -f "$lf" ] || continue
        local base
        base="$(basename "$lf")"
        python3 "$VERIFY_PY" sanitize-log "$lf" "$REPORT_DIR/$base" || true
    done
    if [ "$SKIP_SILO_SETUP" != "1" ] && [ "$KEEP_SILO" != "1" ]; then
        docker compose -f "$COMPOSE_FILE" --profile s3 down -v >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

wait_for_silo() {
    local attempts=0
    until curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then
            echo "ERROR: Silo S3 did not become healthy on http://127.0.0.1:9000" >&2
            docker compose -f "$COMPOSE_FILE" --profile s3 logs silo >&2 || true
            exit 1
        fi
        sleep 1
    done
}

start_silo() {
    if [ "$SKIP_SILO_SETUP" = "1" ]; then
        wait_for_silo
        return 0
    fi
    docker compose -f "$COMPOSE_FILE" --profile s3 down -v >/dev/null 2>&1 || true
    docker compose -f "$COMPOSE_FILE" --profile s3 up -d silo silo-setup
    wait_for_silo
    # Ensure bucket creation job finished cleanly.
    local exit_code
    exit_code="$(docker wait "$(docker compose -f "$COMPOSE_FILE" ps -a -q silo-setup)" 2>/dev/null || echo 0)"
    if [ "${exit_code:-0}" != "0" ]; then
        echo "ERROR: silo-setup exited with $exit_code" >&2
        exit 1
    fi
}

setup_slots() {
    SLOT_A="$WORK_ROOT/slot-a"
    SLOT_B="$WORK_ROOT/slot-b"
    mkdir -p "$SLOT_A" "$SLOT_B"
    cp -a "$FIXTURE_SRC" "$SLOT_A/project"
    cp -a "$FIXTURE_SRC" "$SLOT_B/project"
}

run_fetch() {
    local t0 t1
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    (cd "$SLOT_A/project" && env -u RUSTC_WRAPPER cargo fetch --locked)
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    FETCH_SEC="$(python3 -c "print(round($t1 - $t0, 3))")"
    echo "Fetched fixture dependencies in ${FETCH_SEC}s"
}

RUN_ID="$(date +%s)-$$"
S3_PREFIX="s3-reg-${RUN_ID}/"
export CARGO_INCREMENTAL=0
export SCCACHE_IDLE_TIMEOUT=0
export SCCACHE_BUCKET="test"
export SCCACHE_S3_USE_SSL="false"
export SCCACHE_S3_KEY_PREFIX="$S3_PREFIX"
export AWS_EC2_METADATA_DISABLED="true"
export AWS_DEFAULT_REGION="us-east-1"

# Start/restart dedicated local sccache server for a test phase.
restart_server() {
    local phase="$1"
    local l0_dir="$2"
    local endpoint="$3"
    local secret_key="$4"
    local policy="$5"
    local s3_prefix="${6:-$S3_PREFIX}"
    local skip_check="${7:-0}"

    if [ -n "${SCCACHE_SERVER_UDS:-}" ]; then
        "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_ROOT/sccache.sock"
    export SCCACHE_SERVER_UDS="$WORK_ROOT/${phase}.sock"
    export SCCACHE_DIR="$l0_dir"
    export SCCACHE_MULTILEVEL_CHAIN="disk,s3"
    export SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY="$policy"
    export SCCACHE_ENDPOINT="$endpoint"
    export SCCACHE_S3_KEY_PREFIX="$s3_prefix"
    export AWS_ACCESS_KEY_ID="minioadmin"
    export AWS_SECRET_ACCESS_KEY="$secret_key"
    if [ "$skip_check" = "1" ]; then
        export SCCACHE_SKIP_CACHE_CHECK="true"
    else
        unset SCCACHE_SKIP_CACHE_CHECK || true
    fi
    export SCCACHE_ERROR_LOG="$WORK_ROOT/logs/${phase}.log"
    mkdir -p "$l0_dir"
    SCCACHE_LOG="sccache=debug" "$SCCACHE_BIN" --start-server >/dev/null
}

wait_for_stat_condition() {
    local py_cond="$1"
    local timeout_sec="${2:-10}"
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

run_cargo_and_verify() {
    local leg="$1"
    local slot="$2"
    local target="$3"
    local cargo_args="$4"
    local fetch_sec="$5"
    local wait_cond="${6:-}"
    shift 6

    rm -rf "$target"
    "$SCCACHE_BIN" --zero-stats >/dev/null

    local t0 t1 elapsed
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    (
        cd "$slot/project"
        # shellcheck disable=SC2086
        RUSTC_WRAPPER="$SCCACHE_BIN" \
        SCCACHE_BASEDIRS="$slot" \
        RUSTFLAGS="--remap-path-prefix=$slot=/topsrc" \
        CARGO_TARGET_DIR="$target" \
        cargo build --locked --offline $cargo_args
    )
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    elapsed="$(python3 -c "print($t1 - $t0)")"

    if [ -n "$wait_cond" ]; then
        wait_for_stat_condition "$wait_cond" 65
    fi

    local stats_file="$WORK_ROOT/${leg}.stats.json"
    "$SCCACHE_BIN" --show-stats --stats-format json > "$stats_file"

    python3 "$VERIFY_PY" verify \
        --stats-file "$stats_file" \
        --leg-name "$leg" \
        --elapsed-sec "$elapsed" \
        --fetch-sec "$fetch_sec" \
        --expect-multilevel \
        --output-json "$REPORT_DIR/leg_${leg}.json" \
        "$@"
}

verify_slot_runtime_and_depinfo() {
    local expected_slot="$1"
    local forbidden_slot="$2"
    local target="$3"
    local expect_substr="${4:-tokio-small}"

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
    echo "$payload" | grep -q "$expect_substr" || {
        echo "ERROR: unexpected payload '$payload'" >&2
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
}

start_silo
setup_slots
run_fetch

L0_A="$WORK_ROOT/l0-a"
L0_B="$WORK_ROOT/l0-b"
LEG_FILES=()

# S01: Cold build populates L0 & S3 L1
restart_server "s01_cold" "$L0_A" "http://127.0.0.1:9000" "minioadmin" "all" "$S3_PREFIX"
run_cargo_and_verify "s01_cold" "$SLOT_A" "$SLOT_A/project/target" "" "$FETCH_SEC" "" \
    --min-compile-requests 40 \
    --exact-rust-hits 0 \
    --min-rust-misses 20 \
    --exact-read-errors 0 \
    --exact-write-errors 0
LEG_FILES+=("$REPORT_DIR/leg_s01_cold.json")

C_COUNT="$(python3 -c "import json; print(json.load(open('$REPORT_DIR/leg_s01_cold.json'))['rust_misses'])")"
echo "Measured cacheable Rust crate count C=$C_COUNT"

# Enforce exact L0 and L1 write counts recorded in S01
python3 "$VERIFY_PY" verify \
    --stats-file "$WORK_ROOT/s01_cold.stats.json" \
    --leg-name "s01_cold" \
    --elapsed-sec "$(python3 -c "import json; print(json.load(open('$REPORT_DIR/leg_s01_cold.json'))['elapsed_sec'])")" \
    --fetch-sec "$FETCH_SEC" \
    --expect-multilevel \
    --level-check "0:disk:writes==${C_COUNT}" \
    --level-check "1:s3:writes==${C_COUNT}" \
    --output-json "$REPORT_DIR/leg_s01_cold.json" >/dev/null

# S02: Target deleted, L0 retained -> L0 warm hits (restart server keeping L0 so multi_level stats start fresh)
restart_server "s02_l0_warm" "$L0_A" "http://127.0.0.1:9000" "minioadmin" "all" "$S3_PREFIX"
run_cargo_and_verify "s02_l0_warm" "$SLOT_A" "$SLOT_A/project/target" "" "0" "" \
    --min-compile-requests 40 \
    --exact-rust-hits "$C_COUNT" \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0 \
    --level-check "0:disk:hits==${C_COUNT}" \
    --level-check "1:s3:hits==0"
LEG_FILES+=("$REPORT_DIR/leg_s02_l0_warm.json")

# S03: Target & L0 deleted -> S3 L1 warm hits + L0 backfill
rm -rf "$L0_A"
restart_server "s03_s3_l1_warm" "$L0_A" "http://127.0.0.1:9000" "minioadmin" "all" "$S3_PREFIX"
run_cargo_and_verify "s03_s3_l1_warm" "$SLOT_A" "$SLOT_A/project/target" "" "0" \
    "len(ml)>=2 and ml[0]['backfills_to']>=ml[1]['backfills_from']" \
    --min-compile-requests 40 \
    --exact-rust-hits "$C_COUNT" \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0 \
    --level-check "0:disk:hits==0" \
    --level-check "0:disk:misses>=${C_COUNT}" \
    --level-check "1:s3:hits==${C_COUNT}" \
    --level-check "1:s3:misses<=2" \
    --level-check "0:disk:backfills_to==${C_COUNT}" \
    --level-check "1:s3:backfills_from==${C_COUNT}"
LEG_FILES+=("$REPORT_DIR/leg_s03_s3_l1_warm.json")

# S04: Cross-root build in slot-b with fresh L0 -> safe crates hit S3 L1, manifest/OUT_DIR crates miss
rm -rf "$L0_B"
restart_server "s04_cross_root_l1" "$L0_B" "http://127.0.0.1:9000" "minioadmin" "all" "$S3_PREFIX"
run_cargo_and_verify "s04_cross_root_l1" "$SLOT_B" "$SLOT_B/project/target" "" "0" \
    "len(ml)>=2 and ml[0]['backfills_to']==ml[1]['backfills_from']" \
    --min-compile-requests 40 \
    --min-rust-hits 20 \
    --min-rust-misses 1 \
    --max-rust-misses 6 \
    --exact-rust-total "$C_COUNT" \
    --exact-read-errors 0 \
    --exact-write-errors 0 \
    --level-check "0:disk:hits==0" \
    --level-check "1:s3:hits>=20" \
    --level-check "0:disk:backfills_to>=20" \
    --level-check "1:s3:backfills_from>=20"
LEG_FILES+=("$REPORT_DIR/leg_s04_cross_root_l1.json")

verify_slot_runtime_and_depinfo "$SLOT_B" "$SLOT_A" "$SLOT_B/project/target"

# S05: Verify L0 backfill directory populated and second rebuild hits L0 100%
restart_server "s05_backfill_l0_hit" "$L0_B" "http://127.0.0.1:9000" "minioadmin" "all" "$S3_PREFIX"
l0_files="$(find "$L0_B" -type f | wc -l)"
[ "$l0_files" -gt 0 ] || {
    echo "ERROR: L0 directory $L0_B empty after S04 backfill" >&2
    exit 1
}
echo "Verified L0 backfill files present: count=$l0_files"

run_cargo_and_verify "s05_backfill_l0_hit" "$SLOT_B" "$SLOT_B/project/target" "" "0" "" \
    --min-compile-requests 40 \
    --exact-rust-hits "$C_COUNT" \
    --exact-rust-misses 0 \
    --exact-read-errors 0 \
    --exact-write-errors 0 \
    --level-check "0:disk:hits==${C_COUNT}" \
    --level-check "1:s3:hits==0"
LEG_FILES+=("$REPORT_DIR/leg_s05_backfill_l0_hit.json")

if [ "$SCENARIOS" = "all" ]; then
    # S06: Source change in small-core must invalidate only small-core & produce updated output
    cp "$SLOT_B/project/small-core/src/lib.rs" "$WORK_ROOT/small-core.orig.rs"
    python3 - "$SLOT_B/project/small-core/src/lib.rs" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("input * 3 + 7", "input * 5 + 9"))
PY
    run_cargo_and_verify "s06_input_change" "$SLOT_B" "$SLOT_B/project/target" "" "0" "" \
        --min-compile-requests 40 \
        --exact-rust-hits "$((C_COUNT - 1))" \
        --exact-rust-misses 1 \
        --exact-read-errors 0 \
        --exact-write-errors 0
    LEG_FILES+=("$REPORT_DIR/leg_s06_input_change.json")
    s06_out="$(
        cd "$SLOT_B/project" && \
        env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$SLOT_B/project/target" \
        cargo run --locked --offline -q -p small-app
    )"
    echo "S06 runtime output: $s06_out"
    echo "$s06_out" | grep -q '"value":44' || {
        echo "ERROR: expected updated value 44 in S06 output, got $s06_out" >&2
        exit 1
    }
    cp "$WORK_ROOT/small-core.orig.rs" "$SLOT_B/project/small-core/src/lib.rs"

    # S07: Connection refused under ignore / l0 / all write error policies (skip startup check so runtime fault path executes)
    for policy in ignore l0 all; do
        l0_tmp="$WORK_ROOT/l0-s07-$policy"
        rm -rf "$l0_tmp"
        restart_server "s07_conn_refused_$policy" "$l0_tmp" "http://[::1]:19999" "minioadmin" "$policy" "$S3_PREFIX" "1"
        if [ "$policy" = "all" ]; then
            run_cargo_and_verify "s07_conn_refused_$policy" "$SLOT_A" "$WORK_ROOT/target-s07-$policy" "-p small-manifest" "0" "" \
                --min-compile-requests 1 \
                --exact-rust-hits 0 \
                --exact-rust-misses 1 \
                --exact-read-errors 0 \
                --min-write-errors 1 \
                --level-check "1:s3:write_failures>=1"
        else
            run_cargo_and_verify "s07_conn_refused_$policy" "$SLOT_A" "$WORK_ROOT/target-s07-$policy" "-p small-manifest" "0" \
                "len(ml)>=2 and ml[1]['write_failures']>=1" \
                --min-compile-requests 1 \
                --exact-rust-hits 0 \
                --exact-rust-misses 1 \
                --exact-read-errors 0 \
                --exact-write-errors 0 \
                --level-check "0:disk:writes>=1" \
                --level-check "1:s3:write_failures>=1"
        fi
        LEG_FILES+=("$REPORT_DIR/leg_s07_conn_refused_${policy}.json")
    done

    # S08: S3 authentication error -> diagnostic failure recorded cleanly, build succeeds
    rm -rf "$WORK_ROOT/l0-s08"
    restart_server "s08_s3_auth_error" "$WORK_ROOT/l0-s08" "http://127.0.0.1:9000" "wrong-secret-key" "all" "$S3_PREFIX" "1"
    run_cargo_and_verify "s08_s3_auth_error" "$SLOT_A" "$WORK_ROOT/target-s08" "-p small-manifest" "0" "" \
        --min-compile-requests 1 \
        --exact-rust-hits 0 \
        --exact-rust-misses 1 \
        --min-write-errors 1 \
        --level-check "1:s3:write_failures>=1"
    LEG_FILES+=("$REPORT_DIR/leg_s08_s3_auth_error.json")
    grep -qiE "403|forbidden|signature|auth|failed to write" "$WORK_ROOT/logs/s08_s3_auth_error.log" || {
        echo "ERROR: expected diagnostic S3 auth error in server log" >&2
        tail -40 "$WORK_ROOT/logs/s08_s3_auth_error.log" >&2
        exit 1
    }

    # S09: S3 service stopped mid-session -> start server while healthy, stop silo, then verify fallback + write error
    rm -rf "$WORK_ROOT/l0-s09"
    restart_server "s09_s3_stopped" "$WORK_ROOT/l0-s09" "http://127.0.0.1:9000" "minioadmin" "all" "$S3_PREFIX" "0"
    docker compose -f "$COMPOSE_FILE" --profile s3 stop silo
    run_cargo_and_verify "s09_s3_stopped" "$SLOT_A" "$WORK_ROOT/target-s09" "-p small-manifest" "0" "" \
        --min-compile-requests 1 \
        --exact-rust-hits 0 \
        --exact-rust-misses 1 \
        --min-write-errors 1 \
        --level-check "1:s3:write_failures>=1"
    LEG_FILES+=("$REPORT_DIR/leg_s09_s3_stopped.json")
    docker compose -f "$COMPOSE_FILE" --profile s3 start silo
    wait_for_silo

    # S10: Concurrent builds across two roots sharing daemon + fresh S3 prefix
    rm -rf "$WORK_ROOT/l0-s10" "$SLOT_A/project/target_s10" "$SLOT_B/project/target_s10"
    S10_PREFIX="s3-reg-${RUN_ID}-s10/"
    restart_server "s10_concurrent" "$WORK_ROOT/l0-s10" "http://127.0.0.1:9000" "minioadmin" "all" "$S10_PREFIX"
    "$SCCACHE_BIN" --zero-stats >/dev/null
    t0="$(python3 -c 'import time; print(time.monotonic())')"
    (
        cd "$SLOT_A/project" && \
        RUSTC_WRAPPER="$SCCACHE_BIN" SCCACHE_BASEDIRS="$SLOT_A" \
        RUSTFLAGS="--remap-path-prefix=$SLOT_A=/topsrc" \
        CARGO_TARGET_DIR="$SLOT_A/project/target_s10" cargo build --locked --offline
    ) &
    pid_a=$!
    (
        cd "$SLOT_B/project" && \
        RUSTC_WRAPPER="$SCCACHE_BIN" SCCACHE_BASEDIRS="$SLOT_B" \
        RUSTFLAGS="--remap-path-prefix=$SLOT_B=/topsrc" \
        CARGO_TARGET_DIR="$SLOT_B/project/target_s10" cargo build --locked --offline
    ) &
    pid_b=$!
    wait "$pid_a"
    wait "$pid_b"
    t1="$(python3 -c 'import time; print(time.monotonic())')"
    elapsed="$(python3 -c "print($t1 - $t0)")"

    "$SCCACHE_BIN" --show-stats --stats-format json > "$WORK_ROOT/s10_concurrent.stats.json"
    python3 "$VERIFY_PY" verify \
        --stats-file "$WORK_ROOT/s10_concurrent.stats.json" \
        --leg-name "s10_concurrent" \
        --elapsed-sec "$elapsed" \
        --expect-multilevel \
        --min-compile-requests 80 \
        --exact-rust-total "$((C_COUNT * 2))" \
        --exact-read-errors 0 \
        --exact-write-errors 0 \
        --output-json "$REPORT_DIR/leg_s10_concurrent.json"
    LEG_FILES+=("$REPORT_DIR/leg_s10_concurrent.json")

    verify_slot_runtime_and_depinfo "$SLOT_A" "$SLOT_B" "$SLOT_A/project/target_s10"
    verify_slot_runtime_and_depinfo "$SLOT_B" "$SLOT_A" "$SLOT_B/project/target_s10"
fi

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCCACHE_VER="$("$SCCACHE_BIN" --version)"
RUSTC_VER="$(rustc --version)"
CARGO_VER="$(cargo --version)"

python3 "$VERIFY_PY" report \
    --title "sccache L0+S3 Multilevel Regression" \
    --commit-sha "$COMMIT_SHA" \
    --sccache-version "$SCCACHE_VER" \
    --rustc-version "$RUSTC_VER" \
    --cargo-version "$CARGO_VER" \
    --backend "disk,s3 (silo)" \
    --fixture "tokio-small" \
    --leg-files "${LEG_FILES[@]}" \
    --report-json "$REPORT_DIR/s3-regression-report.json" \
    ${GITHUB_STEP_SUMMARY:+--summary-md "$GITHUB_STEP_SUMMARY"}
