// SPDX-License-Identifier: AGPL-3.0-only
//! Shared validation exchange for the console and explicitly enabled test app.
//! This never signs in, registers a relay, or persists the returned proof.
use std::{
    error::Error,
    io::Read,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use crate::{
    nac::{HardwareConfig, ValidationCtx, MAX_EXCHANGE_BYTES},
    validate_hardware, validation_http_client, validation_url, verify_framework,
};
use plist::Value;
use serde_json::{json, Value as Event};

const BAG: &str = "https://init.ess.apple.com/WebObjects/VCInit.woa/wa/getBag?ix=3";
const MAX_HTTP_BYTES: u64 = 512 * 1024;

/// Cooperative cancellation is checked before each new exchange stage.
/// A request already in flight retains the client's bounded I/O timeout.
#[derive(Clone)]
pub struct ExchangeControl {
    cancelled: Arc<AtomicBool>,
    deadline: Instant,
}

impl ExchangeControl {
    pub fn new(budget: Duration) -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            deadline: Instant::now() + budget,
        }
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }
    pub fn check(&self) -> Result<(), Box<dyn Error>> {
        if self.cancelled.load(Ordering::SeqCst) {
            return Err("validation cancelled".into());
        }
        if Instant::now() >= self.deadline {
            return Err("validation deadline expired".into());
        }
        Ok(())
    }
}

type Admission<'a> = &'a dyn Fn() -> Result<(), Box<dyn Error>>;

fn stage(
    phase: &mut &'static str,
    name: &'static str,
    admit: Admission<'_>,
) -> Result<(), Box<dyn Error>> {
    *phase = name;
    admit()
}

fn response(
    mut reply: reqwest::blocking::Response,
    step: &str,
    observe: &mut impl FnMut(Event),
) -> Result<Vec<u8>, Box<dyn Error>> {
    let status = reply.status();
    if !status.is_success() {
        return Err(format!("{step} HTTP {}", status.as_u16()).into());
    }
    if reply.content_length().is_some_and(|n| n > MAX_HTTP_BYTES) {
        return Err(format!("{step} response too large").into());
    }
    let mut bytes = Vec::new();
    (&mut reply)
        .take(MAX_HTTP_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_HTTP_BYTES {
        return Err(format!("{step} response exceeded bound").into());
    }
    observe(json!({"step":step,"http_status":status.as_u16(),"bytes":bytes.len()}));
    Ok(bytes)
}

fn data_field(value: Value, key: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let bytes = value
        .as_dictionary()
        .and_then(|d| d.get(key))
        .and_then(Value::as_data)
        .ok_or("validation plist lacks required data field")?;
    if bytes.is_empty() || bytes.len() > MAX_EXCHANGE_BYTES {
        return Err("validation data field outside bound".into());
    }
    Ok(bytes.to_vec())
}

pub fn configuration(
    http: &reqwest::blocking::Client,
    phase: &mut &'static str,
    observe: &mut impl FnMut(Event),
    admit: Admission<'_>,
) -> Result<(Vec<u8>, reqwest::Url), Box<dyn Error>> {
    stage(phase, "bag_request", admit)?;
    let bag_bytes = response(http.get(BAG).send()?, "bag", observe)?;
    stage(phase, "bag_decode", admit)?;
    let outer: Value = plist::from_bytes(&bag_bytes)?;
    let bag: Value = plist::from_bytes(&data_field(outer, "bag")?)?;
    stage(phase, "bag_urls", admit)?;
    let cert_url = validation_url(&bag, "id-validation-cert")?;
    let init_url = validation_url(&bag, "id-initialize-validation")?;
    stage(phase, "certificate_request", admit)?;
    let cert_bytes = response(http.get(cert_url).send()?, "certificate", observe)?;
    stage(phase, "certificate_decode", admit)?;
    Ok((
        data_field(plist::from_bytes(&cert_bytes)?, "cert")?,
        init_url,
    ))
}

/// A fresh, single-use challenge. Caller runs this on a blocking worker.
/// Context and emulator stay on that worker; no unsafe Send/Sync is required.
pub fn generate(
    hardware: &HardwareConfig,
    framework: &[u8],
    phase: &mut &'static str,
    observe: &mut impl FnMut(Event),
    admit: Admission<'_>,
) -> Result<Vec<u8>, Box<dyn Error>> {
    stage(phase, "hardware", admit)?;
    validate_hardware(hardware)?;
    stage(phase, "framework", admit)?;
    verify_framework(framework)?;
    stage(phase, "client", admit)?;
    let http = validation_http_client()?;
    let (cert, init_url) = configuration(&http, phase, observe, admit)?;
    let mut request = Vec::new();
    stage(phase, "nac_init", admit)?;
    let mut ctx = ValidationCtx::new(&cert, &mut request, hardware, framework)?;
    observe(json!({"step":"nac_init","request_bytes":request.len(),"result":"success"}));
    stage(phase, "session_encode", admit)?;
    let mut dict = plist::Dictionary::new();
    dict.insert("session-info-request".into(), Value::Data(request));
    let mut body = Vec::new();
    Value::Dictionary(dict).to_writer_xml(&mut body)?;
    stage(phase, "session_request", admit)?;
    let bytes = response(http.post(init_url).body(body).send()?, "session", observe)?;
    stage(phase, "session_decode", admit)?;
    let session = data_field(plist::from_bytes(&bytes)?, "session-info")?;
    stage(phase, "key_establishment", admit)?;
    ctx.key_establishment(&session)?;
    observe(json!({"step":"key_establishment","response_bytes":session.len(),"result":"success"}));
    stage(phase, "sign", admit)?;
    let proof = ctx.sign()?;
    stage(phase, "completion", admit)?;
    if proof.is_empty() || proof.len() > MAX_EXCHANGE_BYTES {
        return Err("validation proof outside bound".into());
    }
    Ok(proof)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_blocks_the_next_stage() {
        let control = ExchangeControl::new(Duration::from_secs(10));
        let mut phase = "startup";
        stage(&mut phase, "bag_request", &|| control.check()).unwrap();
        control.cancel();
        assert!(stage(&mut phase, "session_request", &|| control.check()).is_err());
        assert_eq!(phase, "session_request");
    }
    #[test]
    fn absolute_deadline_blocks_start() {
        let control = ExchangeControl::new(Duration::ZERO);
        assert!(control.check().is_err());
    }
    #[test]
    fn decoded_certificate_is_not_its_plist_envelope() {
        let certificate = vec![1u8; 32];
        let mut dictionary = plist::Dictionary::new();
        dictionary.insert("cert".into(), Value::Data(certificate.clone()));
        let mut envelope = Vec::new();
        Value::Dictionary(dictionary)
            .to_writer_xml(&mut envelope)
            .unwrap();
        let decoded = data_field(plist::from_bytes(&envelope).unwrap(), "cert").unwrap();
        assert_eq!(decoded, certificate);
        assert_ne!(decoded.len(), envelope.len());
    }
    #[test]
    fn exchange_data_has_nonempty_bounded_type() {
        for bytes in [vec![], vec![0; MAX_EXCHANGE_BYTES + 1]] {
            let mut dictionary = plist::Dictionary::new();
            dictionary.insert("session-info".into(), Value::Data(bytes));
            assert!(data_field(Value::Dictionary(dictionary), "session-info").is_err());
        }
        assert!(data_field(Value::String("html".into()), "session-info").is_err());
    }
}
