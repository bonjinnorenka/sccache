pub fn manifest_dir() -> &'static str {
    env!("CARGO_MANIFEST_DIR")
}

#[cfg(test)]
mod tests {
    use super::manifest_dir;

    #[test]
    fn manifest_dir_matches_compile_time_env() {
        assert_eq!(manifest_dir(), env!("CARGO_MANIFEST_DIR"));
        assert!(std::path::Path::new(manifest_dir()).ends_with("small-manifest"));
    }
}
