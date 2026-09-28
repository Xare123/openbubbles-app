//! Historical parent conversion from the committed source, not a live
//! send, remote absence proof or upload permission. This is the native half of
//! the parent dependency: source -> immutable chat envelope -> exact reopen.
//! The app must still durably admit that envelope and prove its remote identity.
#![cfg_attr(not(test), allow(dead_code))]

use std::{io::Cursor, path::PathBuf};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use rustpush::cloud_messages::{
    cloudmessagesp::ChatProto, validate_group_chat_create, validate_historical_direct_chat_create,
    CloudChat, CloudParticipant, CloudProp, GZipWrapper,
};

use crate::{
    cloud_sync_historical_source::{
        HistoricalArchiveSource, HistoricalBinding, HistoricalParentState,
    },
    cloud_sync_historical_source_stage::{
        open_historical_archive_source, NativeHistoricalArchiveStage,
    },
    cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact,
    cloud_sync_outbound::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage},
    cloud_sync_outbound_chat::{
        open_staged_historical_chat, outbound_chat_payload_identity,
        stage_outbound_historical_direct_chat, stage_outbound_historical_group_chat,
    },
};

/// Used only before first durable admission. The caller must first look for an
/// already owned parent operation. An ambiguous adoption result is not a reason
/// to call this again: recovery uses open_historical_parent below.
pub(crate) fn stage_historical_parent(
    storage: PathBuf,
    binding: &HistoricalBinding,
    source_stage: &NativeHistoricalArchiveStage,
) -> Result<NativeProtectedOutboundStage, Failure> {
    let source = open_historical_archive_source(storage.clone(), binding, source_stage)?;
    if source.group_metadata().is_none() {
        let candidate = project_historical_direct_parent(&source)?;
        return stage_outbound_historical_direct_chat(
            storage,
            binding.account_fingerprint.to_owned(),
            candidate,
        );
    }
    // Legacy uses a chat-prefixed unsigned 64-bit value for a new group route.
    // Allocate once, then retain it in the same protected envelope as the record
    // name. A saved route always wins and is never reminted.
    let allocated_identifier = format!("chat{}", rand::random::<u64>());
    let candidate = project_historical_group_parent(&source, &allocated_identifier)?;
    stage_outbound_historical_group_chat(storage, binding.account_fingerprint.to_owned(), candidate)
}

/// Reopen both committed envelopes and prove that the selected source produces
/// every byte of this exact parent. No identity or timestamp is minted on
/// restart. The app origin binding must pin the originally selected source:
/// equivalent metadata from another message is not proof of that ownership.
/// The source must remain retained until its parent has settled.
pub(crate) fn open_historical_parent(
    storage: PathBuf,
    binding: &HistoricalBinding,
    source_stage: &NativeHistoricalArchiveStage,
    parent_stage: &NativeProtectedOutboundStage,
) -> Result<(CloudChat, String), Failure> {
    cloud_sync_verify_committed_lease_exact(
        storage.clone(),
        &parent_stage.lease_reference,
        std::slice::from_ref(&parent_stage.protected_payload_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    open_historical_parent_for_identity(storage, binding, source_stage, parent_stage)
}

/// Read-only comparison before admission also needs the original, uncommitted
/// candidate. This reopens the committed source and verifies every parent byte,
/// but grants no submission authority. Write/recovery callers must use the
/// committed-parent opener above, never this identity-only entry point.
pub(crate) fn open_historical_parent_for_identity(
    storage: PathBuf,
    binding: &HistoricalBinding,
    source_stage: &NativeHistoricalArchiveStage,
    parent_stage: &NativeProtectedOutboundStage,
) -> Result<(CloudChat, String), Failure> {
    let source = open_historical_archive_source(storage.clone(), binding, source_stage)?;
    if parent_stage.protected_server_record_reference != parent_stage.protected_payload_reference {
        return Err(Failure::BindingMismatch);
    }
    let (candidate, record_name) = open_staged_historical_chat(
        storage.clone(),
        binding.account_fingerprint.to_owned(),
        &parent_stage.protected_payload_reference,
        &parent_stage.payload_sha256,
        &parent_stage.server_record_id_hash,
    )?;
    let expected = if source.group_metadata().is_some() {
        project_historical_group_parent(&source, &candidate.chat_identifier)?
    } else {
        project_historical_direct_parent(&source)?
    };
    let (hash, length) = outbound_chat_payload_identity(&expected, &record_name)?;
    if hash != parent_stage.payload_sha256 || length != parent_stage.payload_length {
        return Err(Failure::BindingMismatch);
    }
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let logical = hasher
        .canonical_entity_key_hash(
            crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Chat,
            &candidate.guid,
        )
        .map_err(|_| Failure::BindingMismatch)?;
    if logical.value() != parent_stage.logical_entity_key_hash {
        return Err(Failure::BindingMismatch);
    }
    Ok((candidate, record_name))
}

/// Mirrors the metadata-bearing portion of legacy Chat.toCloud without writing
/// a local Chat, choosing a current account alias, or using wall-clock time.
/// The stored member list describes this snapshot, not historical membership at
/// each message timestamp. The selected handle is only parent metadata; it is
/// never substituted for the missing receiving endpoint of an old message.
fn project_historical_group_parent(
    source: &HistoricalArchiveSource,
    allocated_identifier: &str,
) -> Result<CloudChat, Failure> {
    let group = source.group_metadata().ok_or(Failure::UnsupportedMessage)?;
    let state = source.parent_state().ok_or(Failure::UnsupportedMessage)?;
    if state.8 || state.7.is_some() {
        // Do not silently drop group-photo references. Their asset dependency
        // requires the historical media path, not a fake local file or GUID.
        return Err(Failure::UnsupportedMessage);
    }
    if group
        .1
        .as_ref()
        .zip(state.1.as_ref())
        .is_some_and(|(a, b)| a != b)
    {
        return Err(Failure::BindingMismatch);
    }
    let mut candidate = if let Some(saved) = saved_parent(state)? {
        validate_group_chat_create(&saved).map_err(|_| Failure::UnsupportedMessage)?;
        saved
    } else {
        let group_id = group
            .1
            .as_deref()
            .or(state.1.as_deref())
            .unwrap_or(source.chat_guid());
        let identifier = if let Some(saved_route) = source.chat_guid().strip_prefix("iMessage;+;") {
            saved_route
        } else {
            if !allocated_identifier
                .strip_prefix("chat")
                .is_some_and(|suffix| {
                    suffix
                        .parse::<u64>()
                        .is_ok_and(|number| number.to_string() == suffix)
                })
            {
                return Err(Failure::MalformedMessage);
            }
            allocated_identifier
        };
        CloudChat {
            style: 43,
            is_filtered: 0,
            successful_query: 1,
            state: 3,
            chat_identifier: identifier.to_owned(),
            guid: format!("iMessage;+;{identifier}"),
            group_id: group_id.to_owned(),
            original_group_id: group_id.to_owned(),
            service_name: "iMessage".into(),
            properties: Some(CloudProp {
                number_of_times_respondedto_thread: Some(3),
                should_force_to_sms: Some(false),
                message_handshake_state: Some(1),
                ..Default::default()
            }),
            proto001: Some(GZipWrapper(ChatProto { unk1: Some(0) })),
            ..Default::default()
        }
    };
    let aliases = [
        candidate.guid.as_str(),
        candidate.group_id.as_str(),
        candidate.original_group_id.as_str(),
    ];
    if !aliases.contains(&source.chat_guid())
        || group
            .1
            .as_deref()
            .into_iter()
            .chain(state.1.as_deref())
            .any(|id| id != candidate.group_id && id != candidate.original_group_id)
    {
        return Err(Failure::BindingMismatch);
    }
    // Keep the original saved gid, ogid, route, proto and non-overlaid properties.
    candidate.participants = group
        .2
        .iter()
        .map(|(uri, _)| CloudParticipant { uri: uri.clone() })
        .collect();
    apply_captured_metadata(&mut candidate, state)?;
    validate_group_chat_create(&candidate).map_err(|_| Failure::UnsupportedMessage)?;
    Ok(candidate)
}

/// Direct history keeps the original lineage too. It is not a new local send:
/// no fresh gid, current self alias, timestamp or synthetic Message is invented.
fn project_historical_direct_parent(
    source: &HistoricalArchiveSource,
) -> Result<CloudChat, Failure> {
    if source.group_metadata().is_some() {
        return Err(Failure::UnsupportedMessage);
    }
    let state = source.parent_state().ok_or(Failure::UnsupportedMessage)?;
    if state.8 || state.7.is_some() {
        return Err(Failure::UnsupportedMessage);
    }
    let mut candidate = if let Some(saved) = saved_parent(state)? {
        validate_historical_direct_chat_create(&saved).map_err(|_| Failure::UnsupportedMessage)?;
        saved
    } else {
        // Capture accepts either a canonical direct GUID or a provisional UUID.
        // The latter remains the stable gid when the ordinary reader projects
        // the canonical direct route after confirmed parent readback.
        if source.chat_guid() != format!("iMessage;-;{}", source.peer())
            && uuid::Uuid::parse_str(source.chat_guid()).is_err()
        {
            return Err(Failure::BindingMismatch);
        }
        let group_id = state.1.as_deref().unwrap_or(source.chat_guid());
        CloudChat {
            style: 45,
            is_filtered: 0,
            successful_query: 1,
            state: 3,
            chat_identifier: source.peer().to_owned(),
            guid: format!("iMessage;-;{}", source.peer()),
            group_id: group_id.to_owned(),
            original_group_id: group_id.to_owned(),
            service_name: "iMessage".into(),
            participants: vec![CloudParticipant {
                uri: source.peer().to_owned(),
            }],
            properties: Some(CloudProp {
                number_of_times_respondedto_thread: Some(3),
                should_force_to_sms: Some(false),
                message_handshake_state: Some(1),
                ..Default::default()
            }),
            proto001: Some(GZipWrapper(ChatProto { unk1: Some(0) })),
            ..Default::default()
        }
    };
    if candidate.chat_identifier != source.peer()
        || ![
            candidate.guid.as_str(),
            candidate.group_id.as_str(),
            candidate.original_group_id.as_str(),
        ]
        .contains(&source.chat_guid())
        || state
            .1
            .as_deref()
            .is_some_and(|id| id != candidate.group_id && id != candidate.original_group_id)
    {
        return Err(Failure::BindingMismatch);
    }
    apply_captured_metadata(&mut candidate, state)?;
    validate_historical_direct_chat_create(&candidate).map_err(|_| Failure::UnsupportedMessage)?;
    Ok(candidate)
}

fn saved_parent(state: &HistoricalParentState) -> Result<Option<CloudChat>, Failure> {
    let Some(encoded) = &state.11 else {
        return Ok(None);
    };
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| Failure::MalformedMessage)?;
    let saved: CloudChat =
        plist::from_reader(Cursor::new(&bytes)).map_err(|_| Failure::MalformedMessage)?;
    // Do not silently discard fields that this version cannot preserve.
    let original: plist::Value =
        plist::from_reader(Cursor::new(&bytes)).map_err(|_| Failure::MalformedMessage)?;
    let mut roundtrip = Vec::new();
    plist::to_writer_binary(&mut roundtrip, &saved).map_err(|_| Failure::MalformedMessage)?;
    let restored: plist::Value =
        plist::from_reader(Cursor::new(roundtrip)).map_err(|_| Failure::MalformedMessage)?;
    if original != restored {
        return Err(Failure::UnsupportedMessage);
    }
    Ok(Some(saved))
}

fn apply_captured_metadata(
    candidate: &mut CloudChat,
    state: &HistoricalParentState,
) -> Result<(), Failure> {
    candidate.display_name = state.3.clone();
    let handle = state.2.as_deref().ok_or(Failure::UnsupportedMessage)?;
    candidate.last_addressed_handle = handle
        .strip_prefix("mailto:")
        .or_else(|| handle.strip_prefix("tel:"))
        .unwrap_or(handle)
        .to_owned();
    candidate.last_read_message_timestamp = match state.6 {
        None => 0,
        Some(ms) => ms
            .checked_sub(978_307_200_000)
            .and_then(|v| v.checked_mul(1_000_000))
            .filter(|v| *v >= 0)
            .ok_or(Failure::MalformedMessage)?,
    };
    let properties = candidate.properties.get_or_insert_with(CloudProp::default);
    properties.pv =
        Some(u32::try_from(state.4.unwrap_or(1)).map_err(|_| Failure::MalformedMessage)?);
    properties.last_seen_message_guid = state.5.clone();
    // Preserve saved lineage and append captured aliases without sorting or
    // replacing the stable primary IDs. These aliases also participate in the
    // existing conservative identity-overlap check before admission.
    for alias in &state.12 {
        if !properties.legacy_group_identifiers.contains(alias) {
            properties.legacy_group_identifiers.push(alias.clone());
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{
        cloud_sync_historical_source::{
            HistoricalGroupMetadata, HistoricalParentState, HistoricalRow,
        },
        cloud_sync_historical_source_stage::stage_historical_archive_source,
        cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease,
        cloud_sync_outbound_chat::verify_chat_readback,
    };

    pub(crate) fn parent() -> HistoricalParentState {
        HistoricalParentState(
            1,
            Some("stable-group".into()),
            Some("mailto:self@example.invalid".into()),
            Some("Saved title".into()),
            Some(7),
            Some("last-read-guid".into()),
            Some(1_700_000_000_000),
            None,
            false,
            None,
            false,
            None,
            vec!["older-group-alias".into()],
        )
    }

    pub(crate) fn source(
        binding: &HistoricalBinding,
        parent: HistoricalParentState,
        route: &str,
        sent: bool,
    ) -> HistoricalArchiveSource {
        HistoricalArchiveSource::capture_with_parent(
            &HistoricalRow {
                guid: "historical-group-message",
                text: "synthetic historical text",
                sender: if sent {
                    "self@example.invalid"
                } else {
                    "peer@example.invalid"
                },
                peer: "peer@example.invalid",
                chat_guid: route,
                date_created_ms: 1_700_000_000_000,
                is_from_me: sent,
            },
            binding,
            sent,
            Some(HistoricalGroupMetadata(
                1,
                Some("stable-group".into()),
                vec![("peer@example.invalid".into(), "iMessage".into())],
            )),
            Some(parent),
        )
        .unwrap()
    }

    fn binding(identity: &str) -> HistoricalBinding<'_> {
        HistoricalBinding {
            snapshot_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            account_fingerprint: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            protected_store_identity: identity,
        }
    }

    pub(crate) fn direct_source(
        binding: &HistoricalBinding,
        parent: HistoricalParentState,
        route: &str,
        sent: bool,
    ) -> HistoricalArchiveSource {
        HistoricalArchiveSource::capture_with_parent(
            &HistoricalRow {
                guid: "historical-direct-message",
                text: "Synthetic direct history",
                sender: if sent {
                    "self@example.invalid"
                } else {
                    "peer@example.invalid"
                },
                peer: "peer@example.invalid",
                chat_guid: route,
                date_created_ms: 1_700_000_000_000,
                is_from_me: sent,
            },
            binding,
            sent,
            None,
            Some(parent),
        )
        .unwrap()
    }

    #[test]
    fn direct_history_preserves_canonical_and_provisional_lineage_for_both_origins() {
        let binding = binding("synthetic-store");
        for route in [
            "iMessage;-;peer@example.invalid",
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        ] {
            for sent in [false, true] {
                let mut state = parent();
                state.1 = Some(route.into());
                let source = direct_source(&binding, state, route, sent);
                let source_hash = source.source_sha256().unwrap();
                let projected = project_historical_direct_parent(&source).unwrap();
                assert_eq!(projected.style, 45);
                assert_eq!(projected.guid, "iMessage;-;peer@example.invalid");
                assert_eq!(projected.group_id, route);
                assert_eq!(projected.original_group_id, route);
                assert_eq!(projected.display_name.as_deref(), Some("Saved title"));
                assert_eq!(projected.last_addressed_handle, "self@example.invalid");
                assert_eq!(projected.properties.as_ref().unwrap().pv, Some(7));
                assert_eq!(
                    projected.last_read_message_timestamp,
                    721_692_800_000_000_000
                );
                assert_eq!(source.source_sha256().unwrap(), source_hash);
                assert!(project_historical_group_parent(&source, "chat1").is_err());
            }
        }
    }

    #[test]
    fn direct_history_keeps_saved_proto_lineage_and_known_null_metadata() {
        let binding = binding("synthetic-store");
        let route = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
        let mut state = parent();
        state.1 = Some(route.into());
        let mut saved =
            project_historical_direct_parent(&direct_source(&binding, state.clone(), route, true))
                .unwrap();
        saved.original_group_id = "original-direct-lineage".into();
        saved.proto001.as_mut().unwrap().unk1 = Some(8);
        saved.properties.as_mut().unwrap().gpufc = Some(5);
        let mut bytes = vec![];
        plist::to_writer_binary(&mut bytes, &saved).unwrap();
        state.11 = Some(STANDARD.encode(bytes));
        state.3 = None;
        state.5 = None;
        let reopened =
            project_historical_direct_parent(&direct_source(&binding, state, route, true)).unwrap();
        assert_eq!(reopened.original_group_id, saved.original_group_id);
        assert_eq!(reopened.proto001.unwrap().unk1, Some(8));
        assert_eq!(reopened.properties.as_ref().unwrap().gpufc, Some(5));
        assert_eq!(reopened.properties.unwrap().last_seen_message_guid, None);
        assert_eq!(reopened.display_name, None);
    }

    #[test]
    fn direct_history_rejects_missing_alias_malformed_saved_data_and_asset_loss() {
        let binding = binding("synthetic-store");
        let route = "iMessage;-;peer@example.invalid";
        let mut initial = parent();
        initial.1 = Some(route.into());
        for change in [
            |s: &mut HistoricalParentState| s.2 = None,
            |s: &mut HistoricalParentState| s.7 = Some("photo".into()),
            |s: &mut HistoricalParentState| s.8 = true,
            |s: &mut HistoricalParentState| s.11 = Some(STANDARD.encode(b"not a plist")),
        ] {
            let mut state = initial.clone();
            change(&mut state);
            assert!(
                project_historical_direct_parent(&direct_source(&binding, state, route, true))
                    .is_err()
            );
        }
        let mut saved = project_historical_direct_parent(&direct_source(
            &binding,
            initial.clone(),
            route,
            true,
        ))
        .unwrap();
        saved.chat_identifier = "other@example.invalid".into();
        saved.guid = "iMessage;-;other@example.invalid".into();
        saved.participants[0].uri = "other@example.invalid".into();
        let mut bytes = vec![];
        plist::to_writer_binary(&mut bytes, &saved).unwrap();
        initial.11 = Some(STANDARD.encode(bytes));
        assert!(
            project_historical_direct_parent(&direct_source(&binding, initial, route, true))
                .is_err()
        );
    }

    fn saved_parent(chat: &CloudChat) -> HistoricalParentState {
        let mut bytes = Vec::new();
        plist::to_writer_binary(&mut bytes, chat).unwrap();
        let mut state = parent();
        state.11 = Some(STANDARD.encode(bytes));
        state
    }

    #[test]
    fn group_parent_preserves_metadata_and_one_member_group_without_changing_message_origin() {
        let binding = binding("installation");
        for sent in [false, true] {
            let source = source(&binding, parent(), "stable-group", sent);
            let before = source.encode().unwrap();
            let chat = project_historical_group_parent(&source, "chat123").unwrap();
            assert_eq!(chat.style, 43);
            assert_eq!(chat.guid, "iMessage;+;chat123");
            assert_eq!(chat.group_id, "stable-group");
            assert_eq!(chat.original_group_id, "stable-group");
            assert_eq!(chat.participants.len(), 1);
            assert_eq!(chat.display_name.as_deref(), Some("Saved title"));
            assert_eq!(chat.last_addressed_handle, "self@example.invalid");
            assert_eq!(chat.last_read_message_timestamp, 721_692_800_000_000_000);
            let props = chat.properties.unwrap();
            assert_eq!(props.pv, Some(7));
            assert_eq!(
                props.last_seen_message_guid.as_deref(),
                Some("last-read-guid")
            );
            assert_eq!(props.legacy_group_identifiers, ["older-group-alias"]);
            assert_eq!(source.encode().unwrap(), before);
        }
    }

    #[test]
    fn saved_parent_keeps_route_distinct_original_id_and_unmodified_properties() {
        let binding = binding("installation");
        let original_source = source(&binding, parent(), "stable-group", true);
        let mut original = project_historical_group_parent(&original_source, "chat123").unwrap();
        original.original_group_id = "original-group".into();
        original.properties.as_mut().unwrap().gpufc = Some(11);
        original
            .properties
            .as_mut()
            .unwrap()
            .legacy_group_identifiers
            .push("saved-alias".into());
        let mut state = saved_parent(&original);
        state.3 = Some(String::new());
        let source = source(&binding, state, "original-group", true);
        let restored = project_historical_group_parent(&source, "chatDO-NOT-USE").unwrap();
        assert_eq!(restored.guid, original.guid);
        assert_eq!(restored.chat_identifier, original.chat_identifier);
        assert_eq!(restored.original_group_id, "original-group");
        assert_eq!(restored.display_name.as_deref(), Some(""));
        assert_eq!(restored.properties.as_ref().unwrap().gpufc, Some(11));
        assert_eq!(
            restored
                .properties
                .as_ref()
                .unwrap()
                .legacy_group_identifiers,
            ["older-group-alias", "saved-alias"]
        );
        assert_eq!(restored.proto001.unwrap().unk1, Some(0));
    }

    #[test]
    fn saved_route_uses_snapshot_route_before_allocated_identifier() {
        let binding = binding("installation");
        let source = source(&binding, parent(), "iMessage;+;chatExisting", false);
        let chat = project_historical_group_parent(&source, "chatDO-NOT-USE").unwrap();
        assert_eq!(chat.chat_identifier, "chatExisting");
        assert_eq!(chat.group_id, "stable-group");
    }

    #[test]
    fn malformed_saved_plist_unknown_fields_and_route_conflicts_never_remint_identity() {
        let binding = binding("installation");
        let mut state = parent();
        state.11 = Some(STANDARD.encode(b"bplist00"));
        assert!(project_historical_group_parent(
            &source(&binding, state, "stable-group", false),
            "chat123"
        )
        .is_err());
        let initial = source(&binding, parent(), "stable-group", false);
        let candidate = project_historical_group_parent(&initial, "chat123").unwrap();
        let mut saved = saved_parent(&candidate);
        let mut value: plist::Value = plist::from_reader(Cursor::new(
            STANDARD.decode(saved.11.as_ref().unwrap()).unwrap(),
        ))
        .unwrap();
        value.as_dictionary_mut().unwrap().insert(
            "unknownRequiredMetadata".into(),
            plist::Value::String("retain-me".into()),
        );
        let mut bytes = Vec::new();
        plist::to_writer_binary(&mut bytes, &value).unwrap();
        saved.11 = Some(STANDARD.encode(bytes));
        assert!(project_historical_group_parent(
            &source(&binding, saved, "stable-group", false),
            "chat123"
        )
        .is_err());
        assert!(project_historical_group_parent(
            &source(&binding, saved_parent(&candidate), "unrelated-group", false),
            "chat123"
        )
        .is_err());
    }

    #[test]
    fn unsupported_metadata_is_retained_as_failure_not_silently_dropped() {
        let binding = binding("installation");
        for change in 0..8 {
            let mut state = parent();
            match change {
                0 => state.8 = true,
                1 => state.7 = Some("photo-guid".into()),
                2 => state.2 = None,
                3 => state.1 = Some("different-group".into()),
                4 => state.4 = Some(-1),
                5 => state.6 = Some(i64::MAX),
                6 => state.6 = Some(0),
                _ => state.12.push("invalid\0alias".into()),
            }
            assert!(
                project_historical_group_parent(
                    &source(&binding, state, "stable-group", true),
                    "chat123"
                )
                .is_err(),
                "case {change}"
            );
        }
    }

    #[test]
    fn committed_source_and_parent_reopen_exactly_without_reminting() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_path_buf();
        let identity = crate::cloud_sync_protector::protected_store_identity(
            storage.to_string_lossy().into_owned(),
        )
        .unwrap();
        let binding = binding(&identity);
        let original = source(&binding, parent(), "stable-group", false);
        let source_stage = stage_historical_archive_source(
            storage.clone(),
            &binding,
            &original.source_sha256().unwrap(),
            &original.encode().unwrap(),
        )
        .unwrap();
        assert!(stage_historical_parent(storage.clone(), &binding, &source_stage).is_err());
        cloud_sync_commit_protected_page_lease(
            storage.clone(),
            &source_stage.lease_reference,
            std::slice::from_ref(&source_stage.protected_reference),
        )
        .unwrap();
        let mut parent_stage =
            stage_historical_parent(storage.clone(), &binding, &source_stage).unwrap();
        assert!(
            open_historical_parent(storage.clone(), &binding, &source_stage, &parent_stage)
                .is_err()
        );
        cloud_sync_commit_protected_page_lease(
            storage.clone(),
            &parent_stage.lease_reference,
            std::slice::from_ref(&parent_stage.protected_payload_reference),
        )
        .unwrap();
        let (first, record) =
            open_historical_parent(storage.clone(), &binding, &source_stage, &parent_stage)
                .unwrap();
        let (reopened, same_record) =
            open_historical_parent(storage.clone(), &binding, &source_stage, &parent_stage)
                .unwrap();
        assert_eq!(record, same_record);
        assert_eq!(first.chat_identifier, reopened.chat_identifier);
        assert_eq!(
            verify_chat_readback(
                &reopened,
                &same_record,
                &record,
                &parent_stage.payload_sha256
            )
            .unwrap(),
            parent_stage.payload_sha256
        );
        parent_stage.payload_length += 1;
        assert!(
            open_historical_parent(storage.clone(), &binding, &source_stage, &parent_stage)
                .is_err()
        );
        parent_stage.payload_length -= 1;
        let logical = parent_stage.logical_entity_key_hash.clone();
        parent_stage.logical_entity_key_hash = "L".repeat(43);
        assert!(
            open_historical_parent(storage.clone(), &binding, &source_stage, &parent_stage)
                .is_err()
        );
        parent_stage.logical_entity_key_hash = logical;
        let mut altered_parent = parent();
        altered_parent.3 = Some("different source title".into());
        let altered_source = source(&binding, altered_parent, "stable-group", false);
        let altered_stage = stage_historical_archive_source(
            storage.clone(),
            &binding,
            &altered_source.source_sha256().unwrap(),
            &altered_source.encode().unwrap(),
        )
        .unwrap();
        cloud_sync_commit_protected_page_lease(
            storage.clone(),
            &altered_stage.lease_reference,
            std::slice::from_ref(&altered_stage.protected_reference),
        )
        .unwrap();
        assert!(
            open_historical_parent(storage.clone(), &binding, &altered_stage, &parent_stage)
                .is_err()
        );
        let mut changed = source_stage.clone();
        changed.source_sha256 = "f".repeat(64);
        assert!(
            open_historical_parent(storage.clone(), &binding, &changed, &parent_stage).is_err()
        );
        let wrong = HistoricalBinding {
            snapshot_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            ..binding
        };
        assert!(open_historical_parent(storage, &wrong, &source_stage, &parent_stage).is_err());
    }
}
