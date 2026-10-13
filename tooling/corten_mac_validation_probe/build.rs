// SPDX-License-Identifier: AGPL-3.0-only
fn main() {
    let schema = "../../../rust/src/mac_hw_info.proto";
    println!("cargo:rerun-if-changed={schema}");
    prost_build::compile_protos(&[schema], &["../../../rust/src"])
        .expect("compile exact production hardware-transfer schema");
}
