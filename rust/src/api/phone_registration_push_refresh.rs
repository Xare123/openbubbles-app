//! Prepare a fresh APNs token request without replacing device credentials.
use openssl::{pkey::PKey, x509::X509};
use rustpush::APSState;
use std::{path::Path, sync::{Mutex, OnceLock}};

static PUSH_STATE_WRITES: OnceLock<Mutex<()>> = OnceLock::new();

pub(super) enum SavedHardwareExpectation {
    Absent,
    Exact(Vec<u8>),
}

impl SavedHardwareExpectation {
    pub(super) fn capture(directory: &Path) -> anyhow::Result<Self> {
        match std::fs::read(directory.join("hw_info.plist")) {
            Ok(bytes) => Ok(Self::Exact(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::Absent),
            Err(_) => Err(anyhow::anyhow!("Saved device details could not be read. Existing keys and messages have been kept.")),
        }
    }

    pub(super) fn bytes(&self) -> Option<&[u8]> {
        match self { Self::Absent => None, Self::Exact(bytes) => Some(bytes) }
    }

    pub(super) fn commit<T>(&self, directory: &Path, write: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<T> {
        guarded_hardware_write(directory, self.bytes(), || {
            if matches!(self, Self::Absent) {
                match std::fs::metadata(directory.join("hw_info.plist")) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
                    _ => return Err(anyhow::anyhow!("Device setup changed; the newer saved credentials have been kept.")),
                }
            }
            write()
        })
    }
}

pub(super) enum PushTokenRequirement {
    Retain([u8; 32]),
    Fresh([u8; 32]),
}

impl PushTokenRequirement {
    pub(super) fn accepts(&self, next: Option<[u8; 32]>) -> bool {
        match self {
            Self::Retain(previous) => next == Some(*previous),
            Self::Fresh(previous) => fresh_token_was_issued(Some(*previous), next),
        }
    }

    pub(super) fn failure_message(&self) -> &'static str {
        match self {
            Self::Retain(_) => "Apple Push did not retain this iPhone's token. The previous saved credentials and phone registration were kept; no replacement activation was attempted.",
            Self::Fresh(_) => "Apple Push did not issue a new phone-registration token. The previous connection and saved keys have been kept; retry later.",
        }
    }
}

/// All hardware-state writers share this short local transaction. No network
/// operation or await runs while it is held.
pub(super) fn guarded_hardware_write<T>(
    directory: &Path,
    expected: Option<&[u8]>,
    write: impl FnOnce() -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let _guard = PUSH_STATE_WRITES.get_or_init(|| Mutex::new(())).lock()
        .map_err(|_| anyhow::anyhow!("Device setup persistence is unavailable; saved credentials have been kept."))?;
    if let Some(expected) = expected {
        let current = std::fs::read(directory.join("hw_info.plist"))
            .map_err(|_| anyhow::anyhow!("Device setup changed; saved credentials have been kept."))?;
        if current != expected {
            return Err(anyhow::anyhow!("Device setup changed; the newer saved credentials have been kept."));
        }
    }
    write()
}

pub(super) fn prepare_existing_push_for_refresh(
    current: &APSState,
    same_device: bool,
    protected_public_key: &[u8],
) -> Result<APSState, &'static str> {
    if !same_device {
        return Err("Device setup changed while preparing phone-number registration. Retry with the current device; saved credentials have been kept.");
    }
    if current.token.is_none() {
        return Err("Apple Push is not ready for phone-number registration. Reconnect and retry; saved credentials have been kept.");
    }
    if let Some(native)=&current.native_push {
        if current.keypair.is_some() || !current.has_push_identity() {
            return Err("The saved native push identity is unusable. Existing messages and credentials have been kept.");
        }
        let certificate_key=X509::from_der(&native.certificate).and_then(|cert| cert.public_key())
            .map_err(|_| "The saved native push certificate could not be read. Existing credentials have been kept.")?;
        let public=PKey::public_key_from_der(protected_public_key)
            .map_err(|_| "The native push public key could not be read. Existing credentials have been kept.")?;
        if !certificate_key.public_eq(&public) {
            return Err("The saved native push identity changed. Existing credentials have been kept.");
        }
        let mut prepared=current.clone(); prepared.token=None; return Ok(prepared);
    }
    let pair = current.keypair.as_ref().ok_or(
        "The saved Apple Push certificate is unavailable. Existing messages and device details have been kept.")?;
    let certificate_key = X509::from_der(&pair.cert)
        .and_then(|cert| cert.public_key())
        .map_err(|_| "The saved Apple Push certificate could not be read. Existing messages and device details have been kept.")?;
    let public_key = PKey::public_key_from_der(protected_public_key)
        .map_err(|_| "The saved Apple Push key could not be read. Unlock this device and retry; do not clear app data.")?;
    if !certificate_key.public_eq(&public_key) {
        return Err("The saved Apple Push key does not match its certificate. Existing messages and keys have been kept; no replacement activation was attempted.");
    }
    let mut prepared = current.clone();
    prepared.token = None;
    Ok(prepared)
}

pub(super) fn fresh_token_was_issued(previous: Option<[u8; 32]>, next: Option<[u8; 32]>) -> bool {
    previous.is_some() && next.is_some() && previous != next
}

pub(super) fn validate_push_snapshot(state: &APSState) -> Result<(), &'static str> {
    if state.token.is_none() || !state.has_push_identity() {
        return Err("Apple Push is not ready for setup. Your existing device credentials have been kept; reconnect and retry.");
    }
    Ok(())
}

pub(super) fn saved_push_belongs_to_connection(current: &APSState, saved: &APSState) -> bool {
    if current.native_push.is_some() || saved.native_push.is_some() {
        return current.keypair.is_none() && saved.keypair.is_none()
            && current.has_push_identity() && saved.has_push_identity()
            && match (&current.native_push,&saved.native_push) {
                (Some(a),Some(b))=>a.same_owner(b), _=>false,
            };
    }
    match (&current.keypair, &saved.keypair) {
        (Some(current), Some(saved)) => current.cert == saved.cert && current.private.0 == saved.private.0,
        _ => false,
    }
}

pub(super) fn saved_push_write_is_current(previously_saved: &APSState, saved: &APSState) -> bool {
    previously_saved.token == saved.token && saved_push_belongs_to_connection(previously_saved, saved)
}

#[cfg(test)]
mod tests {
    use super::*;
    use openssl::{asn1::Asn1Time, hash::MessageDigest, rsa::Rsa, x509::X509Name};

    fn fixture() -> (APSState, Vec<u8>) {
        let key = PKey::from_rsa(Rsa::generate(1024).unwrap()).unwrap();
        let mut name = X509Name::builder().unwrap();
        name.append_entry_by_text("CN", "synthetic-phone-push-refresh").unwrap();
        let name = name.build();
        let mut cert = X509::builder().unwrap();
        cert.set_version(2).unwrap();
        cert.set_subject_name(&name).unwrap();
        cert.set_issuer_name(&name).unwrap();
        cert.set_pubkey(&key).unwrap();
        cert.set_not_before(&Asn1Time::days_from_now(0).unwrap()).unwrap();
        cert.set_not_after(&Asn1Time::days_from_now(1).unwrap()).unwrap();
        cert.sign(&key, MessageDigest::sha256()).unwrap();
        // Exercise the public persisted-state schema instead of exposing a
        // private rustpush implementation type just for this fixture.
        let mut pair = plist::Dictionary::new();
        pair.insert("cert".into(), plist::Value::Data(cert.build().to_der().unwrap()));
        pair.insert("private".into(), plist::Value::String("synthetic-existing-key".into()));
        let mut state = plist::Dictionary::new();
        state.insert("token".into(), plist::Value::Data(vec![7; 32]));
        state.insert("keypair".into(), plist::Value::Dictionary(pair));
        (plist::from_value(&plist::Value::Dictionary(state)).unwrap(), key.public_key_to_der().unwrap())
    }

    #[test]
    fn clears_only_candidate_token_and_preserves_original_credentials() {
        let (saved, public) = fixture();
        let next = prepare_existing_push_for_refresh(&saved, true, &public).unwrap();
        assert!(next.token.is_none());
        assert_eq!(saved.token, Some([7; 32]));
        let old = saved.keypair.as_ref().unwrap();
        let new = next.keypair.as_ref().unwrap();
        assert_eq!(new.cert, old.cert);
        assert_eq!(new.private.0, old.private.0);
    }

    fn native_fixture() -> (APSState,Vec<u8>) {
        let (mut state,public)=fixture();
        let cert=state.keypair.take().unwrap().cert;
        state.native_push=Some(rustpush::native_push::NativePushIdentity {
            certificate:cert,device_id:"synthetic-phone".into(),device_uuid:"synthetic-client".into(),
        });
        (state,public)
    }

    #[test]
    fn native_phone_refresh_retains_owner_and_certificate_without_software_alias() {
        let (state,public)=native_fixture();
        let prepared=prepare_existing_push_for_refresh(&state,true,&public).unwrap();
        assert!(prepared.token.is_none());assert!(prepared.keypair.is_none());
        assert!(saved_push_belongs_to_connection(&state,&prepared));
        assert!(validate_push_snapshot(&state).is_ok());
        assert!(validate_push_snapshot(&prepared).is_err());
        assert_eq!(state.token,Some([7;32]));
        assert!(prepare_existing_push_for_refresh(&state,false,&public).is_err());
    }

    #[test]
    fn native_wrong_key_owner_or_mixed_identity_cannot_replace_saved_state() {
        let (state,public)=native_fixture();let (_,wrong)=fixture();
        assert!(prepare_existing_push_for_refresh(&state,true,&wrong).is_err());
        let mut changed=state.clone();changed.native_push.as_mut().unwrap().device_uuid="another-client".into();
        assert!(!saved_push_belongs_to_connection(&state,&changed));
        changed=state.clone();changed.native_push.as_mut().unwrap().device_id="another-phone".into();
        assert!(!saved_push_belongs_to_connection(&state,&changed));
        changed=state.clone();changed.native_push.as_mut().unwrap().certificate=b"bad-der".to_vec();
        assert!(!saved_push_belongs_to_connection(&state,&changed));
        changed=state.clone();changed.keypair=fixture().0.keypair;
        assert!(validate_push_snapshot(&changed).is_err());
        assert!(prepare_existing_push_for_refresh(&changed,true,&public).is_err());
        assert!(!saved_push_belongs_to_connection(&state,&changed));
    }

    #[test]
    fn changed_device_is_refused_before_key_access() {
        let (saved, _) = fixture();
        assert!(prepare_existing_push_for_refresh(&saved, false, b"unreadable").is_err());
        assert_eq!(saved.token, Some([7; 32]));
    }

    #[test]
    fn missing_token_or_key_never_falls_back_to_activation() {
        let (mut saved, public) = fixture();
        saved.token = None;
        assert!(prepare_existing_push_for_refresh(&saved, true, &public).is_err());
        saved.token = Some([7; 32]);
        saved.keypair = None;
        assert!(prepare_existing_push_for_refresh(&saved, true, &public).is_err());
    }

    #[test]
    fn mismatched_or_malformed_public_material_keeps_original_state() {
        let (saved, _) = fixture();
        let other = PKey::from_rsa(Rsa::generate(1024).unwrap()).unwrap();
        assert!(prepare_existing_push_for_refresh(&saved, true, &other.public_key_to_der().unwrap()).is_err());
        assert!(prepare_existing_push_for_refresh(&saved, true, b"malformed").is_err());
        let mut malformed = saved.clone();
        malformed.keypair.as_mut().unwrap().cert = b"malformed".to_vec();
        assert!(prepare_existing_push_for_refresh(&malformed, true, &other.public_key_to_der().unwrap()).is_err());
        assert_eq!(saved.token, Some([7; 32]));
        assert!(saved.keypair.is_some());
    }

    #[test]
    fn fresh_registration_requires_a_distinct_nonempty_token() {
        assert!(fresh_token_was_issued(Some([1; 32]), Some([2; 32])));
        assert!(!fresh_token_was_issued(Some([1; 32]), Some([1; 32])));
        assert!(!fresh_token_was_issued(Some([1; 32]), None));
        assert!(!fresh_token_was_issued(None, Some([2; 32])));
    }

    #[test]
    fn relay_replacement_and_phone_refresh_have_opposite_token_requirements() {
        let retained = PushTokenRequirement::Retain([1; 32]);
        let fresh = PushTokenRequirement::Fresh([1; 32]);
        assert!(retained.accepts(Some([1; 32])));
        assert!(!retained.accepts(Some([2; 32])));
        assert!(!retained.accepts(None));
        assert!(!fresh.accepts(Some([1; 32])));
        assert!(fresh.accepts(Some([2; 32])));
        assert!(!fresh.accepts(None));
    }

    #[test]
    fn retry_snapshot_requires_both_existing_credentials_and_a_token() {
        let (mut state, _) = fixture();
        assert!(validate_push_snapshot(&state).is_ok());
        state.token = None;
        assert!(validate_push_snapshot(&state).is_err());
        state.token = Some([7; 32]);
        state.keypair = None;
        assert!(validate_push_snapshot(&state).is_err());
    }

    #[test]
    fn saved_key_ownership_allows_token_change_but_not_key_replacement() {
        let (current, _) = fixture();
        let mut saved = current.clone();
        saved.token = Some([9; 32]);
        assert!(saved_push_belongs_to_connection(&current, &saved));
        saved.keypair.as_mut().unwrap().private.0 = "other-synthetic-key".into();
        assert!(!saved_push_belongs_to_connection(&current, &saved));
        saved = current.clone();
        saved.keypair.as_mut().unwrap().cert = b"different-certificate".to_vec();
        assert!(!saved_push_belongs_to_connection(&current, &saved));
        saved.keypair = None;
        assert!(!saved_push_belongs_to_connection(&current, &saved));
    }

    #[test]
    fn old_background_writer_cannot_restore_a_superseded_token() {
        let (old, _) = fixture();
        let mut newer = old.clone();
        newer.token = Some([9; 32]);
        assert!(!saved_push_write_is_current(&old, &newer));
        assert!(saved_push_write_is_current(&newer, &newer));
    }

    #[test]
    fn changed_saved_state_rejects_stale_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hw_info.plist");
        std::fs::write(&path, b"newer-synthetic-state").unwrap();
        let mut wrote = false;
        let result = guarded_hardware_write(dir.path(), Some(b"older-synthetic-state"), || {
            wrote = true;
            std::fs::write(&path, b"stale-replacement")?;
            Ok(())
        });
        assert!(result.is_err());
        assert!(!wrote);
        assert_eq!(std::fs::read(&path).unwrap(), b"newer-synthetic-state");
    }

    #[test]
    fn unchanged_saved_state_commits_under_the_same_guard() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hw_info.plist");
        std::fs::write(&path, b"original-synthetic-state").unwrap();
        guarded_hardware_write(dir.path(), Some(b"original-synthetic-state"), || {
            std::fs::write(&path, b"ready-synthetic-state")?;
            Ok(())
        }).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"ready-synthetic-state");
    }

    #[test]
    fn initial_restore_cannot_overwrite_a_replacement_committed_while_connecting() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("hw_info.plist");
        std::fs::write(&file, b"old-synthetic-ticket").unwrap();
        let initial = SavedHardwareExpectation::capture(dir.path()).unwrap();
        std::fs::write(&file, b"new-synthetic-ticket").unwrap();
        let mut wrote = false;
        assert!(initial.commit(dir.path(), || { wrote = true; Ok(()) }).is_err());
        assert!(!wrote);
        assert_eq!(std::fs::read(file).unwrap(), b"new-synthetic-ticket");
    }

    #[test]
    fn initially_missing_profile_cannot_replace_a_newer_first_setup() {
        let dir = tempfile::tempdir().unwrap();
        let initial = SavedHardwareExpectation::capture(dir.path()).unwrap();
        let file = dir.path().join("hw_info.plist");
        std::fs::write(&file, b"newer-synthetic-setup").unwrap();
        assert!(initial.commit(dir.path(), || std::fs::write(&file, b"stale").map_err(Into::into)).is_err());
        assert_eq!(std::fs::read(file).unwrap(), b"newer-synthetic-setup");
    }

    #[test]
    fn unchanged_or_still_missing_profile_allows_the_admitted_commit() {
        for existing in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("hw_info.plist");
            if existing { std::fs::write(&file, b"old-synthetic-setup").unwrap(); }
            let initial = SavedHardwareExpectation::capture(dir.path()).unwrap();
            initial.commit(dir.path(), || std::fs::write(&file, b"admitted-synthetic-setup").map_err(Into::into)).unwrap();
            assert_eq!(std::fs::read(file).unwrap(), b"admitted-synthetic-setup");
        }
    }

    #[test]
    fn unreadable_saved_hardware_is_not_treated_as_an_absent_profile() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("hw_info.plist")).unwrap();
        assert!(SavedHardwareExpectation::capture(dir.path()).is_err());
    }
}
