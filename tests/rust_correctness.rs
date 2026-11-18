//! Comprehensive Rust cache correctness and cross-root regression tests.
//!
//! Any copyright is dedicated to the Public Domain.
//! http://creativecommons.org/publicdomain/zero/1.0/

pub mod helpers;

use anyhow::{Context, Result, ensure};
use assert_cmd::prelude::*;
use fs_err as fs;
use helpers::{CARGO, SCCACHE_BIN, SccacheTest, stop_sccache};
use serde_json::Value;
use serial_test::serial;
use std::ffi::{OsStr, OsString};
#[cfg(unix)]
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug)]
struct StatsSnapshot {
    compile_requests: u64,
    rust_hits: u64,
    rust_misses: u64,
    cache_read_errors: u64,
    cache_write_errors: u64,
}

fn required_u64(obj: &serde_json::Map<String, Value>, field: &str) -> Result<u64> {
    obj.get(field)
        .and_then(Value::as_u64)
        .with_context(|| format!("missing or non-u64 stats field `{field}` in {obj:?}"))
}

fn required_rust_count(obj: &serde_json::Map<String, Value>, field: &str) -> Result<u64> {
    let counts = obj
        .get(field)
        .and_then(Value::as_object)
        .and_then(|section| section.get("counts"))
        .and_then(Value::as_object)
        .with_context(|| format!("missing `{field}.counts` object in {obj:?}"))?;
    match counts.get("Rust") {
        None => Ok(0),
        Some(v) => v
            .as_u64()
            .with_context(|| format!("non-u64 `{field}.counts.Rust`: {v}")),
    }
}

fn read_stats(test_info: &SccacheTest) -> Result<StatsSnapshot> {
    let output = test_info.show_stats()?.get_output().stdout.clone();
    let root: Value =
        serde_json::from_slice(&output).context("failed to parse sccache --show-stats JSON")?;
    let stats = root
        .get("stats")
        .and_then(Value::as_object)
        .context("missing top-level `stats` object in sccache stats JSON")?;

    let snapshot = StatsSnapshot {
        compile_requests: required_u64(stats, "compile_requests")?,
        rust_hits: required_rust_count(stats, "cache_hits")?,
        rust_misses: required_rust_count(stats, "cache_misses")?,
        cache_read_errors: required_u64(stats, "cache_read_errors")?,
        cache_write_errors: required_u64(stats, "cache_write_errors")?,
    };
    ensure!(
        snapshot.compile_requests >= snapshot.rust_hits + snapshot.rust_misses,
        "invalid stats snapshot: compile_requests ({}) < rust_hits ({}) + rust_misses ({})",
        snapshot.compile_requests,
        snapshot.rust_hits,
        snapshot.rust_misses
    );
    Ok(snapshot)
}

fn zero_stats() -> Result<()> {
    Command::new(SCCACHE_BIN.as_os_str())
        .arg("--zero-stats")
        .assert()
        .try_success()?;
    Ok(())
}

fn restart_sccache(
    test_info: &SccacheTest,
    additional_envs: Option<Vec<(OsString, OsString)>>,
) -> Result<()> {
    let cache_dir = test_info.tempdir.path().join("cache");
    stop_sccache()?;
    let mut cmd = Command::new(SCCACHE_BIN.as_os_str());
    cmd.arg("--start-server").env("SCCACHE_DIR", &cache_dir);
    if let Some(envs) = additional_envs {
        cmd.envs(envs);
    }
    cmd.assert()
        .try_success()
        .context("failed to start sccache server")?;
    Ok(())
}

fn build_cargo_command(
    test_info: &SccacheTest,
    project_dir: &Path,
    target_dir: &Path,
    basedirs: Option<&OsStr>,
    client_side: bool,
    extra_env: &[(&str, Option<&str>)],
    use_sccache: bool,
) -> Command {
    let mut cmd = Command::new(CARGO.as_os_str());
    cmd.args(["build", "--color=never"])
        .envs(test_info.env.iter().cloned())
        .env("CARGO_TARGET_DIR", target_dir)
        .env_remove("SCCACHE_BASEDIRS")
        .env_remove("SCCACHE_CLIENT_SIDE")
        .env_remove("RUSTFLAGS")
        .current_dir(project_dir);
    if !use_sccache {
        cmd.env_remove("RUSTC_WRAPPER");
    }
    if let Some(bd) = basedirs {
        cmd.env("SCCACHE_BASEDIRS", bd);
    }
    if client_side {
        cmd.env("SCCACHE_CLIENT_SIDE", "1");
    }
    for (k, v) in extra_env {
        match v {
            Some(val) => {
                cmd.env(k, val);
            }
            None => {
                cmd.env_remove(k);
            }
        }
    }
    cmd
}

fn run_cargo_build(
    test_info: &SccacheTest,
    project_dir: &Path,
    target_dir: &Path,
    basedirs: Option<&OsStr>,
    client_side: bool,
    extra_env: &[(&str, Option<&str>)],
    use_sccache: bool,
) -> Result<()> {
    build_cargo_command(
        test_info,
        project_dir,
        target_dir,
        basedirs,
        client_side,
        extra_env,
        use_sccache,
    )
    .assert()
    .try_success()?;
    Ok(())
}

fn run_cargo_run_stdout(
    test_info: &SccacheTest,
    project_dir: &Path,
    target_dir: &Path,
    basedirs: Option<&OsStr>,
    extra_env: &[(&str, Option<&str>)],
    use_sccache: bool,
) -> Result<String> {
    let mut cmd = Command::new(CARGO.as_os_str());
    cmd.args(["run", "--quiet", "--color=never"])
        .envs(test_info.env.iter().cloned())
        .env("CARGO_TARGET_DIR", target_dir)
        .env_remove("SCCACHE_BASEDIRS")
        .env_remove("RUSTFLAGS")
        .current_dir(project_dir);
    if !use_sccache {
        cmd.env_remove("RUSTC_WRAPPER");
    }
    if let Some(bd) = basedirs {
        cmd.env("SCCACHE_BASEDIRS", bd);
    }
    for (k, v) in extra_env {
        match v {
            Some(val) => {
                cmd.env(k, val);
            }
            None => {
                cmd.env_remove(k);
            }
        }
    }
    let out = cmd.assert().try_success()?.get_output().stdout.clone();
    String::from_utf8(out).context("binary output was not UTF-8")
}

fn clean_dir_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_dir_all(path)?;
    }
    Ok(())
}

fn collect_debug_files_with_ext(
    target_dir: &Path,
    file_prefix: &str,
    ext: &str,
) -> Result<Vec<PathBuf>> {
    let debug_dir = target_dir.join("debug");
    let mut files = Vec::new();
    for entry in walkdir::WalkDir::new(&debug_dir) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if path.extension().is_some_and(|e| e == ext)
            && path
                .file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with(file_prefix))
        {
            files.push(path.to_path_buf());
        }
    }
    files.sort();
    ensure!(
        !files.is_empty(),
        "no .{ext} files matching {file_prefix} in {}",
        debug_dir.display()
    );
    Ok(files)
}

fn assert_files_lack_path(files: &[PathBuf], forbidden: &Path) -> Result<()> {
    let needle = forbidden.to_string_lossy().as_bytes().to_vec();
    for file in files {
        let bytes = fs::read(file)?;
        ensure!(
            !bytes
                .windows(needle.len())
                .any(|window| window == needle.as_slice()),
            "foreign root {} leaked into {}",
            forbidden.display(),
            file.display()
        );
    }
    Ok(())
}

fn assert_files_contain_path(files: &[PathBuf], expected: &Path) -> Result<()> {
    let needle = expected.to_string_lossy().as_bytes().to_vec();
    for file in files {
        let bytes = fs::read(file)?;
        ensure!(
            bytes
                .windows(needle.len())
                .any(|window| window == needle.as_slice()),
            "expected root {} absent from {}",
            expected.display(),
            file.display()
        );
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn debug_comp_dirs(rlib: &Path) -> Result<Vec<String>> {
    let temp = tempfile::tempdir()?;
    Command::new("ar")
        .arg("x")
        .arg(rlib)
        .current_dir(temp.path())
        .assert()
        .try_success()?;
    let mut dirs = Vec::new();
    for entry in fs::read_dir(temp.path())? {
        let object = entry?.path();
        if object.extension().is_none_or(|ext| ext != "o") {
            continue;
        }
        let output = Command::new("readelf")
            .args(["--debug-dump=info"])
            .arg(&object)
            .output()
            .context("failed to run readelf")?;
        ensure!(
            output.status.success(),
            "readelf failed for {}",
            object.display()
        );
        let text = String::from_utf8_lossy(&output.stdout);
        for line in text.lines() {
            if let Some((_, dir)) = line.rsplit_once("DW_AT_comp_dir")
                && let Some((_, dir)) = dir.rsplit_once(": ")
            {
                dirs.push(dir.trim().to_owned());
            }
        }
    }
    ensure!(!dirs.is_empty(), "no DW_AT_comp_dir in {}", rlib.display());
    dirs.sort();
    dirs.dedup();
    Ok(dirs)
}

#[cfg(unix)]
fn collect_dep_info_files(target_dir: &Path, crate_prefix: &str) -> Result<Vec<PathBuf>> {
    collect_debug_files_with_ext(target_dir, crate_prefix, "d")
}

#[cfg(unix)]
fn escape_make_path(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        if matches!(ch, ' ' | '#' | '\\' | '$') {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

#[cfg(unix)]
fn assert_dep_info_clean(
    target_dir: &Path,
    crate_prefix: &str,
    forbidden_roots: &[&Path],
    expected_root: &Path,
) -> Result<()> {
    let files = collect_dep_info_files(target_dir, crate_prefix)?;
    let expected_raw = expected_root.to_str().unwrap();
    let expected_escaped = escape_make_path(expected_raw);

    for path in files {
        let bytes = fs::read(&path)?;
        ensure!(
            !bytes.contains(&0x01) && !bytes.contains(&0x02),
            "unresolved dep-info marker byte remained in {}",
            path.display()
        );
        let text = String::from_utf8(bytes)?;
        for forbidden in forbidden_roots {
            let f_raw = forbidden.to_str().unwrap();
            let f_escaped = escape_make_path(f_raw);
            ensure!(
                !text.contains(f_raw) && !text.contains(&f_escaped),
                "foreign root {f_raw} leaked into {}:\n{text}",
                path.display()
            );
        }
        ensure!(
            text.contains(expected_raw) || text.contains(&expected_escaped),
            "expected root {expected_raw} absent from {}:\n{text}",
            path.display()
        );
    }
    Ok(())
}

#[test]
#[serial]
fn test_env_and_option_env_cache_correctness() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let project = test_info.tempdir.path().join("env-macro-proj");
    fs::create_dir_all(project.join("src"))?;
    fs::write(
        project.join("Cargo.toml"),
        "[package]\nname = \"env-macro-test\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
    )?;
    fs::write(
        project.join("src/lib.rs"),
        r#"pub fn required() -> &'static str {
    env!("CUSTOM_BUILD_TOKEN")
}

pub fn optional() -> Option<&'static str> {
    option_env!("OPTIONAL_BUILD_TOKEN")
}
"#,
    )?;
    fs::write(
        project.join("src/main.rs"),
        r#"fn main() {
    println!(
        "required={};optional={:?}",
        env_macro_test::required(),
        env_macro_test::optional()
    );
}
"#,
    )?;

    let uncached_target = project.join("target-uncached");
    let cached_target = project.join("target-cached");

    // Reference outputs without sccache.
    for (req, opt, expected) in [
        ("v1", None, "required=v1;optional=None"),
        ("v1", Some(""), "required=v1;optional=Some(\"\")"),
        ("v1", Some("alpha"), "required=v1;optional=Some(\"alpha\")"),
    ] {
        clean_dir_if_exists(&uncached_target)?;
        let extra = [
            ("CUSTOM_BUILD_TOKEN", Some(req)),
            ("OPTIONAL_BUILD_TOKEN", opt),
        ];
        let out =
            run_cargo_run_stdout(&test_info, &project, &uncached_target, None, &extra, false)?;
        assert_eq!(out.trim(), expected);
    }

    // Leg 1: Cold compile with OPTIONAL_BUILD_TOKEN unset (None).
    zero_stats()?;
    let env_unset = [
        ("CUSTOM_BUILD_TOKEN", Some("v1")),
        ("OPTIONAL_BUILD_TOKEN", None),
    ];
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_unset,
        true,
    )?;
    let s1 = read_stats(&test_info)?;
    assert_eq!(s1.rust_hits, 0);
    assert_eq!(s1.rust_misses, 1);
    assert_eq!(s1.cache_read_errors, 0);
    assert_eq!(s1.cache_write_errors, 0);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_unset, true)?.trim(),
        "required=v1;optional=None"
    );

    // Leg 2: Rebuild with OPTIONAL_BUILD_TOKEN still unset -> must hit.
    clean_dir_if_exists(&cached_target)?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_unset,
        true,
    )?;
    let s2 = read_stats(&test_info)?;
    assert_eq!(s2.rust_hits, 1);
    assert_eq!(s2.rust_misses, 0);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_unset, true)?.trim(),
        "required=v1;optional=None"
    );

    // Leg 3: OPTIONAL_BUILD_TOKEN="" (Some("")) MUST miss against unset (None)!
    clean_dir_if_exists(&cached_target)?;
    zero_stats()?;
    let env_empty = [
        ("CUSTOM_BUILD_TOKEN", Some("v1")),
        ("OPTIONAL_BUILD_TOKEN", Some("")),
    ];
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_empty,
        true,
    )?;
    let s3 = read_stats(&test_info)?;
    assert_eq!(
        s3.rust_hits, 0,
        "option_env! Some(\"\") must not false-hit cached None entry"
    );
    assert_eq!(s3.rust_misses, 1);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_empty, true)?.trim(),
        "required=v1;optional=Some(\"\")"
    );

    // Leg 4: Rebuild with OPTIONAL_BUILD_TOKEN="" -> must hit the Some("") entry.
    clean_dir_if_exists(&cached_target)?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_empty,
        true,
    )?;
    let s4 = read_stats(&test_info)?;
    assert_eq!(s4.rust_hits, 1);
    assert_eq!(s4.rust_misses, 0);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_empty, true)?.trim(),
        "required=v1;optional=Some(\"\")"
    );

    // Leg 5: OPTIONAL_BUILD_TOKEN="alpha" -> must miss and embed "alpha".
    clean_dir_if_exists(&cached_target)?;
    zero_stats()?;
    let env_alpha = [
        ("CUSTOM_BUILD_TOKEN", Some("v1")),
        ("OPTIONAL_BUILD_TOKEN", Some("alpha")),
    ];
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_alpha,
        true,
    )?;
    let s5 = read_stats(&test_info)?;
    assert_eq!(s5.rust_hits, 0);
    assert_eq!(s5.rust_misses, 1);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_alpha, true)?.trim(),
        "required=v1;optional=Some(\"alpha\")"
    );

    // Leg 6: OPTIONAL_BUILD_TOKEN="beta" -> must miss and embed "beta".
    clean_dir_if_exists(&cached_target)?;
    zero_stats()?;
    let env_beta = [
        ("CUSTOM_BUILD_TOKEN", Some("v1")),
        ("OPTIONAL_BUILD_TOKEN", Some("beta")),
    ];
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_beta,
        true,
    )?;
    let s6 = read_stats(&test_info)?;
    assert_eq!(s6.rust_hits, 0);
    assert_eq!(s6.rust_misses, 1);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_beta, true)?.trim(),
        "required=v1;optional=Some(\"beta\")"
    );

    // Leg 7: CUSTOM_BUILD_TOKEN="v2" -> env! change must miss and embed "v2".
    clean_dir_if_exists(&cached_target)?;
    zero_stats()?;
    let env_v2 = [
        ("CUSTOM_BUILD_TOKEN", Some("v2")),
        ("OPTIONAL_BUILD_TOKEN", Some("beta")),
    ];
    run_cargo_build(
        &test_info,
        &project,
        &cached_target,
        None,
        false,
        &env_v2,
        true,
    )?;
    let s7 = read_stats(&test_info)?;
    assert_eq!(s7.rust_hits, 0);
    assert_eq!(s7.rust_misses, 1);
    assert_eq!(
        run_cargo_run_stdout(&test_info, &project, &cached_target, None, &env_v2, true)?.trim(),
        "required=v2;optional=Some(\"beta\")"
    );

    Ok(())
}

#[test]
#[serial]
fn test_cross_root_safe_reuse_and_manifest_dir_isolation() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("safe_lib/src"))?;
        fs::create_dir_all(proj.join("manifest_lib/src"))?;
        fs::create_dir_all(proj.join("app/src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[workspace]\nmembers = [\"safe_lib\", \"manifest_lib\", \"app\"]\nresolver = \"2\"\n",
        )?;
        fs::write(
            proj.join("safe_lib/Cargo.toml"),
            "[package]\nname = \"safe_lib\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(
            proj.join("safe_lib/src/lib.rs"),
            "pub fn compute(x: u32) -> u32 { x * 3 + 7 }\n",
        )?;
        fs::write(
            proj.join("manifest_lib/Cargo.toml"),
            "[package]\nname = \"manifest_lib\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\nsafe_lib = { path = \"../safe_lib\" }\n",
        )?;
        fs::write(
            proj.join("manifest_lib/src/lib.rs"),
            "pub fn compute(x: u32) -> u32 { safe_lib::compute(x) }\npub fn manifest() -> &'static str { env!(\"CARGO_MANIFEST_DIR\") }\n",
        )?;
        fs::write(
            proj.join("app/Cargo.toml"),
            "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\nsafe_lib = { path = \"../safe_lib\" }\nmanifest_lib = { path = \"../manifest_lib\" }\n",
        )?;
        fs::write(
            proj.join("app/src/main.rs"),
            "fn main() {\n    println!(\"{}|{}\", safe_lib::compute(5), manifest_lib::manifest());\n}\n",
        )?;
    }

    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    let remap_a = format!("--remap-path-prefix={}=/topsrc", slot_a.display());
    let remap_b = format!("--remap-path-prefix={}=/topsrc", slot_b.display());

    // Reference uncached output in slot_b.
    let uncached_out = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target-uncached"),
        None,
        &[("RUSTFLAGS", Some(&remap_b))],
        false,
    )?;
    let (uncached_val, uncached_manifest) = uncached_out
        .trim()
        .split_once('|')
        .context("unexpected app output")?;
    assert_eq!(uncached_val, "22");
    assert_eq!(
        fs::canonicalize(uncached_manifest)?,
        fs::canonicalize(proj_b.join("manifest_lib"))?
    );

    // Build slot_a with SCCACHE_BASEDIRS=slot_a.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    assert_eq!(sa.rust_hits, 0);
    assert_eq!(sa.rust_misses, 2);

    // Build slot_b with SCCACHE_BASEDIRS=slot_b:
    // safe_lib must HIT; manifest_lib (embeds CARGO_MANIFEST_DIR) must MISS.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    let cached_out = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let (cached_val, cached_manifest) = cached_out
        .trim()
        .split_once('|')
        .context("unexpected cached app output")?;
    assert_eq!(cached_val, "22");
    assert_eq!(
        fs::canonicalize(cached_manifest)?,
        fs::canonicalize(proj_b.join("manifest_lib"))?,
        "false cache hit: slot_b binary embedded foreign CARGO_MANIFEST_DIR"
    );
    assert_ne!(
        fs::canonicalize(cached_manifest)?,
        fs::canonicalize(proj_a.join("manifest_lib"))?
    );

    assert_eq!(
        sb.rust_hits, 1,
        "safe_lib must reuse slot_a cache in slot_b (and manifest_lib must not)"
    );
    assert_eq!(
        sb.rust_misses, 1,
        "manifest_lib must miss instead of serving slot_a's CARGO_MANIFEST_DIR"
    );
    assert_eq!(sb.cache_read_errors, 0);
    assert_eq!(sb.cache_write_errors, 0);

    #[cfg(unix)]
    assert_dep_info_clean(&proj_b.join("target"), "safe_lib", &[&slot_a], &slot_b)?;

    Ok(())
}

#[test]
#[serial]
fn test_build_rs_out_dir_and_include_macros() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("asset_inc/src/assets"))?;
        fs::create_dir_all(proj.join("codegen_out/src"))?;
        fs::create_dir_all(proj.join("runner/src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[workspace]\nmembers = [\"asset_inc\", \"codegen_out\", \"runner\"]\nresolver = \"2\"\n",
        )?;
        fs::write(
            proj.join("asset_inc/Cargo.toml"),
            "[package]\nname = \"asset_inc\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(proj.join("asset_inc/src/assets/msg.txt"), "hello-v1")?;
        fs::write(proj.join("asset_inc/src/assets/data.bin"), [1u8, 2, 3, 4])?;
        fs::write(
            proj.join("asset_inc/src/lib.rs"),
            r#"pub fn text() -> &'static str {
    include_str!("assets/msg.txt")
}
pub fn sum_bytes() -> u32 {
    include_bytes!("assets/data.bin").iter().map(|b| u32::from(*b)).sum()
}
"#,
        )?;
        fs::write(
            proj.join("codegen_out/Cargo.toml"),
            "[package]\nname = \"codegen_out\"\nversion = \"0.1.0\"\nedition = \"2024\"\nbuild = \"build.rs\"\n",
        )?;
        fs::write(
            proj.join("codegen_out/build.rs"),
            r#"use std::env;
use std::fs;
use std::path::Path;
fn main() {
    let out = env::var("OUT_DIR").unwrap();
    fs::write(Path::new(&out).join("generated.rs"), "pub const GEN_VAL: u32 = 100;\n").unwrap();
    println!("cargo:rerun-if-changed=build.rs");
}
"#,
        )?;
        fs::write(
            proj.join("codegen_out/src/lib.rs"),
            r#"include!(concat!(env!("OUT_DIR"), "/generated.rs"));
pub fn gen_val() -> u32 { GEN_VAL }
pub fn out_dir() -> &'static str { env!("OUT_DIR") }
"#,
        )?;
        fs::write(
            proj.join("runner/Cargo.toml"),
            "[package]\nname = \"runner\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\nasset_inc = { path = \"../asset_inc\" }\ncodegen_out = { path = \"../codegen_out\" }\n",
        )?;
        fs::write(
            proj.join("runner/src/main.rs"),
            r#"fn main() {
    println!(
        "{}|{}|{}|{}",
        asset_inc::text(),
        asset_inc::sum_bytes(),
        codegen_out::gen_val(),
        codegen_out::out_dir()
    );
}
"#,
        )?;
    }

    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    let remap_a = format!("--remap-path-prefix={}=/topsrc", slot_a.display());
    let remap_b = format!("--remap-path-prefix={}=/topsrc", slot_b.display());

    // 1. Cold build in slot_a.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let s1 = read_stats(&test_info)?;
    assert_eq!(s1.rust_hits, 0);
    assert_eq!(s1.rust_misses, 2);

    // 2. Same-root warm rebuild in slot_a after deleting target: both asset_inc & codegen_out hit.
    clean_dir_if_exists(&proj_a.join("target"))?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let s2 = read_stats(&test_info)?;
    assert_eq!(s2.rust_hits, 2);
    assert_eq!(s2.rust_misses, 0);

    // 3. Modify include_str!/include_bytes! inputs in slot_a -> asset_inc must miss, codegen_out hits.
    fs::write(proj_a.join("asset_inc/src/assets/msg.txt"), "hello-v2")?;
    fs::write(proj_a.join("asset_inc/src/assets/data.bin"), [10u8, 20, 30])?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let s3 = read_stats(&test_info)?;
    assert_eq!(s3.rust_hits, 0);
    assert_eq!(s3.rust_misses, 1);

    let out_a = run_cargo_run_stdout(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let parts_a: Vec<&str> = out_a.trim().split('|').collect();
    assert_eq!(parts_a[0], "hello-v2");
    assert_eq!(parts_a[1], "60");
    assert_eq!(parts_a[2], "100");

    // 4. Modify build.rs generated code in slot_a -> codegen_out must miss and reflect new value.
    fs::write(
        proj_a.join("codegen_out/build.rs"),
        r#"use std::env;
use std::fs;
use std::path::Path;
fn main() {
    let out = env::var("OUT_DIR").unwrap();
    fs::write(Path::new(&out).join("generated.rs"), "pub const GEN_VAL: u32 = 250;\n").unwrap();
    println!("cargo:rerun-if-changed=build.rs");
}
"#,
    )?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let s4 = read_stats(&test_info)?;
    assert_eq!(s4.rust_hits, 0);
    assert_eq!(s4.rust_misses, 1);
    let out_a2 = run_cargo_run_stdout(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    assert!(out_a2.contains("|250|"), "unexpected out_a2: {out_a2}");

    // 5. Cross-root build in slot_b: asset_inc has "hello-v1" (already cached from step 1) -> HIT,
    //    while codegen_out (depends on OUT_DIR env-dep) MUST MISS and report slot_b's OUT_DIR.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let s5 = read_stats(&test_info)?;
    assert_eq!(s5.rust_hits, 1, "asset_inc should reuse slot_a v1 entry");
    assert_eq!(
        s5.rust_misses, 1,
        "codegen_out must miss across roots because OUT_DIR env-dep differs"
    );

    let out_b = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let parts_b: Vec<&str> = out_b.trim().split('|').collect();
    assert_eq!(parts_b[0], "hello-v1");
    assert_eq!(parts_b[1], "10");
    assert_eq!(parts_b[2], "100");
    assert!(
        fs::canonicalize(parts_b[3])?.starts_with(&slot_b),
        "OUT_DIR {} did not belong to {}",
        parts_b[3],
        slot_b.display()
    );
    assert!(!fs::canonicalize(parts_b[3])?.starts_with(&slot_a));

    Ok(())
}

#[test]
#[serial]
fn test_proc_macro_and_remap_path_prefix_cross_root() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    let write_ws = |slot: &Path, macro_val: u32| -> Result<()> {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("remap_lib/src"))?;
        fs::create_dir_all(proj.join("pm_gen/src"))?;
        fs::create_dir_all(proj.join("pm_consumer/src"))?;
        fs::create_dir_all(proj.join("pm_bin/src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[workspace]\nmembers = [\"remap_lib\", \"pm_gen\", \"pm_consumer\", \"pm_bin\"]\nresolver = \"2\"\n",
        )?;
        fs::write(
            proj.join("remap_lib/Cargo.toml"),
            "[package]\nname = \"remap_lib\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(
            proj.join("remap_lib/src/lib.rs"),
            "pub fn remapped_loc() -> &'static str { std::panic::Location::caller().file() }\n",
        )?;
        fs::write(
            proj.join("pm_gen/Cargo.toml"),
            "[package]\nname = \"pm_gen\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[lib]\nproc-macro = true\n",
        )?;
        fs::write(
            proj.join("pm_gen/src/lib.rs"),
            format!(
                "use proc_macro::TokenStream;\n#[proc_macro]\npub fn make_value(_: TokenStream) -> TokenStream {{\n    \"{macro_val}_u32\".parse().unwrap()\n}}\n"
            ),
        )?;
        fs::write(
            proj.join("pm_consumer/Cargo.toml"),
            "[package]\nname = \"pm_consumer\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\npm_gen = { path = \"../pm_gen\" }\n",
        )?;
        fs::write(
            proj.join("pm_consumer/src/lib.rs"),
            "#[inline(never)]\npub fn val() -> u32 { pm_gen::make_value!() }\npub fn loc() -> &'static str { std::panic::Location::caller().file() }\n",
        )?;
        fs::write(
            proj.join("pm_bin/Cargo.toml"),
            "[package]\nname = \"pm_bin\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\nremap_lib = { path = \"../remap_lib\" }\npm_consumer = { path = \"../pm_consumer\" }\n",
        )?;
        fs::write(
            proj.join("pm_bin/src/main.rs"),
            "fn main() { println!(\"{}|{}|{}\", pm_consumer::val(), pm_consumer::loc(), remap_lib::remapped_loc()); }\n",
        )?;
        Ok(())
    };

    write_ws(&slot_a, 42)?;
    write_ws(&slot_b, 42)?;
    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");

    let remap_a = format!("--remap-path-prefix={}=/topsrc", slot_a.display());
    let remap_b = format!("--remap-path-prefix={}=/topsrc", slot_b.display());

    // 1. Build slot_a with remap + basedirs.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    assert_eq!(sa.rust_hits, 0);
    assert_eq!(
        sa.rust_misses, 2,
        "remap_lib and pm_consumer rlibs should be cacheable"
    );

    // 2a. Build remap_lib first in slot_b: must HIT across roots on every OS.
    zero_stats()?;
    build_cargo_command(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )
    .args(["-p", "remap_lib"])
    .assert()
    .try_success()?;
    let sb_remap = read_stats(&test_info)?;
    assert_eq!(
        sb_remap.rust_hits, 1,
        "remap_lib should hit across roots when source/remap/basedirs match"
    );
    assert_eq!(sb_remap.rust_misses, 0);

    // 2b. Finish building slot_b (pm_gen + pm_consumer + pm_bin).
    // The proc macro can observe its process environment and spans without a
    // dep-info entry, so its consumers are never reused across roots.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let sb_pm = read_stats(&test_info)?;
    assert_eq!(
        sb_pm.rust_hits, 0,
        "pm_consumer must not be reused across roots"
    );
    assert_eq!(sb_pm.rust_misses, 1);

    // Ensure slot_b's rlibs do not contain raw slot_a path bytes.
    let slot_a_bytes = slot_a.to_string_lossy().as_bytes().to_vec();
    for rlib_b in collect_debug_files_with_ext(&proj_b.join("target"), "libremap_lib", "rlib")?
        .into_iter()
        .chain(collect_debug_files_with_ext(
            &proj_b.join("target"),
            "libpm_consumer",
            "rlib",
        )?)
    {
        let rlib_bytes = fs::read(&rlib_b)?;
        ensure!(
            !rlib_bytes
                .windows(slot_a_bytes.len())
                .any(|w| w == slot_a_bytes.as_slice()),
            "slot_a path leaked into {}",
            rlib_b.display()
        );
    }

    let out_b = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    assert!(out_b.starts_with("42|"), "unexpected output: {out_b}");

    // 3. Changing RUSTFLAGS remap replacement target must cause a cache miss for both rlibs.
    let remap_b_other = format!(
        "--remap-path-prefix={}=/other_src -C opt-level=1",
        slot_b.display()
    );
    clean_dir_if_exists(&proj_b.join("target"))?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b_other))],
        true,
    )?;
    let s_flags = read_stats(&test_info)?;
    assert_eq!(s_flags.rust_hits, 0);
    assert_eq!(s_flags.rust_misses, 2);

    // 4. Changing proc-macro output must invalidate pm_consumer while remap_lib stays unaffected.
    fs::write(
        proj_b.join("pm_gen/src/lib.rs"),
        "use proc_macro::TokenStream;\n#[proc_macro]\npub fn make_value(_: TokenStream) -> TokenStream {\n    \"99_u32\".parse().unwrap()\n}\n",
    )?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b_other))],
        true,
    )?;
    let s_pm = read_stats(&test_info)?;
    assert_eq!(s_pm.rust_hits, 0);
    assert_eq!(s_pm.rust_misses, 1);
    let out_b2 = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_b_other))],
        true,
    )?;
    assert!(out_b2.starts_with("99|"), "unexpected output: {out_b2}");

    Ok(())
}

#[test]
#[serial]
fn test_proc_macro_untracked_root_lookups_are_not_reused_across_roots() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    let write_ws = |slot: &Path| -> Result<()> {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("pm_gen/src"))?;
        fs::create_dir_all(proj.join("consumer/src"))?;
        fs::create_dir_all(proj.join("runner/src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[workspace]\nmembers = [\"pm_gen\", \"consumer\", \"runner\"]\nresolver = \"2\"\n",
        )?;
        fs::write(
            proj.join("pm_gen/Cargo.toml"),
            "[package]\nname = \"pm_gen\"\nversion = \"0.1.0\"\nedition = \"2021\"\n[lib]\nproc-macro = true\n",
        )?;
        // Neither lookup is reported by rustc's dep-info: the macro process reads
        // them directly instead of going through env!/option_env!.
        fs::write(
            proj.join("pm_gen/src/lib.rs"),
            r#"use proc_macro::TokenStream;

#[proc_macro]
pub fn make_roots(_: TokenStream) -> TokenStream {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let cwd = std::env::current_dir().unwrap().display().to_string();
    format!(
        "pub fn manifest() -> &'static str {{ {:?} }}\npub fn cwd() -> &'static str {{ {:?} }}",
        manifest, cwd
    )
    .parse()
    .unwrap()
}
"#,
        )?;
        fs::write(
            proj.join("consumer/Cargo.toml"),
            "[package]\nname = \"consumer\"\nversion = \"0.1.0\"\nedition = \"2021\"\n[dependencies]\npm_gen = { path = \"../pm_gen\" }\n",
        )?;
        fs::write(
            proj.join("consumer/src/lib.rs"),
            "pm_gen::make_roots!();\npub fn roots() -> (&'static str, &'static str) { (manifest(), cwd()) }\n",
        )?;
        fs::write(
            proj.join("runner/Cargo.toml"),
            "[package]\nname = \"runner\"\nversion = \"0.1.0\"\nedition = \"2021\"\n[dependencies]\nconsumer = { path = \"../consumer\" }\n",
        )?;
        fs::write(
            proj.join("runner/src/main.rs"),
            "fn main() { let (m, c) = consumer::roots(); println!(\"{m}|{c}\"); }\n",
        )?;
        Ok(())
    };

    write_ws(&slot_a)?;
    write_ws(&slot_b)?;
    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");

    let remap_a = format!("--remap-path-prefix={}=/topsrc", slot_a.display());
    let remap_b = format!("--remap-path-prefix={}=/topsrc", slot_b.display());

    // Reference output from a direct, uncached build in slot-b.
    let uncached_out = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target-uncached"),
        None,
        &[("RUSTFLAGS", Some(&remap_b))],
        false,
    )?;
    ensure!(
        uncached_out.trim().starts_with(slot_b.to_str().unwrap()),
        "unexpected uncached output: {uncached_out}"
    );
    ensure!(!uncached_out.contains(slot_a.to_str().unwrap()));

    // The proc-macro dylib is reproducible with the same remap, so the consumer
    // would otherwise hit across roots. Its output is root-dependent through the
    // macro's untracked reads and must not be reused.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    ensure!(sa.rust_hits == 0, "unexpected slot-a hits: {sa:?}");
    ensure!(sa.rust_misses == 1, "unexpected slot-a misses: {sa:?}");

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    ensure!(
        sb.rust_hits == 0,
        "proc-macro consumer must not hit across roots: {sb:?}"
    );
    ensure!(
        sb.rust_misses == 1,
        "proc-macro consumer must be rebuilt in the consuming root: {sb:?}"
    );

    let consumer_rlibs =
        collect_debug_files_with_ext(&proj_b.join("target"), "libconsumer", "rlib")?;
    assert_files_lack_path(&consumer_rlibs, &slot_a)?;

    let cached_out = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    ensure!(
        cached_out == uncached_out,
        "cached slot-b output {cached_out:?} differs from uncached {uncached_out:?}"
    );
    ensure!(!cached_out.contains(slot_a.to_str().unwrap()));

    Ok(())
}

#[test]
#[serial]
fn test_debuginfo_without_remap_is_not_reused_across_roots() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[package]\nname = \"debug_lib\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
        )?;
        fs::write(
            proj.join("src/lib.rs"),
            "#[inline(never)]\npub fn add(a: u32, b: u32) -> u32 { a.wrapping_add(b) }\n",
        )?;
    }

    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    let debuginfo = ["-C", "debuginfo=2"].join(" ");
    let flags = [("RUSTFLAGS", Some(debuginfo.as_str()))];

    // Reference debug info from a direct build in slot-b.
    let uncached_target = proj_b.join("target-uncached");
    run_cargo_build(
        &test_info,
        &proj_b,
        &uncached_target,
        None,
        false,
        &flags,
        false,
    )?;

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &flags,
        true,
    )?;
    let sa = read_stats(&test_info)?;
    ensure!(sa.rust_hits == 0 && sa.rust_misses == 1, "{sa:?}");

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &flags,
        true,
    )?;
    let sb = read_stats(&test_info)?;
    ensure!(
        sb.rust_hits == 0 && sb.rust_misses == 1,
        "debug build without a covering remap must miss across roots: {sb:?}"
    );

    let cached = collect_debug_files_with_ext(&proj_b.join("target"), "libdebug_lib", "rlib")?;
    let uncached = collect_debug_files_with_ext(&uncached_target, "libdebug_lib", "rlib")?;
    assert_files_lack_path(&cached, &slot_a)?;
    assert_files_contain_path(&cached, &slot_b)?;

    #[cfg(target_os = "linux")]
    for rlib in &cached {
        ensure!(
            debug_comp_dirs(rlib)? == debug_comp_dirs(&uncached[0])?,
            "cached debug info {} differs from the local build",
            rlib.display()
        );
    }

    Ok(())
}

#[test]
#[serial]
fn test_debuginfo_with_remap_is_reused_across_roots() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[package]\nname = \"debug_lib\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
        )?;
        fs::write(
            proj.join("src/lib.rs"),
            "#[inline(never)]\npub fn add(a: u32, b: u32) -> u32 { a.wrapping_add(b) }\n",
        )?;
    }

    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    let flags_a = format!(
        "-C debuginfo=2 --remap-path-prefix={}=/topsrc",
        slot_a.display()
    );
    let flags_b = format!(
        "-C debuginfo=2 --remap-path-prefix={}=/topsrc",
        slot_b.display()
    );

    let uncached_target = proj_b.join("target-uncached");
    run_cargo_build(
        &test_info,
        &proj_b,
        &uncached_target,
        None,
        false,
        &[("RUSTFLAGS", Some(&flags_b))],
        false,
    )?;

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&flags_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    ensure!(sa.rust_hits == 0 && sa.rust_misses == 1, "{sa:?}");

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&flags_b))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    ensure!(
        sb.rust_hits == 1 && sb.rust_misses == 0,
        "a remapped debug build should reuse the cache: {sb:?}"
    );

    let cached = collect_debug_files_with_ext(&proj_b.join("target"), "libdebug_lib", "rlib")?;
    let uncached = collect_debug_files_with_ext(&uncached_target, "libdebug_lib", "rlib")?;
    assert_files_lack_path(&cached, &slot_a)?;
    assert_files_lack_path(&cached, &slot_b)?;
    assert_files_contain_path(&cached, Path::new("/topsrc"))?;

    #[cfg(target_os = "linux")]
    for rlib in &cached {
        ensure!(
            debug_comp_dirs(rlib)? == debug_comp_dirs(&uncached[0])?,
            "cached debug info {} differs from the local build",
            rlib.display()
        );
        ensure!(
            debug_comp_dirs(rlib)?
                .iter()
                .all(|dir| dir.starts_with("/topsrc")),
            "cached debug info {} was not remapped",
            rlib.display()
        );
    }

    Ok(())
}

#[test]
#[serial]
fn test_broad_remap_does_not_allow_cross_root_reuse() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let common = fs::canonicalize(test_info.tempdir.path())?;
    let slot_a = common.join("slot-a");
    let slot_b = common.join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[package]\nname = \"debug_lib\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
        )?;
        fs::write(
            proj.join("src/lib.rs"),
            "#[inline(never)]\npub fn add(a: u32, b: u32) -> u32 { a.wrapping_add(b) }\n",
        )?;
    }

    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    // One remap for both roots. It removes the shared parent but keeps the
    // per-root slot directory in the artifact.
    let flags = format!(
        "-C debuginfo=2 --remap-path-prefix={}=/shared",
        common.display()
    );

    let uncached_target = proj_b.join("target-uncached");
    run_cargo_build(
        &test_info,
        &proj_b,
        &uncached_target,
        None,
        false,
        &[("RUSTFLAGS", Some(&flags))],
        false,
    )?;

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&flags))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    ensure!(sa.rust_hits == 0 && sa.rust_misses == 1, "{sa:?}");

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&flags))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    ensure!(
        sb.rust_hits == 0 && sb.rust_misses == 1,
        "a remap that leaves the slot directory must miss across roots: {sb:?}"
    );

    let cached = collect_debug_files_with_ext(&proj_b.join("target"), "libdebug_lib", "rlib")?;
    let uncached = collect_debug_files_with_ext(&uncached_target, "libdebug_lib", "rlib")?;
    let slot_a_in_artifact =
        Path::new("/shared").join(slot_a.file_name().context("slot-a has no file name")?);
    let slot_b_in_artifact =
        Path::new("/shared").join(slot_b.file_name().context("slot-b has no file name")?);
    assert_files_lack_path(&cached, &slot_a_in_artifact)?;
    assert_files_contain_path(&cached, &slot_b_in_artifact)?;

    #[cfg(target_os = "linux")]
    for rlib in &cached {
        ensure!(
            debug_comp_dirs(rlib)? == debug_comp_dirs(&uncached[0])?,
            "cached debug info {} differs from the local build",
            rlib.display()
        );
    }

    Ok(())
}

#[test]
#[serial]
fn test_later_broad_remap_does_not_allow_cross_root_reuse() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let common = fs::canonicalize(test_info.tempdir.path())?;
    let slot_a = common.join("slot-a");
    let slot_b = common.join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[package]\nname = \"debug_lib\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
        )?;
        fs::write(
            proj.join("src/lib.rs"),
            "#[inline(never)]\npub fn add(a: u32, b: u32) -> u32 { a.wrapping_add(b) }\n",
        )?;
    }

    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    // rustc applies the last matching remap, so the root-specific remap is
    // overridden by the shared-parent remap that follows it.
    let flags_a = format!(
        "-C debuginfo=2 --remap-path-prefix={}=/topsrc --remap-path-prefix={}=/shared",
        slot_a.display(),
        common.display()
    );
    let flags_b = format!(
        "-C debuginfo=2 --remap-path-prefix={}=/topsrc --remap-path-prefix={}=/shared",
        slot_b.display(),
        common.display()
    );

    let uncached_target = proj_b.join("target-uncached");
    run_cargo_build(
        &test_info,
        &proj_b,
        &uncached_target,
        None,
        false,
        &[("RUSTFLAGS", Some(&flags_b))],
        false,
    )?;

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&flags_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    ensure!(sa.rust_hits == 0 && sa.rust_misses == 1, "{sa:?}");

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&flags_b))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    ensure!(
        sb.rust_hits == 0 && sb.rust_misses == 1,
        "a later remap that overrides the root remap must miss across roots: {sb:?}"
    );

    let cached = collect_debug_files_with_ext(&proj_b.join("target"), "libdebug_lib", "rlib")?;
    let uncached = collect_debug_files_with_ext(&uncached_target, "libdebug_lib", "rlib")?;
    let slot_a_in_artifact =
        Path::new("/shared").join(slot_a.file_name().context("slot-a has no file name")?);
    let slot_b_in_artifact =
        Path::new("/shared").join(slot_b.file_name().context("slot-b has no file name")?);
    assert_files_lack_path(&cached, &slot_a_in_artifact)?;
    assert_files_contain_path(&cached, &slot_b_in_artifact)?;

    #[cfg(target_os = "linux")]
    for rlib in &cached {
        ensure!(
            debug_comp_dirs(rlib)? == debug_comp_dirs(&uncached[0])?,
            "cached debug info {} differs from the local build",
            rlib.display()
        );
    }

    Ok(())
}

#[cfg(unix)]
#[test]
#[serial]
fn test_paths_with_spaces_and_unicode_and_dep_info_integrity() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot A 日本語");
    let slot_b = test_info.tempdir.path().join("slot B 日本語");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("my project");
        fs::create_dir_all(proj.join("src/sub dir"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[package]\nname = \"unicode_space_test\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(proj.join("src/sub dir/msg 挨拶.txt"), "こんにちは v1")?;
        fs::write(
            proj.join("src/sub dir/helper 補助.rs"),
            "pub fn greeting() -> &'static str { include_str!(\"msg 挨拶.txt\") }\n",
        )?;
        fs::write(
            proj.join("src/lib.rs"),
            "#[path = \"sub dir/helper 補助.rs\"]\npub mod helper;\n",
        )?;
        fs::write(
            proj.join("src/main.rs"),
            "fn main() { println!(\"{}\", unicode_space_test::helper::greeting()); }\n",
        )?;
    }

    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("my project");
    let proj_b = slot_b.join("my project");
    // CARGO_ENCODED_RUSTFLAGS keeps the path with spaces as one argument.
    let encoded_a = format!("--remap-path-prefix={}=/topsrc", slot_a.display());
    let encoded_b = format!("--remap-path-prefix={}=/topsrc", slot_b.display());

    // 1. Build slot A.
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("CARGO_ENCODED_RUSTFLAGS", Some(&encoded_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    assert_eq!(sa.rust_hits, 0);
    assert_eq!(sa.rust_misses, 1);

    // 2. Build slot B -> must hit and rewrite `.d` paths (including escaped spaces & Unicode).
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("CARGO_ENCODED_RUSTFLAGS", Some(&encoded_b))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    assert_eq!(sb.rust_hits, 1);
    assert_eq!(sb.rust_misses, 0);

    assert_dep_info_clean(
        &proj_b.join("target"),
        "unicode_space_test",
        &[&slot_a],
        &slot_b,
    )?;
    let out1 = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("CARGO_ENCODED_RUSTFLAGS", Some(&encoded_b))],
        true,
    )?;
    assert_eq!(out1.trim(), "こんにちは v1");

    // 3. Incremental rebuild (NO target deletion!) after modifying included file in slot B:
    //    Cargo relies on the rewritten `.d` file to detect the dependency change.
    let inc_file = proj_b.join("src/sub dir/msg 挨拶.txt");
    fs::write(&inc_file, "こんにちは v2 updated")?;
    let bumped =
        filetime::FileTime::from_unix_time(filetime::FileTime::now().unix_seconds() + 5, 0);
    filetime::set_file_mtime(&inc_file, bumped)?;

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("CARGO_ENCODED_RUSTFLAGS", Some(&encoded_b))],
        true,
    )?;
    let s_inc = read_stats(&test_info)?;
    assert_eq!(
        s_inc.rust_misses, 1,
        "Cargo should detect changed dependency via rewritten .d and trigger cache miss"
    );
    let out2 = run_cargo_run_stdout(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        &[("CARGO_ENCODED_RUSTFLAGS", Some(&encoded_b))],
        true,
    )?;
    assert_eq!(out2.trim(), "こんにちは v2 updated");

    Ok(())
}

#[cfg(unix)]
fn find_cache_entries(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            entries.extend(find_cache_entries(&path)?);
        } else if path.file_name().is_some_and(|n| n != "stats") {
            entries.push(path);
        }
    }
    Ok(entries)
}

#[cfg(unix)]
#[test]
#[serial]
fn test_dep_info_written_locally_for_cross_root_hits() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let slot_a = test_info.tempdir.path().join("slot-a");
    let slot_b = test_info.tempdir.path().join("slot-b");

    for slot in [&slot_a, &slot_b] {
        let proj = slot.join("project");
        fs::create_dir_all(proj.join("src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[package]\nname = \"localdep_lib\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(proj.join("src/lib.rs"), "pub fn value() -> u32 { 77 }\n")?;
    }

    let slot_a = fs::canonicalize(slot_a)?;
    let slot_b = fs::canonicalize(slot_b)?;
    let proj_a = slot_a.join("project");
    let proj_b = slot_b.join("project");
    let remap_a = format!("--remap-path-prefix={}=/topsrc", slot_a.display());
    let remap_b = format!("--remap-path-prefix={}=/topsrc", slot_b.display());

    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_a,
        &proj_a.join("target"),
        Some(slot_a.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_a))],
        true,
    )?;
    let sa = read_stats(&test_info)?;
    assert_eq!(sa.rust_hits, 0);
    assert_eq!(sa.rust_misses, 1);

    // Rust dep-info is written locally from the hashing invocation and is not
    // part of the cached outputs, so a hit in another root can never restore
    // stale prerequisites.
    let cache_dir = test_info.tempdir.path().join("cache");
    let mut entries = 0usize;
    for entry_path in find_cache_entries(&cache_dir)? {
        let raw = fs::read(&entry_path)?;
        let Ok(mut archive) = zip::ZipArchive::new(Cursor::new(&raw)) else {
            continue;
        };
        entries += 1;
        for i in 0..archive.len() {
            let name = archive.by_index(i)?.name().to_string();
            ensure!(
                !name.ends_with(".d"),
                "cached entry {} contains dep-info {}",
                entry_path.display(),
                name
            );
        }
    }
    ensure!(entries > 0, "expected at least one cache entry");

    // A request supplying both roots as basedirs is still sound: the artifact
    // is reusable, while dep-info stays specific to the consuming build root.
    let multi = format!("{}:{}", slot_a.display(), slot_b.display());
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(OsStr::new(&multi)),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let sb = read_stats(&test_info)?;
    assert_eq!(sb.rust_hits, 1, "cross-root reuse must still hit");
    assert_eq!(sb.rust_misses, 0);
    assert_eq!(sb.cache_read_errors, 0);
    assert_eq!(sb.cache_write_errors, 0);
    assert_dep_info_clean(&proj_b.join("target"), "localdep_lib", &[&slot_a], &slot_b)?;

    // Removing the target and rebuilding in the same root remains a hit and
    // regenerates dep-info for this root.
    clean_dir_if_exists(&proj_b.join("target"))?;
    zero_stats()?;
    run_cargo_build(
        &test_info,
        &proj_b,
        &proj_b.join("target"),
        Some(slot_b.as_os_str()),
        false,
        &[("RUSTFLAGS", Some(&remap_b))],
        true,
    )?;
    let sb2 = read_stats(&test_info)?;
    assert_eq!(sb2.rust_hits, 1);
    assert_eq!(sb2.rust_misses, 0);
    assert_dep_info_clean(&proj_b.join("target"), "localdep_lib", &[&slot_a], &slot_b)?;

    Ok(())
}

#[test]
#[serial]
fn test_concurrent_multi_root_multi_crate_requests() -> Result<()> {
    let test_info = SccacheTest::new(None)?;
    let roots = ["slot-1", "slot-2", "slot-3", "slot-4"]
        .into_iter()
        .map(|name| test_info.tempdir.path().join(name))
        .collect::<Vec<_>>();

    let write_alpha_ws = |root: &Path| -> Result<()> {
        let proj = root.join("proj");
        fs::create_dir_all(proj.join("alpha_lib/src"))?;
        fs::create_dir_all(proj.join("gamma_manifest/src"))?;
        fs::create_dir_all(proj.join("app/src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[workspace]\nmembers = [\"alpha_lib\", \"gamma_manifest\", \"app\"]\nresolver = \"2\"\n",
        )?;
        fs::write(
            proj.join("alpha_lib/Cargo.toml"),
            "[package]\nname = \"alpha_lib\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(
            proj.join("alpha_lib/src/lib.rs"),
            "pub fn val() -> u32 { 101 }\n",
        )?;
        fs::write(
            proj.join("gamma_manifest/Cargo.toml"),
            "[package]\nname = \"gamma_manifest\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(
            proj.join("gamma_manifest/src/lib.rs"),
            "pub fn manifest() -> &'static str { env!(\"CARGO_MANIFEST_DIR\") }\n",
        )?;
        fs::write(
            proj.join("app/Cargo.toml"),
            "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\nalpha_lib = { path = \"../alpha_lib\" }\ngamma_manifest = { path = \"../gamma_manifest\" }\n",
        )?;
        fs::write(
            proj.join("app/src/main.rs"),
            "fn main() { println!(\"{}|{}\", alpha_lib::val(), gamma_manifest::manifest()); }\n",
        )?;
        Ok(())
    };

    let write_beta_ws = |root: &Path| -> Result<()> {
        let proj = root.join("proj");
        fs::create_dir_all(proj.join("beta_lib/src"))?;
        fs::create_dir_all(proj.join("app/src"))?;
        fs::write(
            proj.join("Cargo.toml"),
            "[workspace]\nmembers = [\"beta_lib\", \"app\"]\nresolver = \"2\"\n",
        )?;
        fs::write(
            proj.join("beta_lib/Cargo.toml"),
            "[package]\nname = \"beta_lib\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        )?;
        fs::write(
            proj.join("beta_lib/src/lib.rs"),
            "pub fn val() -> u32 { 202 }\n",
        )?;
        fs::write(
            proj.join("app/Cargo.toml"),
            "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2024\"\n[dependencies]\nbeta_lib = { path = \"../beta_lib\" }\n",
        )?;
        fs::write(
            proj.join("app/src/main.rs"),
            "fn main() { println!(\"{}\", beta_lib::val()); }\n",
        )?;
        Ok(())
    };

    write_alpha_ws(&roots[0])?;
    write_alpha_ws(&roots[1])?;
    write_beta_ws(&roots[2])?;
    write_beta_ws(&roots[3])?;

    let roots = roots
        .into_iter()
        .map(fs::canonicalize)
        .collect::<std::io::Result<Vec<_>>>()?;
    let remaps = roots
        .iter()
        .map(|root| format!("--remap-path-prefix={}=/topsrc", root.display()))
        .collect::<Vec<_>>();

    for client_side in [false, true] {
        // Fresh cache per mode so hit counts remain deterministic.
        clean_dir_if_exists(&test_info.tempdir.path().join("cache"))?;
        fs::create_dir_all(test_info.tempdir.path().join("cache"))?;
        restart_sccache(&test_info, None)?;
        for root in &roots {
            clean_dir_if_exists(&root.join("proj/target"))?;
        }

        // Seed slot-1 (alpha_lib + gamma_manifest) and slot-3 (beta_lib).
        run_cargo_build(
            &test_info,
            &roots[0].join("proj"),
            &roots[0].join("proj/target"),
            Some(roots[0].as_os_str()),
            client_side,
            &[("RUSTFLAGS", Some(remaps[0].as_str()))],
            true,
        )?;
        run_cargo_build(
            &test_info,
            &roots[2].join("proj"),
            &roots[2].join("proj/target"),
            Some(roots[2].as_os_str()),
            client_side,
            &[("RUSTFLAGS", Some(remaps[2].as_str()))],
            true,
        )?;

        // Clean targets in slot-1 and slot-3 so all 4 roots invoke rustc concurrently.
        clean_dir_if_exists(&roots[0].join("proj/target"))?;
        clean_dir_if_exists(&roots[2].join("proj/target"))?;
        zero_stats()?;

        let mut children = Vec::new();
        for (index, root) in roots.iter().enumerate() {
            let child = build_cargo_command(
                &test_info,
                &root.join("proj"),
                &root.join("proj/target"),
                Some(root.as_os_str()),
                client_side,
                &[("RUSTFLAGS", Some(remaps[index].as_str()))],
                true,
            )
            .spawn()?;
            children.push(child);
        }
        for mut child in children {
            ensure!(child.wait()?.success(), "concurrent cargo build failed");
        }

        let stats = read_stats(&test_info)?;
        assert_eq!(stats.cache_read_errors, 0);
        assert_eq!(stats.cache_write_errors, 0);
        // slot-1: alpha(hit) + gamma(hit) = 2
        // slot-2: alpha(hit) + gamma(miss) = 1 hit, 1 miss
        // slot-3: beta(hit) = 1
        // slot-4: beta(hit) = 1
        assert_eq!(stats.rust_hits, 5);
        assert_eq!(stats.rust_misses, 1);

        let out_2 = run_cargo_run_stdout(
            &test_info,
            &roots[1].join("proj"),
            &roots[1].join("proj/target"),
            Some(roots[1].as_os_str()),
            &[("RUSTFLAGS", Some(remaps[1].as_str()))],
            true,
        )?;
        let (v2, m2) = out_2.trim().split_once('|').context("bad slot-2 output")?;
        assert_eq!(v2, "101");
        assert_eq!(
            fs::canonicalize(m2)?,
            fs::canonicalize(roots[1].join("proj/gamma_manifest"))?
        );
        assert_ne!(
            fs::canonicalize(m2)?,
            fs::canonicalize(roots[0].join("proj/gamma_manifest"))?
        );

        let out_4 = run_cargo_run_stdout(
            &test_info,
            &roots[3].join("proj"),
            &roots[3].join("proj/target"),
            Some(roots[3].as_os_str()),
            &[("RUSTFLAGS", Some(remaps[3].as_str()))],
            true,
        )?;
        assert_eq!(out_4.trim(), "202");

        #[cfg(unix)]
        {
            assert_dep_info_clean(
                &roots[1].join("proj/target"),
                "alpha_lib",
                &[&roots[0], &roots[2], &roots[3]],
                &roots[1],
            )?;
            assert_dep_info_clean(
                &roots[3].join("proj/target"),
                "beta_lib",
                &[&roots[0], &roots[1], &roots[2]],
                &roots[3],
            )?;
        }
    }

    Ok(())
}
