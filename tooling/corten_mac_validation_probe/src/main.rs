// SPDX-License-Identifier: AGPL-3.0-only
use std::{error::Error, io::Read, path::Path, time::Instant};
use corten_mac_validation_probe::{decode_transfer, exchange, hex, load_framework, validation_http_client, FRAMEWORK_SHA256};
use serde_json::json;
use sha2::{Digest, Sha256};
fn run(phase: &mut &'static str) -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    let control = exchange::ExchangeControl::new(std::time::Duration::from_secs(75));
    if args.len() == 2 && args[1] == "network" {
        // Same transport/parser as validation, but no QR, framework, NAC init,
        // private input, account, relay, or session POST is touched.
        *phase = "client";
        let (cert, _) = exchange::configuration(&validation_http_client()?, phase, &mut |event| println!("{event}"), &|| control.check())?;
        println!("{}", json!({"step":"public_network","certificate_bytes":cert.len(),"hardware":"UNUSED","account_access":false,"session_post":"UNRUN"}));
        return Ok(());
    }
    if args.len() != 4 || args[1] != "--framework" || !["inspect", "imports", "engine", "validate"].contains(&args[3].as_str()) {
        return Err("usage: corten-mac-validation-probe network OR --framework PATH inspect|imports|engine|validate; binary OABS on stdin for validate".into());
    }
    *phase = "framework";
    let framework = load_framework(Path::new(&args[2]))?;
    println!("{}", json!({"step":"framework","sha256":FRAMEWORK_SHA256,"bytes":framework.len(),"hash_verified":true}));
    if args[3] == "inspect" { return Ok(()); }
    if args[3] == "imports" {
        let (supported, unresolved) = corten_mac_validation_probe::nac::inspect_import_plan(&framework)?;
        println!("{}", json!({"step":"import_plan","supported":supported,"unresolved":unresolved,"unsupported_policy":"unmapped_fault_on_access","hardware":"UNUSED","network":"UNRUN"}));
        return Ok(());
    }
    if args[3] == "engine" {
        *phase = "engine";
        let value = corten_mac_validation_probe::nac::engine_selfcheck()?;
        if value != 42 { return Err("engine return result mismatch".into()); }
        println!("{}", json!({"step":"engine_return","result":value,"hardware":"UNUSED","network":"UNRUN"}));
        return Ok(());
    }
    *phase = "input";
    let mut input = Vec::new();
    std::io::stdin().take(4097).read_to_end(&mut input)?;
    *phase = "hardware";
    let hardware = decode_transfer(&input)?;
    println!("{}", json!({"step":"hardware","input_bytes":input.len(),"input_sha256":hex(Sha256::digest(&input)),"encrypted_fields":[hardware.platform_serial_number_enc.len(),hardware.platform_uuid_enc.len(),hardware.root_disk_uuid_enc.len(),hardware.rom_enc.len(),hardware.mlb_enc.len()],"identity_preserved":true}));
    let proof = exchange::generate(&hardware, &framework, phase, &mut |event| println!("{event}"), &|| control.check())?;
    println!("{}", json!({"step":"sign","proof_bytes":proof.len(),"proof_sha256":hex(Sha256::digest(&proof)),"result":"generated","account_acceptance":"UNRUN","production_integration":"UNRUN"}));
    Ok(())
}
fn main() {
    let began = Instant::now();
    // Never allow legacy hook panic text to reveal values. The caller's outer
    // process timeout remains an independent bound on the one exchange.
    std::panic::set_hook(Box::new(|_| {}));
    let mut phase = "startup";
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&mut phase))) {
        Ok(Ok(())) => println!("{}", json!({"step":"complete","elapsed_seconds":began.elapsed().as_secs_f64()})),
        Ok(Err(error)) => { eprintln!("{}", json!({"step":"failed","phase":phase,"error":error.to_string(),"elapsed_seconds":began.elapsed().as_secs_f64()})); std::process::exit(2); }
        Err(_) => { eprintln!("{}", json!({"step":"failed","phase":phase,"error":"bounded validator rejected invalid emulated state"})); std::process::exit(3); }
    }
}
