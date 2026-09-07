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
    cloud_sync_chat_identity::{validate_chat_identity_candidate, CloudChatIdentityComparison},
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
    pub source_binding_hash: Option<String>,
    pub native_session_id: Option<String>,
    pub failure_code: Option<CloudSyncTransientFailureCode>,
}

fn failure(code: CloudSyncTransientFailureCode) -> CloudSyncChatIdentityResult {
    CloudSyncChatIdentityResult {
        comparison: None,
        candidate_binding_hash: None,
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
            b"OpenBubbles Cloud Sync V2 Chat observation source v1\0",
            &binding,
        )),
        candidate_binding_hash: Some(observation.candidate_binding_hash),
        native_session_id: Some(before.native_session_id),
        failure_code: None,
    }
}

#[cfg(test)]
mod cloud_sync_chat_identity_bridge_tests {
    use super::*;

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
                && result.source_binding_hash.is_none()
                && result.native_session_id.is_none()
        );
    }
}
