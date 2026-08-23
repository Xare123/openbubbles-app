//! Dependency-light keyed identity hashing for Cloud Sync V2.
//!
//! This module holds the per-install semantic identifier hasher and the two
//! small types it reports through. It deliberately depends only on hashing,
//! encoding, and the canonical DTO validation types so the native protector
//! and its standalone harness can both link it without the Apple record
//! parsing stack.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use thiserror::Error;

use crate::cloud_sync_canonical_dto::{
    CloudCanonicalAliasKind, CloudCanonicalEntityKind, CloudCanonicalHash,
    CloudCanonicalValidationFailure,
};

type HmacSha256 = Hmac<Sha256>;

const RECORD_ID_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 server record identity\0";
const LOGICAL_ID_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 logical entity identity\0";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum CloudSemanticEntityKind {
    Chat,
    Message,
    Attachment,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum CloudSemanticDecodeFailure {
    #[error("Cloud Sync record type is unsupported")]
    UnsupportedRecordType,
    #[error("Cloud Sync record metadata is malformed")]
    MalformedRecord,
    #[error("Cloud Sync PCS material is unavailable")]
    PcsUnavailable,
    #[error("Cloud Sync upstream operation failed and may be retried")]
    RetryableUpstreamFailure,
    #[error("Cloud Sync tombstone has no known entity mapping")]
    TombstoneMappingMissing,
}

/// Per-install keyed hashing adapter. The key is held only in the native
/// boundary. Callers must obtain it from protected local storage and must not
/// place it in diagnostics or Dart-visible state.
#[derive(Clone)]
pub struct CloudSemanticIdentifierHasher {
    key: Vec<u8>,
}

impl CloudSemanticIdentifierHasher {
    pub fn new(key: impl AsRef<[u8]>) -> Result<Self, CloudSemanticDecodeFailure> {
        let key = key.as_ref();
        if key.is_empty() {
            return Err(CloudSemanticDecodeFailure::MalformedRecord);
        }
        Ok(Self { key: key.to_vec() })
    }

    pub(crate) fn digest(&self, domain: &[u8], value: &str) -> String {
        let mut mac = HmacSha256::new_from_slice(&self.key)
            .expect("HMAC accepts arbitrary non-empty key lengths");
        mac.update(domain);
        mac.update(value.as_bytes());
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    }

    pub(crate) fn server_record_id_hash(&self, record_name: &str) -> String {
        self.digest(RECORD_ID_DOMAIN, record_name)
    }

    pub(crate) fn logical_entity_key_hash(
        &self,
        entity_kind: CloudSemanticEntityKind,
        identifier: &str,
    ) -> String {
        let kind = match entity_kind {
            CloudSemanticEntityKind::Chat => b"chat\0".as_slice(),
            CloudSemanticEntityKind::Message => b"message\0".as_slice(),
            CloudSemanticEntityKind::Attachment => b"attachment\0".as_slice(),
        };
        let mut canonical = Vec::with_capacity(kind.len() + identifier.len());
        canonical.extend_from_slice(kind);
        canonical.extend_from_slice(identifier.as_bytes());
        let canonical =
            std::str::from_utf8(&canonical).expect("entity kind and logical identifiers are UTF-8");
        self.digest(LOGICAL_ID_DOMAIN, canonical)
    }

    pub(crate) fn canonical_server_record_id_hash(
        &self,
        record_name: &str,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        CloudCanonicalHash::new(self.server_record_id_hash(record_name))
    }

    pub(crate) fn canonical_entity_key_hash(
        &self,
        entity_kind: CloudCanonicalEntityKind,
        identifier: &str,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        let kind = match entity_kind {
            CloudCanonicalEntityKind::Chat => b"chat\0".as_slice(),
            CloudCanonicalEntityKind::Message => b"message\0".as_slice(),
            CloudCanonicalEntityKind::Reaction => b"reaction\0".as_slice(),
            CloudCanonicalEntityKind::Attachment => b"attachment\0".as_slice(),
            CloudCanonicalEntityKind::GroupPhoto => b"group-photo\0".as_slice(),
        };
        let mut canonical = Vec::with_capacity(kind.len() + identifier.len());
        canonical.extend_from_slice(kind);
        canonical.extend_from_slice(identifier.as_bytes());
        let canonical =
            std::str::from_utf8(&canonical).expect("entity kind and logical identifiers are UTF-8");
        CloudCanonicalHash::new(self.digest(LOGICAL_ID_DOMAIN, canonical))
    }

    pub(crate) fn canonical_reaction_key_hash(
        &self,
        reaction_guid: &str,
        parent_guid: &str,
        parent_part: Option<u32>,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        let part = parent_part
            .map(|value| format!("part:{value}"))
            .unwrap_or_else(|| "partless".to_owned());
        self.canonical_entity_key_hash(
            CloudCanonicalEntityKind::Reaction,
            &format!("{reaction_guid}\0{parent_guid}\0{part}"),
        )
    }

    pub(crate) fn canonical_owned_attachment_key_hash(
        &self,
        owner_message_guid: &str,
        owner_part: u32,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        self.canonical_entity_key_hash(
            CloudCanonicalEntityKind::Attachment,
            &format!("{owner_message_guid}\0{owner_part}"),
        )
    }

    pub(crate) fn canonical_alias_key_hash(
        &self,
        alias_kind: CloudCanonicalAliasKind,
        value: &str,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        const ALIAS_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 canonical alias identity v1\0";
        let kind = match alias_kind {
            CloudCanonicalAliasKind::ChatGroupId => b"group-id\0".as_slice(),
            CloudCanonicalAliasKind::ChatOriginalGroupId => b"original-group-id\0".as_slice(),
            CloudCanonicalAliasKind::ChatServiceIdentifier => b"service-identifier\0".as_slice(),
            CloudCanonicalAliasKind::ChatLegacyGroupIdentifier => {
                b"legacy-group-identifier\0".as_slice()
            }
        };
        let mut canonical = Vec::with_capacity(kind.len() + value.len());
        canonical.extend_from_slice(kind);
        canonical.extend_from_slice(value.as_bytes());
        let canonical =
            std::str::from_utf8(&canonical).expect("alias kind and identifier are UTF-8");
        CloudCanonicalHash::new(self.digest(ALIAS_DOMAIN, canonical))
    }

    pub(crate) fn canonical_etag_hash(
        &self,
        etag: &str,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        const ETAG_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 etag identity v1\0";
        CloudCanonicalHash::new(self.digest(ETAG_DOMAIN, etag))
    }

    pub(crate) fn canonical_change_id_hash(
        &self,
        canonical_change_material: &str,
    ) -> Result<CloudCanonicalHash, CloudCanonicalValidationFailure> {
        const CHANGE_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 change identity v1\0";
        CloudCanonicalHash::new(self.digest(CHANGE_DOMAIN, canonical_change_material))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_reaction_identity_distinguishes_partless_from_part_zero() {
        let hasher = CloudSemanticIdentifierHasher::new(b"reaction-identity-test").unwrap();
        let partless = hasher
            .canonical_reaction_key_hash("reaction-guid", "parent-guid", None)
            .unwrap();
        let part_zero = hasher
            .canonical_reaction_key_hash("reaction-guid", "parent-guid", Some(0))
            .unwrap();
        let part_one = hasher
            .canonical_reaction_key_hash("reaction-guid", "parent-guid", Some(1))
            .unwrap();

        assert_ne!(partless, part_zero);
        assert_ne!(partless, part_one);
        assert_ne!(part_zero, part_one);
        assert_eq!(
            part_zero,
            hasher
                .canonical_reaction_key_hash("reaction-guid", "parent-guid", Some(0))
                .unwrap()
        );
    }

    #[test]
    fn owned_attachment_identity_is_stable_for_owner_and_part() {
        let hasher = CloudSemanticIdentifierHasher::new(b"attachment-identity-test").unwrap();
        let first = hasher
            .canonical_owned_attachment_key_hash("message_guid_with_underscores", 7)
            .unwrap();

        assert_eq!(
            first,
            hasher
                .canonical_owned_attachment_key_hash("message_guid_with_underscores", 7)
                .unwrap()
        );
        assert_ne!(
            first,
            hasher
                .canonical_owned_attachment_key_hash("message_guid_with_underscores", 8)
                .unwrap()
        );
    }
}
