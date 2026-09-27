//! Synthetic encrypted-store/API composition. No credentials or live account.
use super::*;
use crate::cloud_sync_archive_discovery_source::ArchiveDiscoverySource;
use crate::cloud_sync_canonical_dto::CloudCanonicalChatStyle;
use crate::cloud_sync_historical_projection::tests::chat;
use crate::cloud_sync_historical_source::{
    HistoricalArchiveSource, HistoricalBinding, HistoricalRow,
};
use crate::cloud_sync_historical_source_stage::stage_historical_archive_source;
use crate::cloud_sync_native_fetch::{
    cloud_sync_commit_protected_page, cloud_sync_commit_protected_page_lease,
    cloud_sync_stage_test_chat_parent,
};
use prost::Message as _;

const CONTAINER: &str = "synthetic-container-user";

fn proof_fixture(
    directory: &std::path::Path,
    commit_source: bool,
) -> CloudSyncHistoricalArchiveCreateProof {
    let storage = directory.to_string_lossy().into_owned();
    let auth = CloudSyncNativeAuthMetadata {
        account_fingerprint: "A".repeat(43),
        native_session_id: "N".repeat(43),
        protected_store_identity: crate::cloud_sync_protector::protected_store_identity(
            storage.clone(),
        )
        .unwrap(),
    };
    let snapshot = "a".repeat(64);
    let binding = HistoricalBinding {
        snapshot_sha256: &snapshot,
        account_fingerprint: &auth.account_fingerprint,
        protected_store_identity: &auth.protected_store_identity,
    };
    let source = HistoricalArchiveSource::capture(
        &HistoricalRow {
            guid: "historical-api-fixture-guid",
            text: "Historical API fixture only 😀",
            sender: "mailto:original@example.invalid",
            peer: "peer@example.invalid",
            chat_guid: "iMessage;-;peer@example.invalid",
            date_created_ms: 1_700_000_000_123,
            is_from_me: true,
        },
        &binding,
        true,
    )
    .unwrap();
    let source = stage_historical_archive_source(
        directory.to_path_buf(),
        &binding,
        &source.source_sha256().unwrap(),
        &source.encode().unwrap(),
    )
    .unwrap();
    if commit_source {
        cloud_sync_commit_protected_page_lease(
            directory.to_path_buf(),
            &source.lease_reference,
            std::slice::from_ref(&source.protected_reference),
        )
        .unwrap();
    }
    use rustpush::cloudkit_proto::{
        record, Identifier, Record, RecordIdentifier, RecordZoneIdentifier,
    };
    let record = Record {
        record_identifier: Some(RecordIdentifier {
            value: Some(Identifier {
                name: Some("historical-chat-parent".into()),
                r#type: Some(1),
            }),
            zone_identifier: Some(RecordZoneIdentifier {
                value: Some(Identifier {
                    name: Some("chatManateeZone".into()),
                    r#type: Some(6),
                }),
                owner_identifier: Some(Identifier {
                    name: Some("synthetic-owner".into()),
                    r#type: Some(7),
                }),
                ..Default::default()
            }),
        }),
        r#type: Some(record::Type {
            name: Some("ChatEncryptedV3".into()),
        }),
        etag: Some("exact-parent-etag".into()),
        permission: Some(1),
        ..Default::default()
    };
    let page = cloud_sync_stage_test_chat_parent(
        directory.to_path_buf(),
        auth.account_fingerprint.clone(),
        7,
        &record,
    );
    let change = &page.changes()[0];
    let chat_source = super::super::cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput {
        change_id_hash: change.change_id().into(),
        record_id_hash: change.record_id_hash().into(),
        etag_hash: change.etag_hash().unwrap().into(),
        payload_sha256: change.payload_digest().into(),
        payload_length: Some(change.payload_length()),
        server_modified_at_millis: change.server_modified_at_millis(),
        protected_raw_envelope_reference: change.protected_raw_envelope_reference().into(),
    };
    cloud_sync_commit_protected_page(
        directory.to_path_buf(),
        &page,
        &[
            change.protected_record_identity_reference().into(),
            change.protected_raw_envelope_reference().into(),
        ],
    )
    .unwrap();
    let request =
        cloud_sync_attachment_group_decode_request(&storage, &auth, 7, &chat_source).unwrap();
    CloudSyncHistoricalArchiveCreateProof {
        storage_directory: storage,
        auth: Arc::new(auth),
        snapshot_sha256: snapshot,
        source,
        chat_generation: 7,
        chat_source,
        request,
        route: chat("peer@example.invalid", CloudCanonicalChatStyle::Direct),
        parent_binding_sha256: "b".repeat(64),
        expires_at: std::time::Instant::now() + Duration::from_secs(300),
    }
}

fn discovery(proof: &CloudSyncHistoricalArchiveCreateProof) -> ArchiveDiscoverySource {
    ArchiveDiscoverySource::Historical {
        snapshot_sha256: proof.snapshot_sha256.clone(),
        stage: proof.source.clone(),
    }
}

fn absent(proof: &CloudSyncHistoricalArchiveCreateProof) -> CloudSyncReceivedRecordObservation {
    CloudSyncReceivedRecordObservation {
        disposition: CloudSyncReceivedRecordDisposition::Absent,
        message_guid_hash: proof.source.message_guid_hash.clone(),
        source_sha256: proof.source.source_sha256.clone(),
        logical_entity_key_hash: "L".repeat(43),
        server_record_id_hash: "R".repeat(43),
        etag_hash: None,
        protected_raw_record_reference: None,
        protected_raw_record_lease_reference: None,
        raw_generation: 9,
    }
}

fn input(
    proof: &CloudSyncHistoricalArchiveCreateProof,
    commit: bool,
) -> CloudSyncPreparedMessageCreateInput {
    let source =
        cloud_sync_validate_historical_create_proof(&proof.storage_directory, &proof.auth, proof)
            .unwrap();
    let stage = crate::cloud_sync_outbound::historical::stage_historical_message(
        PathBuf::from(&proof.storage_directory),
        proof.auth.account_fingerprint.clone(),
        CONTAINER,
        &source,
        &proof.route,
        &proof.parent_binding_sha256,
    )
    .unwrap();
    if commit {
        cloud_sync_commit_protected_page_lease(
            PathBuf::from(&proof.storage_directory),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_payload_reference),
        )
        .unwrap();
    }
    CloudSyncPreparedMessageCreateInput {
        local_operation_id: crate::cloud_sync_outbound::initial_message_create_operation_id(
            &proof.auth.account_fingerprint,
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
        historical_archive_proof: Some(proof.clone()),
    }
}

fn inspection(message: CloudMessage) -> rustpush::cloud_messages::CloudMessageRecordInspection {
    rustpush::cloud_messages::CloudMessageRecordInspection {
        msg_proto: message.msg_proto.0.encode_to_vec(),
        msg_proto_2: message.msg_proto_2.as_ref().map(|v| v.0.encode_to_vec()),
        msg_proto_3: message.msg_proto_3.as_ref().map(|v| v.0.encode_to_vec()),
        msg_proto_4: message.msg_proto_4.as_ref().map(|v| v.0.encode_to_vec()),
        message,
    }
}

#[test]
fn historical_api_absence_requires_exact_fresh_purpose_and_source() {
    let directory = tempfile::tempdir().unwrap();
    let proof = proof_fixture(directory.path(), true);
    let source = discovery(&proof);
    let check =
        |source: &ArchiveDiscoverySource,
         observation: &CloudSyncReceivedRecordObservation,
         raw,
         age| cloud_sync_require_historical_absence(source, observation, raw, age, &proof);
    assert!(check(&source, &absent(&proof), false, Duration::from_secs(1)).is_ok());
    assert!(check(&source, &absent(&proof), true, Duration::ZERO).is_err());
    assert!(check(&source, &absent(&proof), false, Duration::from_secs(61)).is_err());
    for disposition in [
        CloudSyncReceivedRecordDisposition::Equivalent,
        CloudSyncReceivedRecordDisposition::NeedsProjection,
        CloudSyncReceivedRecordDisposition::ConflictingIdentity,
        CloudSyncReceivedRecordDisposition::Unresolved,
    ] {
        let mut observation = absent(&proof);
        observation.disposition = disposition;
        assert!(check(&source, &observation, false, Duration::ZERO).is_err());
    }
    for field in 0..6 {
        let mut observation = absent(&proof);
        match field {
            0 => observation.message_guid_hash = "c".repeat(64),
            1 => observation.source_sha256 = "c".repeat(64),
            2 => observation.raw_generation = 0,
            3 => observation.etag_hash = Some("E".repeat(43)),
            4 => observation.protected_raw_record_reference = Some("unexpected".into()),
            _ => observation.protected_raw_record_lease_reference = Some("unexpected".into()),
        }
        assert!(check(&source, &observation, false, Duration::ZERO).is_err());
    }
    for field in 0..8 {
        let mut altered = proof.clone();
        match field {
            0 => altered.snapshot_sha256 = "c".repeat(64),
            1 => altered.source.source_sha256 = "c".repeat(64),
            2 => altered.source.message_guid_hash = "c".repeat(64),
            3 => altered.source.lease_reference.push('x'),
            4 => altered.source.protected_reference.push('x'),
            5 => altered.source.payload_sha256 = "c".repeat(64),
            6 => altered.source.payload_length += 1,
            _ => altered.source.payload_length = 0,
        }
        assert!(check(&discovery(&altered), &absent(&proof), false, Duration::ZERO).is_err());
    }
    let stage = &proof.source;
    let received = ArchiveDiscoverySource::Received(
        crate::cloud_sync_received_source_stage::NativeReceivedArchiveStage {
            message_guid_hash: stage.message_guid_hash.clone(),
            source_sha256: stage.source_sha256.clone(),
            protected_reference: stage.protected_reference.clone(),
            lease_reference: stage.lease_reference.clone(),
            payload_sha256: stage.payload_sha256.clone(),
            payload_length: stage.payload_length,
        },
    );
    assert!(check(&received, &absent(&proof), false, Duration::ZERO).is_err());
}

#[test]
fn historical_api_proof_reopens_exact_source_and_parent_with_live_scope() {
    let directory = tempfile::tempdir().unwrap();
    let proof = proof_fixture(directory.path(), true);
    assert!(cloud_sync_validate_historical_create_proof(
        &proof.storage_directory,
        &proof.auth,
        &proof
    )
    .is_ok());
    assert_eq!(
        format!("{proof:?}"),
        "CloudSyncHistoricalArchiveCreateProof(redacted)"
    );
    for field in 0..3 {
        let mut auth = CloudSyncNativeAuthMetadata {
            account_fingerprint: proof.auth.account_fingerprint.clone(),
            native_session_id: proof.auth.native_session_id.clone(),
            protected_store_identity: proof.auth.protected_store_identity.clone(),
        };
        match field {
            0 => auth.account_fingerprint = "B".repeat(43),
            1 => auth.native_session_id = "M".repeat(43),
            _ => auth.protected_store_identity = "foreign-store".into(),
        }
        assert!(matches!(
            cloud_sync_validate_historical_create_proof(&proof.storage_directory, &auth, &proof),
            Err(CloudSyncOutboundSafeCode::InvalidScope)
        ));
    }
    for field in 0..8 {
        let mut changed = proof.clone();
        match field {
            0 => changed.expires_at = std::time::Instant::now(),
            1 => changed.storage_directory.push('x'),
            2 => changed.snapshot_sha256 = "c".repeat(64),
            3 => changed.source.source_sha256 = "c".repeat(64),
            4 => changed.chat_generation += 1,
            5 => {
                changed.chat_source.protected_raw_envelope_reference =
                    format!("obcs2.ref.{}", "Z".repeat(43))
            }
            6 => changed.route = chat("other@example.invalid", CloudCanonicalChatStyle::Direct),
            _ => changed.parent_binding_sha256 = "invalid".into(),
        }
        assert!(cloud_sync_validate_historical_create_proof(
            &proof.storage_directory,
            &proof.auth,
            &changed
        )
        .is_err());
    }
    let other = tempfile::tempdir().unwrap();
    let uncommitted = proof_fixture(other.path(), false);
    assert!(cloud_sync_validate_historical_create_proof(
        &uncommitted.storage_directory,
        &uncommitted.auth,
        &uncommitted
    )
    .is_err());
}

#[test]
fn historical_api_message_open_and_raw_readback_keep_origin_and_digest() {
    let directory = tempfile::tempdir().unwrap();
    let proof = proof_fixture(directory.path(), true);
    let mut input = input(&proof, false);
    let open = |input: &CloudSyncPreparedMessageCreateInput| {
        cloud_sync_open_message_create_bound(
            &proof.storage_directory,
            &proof.auth,
            CONTAINER,
            input,
        )
    };
    assert!(open(&input).is_err());
    cloud_sync_commit_protected_page_lease(
        directory.path().to_path_buf(),
        &input.protected_lease_reference,
        std::slice::from_ref(&input.protected_payload_reference),
    )
    .unwrap();
    let opened = open(&input).unwrap();
    assert!(matches!(
        &opened,
        CloudSyncOpenedMessageCreate::HistoricalArchive { .. }
    ));
    assert_eq!(
        opened.message().msg_proto.0.text.as_deref(),
        Some("Historical API fixture only 😀")
    );
    assert!(opened
        .verify_readback(opened.message().clone(), &input.payload_sha256)
        .is_err());
    assert_eq!(
        opened
            .verify_raw_readback(&inspection(opened.message().clone()), &input.payload_sha256)
            .unwrap(),
        input.payload_sha256
    );
    let mut unknown = inspection(opened.message().clone());
    unknown.msg_proto.extend([0xf8, 0x07, 0x01]);
    assert!(opened
        .verify_raw_readback(&unknown, &input.payload_sha256)
        .is_err());
    let mut newer = opened.message().clone();
    newer.msg_proto.0.text = Some("Newer edit".into());
    assert!(opened
        .verify_raw_readback(&inspection(newer), &input.payload_sha256)
        .is_err());
    for field in 0..5 {
        let mut changed = input.clone();
        match field {
            0 => changed.logical_entity_key_hash = "L".repeat(43),
            1 => changed.server_record_id_hash = "R".repeat(43),
            2 => changed.payload_sha256 = "c".repeat(64),
            3 => {
                changed
                    .historical_archive_proof
                    .as_mut()
                    .unwrap()
                    .parent_binding_sha256 = "c".repeat(64)
            }
            _ => {
                changed
                    .historical_archive_proof
                    .as_mut()
                    .unwrap()
                    .source
                    .payload_sha256 = "c".repeat(64)
            }
        }
        assert!(open(&changed).is_err());
    }
    assert!(cloud_sync_open_message_create_bound(
        &proof.storage_directory,
        &proof.auth,
        "foreign-container",
        &input
    )
    .is_err());
    input.historical_archive_proof = None;
    assert!(
        open(&input).is_err(),
        "historical envelope must not become ordinary send proof"
    );
}

#[test]
fn historical_api_rejects_mixed_origin_and_nonmessage_inputs() {
    let directory = tempfile::tempdir().unwrap();
    let proof = proof_fixture(directory.path(), true);
    let mut input = input(&proof, true);
    input.attachment_parent_context = Some(CloudSyncNativeSendReceiptContext {
        storage_directory: proof.storage_directory.clone(),
        guid_hash: proof.source.message_guid_hash.clone(),
        account_fingerprint: proof.auth.account_fingerprint.clone(),
        protected_store_identity: proof.auth.protected_store_identity.clone(),
        native_session_id: proof.auth.native_session_id.clone(),
        source_binding: None,
    });
    assert!(matches!(
        cloud_sync_open_message_create_bound(
            &proof.storage_directory,
            &proof.auth,
            CONTAINER,
            &input
        ),
        Err(CloudSyncOutboundSafeCode::InvalidRequest)
    ));
    input.attachment_parent_context = None;
    let request = "11111111-2222-4ABC-8DEF-555555555555";
    for chat in [false, true] {
        input.local_operation_id = if chat {
            crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(
                &proof.auth.account_fingerprint,
                &input.logical_entity_key_hash,
            )
        } else {
            crate::cloud_sync_outbound_attachment::initial_attachment_create_operation_id(
                &proof.auth.account_fingerprint,
                &input.logical_entity_key_hash,
            )
        }
        .unwrap();
        let valid = |input: &CloudSyncPreparedMessageCreateInput| {
            if chat {
                is_valid_cloud_sync_chat_create_input(
                    &proof.auth.account_fingerprint,
                    request,
                    input,
                )
            } else {
                is_valid_cloud_sync_attachment_create_input(
                    &proof.auth.account_fingerprint,
                    request,
                    input,
                )
            }
        };
        assert!(!valid(&input));
        input.historical_archive_proof = None;
        assert!(valid(&input));
        input.historical_archive_proof = Some(proof.clone());
    }
}

#[tokio::test]
async fn historical_api_consumed_discovery_cannot_stage_or_reuse_authority() {
    let directory = tempfile::tempdir().unwrap();
    let proof = proof_fixture(directory.path(), true);
    let prepared = CloudSyncPreparedHistoricalDiscovery {
        inner: CloudSyncPreparedReceivedDiscovery {
            pending: tokio::sync::Mutex::new(None),
        },
    };
    for _ in 0..2 {
        let result = cloud_sync_stage_historical_archive_create(&prepared, 0, &proof).await;
        assert!(
            matches!(result, Err(error) if error.to_string() == "cloud_sync_historical_archive_discovery_consumed")
        );
    }
    cloud_sync_discard_historical_discovery(&prepared).await;
}
