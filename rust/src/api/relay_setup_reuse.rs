//! Same-physical-relay recovery. No key generation, activation or account calls.
use super::{JoinedOSConfig, SavedHardwareState};
use std::sync::Arc;

pub(super) fn prepare(
    saved: &SavedHardwareState,
    candidate: &JoinedOSConfig,
) -> anyhow::Result<Option<SavedHardwareState>> {
    let (JoinedOSConfig::Relay(old), JoinedOSConfig::Relay(new)) =
        (&saved.os_config, candidate) else { return Ok(None) };
    let Some(retained) = old.native_replacement(new) else { return Ok(None) };
    // Missing protected credentials are not permission to fall back to fresh
    // activation or erase cached phone credentials.
    super::phone_registration_push_refresh::validate_push_snapshot(&saved.push)
        .map_err(|_| anyhow::anyhow!(
            "The saved iPhone push credentials are unavailable. Existing messages and device details were kept; no replacement activation was attempted."))?;
    if saved.identity.is_empty() {
        return Err(anyhow::anyhow!(
            "The saved iPhone encryption identity is unavailable. Existing messages and keys were kept; no replacement activation was attempted."));
    }
    Ok(Some(SavedHardwareState {
        push: saved.push.clone(),
        identity: saved.identity.clone(),
        os_config: JoinedOSConfig::Relay(Arc::new(retained)),
    }))
}

/// Background persistence also binds the relay ticket/capability, not only its
/// physical device and push token. An old writer cannot restore an old ticket.
pub(super) fn same_config(a: &JoinedOSConfig, b: &JoinedOSConfig) -> anyhow::Result<bool> {
    Ok(plist::to_value(a)? == plist::to_value(b)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustpush::RelayConfig;
    use serde_json::json;

    fn relay(native: bool, code: &str) -> JoinedOSConfig {
        JoinedOSConfig::Relay(Arc::new(serde_json::from_value(json!({
            "version": {"software_build_id":"synthetic-build", "software_name":"iPhone OS",
                "software_version":"synthetic-version", "serial_number":"synthetic-serial",
                "hardware_version":"iPhone9,3", "unique_device_id":"synthetic-device"},
            "icloud_ua":"synthetic-agent", "aoskit_version":"synthetic-kit",
            "dev_uuid":"retained-uuid", "protocol_version":1660, "host":"https://relay.example",
            "code":code, "beeper_token":null, "udid":"retained-udid", "native_auth_v1":native
        })).unwrap()))
    }

    fn saved() -> SavedHardwareState {
        let mut pair = plist::Dictionary::new();
        pair.insert("cert".into(), plist::Value::Data(vec![1, 2, 3]));
        pair.insert("private".into(), plist::Value::String("synthetic-protected-key-handle".into()));
        let mut push = plist::Dictionary::new();
        push.insert("token".into(), plist::Value::Data(vec![7; 32]));
        push.insert("keypair".into(), plist::Value::Dictionary(pair));
        SavedHardwareState {push: plist::from_value(&plist::Value::Dictionary(push)).unwrap(),
            identity: vec![4, 5, 6], os_config: relay(false, "synthetic-old-ticket")}
    }

    fn changed(candidate: &JoinedOSConfig, field: &str, value: &str) -> JoinedOSConfig {
        let JoinedOSConfig::Relay(config) = candidate else { panic!() };
        let mut data = serde_json::to_value(config.as_ref()).unwrap();
        data["version"][field] = json!(value);
        JoinedOSConfig::Relay(Arc::new(serde_json::from_value::<RelayConfig>(data).unwrap()))
    }

    #[test]
    fn native_same_phone_retains_keys_identity_token_and_local_device_ids() {
        let old = saved();
        let mut candidate = relay(true, "synthetic-new-ticket");
        let JoinedOSConfig::Relay(config) = &mut candidate else { panic!() };
        Arc::make_mut(config).dev_uuid = "new-unused-uuid".into();
        Arc::make_mut(config).udid = Some("new-unused-udid".into());
        let next = prepare(&old, &candidate).unwrap().unwrap();
        assert_eq!(plist::to_value(&old.push).unwrap(), plist::to_value(&next.push).unwrap());
        assert_eq!(old.identity, next.identity);
        let JoinedOSConfig::Relay(next) = next.os_config else { panic!() };
        assert_eq!(next.dev_uuid, "retained-uuid");
        assert_eq!(next.udid.as_deref(), Some("retained-udid"));
        assert_eq!(next.code, "synthetic-new-ticket");
        assert!(next.native_auth_v1);
        assert!(!same_config(&old.os_config, &candidate).unwrap());
    }

    #[test]
    fn different_or_missing_phone_identity_never_reuses_saved_push() {
        let candidate = relay(true, "synthetic-new-ticket");
        for field in ["unique_device_id", "serial_number", "hardware_version"] {
            for value in ["different-device", ""] {
                assert!(prepare(&saved(), &changed(&candidate, field, value)).unwrap().is_none());
            }
        }
    }

    #[test]
    fn udid_case_and_os_update_do_not_force_new_activation() {
        let candidate = relay(true, "synthetic-new-ticket");
        let candidate = changed(&candidate, "unique_device_id", "SYNTHETIC-DEVICE");
        let candidate = changed(&candidate, "software_version", "new-runtime-version");
        assert!(prepare(&saved(), &candidate).unwrap().is_some());
    }

    #[test]
    fn legacy_relay_keeps_its_existing_setup_path() {
        assert!(prepare(&saved(), &relay(false, "synthetic-new-ticket")).unwrap().is_none());
    }

    #[test]
    fn missing_retained_credentials_fail_without_fresh_activation_fallback() {
        let candidate = relay(true, "synthetic-new-ticket");
        let mut old = saved();
        old.push.token = None;
        assert!(prepare(&old, &candidate).is_err());
        old = saved();
        old.push.keypair = None;
        assert!(prepare(&old, &candidate).is_err());
        old = saved();
        old.identity.clear();
        assert!(prepare(&old, &candidate).is_err());
    }

    #[test]
    fn replaced_ticket_or_capability_invalidates_old_background_writer() {
        let old = saved();
        assert!(same_config(&old.os_config, &old.os_config).unwrap());
        assert!(!same_config(&old.os_config, &relay(false, "different-ticket")).unwrap());
        assert!(!same_config(&old.os_config, &relay(true, "synthetic-old-ticket")).unwrap());
        let next = prepare(&old, &relay(true, "synthetic-new-ticket")).unwrap().unwrap();
        assert!(!same_config(&old.os_config, &next.os_config).unwrap());
    }

    #[test]
    fn recovery_preparation_does_not_mutate_original_saved_state() {
        let old = saved();
        let before = plist::to_value(&old).unwrap();
        let _ = prepare(&old, &relay(true, "synthetic-new-ticket")).unwrap();
        assert_eq!(plist::to_value(&old).unwrap(), before);
    }

    #[test]
    fn incomplete_saved_phone_identity_cannot_authorize_credential_reuse() {
        let mut old = saved();
        let candidate = relay(true, "synthetic-new-ticket");
        for field in ["unique_device_id", "serial_number", "hardware_version"] {
            old.os_config = changed(&relay(false, "synthetic-old-ticket"), field, "");
            assert!(prepare(&old, &candidate).unwrap().is_none());
        }
    }
}
