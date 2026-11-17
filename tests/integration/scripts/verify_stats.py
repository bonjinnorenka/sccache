#!/usr/bin/env python3
"""Strict sccache JSON stats validator, report generator, and log sanitizer."""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


REQUIRED_STATS_KEYS = (
    "compile_requests",
    "requests_not_cacheable",
    "requests_executed",
    "cache_hits",
    "cache_misses",
    "non_cacheable_compilations",
    "cache_read_errors",
    "cache_write_errors",
    "cache_errors",
)

REQUIRED_LEVEL_KEYS = (
    "name",
    "location",
    "hits",
    "misses",
    "writes",
    "write_failures",
    "backfills_from",
    "backfills_to",
)

LEVEL_EXPR_RE = re.compile(r"^(\d+):([^:]+):([a-z_]+)(==|!=|>=|<=|>|<)(\d+)$")


def require_int(obj: dict[str, Any], key: str, ctx: str) -> int:
    if key not in obj:
        raise ValueError(f"missing required field `{key}` in {ctx}")
    val = obj[key]
    if isinstance(val, bool) or not isinstance(val, int):
        raise ValueError(f"field `{key}` in {ctx} must be int, got {type(val).__name__}")
    return val


def require_lang_rust_count(obj: dict[str, Any], section: str) -> int:
    if section not in obj or not isinstance(obj[section], dict):
        raise ValueError(f"missing or non-object `{section}` in stats")
    counts = obj[section].get("counts")
    if not isinstance(counts, dict):
        raise ValueError(f"missing or non-object `{section}.counts` in stats")
    val = counts.get("Rust", 0)
    if isinstance(val, bool) or not isinstance(val, int):
        raise ValueError(f"non-int `{section}.counts.Rust`: {val!r}")
    return val


def parse_and_validate_stats(raw: str, expect_multilevel: bool) -> dict[str, Any]:
    if not raw.strip():
        raise ValueError("empty sccache --show-stats JSON output")
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid sccache --show-stats JSON: {exc}") from exc

    if not isinstance(doc, dict):
        raise ValueError("top-level sccache stats JSON must be an object")
    for top_key in ("stats", "cache_location", "version"):
        if top_key not in doc:
            raise ValueError(f"missing top-level key `{top_key}` in sccache stats JSON")

    stats = doc["stats"]
    if not isinstance(stats, dict):
        raise ValueError("`stats` must be an object")
    for key in REQUIRED_STATS_KEYS:
        if key not in stats:
            raise ValueError(f"missing required stats key `{key}`")

    multi_level = stats.get("multi_level")
    if expect_multilevel:
        if not isinstance(multi_level, list) or not multi_level:
            raise ValueError("expected non-empty `stats.multi_level` array")
        for idx, level in enumerate(multi_level):
            if not isinstance(level, dict):
                raise ValueError(f"`stats.multi_level[{idx}]` must be an object")
            for k in REQUIRED_LEVEL_KEYS:
                if k not in level:
                    raise ValueError(f"missing `{k}` in `stats.multi_level[{idx}]`")
            for int_k in (
                "hits",
                "misses",
                "writes",
                "write_failures",
                "backfills_from",
                "backfills_to",
            ):
                require_int(level, int_k, f"multi_level[{idx}]")

    parsed = {
        "version": doc["version"],
        "cache_location": doc["cache_location"],
        "compile_requests": require_int(stats, "compile_requests", "stats"),
        "requests_not_cacheable": require_int(stats, "requests_not_cacheable", "stats"),
        "requests_executed": require_int(stats, "requests_executed", "stats"),
        "non_cacheable_compilations": require_int(
            stats, "non_cacheable_compilations", "stats"
        ),
        "cache_read_errors": require_int(stats, "cache_read_errors", "stats"),
        "cache_write_errors": require_int(stats, "cache_write_errors", "stats"),
        "rust_hits": require_lang_rust_count(stats, "cache_hits"),
        "rust_misses": require_lang_rust_count(stats, "cache_misses"),
        "rust_errors": require_lang_rust_count(stats, "cache_errors"),
        "multi_level": multi_level,
    }
    return parsed


def eval_cmp(actual: int, op: str, expected: int) -> bool:
    if op == "==":
        return actual == expected
    if op == "!=":
        return actual != expected
    if op == ">=":
        return actual >= expected
    if op == "<=":
        return actual <= expected
    if op == ">":
        return actual > expected
    if op == "<":
        return actual < expected
    raise ValueError(f"unsupported operator {op}")


def cmd_verify(args: argparse.Namespace) -> int:
    raw = (
        Path(args.stats_file).read_text(encoding="utf-8")
        if args.stats_file
        else sys.stdin.read()
    )
    failures: list[str] = []
    parsed: dict[str, Any] = {}
    try:
        parsed = parse_and_validate_stats(raw, args.expect_multilevel)
    except ValueError as exc:
        failures.append(str(exc))

    if not failures:
        checks = [
            ("compile_requests", args.min_compile_requests, ">="),
            ("compile_requests", args.exact_compile_requests, "=="),
            ("rust_hits", args.min_rust_hits, ">="),
            ("rust_hits", args.exact_rust_hits, "=="),
            ("rust_misses", args.min_rust_misses, ">="),
            ("rust_misses", args.max_rust_misses, "<="),
            ("rust_misses", args.exact_rust_misses, "=="),
            ("cache_read_errors", args.exact_read_errors, "=="),
            ("cache_read_errors", args.min_read_errors, ">="),
            ("cache_write_errors", args.exact_write_errors, "=="),
            ("cache_write_errors", args.min_write_errors, ">="),
        ]
        for field, expected, op in checks:
            if expected is not None:
                actual = parsed[field]
                if not eval_cmp(actual, op, expected):
                    failures.append(f"{field}: expected {op} {expected}, got {actual}")

        if args.exact_rust_total is not None:
            rust_total = parsed["rust_hits"] + parsed["rust_misses"]
            if rust_total != args.exact_rust_total:
                failures.append(
                    f"rust_hits + rust_misses: expected == {args.exact_rust_total}, got {rust_total}"
                )

        if args.min_any_errors is not None:
            total_errs = parsed["cache_read_errors"] + parsed["cache_write_errors"]
            if total_errs < args.min_any_errors:
                failures.append(
                    f"cache_read_errors + cache_write_errors: expected >= {args.min_any_errors}, got {total_errs}"
                )

        levels = parsed.get("multi_level") or []
        for expr in args.level_check:
            m = LEVEL_EXPR_RE.match(expr)
            if not m:
                failures.append(f"invalid --level-check expression: {expr!r}")
                continue
            idx = int(m.group(1))
            name_substr = m.group(2)
            key = m.group(3)
            op = m.group(4)
            expected = int(m.group(5))
            if idx >= len(levels):
                failures.append(
                    f"level {idx} ({name_substr}) missing; multi_level len={len(levels)}"
                )
                continue
            lvl = levels[idx]
            lvl_name = str(lvl.get("name", ""))
            if name_substr.lower() not in lvl_name.lower():
                failures.append(
                    f"level {idx} name `{lvl_name}` does not match `{name_substr}`"
                )
                continue
            if key not in lvl:
                failures.append(f"level {idx} missing key `{key}`")
                continue
            actual = lvl[key]
            if not eval_cmp(actual, op, expected):
                failures.append(
                    f"level[{idx}] ({lvl_name}).{key}: expected {op} {expected}, got {actual}"
                )

    status = "FAIL" if failures else "PASS"
    failure_reason = "; ".join(failures)
    record = {
        "leg": args.leg_name,
        "status": status,
        "failure_reason": failure_reason,
        "elapsed_sec": args.elapsed_sec,
        "fetch_sec": args.fetch_sec,
        **parsed,
    }
    if args.output_json:
        out_path = Path(args.output_json)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

    if parsed:
        print(
            f"STATS_VERIFY leg={args.leg_name} status={status} "
            f"req={parsed['compile_requests']} hits={parsed['rust_hits']} "
            f"misses={parsed['rust_misses']} noncache={parsed['requests_not_cacheable']} "
            f"rerr={parsed['cache_read_errors']} werr={parsed['cache_write_errors']} "
            f"elapsed={args.elapsed_sec:.2f}s"
        )
    else:
        print(
            f"STATS_VERIFY leg={args.leg_name} status=FAIL reason={failure_reason}",
            file=sys.stderr,
        )

    if failures:
        print(f"VERIFICATION FAILED ({args.leg_name}): {failure_reason}", file=sys.stderr)
        return 1
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    legs = [json.loads(Path(p).read_text(encoding="utf-8")) for p in args.leg_files]
    overall_pass = all(leg.get("status") == "PASS" for leg in legs)
    overall_status = "PASS" if overall_pass and legs else "FAIL"
    failures = [
        f"{leg.get('leg')}: {leg.get('failure_reason')}"
        for leg in legs
        if leg.get("status") != "PASS"
    ]

    report = {
        "title": args.title,
        "commit_sha": args.commit_sha,
        "sccache_version": args.sccache_version,
        "rustc_version": args.rustc_version,
        "cargo_version": args.cargo_version,
        "backend": args.backend,
        "fixture": args.fixture,
        "status": overall_status,
        "failure_reasons": failures,
        "legs": legs,
    }
    if args.report_json:
        out_path = Path(args.report_json)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    lines = [
        f"## {args.title} — {overall_status}",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Commit SHA | `{args.commit_sha}` |",
        f"| sccache | `{args.sccache_version}` |",
        f"| rustc | `{args.rustc_version}` |",
        f"| cargo | `{args.cargo_version}` |",
        f"| Backend | `{args.backend}` |",
        f"| Fixture | `{args.fixture}` |",
        f"| Status | **{overall_status}** |",
        "",
        "| Leg | Status | Requests | Rust Hits | Rust Misses | Non-cacheable | Read Err | Write Err | Elapsed (s) | Notes |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for leg in legs:
        ml_note = ""
        if isinstance(leg.get("multi_level"), list):
            parts = []
            for lvl in leg["multi_level"]:
                parts.append(
                    f"{lvl['name']}:h={lvl['hits']}/m={lvl['misses']}/w={lvl['writes']}/wf={lvl['write_failures']}/bf_from={lvl['backfills_from']}/bf_to={lvl['backfills_to']}"
                )
            ml_note = "; ".join(parts)
        note = leg.get("failure_reason") or ml_note
        lines.append(
            f"| `{leg.get('leg', '-')}` | **{leg.get('status', 'FAIL')}** | "
            f"{leg.get('compile_requests', '-')} | {leg.get('rust_hits', '-')} | "
            f"{leg.get('rust_misses', '-')} | {leg.get('requests_not_cacheable', '-')} | "
            f"{leg.get('cache_read_errors', '-')} | {leg.get('cache_write_errors', '-')} | "
            f"{leg.get('elapsed_sec', 0.0):.2f} | {note} |"
        )
    lines.append("")

    summary_text = "\n".join(lines)
    if args.summary_md:
        Path(args.summary_md).parent.mkdir(parents=True, exist_ok=True)
        with open(args.summary_md, "a", encoding="utf-8") as fh:
            fh.write(summary_text + "\n")
    else:
        print(summary_text)

    return 0 if overall_status == "PASS" else 1


def cmd_sanitize_log(args: argparse.Namespace) -> int:
    src = Path(args.input_log)
    dst = Path(args.output_log)
    if not src.exists():
        return 0
    text = src.read_text(encoding="utf-8", errors="replace")
    secret_env_vars = (
        "ACTIONS_RUNTIME_TOKEN",
        "ACTIONS_RESULTS_URL",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "GITHUB_TOKEN",
    )
    for var in secret_env_vars:
        val = os.environ.get(var, "")
        if val:
            text = text.replace(val, f"[REDACTED_{var}]")
    text = re.sub(r"(?i)(authorization:\s*bearer\s+)\S+", r"\1[REDACTED]", text)
    text = re.sub(r"(?i)([?&](?:sig|token|sv|st|se)=)[^&\s]+", r"\1[REDACTED]", text)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(text, encoding="utf-8")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Strict sccache stats verifier")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_verify = sub.add_parser("verify", help="Validate sccache stats JSON")
    p_verify.add_argument("--stats-file", help="Path to stats JSON (defaults to stdin)")
    p_verify.add_argument("--leg-name", default="default")
    p_verify.add_argument("--elapsed-sec", type=float, default=0.0)
    p_verify.add_argument("--fetch-sec", type=float, default=0.0)
    p_verify.add_argument("--output-json")
    p_verify.add_argument("--expect-multilevel", action="store_true")
    p_verify.add_argument("--min-compile-requests", type=int)
    p_verify.add_argument("--exact-compile-requests", type=int)
    p_verify.add_argument("--min-rust-hits", type=int)
    p_verify.add_argument("--exact-rust-hits", type=int)
    p_verify.add_argument("--min-rust-misses", type=int)
    p_verify.add_argument("--max-rust-misses", type=int)
    p_verify.add_argument("--exact-rust-misses", type=int)
    p_verify.add_argument("--exact-rust-total", type=int)
    p_verify.add_argument("--exact-read-errors", type=int)
    p_verify.add_argument("--min-read-errors", type=int)
    p_verify.add_argument("--exact-write-errors", type=int)
    p_verify.add_argument("--min-write-errors", type=int)
    p_verify.add_argument("--min-any-errors", type=int)
    p_verify.add_argument("--level-check", action="append", default=[])
    p_verify.set_defaults(func=cmd_verify)

    p_report = sub.add_parser("report", help="Generate combined JSON and Markdown summary")
    p_report.add_argument("--title", required=True)
    p_report.add_argument("--commit-sha", default="unknown")
    p_report.add_argument("--sccache-version", default="unknown")
    p_report.add_argument("--rustc-version", default="unknown")
    p_report.add_argument("--cargo-version", default="unknown")
    p_report.add_argument("--backend", required=True)
    p_report.add_argument("--fixture", required=True)
    p_report.add_argument("--leg-files", nargs="+", required=True)
    p_report.add_argument("--report-json")
    p_report.add_argument("--summary-md")
    p_report.set_defaults(func=cmd_report)

    p_san = sub.add_parser("sanitize-log", help="Redact secrets from server logs")
    p_san.add_argument("input_log")
    p_san.add_argument("output_log")
    p_san.set_defaults(func=cmd_sanitize_log)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
