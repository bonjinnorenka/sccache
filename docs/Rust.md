sccache includes support for caching Rust compilation. This includes many caveats, and is primarily focused on caching rustc invocations as produced by cargo. A (possibly-incomplete) list follows:
* `--emit` is required.
* `--crate-name` is required.
* Only `link`, `metadata` and `dep-info` are supported as `--emit` values, and `link` must be present.
* `--out-dir` is required.
* `-o file` is not supported.
* Compilation from stdin is not supported, a source file must be provided.
* Values from `env!` require Rust >= 1.46 to be tracked in caching.
* Procedural macros that read files from the filesystem may not be cached properly.
* `rustc`'s incremental compilation needs to be disabled. See [The Cargo Book](https://doc.rust-lang.org/cargo/reference/profiles.html#incremental)
* `SCCACHE_BASEDIRS` normalizes matching paths in cache-key inputs (arguments, `--remap-path-prefix` source prefixes, Cargo path env vars, and `cwd`), while keeping tracked `rustc` `env-dep` values verbatim so crates using `env!("CARGO_MANIFEST_DIR")` or `env!("OUT_DIR")` do not falsely reuse artifacts across build roots. Rust `.d` dep-info is generated locally for every invocation, so a cache hit never restores another build root's paths.
* Cross-root Rust reuse is fail-closed. `rustc` embeds `cwd` and source names in debug info and crate metadata, so `SCCACHE_BASEDIRS` only normalizes a Rust invocation when the final `--remap-path-prefix` that `rustc` applies to each of those paths removes the basedir and `--remap-path-scope` includes `all` (the default). A remap above the basedir leaves the root directory in the output, and the last matching remap wins. Otherwise the raw paths remain in the key. Compilations that consume a procedural macro also keep raw paths, because proc macros can read `CARGO_MANIFEST_DIR` or `current_dir()` without a dep-info entry.
* Crates that invoke the system linker cannot be cached. Examples are `bin`, `dylib`, `cdylib`, and `proc-macro` crates.

If you are using Rust 1.18 or later, you can ask cargo to wrap all compilation with sccache by setting `RUSTC_WRAPPER=sccache` in your build environment.
