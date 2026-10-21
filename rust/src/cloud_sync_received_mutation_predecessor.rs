//! Prove a sealed receive can mutate the exact decrypted original message.
//! Local rows, matching text and caller assertions never establish authorship.
//! The caller obtains inspection and current handles from the same authenticated
//! native client, and separately binds the exact raw record, ETag and parent.
#![cfg_attr(not(test), allow(dead_code))]

use crate::{
    cloud_sync_canonical_dto::{
        CloudCanonicalChatPayload, CloudCanonicalChatStyle, CloudCanonicalService,
    },
    cloud_sync_outbound::CloudSyncOutboundFailure as Failure,
    cloud_sync_received_mutation_source::ReceivedMutationSource,
    cloud_sync_received_source::{hex_digest, ReceivedArchiveOrigin},
};
use rustpush::cloud_messages::{CloudMessageRecordInspection, MessageFlags};
use std::collections::HashSet;

// No Debug/serde or public constructor. This is a native validation result,
// not a received hash inserted into an outgoing IDS receipt field.
pub(crate) struct ReceivedMutationPredecessorProof(String);

impl ReceivedMutationPredecessorProof {
    pub(crate) fn sha256(&self) -> &str {
        &self.0
    }
}

pub(crate) fn prove_received_mutation_predecessor(
    source: &ReceivedMutationSource,
    original: &CloudMessageRecordInspection,
    parent: &CloudCanonicalChatPayload,
    current_native_handles: &[String],
) -> Result<ReceivedMutationPredecessorProof, Failure> {
    let message = &original.message;
    let local = |handle: &str| {
        current_native_handles
            .iter()
            .any(|v| bare(v) == bare(handle))
    };
    let mirrored = source.origin() == ReceivedArchiveOrigin::Mirrored;
    let mutation_time = source
        .sent_timestamp()
        .checked_sub(978_307_200_000)
        .and_then(|v| v.checked_mul(1_000_000))
        .and_then(|v| i64::try_from(v).ok())
        .ok_or(Failure::MalformedMessage)?;
    if current_native_handles.is_empty()
        || current_native_handles.len() > 64
        || !current_native_handles
            .iter()
            .any(|v| v == source.recipient())
        || message.destination_caller_id.is_empty()
        || !local(&message.destination_caller_id)
        || message.guid != source.target_guid()
        || message.service != "iMessage"
        || parent.service() != CloudCanonicalService::IMessage
        || !matches!(message.r#type, 0..=2)
        || message.time < 0
        || message.time > mutation_time
        || message.flags.contains(MessageFlags::IS_FROM_ME) != mirrored
    {
        return Err(Failure::BindingMismatch);
    }
    if mirrored {
        if !current_native_handles.iter().any(|v| v == source.sender())
            || (!message.sender.is_empty() && !local(&message.sender))
        {
            return Err(Failure::BindingMismatch);
        }
    } else if local(source.sender()) || bare(&message.sender) != bare(source.sender()) {
        return Err(Failure::BindingMismatch);
    }

    let external = source
        .participants()
        .iter()
        .filter(|v| !source.self_handles().contains(v))
        .map(String::as_str)
        .collect::<HashSet<_>>();
    match parent.style() {
        CloudCanonicalChatStyle::Direct => {
            let peer = external.iter().next().ok_or(Failure::BindingMismatch)?;
            if external.len() != 1
                || parent.chat_identifier() != bare(peer)
                || parent.guid() != format!("iMessage;-;{}", bare(peer))
                || message.chat_id != parent.guid()
                || parent.participant_handles().is_empty()
                || parent
                    .participant_handles()
                    .iter()
                    .any(|v| bare(v) != bare(peer))
            {
                return Err(Failure::BindingMismatch);
            }
        }
        CloudCanonicalChatStyle::Group => {
            let group = source.sender_guid().ok_or(Failure::BindingMismatch)?;
            if !uuid::Uuid::parse_str(group).is_ok_and(|value| !value.is_nil() && group.len() == 36)
                || ![
                    parent.chat_identifier(),
                    parent.group_id(),
                    parent.original_group_id(),
                ]
                .contains(&group)
                || parent.guid() != format!("iMessage;+;{}", parent.chat_identifier())
                || message.chat_id != parent.group_id()
            {
                return Err(Failure::BindingMismatch);
            }
            // Current membership/title is intentionally not an author proof:
            // an original participant may have left the group since sending.
        }
    }
    if let Some(proto) = &message.msg_proto_4 {
        if proto.0.service.as_deref().is_some_and(|v| v != "iMessage")
            || proto
                .0
                .group_id
                .as_deref()
                .is_some_and(|v| v != parent.guid())
        {
            return Err(Failure::BindingMismatch);
        }
    }
    let binding = serde_json::to_vec(&serde_json::json!([
        "cloud-sync-received-mutation-predecessor-v1",
        source.source_sha256()?,
        source.guid_hash()?,
        source.target_guid_hash()?,
        message.guid,
        message.sender,
        message.destination_caller_id,
        message.flags.bits(),
        message.time,
        message.r#type,
        message.service,
        message.chat_id,
        parent.guid(),
        parent.chat_identifier(),
        parent.group_id(),
        parent.original_group_id(),
        hex_digest(&original.msg_proto),
        original.msg_proto_4.as_ref().map(|v| hex_digest(v)),
    ]))
    .map_err(|_| Failure::MalformedMessage)?;
    Ok(ReceivedMutationPredecessorProof(hex_digest(&binding)))
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
    use crate::cloud_sync_received_mutation_source::tests::fixture;
    use prost::Message as _;
    use rustpush::cloud_messages::{
        cloudmessagesp::{MessageProto, MessageProto4},
        CloudMessage, GZipWrapper,
    };

    fn parent(group: bool) -> CloudCanonicalChatPayload {
        let identifier = if group {
            "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        } else {
            "remote@example.com"
        };
        CloudCanonicalChatPayload::new(
            format!("iMessage;{};{identifier}", if group { "+" } else { "-" }),
            identifier.into(),
            "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF".into(),
            "CCCCCCCC-DDDD-4EEE-8FFF-AAAAAAAAAAAA".into(),
            CloudCanonicalService::IMessage,
            if group {
                CloudCanonicalChatStyle::Group
            } else {
                CloudCanonicalChatStyle::Direct
            },
            vec!["mailto:remote@example.com".into()],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap()
    }

    fn original(
        source: &ReceivedMutationSource,
        chat: &CloudCanonicalChatPayload,
    ) -> CloudMessageRecordInspection {
        let proto = MessageProto {
            text: Some("original text".into()),
            ..Default::default()
        };
        let proto4 = MessageProto4 {
            service: Some("iMessage".into()),
            group_id: Some(chat.guid().into()),
            ..Default::default()
        };
        CloudMessageRecordInspection {
            msg_proto: proto.encode_to_vec(),
            msg_proto_2: None,
            msg_proto_3: None,
            msg_proto_4: Some(proto4.encode_to_vec()),
            message: CloudMessage {
                guid: source.target_guid().into(),
                service: "iMessage".into(),
                r#type: 1,
                time: 721_692_799_000_000_000,
                sender: if source.origin() == ReceivedArchiveOrigin::Mirrored {
                    ""
                } else {
                    "remote@example.com"
                }
                .into(),
                destination_caller_id: "owner@example.com".into(),
                flags: if source.origin() == ReceivedArchiveOrigin::Mirrored {
                    MessageFlags::IS_FROM_ME
                } else {
                    MessageFlags::empty()
                },
                chat_id: if chat.style() == CloudCanonicalChatStyle::Group {
                    chat.group_id()
                } else {
                    chat.guid()
                }
                .into(),
                msg_proto: GZipWrapper(proto),
                msg_proto_4: Some(GZipWrapper(proto4)),
                ..Default::default()
            },
        }
    }

    #[test]
    fn native_received_predecessor_proves_both_origins_and_exact_group_parent() {
        for mirrored in [false, true] {
            for unsend in [false, true] {
                for group in [false, true] {
                    let (mut wire, handles) = fixture(mirrored, unsend);
                    let chat = parent(group);
                    if group {
                        wire.conversation.as_mut().unwrap().sender_guid =
                            Some(chat.original_group_id().into());
                    }
                    let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
                    let raw = original(&source, &chat);
                    let proof = prove_received_mutation_predecessor(&source, &raw, &chat, &handles)
                        .unwrap();
                    assert_eq!(proof.sha256().len(), 64);
                }
            }
        }
    }

    #[test]
    fn native_received_predecessor_allows_only_account_owned_endpoint_aliases() {
        for mirrored in [false, true] {
            let (wire, mut handles) = fixture(mirrored, false);
            let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
            let chat = parent(false);
            let mut raw = original(&source, &chat);
            raw.message.destination_caller_id = "other-own@example.com".into();
            assert!(prove_received_mutation_predecessor(&source, &raw, &chat, &handles).is_err());
            handles.push("mailto:other-own@example.com".into());
            if mirrored {
                raw.message.sender = "other-own@example.com".into();
            }
            assert!(prove_received_mutation_predecessor(&source, &raw, &chat, &handles).is_ok());
        }
    }

    #[test]
    fn native_received_predecessor_rejects_actor_direction_guid_route_and_time_drift() {
        for mirrored in [false, true] {
            for variant in 0..10 {
                let (wire, handles) = fixture(mirrored, false);
                let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
                let chat = parent(false);
                let mut raw = original(&source, &chat);
                match variant {
                    0 => raw.message.sender = "unrelated@example.com".into(),
                    1 => raw.message.flags.toggle(MessageFlags::IS_FROM_ME),
                    2 => raw.message.guid = wire.id.clone(),
                    3 => raw.message.chat_id = "iMessage;-;unrelated@example.com".into(),
                    4 => raw.message.time += 2_000_000_000,
                    5 => raw.message.service = "SMS".into(),
                    6 => {
                        raw.message.msg_proto_4.as_mut().unwrap().0.group_id =
                            Some("wrong-parent".into())
                    }
                    7 => raw.message.destination_caller_id = "unrelated@example.com".into(),
                    8 => raw.message.r#type = 100,
                    _ => raw.message.msg_proto_4.as_mut().unwrap().0.service = Some("SMS".into()),
                }
                assert!(
                    prove_received_mutation_predecessor(&source, &raw, &chat, &handles).is_err(),
                    "variant {variant}"
                );
            }
        }
    }

    #[test]
    fn native_received_predecessor_preserves_original_bytes_and_rejects_group_alias_guess() {
        let (mut wire, handles) = fixture(false, false);
        let chat = parent(true);
        wire.conversation.as_mut().unwrap().sender_guid = Some(chat.original_group_id().into());
        let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
        let mut raw = original(&source, &chat);
        // Unknown protobuf field99 remains in the inspected native byte image.
        raw.msg_proto.extend_from_slice(&[0x98, 0x06, 0x01]);
        let before = raw.msg_proto.clone();
        assert!(prove_received_mutation_predecessor(&source, &raw, &chat, &handles).is_ok());
        assert_eq!(raw.msg_proto, before);
        raw.message.chat_id = chat.guid().into();
        assert!(prove_received_mutation_predecessor(&source, &raw, &chat, &handles).is_err());
        wire.conversation.as_mut().unwrap().sender_guid =
            Some("DDDDDDDD-EEEE-4FFF-8AAA-BBBBBBBBBBBB".into());
        let unrelated = ReceivedMutationSource::capture(&wire, &handles).unwrap();
        assert!(prove_received_mutation_predecessor(
            &unrelated,
            &original(&unrelated, &chat),
            &chat,
            &handles
        )
        .is_err());
    }

    #[test]
    fn received_original_proof_and_lossless_composer_preserve_unknown_wire_fields() {
        for mirrored in [false, true] {
            for unsend in [false, true] {
                let (wire, handles) = fixture(mirrored, unsend);
                let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
                let chat = parent(false);
                let mut raw = original(&source, &chat);
                let unknown = [0x98, 0x06, 0x01];
                raw.msg_proto.extend_from_slice(&unknown);
                prove_received_mutation_predecessor(&source, &raw, &chat, &handles).unwrap();
                let changed = crate::cloud_sync_message_update_compose::compose_message_update(
                    rustpush::cloud_messages::CloudMessageUpdatePredecessorView {
                        msg_proto: &raw.msg_proto,
                        message_time_apple_nanos: raw.message.time,
                        outer_type: raw.message.r#type,
                    },
                    &source.message().unwrap(),
                    source.sent_timestamp(),
                )
                .unwrap();
                assert!(changed.windows(unknown.len()).any(|v| v == unknown));
                let parsed = MessageProto::decode(changed.as_slice()).unwrap();
                if !unsend {
                    assert_eq!(parsed.text.as_deref(), Some("Edited 😀"));
                }
                assert!(parsed.message_summary_info.is_some());
            }
        }
    }
}
