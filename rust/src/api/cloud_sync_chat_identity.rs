//! Read-only retained-Chat observation for the Windows qualification loop.
//! This returns no Chat payload, projection result, or write permit.

use std::{path::PathBuf, sync::Arc};

use rustpush::{
    cloud_messages::{CloudChat, CloudMessagesClient},
    cloudkit_operation_gate::acquire_cloudkit_read_authentication,
    DefaultAnisetteProvider,
};

use super::api::{
    cloud_sync_auth_identity_remains_exact, cloud_sync_capture_auth_snapshot,
    map_cloud_sync_transient_failure, CloudSyncTransientFailureCode,
};
use crate::{
    cloud_sync_chat_identity::{
        chat_identity_candidate_binding, validate_chat_identity_candidate,
        CloudChatIdentityComparison,
    },
    cloud_sync_native_fetch::CloudNativeStream,
    cloud_sync_protector,
    cloud_sync_transient_bridge::{
        cloud_sync_observe_chat_identity_cached_only, CloudTransientDecodeOutcome,
        CloudTransientDecodeRequest, CloudTransientExpectedChangeKind,
    },
};

/// Only copied, opaque journal source metadata. Never a native record body.
#[derive(Clone)]
pub struct CloudSyncChatIdentitySourceInput {
    pub change_id_hash: String,
    pub record_id_hash: String,
    pub etag_hash: String,
    pub payload_sha256: String,
    pub payload_length: Option<u64>,
    pub server_modified_at_millis: Option<i64>,
    pub protected_raw_envelope_reference: String,
}

/// The original immutable outbound envelope, never a replacement Chat or new
/// server record. Opening this value performs no adoption or remote operation.
#[derive(Clone)]
pub struct CloudSyncStagedChatIdentityCandidate {
    pub protected_payload_reference: String,
    pub payload_sha256: String,
    pub record_id_hash: String,
    pub logical_entity_key_hash: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncChatIdentityComparison {
    Overlaps,
    Disjoint,
    Incomplete,
}

/// Ephemeral observation only. The keyed binding covers the exact candidate,
/// source revision, caller's read-set fence and native client/store/account.
/// It does not prove the caller's read-set complete or the remote head current.
pub struct CloudSyncChatIdentityResult {
    pub comparison: Option<CloudSyncChatIdentityComparison>,
    pub candidate_binding_hash: Option<String>,
    pub staged_candidate_binding_hash: Option<String>,
    pub source_binding_hash: Option<String>,
    pub native_session_id: Option<String>,
    pub failure_code: Option<CloudSyncTransientFailureCode>,
}

fn failure(code: CloudSyncTransientFailureCode) -> CloudSyncChatIdentityResult {
    CloudSyncChatIdentityResult {
        comparison: None,
        candidate_binding_hash: None,
        staged_candidate_binding_hash: None,
        source_binding_hash: None,
        native_session_id: None,
        failure_code: Some(code),
    }
}

fn valid_read_set_fence(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn verify_staged_candidate(
    storage_directory: &str,
    account_fingerprint: &str,
    candidate: &CloudChat,
    stage: &CloudSyncStagedChatIdentityCandidate,
) -> Result<String, ()> {
    let (stored, _) = crate::cloud_sync_outbound_chat::open_staged_outbound_chat(
        PathBuf::from(storage_directory),
        account_fingerprint.to_owned(),
        &stage.protected_payload_reference,
        &stage.payload_sha256,
        &stage.record_id_hash,
    )
    .map_err(|_| ())?;
    let hasher = cloud_sync_protector::semantic_identifier_hasher(storage_directory.to_owned())
        .map_err(|_| ())?;
    let candidate_binding = chat_identity_candidate_binding(candidate, &hasher)?;
    if chat_identity_candidate_binding(&stored, &hasher)? != candidate_binding
        || hasher
            .canonical_entity_key_hash(
                crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Chat,
                &stored.guid,
            )
            .map_err(|_| ())?
            .value()
            != stage.logical_entity_key_hash
    {
        return Err(());
    }
    Ok(hasher.digest(
        b"OpenBubbles Cloud Sync V2 staged Chat observation v1\0",
        &serde_json::json!([
            account_fingerprint,
            candidate_binding,
            stage.protected_payload_reference,
            stage.payload_sha256,
            stage.record_id_hash,
            stage.logical_entity_key_hash,
        ])
        .to_string(),
    ))
}

/// No keychain synchronization, remote lookup/save/delete, local projection or
/// admission. Requires a warmed exact Chat zone under an active writer pause.
/// A retained malformed record fails closed, never becomes disjoint by default.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_observe_protected_chat_identity(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    generation: u64,
    read_set_fence_sha256: String,
    candidate: CloudChat,
    source: CloudSyncChatIdentitySourceInput,
    staged_candidate: Option<CloudSyncStagedChatIdentityCandidate>,
) -> CloudSyncChatIdentityResult {
    if !valid_read_set_fence(&read_set_fence_sha256)
        || validate_chat_identity_candidate(&candidate).is_err()
    {
        return failure(CloudSyncTransientFailureCode::InvalidRequest);
    }
    let request = match CloudTransientDecodeRequest::new(
        PathBuf::from(&storage_directory),
        expected_account_fingerprint.clone(),
        expected_protected_store_identity.clone(),
        "com.apple.messages.cloud".into(),
        "private".into(),
        "chatManateeZone".into(),
        "messages".into(),
        2,
        CloudNativeStream::Chats,
        generation,
        CloudTransientExpectedChangeKind::Save,
        source.change_id_hash.clone(),
        source.record_id_hash.clone(),
        Some(source.etag_hash.clone()),
        source.payload_sha256.clone(),
        source.payload_length,
        source.server_modified_at_millis,
        source.protected_raw_envelope_reference.clone(),
        None,
    ) {
        Ok(request) => request,
        Err(error) => return failure(map_cloud_sync_transient_failure(error)),
    };
    let permit = match acquire_cloudkit_read_authentication(native_writer_pause_token) {
        Ok(permit) => permit,
        Err(_) => return failure(CloudSyncTransientFailureCode::ReadAuthenticationScope),
    };
    let before =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth)
                if auth.account_fingerprint == expected_account_fingerprint
                    && auth.protected_store_identity == expected_protected_store_identity =>
            {
                auth
            }
            _ => return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch),
        };
    let stage_binding = match staged_candidate.as_ref() {
        Some(stage) => match verify_staged_candidate(
            &storage_directory,
            &expected_account_fingerprint,
            &candidate,
            stage,
        ) {
            Ok(binding) => Some(binding),
            Err(()) => return failure(CloudSyncTransientFailureCode::InvalidRequest),
        },
        None => None,
    };
    let observation = match cloud_sync_observe_chat_identity_cached_only(
        cloud_messages_client,
        &permit,
        request,
        &candidate,
    )
    .await
    {
        CloudTransientDecodeOutcome::ChatIdentityObserved(observation) => observation,
        CloudTransientDecodeOutcome::Failure(error) => {
            return failure(map_cloud_sync_transient_failure(error))
        }
        // A normal projection, quarantine or service disposition is not a
        // negative identity observation. No partial proof leaves this branch.
        _ => return failure(CloudSyncTransientFailureCode::MalformedRecord),
    };
    let after =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch),
        };
    if !cloud_sync_auth_identity_remains_exact(
        &before,
        &after,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch);
    }
    // Verify again after awaited decoding. A revoked, removed or substituted
    // staged envelope cannot leave usable evidence, even for a disjoint source.
    if let Some(stage) = staged_candidate.as_ref() {
        if verify_staged_candidate(
            &storage_directory,
            &expected_account_fingerprint,
            &candidate,
            stage,
        )
        .ok()
            != stage_binding
        {
            return failure(CloudSyncTransientFailureCode::InvalidRequest);
        }
    }
    let hasher = match cloud_sync_protector::semantic_identifier_hasher(storage_directory) {
        Ok(hasher) => hasher,
        Err(_) => return failure(CloudSyncTransientFailureCode::DecoderFailure),
    };
    let binding = serde_json::json!([
        before.native_session_id,
        expected_account_fingerprint,
        expected_protected_store_identity,
        "com.apple.messages.cloud",
        "private",
        "chatManateeZone",
        "messages",
        2,
        generation,
        read_set_fence_sha256,
        observation.candidate_binding_hash,
        stage_binding,
        source.change_id_hash,
        source.record_id_hash,
        source.etag_hash,
        source.payload_sha256,
        source.payload_length,
        source.server_modified_at_millis,
        source.protected_raw_envelope_reference,
    ])
    .to_string();
    CloudSyncChatIdentityResult {
        comparison: Some(match observation.comparison {
            CloudChatIdentityComparison::Overlaps => CloudSyncChatIdentityComparison::Overlaps,
            CloudChatIdentityComparison::Disjoint => CloudSyncChatIdentityComparison::Disjoint,
            CloudChatIdentityComparison::Incomplete => CloudSyncChatIdentityComparison::Incomplete,
        }),
        source_binding_hash: Some(hasher.digest(
            b"OpenBubbles Cloud Sync V2 Chat observation source v2\0",
            &binding,
        )),
        candidate_binding_hash: Some(observation.candidate_binding_hash),
        staged_candidate_binding_hash: stage_binding,
        native_session_id: Some(before.native_session_id),
        failure_code: None,
    }
}

#[cfg(test)]
mod cloud_sync_chat_identity_bridge_tests {
    use super::*;

    #[cfg(target_os = "windows")]
    #[test]
    fn staged_observation_checks_protected_payload_record_account_and_every_candidate_field() {
        use rustpush::cloud_messages::{
            cloudmessagesp::ChatProto, CloudParticipant, CloudProp, GZipWrapper,
        };
        let directory = tempfile::tempdir().unwrap();
        let other_directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let account = "A".repeat(43);
        let candidate = CloudChat {
            guid: "iMessage;-;recipient@example.invalid".into(),
            chat_identifier: "recipient@example.invalid".into(),
            group_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".into(),
            original_group_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".into(),
            last_addressed_handle: "sender@example.invalid".into(),
            participants: vec![CloudParticipant {
                uri: "recipient@example.invalid".into(),
            }],
            service_name: "iMessage".into(),
            style: 45,
            state: 3,
            successful_query: 1,
            // Match the production Dart encoder, including optional plist
            // properties and gzip protobuf rather than a minimal identity.
            properties: Some(CloudProp {
                pv: Some(1),
                number_of_times_respondedto_thread: Some(3),
                should_force_to_sms: Some(false),
                message_handshake_state: Some(1),
                ..Default::default()
            }),
            proto001: Some(GZipWrapper(ChatProto { unk1: Some(0) })),
            ..Default::default()
        };
        let stage_one = || {
            let stage = crate::cloud_sync_outbound_chat::stage_outbound_chat(
                directory.path().into(),
                account.clone(),
                candidate.clone(),
            )
            .unwrap();
            CloudSyncStagedChatIdentityCandidate {
                protected_payload_reference: stage.protected_payload_reference,
                payload_sha256: stage.payload_sha256,
                record_id_hash: stage.server_record_id_hash,
                logical_entity_key_hash: stage.logical_entity_key_hash,
            }
        };
        let stage = stage_one();
        let binding = verify_staged_candidate(storage, &account, &candidate, &stage).unwrap();
        assert_eq!(
            binding,
            verify_staged_candidate(storage, &account, &candidate, &stage).unwrap()
        );
        assert_ne!(
            binding,
            verify_staged_candidate(storage, &account, &candidate, &stage_one()).unwrap()
        );
        assert!(verify_staged_candidate(storage, &"B".repeat(43), &candidate, &stage).is_err());
        assert!(verify_staged_candidate(
            other_directory.path().to_str().unwrap(),
            &account,
            &candidate,
            &stage
        )
        .is_err());
        for field in 0..4 {
            let mut changed = stage.clone();
            match field {
                0 => changed.payload_sha256 = "0".repeat(64),
                1 => changed.record_id_hash = "B".repeat(43),
                2 => changed.logical_entity_key_hash = "C".repeat(43),
                _ => changed.protected_payload_reference = format!("obcs2.ref.{}", "D".repeat(43)),
            }
            assert!(verify_staged_candidate(storage, &account, &candidate, &changed).is_err());
        }
        let mut changed = candidate.clone();
        changed.last_addressed_handle = "different@example.invalid".into();
        assert!(verify_staged_candidate(storage, &account, &changed, &stage).is_err());
        changed = candidate.clone();
        changed.last_read_message_timestamp = 99;
        assert!(verify_staged_candidate(storage, &account, &changed, &stage).is_err());
    }

    #[test]
    fn fence_is_bounded_lowercase_sha256_and_failure_has_no_proof() {
        assert!(valid_read_set_fence(&"a".repeat(64)));
        for invalid in [
            "a".repeat(63),
            "a".repeat(65),
            "A".repeat(64),
            "g".repeat(64),
        ] {
            assert!(!valid_read_set_fence(&invalid));
        }
        let result = failure(CloudSyncTransientFailureCode::MalformedRecord);
        assert!(
            result.comparison.is_none()
                && result.candidate_binding_hash.is_none()
                && result.staged_candidate_binding_hash.is_none()
                && result.source_binding_hash.is_none()
                && result.native_session_id.is_none()
        );
    }
}
