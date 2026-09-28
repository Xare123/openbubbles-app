//! Historical ownership for the existing one-shot attachment upload engine.
//! This does not manufacture an IDS context or grant a historical queue policy.
//! The app must retain the same lifecycle, journal, and mutation-capability fences.
use super::*;
use crate::{
    cloud_sync_attachment_upload::AttachmentUploadPlan,
    cloud_sync_historical_source::{HistoricalArchiveSource, HistoricalBinding},
    cloud_sync_historical_source_stage::{
        open_historical_archive_source, NativeHistoricalArchiveStage,
    },
    cloud_sync_outbound_attachment::AttachmentSourceKind,
};

enum SourceContext {
    Ids(CloudSyncNativeSendReceiptContext),
    Historical(CloudSyncHistoricalAttachmentContext),
}

/// Private, already-opened source owner. The public input is revalidated at
/// every asynchronous boundary and before the durable consume claim.
pub(super) struct UploadContext {
    pub(super) storage_directory: String,
    pub(super) account_fingerprint: String,
    pub(super) protected_store_identity: String,
    pub(super) source_kind: AttachmentSourceKind,
    source: SourceContext,
}

impl From<CloudSyncNativeSendReceiptContext> for UploadContext {
    fn from(context: CloudSyncNativeSendReceiptContext) -> Self {
        Self {
            storage_directory: context.storage_directory.clone(),
            account_fingerprint: context.account_fingerprint.clone(),
            protected_store_identity: context.protected_store_identity.clone(),
            source_kind: AttachmentSourceKind::IdsSent,
            source: SourceContext::Ids(context),
        }
    }
}

impl UploadContext {
    fn historical(
        input: CloudSyncHistoricalAttachmentContext,
        source: &HistoricalArchiveSource,
    ) -> Self {
        Self {
            storage_directory: input.storage_directory.clone(),
            account_fingerprint: input.expected_auth.account_fingerprint.clone(),
            protected_store_identity: input.expected_auth.protected_store_identity.clone(),
            source_kind: AttachmentSourceKind::historical(source),
            source: SourceContext::Historical(input),
        }
    }

    pub(super) fn require_auth(&self, actual: &CloudSyncNativeAuthMetadata) -> anyhow::Result<()> {
        match &self.source {
            SourceContext::Ids(context) => {
                if self.source_kind != AttachmentSourceKind::IdsSent {
                    return Err(anyhow!("cloud_sync_attachment_upload_source_changed"));
                }
                cloud_sync_require_source_context_auth(context, actual)
            }
            SourceContext::Historical(input) => {
                let source = open_source(input, actual)?;
                if AttachmentSourceKind::historical(&source) != self.source_kind {
                    return Err(anyhow!("cloud_sync_attachment_upload_source_changed"));
                }
                Ok(())
            }
        }
    }
}

pub(super) fn open_source(
    input: &CloudSyncHistoricalAttachmentContext,
    actual: &CloudSyncNativeAuthMetadata,
) -> anyhow::Result<HistoricalArchiveSource> {
    cloud_sync_require_historical_auth(&input.expected_auth, actual)?;
    let binding = &input.source;
    if binding.account_fingerprint != actual.account_fingerprint
        || binding.protected_store_identity != actual.protected_store_identity
    {
        return Err(anyhow!("cloud_sync_historical_attachment_identity_changed"));
    }
    let source = open_historical_archive_source(
        PathBuf::from(&input.storage_directory),
        &HistoricalBinding {
            snapshot_sha256: &binding.snapshot_sha256,
            account_fingerprint: &binding.account_fingerprint,
            protected_store_identity: &binding.protected_store_identity,
        },
        &NativeHistoricalArchiveStage {
            message_guid_hash: binding.message_guid_hash.clone(),
            source_sha256: binding.source_sha256.clone(),
            protected_reference: binding.protected_reference.clone(),
            lease_reference: binding.lease_reference.clone(),
            payload_sha256: binding.payload_sha256.clone(),
            payload_length: binding.payload_length,
        },
    )
    .map_err(|_| anyhow!("cloud_sync_historical_attachment_source_unavailable"))?;
    if source.media().is_none() {
        return Err(anyhow!("cloud_sync_historical_attachment_source_invalid"));
    }
    Ok(source)
}

/// Read the complete, source-bound inventory before allocating randomized plans.
pub(super) fn inspect_sources(
    context: &CloudSyncHistoricalAttachmentContext,
    auth: &CloudSyncNativeAuthMetadata,
) -> anyhow::Result<Vec<CloudSyncAttachmentSourceEntry>> {
    let source = open_source(context, auth)?;
    let hasher =
        crate::cloud_sync_protector::semantic_identifier_hasher(context.storage_directory.clone())
            .map_err(|_| anyhow!("cloud_sync_historical_attachment_source_unavailable"))?;
    source.media().ok_or_else(|| anyhow!("cloud_sync_historical_attachment_source_invalid"))?
        .4.1.iter().map(|entry| {
            let original = entry.3.as_deref()
                .ok_or_else(|| anyhow!("cloud_sync_historical_attachment_source_invalid"))?;
            let material = crate::cloud_sync_historical_attachment_source::historical_attachment_upload_material(
                &source, original).map_err(|_| anyhow!("cloud_sync_historical_attachment_source_invalid"))?;
            let logical = hasher.canonical_attachment_key_hash(&material.meta.guid)
                .map_err(|_| anyhow!("cloud_sync_historical_attachment_source_invalid"))?;
            Ok(CloudSyncAttachmentSourceEntry {
                original_attachment_guid: original.to_owned(),
                reflected_attachment_guid: material.meta.guid,
                logical_entity_key_hash: logical.value().to_owned(),
            })
        }).collect()
}

/// Decode the original completed stage under an explicit owner. Historical
/// content must equal the descriptor-derived metadata in full, not just GUID.
pub(super) fn open_record(
    storage: &str,
    auth: &CloudSyncNativeAuthMetadata,
    input: &CloudSyncPreparedMessageCreateInput,
    historical: Option<&CloudSyncHistoricalAttachmentContext>,
) -> Result<
    (
        AttachmentSourceKind,
        rustpush::cloud_messages::CloudAttachment,
        String,
    ),
    CloudSyncOutboundSafeCode,
> {
    let source = match historical {
        None => None,
        Some(context) => {
            if context.storage_directory != storage {
                return Err(CloudSyncOutboundSafeCode::InvalidScope);
            }
            Some(
                open_source(context, auth)
                    .map_err(|_| CloudSyncOutboundSafeCode::BindingMismatch)?,
            )
        }
    };
    let kind = source
        .as_ref()
        .map(AttachmentSourceKind::historical)
        .unwrap_or(AttachmentSourceKind::IdsSent);
    let (attachment, record) =
        crate::cloud_sync_outbound_attachment::open_staged_attachment_for_source(
            kind,
            PathBuf::from(storage),
            auth.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
            &input.server_record_id_hash,
        )
        .map_err(map_cloud_sync_outbound_failure)?;
    if let Some(source) = source {
        let material =
            crate::cloud_sync_historical_attachment_source::historical_attachment_upload_material(
                &source,
                &attachment.cm.0.guid,
            )
            .map_err(map_cloud_sync_outbound_failure)?;
        let mut expected = Vec::new();
        let mut actual = Vec::new();
        plist::to_writer_binary(&mut expected, &material.meta)
            .map_err(|_| CloudSyncOutboundSafeCode::MalformedMessage)?;
        plist::to_writer_binary(&mut actual, &attachment.cm.0)
            .map_err(|_| CloudSyncOutboundSafeCode::MalformedMessage)?;
        if expected != actual {
            return Err(CloudSyncOutboundSafeCode::BindingMismatch);
        }
    }
    Ok((kind, attachment, record))
}

fn open_file(path: &str) -> anyhow::Result<File> {
    let path = PathBuf::from(path);
    let metadata = fs::symlink_metadata(&path)
        .map_err(|_| anyhow!("cloud_sync_attachment_source_unavailable"))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(anyhow!("cloud_sync_attachment_source_unavailable"));
    }
    let file = File::open(path).map_err(|_| anyhow!("cloud_sync_attachment_source_unavailable"))?;
    if !file.metadata().is_ok_and(|value| value.is_file()) {
        return Err(anyhow!("cloud_sync_attachment_source_unavailable"));
    }
    Ok(file)
}

fn open_plan(
    context: &UploadContext,
    stage: &CloudSyncAttachmentUploadPlanReference,
    source: &HistoricalArchiveSource,
) -> anyhow::Result<AttachmentUploadPlan> {
    let plan = crate::cloud_sync_attachment_upload::open_journaled_attachment_upload(
        PathBuf::from(&context.storage_directory),
        context.account_fingerprint.clone(),
        &stage.logical_entity_key_hash,
        &stage.protected_payload_reference,
        &stage.payload_sha256,
        &stage.server_record_id_hash,
        &stage.lease_reference,
    )
    .map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_unavailable"))?;
    plan.validate_historical_parent_source(source)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_source_changed"))?;
    Ok(plan)
}

fn receipt_binding(
    context: &UploadContext,
    stage: &CloudSyncAttachmentUploadPlanReference,
    plan: &AttachmentUploadPlan,
) -> anyhow::Result<crate::cloud_sync_attachment_upload_receipt::AttachmentUploadReceiptBinding> {
    Ok(
        crate::cloud_sync_attachment_upload_receipt::AttachmentUploadReceiptBinding {
            account_fingerprint: context.account_fingerprint.clone(),
            protected_store_identity: context.protected_store_identity.clone(),
            plan_payload_sha256: stage.payload_sha256.clone(),
            upload_attempt_id: plan
                .upload_attempt_id()
                .map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?
                .to_owned(),
        },
    )
}

async fn capture_auth(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage: String,
) -> anyhow::Result<CloudSyncNativeAuthMetadata> {
    cloud_sync_capture_auth_snapshot(client, storage)
        .await
        .map_err(|_| anyhow!("cloud_sync_historical_attachment_auth_unavailable"))
}

pub(super) async fn stage_plan(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    input: CloudSyncHistoricalAttachmentContext,
    original_attachment_guid: String,
    source_path: String,
) -> anyhow::Result<CloudSyncAttachmentUploadPlanResult> {
    let auth = capture_auth(client, input.storage_directory.clone()).await?;
    let source = open_source(&input, &auth)?;
    let context = UploadContext::historical(input, &source);
    let writer = client
        .warm_attachment_writer_preparation_lookup_only()
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_auth_unavailable"))?;
    let after = capture_auth(client, context.storage_directory.clone()).await?;
    context.require_auth(&after)?;
    client
        .validate_writer_preparation_binding(&writer)
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_binding_changed"))?;
    let record = cloud_sync_attachment_upload_record_identifier(
        writer.container_scoped_user_id(),
        &Uuid::new_v4().to_string().to_uppercase(),
    )?;
    let mut file = open_file(&source_path)?;
    let plan = crate::cloud_sync_attachment_upload::prepare_verified_historical_upload_plan(
        client,
        &source,
        &original_attachment_guid,
        record,
        &mut file,
        std::path::Path::new(&context.storage_directory),
    )
    .await
    .map_err(|error| anyhow!("{error}"))?;
    let after = capture_auth(client, context.storage_directory.clone()).await?;
    context.require_auth(&after)?;
    client
        .validate_writer_preparation_binding(&writer)
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_binding_changed"))?;
    let upload_attempt_id = plan
        .upload_attempt_id()
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_invalid"))?
        .to_owned();
    let stage = crate::cloud_sync_attachment_upload::stage_attachment_upload(
        PathBuf::from(context.storage_directory),
        context.account_fingerprint,
        &plan,
    )
    .map_err(|_| anyhow!("cloud_sync_attachment_preparation_stage_failed"))?;
    Ok(CloudSyncAttachmentUploadPlanResult {
        stage: cloud_sync_bridge_stage(stage),
        upload_attempt_id,
    })
}

pub(super) async fn prepare_upload(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    input: CloudSyncHistoricalAttachmentContext,
    stage: CloudSyncAttachmentUploadPlanReference,
    original_attachment_guid: String,
    source_path: String,
    timeout: u64,
) -> anyhow::Result<CloudSyncPreparedAttachmentUploadResult> {
    if !(1..=300).contains(&timeout) {
        return Err(anyhow!("cloud_sync_attachment_upload_timeout_invalid"));
    }
    let auth = capture_auth(client, input.storage_directory.clone()).await?;
    let source = open_source(&input, &auth)?;
    let context = UploadContext::historical(input, &source);
    let plan = open_plan(&context, &stage, &source)?;
    let receipt_binding = receipt_binding(&context, &stage, &plan)?;
    let writer_binding = client
        .warm_attachment_writer_preparation_lookup_only()
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
    let record = cloud_sync_attachment_upload_record_identifier(
        writer_binding.container_scoped_user_id(),
        plan.record_name()
            .map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?,
    )?;
    let mut file = open_file(&source_path)?;
    let local_operation_id = format!("upload1:{}", stage.payload_sha256);
    let permit = rustpush::cloudkit_operation_gate::acquire_cloudkit_writer_operation()
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_writer_busy"))?;
    let prepared = permit
        .run(plan.prepare_verified_historical_submission(
            client,
            &writer_binding,
            &source,
            &original_attachment_guid,
            &record,
            local_operation_id.clone(),
            &mut file,
            std::path::Path::new(&context.storage_directory),
            Duration::from_secs(timeout),
        ))
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_prepare_failed"))?;
    let after = capture_auth(client, context.storage_directory.clone()).await?;
    context.require_auth(&after)?;
    client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_binding_changed"))?;
    let handle_binding_sha256 = cloud_sync_new_prepared_handle_binding_sha256();
    let upload_attempt_id = receipt_binding.upload_attempt_id.clone();
    Ok(CloudSyncPreparedAttachmentUploadResult {
        handle: CloudSyncPreparedAttachmentUploadHandle {
            owner: tokio::sync::Mutex::new(Some(CloudSyncAttachmentUploadOwner::Native {
                prepared,
                permit,
                client: client.clone(),
                writer_binding,
                plan,
                local_operation_id,
            })),
            context,
            receipt_binding,
            handle_binding_sha256: handle_binding_sha256.clone(),
            reconciliation_binding_sha256: std::sync::OnceLock::new(),
        },
        handle_binding_sha256,
        upload_attempt_id,
    })
}

async fn load_completion(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    input: CloudSyncHistoricalAttachmentContext,
    stage: &CloudSyncAttachmentUploadPlanReference,
) -> anyhow::Result<(UploadContext, AttachmentUploadPlan, Option<Vec<u8>>)> {
    let auth = capture_auth(client, input.storage_directory.clone()).await?;
    let source = open_source(&input, &auth)?;
    let context = UploadContext::historical(input, &source);
    let plan = open_plan(&context, stage, &source)?;
    let binding = receipt_binding(&context, stage, &plan)?;
    let encoded = plan
        .recover_completed_receipt(std::path::Path::new(&context.storage_directory), &binding)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_receipt_unavailable"))?;
    let after = capture_auth(client, context.storage_directory.clone()).await?;
    context.require_auth(&after)?;
    Ok((context, plan, encoded))
}

pub(super) async fn verify_receipt(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    input: CloudSyncHistoricalAttachmentContext,
    stage: CloudSyncAttachmentUploadPlanReference,
    expected_attempt_id: String,
) -> anyhow::Result<Option<CloudSyncAttachmentUploadReceiptEvidence>> {
    let (_, plan, encoded) = load_completion(client, input, &stage).await?;
    if plan
        .upload_attempt_id()
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?
        != expected_attempt_id
    {
        return Err(anyhow!("cloud_sync_attachment_upload_attempt_changed"));
    }
    Ok(
        encoded.map(|value| CloudSyncAttachmentUploadReceiptEvidence {
            upload_attempt_id: expected_attempt_id,
            plan_payload_sha256: stage.payload_sha256,
            completed_payload_sha256: format!("{:x}", sha2::Sha256::digest(&value)),
            logical_entity_key_hash: stage.logical_entity_key_hash,
            server_record_id_hash: stage.server_record_id_hash,
        }),
    )
}

pub(super) async fn recover(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    input: CloudSyncHistoricalAttachmentContext,
    stage: CloudSyncAttachmentUploadPlanReference,
) -> anyhow::Result<Option<CloudSyncProtectedOutboundStage>> {
    let (context, plan, encoded) = load_completion(client, input, &stage).await?;
    let Some(encoded) = encoded else {
        return Ok(None);
    };
    let attachment = plan
        .validate_completed_envelope(&encoded)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_result_invalid"))?;
    let result = crate::cloud_sync_outbound_attachment::stage_attachment_for_source(
        context.source_kind,
        PathBuf::from(context.storage_directory),
        context.account_fingerprint,
        attachment,
        plan.record_name()
            .map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?,
    )
    .map_err(|_| anyhow!("cloud_sync_attachment_upload_result_stage_failed"))?;
    Ok(Some(cloud_sync_bridge_stage(result)))
}

#[cfg(test)]
fn test_input(
    directory: &std::path::Path,
    sent: bool,
    commit: bool,
) -> CloudSyncHistoricalAttachmentContext {
    use crate::cloud_sync_historical_attachment_source::tests as fixture;
    let original = fixture::source_with(&fixture::descriptor(), sent, |_| {});
    let auth = CloudSyncNativeAuthMetadata {
        account_fingerprint: "A".repeat(43),
        native_session_id: "N".repeat(43),
        protected_store_identity: crate::cloud_sync_protector::protected_store_identity(
            directory.to_string_lossy().into_owned(),
        )
        .unwrap(),
    };
    let snapshot = "ab".repeat(32);
    let binding = HistoricalBinding {
        snapshot_sha256: &snapshot,
        account_fingerprint: &auth.account_fingerprint,
        protected_store_identity: &auth.protected_store_identity,
    };
    let source = HistoricalArchiveSource::capture_with_media(
        &crate::cloud_sync_historical_source::HistoricalRow {
            guid: original.guid(),
            text: original.text(),
            sender: original.sender(),
            peer: original.peer(),
            chat_guid: original.chat_guid(),
            date_created_ms: original.sent_timestamp(),
            is_from_me: sent,
        },
        &binding,
        sent,
        None,
        None,
        original.media().cloned(),
    )
    .unwrap();
    let source_bytes = source.encode().unwrap();
    let stage = crate::cloud_sync_historical_source_stage::stage_historical_archive_source(
        directory.to_path_buf(),
        &binding,
        &source.source_sha256().unwrap(),
        &source_bytes,
    )
    .unwrap();
    if commit {
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
    }
    CloudSyncHistoricalAttachmentContext {
        storage_directory: directory.to_string_lossy().into_owned(),
        source: CloudSyncNativeHistoricalArchiveSourceBinding {
            account_fingerprint: auth.account_fingerprint.clone(),
            protected_store_identity: auth.protected_store_identity.clone(),
            snapshot_sha256: snapshot,
            message_guid_hash: stage.message_guid_hash,
            source_sha256: stage.source_sha256,
            protected_reference: stage.protected_reference,
            lease_reference: stage.lease_reference,
            payload_sha256: stage.payload_sha256,
            payload_length: stage.payload_length,
        },
        expected_auth: auth,
    }
}

#[cfg(test)]
pub(super) fn test_context(directory: &std::path::Path, sent: bool) -> UploadContext {
    let input = test_input(directory, sent, true);
    let source = open_source(&input, &input.expected_auth).unwrap();
    UploadContext::historical(input, &source)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn historical_inventory_matches_final_record_identity_in_both_directions() {
        for sent in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let input = test_input(directory.path(), sent, true);
            let found = inspect_sources(&input, &input.expected_auth).unwrap();
            assert_eq!(found.len(), 1);
            let source = open_source(&input, &input.expected_auth).unwrap();
            let original = source.media().unwrap().4 .1[0].3.as_deref().unwrap();
            let material = crate::cloud_sync_historical_attachment_source::historical_attachment_upload_material(
                &source, original).unwrap();
            let expected = crate::cloud_sync_protector::semantic_identifier_hasher(
                input.storage_directory.clone(),
            )
            .unwrap()
            .canonical_attachment_key_hash(&material.meta.guid)
            .unwrap();
            assert_eq!(found[0].original_attachment_guid, original);
            assert_eq!(found[0].reflected_attachment_guid, material.meta.guid);
            assert_eq!(found[0].logical_entity_key_hash, expected.value());
            let reopened = inspect_sources(&input, &input.expected_auth).unwrap();
            assert_eq!(
                reopened[0].logical_entity_key_hash,
                found[0].logical_entity_key_hash
            );
        }
    }

    #[test]
    fn historical_inventory_rejects_uncommitted_or_substituted_source() {
        let directory = tempfile::tempdir().unwrap();
        let input = test_input(directory.path(), true, false);
        assert!(inspect_sources(&input, &input.expected_auth).is_err());
        let input = test_input(directory.path(), true, true);
        let mut wrong = input.clone();
        wrong.source.snapshot_sha256 = "cd".repeat(32);
        assert!(inspect_sources(&wrong, &input.expected_auth).is_err());
        let mut auth = input.expected_auth.clone();
        auth.account_fingerprint = "B".repeat(43);
        assert!(inspect_sources(&input, &auth).is_err());
    }

    #[test]
    fn historical_owner_requires_original_committed_source_and_every_binding_field() {
        for sent in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let input = test_input(directory.path(), sent, false);
            assert!(open_source(&input, &input.expected_auth).is_err());
            crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
                directory.path().to_path_buf(),
                &input.source.lease_reference,
                std::slice::from_ref(&input.source.protected_reference),
            )
            .unwrap();
            let source = open_source(&input, &input.expected_auth).unwrap();
            let mut owner = UploadContext::historical(input.clone(), &source);
            assert_eq!(
                owner.source_kind,
                if sent {
                    AttachmentSourceKind::HistoricalSent
                } else {
                    AttachmentSourceKind::HistoricalReceived
                }
            );
            owner.require_auth(&input.expected_auth).unwrap();
            owner.source_kind = AttachmentSourceKind::IdsSent;
            assert!(owner.require_auth(&input.expected_auth).is_err());
            for field in 0..9 {
                let mut changed = input.clone();
                match field {
                    0 => changed.source.account_fingerprint = "B".repeat(43),
                    1 => changed.source.protected_store_identity.push('x'),
                    2 => changed.source.snapshot_sha256 = "cc".repeat(32),
                    3 => changed.source.message_guid_hash = "cc".repeat(32),
                    4 => changed.source.source_sha256 = "cc".repeat(32),
                    5 => changed.source.protected_reference.push('x'),
                    6 => changed.source.lease_reference.push('x'),
                    7 => changed.source.payload_sha256 = "cc".repeat(32),
                    _ => changed.source.payload_length += 1,
                }
                assert!(
                    open_source(&changed, &input.expected_auth).is_err(),
                    "field {field}"
                );
            }
            for field in 0..3 {
                let mut auth = input.expected_auth.clone();
                match field {
                    0 => auth.account_fingerprint = "B".repeat(43),
                    1 => auth.protected_store_identity.push('x'),
                    _ => auth.native_session_id = "M".repeat(43),
                }
                assert!(open_source(&input, &auth).is_err());
            }
            assert_eq!(
                format!("{input:?}"),
                "CloudSyncHistoricalAttachmentContext(redacted)"
            );
        }
    }

    fn stage_record(
        context: &CloudSyncHistoricalAttachmentContext,
        alter_metadata: bool,
    ) -> CloudSyncPreparedMessageCreateInput {
        use rustpush::{
            cloud_messages::{CloudAttachment, GZipWrapper},
            cloudkit_proto::{Asset, ProtectionInfo},
        };
        let source = open_source(context, &context.expected_auth).unwrap();
        let guid = source.media().unwrap().4 .1[0].3.as_deref().unwrap();
        let mut material =
            crate::cloud_sync_historical_attachment_source::historical_attachment_upload_material(
                &source, guid,
            )
            .unwrap();
        if alter_metadata {
            material.meta.transfer_name = Some("different-file.jpg".into());
        }
        let record = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE2";
        let attachment = CloudAttachment {
            lqa: Asset {
                signature: Some(vec![4; 21]),
                reference_signature: Some(vec![1; 21]),
                size: Some(material.meta.total_bytes as u64),
                protection_info: Some(ProtectionInfo {
                    protection_info: Some(vec![7; 32]),
                    ..Default::default()
                }),
                record_id: Some(
                    cloud_sync_attachment_upload_record_identifier("owner", record).unwrap(),
                ),
                upload_receipt: Some("synthetic-upload-receipt".into()),
                ..Default::default()
            },
            cm: GZipWrapper(material.meta),
        };
        let stage = crate::cloud_sync_outbound_attachment::stage_attachment_for_source(
            AttachmentSourceKind::historical(&source),
            PathBuf::from(&context.storage_directory),
            context.expected_auth.account_fingerprint.clone(),
            attachment,
            record,
        )
        .unwrap();
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            PathBuf::from(&context.storage_directory),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_payload_reference),
        )
        .unwrap();
        CloudSyncPreparedMessageCreateInput {
            local_operation_id:
                crate::cloud_sync_outbound_attachment::initial_attachment_create_operation_id(
                    &context.expected_auth.account_fingerprint,
                    &stage.logical_entity_key_hash,
                )
                .unwrap(),
            logical_entity_key_hash: stage.logical_entity_key_hash,
            protected_lease_reference: stage.lease_reference,
            protected_payload_reference: stage.protected_payload_reference,
            payload_sha256: stage.payload_sha256,
            protected_server_record_reference: stage.protected_server_record_reference,
            server_record_id_hash: stage.server_record_id_hash,
            apple_operation_uuid: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE1".into(),
            attachment_parent_context: None,
            attachment_parent_group_proof: None,
            received_archive_proof: None,
            historical_archive_proof: None,
            historical_chat_source: None,
        }
    }

    #[test]
    fn historical_child_save_requires_explicit_source_and_complete_original_metadata() {
        for sent in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let context = test_input(directory.path(), sent, true);
            let input = stage_record(&context, false);
            assert!(is_valid_cloud_sync_attachment_create_input(
                &context.expected_auth.account_fingerprint,
                "11111111-2222-4ABC-8DEF-555555555555",
                &input
            ));
            let (kind, _, _) = open_record(
                &context.storage_directory,
                &context.expected_auth,
                &input,
                Some(&context),
            )
            .unwrap();
            assert_eq!(
                kind,
                if sent {
                    AttachmentSourceKind::HistoricalSent
                } else {
                    AttachmentSourceKind::HistoricalReceived
                }
            );
            assert!(open_record(
                &context.storage_directory,
                &context.expected_auth,
                &input,
                None
            )
            .is_err());
            let other = tempfile::tempdir().unwrap();
            assert!(open_record(
                &other.path().to_string_lossy(),
                &context.expected_auth,
                &input,
                Some(&context)
            )
            .is_err());
            let wrong = stage_record(&context, true);
            assert!(open_record(
                &context.storage_directory,
                &context.expected_auth,
                &wrong,
                Some(&context)
            )
            .is_err());
            let mut wrong_digest = input.clone();
            wrong_digest.payload_sha256 = "cc".repeat(32);
            assert!(open_record(
                &context.storage_directory,
                &context.expected_auth,
                &wrong_digest,
                Some(&context)
            )
            .is_err());
        }
    }
}
