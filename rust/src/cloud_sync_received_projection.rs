//! Native received-source to CloudMessage projection, not send/write authority.
//! Requires a separately authenticated canonical chat. Never calls IDS,
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
    if source.has_media() {
        return Err(Failure::UnsupportedMessage);
    }
    project_direct_headers(source, chat)
}

fn project_direct_headers(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<CloudMessage, Failure> {
    if chat.service() != CloudCanonicalService::IMessage
        || chat.style() != CloudCanonicalChatStyle::Direct
        || source.group_id().is_some()
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
    project_headers(source, expected_route.clone(), expected_route)
}

/// An exact captured wire group ID must belong to the authenticated parent.
/// Current members/title/sender preference cannot establish that relationship:
/// a former participant's old message still keeps its original sender.
pub(crate) fn project_received_group_plain_text(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<CloudMessage, Failure> {
    if source.has_media() {
        return Err(Failure::UnsupportedMessage);
    }
    project_group_headers(source, chat)
}

fn project_group_headers(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<CloudMessage, Failure> {
    let group = source.group_id().ok_or(Failure::UnsupportedMessage)?;
    if chat.service() != CloudCanonicalService::IMessage
        || chat.style() != CloudCanonicalChatStyle::Group
        || !source.peer().is_empty()
    {
        return Err(Failure::UnsupportedMessage);
    }
    if chat.guid() != format!("iMessage;+;{}", chat.chat_identifier())
        || ![
            chat.chat_identifier(),
            chat.group_id(),
            chat.original_group_id(),
        ]
        .contains(&group)
    {
        return Err(Failure::BindingMismatch);
    }
    // CloudKit's outer chat_id is the parent's gid; proto4 carries the
    // canonical iMessage route. They are deliberately not interchangeable.
    project_headers(source, chat.group_id().to_owned(), chat.guid().to_owned())
}

/// Select only from the immutable source, never from mutable UI membership.
/// Direct projection remains strict and cannot accept a group source.
pub(crate) fn project_received_archive_plain_text(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<CloudMessage, Failure> {
    if source.group_id().is_some() {
        project_received_group_plain_text(source, chat)
    } else {
        project_received_plain_text(source, chat)
    }
}

/// Reuse the exact existing body projector without converting received
/// metadata into an outgoing receipt. The result supplies neither child upload
/// proof nor permission to create a parent; callers must establish both.
pub(crate) fn project_received_media(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
) -> Result<
    (
        CloudMessage,
        crate::cloud_sync_attachment_parent::ParentAttributedProjection,
    ),
    Failure,
> {
    if !source.has_media() {
        return Err(Failure::UnsupportedMessage);
    }
    let mut message = if source.group_id().is_some() {
        project_group_headers(source, chat)?
    } else {
        project_direct_headers(source, chat)?
    };
    let projection =
        crate::cloud_sync_attachment_parent::project_parent_attributed_body(&source.media_body()?)?;
    message.msg_proto.0.text = Some(projection.text.clone());
    message.msg_proto.0.attributed_body = Some(projection.encoded_body.clone());
    Ok((message, projection))
}

fn project_headers(
    source: &ReceivedArchiveSource,
    chat_id: String,
    route: String,
) -> Result<CloudMessage, Failure> {
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
        chat_id,
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
    fn received_media_uses_original_headers_and_shared_body_but_never_plain_text_authority() {
        for mirrored in [false, true] {
            for group in [false, true] {
                let (wire, handles) =
                    crate::cloud_sync_received_source::tests::media_fixture(mirrored, group);
                let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
                let canonical = if group {
                    group_parent(0, true)
                } else {
                    chat(
                        "remote@example.com",
                        CloudCanonicalChatStyle::Direct,
                        "mailto:later-alias@example.com",
                    )
                };
                assert!(project_received_archive_plain_text(&source, &canonical).is_err());
                assert!(project_received_plain_text(&source, &canonical).is_err());
                assert!(project_received_group_plain_text(&source, &canonical).is_err());
                let (projected, body) = project_received_media(&source, &canonical).unwrap();
                assert_eq!(projected.guid, wire.id);
                assert_eq!(projected.destination_caller_id, "owner@example.com");
                assert_eq!(
                    projected.sender,
                    if mirrored { "" } else { "remote@example.com" }
                );
                assert_eq!(projected.flags.contains(MessageFlags::IS_FROM_ME), mirrored);
                assert_eq!(body.text, "caption ");
                assert_eq!(body.links.len(), 1);
                assert_eq!(body.links[0].original_guid, "received:0");
                assert_eq!(body.links[0].apple_guid, format!("at_7_{}", wire.id));
                body.validate_encoded_body(
                    projected.msg_proto.0.attributed_body.as_deref().unwrap(),
                )
                .unwrap();
                assert_ne!(
                    compare_received_record(&projected, &projected),
                    ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
                );
            }
        }
    }

    #[test]
    fn received_media_projection_cannot_guess_a_parent_or_lose_auxiliary_descriptors() {
        let (mut wire, handles) =
            crate::cloud_sync_received_source::tests::media_fixture(false, false);
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert!(project_received_media(
            &source,
            &chat(
                "other@example.com",
                CloudCanonicalChatStyle::Direct,
                "owner@example.com"
            )
        )
        .is_err());
        if let rustpush::Message::Message(normal) = &mut wire.message {
            if let rustpush::MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                a.iris = true;
            }
        }
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert!(source.media_body().unwrap().attachments()[0].iris);
        // The shared projector refuses an all-auxiliary body rather than
        // stripping the attachment and treating a caption as complete media.
        assert!(project_received_media(
            &source,
            &chat(
                "remote@example.com",
                CloudCanonicalChatStyle::Direct,
                "owner@example.com"
            )
        )
        .is_err());
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
    fn captured_group_source_cannot_enter_a_direct_projection_or_create() {
        for mirrored in [false, true] {
            let (mut wire, handles) = fixture(mirrored, "group source");
            let conversation = wire.conversation.as_mut().unwrap();
            conversation.sender_guid = Some("77777777-8888-4999-aaaa-bbbbbbbbbbbb".into());
            conversation.participants.push("tel:+15550000002".into());
            let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
            assert_eq!(
                source.group_id(),
                Some("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
            );
            for style in [
                CloudCanonicalChatStyle::Direct,
                CloudCanonicalChatStyle::Group,
            ] {
                assert!(project_received_plain_text(
                    &source,
                    &chat("remote@example.com", style, "mailto:owner@example.com"),
                )
                .is_err());
            }
        }
    }
    const GROUP: &str = "77777777-8888-4999-aaaa-bbbbbbbbbbbb";

    pub(crate) fn group_source(mirrored: bool) -> ReceivedArchiveSource {
        let (mut wire, handles) = fixture(mirrored, "Original group text 😀");
        let conversation = wire.conversation.as_mut().unwrap();
        conversation.sender_guid = Some(GROUP.into());
        conversation.participants.push("tel:+15550000002".into());
        ReceivedArchiveSource::capture(&wire, &handles).unwrap()
    }

    pub(crate) fn group_parent(alias_position: usize, matched: bool) -> CloudCanonicalChatPayload {
        let alias = if matched {
            GROUP
        } else {
            "11111111-2222-4333-8444-555555555555"
        };
        let identifier = if alias_position == 0 {
            alias
        } else {
            "restored-chat"
        };
        let group_id = if alias_position == 1 {
            alias
        } else {
            "opaque-cloud-group"
        };
        let original = if alias_position == 2 {
            alias
        } else {
            "old-group-id"
        };
        CloudCanonicalChatPayload::new(
            format!("iMessage;+;{identifier}"),
            identifier.into(),
            group_id.into(),
            original.into(),
            CloudCanonicalService::IMessage,
            CloudCanonicalChatStyle::Group,
            // Deliberately different from the old wire members. Current
            // members are not proof of historical sender identity.
            vec!["mailto:current-member@example.invalid".into()],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value("mailto:new-alias@example.invalid".into()),
            CloudCanonicalField::Value(9),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap()
    }

    #[test]
    fn group_projection_binds_exact_parent_alias_and_original_received_endpoint() {
        for mirrored in [false, true] {
            for alias_position in 0..3 {
                let source = group_source(mirrored);
                let parent = group_parent(alias_position, true);
                let value = project_received_group_plain_text(&source, &parent).unwrap();
                assert_eq!(value.chat_id, parent.group_id());
                assert_eq!(
                    value.msg_proto_4.as_ref().unwrap().0.group_id.as_deref(),
                    Some(parent.guid())
                );
                assert_eq!(value.destination_caller_id, "owner@example.com");
                assert_eq!(
                    value.sender,
                    if mirrored { "" } else { "remote@example.com" }
                );
                assert_eq!(value.flags.contains(MessageFlags::IS_FROM_ME), mirrored);
                assert_eq!(value.time, 721_692_800_000_000_000);
                assert_eq!(value.msg_proto.0.text.as_deref(), Some(source.text()));
                assert_eq!(
                    compare_received_record(&value, &value),
                    ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
                );
                assert!(project_received_plain_text(&source, &parent).is_err());
                assert!(project_received_archive_plain_text(&source, &parent).is_ok());
                assert!(project_received_archive_plain_text(
                    &source,
                    &group_parent(alias_position, false)
                )
                .is_err());
            }
        }
    }

    #[test]
    fn group_projection_never_guesses_parent_from_members_or_accepts_direct_source() {
        let group = group_source(false);
        assert!(project_received_archive_plain_text(
            &group,
            &chat(
                "remote@example.com",
                CloudCanonicalChatStyle::Direct,
                "mailto:owner@example.com"
            )
        )
        .is_err());
        let (wire, handles) = fixture(false, "Direct text");
        let direct = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert!(project_received_group_plain_text(&direct, &group_parent(1, true)).is_err());
        assert!(project_received_archive_plain_text(&direct, &group_parent(1, true)).is_err());
        // A canonical direct source still follows the unchanged direct path.
        let parent = chat(
            "remote@example.com",
            CloudCanonicalChatStyle::Direct,
            "mailto:owner@example.com",
        );
        assert!(project_received_archive_plain_text(&direct, &parent).is_ok());
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
