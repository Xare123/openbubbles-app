// Temporary test-only addition to the exact candidate's client.rs. Never ship.
#[cfg(test)]
mod ob_android_public_transport {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct DeniedProvider(Arc<AtomicUsize>);
    impl AnisetteProvider for DeniedProvider {
        async fn get_anisette_headers(&mut self) -> Result<HashMap<String, String>, omnisette::AnisetteError> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(omnisette::AnisetteError::AnisetteNotProvisioned)
        }
    }

    #[test]
    #[ignore = "Explicit credential-free Android transport qualification only"]
    fn production_auth_client_reaches_public_endpoints() {
        assert_eq!(std::env::consts::OS, "android");
        assert_eq!(std::env::consts::ARCH, "x86_64");
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let calls = Arc::new(AtomicUsize::new(0));
            let provider = Arc::new(Mutex::new(AnisetteClient::new(DeniedProvider(calls.clone()))));
            // The actual production constructor, certificates and HTTP backend.
            let account = AppleAccount::new_with_anisette(LoginClientInfo::default(), provider).unwrap();
            assert!(account.username.is_none() && account.spd.is_none());
            assert!(account.tokens.is_empty() && account.hashed_password.is_none());
            let mut all_reached = true;
            for (label, url) in [
                ("google-control", "https://www.google.com/"),
                ("gsa-public", "https://gsa.apple.com/grandslam/GsService2"),
            ] {
                let started = std::time::Instant::now();
                let expected = reqwest::Url::parse(url).unwrap();
                let result = tokio::time::timeout(Duration::from_secs(8),
                    account.client.get(url).timeout(Duration::from_secs(6)).send()).await;
                let (reached, status, failure) = match result {
                    Ok(Ok(response)) => (response.url().origin() == expected.origin(),
                                         response.status().as_u16(), None),
                    Ok(Err(error)) => (false, 0, Some(format!("{error:?}"))),
                    Err(_) => (false, 0, Some("bounded-request-timeout".to_string())),
                };
                all_reached &= reached;
                // No response body, account headers, cookies or identity input.
                println!("\n{}", serde_json::json!({"probe": label, "host": expected.host_str(),
                    "strict_https": reached, "http_status": status, "failure": failure,
                    "milliseconds": started.elapsed().as_millis(), "authentication_tested": false}));
            }
            let provider_calls = calls.load(Ordering::SeqCst);
            println!("\n{}", serde_json::json!({"provider_calls": provider_calls,
                "credentials_loaded": false, "authentication_tested": false,
                "transport_passed": all_reached && provider_calls == 0}));
            assert_eq!(provider_calls, 0);
            assert!(all_reached, "public transport failed; no account request was made");
        });
    }
}
