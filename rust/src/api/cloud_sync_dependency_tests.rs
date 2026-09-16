use super::selected_message_parent;
use crate::cloud_sync_canonical_dto::{
    CloudCanonicalAlias, CloudCanonicalAttachmentPayload, CloudCanonicalEntityKind,
    CloudCanonicalField, CloudCanonicalHash, CloudCanonicalKnownMessageFlags,
    CloudCanonicalMessageAssociation, CloudCanonicalMessagePayload, CloudCanonicalParentReference,
    CloudCanonicalPayload, CloudCanonicalReactionKind, CloudCanonicalReplyReference,
    CloudCanonicalService, CLOUD_CANONICAL_MESSAGE_CHAT_ALIAS_KINDS,
};
use crate::cloud_sync_extension_metadata::{
    serialize_session_metadata_json, ExtensionBalloonMetadata, ExtensionPayloadMetadata,
    ExtensionSessionContext, ExtensionSessionRole,
};
use crate::cloud_sync_outbound::deterministic_message_record_name;
use crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher;

const CHILD: &str = "CCCCCCCC-1234-4ABC-8DEF-111111111111";
const PARENT: &str = "AaBbCcDd-1234-4ABC-8DEF-222222222222";
const BALLOON_UUID: &str = "BBBBBBBB-1234-4ABC-8DEF-333333333333";
const BUNDLE: &str = "com.example.synthetic-parent-test";
const CHAT: &str = "iMessage;-;peer@example.invalid";

fn hasher() -> CloudSemanticIdentifierHasher {
    CloudSemanticIdentifierHasher::new(b"synthetic-parent-selector-install-key").unwrap()
}

fn message_hash(hasher: &CloudSemanticIdentifierHasher, guid: &str) -> CloudCanonicalHash {
    hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, guid)
        .unwrap()
}

fn message(
    association: CloudCanonicalMessageAssociation,
    reply: Option<CloudCanonicalReplyReference>,
    extension: Option<Vec<u8>>,
) -> CloudCanonicalPayload {
    let hasher = hasher();
    let aliases: Vec<_> = CLOUD_CANONICAL_MESSAGE_CHAT_ALIAS_KINDS
        .into_iter()
        .map(|kind| {
            CloudCanonicalAlias::new(kind, hasher.canonical_alias_key_hash(kind, CHAT).unwrap())
        })
        .collect();
    let bundle = if extension.is_some() {
        CloudCanonicalField::Value(BUNDLE.to_owned())
    } else {
        CloudCanonicalField::Absent
    };
    CloudCanonicalPayload::Message(Box::new(
        CloudCanonicalMessagePayload::new(
            CHILD.into(),
            CHAT.into(),
            aliases[0].key_hash().clone(),
            hasher
                .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, CHAT)
                .unwrap(),
            None,
            aliases,
            None,
            None,
            "mailto:peer@example.invalid".into(),
            1_800_000_000_000,
            0,
            CloudCanonicalService::IMessage,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value("synthetic child".into()),
            CloudCanonicalField::Absent,
            bundle,
            extension.map_or(CloudCanonicalField::Absent, CloudCanonicalField::Value),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalKnownMessageFlags::default(),
            association,
            reply,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .expect("validated canonical Message fixture"),
    ))
}

fn extension(role: ExtensionSessionRole, guid: &str, declared: &CloudCanonicalHash) -> Vec<u8> {
    let metadata = ExtensionPayloadMetadata {
        name: "Synthetic App".into(),
        app_id: None,
        bundle_id: BUNDLE.into(),
        balloon: ExtensionBalloonMetadata {
            url: "app:synthetic".into(),
            session: Some(BALLOON_UUID.into()),
            ld_text: None,
            is_live: true,
            icon: None,
            layout: None,
        },
    };
    serialize_session_metadata_json(
        &metadata,
        &ExtensionSessionContext {
            role,
            session_guid: guid.into(),
            session_logical_key_hash: declared.value().into(),
        },
    )
    .expect("validated extension metadata, separate balloon and wire session IDs")
}

fn reply(guid: &str, declared: CloudCanonicalHash) -> CloudCanonicalPayload {
    message(
        CloudCanonicalMessageAssociation::None,
        Some(CloudCanonicalReplyReference::new(guid.into(), "0".into(), declared).unwrap()),
        None,
    )
}

fn parent_reference(guid: &str, declared: CloudCanonicalHash) -> CloudCanonicalParentReference {
    CloudCanonicalParentReference::new(guid.into(), Some(0), declared, None, None).unwrap()
}

fn attachment(owner: Option<(&str, CloudCanonicalHash)>) -> CloudCanonicalPayload {
    let (guid, owner_guid, owner_hash, part) = match owner {
        Some((guid, hash)) => (format!("{guid}_0"), Some(guid.into()), Some(hash), Some(0)),
        None => ("standalone-attachment".into(), None, None, None),
    };
    CloudCanonicalPayload::Attachment(Box::new(
        CloudCanonicalAttachmentPayload::new(
            guid,
            owner_guid,
            owner_hash,
            part,
            CloudCanonicalField::Value("public.data".into()),
            CloudCanonicalField::Value("application/octet-stream".into()),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value(17),
            CloudCanonicalField::Value(false),
            CloudCanonicalField::Absent,
        )
        .expect("validated canonical Attachment fixture"),
    ))
}

#[test]
fn extension_update_selects_true_message_session_not_balloon_uuid() {
    let hasher = hasher();
    let expected = message_hash(&hasher, PARENT);
    let payload = message(
        CloudCanonicalMessageAssociation::None,
        None,
        Some(extension(ExtensionSessionRole::Update, PARENT, &expected)),
    );
    let selected = selected_message_parent(&payload, expected.value(), &hasher).unwrap();
    assert_eq!(selected, PARENT);
    let balloon = message_hash(&hasher, BALLOON_UUID);
    assert!(selected_message_parent(&payload, balloon.value(), &hasher).is_err());
    assert!(
        selected_message_parent(&payload, message_hash(&hasher, CHILD).value(), &hasher).is_err()
    );
    let salt = "synthetic-container-user";
    assert_eq!(
        deterministic_message_record_name(&selected, salt).unwrap(),
        deterministic_message_record_name(PARENT, salt).unwrap()
    );
    assert_ne!(
        deterministic_message_record_name(&selected, salt).unwrap(),
        deterministic_message_record_name(BALLOON_UUID, salt).unwrap()
    );
}

#[test]
fn ordinary_message_and_extension_base_do_not_invent_parent() {
    let hasher = hasher();
    let base_hash = message_hash(&hasher, CHILD);
    for payload in [
        message(CloudCanonicalMessageAssociation::None, None, None),
        message(
            CloudCanonicalMessageAssociation::None,
            None,
            Some(extension(ExtensionSessionRole::Base, CHILD, &base_hash)),
        ),
    ] {
        for guid in [CHILD, PARENT, BALLOON_UUID] {
            assert!(selected_message_parent(
                &payload,
                message_hash(&hasher, guid).value(),
                &hasher
            )
            .is_err());
        }
    }
}

#[test]
fn reply_and_reaction_add_remove_select_declared_message_parent() {
    let hasher = hasher();
    let expected = message_hash(&hasher, PARENT);
    let parent = parent_reference(PARENT, expected.clone());
    for payload in [
        reply(PARENT, expected.clone()),
        message(
            CloudCanonicalMessageAssociation::ReactionAdd {
                kind: CloudCanonicalReactionKind::Like,
                parent: parent.clone(),
            },
            None,
            None,
        ),
        message(
            CloudCanonicalMessageAssociation::ReactionRemove {
                kind: CloudCanonicalReactionKind::Like,
                parent,
            },
            None,
            None,
        ),
    ] {
        assert_eq!(
            selected_message_parent(&payload, expected.value(), &hasher).unwrap(),
            PARENT
        );
        let reaction_domain = hasher
            .canonical_entity_key_hash(CloudCanonicalEntityKind::Reaction, PARENT)
            .unwrap();
        assert!(selected_message_parent(&payload, reaction_domain.value(), &hasher).is_err());
    }
}

#[test]
fn owned_attachment_selects_message_owner_and_unowned_attachment_rejects() {
    let hasher = hasher();
    let expected = message_hash(&hasher, PARENT);
    let payload = attachment(Some((PARENT, expected.clone())));
    assert_eq!(
        selected_message_parent(&payload, expected.value(), &hasher).unwrap(),
        PARENT
    );
    let child_hash = hasher
        .canonical_owned_attachment_key_hash(PARENT, 0)
        .unwrap();
    assert!(selected_message_parent(&payload, child_hash.value(), &hasher).is_err());
    assert!(selected_message_parent(&attachment(None), expected.value(), &hasher).is_err());
}

#[test]
fn wrong_malformed_or_stale_install_expected_hash_cannot_select_a_parent() {
    let hasher = hasher();
    let expected = message_hash(&hasher, PARENT);
    let payload = reply(PARENT, expected.clone());
    let other_install = CloudSemanticIdentifierHasher::new(b"different-synthetic-install").unwrap();
    for wrong in [
        String::new(),
        "A".repeat(42),
        "!".repeat(43),
        "A".repeat(44),
        message_hash(&hasher, "unrelated-parent").value().into(),
        message_hash(&other_install, PARENT).value().into(),
    ] {
        assert!(selected_message_parent(&payload, &wrong, &hasher).is_err());
    }
    assert!(selected_message_parent(&payload, expected.value(), &other_install).is_err());
    assert_eq!(
        selected_message_parent(&payload, expected.value(), &hasher).unwrap(),
        PARENT
    );
}

#[test]
fn substituted_declared_parent_hash_fails_even_when_caller_repeats_it() {
    let hasher = hasher();
    let actual = message_hash(&hasher, PARENT);
    let forged = message_hash(&hasher, "substituted-parent");
    // The canonical constructors validate DTO shape. The selector must also
    // bind GUID bytes to the install-keyed hash, for every parent-bearing shape.
    for payload in [
        reply(PARENT, forged.clone()),
        message(
            CloudCanonicalMessageAssociation::ReactionAdd {
                kind: CloudCanonicalReactionKind::Heart,
                parent: parent_reference(PARENT, forged.clone()),
            },
            None,
            None,
        ),
        attachment(Some((PARENT, forged.clone()))),
        message(
            CloudCanonicalMessageAssociation::None,
            None,
            Some(extension(ExtensionSessionRole::Update, PARENT, &forged)),
        ),
    ] {
        assert!(selected_message_parent(&payload, forged.value(), &hasher).is_err());
        assert!(selected_message_parent(&payload, actual.value(), &hasher).is_err());
    }
}

#[test]
fn parent_guid_case_is_preserved_through_logical_and_physical_keying() {
    let hasher = hasher();
    let lower = PARENT.to_lowercase();
    let upper = PARENT.to_uppercase();
    let variants = [PARENT, lower.as_str(), upper.as_str()];
    let mut record_hashes = Vec::new();
    for guid in variants {
        let logical = message_hash(&hasher, guid);
        let payload = reply(guid, logical.clone());
        let selected = selected_message_parent(&payload, logical.value(), &hasher).unwrap();
        assert_eq!(selected.as_bytes(), guid.as_bytes());
        for other in variants.into_iter().filter(|other| *other != guid) {
            assert!(selected_message_parent(
                &payload,
                message_hash(&hasher, other).value(),
                &hasher
            )
            .is_err());
        }
        let name = deterministic_message_record_name(&selected, "container-A").unwrap();
        let keyed = hasher.server_record_id_hash(&name);
        assert_eq!(
            keyed,
            hasher.server_record_id_hash(
                &deterministic_message_record_name(guid, "container-A").unwrap()
            )
        );
        assert_ne!(
            keyed,
            hasher.server_record_id_hash(
                &deterministic_message_record_name(guid, "container-B").unwrap()
            )
        );
        assert_ne!(keyed, logical.value());
        assert!(!record_hashes.contains(&keyed));
        record_hashes.push(keyed);
    }
}

#[test]
fn locator_source_keeps_cached_read_and_final_protected_child_rebind() {
    let source = include_str!("cloud_sync_dependency.rs");
    let tail = source
        .split("pub async fn cloud_sync_locate_protected_message_parent(")
        .nth(1)
        .expect("locator API");
    // Top-level closing brace ends this cached API. A separate explicit
    // exact-fetch API later in the module is outside this contract.
    let (api, _) = tail.split_once("\n}").expect("cached locator body end");
    assert!(api.contains("get_cached_container_for_read_authentication"));
    assert!(api.contains("cloud_sync_decode_transient_record_cached_only"));
    assert!(api.contains("Arc::ptr_eq(&container, &current_container)"));
    let rebind = api
        .find("bind_envelope(&request, &child, &hasher)")
        .unwrap();
    let returned = api
        .find("target: Some(CloudSyncDependencyParentTarget")
        .unwrap();
    assert!(rebind < returned);
    for forbidden in [
        "ZoneSaveOperation",
        "RecordFetchOperation",
        "InspectReceivedRecordOperation",
        "sync_keychain(",
        "warmReadAuthentication",
        "cloud_sync_stage_received",
        "stage_received_message(",
        "get_container().await",
    ] {
        assert!(
            !api.contains(forbidden),
            "unexpected side-effect path: {forbidden}"
        );
    }
}
