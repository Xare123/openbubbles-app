//! Credential-free public GETs through the unchanged production clients.
use rustpush::OB_STRICT_TLS_REQWEST as reqwest;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

async fn observe(client: &reqwest::Client, name: &str, url: &'static str) -> bool {
    let began = Instant::now();
    let parsed = reqwest::Url::parse(url).unwrap();
    let expected_origin = parsed.origin().ascii_serialization();
    let observation = tokio::time::timeout(
        Duration::from_secs(8),
        client.get(url).timeout(Duration::from_secs(6)).send(),
    )
    .await;
    match observation {
        Ok(Ok(response)) => {
            let origin = response.url().origin().ascii_serialization();
            let same_origin = origin == expected_origin;
            println!(
                "{}",
                serde_json::json!({
                    "client": name,
                    "original_host": parsed.host_str().unwrap(),
                    "strict_https": same_origin,
                    "http_status": response.status().as_u16(),
                    "final_origin": origin,
                    "same_origin": same_origin,
                    "milliseconds": began.elapsed().as_millis(),
                    "authentication_tested": false,
                })
            );
            same_origin
        }
        other => {
            let failure = match other {
                Ok(Err(error)) => format!("{error:?}"),
                Err(_) => "bounded request timeout".to_owned(),
                _ => unreachable!(),
            };
            println!(
                "{}",
                serde_json::json!({
                    "client": name,
                    "original_host": parsed.host_str().unwrap(),
                    "strict_https": false,
                    "http_status": 0,
                    "failure": failure,
                    "milliseconds": began.elapsed().as_millis(),
                    "authentication_tested": false,
                })
            );
            false
        }
    }
}

#[tokio::main]
async fn main() {
    if std::env::args_os().len() != 1 {
        eprintln!("No account, identity, URL or configuration inputs accepted");
        std::process::exit(64);
    }
    let (account_client, provider_calls) = rustpush::ob_strict_tls_account_client()
        .expect("Empty production client construction failed");
    let ids = &*rustpush::OB_STRICT_TLS_IDS_CLIENT;
    let google = observe(ids, "ids_cloudkit_rustls", "https://www.google.com/").await;
    let bag = observe(
        ids,
        "ids_cloudkit_rustls",
        "https://init.ess.apple.com/WebObjects/VCInit.woa/wa/getBag?ix=3",
    )
    .await;
    let gsa = observe(
        &account_client,
        "apple_account_default_tls",
        "https://gsa.apple.com/grandslam/GsService2",
    )
    .await;
    let calls = provider_calls.load(Ordering::SeqCst);
    println!(
        "{}",
        serde_json::json!({
            "anisette_provider_calls": calls,
            "credentials_loaded": false,
            "authentication_tested": false,
            "cloudkit_tested": false,
            "strict_transport_passed": google && bag && gsa && calls == 0,
        })
    );
    std::process::exit(if google && bag && gsa && calls == 0 {
        0
    } else {
        2
    });
}
