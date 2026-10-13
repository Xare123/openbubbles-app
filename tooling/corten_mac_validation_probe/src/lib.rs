// SPDX-License-Identifier: AGPL-3.0-only
pub mod nac;
use std::{error::Error, fmt, io::Read, path::Path};
use prost::Message;
use sha1::{Digest, Sha1};
use sha2::Sha256;
pub mod production_proto { include!(concat!(env!("OUT_DIR"), "/bbhwinfo.rs")); }
pub const FRAMEWORK_BYTES: u64 = 6_222_784;
pub const FRAMEWORK_SHA1: &str = "e1181ccad82e6629d52c6a006645ad87ee59bd13";
pub const FRAMEWORK_SHA256: &str = "74c2a8fe826a478f14f6e17b3709a8b315e8c0e0e34e3fba6b9c4eee2f4516e9";
// Exact production schema, normalizing only Git's CRLF/LF checkout difference.
pub const SCHEMA_SHA256: &str = "621eedbc97207d504c107b27eb074253f75729414ef9447e7c5c8d1b553223c0";

#[derive(Debug)]
pub enum AbsintheError { Other(String), NacError(i32) }
impl fmt::Display for AbsintheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self { Self::Other(s) => f.write_str(s), Self::NacError(c) => write!(f, "NAC return code {c}") }
    }
}
impl Error for AbsintheError {}
pub fn hex(bytes: impl AsRef<[u8]>) -> String { bytes.as_ref().iter().map(|b| format!("{b:02x}")).collect() }

pub fn load_framework(path: &Path) -> Result<Vec<u8>, Box<dyn Error>> {
    let file = std::fs::File::open(path)?;
    if file.metadata()?.len() != FRAMEWORK_BYTES { return Err("framework size mismatch".into()); }
    let mut bytes = Vec::new();
    file.take(FRAMEWORK_BYTES + 1).read_to_end(&mut bytes)?;
    verify_framework(&bytes)?;
    Ok(bytes)
}
pub fn verify_framework(bytes: &[u8]) -> Result<(), Box<dyn Error>> {
    if bytes.len() as u64 != FRAMEWORK_BYTES || hex(Sha1::digest(bytes)) != FRAMEWORK_SHA1 || hex(Sha256::digest(bytes)) != FRAMEWORK_SHA256 {
        return Err("framework does not match the pinned artifact".into());
    }
    Ok(())
}
pub fn decode_transfer(bytes: &[u8]) -> Result<nac::HardwareConfig, Box<dyn Error>> {
    if bytes.len() <= 5 || bytes.len() > 4096 || !bytes.starts_with(b"OABS\0") {
        return Err("expected bounded binary OABS-zero transfer".into());
    }
    let schema = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../rust/src/mac_hw_info.proto"));
    let canonical_schema = std::str::from_utf8(schema)?.replace("\r\n", "\n");
    if hex(Sha256::digest(canonical_schema.as_bytes())) != SCHEMA_SHA256 { return Err("production schema hash mismatch".into()); }
    let info = production_proto::HwInfo::decode(&bytes[5..])?;
    if info.version.is_empty() || info.device_id.is_empty() || info.icloud_ua.is_empty() || info.aoskit_version.is_empty() || info.protocol_version <= 0 {
        return Err("transfer lacks production software metadata".into());
    }
    let hw = info.inner.ok_or("transfer has no inner hardware")?;
    for value in [&hw.product_name, &hw.platform_serial_number, &hw.platform_uuid, &hw.root_disk_uuid, &hw.board_id, &hw.os_build_num, &hw.mlb] {
        if value.is_empty() || value.len() > 512 { return Err("hardware text field absent or oversized".into()); }
    }
    for value in [&hw.platform_serial_number_enc, &hw.platform_uuid_enc, &hw.root_disk_uuid_enc, &hw.rom_enc, &hw.mlb_enc] {
        if value.is_empty() || value.len() > 256 { return Err("requires genuine pre-enriched encrypted hardware fields".into()); }
    }
    if hw.rom.is_empty() || hw.rom.len() > 256 { return Err("ROM absent or oversized".into()); }
    Ok(nac::HardwareConfig {
        product_name: hw.product_name,
        io_mac_address: hw.io_mac_address.try_into().map_err(|_| "MAC must be six bytes")?,
        platform_serial_number: hw.platform_serial_number, platform_uuid: hw.platform_uuid,
        root_disk_uuid: hw.root_disk_uuid, board_id: hw.board_id, os_build_num: hw.os_build_num,
        platform_serial_number_enc: hw.platform_serial_number_enc,
        platform_uuid_enc: hw.platform_uuid_enc, root_disk_uuid_enc: hw.root_disk_uuid_enc,
        rom: hw.rom, rom_enc: hw.rom_enc, mlb: hw.mlb, mlb_enc: hw.mlb_enc,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn unknown_framework_is_rejected() { assert!(verify_framework(b"not the framework").is_err()); }
    #[test] fn malformed_transfer_is_rejected() {
        for input in [&b"OABS"[..], &b"OABS\0"[..], &b"OABS\x01invalid"[..], &b"OABS\0\xff"[..]] {
            assert!(decode_transfer(input).is_err());
        }
    }
    #[test] fn missing_hardware_does_not_generate_identity() {
        let empty = production_proto::HwInfo::default().encode_to_vec();
        let mut bytes = b"OABS\0".to_vec(); bytes.extend(empty);
        assert!(decode_transfer(&bytes).is_err());
    }
}
