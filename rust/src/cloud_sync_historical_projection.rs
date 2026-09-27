//! Historical source projection, not live-send proof or write authority.
//! Known sent identities can be represented exactly. Old incoming rows do not
//! retain their receiving endpoint, so they remain discoverable but cannot use
//! this create projection yet. Never substitute a current chat sender preference.
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
    if source.origin() != HistoricalArchiveOrigin::HistoricalSent
        || chat.service() != CloudCanonicalService::IMessage
        || chat.style() != CloudCanonicalChatStyle::Direct
    {
        return Err(Failure::UnsupportedMessage);
    }
    let peer = bare(source.peer());
    let sender = bare(source.sender());
    let route = format!("iMessage;-;{peer}");
    if peer.is_empty()
        || sender.is_empty()
        || peer == sender
        || source.chat_guid() != route
        || chat.guid() != route
        || chat.chat_identifier() != peer
        || chat.participant_handles().is_empty()
        || chat.participant_handles().iter().any(|v| bare(v) != peer)
    {
        return Err(Failure::BindingMismatch);
    }
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
        chat_id: route.clone(),
        sender: String::new(),
        time,
        msg_proto_2: None,
        destination_caller_id: sender.to_owned(),
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
            | MessageFlags::IS_FROM_ME
            | MessageFlags::WAS_DATA_DETECTED,
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
    use crate::cloud_sync_historical_source::{HistoricalBinding, HistoricalRow};

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
    fn incoming_missing_endpoint_is_not_replaced_by_current_chat_preference() {
        let source = source(false, "Incoming history", &"a".repeat(64));
        assert!(matches!(
            project_historical_plain_text(
                &source,
                &chat("peer@example.invalid", CloudCanonicalChatStyle::Direct)
            ),
            Err(Failure::UnsupportedMessage)
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
}
