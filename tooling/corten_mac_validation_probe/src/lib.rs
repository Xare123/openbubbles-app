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

pub fn validation_http_client() -> Result<reqwest::blocking::Client, Box<dyn Error>> {
    let mut builder = reqwest::blocking::Client::builder().use_rustls_tls().gzip(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(15))
        .connect_timeout(std::time::Duration::from_secs(5));
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert("Accept-Language", reqwest::header::HeaderValue::from_static("en-US,en;q=0.9"));
    builder = builder.default_headers(headers).http1_title_case_headers();
    for pem in [
        &include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../rustpush/certs/root/profileidentity.ess.apple.com.cert"))[..],
        &include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../rustpush/certs/root/init.ess.apple.com.cert"))[..],
    ] {
        builder = builder.add_root_certificate(reqwest::Certificate::from_pem(pem)?);
    }
    Ok(builder.build()?)
}

/// Apple's authenticated bag still advertises this public certificate via HTTP.
/// Upgrade only that exact known endpoint. Never downgrade TLS or upgrade an
/// arbitrary URL from the bag; the initialization request must remain HTTPS.
pub fn validation_url(value: &plist::Value, key: &str) -> Result<reqwest::Url, Box<dyn Error>> {
    let text = value.as_dictionary().and_then(|d| d.get(key)).and_then(plist::Value::as_string)
        .ok_or("validation bag missing expected URL")?;
    let text = if key == "id-validation-cert" && text == "http://static.ess.apple.com/identity/validation/cert-1.0.plist" {
        "https://static.ess.apple.com/identity/validation/cert-1.0.plist"
    } else { text };
    let url = reqwest::Url::parse(text)?;
    let host = url.host_str().ok_or("validation URL lacks host")?;
    if url.scheme() != "https" || !(host == "apple.com" || host.ends_with(".apple.com"))
        || !url.username().is_empty() || url.password().is_some()
        || url.port_or_known_default() != Some(443) || url.fragment().is_some() {
        return Err("validation URL is outside strict Apple HTTPS origins".into());
    }
    Ok(url)
}

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
    #[test] fn validation_http_decodes_the_gzip_used_by_apple() {
        use std::io::{Read, Write};
        let client = validation_http_client().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(std::time::Duration::from_secs(2))).unwrap();
            let mut request = [0u8; 4096];
            assert!(stream.read(&mut request).unwrap() > 0);
            let compressed: &[u8] = &[31,139,8,0,0,0,0,0,2,10,43,40,77,202,201,76,214,45,75,204,201,76,73,44,201,204,207,211,77,203,172,40,41,45,74,5,0,118,67,30,109,25,0,0,0];
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", compressed.len()).unwrap();
            stream.write_all(compressed).unwrap();
        });
        let response = client.get(format!("http://{address}/public-fixture")).send().unwrap();
        assert!(response.headers().get("Content-Encoding").is_none());
        assert_eq!(response.bytes().unwrap().as_ref(), b"public-validation-fixture");
        server.join().unwrap();
    }
    fn endpoint_bag(key: &str, url: &str) -> plist::Value {
        let mut bag = plist::Dictionary::new();
        bag.insert(key.into(), plist::Value::String(url.into()));
        plist::Value::Dictionary(bag)
    }
    #[test] fn validation_url_upgrades_only_the_known_public_certificate() {
        let key = "id-validation-cert";
        let bag = endpoint_bag(key, "http://static.ess.apple.com/identity/validation/cert-1.0.plist");
        assert_eq!(validation_url(&bag, key).unwrap().as_str(),
            "https://static.ess.apple.com/identity/validation/cert-1.0.plist");
    }
    #[test] fn validation_url_keeps_current_https_origins() {
        for (key, url) in [
            ("id-validation-cert", "https://static.ess.apple.com/identity/validation/cert-1.0.plist"),
            ("id-initialize-validation", "https://identity.ess.apple.com/WebObjects/TDIdentityService.woa/wa/initializeValidation"),
        ] {
            assert_eq!(validation_url(&endpoint_bag(key, url), key).unwrap().as_str(), url);
        }
    }
    #[test] fn validation_url_never_upgrades_session_or_unknown_http() {
        for (key, url) in [
            ("id-initialize-validation", "http://static.ess.apple.com/identity/validation/cert-1.0.plist"),
            ("id-validation-cert", "http://static.ess.apple.com/identity/validation/cert-2.0.plist"),
            ("id-validation-cert", "http://static.ess.apple.com/identity/validation/cert-1.0.plist?changed=1"),
            ("id-validation-cert", "http://static.ess.apple.com:80/identity/validation/cert-1.0.plist"),
        ] {
            assert!(validation_url(&endpoint_bag(key, url), key).is_err());
        }
    }
    #[test] fn validation_url_rejects_foreign_origins_and_ambiguous_authorities() {
        for url in ["https://apple.com.example.org/cert", "https://example.org/apple.com/cert",
            "https://apple.com@evil.example/cert", "https://user@static.ess.apple.com/cert",
            "https://static.ess.apple.com:444/cert", "https://static.ess.apple.com/cert#fragment",
            "file:///cert", "not a URL"] {
            assert!(validation_url(&endpoint_bag("id-validation-cert", url), "id-validation-cert").is_err());
        }
    }
    #[test] fn validation_url_rejects_missing_or_non_string_bag_values() {
        assert!(validation_url(&plist::Value::String("invalid".into()), "id-validation-cert").is_err());
        let mut bag = plist::Dictionary::new();
        assert!(validation_url(&plist::Value::Dictionary(bag.clone()), "id-validation-cert").is_err());
        bag.insert("id-validation-cert".into(), plist::Value::Data(vec![1, 2]));
        assert!(validation_url(&plist::Value::Dictionary(bag), "id-validation-cert").is_err());
    }
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
