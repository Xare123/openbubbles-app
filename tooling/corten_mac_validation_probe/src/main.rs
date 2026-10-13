// SPDX-License-Identifier: AGPL-3.0-only
use std::{error::Error, io::Read, path::Path, time::Instant};
use corten_mac_validation_probe::{decode_transfer, hex, load_framework, nac::ValidationCtx, validation_http_client, validation_url, FRAMEWORK_SHA256};
use plist::Value;
use serde_json::json;
use sha2::{Digest, Sha256};
const BAG: &str = "https://init.ess.apple.com/WebObjects/VCInit.woa/wa/getBag?ix=3";
const MAX_HTTP_BYTES: u64 = 512 * 1024;

fn response(mut reply: reqwest::blocking::Response, step: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let status = reply.status();
    if !status.is_success() { return Err(format!("{step} HTTP {}", status.as_u16()).into()); }
    if reply.content_length().is_some_and(|n| n > MAX_HTTP_BYTES) { return Err(format!("{step} response too large").into()); }
    let mut bytes = Vec::new();
    (&mut reply).take(MAX_HTTP_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_HTTP_BYTES { return Err(format!("{step} response exceeded bound").into()); }
    println!("{}", json!({"step":step,"http_status":status.as_u16(),"bytes":bytes.len()}));
    Ok(bytes)
}
fn data_field(value: Value, key: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let bytes = value.as_dictionary().and_then(|d| d.get(key)).and_then(Value::as_data).ok_or("validation plist lacks required data field")?;
    if bytes.is_empty() || bytes.len() > corten_mac_validation_probe::nac::MAX_EXCHANGE_BYTES { return Err("validation data field outside bound".into()); }
    Ok(bytes.to_vec())
}
fn validation_configuration(http: &reqwest::blocking::Client) -> Result<(Vec<u8>, reqwest::Url), Box<dyn Error>> {
    let bag_outer: Value = plist::from_bytes(&response(http.get(BAG).send()?, "bag")?)?;
    let bag: Value = plist::from_bytes(&data_field(bag_outer, "bag")?)?;
    let cert_url = validation_url(&bag, "id-validation-cert")?;
    let init_url = validation_url(&bag, "id-initialize-validation")?;
    let cert_plist: Value = plist::from_bytes(&response(http.get(cert_url).send()?, "certificate")?)?;
    Ok((data_field(cert_plist, "cert")?, init_url))
}
fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 2 && args[1] == "network" {
        // Same transport/parser as validation, but no QR, framework, NAC init,
        // private input, account, relay, or session POST is touched.
        let (cert, _) = validation_configuration(&validation_http_client()?)?;
        println!("{}", json!({"step":"public_network","certificate_bytes":cert.len(),"hardware":"UNUSED","account_access":false,"session_post":"UNRUN"}));
        return Ok(());
    }
    if args.len() != 4 || args[1] != "--framework" || !["inspect", "engine", "validate"].contains(&args[3].as_str()) {
        return Err("usage: corten-mac-validation-probe network OR --framework PATH inspect|engine|validate; binary OABS on stdin for validate".into());
    }
    let framework = load_framework(Path::new(&args[2]))?;
    println!("{}", json!({"step":"framework","sha256":FRAMEWORK_SHA256,"bytes":framework.len(),"hash_verified":true}));
    if args[3] == "inspect" { return Ok(()); }
    if args[3] == "engine" {
        let value = corten_mac_validation_probe::nac::engine_selfcheck()?;
        if value != 42 { return Err("engine return result mismatch".into()); }
        println!("{}", json!({"step":"engine_return","result":value,"hardware":"UNUSED","network":"UNRUN"}));
        return Ok(());
    }
    let mut input = Vec::new();
    std::io::stdin().take(4097).read_to_end(&mut input)?;
    let hardware = decode_transfer(&input)?;
    println!("{}", json!({"step":"hardware","input_bytes":input.len(),"input_sha256":hex(Sha256::digest(&input)),"encrypted_fields":[hardware.platform_serial_number_enc.len(),hardware.platform_uuid_enc.len(),hardware.root_disk_uuid_enc.len(),hardware.rom_enc.len(),hardware.mlb_enc.len()],"identity_preserved":true}));
    let http = validation_http_client()?;
    let (cert, init_url) = validation_configuration(&http)?;
    let mut request = Vec::new();
    let mut ctx = ValidationCtx::new(&cert, &mut request, &hardware, &framework)?;
    println!("{}", json!({"step":"nac_init","request_bytes":request.len(),"result":"success"}));
    let mut dict = plist::Dictionary::new();
    dict.insert("session-info-request".into(), Value::Data(request));
    let mut body = Vec::new();
    Value::Dictionary(dict).to_writer_xml(&mut body)?;
    let session_plist: Value = plist::from_bytes(&response(http.post(init_url).body(body).send()?, "session")?)?;
    let session = data_field(session_plist, "session-info")?;
    ctx.key_establishment(&session)?;
    println!("{}", json!({"step":"key_establishment","response_bytes":session.len(),"result":"success"}));
    let proof = ctx.sign()?;
    println!("{}", json!({"step":"sign","proof_bytes":proof.len(),"proof_sha256":hex(Sha256::digest(&proof)),"result":"generated","account_acceptance":"UNRUN","production_integration":"UNRUN"}));
    Ok(())
}
fn main() {
    let began = Instant::now();
    // Never allow legacy hook panic text to reveal values. The caller's outer
    // process timeout remains an independent bound on the one exchange.
    std::panic::set_hook(Box::new(|_| {}));
    match std::panic::catch_unwind(run) {
        Ok(Ok(())) => println!("{}", json!({"step":"complete","elapsed_seconds":began.elapsed().as_secs_f64()})),
        Ok(Err(error)) => { eprintln!("{}", json!({"step":"failed","error":error.to_string(),"elapsed_seconds":began.elapsed().as_secs_f64()})); std::process::exit(2); }
        Err(_) => { eprintln!("{}", json!({"step":"failed","error":"bounded validator rejected invalid emulated state"})); std::process::exit(3); }
    }
}
