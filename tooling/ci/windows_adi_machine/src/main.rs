//! Isolated machine-slot provisioning only. Private pipe output must not be logged.
//! No accounts, password, Apple verification code, OTP generation or arbitrary DSID.
use adi::proxy::{ADIProvisioningSession, ADIProxy};
use base64::{Engine, prelude::BASE64_STANDARD};
use library_coreadi::windows::{WindowsCoreADIProxy, device_identifier};
use serde_json::{Value, json};
use std::io::{BufRead, Write};

const MACHINE: i64 = -2;
const MAX_INPUT: u64 = 1024 * 1024;
type Result<T> = std::result::Result<T, &'static str>;

fn require_host() -> Result<()> {
    if std::env::var("GITHUB_ACTIONS").as_deref() != Ok("true")
        || std::env::var("RUNNER_ENVIRONMENT").as_deref() != Ok("github-hosted")
        || std::env::var("RUNNER_OS").as_deref() != Ok("Windows")
    { return Err("host-not-admitted"); }
    Ok(())
}

fn read_input() -> Result<Value> {
    let mut line = String::new();
    std::io::Read::take(std::io::stdin().lock(), MAX_INPUT + 1)
        .read_line(&mut line).map_err(|_| "pipe-read")?;
    if line.len() as u64 > MAX_INPUT || !line.ends_with('\n') { return Err("pipe-bound"); }
    serde_json::from_str(&line).map_err(|_| "pipe-json")
}

fn blob(value: &Value, field: &str) -> Result<Vec<u8>> {
    let raw = value.get(field).and_then(Value::as_str).ok_or("blob-missing")?;
    if raw.is_empty() || raw.len() > MAX_INPUT as usize / 2 { return Err("blob-bound"); }
    BASE64_STANDARD.decode(raw).map_err(|_| "blob-base64")
}

fn emit(value: Value) -> Result<()> {
    println!("{value}");
    std::io::stdout().flush().map_err(|_| "pipe-flush")
}

fn native<T>(stage: &'static str, value: adi::proxy::ADIResult<T>) -> Result<T> {
    value.map_err(|error| {
        // Fixed stage and numeric error only, never native buffers or identifiers.
        let _ = emit(json!({"stage": stage, "native_error": error.code()}));
        stage
    })
}

struct Pending<'a> {
    proxy: &'a WindowsCoreADIProxy,
    session: Option<ADIProvisioningSession<'a>>,
}
impl Drop for Pending<'_> {
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            let _ = self.proxy.destroy_provisioning_session(session);
        }
    }
}

fn handshake(proxy: &WindowsCoreADIProxy) -> Result<()> {
    emit(json!({"stage": "ready", "device_id": device_identifier()}))?;
    let start = read_input()?;
    if start.get("action").and_then(Value::as_str) != Some("start") { return Err("start-command"); }
    let spim = blob(&start, "spim")?;
    let (cpim, session) = native("native-start", proxy.start_provisioning(MACHINE, &spim))?;
    let mut pending = Pending { proxy, session: Some(session) };
    if cpim.is_empty() || cpim.len() > MAX_INPUT as usize / 2 { return Err("cpim-bound"); }
    emit(json!({"stage": "started", "cpim": BASE64_STANDARD.encode(cpim)}))?;
    let finish = read_input()?;
    if finish.get("action").and_then(Value::as_str) != Some("finish") { return Err("finish-command"); }
    let ptm = blob(&finish, "ptm")?;
    let tk = blob(&finish, "tk")?;
    let routing = finish.get("routing").and_then(Value::as_u64).ok_or("routing-invalid")?;
    native("native-finish", proxy.end_provisioning(pending.session.take().ok_or("session-missing")?, &ptm, &tk))?;
    native("native-routing", proxy.set_idms_routing(MACHINE, routing))?;
    if !native("native-query", proxy.is_machine_provisioned(MACHINE))? { return Err("not-provisioned"); }
    emit(json!({"stage": "provisioned", "provisioned": true}))
}

fn run() -> Result<()> {
    require_host()?;
    if std::env::args_os().len() != 2 { return Err("library-argument"); }
    let path = std::path::PathBuf::from(std::env::args_os().nth(1).ok_or("library-argument")?);
    let proxy = WindowsCoreADIProxy::open(&path).map_err(|_| "library-open")?;
    // A pre-existing slot is not ours to change or erase. No account enumeration.
    if native("initial-query", proxy.is_machine_provisioned(MACHINE))? { return Err("existing-machine-state"); }
    let result = handshake(&proxy);
    // Only the initially empty slot on this disposable runner is in scope.
    let cleanup = (|| {
        if native("cleanup-query", proxy.is_machine_provisioned(MACHINE))? {
            native("cleanup-erase", proxy.erase_provisioning(MACHINE))?;
        }
        if native("cleanup-verify", proxy.is_machine_provisioned(MACHINE))? { return Err("cleanup-survivor"); }
        emit(json!({"stage": "cleanup", "machine_state_removed": true}))
    })();
    cleanup?;
    result
}

fn main() -> std::process::ExitCode {
    std::panic::set_hook(Box::new(|_| { eprintln!("machine-probe-panic"); }));
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(stage) => {
            let _ = emit(json!({"stage": "error", "error": stage}));
            std::process::ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn binary_protocol_rejects_missing_empty_and_invalid_inputs() {
        for value in [json!({}), json!({"spim": ""}), json!({"spim": "!"}), json!({"spim": 7})] {
            assert!(blob(&value, "spim").is_err());
        }
        assert_eq!(blob(&json!({"spim": "AQID"}), "spim").unwrap(), [1, 2, 3]);
    }
    #[test]
    fn binary_protocol_has_a_size_bound() {
        assert!(blob(&json!({"spim": "A".repeat(MAX_INPUT as usize)}), "spim").is_err());
    }
}
