//! Native received-source to CloudMessage projection, not send/write authority.
//! Requires a separately authenticated canonical direct chat. Never calls IDS,
//! uses the current sender preference, or changes outgoing receipt validators.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_canonical_dto::{
    CloudCanonicalChatPayload, CloudCanonicalChatStyle, CloudCanonicalService,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use crate::cloud_sync_received_source::{ReceivedArchiveOrigin, ReceivedArchiveSource};
use rustpush::cloud_messages::{
    cloudmessagesp::{MessageProto, MessageProto3, MessageProto4},
    CloudMessage, GZipWrapper, MessageFlags,
};

pub(crate) fn project_received_plain_text(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<CloudMessage, Failure> {
    if chat.service() != CloudCanonicalService::IMessage
        || chat.style() != CloudCanonicalChatStyle::Direct
    {
        return Err(Failure::UnsupportedMessage);
    }
    let expected_route = format!("iMessage;-;{}", source.peer());
    if chat.chat_identifier() != source.peer()
        || chat.guid() != expected_route
        || chat.participant_handles().is_empty()
        || chat
            .participant_handles()
            .iter()
            .any(|handle| bare(handle) != source.peer())
    {
        return Err(Failure::BindingMismatch);
    }
    // IDS stores Unix milliseconds; CloudMessage uses Apple-epoch nanoseconds.
    // Checked conversion preserves source precision and rejects impossible time.
    let millis = i64::try_from(source.sent_timestamp()).map_err(|_| Failure::MalformedMessage)?;
    let time = millis
        .checked_sub(978_307_200_000)
        .and_then(|v| v.checked_mul(1_000_000))
        .filter(|v| *v > 0)
        .ok_or(Failure::MalformedMessage)?;
    let mirrored = source.origin() == ReceivedArchiveOrigin::Mirrored;
    let flags = MessageFlags::IS_FINISHED
        | MessageFlags::IS_SENT
        | MessageFlags::WAS_DATA_DETECTED
        | if mirrored {
            MessageFlags::IS_FROM_ME
        } else {
            MessageFlags::empty()
        };
    Ok(CloudMessage {
        utm: None,
        r#type: 1,
        error: 0,
        chat_id: expected_route.clone(),
        sender: if mirrored {
            String::new()
        } else {
            bare(source.sender()).to_owned()
        },
        time,
        msg_proto_2: None,
        // Unlike legacy Message.toCloud, the exact received endpoint is the
        // source of truth. A later selected alias must not rewrite provenance.
        destination_caller_id: bare(source.recipient()).to_owned(),
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
        flags,
        guid: source.guid().to_owned(),
        msg_proto_3: Some(GZipWrapper(MessageProto3 {
            unk2: Some(0),
            unk3: Some(0),
        })),
        service: "iMessage".into(),
        msg_proto_4: Some(GZipWrapper(MessageProto4 {
            service: Some("iMessage".into()),
            group_id: Some(expected_route),
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
mod tests {
    use super::*;
    use crate::cloud_sync_canonical_dto::CloudCanonicalField;
    use crate::cloud_sync_received_record_match::{
        compare_received_record, ReceivedRecordMatchVerdict,
    };
    use crate::cloud_sync_received_source::tests::fixture;

    fn chat(
        peer: &str,
        style: CloudCanonicalChatStyle,
        sender_preference: &str,
    ) -> CloudCanonicalChatPayload {
        CloudCanonicalChatPayload::new(
            format!("iMessage;-;{peer}"),
            peer.into(),
            "group-alias".into(),
            "original-alias".into(),
            CloudCanonicalService::IMessage,
            style,
            vec![format!("mailto:{peer}")],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value(sender_preference.into()),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap()
    }
    #[test]
    fn incoming_and_mirrored_preserve_source_direction_endpoint_time_and_text() {
        for mirrored in [false, true] {
            let (wire, handles) = fixture(mirrored, "legible received text 😀");
            let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
            let canonical = chat(
                "remote@example.com",
                CloudCanonicalChatStyle::Direct,
                "mailto:new-alias@example.com",
            );
            let projected = project_received_plain_text(&source, &canonical).unwrap();
            assert_eq!(projected.guid, wire.id);
            assert_eq!(
                projected.sender,
                if mirrored { "" } else { "remote@example.com" }
            );
            assert_eq!(projected.destination_caller_id, "owner@example.com");
            assert_eq!(projected.time, 721_692_800_000_000_000);
            assert_eq!(
                projected.msg_proto.0.text.as_deref(),
                Some("legible received text 😀")
            );
            assert_eq!(projected.flags.contains(MessageFlags::IS_FROM_ME), mirrored);
            assert_eq!(
                compare_received_record(&projected, &projected),
                ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
            );
        }
    }
    #[test]
    fn unrelated_or_group_parent_is_not_guessed_from_title_or_current_sender() {
        let (wire, handles) = fixture(false, "source");
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert!(project_received_plain_text(
            &source,
            &chat(
                "other@example.com",
                CloudCanonicalChatStyle::Direct,
                "mailto:owner@example.com"
            )
        )
        .is_err());
        assert!(project_received_plain_text(
            &source,
            &chat(
                "remote@example.com",
                CloudCanonicalChatStyle::Group,
                "mailto:owner@example.com"
            )
        )
        .is_err());
    }
    #[test]
    fn invalid_apple_epoch_or_overflow_never_wraps() {
        for timestamp in [1, 978_307_200_000, i64::MAX as u64] {
            let (mut wire, handles) = fixture(false, "source");
            wire.sent_timestamp = timestamp;
            let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
            assert!(project_received_plain_text(
                &source,
                &chat(
                    "remote@example.com",
                    CloudCanonicalChatStyle::Direct,
                    "mailto:owner@example.com"
                )
            )
            .is_err());
        }
    }
}
