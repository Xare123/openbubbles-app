use super::*;
use prost::Message as _;

const HEADING_GUID: &str = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const LINKED_GUID: &str = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB";
const BALLOON_SESSION: &str = "01010101-0101-0101-0101-010101010101";

fn heading_message(linked_guid: Option<&str>) -> CloudMessage {
    // The real keyed-archive shape from
    // extension_archive_projects_renderer_metadata_with_base_message, with a
    // distinct internal balloon UUID so it cannot stand in for a Message GUID.
    let root = PlistValue::Dictionary(
        [
            (
                "$class".to_owned(),
                PlistValue::String("NSMutableDictionary".into()),
            ),
            ("an".to_owned(), PlistValue::String("Synthetic app".into())),
            (
                "URL".to_owned(),
                PlistValue::Dictionary(
                    [
                        ("$class".to_owned(), PlistValue::String("NSURL".into())),
                        ("NS.base".to_owned(), PlistValue::String("$null".into())),
                        (
                            "NS.relative".to_owned(),
                            PlistValue::String("app:synthetic".into()),
                        ),
                    ]
                    .into_iter()
                    .collect(),
                ),
            ),
            (
                "sessionIdentifier".to_owned(),
                PlistValue::Dictionary(
                    [
                        ("$class".to_owned(), PlistValue::String("NSUUID".into())),
                        ("NS.uuidbytes".to_owned(), PlistValue::Data(vec![1; 16])),
                    ]
                    .into_iter()
                    .collect(),
                ),
            ),
        ]
        .into_iter()
        .collect(),
    );
    let archive = rustpush::KeyedArchive::archive_item(root).unwrap();
    let mut bytes = Vec::new();
    archive.to_writer_binary(&mut bytes).unwrap();
    let mut message = normal_message(Some("Synthetic app heading"));
    message.guid = HEADING_GUID.to_owned();
    message.msg_proto.0.balloon_bundle_id = Some("com.example.synthetic".into());
    message.msg_proto.0.payload_data = Some(bytes);
    message.msg_proto.0.associated_message_type = Some(3);
    message.msg_proto.0.associated_message_guid = linked_guid.map(str::to_owned);
    message
}

fn assert_independent_heading<'a>(
    outcome: &'a CloudCanonicalConversionOutcome,
    message: &CloudMessage,
    hasher: &CloudSemanticIdentifierHasher,
) -> &'a CloudCanonicalMessagePayload {
    let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
        panic!("supported heading should convert: {outcome:?}");
    };
    let own_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, &message.guid)
        .unwrap();
    assert_eq!(
        mutation.envelope().entity_kind(),
        CloudCanonicalEntityKind::Message
    );
    assert_eq!(mutation.envelope().logical_entity_key_hash(), &own_hash);
    assert!(mutation.envelope().parent_logical_key_hash().is_none());
    let snapshot = mutation.snapshot().expect("heading snapshot");
    assert_eq!(snapshot.entity_kind(), CloudCanonicalEntityKind::Message);
    assert_eq!(snapshot.logical_entity_key_hash(), &own_hash);
    assert!(snapshot.parent_logical_key_hash().is_none());

    let payload = message_payload(outcome);
    assert_eq!(payload.guid(), message.guid);
    assert!(matches!(
        payload.association(),
        CloudCanonicalMessageAssociation::Heading(_)
    ));
    assert!(!payload.association().is_reaction());
    assert!(payload.association().reaction().is_none());
    assert!(payload.association().sticker().is_none());
    assert!(payload.reply().is_none());
    let (metadata, session) = crate::cloud_sync_extension_metadata::parse_projection_metadata_json(
        payload
            .decoded_extension_payload()
            .value()
            .expect("decoded extension metadata"),
    )
    .unwrap();
    assert_eq!(metadata.name, "Synthetic app");
    assert_eq!(metadata.bundle_id, "com.example.synthetic");
    assert_eq!(metadata.balloon.url, "app:synthetic");
    assert_eq!(metadata.balloon.session.as_deref(), Some(BALLOON_SESSION));
    assert!(
        session.is_none(),
        "heading must not invent Base/Update context"
    );
    payload
}

#[test]
fn heading_nonself_link_preserves_message_identity_across_outer_message_family() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    let linked_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, LINKED_GUID)
        .unwrap();
    let folded_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            &LINKED_GUID.to_lowercase(),
        )
        .unwrap();
    assert_ne!(linked_hash, folded_hash);
    for outer_type in 0..=2 {
        let mut message = heading_message(Some(LINKED_GUID));
        message.r#type = outer_type;
        let original_proto = message.msg_proto.0.encode_to_vec();
        let outcome = convert_message(
            &context(&hasher, "server-heading-nonself", None),
            &message_presence(),
            &message,
        );
        let payload = assert_independent_heading(&outcome, &message, &hasher);
        assert_eq!(
            payload.text().value().map(String::as_str),
            Some("Synthetic app heading")
        );
        let heading = payload.association().heading().unwrap();
        assert_eq!(heading.linked_guid(), Some(LINKED_GUID));
        assert_eq!(heading.linked_hash(), Some(&linked_hash));
        assert_eq!(message.msg_proto.0.encode_to_vec(), original_proto);
    }
}

#[test]
fn heading_self_reference_is_optional_navigation_not_a_parent_cycle_or_base() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    let message = heading_message(Some(HEADING_GUID));
    let outcome = convert_message(
        &context(&hasher, "server-heading-self", None),
        &message_presence(),
        &message,
    );
    let payload = assert_independent_heading(&outcome, &message, &hasher);
    let own_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, HEADING_GUID)
        .unwrap();
    let heading = payload.association().heading().unwrap();
    assert_eq!(heading.linked_guid(), Some(HEADING_GUID));
    assert_eq!(heading.linked_hash(), Some(&own_hash));
}

#[test]
fn heading_without_link_does_not_use_own_guid_or_internal_balloon_session() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    let message = heading_message(None);
    let outcome = convert_message(
        &context(&hasher, "server-heading-no-target", None),
        &message_presence(),
        &message,
    );
    let payload = assert_independent_heading(&outcome, &message, &hasher);
    let heading = payload.association().heading().unwrap();
    assert!(heading.linked_guid().is_none());
    assert!(heading.linked_hash().is_none());
    assert!(heading.range_location().is_none());
    assert!(heading.range_length().is_none());
}

#[test]
fn heading_ranges_preserve_independent_presence_and_full_uint32_values() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    for linked in [None, Some(LINKED_GUID)] {
        for (location, length) in [
            (None, None),
            (Some(0), Some(0)),
            (Some(0), Some(u32::MAX)),
            (Some(u32::MAX), Some(0)),
            (Some(u32::MAX), Some(u32::MAX)),
            (Some(7), None),
            (None, Some(u32::MAX)),
        ] {
            let mut message = heading_message(linked);
            message.msg_proto.0.associated_message_range_location = location;
            message.msg_proto.0.associated_message_range_length = length;
            // Exercise actual uint32 protobuf serialization. These are opaque
            // fields, not a signed -1 sentinel or an additive text-span range.
            let wire = message.msg_proto.0.encode_to_vec();
            message.msg_proto.0 = MessageProto::decode(wire.as_slice()).unwrap();
            let outcome = convert_message(
                &context(&hasher, "server-heading-ranges", None),
                &message_presence(),
                &message,
            );
            let payload = assert_independent_heading(&outcome, &message, &hasher);
            let heading = payload.association().heading().unwrap();
            assert_eq!(heading.linked_guid(), linked);
            assert_eq!(heading.range_location(), location);
            assert_eq!(heading.range_length(), length);
            assert_eq!(message.msg_proto.0.encode_to_vec(), wire);
        }
    }
}

#[test]
fn heading_wrapped_empty_and_control_character_links_are_rejected() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    for linked in [
        "",
        "p:0/BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
        "bp:BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
        "urn:uuid:BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
        "parent/child",
        "bad\0guid",
        "bad\nguid",
        "bad\tguid",
        "bad\u{7f}guid",
    ] {
        let message = heading_message(Some(linked));
        let original_proto = message.msg_proto.0.encode_to_vec();
        let outcome = convert_message(
            &context(&hasher, "server-heading-invalid-link", None),
            &message_presence(),
            &message,
        );
        assert!(
            matches!(outcome, CloudCanonicalConversionOutcome::Quarantined(_)),
            "invalid link must not become a heading: {linked:?}, {outcome:?}"
        );
        assert_eq!(message.msg_proto.0.encode_to_vec(), original_proto);
    }
}

#[test]
fn heading_requires_non_url_carrier_and_real_decodable_extension_payload() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    let valid = heading_message(Some(LINKED_GUID));
    let valid_bytes = valid.msg_proto.0.payload_data.clone().unwrap();
    let wrong_root =
        rustpush::KeyedArchive::archive_item(PlistValue::String("not app metadata".into()))
            .unwrap();
    let mut wrong_schema = Vec::new();
    wrong_root.to_writer_binary(&mut wrong_schema).unwrap();
    for (label, bundle, bytes, unsupported_association) in [
        ("no payload", Some("com.example.synthetic"), None, true),
        (
            "empty payload",
            Some("com.example.synthetic"),
            Some(vec![]),
            false,
        ),
        (
            "malformed payload",
            Some("com.example.synthetic"),
            Some(vec![1, 2, 3]),
            false,
        ),
        (
            "unsupported archive schema",
            Some("com.example.synthetic"),
            Some(wrong_schema),
            false,
        ),
        ("no bundle", None, Some(valid_bytes.clone()), true),
        ("empty bundle", Some(""), Some(valid_bytes.clone()), true),
        (
            "URL carrier",
            Some(URL_BALLOON_PROVIDER),
            Some(valid_bytes),
            true,
        ),
    ] {
        let mut message = valid.clone();
        message.msg_proto.0.balloon_bundle_id = bundle.map(str::to_owned);
        message.msg_proto.0.payload_data = bytes;
        let outcome = convert_message(
            &context(&hasher, "server-heading-invalid-carrier", None),
            &message_presence(),
            &message,
        );
        let expected = if unsupported_association {
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::UnsupportedAssociationType,
            )
        } else {
            CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedExtensionPayload,
            )
        };
        assert_eq!(outcome, expected, "{label}");
    }
}

#[test]
fn heading_does_not_admit_carrier_services_or_outer_type_three() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    for (service, excluded) in [
        ("SMS", CloudCanonicalOutOfScopeService::SmsFamily),
        ("RCS", CloudCanonicalOutOfScopeService::Rcs),
    ] {
        let mut message = heading_message(Some(LINKED_GUID));
        message.service = service.into();
        assert_eq!(
            convert_message(
                &context(&hasher, "server-heading-carrier-service", None),
                &message_presence(),
                &message
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(excluded)
        );
    }
    let mut message = heading_message(Some(LINKED_GUID));
    message.r#type = 3;
    assert_eq!(
        convert_message(
            &context(&hasher, "server-heading-outer-three", None),
            &message_presence(),
            &message
        ),
        CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::UnsupportedMessageType
        )
    );
}

#[test]
fn type_two_update_keeps_actual_message_parent_not_heading_or_balloon_uuid() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    let mut update = heading_message(Some(LINKED_GUID));
    update.msg_proto.0.associated_message_type = Some(2);
    update.msg_proto.0.associated_message_range_location = Some(0);
    update.msg_proto.0.associated_message_range_length = Some(0);
    let original_proto = update.msg_proto.0.encode_to_vec();
    let outcome = convert_message(
        &context(&hasher, "server-heading-control-update", None),
        &message_presence(),
        &update,
    );
    let CloudCanonicalConversionOutcome::Ready(mutation) = &outcome else {
        panic!("existing type-2 update must remain supported: {outcome:?}");
    };
    let parent_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, LINKED_GUID)
        .unwrap();
    let own_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, HEADING_GUID)
        .unwrap();
    let balloon_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, BALLOON_SESSION)
        .unwrap();
    assert_ne!(parent_hash, balloon_hash);
    assert_eq!(
        mutation.envelope().entity_kind(),
        CloudCanonicalEntityKind::Message
    );
    assert_eq!(mutation.envelope().logical_entity_key_hash(), &own_hash);
    assert_eq!(
        mutation.envelope().parent_logical_key_hash(),
        Some(&parent_hash)
    );
    assert_eq!(
        mutation.snapshot().unwrap().parent_logical_key_hash(),
        Some(&parent_hash)
    );
    let payload = message_payload(&outcome);
    assert_eq!(payload.guid(), HEADING_GUID);
    assert!(matches!(
        payload.association(),
        CloudCanonicalMessageAssociation::None
    ));
    assert!(payload.association().heading().is_none());
    assert!(!payload.association().is_reaction());
    let (metadata, session) = crate::cloud_sync_extension_metadata::parse_projection_metadata_json(
        payload.decoded_extension_payload().value().unwrap(),
    )
    .unwrap();
    let session = session.expect("type-2 update session");
    assert!(session.role == crate::cloud_sync_extension_metadata::ExtensionSessionRole::Update);
    assert_eq!(session.session_guid, LINKED_GUID);
    assert_eq!(session.session_logical_key_hash, parent_hash.value());
    assert_eq!(metadata.balloon.session.as_deref(), Some(BALLOON_SESSION));
    assert_eq!(update.msg_proto.0.encode_to_vec(), original_proto);
}

#[test]
fn type_two_update_still_rejects_missing_self_and_wrapped_parent() {
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    for linked in [None, Some(HEADING_GUID), Some(""), Some("p:0/parent-guid")] {
        let mut update = heading_message(linked);
        update.msg_proto.0.associated_message_type = Some(2);
        let outcome = convert_message(
            &context(&hasher, "server-heading-invalid-update", None),
            &message_presence(),
            &update,
        );
        assert_eq!(
            outcome,
            CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedExtensionPayload
            )
        );
    }
}

#[test]
fn heading_own_reply_is_causal_while_its_navigation_link_is_not() {
    const REPLY_GUID: &str = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC";
    let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
    let mut message = heading_message(Some(LINKED_GUID));
    message.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
        reply: Some(format!("r:0:{REPLY_GUID}")),
    }));
    let outcome = convert_message(
        &context(&hasher, "server-heading-with-own-reply", None),
        &message_presence(),
        &message,
    );
    let CloudCanonicalConversionOutcome::Ready(mutation) = &outcome else {
        panic!("heading may retain its own reply: {outcome:?}");
    };
    let own_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, HEADING_GUID)
        .unwrap();
    let reply_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, REPLY_GUID)
        .unwrap();
    let linked_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, LINKED_GUID)
        .unwrap();
    assert_ne!(reply_hash, linked_hash);
    assert_eq!(
        mutation.envelope().entity_kind(),
        CloudCanonicalEntityKind::Message
    );
    assert_eq!(mutation.envelope().logical_entity_key_hash(), &own_hash);
    assert_eq!(
        mutation.envelope().parent_logical_key_hash(),
        Some(&reply_hash)
    );
    assert_eq!(
        mutation.snapshot().unwrap().parent_logical_key_hash(),
        Some(&reply_hash)
    );
    let payload = message_payload(&outcome);
    let heading = payload
        .association()
        .heading()
        .expect("heading association");
    assert_eq!(heading.linked_guid(), Some(LINKED_GUID));
    assert_eq!(heading.linked_hash(), Some(&linked_hash));
    assert!(!payload.association().is_reaction());
    let reply = payload.reply().expect("own reply retained");
    assert_eq!(reply.parent_guid(), REPLY_GUID);
    assert_eq!(reply.parent_part(), "0");
    assert_eq!(reply.parent_hash(), &reply_hash);
    let (_, session) = crate::cloud_sync_extension_metadata::parse_projection_metadata_json(
        payload.decoded_extension_payload().value().unwrap(),
    )
    .unwrap();
    assert!(session.is_none());
}
