use super::*;
use crate::cloud_sync_canonical_dto::{
    CloudCanonicalHeadingReference, CloudCanonicalReplyReference,
};
use crate::cloud_sync_extension_metadata::{
    serialize_generated_metadata_json, ExtensionBalloonMetadata, ExtensionPayloadMetadata,
};

// Synthetic heading-identity fixtures for the post-build validator.
// No real data: guids below are fake and only need identifier shape.
const HEADING_IDENTITY_OWN_GUID: &str = "heading-own-guid";
const HEADING_IDENTITY_LINKED_GUID: &str = "heading-linked-guid";
const HEADING_IDENTITY_OTHER_GUID: &str = "heading-other-guid";
const HEADING_IDENTITY_REPLY_PARENT_GUID: &str = "heading-reply-parent-guid";
const HEADING_IDENTITY_CHAT: &str = "iMessage;-;+15555550100";
const HEADING_IDENTITY_BUNDLE: &str = "com.example.synthetic";

fn heading_identity_metadata_bytes() -> Vec<u8> {
    let metadata = ExtensionPayloadMetadata {
        name: "Synthetic app".to_owned(),
        app_id: None,
        bundle_id: HEADING_IDENTITY_BUNDLE.to_owned(),
        balloon: ExtensionBalloonMetadata {
            url: "app:synthetic".to_owned(),
            session: None,
            ld_text: None,
            is_live: false,
            icon: None,
            layout: None,
        },
    };
    serialize_generated_metadata_json(&metadata).unwrap()
}

#[allow(clippy::too_many_arguments)]
fn heading_identity_mutation(
    hasher: &CloudSemanticIdentifierHasher,
    own_guid: &str,
    linked_guid: Option<&str>,
    linked_hash_override: Option<CloudCanonicalHash>,
    logical_hash_override: Option<CloudCanonicalHash>,
    reply_parent_guid: Option<&str>,
    reply_hash_override: Option<CloudCanonicalHash>,
) -> CloudCanonicalMutation {
    let chat_alias_hash = hasher
        .canonical_alias_key_hash(
            CloudCanonicalAliasKind::ChatServiceIdentifier,
            HEADING_IDENTITY_CHAT,
        )
        .unwrap();
    let exact_guid_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, HEADING_IDENTITY_CHAT)
        .unwrap();
    let alias_candidates =
        message_chat_alias_candidates(hasher, HEADING_IDENTITY_CHAT, Some(chat_alias_hash.clone()));
    let linked_hash = match (linked_guid, linked_hash_override) {
        (Some(guid), None) => Some(
            hasher
                .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, guid)
                .unwrap(),
        ),
        (Some(_), Some(hash)) => Some(hash),
        (None, None) => None,
        (None, Some(_)) => panic!("linked hash without linked guid is malformed"),
    };
    let heading = CloudCanonicalHeadingReference::new(
        linked_guid.map(str::to_owned),
        linked_hash,
        None,
        None,
    )
    .unwrap();
    let reply = match reply_parent_guid {
        Some(parent_guid) => {
            let expected = hasher
                .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, parent_guid)
                .unwrap();
            Some(
                CloudCanonicalReplyReference::new(
                    parent_guid.to_owned(),
                    "0".to_owned(),
                    reply_hash_override.unwrap_or(expected),
                )
                .unwrap(),
            )
        }
        None => {
            assert!(reply_hash_override.is_none());
            None
        }
    };
    let payload = CloudCanonicalPayload::Message(Box::new(
        CloudCanonicalMessagePayload::new(
            own_guid.to_owned(),
            HEADING_IDENTITY_CHAT.to_owned(),
            chat_alias_hash,
            exact_guid_hash,
            None,
            alias_candidates,
            None,
            None,
            "sender@example.invalid".to_owned(),
            1,
            0,
            CloudCanonicalService::IMessage,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value("body".to_owned()),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value(HEADING_IDENTITY_BUNDLE.to_owned()),
            CloudCanonicalField::Value(heading_identity_metadata_bytes()),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalKnownMessageFlags::default(),
            CloudCanonicalMessageAssociation::Heading(heading),
            reply.clone(),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap(),
    ));
    let logical_hash = logical_hash_override.unwrap_or_else(|| {
        hasher
            .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, own_guid)
            .unwrap()
    });
    let parent_hash = reply.as_ref().map(|value| value.parent_hash().clone());
    upsert_mutation(
        CloudCanonicalEntityKind::Message,
        logical_hash,
        parent_hash,
        payload,
    )
}

fn heading_identity_message_payload(
    mutation: &CloudCanonicalMutation,
) -> &CloudCanonicalMessagePayload {
    match mutation.payload().expect("message payload") {
        CloudCanonicalPayload::Message(payload) => payload,
        _ => panic!("heading mutation must carry a message payload"),
    }
}

#[test]
fn heading_identity_uses_own_message_hash_for_nonself_self_and_absent_links() {
    let hasher = CloudSemanticIdentifierHasher::new(b"heading-identity-test").unwrap();
    let own_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, HEADING_IDENTITY_OWN_GUID)
        .unwrap();
    let linked_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_LINKED_GUID,
        )
        .unwrap();
    assert_ne!(own_hash, linked_hash);
    for linked in [
        Some(HEADING_IDENTITY_LINKED_GUID),
        Some(HEADING_IDENTITY_OWN_GUID),
        None,
    ] {
        let mutation = heading_identity_mutation(
            &hasher,
            HEADING_IDENTITY_OWN_GUID,
            linked,
            None,
            None,
            None,
            None,
        );
        assert_eq!(
            validate_canonical_identity_bindings(&mutation, &hasher),
            Ok(())
        );
        assert_eq!(mutation.envelope().logical_entity_key_hash(), &own_hash);
        assert!(mutation.envelope().parent_logical_key_hash().is_none());
        assert!(mutation
            .snapshot()
            .unwrap()
            .parent_logical_key_hash()
            .is_none());
        let payload = heading_identity_message_payload(&mutation);
        assert_eq!(payload.guid(), HEADING_IDENTITY_OWN_GUID);
        assert!(payload.reply().is_none());
        let heading = payload
            .association()
            .heading()
            .expect("heading association");
        assert_eq!(heading.linked_guid(), linked);
        match linked {
            Some(HEADING_IDENTITY_OWN_GUID) => assert_eq!(heading.linked_hash(), Some(&own_hash)),
            Some(_) => assert_eq!(heading.linked_hash(), Some(&linked_hash)),
            None => assert!(heading.linked_hash().is_none()),
        }
    }
}

#[test]
fn heading_identity_rejects_linked_hash_from_wrong_identifier_and_wrong_account() {
    let hasher = CloudSemanticIdentifierHasher::new(b"heading-identity-test").unwrap();
    let valid = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        None,
        None,
        None,
        None,
    );
    assert_eq!(
        validate_canonical_identity_bindings(&valid, &hasher),
        Ok(())
    );
    let wrong_identifier_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_OTHER_GUID,
        )
        .unwrap();
    let tampered_identifier = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        Some(wrong_identifier_hash.clone()),
        None,
        None,
        None,
    );
    let expected_linked_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_LINKED_GUID,
        )
        .unwrap();
    assert_ne!(wrong_identifier_hash, expected_linked_hash);
    assert_eq!(
        validate_canonical_identity_bindings(&tampered_identifier, &hasher),
        Err(CloudCanonicalValidationFailure::InvalidPayload)
    );
    let wrong_account = CloudSemanticIdentifierHasher::new(b"wrong-account-key").unwrap();
    let wrong_account_hash = wrong_account
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_LINKED_GUID,
        )
        .unwrap();
    assert_ne!(wrong_account_hash, expected_linked_hash);
    let tampered_account = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        Some(wrong_account_hash),
        None,
        None,
        None,
    );
    assert_eq!(
        validate_canonical_identity_bindings(&tampered_account, &hasher),
        Err(CloudCanonicalValidationFailure::InvalidPayload)
    );
}

#[test]
fn heading_identity_rejects_wrong_envelope_logical_hash() {
    let hasher = CloudSemanticIdentifierHasher::new(b"heading-identity-test").unwrap();
    let valid = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        None,
        None,
        None,
        None,
    );
    assert_eq!(
        validate_canonical_identity_bindings(&valid, &hasher),
        Ok(())
    );
    let random_hash = CloudCanonicalHash::new(digest('t')).unwrap();
    let tampered_random = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        None,
        Some(random_hash),
        None,
        None,
    );
    assert_eq!(
        validate_canonical_identity_bindings(&tampered_random, &hasher),
        Err(CloudCanonicalValidationFailure::InvalidPayload)
    );
    let confused_deputy_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_LINKED_GUID,
        )
        .unwrap();
    let tampered_deputy = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        None,
        Some(confused_deputy_hash),
        None,
        None,
    );
    assert_eq!(
        validate_canonical_identity_bindings(&tampered_deputy, &hasher),
        Err(CloudCanonicalValidationFailure::InvalidPayload)
    );
}

#[test]
fn heading_identity_keeps_ordinary_causal_reply_validated() {
    let hasher = CloudSemanticIdentifierHasher::new(b"heading-identity-test").unwrap();
    let own_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, HEADING_IDENTITY_OWN_GUID)
        .unwrap();
    let reply_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_REPLY_PARENT_GUID,
        )
        .unwrap();
    let linked_hash = hasher
        .canonical_entity_key_hash(
            CloudCanonicalEntityKind::Message,
            HEADING_IDENTITY_LINKED_GUID,
        )
        .unwrap();
    assert_ne!(reply_hash, linked_hash);
    let valid = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        None,
        None,
        Some(HEADING_IDENTITY_REPLY_PARENT_GUID),
        None,
    );
    assert_eq!(
        validate_canonical_identity_bindings(&valid, &hasher),
        Ok(())
    );
    assert_eq!(valid.envelope().logical_entity_key_hash(), &own_hash);
    assert_eq!(
        valid.envelope().parent_logical_key_hash(),
        Some(&reply_hash)
    );
    let payload = heading_identity_message_payload(&valid);
    let heading = payload
        .association()
        .heading()
        .expect("heading association");
    assert_eq!(heading.linked_guid(), Some(HEADING_IDENTITY_LINKED_GUID));
    assert_eq!(heading.linked_hash(), Some(&linked_hash));
    let reply = payload.reply().expect("causal reply retained");
    assert_eq!(reply.parent_guid(), HEADING_IDENTITY_REPLY_PARENT_GUID);
    assert_eq!(reply.parent_hash(), &reply_hash);
    let wrong_reply_hash = CloudCanonicalHash::new(digest('r')).unwrap();
    assert_ne!(wrong_reply_hash, reply_hash);
    let tampered_reply = heading_identity_mutation(
        &hasher,
        HEADING_IDENTITY_OWN_GUID,
        Some(HEADING_IDENTITY_LINKED_GUID),
        None,
        None,
        Some(HEADING_IDENTITY_REPLY_PARENT_GUID),
        Some(wrong_reply_hash),
    );
    assert_eq!(
        validate_canonical_identity_bindings(&tampered_reply, &hasher),
        Err(CloudCanonicalValidationFailure::InvalidPayload)
    );
}
