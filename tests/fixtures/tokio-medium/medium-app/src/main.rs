fn main() {
    let summary = medium_core::describe_client_and_router();
    let dir = medium_manifest::manifest_dir();
    println!("{summary}|{dir}");
}
