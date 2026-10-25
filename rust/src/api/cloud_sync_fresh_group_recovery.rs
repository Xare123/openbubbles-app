//! Exact-record storage conversion. Durable local-send recovery authority and
//! audit adoption remain the caller's separate obligation; no mutation is sent.
use super::*;
use crate::cloud_sync_outbound::NativeProtectedOutboundStage;

fn valid_previous_stage(stage: &CloudSyncLegacyGroupChatStage) -> bool {
    is_cloud_sync_keyed_hash(&stage.logical_entity_key_hash)
        && is_cloud_sync_protected_reference(&stage.protected_payload_reference)
        && is_cloud_sync_hex_digest(&stage.payload_sha256)
        && stage.protected_payload_reference == stage.protected_server_record_reference
        && is_cloud_sync_keyed_hash(&stage.server_record_id_hash)
        && is_cloud_sync_lease_reference(&stage.lease_reference)
}

pub(super) async fn stage_exact(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage: String,
    expected: CloudSyncNativeAuthMetadata,
    previous: CloudSyncLegacyGroupChatStage,
    expected_chat: CloudChat,
) -> CloudSyncProtectedOutboundStageResult {
    if !valid_previous_stage(&previous) {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidRequest);
    }
    if rustpush::cloud_messages::validate_group_chat_create(&expected_chat).is_err() {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::UnsupportedMessage);
    }
    let before = match cloud_sync_capture_auth_snapshot(client, storage.clone()).await {
        Ok(value) => value,
        Err(_) => return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::NativeAuthUnavailable),
    };
    if !cloud_sync_auth_identity_remains_exact(
        &expected, &before, &expected.account_fingerprint, &expected.protected_store_identity,
    ) {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    // Reuse the normal lookup-only Chat preparation and exact binding checks.
    // No prepared save owner or CloudKit writer permit is created here.
    let writer_binding = match client.warm_chat_writer_preparation_lookup_only().await {
        Ok(value) => value,
        Err(_) => return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::NativeAuthUnavailable),
    };
    let after = match cloud_sync_capture_auth_snapshot(client, storage.clone()).await {
        Ok(value) => value,
        Err(_) => return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::NativeAuthUnavailable),
    };
    if !cloud_sync_auth_identity_remains_exact(
        &before, &after, &expected.account_fingerprint, &expected.protected_store_identity,
    ) || client.validate_writer_preparation_binding(&writer_binding).await.is_err() {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    let result = (|| {
        let (chat, record_name) = crate::cloud_sync_outbound_chat::open_staged_outbound_chat(
            PathBuf::from(&storage), after.account_fingerprint.clone(),
            &previous.protected_payload_reference, &previous.payload_sha256,
            &previous.server_record_id_hash,
        )?;
        let (_, payload_length) = crate::cloud_sync_outbound_chat::outbound_chat_payload_identity(
            &chat, &record_name,
        )?;
        let original = NativeProtectedOutboundStage {
            logical_entity_key_hash: previous.logical_entity_key_hash,
            protected_payload_reference: previous.protected_payload_reference,
            payload_sha256: previous.payload_sha256,
            payload_length,
            protected_server_record_reference: previous.protected_server_record_reference,
            server_record_id_hash: previous.server_record_id_hash,
            lease_reference: previous.lease_reference,
        };
        crate::cloud_sync_outbound_chat::stage_recovered_fresh_group_chat_exact(
            PathBuf::from(storage), after.account_fingerprint, &original, &expected_chat,
        )
    })();
    match result {
        Ok(stage) => CloudSyncProtectedOutboundStageResult {
            stage: Some(CloudSyncProtectedOutboundStage {
                logical_entity_key_hash: stage.logical_entity_key_hash,
                protected_payload_reference: stage.protected_payload_reference,
                payload_sha256: stage.payload_sha256,
                payload_length: stage.payload_length,
                protected_server_record_reference: stage.protected_server_record_reference,
                server_record_id_hash: stage.server_record_id_hash,
                lease_reference: stage.lease_reference,
            }),
            failure: None,
        },
        Err(failure) => cloud_sync_outbound_failure_result(map_cloud_sync_outbound_failure(failure)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage() -> CloudSyncLegacyGroupChatStage {
        CloudSyncLegacyGroupChatStage {
            logical_entity_key_hash: "L".repeat(43),
            protected_payload_reference: format!("obcs2.ref.{}", "R".repeat(43)),
            payload_sha256: "a".repeat(64),
            protected_server_record_reference: format!("obcs2.ref.{}", "R".repeat(43)),
            server_record_id_hash: "S".repeat(43),
            lease_reference: format!("obcs2.lease.{}", "b".repeat(32)),
        }
    }

    #[test]
    fn exact_group_recovery_input_requires_one_bounded_legacy_stage() {
        assert!(valid_previous_stage(&stage()));
        let changes: &[fn(&mut CloudSyncLegacyGroupChatStage)] = &[
            |s| s.logical_entity_key_hash.clear(),
            |s| s.protected_payload_reference = "obcs2.ref.short".into(),
            |s| s.payload_sha256 = "g".repeat(64),
            |s| s.protected_server_record_reference = format!("obcs2.ref.{}", "X".repeat(43)),
            |s| s.server_record_id_hash = "S".repeat(42),
            |s| s.lease_reference = format!("obcs2.lease.{}", "B".repeat(32)),
        ];
        for change in changes {
            let mut changed = stage();
            change(&mut changed);
            assert!(!valid_previous_stage(&changed));
        }
    }
}
