fn main() {
    let rendered = small_core::compute(7);
    let dir = small_manifest::manifest_dir();
    println!("{rendered}|{dir}");
}
