use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let project_root = PathBuf::from(&crate_dir).parent().unwrap().to_owned();

    // 1. Generate the header using cbindgen
    let header_src = PathBuf::from(&crate_dir).join("syphonout_core.h");
    
    let status = Command::new("cbindgen")
        .arg("--config")
        .arg("cbindgen.toml")
        .arg("--output")
        .arg(&header_src)
        .current_dir(&crate_dir)
        .status()
        .expect("Failed to execute cbindgen");

    if !status.success() {
        panic!("cbindgen failed to generate header");
    }

    // 2. Copy the generated header to the Bridging directory
    let header_dest = project_root
        .join("SyphonOut")
        .join("Bridging")
        .join("syphonout_core.h");

    if let Some(parent) = header_dest.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    std::fs::copy(&header_src, &header_dest).expect("Failed to copy header to bridging directory");

    println!("cargo:rerun-if-changed=src/");
    println!("cargo:rerun-if-changed=cbindgen.toml");
}