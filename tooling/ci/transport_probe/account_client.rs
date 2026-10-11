// Temporary diagnostic seam. Never include this export in a release.
pub fn ob_strict_tls_account_client(
) -> Result<(Client, Arc<std::sync::atomic::AtomicUsize>), crate::Error> {
    struct NoAnisette {
        calls: Arc<std::sync::atomic::AtomicUsize>,
    }
    impl AnisetteProvider for NoAnisette {
        fn get_anisette_headers(
            &mut self,
        ) -> impl std::future::Future<
            Output = Result<HashMap<String, String>, omnisette::AnisetteError>,
        > + Send {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            std::future::ready(Err(omnisette::AnisetteError::AnisetteNotProvisioned))
        }
    }
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let unused_provider = Arc::new(Mutex::new(omnisette::AnisetteClient::new(NoAnisette {
        calls: calls.clone(),
    })));
    let account = AppleAccount::new_with_anisette(LoginClientInfo::default(), unused_provider)?;
    assert!(account.username.is_none());
    assert!(account.spd.is_none());
    assert!(account.tokens.is_empty());
    assert!(account.hashed_password.is_none());
    Ok((account.client, calls))
}
