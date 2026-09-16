//! Cached-only parent locator for retained Message/Attachment dependencies.
//! A target comes from an authenticated child, never a caller-supplied GUID.
//! This creates no fetch, projection, cursor, file lease or write permission.

use std::{path::PathBuf, sync::Arc};

use rustpush::{
    cloud_messages::CloudMessagesClient,
    cloudkit_operation_gate::acquire_cloudkit_read_authentication, DefaultAnisetteProvider,
};

use super::{
    api::{
        cloud_sync_auth_identity_remains_exact, cloud_sync_capture_auth_snapshot,
        map_cloud_sync_transient_failure, CloudSyncNativeAuthMetadata,
        CloudSyncTransientFailureCode,
    },
    cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput,
};
use crate::{
    cloud_sync_canonical_dto::{
        CloudCanonicalEntityKind, CloudCanonicalMessageAssociation, CloudCanonicalPayload,
    },
    cloud_sync_extension_metadata::{parse_projection_metadata_json, ExtensionSessionRole},
    cloud_sync_native_fetch::{
        cloud_sync_unprotect_raw_envelope, CloudNativeProtectionScope, CloudNativeStream,
    },
    cloud_sync_protector,
    cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
    cloud_sync_transient_bridge::{
        bind_envelope, cloud_sync_decode_transient_record_cached_only, CloudTransientDecodeOutcome,
        CloudTransientDecodeRequest, CloudTransientExpectedChangeKind,
    },
};

/// Diagnostic locator only. Even a complete target is not an absent-record,
/// ownership, mutation, or remote-head proof. Raw parent IDs and salt stay native.
pub struct CloudSyncDependencyParentTarget {
    pub source_change_id_hash: String,
    pub source_record_id_hash: String,
    pub source_generation: u64,
    pub message_generation: u64,
    pub parent_logical_key_hash: String,
    pub parent_record_id_hash: String,
    pub native_session_id: String,
    pub binding_hash: String,
}

pub struct CloudSyncDependencyParentResult {
    pub target: Option<CloudSyncDependencyParentTarget>,
    pub failure_code: Option<CloudSyncTransientFailureCode>,
}

fn failure(code: CloudSyncTransientFailureCode) -> CloudSyncDependencyParentResult {
    CloudSyncDependencyParentResult {
        target: None,
        failure_code: Some(code),
    }
}

fn keyed_hash(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Select only a dependency actually declared by the validated canonical DTO.
/// Return the GUID only inside Rust; exact bytes matter for Apple's HMAC name.
fn selected_message_parent(
    payload: &CloudCanonicalPayload,
    expected_hash: &str,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<String, ()> {
    if !keyed_hash(expected_hash) {
        return Err(());
    }
    let mut parents = Vec::<(String, String)>::new();
    match payload {
        CloudCanonicalPayload::Message(message) => {
            if let Some(bytes) = message.decoded_extension_payload().value() {
                let (_, context) = parse_projection_metadata_json(bytes).map_err(|_| ())?;
                if let Some(context) = context {
                    if context.role == ExtensionSessionRole::Update {
                        parents.push((context.session_guid, context.session_logical_key_hash));
                    }
                }
            }
            if let Some(reply) = message.reply() {
                parents.push((
                    reply.parent_guid().to_owned(),
                    reply.parent_hash().value().to_owned(),
                ));
            }
            match message.association() {
                CloudCanonicalMessageAssociation::None => {}
                CloudCanonicalMessageAssociation::Sticker(parent)
                | CloudCanonicalMessageAssociation::ReactionAdd { parent, .. }
                | CloudCanonicalMessageAssociation::ReactionRemove { parent, .. } => {
                    parents.push((
                        parent.parent_guid().to_owned(),
                        parent.parent_hash().value().to_owned(),
                    ));
                }
            }
        }
        CloudCanonicalPayload::Attachment(attachment) => {
            if let (Some(guid), Some(hash)) = (
                attachment.owner_message_guid(),
                attachment.owner_message_key_hash(),
            ) {
                parents.push((guid.to_owned(), hash.value().to_owned()));
            }
        }
        _ => return Err(()),
    }
    let mut selected = None;
    for (guid, declared_hash) in parents {
        let actual = hasher
            .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, &guid)
            .map_err(|_| ())?;
        if actual.value() != declared_hash {
            return Err(());
        }
        if declared_hash != expected_hash {
            continue;
        }
        if selected.as_ref().is_some_and(|previous| previous != &guid) {
            return Err(());
        }
        selected = Some(guid);
    }
    selected.ok_or(())
}

/// Derive a keyed physical record locator using only cached same-container
/// identity and PCS. Callers must separately prove the selected source is still
/// the current durable child and target generation before using this observation.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_locate_protected_message_parent(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    expected_auth: CloudSyncNativeAuthMetadata,
    source_zone: String,
    source_generation: u64,
    message_generation: u64,
    expected_parent_logical_key_hash: String,
    source: CloudSyncChatIdentitySourceInput,
) -> CloudSyncDependencyParentResult {
    if message_generation == 0 || !keyed_hash(&expected_parent_logical_key_hash) {
        return failure(CloudSyncTransientFailureCode::InvalidRequest);
    }
    let stream = match source_zone.as_str() {
        "messageManateeZone" => CloudNativeStream::Messages,
        "attachmentManateeZone" => CloudNativeStream::Attachments,
        _ => return failure(CloudSyncTransientFailureCode::InvalidRequest),
    };
    let request = match CloudTransientDecodeRequest::new(
        PathBuf::from(&storage_directory),
        expected_auth.account_fingerprint.clone(),
        expected_auth.protected_store_identity.clone(),
        "com.apple.messages.cloud".into(),
        "private".into(),
        source_zone.clone(),
        "messages".into(),
        2,
        stream,
        source_generation,
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
            Ok(auth) => auth,
            Err(_) => return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch),
        };
    if !cloud_sync_auth_identity_remains_exact(
        &expected_auth,
        &before,
        &expected_auth.account_fingerprint,
        &expected_auth.protected_store_identity,
    ) {
        return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch);
    }
    let container = match cloud_messages_client
        .get_cached_container_for_read_authentication(&permit)
        .await
    {
        Ok(container) => container,
        Err(_) => return failure(CloudSyncTransientFailureCode::ReadAuthenticationScope),
    };
    let decoded = match cloud_sync_decode_transient_record_cached_only(
        cloud_messages_client,
        &permit,
        request.clone(),
    )
    .await
    {
        CloudTransientDecodeOutcome::Ready(decoded) => decoded,
        CloudTransientDecodeOutcome::Failure(error) => {
            return failure(map_cloud_sync_transient_failure(error))
        }
        _ => return failure(CloudSyncTransientFailureCode::MalformedRecord),
    };
    let Some(payload) = decoded.payload() else {
        return failure(CloudSyncTransientFailureCode::MalformedRecord);
    };
    let hasher = match cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
        Ok(hasher) => hasher,
        Err(_) => return failure(CloudSyncTransientFailureCode::DecoderFailure),
    };
    let parent_guid =
        match selected_message_parent(payload, &expected_parent_logical_key_hash, &hasher) {
            Ok(guid) => guid,
            Err(_) => return failure(CloudSyncTransientFailureCode::InvalidRequest),
        };
    let record_name = match crate::cloud_sync_outbound::deterministic_message_record_name(
        &parent_guid,
        &container.user_id,
    ) {
        Ok(name) => name,
        Err(_) => return failure(CloudSyncTransientFailureCode::InvalidRequest),
    };
    let record_hash = hasher.server_record_id_hash(&record_name);
    let after =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch),
        };
    let current_container = match cloud_messages_client
        .get_cached_container_for_read_authentication(&permit)
        .await
    {
        Ok(container) => container,
        Err(_) => return failure(CloudSyncTransientFailureCode::ReadAuthenticationScope),
    };
    if !Arc::ptr_eq(&container, &current_container)
        || !cloud_sync_auth_identity_remains_exact(
            &before,
            &after,
            &expected_auth.account_fingerprint,
            &expected_auth.protected_store_identity,
        )
    {
        return failure(CloudSyncTransientFailureCode::ActiveAccountMismatch);
    }
    // Reopen and bind the exact protected child after the final await. No
    // replaced reference or stale source can yield even a cached locator.
    let protection =
        match CloudNativeProtectionScope::new(after.account_fingerprint.clone(), stream) {
            Ok(scope) => scope,
            Err(_) => return failure(CloudSyncTransientFailureCode::InvalidRequest),
        };
    let child = match cloud_sync_unprotect_raw_envelope(
        PathBuf::from(&storage_directory),
        &protection,
        stream,
        source_generation,
        &source.protected_raw_envelope_reference,
    ) {
        Ok(child) => child,
        Err(_) => return failure(CloudSyncTransientFailureCode::DecoderFailure),
    };
    if let Err(error) = bind_envelope(&request, &child, &hasher) {
        return failure(map_cloud_sync_transient_failure(error));
    }
    let binding_hash = hasher.digest(
        b"OpenBubbles Cloud Sync V2 dependency locator v1\0",
        &serde_json::json!([
            after.native_session_id,
            after.account_fingerprint,
            after.protected_store_identity,
            source_zone,
            source_generation,
            message_generation,
            source.change_id_hash,
            source.record_id_hash,
            source.etag_hash,
            source.payload_sha256,
            source.payload_length,
            source.server_modified_at_millis,
            source.protected_raw_envelope_reference,
            expected_parent_logical_key_hash,
            record_hash,
        ])
        .to_string(),
    );
    CloudSyncDependencyParentResult {
        target: Some(CloudSyncDependencyParentTarget {
            source_change_id_hash: source.change_id_hash,
            source_record_id_hash: source.record_id_hash,
            source_generation,
            message_generation,
            parent_logical_key_hash: expected_parent_logical_key_hash,
            parent_record_id_hash: record_hash,
            native_session_id: after.native_session_id,
            binding_hash,
        }),
        failure_code: None,
    }
}

#[cfg(test)]
#[path = "cloud_sync_dependency_tests.rs"]
mod tests;
