//! Explicit, ignored authentication discriminators using the production path.
//! SRP-init is credential-free. The separate password/SMS check requires the
//! private sealing wrapper. Neither test registers IDS or accesses CloudKit.
use super::*;
use std::io::{self, BufRead, Read, Write};
use omnisette::remote_anisette_v3::{AnisetteClient as RemoteClient, AnisetteState};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeInput {
    username: String,
    endpoint: String,
    state_plist: String,
    client_info: ProbeClientInfo,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeClientInfo {
    ak_context_type: String,
    client_app_name: String,
    client_bundle_id: String,
    mme_client_info: String,
    mme_client_info_akd: String,
    akd_user_agent: String,
    browser_user_agent: String,
    hardware_headers: HashMap<String, String>,
    push_token: Option<String>,
    update_account_bundle_id: String,
}

impl From<ProbeClientInfo> for LoginClientInfo {
    fn from(v: ProbeClientInfo) -> Self {
        Self {
            ak_context_type: v.ak_context_type,
            client_app_name: v.client_app_name,
            client_bundle_id: v.client_bundle_id,
            mme_client_info: v.mme_client_info,
            mme_client_info_akd: v.mme_client_info_akd,
            akd_user_agent: v.akd_user_agent,
            browser_user_agent: v.browser_user_agent,
            hardware_headers: v.hardware_headers,
            push_token: v.push_token,
            update_account_bundle_id: v.update_account_bundle_id,
        }
    }
}

struct PreservedProvider {
    client: RemoteClient,
    state: AnisetteState,
}

impl AnisetteProvider for PreservedProvider {
    async fn get_anisette_headers(&mut self) -> Result<HashMap<String, String>, omnisette::AnisetteError> {
        // One request only. Never provision, reset, retry or write saved state.
        Ok(self.client.get_headers(&self.state).await?.get_headers())
    }
}

struct NumericStatusLogger;
impl log::Log for NumericStatusLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.target() == "icloud_auth::client"
    }
    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) { return; }
        let text = record.args().to_string();
        if text.starts_with("Apple authentication status: stage=") || text.starts_with("Apple authentication HTTP: stage=") {
            println!("{text}");
            let _ = io::stdout().flush();
        }
    }
    fn flush(&self) {}
}
static LOGGER: NumericStatusLogger = NumericStatusLogger;

async fn run_probe(input: ProbeInput) -> Result<bool, Error> {
    let username = input.username.clone();
    let account = prepared_account(input).await?;
    let anisette = account.get_anisette().await?;
    let srp = SrpClient::<Sha256>::new(&G_2048);
    let a: Vec<u8> = (0..32).map(|_| rand::random::<u8>()).collect();
    let (response, _) = account.request_srp_init(
        &username, srp.compute_public_ephemeral(&a), &anisette,
        &Uuid::new_v4().to_string().to_uppercase(),
    ).await?;
    // Validate only the shape. Do not display challenge/salt or calculate proof.
    srp_init_params(&response)?;
    Ok(true)
}

async fn prepared_account(input: ProbeInput) -> Result<AppleAccount<PreservedProvider>, Error> {
    let info: LoginClientInfo = input.client_info.into();
    let state_bytes = base64::decode(input.state_plist).map_err(|_| Error::Parse)?;
    let state: AnisetteState = plist::from_bytes(&state_bytes)?;
    if !state.is_provisioned() { return Err(Error::Parse); }
    let client = RemoteClient::new(input.endpoint, info.clone()).await?;
    let provider = Arc::new(Mutex::new(AnisetteClient::new(PreservedProvider { client, state })));
    AppleAccount::new_with_anisette(info, provider)
}

fn error_kind(error: &Error) -> &'static str {
    match error {
        Error::ErrorGettingAnisette(_) => "provider",
        Error::ReqwestError(_) => "transport",
        Error::UnexpectedResponse(_) => "unexpected-response",
        Error::PlistError(_) => "plist",
        Error::Parse => "parse",
        Error::AuthSrpWithMessage(_, _) => "apple-status-rejected",
        Error::AuthSrp => "auth-rejected",
        Error::FailedGetting2FAConfig => "two-factor-config-unavailable",
        Error::HardwareKeyError => "no-supported-trusted-phone",
        Error::Bad2faCode => "verification-rejected",
        _ => "other",
    }
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "manual private-input check; contacts the existing provider and Apple SRP-init only"]
async fn retained_profile_srp_init_only() {
    let mut raw = Vec::new();
    io::stdin().take(65537).read_to_end(&mut raw).expect("private stdin read failed");
    assert!(raw.len() <= 65536, "private input exceeds bound");
    let input: ProbeInput = serde_json::from_slice(&raw).expect("private input schema invalid");
    assert!(!input.username.is_empty(), "account selection required");
    log::set_logger(&LOGGER).expect("isolated logger required");
    log::set_max_level(log::LevelFilter::Debug);
    let result = tokio::time::timeout(Duration::from_secs(45), run_probe(input)).await;
    let outcome = match result {
        Ok(Ok(true)) => "init-accepted-proof-not-submitted",
        Ok(Err(Error::AuthSrpWithMessage(_, _))) => "apple-init-rejected",
        Ok(Err(error)) => {
            let kind = error_kind(&error);
            println!("probe_error_kind={kind}");
            "transport-provider-or-response-error"
        },
        _ => "bounded-timeout",
    };
    println!("probe_outcome={outcome}; password_submissions=0; sms_requests=0; persistence_writes=0");
    // A server rejection is a measured outcome, not a passing login assertion.
    assert!(!matches!(outcome, "bounded-timeout" | "transport-provider-or-response-error"), "probe did not reach a classifiable Apple response");
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PasswordProbeInput {
    context: ProbeInput,
    password_sha256: String,
    output_protocol: String,
}

fn read_private_line(limit: u64) -> Vec<u8> {
    let mut raw = Vec::new();
    io::stdin().lock().take(limit + 1).read_until(b'\n', &mut raw).expect("private stdin read failed");
    assert!(raw.len() as u64 <= limit && raw.last() == Some(&b'\n'), "invalid private input framing");
    raw
}

fn print_state(state: &LoginState) {
    let label = match state {
        LoginState::LoggedIn => "logged-in",
        LoginState::NeedsDevice2FA => "needs-device-2fa",
        LoginState::NeedsSMS2FA => "needs-sms-2fa",
        LoginState::Needs2FAVerification => "needs-device-verification",
        LoginState::NeedsSMS2FAVerification(_) => "needs-sms-verification",
        LoginState::NeedsExtraStep(_) => "needs-extra-step",
        LoginState::NeedsLogin => "needs-login",
    };
    println!("probe_login_state={label}");
    let _ = io::stdout().flush();
}

async fn password_sms_probe(input: PasswordProbeInput) -> Result<(), Error> {
    if input.output_protocol != "private-pipe-sealed-v1" { return Err(Error::Parse); }
    let username = input.context.username.clone();
    let password = base64::decode(input.password_sha256).map_err(|_| Error::Parse)?;
    if password.len() != 32 { return Err(Error::Parse); }
    let mut account = bounded_auth(prepared_account(input.context)).await?;
    println!("probe_password_attempt=1");
    let state = bounded_auth(account.login_email_pass(&username, &password)).await?;
    print_state(&state);
    let state = match state {
        LoginState::NeedsDevice2FA | LoginState::NeedsSMS2FA | LoginState::Needs2FAVerification => {
            // Use the actual trusted-phone list. Never invent or change a number.
            match bounded_auth(account.get_auth_extras()).await {
                Ok(extras) => {
                    if let Some(LoginState::NeedsSMS2FAVerification(body)) = extras.new_state {
                        LoginState::NeedsSMS2FAVerification(body)
                    } else if extras.trusted_phone_numbers.len() == 1 {
                        println!("probe_sms_request=1");
                        bounded_auth(account.send_sms_2fa_to_devices(extras.trusted_phone_numbers[0].id)).await?
                    } else {
                        println!("probe_outcome=trusted-phone-selection-required");
                        return Ok(());
                    }
                }
                Err(error) if matches!(state, LoginState::Needs2FAVerification) => {
                    // Keep the already-sent challenge alive rather than replaying
                    // the password or claiming that SMS succeeded.
                    println!("probe_sms_unavailable={}", error_kind(&error));
                    LoginState::Needs2FAVerification
                }
                Err(error) => return Err(error),
            }
        }
        state => state,
    };
    let code_was_required = matches!(state, LoginState::NeedsSMS2FAVerification(_) | LoginState::Needs2FAVerification);
    let state = if let LoginState::NeedsSMS2FAVerification(body) = state {
        println!("probe_sms_requested=true");
        let _ = io::stdout().flush();
        // Only the private controlling wrapper can provide this framed input.
        let raw = tokio::task::spawn_blocking(|| read_private_line(256)).await.map_err(|_| Error::Parse)?;
        let code: String = serde_json::from_slice(&raw)?;
        if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) { return Err(Error::Parse); }
        bounded_auth(account.verify_sms_2fa(code, body)).await?
    } else if matches!(state, LoginState::Needs2FAVerification) {
        println!("probe_device_verification_available=true");
        let _ = io::stdout().flush();
        let raw = tokio::task::spawn_blocking(|| read_private_line(256)).await.map_err(|_| Error::Parse)?;
        let code: String = serde_json::from_slice(&raw)?;
        if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) { return Err(Error::Parse); }
        bounded_auth(account.verify_2fa(code)).await?
    } else { state };
    print_state(&state);
    let state = if code_was_required {
        if !matches!(state, LoginState::LoggedIn | LoginState::NeedsLogin) {
            println!("probe_outcome=authentication-not-complete");
            return Ok(());
        }
        // Match the application's post-verification gate. Accepted verification
        // is not a substitute for the fresh SRP exchange and authenticated PET.
        println!("probe_post_verification_login=1");
        let state = bounded_auth(account.login_email_pass(&username, &password)).await?;
        print_state(&state);
        state
    } else { state };
    if !probe_authentication_is_complete(&state, account.get_pet().is_some()) {
        println!("probe_outcome=authentication-not-complete");
        return Ok(());
    }
    // Output only to the private pipe consumed and sealed by the wrapper. Never
    // invoke this test with --nocapture without that wrapper. No message/CloudKit
    // operations, token fetch, identity registration or auto-retry are performed.
    let tokens: serde_json::Value = account.tokens.iter().map(|(name, token)| {
        (name.clone(), json!({"token": token.token, "expiration_unix_millis": token.expiration.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_millis()}))
    }).collect();
    println!("private_account_snapshot={}", json!({"username": account.username, "spd": account.spd,
        "tokens": tokens, "hashed_password": base64::encode(password)}));
    println!("probe_outcome=authenticated-no-cloudkit-or-registration");
    Ok(())
}

fn probe_authentication_is_complete(state: &LoginState, has_pet: bool) -> bool {
    matches!(state, LoginState::LoggedIn) && has_pet
}

#[test]
fn probe_success_requires_authenticated_state_and_pet() {
    assert!(probe_authentication_is_complete(&LoginState::LoggedIn, true));
    assert!(!probe_authentication_is_complete(&LoginState::LoggedIn, false));
    for state in [LoginState::NeedsLogin, LoginState::Needs2FAVerification,
        LoginState::NeedsDevice2FA, LoginState::NeedsSMS2FA] {
        assert!(!probe_authentication_is_complete(&state, true));
        assert!(!probe_authentication_is_complete(&state, false));
    }
}

async fn bounded_auth<T>(operation: impl std::future::Future<Output = Result<T, Error>>) -> Result<T, Error> {
    tokio::time::timeout(Duration::from_secs(45), operation).await
        .map_err(|_| Error::UnexpectedResponse("bounded-network-timeout".to_string()))?
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "manual authorized password and one SMS; use only private sealing wrapper"]
async fn retained_profile_password_sms() {
    let raw = read_private_line(65536);
    let input: PasswordProbeInput = serde_json::from_slice(&raw).expect("invalid private schema");
    log::set_logger(&LOGGER).expect("isolated logger required");
    log::set_max_level(log::LevelFilter::Debug);
    // Interactive input has a separate deadline from each bounded network phase.
    // The private wrapper terminates the process if stdin is never completed.
    match tokio::time::timeout(Duration::from_secs(900), password_sms_probe(input)).await {
        Ok(Ok(())) => {},
        Ok(Err(error)) => println!("probe_error_kind={}", error_kind(&error)),
        Err(_) => println!("probe_error_kind=bounded-network-timeout"),
    }
    let _ = io::stdout().flush();
}
