//! Candidate-specific identity observation, not projection or write authority.
//! Compare the complete known Chat identity before service filtering. No remote
//! absence is inferred: an unseen or concurrently created record can still exist.

use std::collections::BTreeSet;

use rustpush::cloud_messages::{validate_direct_chat_create, CloudChat};

use crate::{
    cloud_sync_canonical_converter::{
        CloudNestedPresence, CloudRawFieldPresence, CloudRawRecordPresence,
    },
    cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudChatIdentityComparison {
    Overlaps,
    Disjoint,
    Incomplete,
}

pub(crate) struct CloudChatIdentityObservation {
    pub comparison: CloudChatIdentityComparison,
    pub candidate_binding_hash: String,
}

impl std::fmt::Debug for CloudChatIdentityObservation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CloudChatIdentityObservation")
            .field("comparison", &self.comparison)
            .finish_non_exhaustive()
    }
}

fn identifier(value: &str) -> Option<String> {
    if value.is_empty()
        || value.len() > 4096
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        return None;
    }
    // Conservative comparison only. Case/prefix folding may produce overlap,
    // never permission to merge or rewrite the source's canonical identity.
    let lower = value.to_lowercase();
    Some(
        lower
            .strip_prefix("tel:")
            .or_else(|| lower.strip_prefix("mailto:"))
            .unwrap_or(&lower)
            .to_owned(),
    )
}

fn participant(value: &str) -> Option<String> {
    let value = identifier(value)?;
    let phone = value
        .strip_prefix('+')
        .is_some_and(|v| !v.is_empty() && v.len() <= 15 && v.bytes().all(|b| b.is_ascii_digit()));
    let email = value.split_once('@').is_some_and(|(local, domain)| {
        !local.is_empty()
            && !domain.is_empty()
            && !domain.contains('@')
            && !value.chars().any(char::is_whitespace)
    });
    (phone || email).then_some(value)
}

pub(crate) fn validate_chat_identity_candidate(candidate: &CloudChat) -> Result<(), ()> {
    validate_direct_chat_create(candidate).map_err(|_| ())?;
    participant(&candidate.chat_identifier).ok_or(())?;
    for value in [
        &candidate.guid,
        &candidate.chat_identifier,
        &candidate.group_id,
        &candidate.original_group_id,
        &candidate.last_addressed_handle,
    ] {
        identifier(value).ok_or(())?;
    }
    Ok(())
}

/// The caller must run the authenticated, strict PCS/record parser first.
/// The returned keyed binding covers the exact candidate, not only a service
/// label. An error means invalid candidate; incomplete source remains unknown.
pub(crate) fn observe_chat_identity(
    candidate: &CloudChat,
    source: &CloudChat,
    presence: &CloudRawRecordPresence,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudChatIdentityObservation, ()> {
    validate_chat_identity_candidate(candidate)?;
    let recipient = participant(&candidate.chat_identifier).ok_or(())?;
    let candidate_values = [
        candidate.guid.as_str(),
        candidate.chat_identifier.as_str(),
        candidate.group_id.as_str(),
        candidate.original_group_id.as_str(),
        candidate.last_addressed_handle.as_str(),
    ];
    let binding = serde_json::to_string(candidate).map_err(|_| ())?;
    if binding.len() > 16 * 1024 {
        return Err(());
    }
    let candidate_binding_hash = hasher.digest(
        b"OpenBubbles Cloud Sync V2 Chat observation candidate v1\0",
        &binding,
    );
    let observed = |comparison| {
        Ok(CloudChatIdentityObservation {
            comparison,
            candidate_binding_hash: candidate_binding_hash.clone(),
        })
    };
    let mut target = BTreeSet::from([recipient]);
    for value in &candidate_values[..4] {
        target.insert(identifier(value).ok_or(())?);
    }
    // Last-addressed handle is normally our own account. It binds the candidate
    // above, but must not make every conversation on our account overlap.
    let required = ["guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts"];
    if required
        .iter()
        .any(|field| presence.field(field) != CloudRawFieldPresence::PresentWithValue)
        || !matches!(source.style, 43 | 45)
        || !matches!(
            source.service_name.as_str(),
            "iMessage" | "SMS" | "MMS" | "RCS" | "iMessageLite"
        )
        || source.participants.len() > 4096
    {
        return observed(CloudChatIdentityComparison::Incomplete);
    }
    let mut values = Vec::from([
        source.guid.as_str(),
        source.chat_identifier.as_str(),
        source.group_id.as_str(),
        source.original_group_id.as_str(),
    ]);
    match (&source.properties, presence.field("prop")) {
        (None, CloudRawFieldPresence::Absent) => {}
        (None, _) if presence.was_sent_as_empty_list("prop") => {}
        (Some(properties), CloudRawFieldPresence::PresentWithValue) => {
            match presence.nested_field("prop", "legacyGroupIdentifiers") {
                CloudNestedPresence::Present => {}
                CloudNestedPresence::Absent if properties.legacy_group_identifiers.is_empty() => {}
                _ => return observed(CloudChatIdentityComparison::Incomplete),
            }
            if properties.legacy_group_identifiers.len() > 4096 {
                return observed(CloudChatIdentityComparison::Incomplete);
            }
            values.extend(
                properties
                    .legacy_group_identifiers
                    .iter()
                    .map(String::as_str),
            );
        }
        _ => return observed(CloudChatIdentityComparison::Incomplete),
    }
    let Some(mut source_identities) = values
        .into_iter()
        .map(identifier)
        .collect::<Option<BTreeSet<_>>>()
    else {
        return observed(CloudChatIdentityComparison::Incomplete);
    };
    for entry in &source.participants {
        let Some(value) = participant(&entry.uri) else {
            return observed(CloudChatIdentityComparison::Incomplete);
        };
        source_identities.insert(value);
    }
    observed(if target.is_disjoint(&source_identities) {
        CloudChatIdentityComparison::Disjoint
    } else {
        CloudChatIdentityComparison::Overlaps
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustpush::{
        cloud_messages::{CloudParticipant, CloudProp},
        cloudkit_proto::{
            record::{
                field::{Identifier, Value},
                Field,
            },
            Record,
        },
    };

    fn candidate() -> CloudChat {
        CloudChat {
            guid: "iMessage;-;+15555550101".into(),
            chat_identifier: "+15555550101".into(),
            group_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".into(),
            original_group_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".into(),
            service_name: "iMessage".into(),
            style: 45,
            state: 3,
            successful_query: 1,
            participants: vec![CloudParticipant {
                uri: "+15555550101".into(),
            }],
            last_addressed_handle: "owner@example.invalid".into(),
            ..Default::default()
        }
    }
    fn source() -> CloudChat {
        CloudChat {
            guid: "different-guid".into(),
            chat_identifier: "+15555550202".into(),
            group_id: "different-group".into(),
            original_group_id: "different-original".into(),
            participants: vec![CloudParticipant {
                uri: "tel:+15555550202".into(),
            }],
            ..candidate()
        }
    }
    fn presence(omit: Option<&str>, props: bool) -> CloudRawRecordPresence {
        let mut names = vec!["guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts"];
        if props {
            names.push("prop");
        }
        CloudRawRecordPresence::extract(&Record {
            record_field: names
                .into_iter()
                .filter(|name| Some(*name) != omit)
                .map(|name| Field {
                    identifier: Some(Identifier {
                        name: Some(name.into()),
                        ..Default::default()
                    }),
                    value: Some(Value::default()),
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        })
        .unwrap()
    }
    fn compare(
        source: &CloudChat,
        presence: &CloudRawRecordPresence,
    ) -> CloudChatIdentityComparison {
        observe_chat_identity(
            &candidate(),
            source,
            presence,
            &CloudSemanticIdentifierHasher::new(b"test-key").unwrap(),
        )
        .unwrap()
        .comparison
    }
    #[test]
    fn service_does_not_hide_any_identity_overlap() {
        for service in ["iMessage", "SMS", "MMS", "RCS", "iMessageLite"] {
            let distinct = CloudChat {
                service_name: service.into(),
                ..source()
            };
            assert_eq!(
                compare(&distinct, &presence(None, false)),
                CloudChatIdentityComparison::Disjoint
            );
            for field in ["guid", "cid", "gid", "ogid", "participant"] {
                let mut overlap = distinct.clone();
                match field {
                    "guid" => overlap.guid = candidate().guid,
                    "cid" => overlap.chat_identifier = candidate().chat_identifier,
                    "gid" => overlap.group_id = candidate().group_id.to_lowercase(),
                    "ogid" => overlap.original_group_id = candidate().group_id,
                    _ => overlap.participants[0].uri = "TEL:+15555550101".into(),
                }
                assert_eq!(
                    compare(&overlap, &presence(None, false)),
                    CloudChatIdentityComparison::Overlaps,
                    "{service}/{field}"
                );
            }
        }
    }
    #[test]
    fn missing_or_uninterpretable_identity_never_proves_disjointness() {
        for field in ["guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts"] {
            assert_eq!(
                compare(&source(), &presence(Some(field), false)),
                CloudChatIdentityComparison::Incomplete
            );
        }
        for bad in ["", " +15555550202", "future:opaque", "tel:"] {
            let mut row = source();
            row.participants[0].uri = bad.into();
            assert_eq!(
                compare(&row, &presence(None, false)),
                CloudChatIdentityComparison::Incomplete
            );
        }
        let unknown = CloudChat {
            service_name: "FutureService".into(),
            ..source()
        };
        assert_eq!(
            compare(&unknown, &presence(None, false)),
            CloudChatIdentityComparison::Incomplete
        );
    }
    #[test]
    fn property_lineage_requires_the_actual_decoded_dictionary() {
        let row = CloudChat {
            properties: Some(CloudProp {
                legacy_group_identifiers: vec![candidate().group_id],
                ..Default::default()
            }),
            ..source()
        };
        let mut fields = presence(None, true);
        assert_eq!(
            compare(&row, &fields),
            CloudChatIdentityComparison::Incomplete
        );
        let mut bytes = vec![];
        plist::to_writer_binary(&mut bytes, row.properties.as_ref().unwrap()).unwrap();
        fields
            .capture_decrypted_plist_dictionary("prop", &bytes)
            .unwrap();
        assert_eq!(
            compare(&row, &fields),
            CloudChatIdentityComparison::Overlaps
        );
    }
    #[test]
    fn observation_binding_is_candidate_and_install_specific_and_debug_is_redacted() {
        let key = CloudSemanticIdentifierHasher::new(b"test-key").unwrap();
        let a =
            observe_chat_identity(&candidate(), &source(), &presence(None, false), &key).unwrap();
        let mut other = candidate();
        other.last_addressed_handle = "other-owner@example.invalid".into();
        let b = observe_chat_identity(&other, &source(), &presence(None, false), &key).unwrap();
        let c = observe_chat_identity(
            &candidate(),
            &source(),
            &presence(None, false),
            &CloudSemanticIdentifierHasher::new(b"other-key").unwrap(),
        )
        .unwrap();
        assert_ne!(a.candidate_binding_hash, b.candidate_binding_hash);
        assert_ne!(a.candidate_binding_hash, c.candidate_binding_hash);
        assert!(!format!("{a:?}").contains(&a.candidate_binding_hash));
        other.participants.clear();
        assert!(observe_chat_identity(&other, &source(), &presence(None, false), &key).is_err());
    }
}
