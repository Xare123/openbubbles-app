// SPDX-License-Identifier: AGPL-3.0-only
fn main() {
    let schema = "../../../rust/src/mac_hw_info.proto";
    println!("cargo:rerun-if-changed={schema}");
    prost_build::compile_protos(&[schema], &["../../../rust/src"])
        .expect("compile exact production hardware-transfer schema");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        // Android x64 uses the native x86 host backend and needs no ARM cache
        // maintenance helper. Preserve the real NDK runtime on ARM64.
        let architecture = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
        if architecture == "x86_64" {
            return;
        }
        assert_eq!(architecture, "aarch64", "unqualified Android architecture");
        let compiler = std::env::var("CC_aarch64_linux_android").expect("pinned NDK compiler required");
        let output = std::process::Command::new(compiler).arg("--print-libgcc-file-name")
            .output().expect("query NDK compiler runtime");
        assert!(output.status.success(), "NDK runtime query failed");
        let text = String::from_utf8(output.stdout).expect("NDK path must be UTF-8");
        let library = std::path::Path::new(text.trim());
        let name = library.file_name().unwrap().to_str().unwrap();
        assert!(library.is_file() && name == "libclang_rt.builtins-aarch64-android.a", "expected real Android ARM64 compiler runtime");
        println!("cargo:rustc-link-search=native={}", library.parent().unwrap().display());
        println!("cargo:rustc-link-lib=static=clang_rt.builtins-aarch64-android");
    }
}
