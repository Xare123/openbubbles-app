//! Historical source projection, not live-send proof or write authority.
//! Known sent identities are exact. The historical received candidate represents
//! an unknown original receiving endpoint as a present empty scalar, never a
//! guessed current chat preference. This is not live received provenance. The
//! app coordinator keeps this candidate deferred pending live compatibility proof.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_canonical_dto::{
    CloudCanonicalChatPayload, CloudCanonicalChatStyle, CloudCanonicalService,
};
use crate::cloud_sync_historical_source::{HistoricalArchiveOrigin, HistoricalArchiveSource};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use rustpush::cloud_messages::{
    cloudmessagesp::{MessageProto, MessageProto3, MessageProto4},
    CloudMessage, GZipWrapper, MessageFlags,
};

pub(crate) fn project_historical_plain_text(
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<CloudMessage, Failure> {
    // A media source must go through child upload/readback and a media-aware
    // parent projector. Never silently archive just its caption as plain text.
    if source.media().is_some() {
        return Err(Failure::UnsupportedMessage);
    }
    if chat.service() != CloudCanonicalService::IMessage {
        return Err(Failure::UnsupportedMessage);
    }
    let peer = bare(source.peer());
    let sender = bare(source.sender());
    let sent = source.origin() == HistoricalArchiveOrigin::HistoricalSent;
    if peer.is_empty() || sender.is_empty() {
        return Err(Failure::BindingMismatch);
    }
    let (chat_id, route) = if let Some(group) = source.group_metadata() {
        // Link an old message to the exact decoded CloudKit parent. The stored
        // member list may be newer than this message, so it is not a historical
        // membership claim and must not be substituted for the parent identity.
        let aliases = [chat.guid(), chat.group_id(), chat.original_group_id()];
        if chat.style() != CloudCanonicalChatStyle::Group
            || chat.guid() != format!("iMessage;+;{}", chat.chat_identifier())
            || !aliases.contains(&source.chat_guid())
            || group
                .1
                .as_deref()
                .is_some_and(|id| id != chat.group_id() && id != chat.original_group_id())
        {
            return Err(Failure::BindingMismatch);
        }
        (chat.group_id().to_owned(), chat.guid().to_owned())
    } else {
        let route = format!("iMessage;-;{peer}");
        // A captured provisional direct GUID becomes the confirmed parent's
        // gid. Only that exact lineage proves its new canonical route; matching
        // the peer alone does not authorize moving a historical message.
        let captured_lineage = source.parent_state().is_some_and(|state| {
            uuid::Uuid::parse_str(source.chat_guid()).is_ok()
                && [chat.group_id(), chat.original_group_id()].contains(&source.chat_guid())
                && state
                    .1
                    .as_deref()
                    .is_none_or(|id| id == chat.group_id() || id == chat.original_group_id())
        });
        if chat.style() != CloudCanonicalChatStyle::Direct
            || (sent && peer == sender)
            || (!sent && peer != sender)
            || (source.chat_guid() != route && !captured_lineage)
            || chat.guid() != route
            || chat.chat_identifier() != peer
            || chat.participant_handles().is_empty()
            || chat.participant_handles().iter().any(|v| bare(v) != peer)
        {
            return Err(Failure::BindingMismatch);
        }
        (route.clone(), route)
    };
    let time = i64::try_from(source.sent_timestamp())
        .ok()
        .and_then(|v| v.checked_sub(978_307_200_000))
        .and_then(|v| v.checked_mul(1_000_000))
        .filter(|v| *v > 0)
        .ok_or(Failure::MalformedMessage)?;
    Ok(CloudMessage {
        utm: None,
        r#type: 1,
        error: 0,
        chat_id,
        sender: if sent {
            String::new()
        } else {
            sender.to_owned()
        },
        time,
        msg_proto_2: None,
        // Empty is an explicit unknown scalar, not an omitted encrypted field.
        // Original known sender/peer, direction, GUID, time and body remain exact.
        destination_caller_id: if sent {
            sender.to_owned()
        } else {
            String::new()
        },
        msg_proto: GZipWrapper(MessageProto {
            unk1: 1,
            text: Some(source.text().to_owned()),
            date_read: Some(0),
            date_delivered: Some(0),
            unk10: Some(0),
            unk11: Some(0),
            unk14: Some(0),
            ..Default::default()
        }),
        flags: MessageFlags::IS_FINISHED
            | MessageFlags::IS_SENT
            | MessageFlags::WAS_DATA_DETECTED
            | if sent {
                MessageFlags::IS_FROM_ME
            } else {
                MessageFlags::empty()
            },
        guid: source.guid().to_owned(),
        msg_proto_3: Some(GZipWrapper(MessageProto3 {
            unk2: Some(0),
            unk3: Some(0),
        })),
        service: "iMessage".into(),
        msg_proto_4: Some(GZipWrapper(MessageProto4 {
            service: Some("iMessage".into()),
            group_id: Some(route),
            schedule_type: Some(0),
            schedule_state: Some(0),
            sent_or_received_off_grid: Some(0),
            ..Default::default()
        })),
    })
}

fn bare(handle: &str) -> &str {
    handle
        .strip_prefix("mailto:")
        .or_else(|| handle.strip_prefix("tel:"))
        .unwrap_or(handle)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::cloud_sync_canonical_dto::CloudCanonicalField;
    use crate::cloud_sync_historical_source::{
        HistoricalBinding, HistoricalGroupMetadata, HistoricalRow,
    };

    pub(crate) fn group_source(
        sent: bool,
        local_guid: &str,
        cloud_guid: Option<&str>,
    ) -> HistoricalArchiveSource {
        HistoricalArchiveSource::capture_group(
            &HistoricalRow {
                guid: "historical-group-message",
                text: "Preserved group text",
                sender: if sent {
                    "mailto:original@example.invalid"
                } else {
                    "mailto:departed@example.invalid"
                },
                peer: "peer@example.invalid",
                chat_guid: local_guid,
                date_created_ms: 1_700_000_000_123,
                is_from_me: sent,
            },
            &HistoricalBinding {
                snapshot_sha256: &"a".repeat(64),
                account_fingerprint: "synthetic-account",
                protected_store_identity: "synthetic-store",
            },
            sent,
            HistoricalGroupMetadata(
                1,
                cloud_guid.map(str::to_owned),
                vec![
                    ("peer@example.invalid".into(), "iMessage".into()),
                    ("+15555550100".into(), "iMessage".into()),
                ],
            ),
        )
        .unwrap()
    }

    #[test]
    fn group_history_uses_verified_parent_ids_not_first_member_or_current_alias() {
        let parent = crate::cloud_sync_outbound::attachment_parent_test_support::group();
        for sent in [false, true] {
            for alias in [parent.guid(), parent.group_id(), parent.original_group_id()] {
                let source = group_source(sent, alias, Some(parent.group_id()));
                let value = project_historical_plain_text(&source, &parent).unwrap();
                assert_eq!(value.chat_id, parent.group_id());
                assert_eq!(
                    value.msg_proto_4.unwrap().0.group_id.as_deref(),
                    Some(parent.guid())
                );
                assert_eq!(value.guid, source.guid());
                assert_eq!(value.msg_proto.0.text.as_deref(), Some(source.text()));
                assert_eq!(
                    value.destination_caller_id,
                    if sent { "original@example.invalid" } else { "" }
                );
                assert_eq!(
                    value.sender,
                    if sent { "" } else { "departed@example.invalid" }
                );
            }
        }
    }

    #[test]
    fn group_history_requires_matching_ids_and_cannot_become_direct_history() {
        let parent = crate::cloud_sync_outbound::attachment_parent_test_support::group();
        let original = group_source(true, parent.original_group_id(), None);
        assert!(project_historical_plain_text(&original, &parent).is_ok());
        for wrong in [
            group_source(true, "unrelated-local-group", Some(parent.group_id())),
            group_source(true, parent.guid(), Some("unrelated-cloud-group")),
        ] {
            assert!(project_historical_plain_text(&wrong, &parent).is_err());
        }
        assert!(project_historical_plain_text(
            &original,
            &chat("peer@example.invalid", CloudCanonicalChatStyle::Direct)
        )
        .is_err());
        assert!(
            project_historical_plain_text(&source(true, "Plain", &"a".repeat(64)), &parent)
                .is_err()
        );
    }

    pub(crate) fn source(sent: bool, text: &str, snapshot: &str) -> HistoricalArchiveSource {
        HistoricalArchiveSource::capture(
            &HistoricalRow {
                guid: "historical-source-guid",
                text,
                sender: if sent {
                    "mailto:original@example.invalid"
                } else {
                    "mailto:peer@example.invalid"
                },
                peer: "peer@example.invalid",
                chat_guid: "iMessage;-;peer@example.invalid",
                date_created_ms: 1_700_000_000_123,
                is_from_me: sent,
            },
            &HistoricalBinding {
                snapshot_sha256: snapshot,
                account_fingerprint: "synthetic-account",
                protected_store_identity: "synthetic-store",
            },
            sent,
        )
        .unwrap()
    }

    pub(crate) fn chat(peer: &str, style: CloudCanonicalChatStyle) -> CloudCanonicalChatPayload {
        CloudCanonicalChatPayload::new(
            format!("iMessage;-;{peer}"),
            peer.into(),
            "group-alias".into(),
            "original-alias".into(),
            CloudCanonicalService::IMessage,
            style,
            vec![format!("mailto:{peer}")],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value("mailto:new-preference@example.invalid".into()),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap()
    }

    #[test]
    fn known_sent_source_keeps_original_address_text_guid_and_millisecond_time() {
        let source = source(true, "Historical content 😀", &"a".repeat(64));
        let message = project_historical_plain_text(
            &source,
            &chat("peer@example.invalid", CloudCanonicalChatStyle::Direct),
        )
        .unwrap();
        assert_eq!(message.guid, source.guid());
        assert_eq!(
            message.msg_proto.0.text.as_deref(),
            Some("Historical content 😀")
        );
        assert_eq!(message.time, 721_692_800_123_000_000);
        assert_eq!(message.destination_caller_id, "original@example.invalid");
        assert_eq!(message.sender, "");
        assert!(message.flags.contains(MessageFlags::IS_FROM_ME));
        assert!(!message
            .flags
            .intersects(MessageFlags::IS_READ | MessageFlags::IS_DELIVERED));
    }

    #[test]
    fn incoming_unknown_endpoint_is_preserved_not_replaced_by_current_chat_preference() {
        let source = source(false, "Incoming history", &"a".repeat(64));
        let projected = project_historical_plain_text(
            &source,
            &chat("peer@example.invalid", CloudCanonicalChatStyle::Direct),
        )
        .unwrap();
        assert_eq!(projected.destination_caller_id, "");
        assert_eq!(projected.sender, "peer@example.invalid");
        assert_eq!(projected.guid, source.guid());
        assert_eq!(
            projected.msg_proto.0.text.as_deref(),
            Some("Incoming history")
        );
        assert_eq!(projected.time, 721_692_800_123_000_000);
        assert!(!projected.flags.intersects(
            MessageFlags::IS_FROM_ME | MessageFlags::IS_READ | MessageFlags::IS_DELIVERED
        ));
    }

    #[test]
    fn parent_route_and_group_cannot_be_guessed() {
        let source = source(true, "History", &"a".repeat(64));
        for parent in [
            chat("other@example.invalid", CloudCanonicalChatStyle::Direct),
            chat("peer@example.invalid", CloudCanonicalChatStyle::Group),
        ] {
            assert!(project_historical_plain_text(&source, &parent).is_err());
        }
    }

    #[test]
    fn provisional_direct_history_requires_captured_lineage_not_peer_similarity() {
        let route = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
        let binding = HistoricalBinding {
            snapshot_sha256: &"a".repeat(64),
            account_fingerprint: "synthetic-account",
            protected_store_identity: "synthetic-store",
        };
        let mut state = crate::cloud_sync_historical_chat::tests::parent();
        state.1 = Some(route.into());
        let parent = CloudCanonicalChatPayload::new(
            "iMessage;-;peer@example.invalid".into(),
            "peer@example.invalid".into(),
            route.into(),
            route.into(),
            CloudCanonicalService::IMessage,
            CloudCanonicalChatStyle::Direct,
            vec!["mailto:peer@example.invalid".into()],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap();
        for sent in [false, true] {
            let source = crate::cloud_sync_historical_chat::tests::direct_source(
                &binding,
                state.clone(),
                route,
                sent,
            );
            let message = project_historical_plain_text(&source, &parent).unwrap();
            assert_eq!(message.chat_id, parent.guid());
            assert_eq!(message.guid, source.guid());
            assert_eq!(
                message.destination_caller_id,
                if sent { "self@example.invalid" } else { "" }
            );
            // Same canonical route and peer, but unrelated gid/ogid.
            assert!(project_historical_plain_text(
                &source,
                &chat("peer@example.invalid", CloudCanonicalChatStyle::Direct)
            )
            .is_err());
        }
        state.1 = Some("unrelated-lineage".into());
        let source =
            crate::cloud_sync_historical_chat::tests::direct_source(&binding, state, route, true);
        assert!(project_historical_plain_text(&source, &parent).is_err());
    }
}
