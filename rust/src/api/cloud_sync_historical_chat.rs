//! Historical parent integration with the existing Chat prepare/consume/readback
//! path. The selected source stays distinct from native send/receive evidence.
use super::*;
use crate::{
    cloud_sync_historical_source::HistoricalBinding,
    cloud_sync_historical_source_stage::NativeHistoricalArchiveStage,
    cloud_sync_outbound::NativeProtectedOutboundStage,
};

fn source_binding<'a>(
    source: &'a CloudSyncNativeHistoricalArchiveSourceBinding,
    auth: &'a CloudSyncNativeAuthMetadata,
) -> Result<HistoricalBinding<'a>, CloudSyncOutboundSafeCode> {
    if source.account_fingerprint != auth.account_fingerprint
        || source.protected_store_identity != auth.protected_store_identity
    {
        return Err(CloudSyncOutboundSafeCode::InvalidScope);
    }
    Ok(HistoricalBinding {
        snapshot_sha256: &source.snapshot_sha256,
        account_fingerprint: &auth.account_fingerprint,
        protected_store_identity: &auth.protected_store_identity,
    })
}

fn source_stage(
    source: &CloudSyncNativeHistoricalArchiveSourceBinding,
) -> NativeHistoricalArchiveStage {
    NativeHistoricalArchiveStage {
        message_guid_hash: source.message_guid_hash.clone(),
        source_sha256: source.source_sha256.clone(),
        protected_reference: source.protected_reference.clone(),
        lease_reference: source.lease_reference.clone(),
        payload_sha256: source.payload_sha256.clone(),
        payload_length: source.payload_length,
    }
}

fn open_identity_candidate(
    storage: &str,
    auth: &CloudSyncNativeAuthMetadata,
    source: &CloudSyncNativeHistoricalArchiveSourceBinding,
    stage: &CloudSyncProtectedOutboundStage,
) -> Result<CloudChat, CloudSyncOutboundSafeCode> {
    let binding = source_binding(source, auth)?;
    let (candidate, _) =
        crate::cloud_sync_historical_chat::open_historical_group_parent_for_identity(
            PathBuf::from(storage),
            &binding,
            &source_stage(source),
            &NativeProtectedOutboundStage {
                logical_entity_key_hash: stage.logical_entity_key_hash.clone(),
                protected_payload_reference: stage.protected_payload_reference.clone(),
                payload_sha256: stage.payload_sha256.clone(),
                payload_length: stage.payload_length,
                protected_server_record_reference: stage.protected_server_record_reference.clone(),
                server_record_id_hash: stage.server_record_id_hash.clone(),
                lease_reference: stage.lease_reference.clone(),
            },
        )
        .map_err(map_cloud_sync_outbound_failure)?;
    Ok(candidate)
}

/// Comparison is deliberately read-only and can precede candidate adoption.
/// The exact selected historical source is rechecked around the existing
/// observer's awaited work; a failed check must never become disjoint evidence.
#[allow(clippy::too_many_arguments)]
pub(super) async fn observe_parent_identity(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    pause: u64,
    storage: String,
    expected: CloudSyncNativeAuthMetadata,
    generation: u64,
    fence: String,
    source: CloudSyncNativeHistoricalArchiveSourceBinding,
    stage: CloudSyncProtectedOutboundStage,
    retained: crate::api::cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput,
) -> crate::api::cloud_sync_chat_identity::CloudSyncChatIdentityResult {
    use crate::api::cloud_sync_chat_identity::{
        cloud_sync_observe_protected_chat_identity, CloudSyncChatIdentityResult,
        CloudSyncStagedChatIdentityCandidate,
    };
    let fail = |code| CloudSyncChatIdentityResult {
        comparison: None,
        candidate_binding_hash: None,
        staged_candidate_binding_hash: None,
        source_binding_hash: None,
        native_session_id: None,
        failure_code: Some(code),
    };
    let before = match cloud_sync_capture_auth_snapshot(client, storage.clone()).await {
        Ok(auth) if cloud_sync_require_historical_auth(&expected, &auth).is_ok() => auth,
        _ => return fail(CloudSyncTransientFailureCode::ActiveAccountMismatch),
    };
    let candidate = match open_identity_candidate(&storage, &before, &source, &stage) {
        Ok(candidate) => candidate,
        Err(_) => return fail(CloudSyncTransientFailureCode::InvalidRequest),
    };
    let observed = cloud_sync_observe_protected_chat_identity(
        client,
        pause,
        storage.clone(),
        before.account_fingerprint.clone(),
        before.protected_store_identity.clone(),
        generation,
        fence,
        candidate,
        retained,
        Some(CloudSyncStagedChatIdentityCandidate {
            protected_payload_reference: stage.protected_payload_reference.clone(),
            payload_sha256: stage.payload_sha256.clone(),
            record_id_hash: stage.server_record_id_hash.clone(),
            logical_entity_key_hash: stage.logical_entity_key_hash.clone(),
        }),
    )
    .await;
    if observed.failure_code.is_some() {
        return observed;
    }
    let after = match cloud_sync_capture_auth_snapshot(client, storage.clone()).await {
        Ok(auth) if cloud_sync_require_historical_auth(&before, &auth).is_ok() => auth,
        _ => return fail(CloudSyncTransientFailureCode::ActiveAccountMismatch),
    };
    if observed.native_session_id.as_ref() != Some(&before.native_session_id)
        || open_identity_candidate(&storage, &after, &source, &stage).is_err()
    {
        return fail(CloudSyncTransientFailureCode::InvalidRequest);
    }
    observed
}

pub(super) async fn stage_parent(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage: String,
    expected_auth: CloudSyncNativeAuthMetadata,
    source: CloudSyncNativeHistoricalArchiveSourceBinding,
) -> CloudSyncProtectedOutboundStageResult {
    let result = async {
        let before = cloud_sync_capture_auth_snapshot(client, storage.clone())
            .await
            .map_err(|_| CloudSyncOutboundSafeCode::NativeAuthUnavailable)?;
        cloud_sync_require_historical_auth(&expected_auth, &before)
            .map_err(|_| CloudSyncOutboundSafeCode::InvalidScope)?;
        let binding = source_binding(&source, &before)?;
        let stage = crate::cloud_sync_historical_chat::stage_historical_group_parent(
            PathBuf::from(&storage),
            &binding,
            &source_stage(&source),
        )
        .map_err(map_cloud_sync_outbound_failure)?;
        let after = cloud_sync_capture_auth_snapshot(client, storage.clone())
            .await
            .map_err(|_| CloudSyncOutboundSafeCode::NativeAuthUnavailable)
            .and_then(|after| {
                cloud_sync_require_historical_auth(&expected_auth, &after)
                    .map_err(|_| CloudSyncOutboundSafeCode::InvalidScope)
            });
        if let Err(code) = after {
            // No app adoption has occurred yet. Keep the original source; only
            // this unreturned candidate lease is eligible for rollback.
            let _ = crate::cloud_sync_native_fetch::cloud_sync_rollback_protected_page_lease(
                PathBuf::from(&storage),
                &stage.lease_reference,
            );
            return Err(code);
        }
        Ok(cloud_sync_bridge_stage(stage))
    }
    .await;
    match result {
        Ok(stage) => CloudSyncProtectedOutboundStageResult {
            stage: Some(stage),
            failure: None,
        },
        Err(code) => cloud_sync_outbound_failure_result(code),
    }
}

/// Shared by preparation, delayed consumption and ambiguous-write readback.
/// Neither the source nor the frozen parent can be replaced after adoption.
pub(super) fn open_chat_create_bound(
    storage: &str,
    auth: &CloudSyncNativeAuthMetadata,
    input: &CloudSyncPreparedMessageCreateInput,
) -> Result<(CloudChat, String), CloudSyncOutboundSafeCode> {
    if input.attachment_parent_context.is_some()
        || input.attachment_parent_group_proof.is_some()
        || input.received_archive_proof.is_some()
        || input.historical_archive_proof.is_some()
        || input.protected_payload_reference != input.protected_server_record_reference
    {
        return Err(CloudSyncOutboundSafeCode::InvalidRequest);
    }
    crate::cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact(
        PathBuf::from(storage),
        &input.protected_lease_reference,
        std::slice::from_ref(&input.protected_payload_reference),
    )
    .map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    let opened = crate::cloud_sync_outbound_chat::open_staged_outbound_chat(
        PathBuf::from(storage),
        auth.account_fingerprint.clone(),
        &input.protected_payload_reference,
        &input.payload_sha256,
        &input.server_record_id_hash,
    )
    .map_err(map_cloud_sync_outbound_failure)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(storage.to_owned())
        .map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    let logical = hasher
        .canonical_entity_key_hash(
            crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Chat,
            &opened.0.guid,
        )
        .map_err(|_| CloudSyncOutboundSafeCode::BindingMismatch)?;
    if logical.value() != input.logical_entity_key_hash {
        return Err(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    if let Some(source) = &input.historical_chat_source {
        let binding = source_binding(source, auth)?;
        let (_, payload_length) =
            crate::cloud_sync_outbound_chat::outbound_chat_payload_identity(&opened.0, &opened.1)
                .map_err(map_cloud_sync_outbound_failure)?;
        crate::cloud_sync_historical_chat::open_historical_group_parent(
            PathBuf::from(storage),
            &binding,
            &source_stage(source),
            &NativeProtectedOutboundStage {
                logical_entity_key_hash: input.logical_entity_key_hash.clone(),
                protected_payload_reference: input.protected_payload_reference.clone(),
                payload_sha256: input.payload_sha256.clone(),
                payload_length,
                protected_server_record_reference: input.protected_server_record_reference.clone(),
                server_record_id_hash: input.server_record_id_hash.clone(),
                lease_reference: input.protected_lease_reference.clone(),
            },
        )
        .map_err(map_cloud_sync_outbound_failure)
    } else {
        // A group must never fall back to the local direct-send writer when its
        // historical source is missing. Existing direct creates keep their lane.
        rustpush::cloud_messages::validate_direct_chat_create(&opened.0)
            .map_err(|_| CloudSyncOutboundSafeCode::UnsupportedMessage)?;
        Ok(opened)
    }
}

/// Internal ownership retained by the same single-use native consumer. No new
/// public capability, second writer, retry engine or account-session fallback.
pub(super) struct HistoricalChatPreparation {
    storage: String,
    auth: CloudSyncNativeAuthMetadata,
    input: CloudSyncPreparedMessageCreateInput,
}

impl HistoricalChatPreparation {
    pub(super) fn new(
        storage: String,
        auth: CloudSyncNativeAuthMetadata,
        input: CloudSyncPreparedMessageCreateInput,
    ) -> Self {
        Self {
            storage,
            auth,
            input,
        }
    }

    fn revalidate_auth(
        &self,
        auth: &CloudSyncNativeAuthMetadata,
    ) -> Result<(), CloudSyncOutboundSafeCode> {
        if self.input.historical_chat_source.is_none()
            || !cloud_sync_auth_identity_remains_exact(
                &self.auth,
                auth,
                &self.auth.account_fingerprint,
                &self.auth.protected_store_identity,
            )
        {
            return Err(CloudSyncOutboundSafeCode::InvalidScope);
        }
        open_chat_create_bound(&self.storage, auth, &self.input).map(|_| ())
    }

    pub(super) async fn revalidate(
        &self,
        client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    ) -> Result<(), CloudSyncOutboundSafeCode> {
        let auth = cloud_sync_capture_auth_snapshot(client, self.storage.clone())
            .await
            .map_err(|_| CloudSyncOutboundSafeCode::NativeAuthUnavailable)?;
        self.revalidate_auth(&auth)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_historical_chat::tests::{parent, source};
    use crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease;

    const REQUEST: &str = "11111111-2222-4ABC-8DEF-555555555555";

    fn fixture(
        storage: &str,
        committed: bool,
    ) -> (
        CloudSyncNativeAuthMetadata,
        CloudSyncPreparedMessageCreateInput,
    ) {
        let auth = CloudSyncNativeAuthMetadata {
            account_fingerprint: "A".repeat(43),
            native_session_id: "N".repeat(43),
            protected_store_identity: crate::cloud_sync_protector::protected_store_identity(
                storage.into(),
            )
            .unwrap(),
        };
        let snapshot = "a".repeat(64);
        let binding = HistoricalBinding {
            snapshot_sha256: &snapshot,
            account_fingerprint: &auth.account_fingerprint,
            protected_store_identity: &auth.protected_store_identity,
        };
        let original = source(&binding, parent(), "stable-group", false);
        let source = crate::cloud_sync_historical_source_stage::stage_historical_archive_source(
            PathBuf::from(storage),
            &binding,
            &original.source_sha256().unwrap(),
            &original.encode().unwrap(),
        )
        .unwrap();
        cloud_sync_commit_protected_page_lease(
            PathBuf::from(storage),
            &source.lease_reference,
            std::slice::from_ref(&source.protected_reference),
        )
        .unwrap();
        let stage = crate::cloud_sync_historical_chat::stage_historical_group_parent(
            PathBuf::from(storage),
            &binding,
            &source,
        )
        .unwrap();
        if committed {
            cloud_sync_commit_protected_page_lease(
                PathBuf::from(storage),
                &stage.lease_reference,
                std::slice::from_ref(&stage.protected_payload_reference),
            )
            .unwrap();
        }
        let input = CloudSyncPreparedMessageCreateInput {
            local_operation_id: crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(
                &auth.account_fingerprint,
                &stage.logical_entity_key_hash,
            )
            .unwrap(),
            logical_entity_key_hash: stage.logical_entity_key_hash,
            protected_lease_reference: stage.lease_reference,
            protected_payload_reference: stage.protected_payload_reference,
            payload_sha256: stage.payload_sha256,
            protected_server_record_reference: stage.protected_server_record_reference,
            server_record_id_hash: stage.server_record_id_hash,
            apple_operation_uuid: "AAAAAAAA-BBBB-4CCC-8DDD-000000000001".into(),
            attachment_parent_context: None,
            attachment_parent_group_proof: None,
            received_archive_proof: None,
            historical_archive_proof: None,
            historical_chat_source: Some(CloudSyncNativeHistoricalArchiveSourceBinding {
                account_fingerprint: auth.account_fingerprint.clone(),
                protected_store_identity: auth.protected_store_identity.clone(),
                snapshot_sha256: snapshot,
                message_guid_hash: source.message_guid_hash,
                source_sha256: source.source_sha256,
                protected_reference: source.protected_reference,
                lease_reference: source.lease_reference,
                payload_sha256: source.payload_sha256,
                payload_length: source.payload_length,
            }),
        };
        (auth, input)
    }

    #[test]
    fn historical_parent_api_reopens_same_source_route_and_record_across_prepare_and_readback() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let (auth, input) = fixture(storage, true);
        assert!(is_valid_cloud_sync_chat_create_input(
            &auth.account_fingerprint,
            REQUEST,
            &input
        ));
        let (first, record) = open_chat_create_bound(storage, &auth, &input).unwrap();
        let (reopened, same_record) = open_chat_create_bound(storage, &auth, &input).unwrap();
        assert_eq!(record, same_record);
        assert_eq!(first.guid, reopened.guid);
        assert_eq!(reopened.group_id, "stable-group");
        assert_eq!(reopened.display_name.as_deref(), Some("Saved title"));
        assert_eq!(reopened.style, 43);
        assert_eq!(
            crate::cloud_sync_outbound_chat::verify_chat_readback(
                &reopened,
                &same_record,
                &record,
                &input.payload_sha256
            )
            .unwrap(),
            input.payload_sha256
        );
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &auth.account_fingerprint,
            REQUEST,
            &input
        ));
        assert!(!is_valid_cloud_sync_attachment_create_input(
            &auth.account_fingerprint,
            REQUEST,
            &input
        ));
        let mut message = input.clone();
        message.local_operation_id =
            crate::cloud_sync_outbound::initial_message_create_operation_id(
                &auth.account_fingerprint,
                &message.logical_entity_key_hash,
            )
            .unwrap();
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &auth.account_fingerprint,
            REQUEST,
            &message
        ));
        assert!(matches!(
            cloud_sync_open_message_create_bound(storage, &auth, "synthetic", &message),
            Err(CloudSyncOutboundSafeCode::InvalidRequest)
        ));
    }

    #[test]
    fn historical_parent_api_rejects_unadopted_parent_and_never_falls_back_without_source() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let (auth, mut input) = fixture(storage, false);
        assert!(matches!(
            open_chat_create_bound(storage, &auth, &input),
            Err(CloudSyncOutboundSafeCode::ProtectedStorage)
        ));
        let (chat, record) = crate::cloud_sync_outbound_chat::open_staged_outbound_chat(
            PathBuf::from(storage),
            auth.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
            &input.server_record_id_hash,
        )
        .unwrap();
        let (_, length) =
            crate::cloud_sync_outbound_chat::outbound_chat_payload_identity(&chat, &record)
                .unwrap();
        let stage = CloudSyncProtectedOutboundStage {
            logical_entity_key_hash: input.logical_entity_key_hash.clone(),
            protected_payload_reference: input.protected_payload_reference.clone(),
            payload_sha256: input.payload_sha256.clone(),
            payload_length: length,
            protected_server_record_reference: input.protected_server_record_reference.clone(),
            server_record_id_hash: input.server_record_id_hash.clone(),
            lease_reference: input.protected_lease_reference.clone(),
        };
        let source = input.historical_chat_source.as_ref().unwrap();
        assert_eq!(
            open_identity_candidate(storage, &auth, source, &stage)
                .unwrap()
                .guid,
            chat.guid
        );
        let mut wrong_source = source.clone();
        wrong_source.snapshot_sha256 = "b".repeat(64);
        assert!(open_identity_candidate(storage, &auth, &wrong_source, &stage).is_err());
        let mut wrong_stage = stage.clone();
        wrong_stage.payload_length += 1;
        assert!(open_identity_candidate(storage, &auth, source, &wrong_stage).is_err());
        // The successful observation did not commit a lease or permit a write.
        assert!(matches!(
            open_chat_create_bound(storage, &auth, &input),
            Err(CloudSyncOutboundSafeCode::ProtectedStorage)
        ));
        cloud_sync_commit_protected_page_lease(
            PathBuf::from(storage),
            &input.protected_lease_reference,
            std::slice::from_ref(&input.protected_payload_reference),
        )
        .unwrap();
        assert!(open_chat_create_bound(storage, &auth, &input).is_ok());
        input.historical_chat_source = None;
        assert!(matches!(
            open_chat_create_bound(storage, &auth, &input),
            Err(CloudSyncOutboundSafeCode::UnsupportedMessage)
        ));
    }

    #[test]
    fn historical_parent_api_binds_every_source_and_envelope_member() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let (auth, original) = fixture(storage, true);
        for field in 0..15 {
            let mut input = original.clone();
            let source = input.historical_chat_source.as_mut().unwrap();
            match field {
                0 => source.account_fingerprint = "B".repeat(43),
                1 => source.protected_store_identity = "different-store".into(),
                2 => source.snapshot_sha256 = "b".repeat(64),
                3 => source.message_guid_hash = "b".repeat(64),
                4 => source.source_sha256 = "b".repeat(64),
                5 => source.protected_reference = format!("obcs2.ref.{}", "B".repeat(43)),
                6 => source.lease_reference = format!("obcs2.lease.{}", "b".repeat(32)),
                7 => source.payload_sha256 = "b".repeat(64),
                8 => source.payload_length += 1,
                9 => input.logical_entity_key_hash = "B".repeat(43),
                10 => input.protected_lease_reference = format!("obcs2.lease.{}", "b".repeat(32)),
                11 => input.protected_payload_reference = format!("obcs2.ref.{}", "B".repeat(43)),
                12 => {
                    input.protected_server_record_reference =
                        format!("obcs2.ref.{}", "B".repeat(43))
                }
                13 => input.server_record_id_hash = "B".repeat(43),
                14 => input.payload_sha256 = "b".repeat(64),
                _ => unreachable!(),
            }
            assert!(
                open_chat_create_bound(storage, &auth, &input).is_err(),
                "field {field}"
            );
        }
    }

    #[test]
    fn delayed_historical_parent_consumer_rechecks_session_store_and_source() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let (auth, input) = fixture(storage, true);
        let mut proof = HistoricalChatPreparation::new(storage.into(), auth.clone(), input);
        assert!(proof.revalidate_auth(&auth).is_ok());
        for field in 0..3 {
            let mut changed = auth.clone();
            match field {
                0 => changed.account_fingerprint = "B".repeat(43),
                1 => changed.native_session_id = "B".repeat(43),
                _ => changed.protected_store_identity = "different-store".into(),
            }
            assert!(matches!(
                proof.revalidate_auth(&changed),
                Err(CloudSyncOutboundSafeCode::InvalidScope)
            ));
        }
        proof
            .input
            .historical_chat_source
            .as_mut()
            .unwrap()
            .snapshot_sha256 = "b".repeat(64);
        assert!(proof.revalidate_auth(&auth).is_err());
    }
}
