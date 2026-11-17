#!/usr/bin/env bash
set -euo pipefail

# Performance and cache hit-rate regression harness for tokio-small and tokio-medium.
# Separates `cargo fetch --locked` from compilation timing across Cold, L0 Warm (x2),
# S3 L1 Warm (Silo), and Cross-root S3 L1 Warm scenarios.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/tests/integration/docker-compose.yml"
VERIFY_PY="$SCRIPT_DIR/verify_stats.py"

SCCACHE_BIN="${SCCACHE_BIN:-$REPO_ROOT/target/debug/sccache}"
REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/target/regression-reports/performance}"
SKIP_SILO_SETUP="${SKIP_SILO_SETUP:-0}"
KEEP_SILO="${KEEP_SILO:-0}"
mkdir -p "$REPORT_DIR"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sccache-perf-reg-XXXXXX")"
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
            echo "ERROR: Silo S3 did not become healthy" >&2
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
    local exit_code
    exit_code="$(docker wait "$(docker compose -f "$COMPOSE_FILE" ps -a -q silo-setup)" 2>/dev/null || echo 0)"
    if [ "${exit_code:-0}" != "0" ]; then
        echo "ERROR: silo-setup exited with $exit_code" >&2
        exit 1
    fi
}

export CARGO_INCREMENTAL=0
export SCCACHE_IDLE_TIMEOUT=0
export SCCACHE_BUCKET="test"
export SCCACHE_ENDPOINT="http://127.0.0.1:9000"
export SCCACHE_S3_USE_SSL="false"
export AWS_ACCESS_KEY_ID="minioadmin"
export AWS_SECRET_ACCESS_KEY="minioadmin"
export AWS_EC2_METADATA_DISABLED="true"
export AWS_DEFAULT_REGION="us-east-1"

RUN_ID="$(date +%s)-$$"

restart_perf_server() {
    local phase="$1"
    local l0_dir="$2"
    local prefix="$3"

    "$SCCACHE_BIN" --stop-server >/dev/null 2>&1 || true
    export SCCACHE_SERVER_UDS="$WORK_ROOT/${phase}.sock"
    export SCCACHE_DIR="$l0_dir"
    export SCCACHE_MULTILEVEL_CHAIN="disk,s3"
    export SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY="all"
    export SCCACHE_S3_KEY_PREFIX="$prefix"
    export SCCACHE_ERROR_LOG="$WORK_ROOT/logs/${phase}.log"
    mkdir -p "$l0_dir"
    SCCACHE_LOG="sccache=warn" "$SCCACHE_BIN" --start-server >/dev/null
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
        raise SystemExit(f"Timed out waiting for `{cond}`: {raw}")
    time.sleep(0.1)
PY
}

ALL_LEGS=()

run_fixture_perf() {
    local name="$1"
    local min_reqs="$2"
    local min_cold_rust="$3"
    local xroot_min_hits="$4"
    local xroot_max_misses="$5"
    local manifest_pkg="$6"
    local app_pkg="$7"
    local min_xroot_rate="$8"

    local src="$REPO_ROOT/tests/fixtures/$name"
    local slot_a="$WORK_ROOT/$name/slot-a"
    local slot_b="$WORK_ROOT/$name/slot-b"
    local l0_a="$WORK_ROOT/$name/l0-a"
    local l0_s3="$WORK_ROOT/$name/l0-s3"
    local l0_b="$WORK_ROOT/$name/l0-b"
    local prefix="perf-${RUN_ID}-${name}/"

    mkdir -p "$slot_a" "$slot_b"
    cp -a "$src" "$slot_a/project"
    cp -a "$src" "$slot_b/project"

    local tf0 tf1 fetch_sec
    tf0="$(python3 -c 'import time; print(time.monotonic())')"
    (cd "$slot_a/project" && env -u RUSTC_WRAPPER cargo fetch --locked)
    tf1="$(python3 -c 'import time; print(time.monotonic())')"
    fetch_sec="$(python3 -c "print(round($tf1 - $tf0, 3))")"

    run_leg() {
        local leg="$1"
        local slot="$2"
        local wait_cond="$3"
        shift 3

        rm -rf "$slot/project/target"
        "$SCCACHE_BIN" --zero-stats >/dev/null
        local t0 t1 elapsed
        t0="$(python3 -c 'import time; print(time.monotonic())')"
        (
            cd "$slot/project" && \
            RUSTC_WRAPPER="$SCCACHE_BIN" \
            SCCACHE_BASEDIRS="$slot" \
            CARGO_TARGET_DIR="$slot/project/target" \
            cargo build --locked --offline
        )
        t1="$(python3 -c 'import time; print(time.monotonic())')"
        elapsed="$(python3 -c "print($t1 - $t0)")"

        if [ -n "$wait_cond" ]; then
            wait_for_stat_condition "$wait_cond" 60
        fi
        local stats_f="$WORK_ROOT/${leg}.stats.json"
        "$SCCACHE_BIN" --show-stats --stats-format json > "$stats_f"
        python3 "$VERIFY_PY" verify \
            --stats-file "$stats_f" \
            --leg-name "$leg" \
            --elapsed-sec "$elapsed" \
            --fetch-sec "$fetch_sec" \
            --expect-multilevel \
            --output-json "$REPORT_DIR/leg_${leg}.json" \
            "$@"
    }

    # 1. Cold build
    restart_perf_server "${name}_cold" "$l0_a" "$prefix"
    run_leg "${name}_cold" "$slot_a" "" \
        --min-compile-requests "$min_reqs" \
        --exact-rust-hits 0 \
        --min-rust-misses "$min_cold_rust" \
        --exact-read-errors 0 \
        --exact-write-errors 0
    ALL_LEGS+=("$REPORT_DIR/leg_${name}_cold.json")

    local c_rust c_total
    c_rust="$(python3 -c "import json; print(json.load(open('$REPORT_DIR/leg_${name}_cold.json'))['rust_misses'])")"
    c_total="$(python3 -c "import json; print(json.load(open('$REPORT_DIR/leg_${name}_cold.json'))['multi_level'][0]['writes'])")"

    # 2. L0 Warm iteration 1 and iteration 2
    for iter in 1 2; do
        restart_perf_server "${name}_l0_warm_${iter}" "$l0_a" "$prefix"
        run_leg "${name}_l0_warm_${iter}" "$slot_a" "" \
            --min-compile-requests "$min_reqs" \
            --exact-rust-hits "$c_rust" \
            --exact-rust-misses 0 \
            --exact-read-errors 0 \
            --exact-write-errors 0 \
            --level-check "0:disk:hits==${c_total}" \
            --level-check "1:s3:hits==0"
        ALL_LEGS+=("$REPORT_DIR/leg_${name}_l0_warm_${iter}.json")
    done

    # 3. Silo L1 Warm (fresh L0 + fresh target)
    rm -rf "$l0_s3"
    restart_perf_server "${name}_s3_l1_warm" "$l0_s3" "$prefix"
    run_leg "${name}_s3_l1_warm" "$slot_a" "len(ml)>=2 and ml[0]['backfills_to']>=ml[1]['backfills_from']" \
        --min-compile-requests "$min_reqs" \
        --exact-rust-hits "$c_rust" \
        --exact-rust-misses 0 \
        --exact-read-errors 0 \
        --exact-write-errors 0 \
        --level-check "0:disk:hits==0" \
        --level-check "1:s3:hits==${c_total}" \
        --level-check "0:disk:backfills_to==${c_total}" \
        --level-check "1:s3:backfills_from==${c_total}"
    ALL_LEGS+=("$REPORT_DIR/leg_${name}_s3_l1_warm.json")

    # 4. Cross-root S3 L1 Warm (slot-b, fresh L0 + fresh target)
    rm -rf "$l0_b"
    restart_perf_server "${name}_cross_root_l1" "$l0_b" "$prefix"
    run_leg "${name}_cross_root_l1" "$slot_b" "len(ml)>=2 and ml[0]['backfills_to']>=ml[1]['backfills_from']" \
        --min-compile-requests "$min_reqs" \
        --min-rust-hits "$xroot_min_hits" \
        --min-rust-misses 1 \
        --max-rust-misses "$xroot_max_misses" \
        --exact-rust-total "$c_rust" \
        --exact-read-errors 0 \
        --exact-write-errors 0 \
        --level-check "0:disk:hits==0"
    ALL_LEGS+=("$REPORT_DIR/leg_${name}_cross_root_l1.json")

    local out expected_manifest actual_manifest
    out="$(cd "$slot_b/project" && env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$slot_b/project/target" cargo run --locked --offline -q -p "$app_pkg")"
    expected_manifest="$(cd "$slot_b/project/$manifest_pkg" && pwd -P)"
    actual_manifest="${out#*|}"
    [ "$actual_manifest" = "$expected_manifest" ] || {
        echo "FALSE HIT DETECTED in $name: expected $expected_manifest, got $actual_manifest" >&2
        exit 1
    }
    (cd "$slot_b/project" && env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$slot_b/project/target" cargo test --locked --offline -p "$manifest_pkg")

    # Compute hit rates, speedups, and enforce latency / hit-rate assertions
    python3 - "$REPORT_DIR" "$name" "$min_xroot_rate" "$fetch_sec" "${GITHUB_STEP_SUMMARY:-}" <<'PY'
import json, pathlib, sys
report_dir, name, min_xroot_rate, fetch_sec = pathlib.Path(sys.argv[1]), sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
summary_path = sys.argv[5] if len(sys.argv) > 5 else ""

cold = json.loads((report_dir / f"leg_{name}_cold.json").read_text())
w1 = json.loads((report_dir / f"leg_{name}_l0_warm_1.json").read_text())
w2 = json.loads((report_dir / f"leg_{name}_l0_warm_2.json").read_text())
l1 = json.loads((report_dir / f"leg_{name}_s3_l1_warm.json").read_text())
xr = json.loads((report_dir / f"leg_{name}_cross_root_l1.json").read_text())

l0_mean = (w1["elapsed_sec"] + w2["elapsed_sec"]) / 2.0
xr_total = xr["rust_hits"] + xr["rust_misses"]
xr_rate = (100.0 * xr["rust_hits"] / xr_total) if xr_total else 0.0

assert l0_mean < cold["elapsed_sec"], f"{name}: expected L0 warm mean ({l0_mean:.2f}s) < cold ({cold['elapsed_sec']:.2f}s)"
assert l1["elapsed_sec"] < cold["elapsed_sec"], f"{name}: expected S3 L1 warm ({l1['elapsed_sec']:.2f}s) < cold ({cold['elapsed_sec']:.2f}s)"
assert xr_rate >= min_xroot_rate, f"{name}: cross-root hit rate {xr_rate:.2f}% < {min_xroot_rate:.2f}%"

perf_doc = {
    "fixture": name,
    "fetch_sec": fetch_sec,
    "cold_sec": round(cold["elapsed_sec"], 3),
    "l0_warm_mean_sec": round(l0_mean, 3),
    "l0_speedup": round(cold["elapsed_sec"] / l0_mean, 2) if l0_mean > 0 else 0.0,
    "s3_l1_warm_sec": round(l1["elapsed_sec"], 3),
    "s3_l1_speedup": round(cold["elapsed_sec"] / l1["elapsed_sec"], 2) if l1["elapsed_sec"] > 0 else 0.0,
    "cross_root_l1_sec": round(xr["elapsed_sec"], 3),
    "cross_root_rust_hits": xr["rust_hits"],
    "cross_root_rust_misses": xr["rust_misses"],
    "cross_root_hit_rate_pct": round(xr_rate, 2),
}
(report_dir / f"summary_{name}.json").write_text(json.dumps(perf_doc, indent=2) + "\n")
print(f"PERF_SUMMARY {name}: cold={perf_doc['cold_sec']}s l0_warm_mean={perf_doc['l0_warm_mean_sec']}s ({perf_doc['l0_speedup']}x) s3_l1={perf_doc['s3_l1_warm_sec']}s ({perf_doc['s3_l1_speedup']}x) xroot={perf_doc['cross_root_hit_rate_pct']}% fetch={fetch_sec}s")

if summary_path:
    lines = [
        f"### Performance Summary: `{name}`",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Dependency fetch (`cargo fetch --locked`) | {fetch_sec:.2f}s |",
        f"| Cold build | {perf_doc['cold_sec']:.2f}s |",
        f"| L0 Warm mean (2 runs, 100% hit) | {perf_doc['l0_warm_mean_sec']:.2f}s ({perf_doc['l0_speedup']:.2f}x) |",
        f"| Silo S3 L1 Warm (100% hit) | {perf_doc['s3_l1_warm_sec']:.2f}s ({perf_doc['s3_l1_speedup']:.2f}x) |",
        f"| Cross-root S3 L1 (`slot-b`) | {perf_doc['cross_root_l1_sec']:.2f}s ({xr['rust_hits']}/{xr_total} hits, {perf_doc['cross_root_hit_rate_pct']:.2f}%) |",
        "",
    ]
    with open(summary_path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
PY
}

start_silo
run_fixture_perf "tokio-small" 40 20 20 6 "small-manifest" "small-app" 75.0
run_fixture_perf "tokio-medium" 150 90 90 25 "medium-manifest" "medium-app" 80.0

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCCACHE_VER="$("$SCCACHE_BIN" --version)"
RUSTC_VER="$(rustc --version)"
CARGO_VER="$(cargo --version)"

python3 "$VERIFY_PY" report \
    --title "sccache Performance Regression (tokio-small + tokio-medium)" \
    --commit-sha "$COMMIT_SHA" \
    --sccache-version "$SCCACHE_VER" \
    --rustc-version "$RUSTC_VER" \
    --cargo-version "$CARGO_VER" \
    --backend "disk,s3 (silo)" \
    --fixture "tokio-small + tokio-medium" \
    --leg-files "${ALL_LEGS[@]}" \
    --report-json "$REPORT_DIR/performance-report.json" \
    ${GITHUB_STEP_SUMMARY:+--summary-md "$GITHUB_STEP_SUMMARY"}
