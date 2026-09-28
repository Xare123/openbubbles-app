//! Immutable historical archive source for upgrade imports. No network,
//! persistence, IDS send, CloudKit authority, projection, or save method.
//! Distinct from live receive: there is no MessageInst wire, no receive
//! endpoint is retained (old rows never recorded one), and nothing here
//! invents chat.usingHandle, a self alias, or create authority. Raw
//! content stays native and must be protected by the separate staging
//! wrapper before retention. No Debug implementations.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_historical_media::HistoricalMedia;
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const FORMAT: &str = "cloud-sync-historical-source-v1";
const GROUP_FORMAT: &str = "cloud-sync-historical-source-v2";
const PARENT_FORMAT: &str = "cloud-sync-historical-source-v3";
const MEDIA_FORMAT: &str = "cloud-sync-historical-source-v4";
const MAX_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 4096;
/// First Unix millisecond representable as positive Apple-epoch nanos:
/// (millis - 978307200000) * 1000000 > 0. Matches the Dart request bound.
const MIN_DATE_CREATED_MS: u64 = 978_307_200_001;
/// Upper bound matching the Dart request bound.
const MAX_DATE_CREATED_MS: u64 = 10_201_679_236_854;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum HistoricalArchiveOrigin {
    HistoricalReceived,
    HistoricalSent,
}

impl HistoricalArchiveOrigin {
    fn label(self) -> &'static str {
        match self {
            Self::HistoricalReceived => "historicalReceived",
            Self::HistoricalSent => "historicalSent",
        }
    }
}

/// Validated caller binding. The caller qualifies the snapshot and the
/// authenticated account/store before staging; shape checks here never
/// authenticate ownership.
pub(crate) struct HistoricalBinding<'a> {
    pub(crate) snapshot_sha256: &'a str,
    pub(crate) account_fingerprint: &'a str,
    pub(crate) protected_store_identity: &'a str,
}

/// Plain historical row fields from the assessed stored row. No wire
/// object, no reply tokens, no delivery metadata.
pub(crate) struct HistoricalRow<'a> {
    pub(crate) guid: &'a str,
    pub(crate) text: &'a str,
    pub(crate) sender: &'a str,
    pub(crate) peer: &'a str,
    pub(crate) chat_guid: &'a str,
    pub(crate) date_created_ms: u64,
    pub(crate) is_from_me: bool,
}

/// Exact stored group context, not membership at the historical send time.
/// Tuple order matches the optional Dart snapshot/source extension.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HistoricalGroupMetadata(
    pub(crate) u8,
    pub(crate) Option<String>,
    pub(crate) Vec<(String, String)>,
);

/// Frozen conversion inputs, never native ownership/create authority. Tuple
/// order is the Dart CloudSyncHistoricalChatState wire format. Saved plist bytes
/// remain opaque until a parent projector validates their full routing identity.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HistoricalParentState(
    pub(crate) u8,             // version
    pub(crate) Option<String>, // cloudGuid
    pub(crate) Option<String>, // usingHandle
    pub(crate) Option<String>, // displayName
    pub(crate) Option<i64>,    // groupVersion
    pub(crate) Option<String>, // lastReadMessageGuid
    pub(crate) Option<i64>,    // latestMessageDateMs
    pub(crate) Option<String>, // photoAttachmentGuid
    pub(crate) bool,           // customAvatarPresent
    pub(crate) Option<String>, // ckRecordId
    pub(crate) bool,           // ckSyncState
    pub(crate) Option<String>, // cloudDataBase64
    pub(crate) Vec<String>,    // guidRefs
);

impl HistoricalParentState {
    fn validate(&self) -> Result<(), Failure> {
        if self.0 != 1 {
            return Err(Failure::MalformedMessage);
        }
        // Capture retains metadata, including unsupported values, under the
        // existing whole-source byte limit. The parent projector must validate
        // identity before use; chat preferences cannot invalidate otherwise
        // supported messages whose parents already exist. Match the Dart codec.
        if let Some(encoded) = &self.11 {
            if encoded.len() > MAX_BYTES {
                return Err(Failure::OversizedMessage);
            }
            let bytes = STANDARD
                .decode(encoded)
                .map_err(|_| Failure::MalformedMessage)?;
            if STANDARD.encode(bytes) != *encoded {
                return Err(Failure::MalformedMessage);
            }
        }
        Ok(())
    }
}

/// Exact Dart stagedHistoricalPayload wire shape, in fixed field order:
/// format, guid, text, origin, isFromMe, senderAddress, peerAddress,
/// chatGuid, dateCreatedMs, snapshotSha256, accountFingerprint,
/// protectedStoreIdentity. Field renames preserve that order for
/// canonical byte equality with Dart jsonEncode output.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Source {
    format: String,
    guid: String,
    text: String,
    origin: HistoricalArchiveOrigin,
    #[serde(rename = "isFromMe")]
    is_from_me: bool,
    #[serde(rename = "senderAddress")]
    sender: String,
    #[serde(rename = "peerAddress")]
    peer: String,
    #[serde(rename = "chatGuid")]
    chat_guid: String,
    #[serde(rename = "dateCreatedMs")]
    sent_timestamp: u64,
    #[serde(rename = "snapshotSha256")]
    snapshot_sha256: String,
    #[serde(rename = "accountFingerprint")]
    account_fingerprint: String,
    #[serde(rename = "protectedStoreIdentity")]
    protected_store_identity: String,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "groupMetadata"
    )]
    group_metadata: Option<HistoricalGroupMetadata>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "parentState"
    )]
    parent_state: Option<HistoricalParentState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    media: Option<HistoricalMedia>,
}

pub(crate) struct HistoricalArchiveSource(Source);

impl HistoricalArchiveSource {
    /// Stages one assessed row against its validated binding. Rejects
    /// directional contradictions, blank/NUL/oversized fields, and
    /// out-of-range dates. Never synthesizes a MessageInst.
    pub(crate) fn capture(
        row: &HistoricalRow,
        binding: &HistoricalBinding,
        sender_is_local: bool,
    ) -> Result<Self, Failure> {
        Self::capture_with_group(row, binding, sender_is_local, None)
    }

    pub(crate) fn capture_group(
        row: &HistoricalRow,
        binding: &HistoricalBinding,
        sender_is_local: bool,
        group: HistoricalGroupMetadata,
    ) -> Result<Self, Failure> {
        Self::capture_with_group(row, binding, sender_is_local, Some(group))
    }

    fn capture_with_group(
        row: &HistoricalRow,
        binding: &HistoricalBinding,
        sender_is_local: bool,
        group_metadata: Option<HistoricalGroupMetadata>,
    ) -> Result<Self, Failure> {
        Self::capture_with_parent(row, binding, sender_is_local, group_metadata, None)
    }

    pub(crate) fn capture_with_parent(
        row: &HistoricalRow,
        binding: &HistoricalBinding,
        sender_is_local: bool,
        group_metadata: Option<HistoricalGroupMetadata>,
        parent_state: Option<HistoricalParentState>,
    ) -> Result<Self, Failure> {
        Self::capture_with_media(
            row,
            binding,
            sender_is_local,
            group_metadata,
            parent_state,
            None,
        )
    }

    pub(crate) fn capture_with_media(
        row: &HistoricalRow,
        binding: &HistoricalBinding,
        sender_is_local: bool,
        group_metadata: Option<HistoricalGroupMetadata>,
        parent_state: Option<HistoricalParentState>,
        media: Option<HistoricalMedia>,
    ) -> Result<Self, Failure> {
        if let Some(parent) = &parent_state {
            parent.validate()?;
        }
        identifier(row.guid)?;
        if row.guid.starts_with("temp") || row.guid.starts_with("error") {
            return Err(Failure::UnsupportedMessage);
        }
        identifier(row.sender)?;
        identifier(row.peer)?;
        identifier(row.chat_guid)?;
        if let Some(group) = &group_metadata {
            if group.0 != 1 || group.2.is_empty() {
                return Err(Failure::MalformedMessage);
            }
            if let Some(cloud_guid) = &group.1 {
                identifier(cloud_guid)?;
            }
            let mut members = std::collections::HashSet::new();
            for (address, service) in &group.2 {
                identifier(address)?;
                identifier(bare(address))?;
                if service != "iMessage" || !members.insert(bare(address)) {
                    return Err(Failure::MalformedMessage);
                }
            }
            if !members.contains(bare(row.peer)) {
                return Err(Failure::BindingMismatch);
            }
        }
        if let Some(media) = &media {
            media.validate(row.guid, row.text)?;
        } else {
            if row.text.is_empty()
                || row.text.trim_matches(dart_whitespace).is_empty()
                || row.text.contains('\0')
                || row.text.len() > MAX_TEXT_BYTES
            {
                return Err(Failure::MalformedMessage);
            }
        }
        if row.date_created_ms < MIN_DATE_CREATED_MS || row.date_created_ms > MAX_DATE_CREATED_MS {
            return Err(Failure::MalformedMessage);
        }
        snapshot_hex(binding.snapshot_sha256)?;
        identifier(binding.account_fingerprint)?;
        identifier(binding.protected_store_identity)?;
        let origin = match (sender_is_local, row.is_from_me) {
            (true, true) => HistoricalArchiveOrigin::HistoricalSent,
            (false, false) => HistoricalArchiveOrigin::HistoricalReceived,
            _ => return Err(Failure::BindingMismatch),
        };
        let source = Source {
            format: if media.is_some() {
                MEDIA_FORMAT
            } else if parent_state.is_some() {
                PARENT_FORMAT
            } else if group_metadata.is_some() {
                GROUP_FORMAT
            } else {
                FORMAT
            }
            .into(),
            guid: row.guid.into(),
            text: row.text.into(),
            origin,
            is_from_me: row.is_from_me,
            sender: row.sender.into(),
            peer: row.peer.into(),
            chat_guid: row.chat_guid.into(),
            sent_timestamp: row.date_created_ms,
            snapshot_sha256: binding.snapshot_sha256.into(),
            account_fingerprint: binding.account_fingerprint.into(),
            protected_store_identity: binding.protected_store_identity.into(),
            group_metadata,
            parent_state,
            media,
        };
        let staged = Self(source);
        staged.encode()?;
        Ok(staged)
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>, Failure> {
        let bytes = serde_json::to_vec(&self.0).map_err(|_| Failure::MalformedMessage)?;
        if bytes.len() > MAX_BYTES {
            return Err(Failure::OversizedMessage);
        }
        Ok(bytes)
    }

    /// Canonical decode for staging verification and read-only discovery.
    /// Deny unknown fields, require the independently retained source digest
    /// and caller-qualified scope, then compare canonical bytes. The digest is
    /// integrity, not account authentication or permission to save a record.
    pub(crate) fn decode(
        bytes: &[u8],
        binding: &HistoricalBinding,
        expected_source_sha256: &str,
    ) -> Result<Self, Failure> {
        if bytes.is_empty() || bytes.len() > MAX_BYTES {
            return Err(Failure::OversizedMessage);
        }
        snapshot_hex(expected_source_sha256)?;
        let source: Source =
            serde_json::from_slice(bytes).map_err(|_| Failure::MalformedMessage)?;
        let expected_format = if source.media.is_some() {
            MEDIA_FORMAT
        } else if source.parent_state.is_some() {
            PARENT_FORMAT
        } else if source.group_metadata.is_some() {
            GROUP_FORMAT
        } else {
            FORMAT
        };
        if source.format != expected_format {
            return Err(Failure::UnsupportedMessage);
        }
        if source.snapshot_sha256 != binding.snapshot_sha256
            || source.account_fingerprint != binding.account_fingerprint
            || source.protected_store_identity != binding.protected_store_identity
        {
            return Err(Failure::BindingMismatch);
        }
        let sender_is_local = source.origin == HistoricalArchiveOrigin::HistoricalSent;
        let row = HistoricalRow {
            guid: &source.guid,
            text: &source.text,
            sender: &source.sender,
            peer: &source.peer,
            chat_guid: &source.chat_guid,
            date_created_ms: source.sent_timestamp,
            is_from_me: source.is_from_me,
        };
        let canonical = Self::capture_with_media(
            &row,
            binding,
            sender_is_local,
            source.group_metadata.clone(),
            source.parent_state.clone(),
            source.media.clone(),
        )?;
        if canonical.0 != source
            || canonical.encode()? != bytes
            || canonical.source_sha256()? != expected_source_sha256
        {
            return Err(Failure::BindingMismatch);
        }
        Ok(canonical)
    }

    pub(crate) fn guid(&self) -> &str {
        &self.0.guid
    }
    pub(crate) fn origin(&self) -> HistoricalArchiveOrigin {
        self.0.origin
    }
    pub(crate) fn sent_timestamp(&self) -> u64 {
        self.0.sent_timestamp
    }
    pub(crate) fn text(&self) -> &str {
        &self.0.text
    }
    pub(crate) fn sender(&self) -> &str {
        &self.0.sender
    }
    pub(crate) fn peer(&self) -> &str {
        &self.0.peer
    }
    pub(crate) fn chat_guid(&self) -> &str {
        &self.0.chat_guid
    }
    pub(crate) fn group_metadata(&self) -> Option<&HistoricalGroupMetadata> {
        self.0.group_metadata.as_ref()
    }
    pub(crate) fn parent_state(&self) -> Option<&HistoricalParentState> {
        self.0.parent_state.as_ref()
    }
    pub(crate) fn media(&self) -> Option<&HistoricalMedia> {
        self.0.media.as_ref()
    }
    pub(crate) fn require_account_store(&self, account: &str, store: &str) -> Result<(), Failure> {
        if self.0.account_fingerprint != account || self.0.protected_store_identity != store {
            return Err(Failure::BindingMismatch);
        }
        Ok(())
    }
    /// Lane-local ID digest in a namespace disjoint from live capture.
    pub(crate) fn guid_hash(&self) -> Result<String, Failure> {
        digest(&serde_json::json!([
            "cloud-sync-historical-archive-guid-v1",
            self.0.guid
        ]))
    }
    /// Lane-local source digest over the full validated binding.
    pub(crate) fn source_sha256(&self) -> Result<String, Failure> {
        let s = &self.0;
        let mut fields = vec![serde_json::json!(if s.media.is_some() {
            "cloud-sync-historical-archive-source-v4"
        } else if s.parent_state.is_some() {
            "cloud-sync-historical-archive-source-v3"
        } else if s.group_metadata.is_some() {
            "cloud-sync-historical-archive-source-v2"
        } else {
            "cloud-sync-historical-archive-source-v1"
        })];
        fields.extend(
            serde_json::json!([
                s.guid,
                s.text,
                s.sender,
                s.peer,
                s.chat_guid,
                s.sent_timestamp,
                s.origin.label(),
                s.is_from_me,
                s.snapshot_sha256,
                s.account_fingerprint,
                s.protected_store_identity
            ])
            .as_array()
            .ok_or(Failure::MalformedMessage)?
            .iter()
            .cloned(),
        );
        if let Some(group) = &s.group_metadata {
            fields.push(serde_json::to_value(group).map_err(|_| Failure::MalformedMessage)?);
        }
        if let Some(parent) = &s.parent_state {
            fields.push(serde_json::to_value(parent).map_err(|_| Failure::MalformedMessage)?);
        }
        if let Some(media) = &s.media {
            fields.push(serde_json::to_value(media).map_err(|_| Failure::MalformedMessage)?);
        }
        digest(&serde_json::Value::Array(fields))
    }
}

fn bare(value: &str) -> &str {
    value
        .strip_prefix("mailto:")
        .or_else(|| value.strip_prefix("tel:"))
        .unwrap_or(value)
}

fn dart_whitespace(c: char) -> bool {
    c.is_whitespace() || c == '\u{feff}'
}
fn identifier(value: &str) -> Result<(), Failure> {
    if value.is_empty() || value.trim_matches(dart_whitespace) != value || value.contains('\0') {
        return Err(Failure::MalformedMessage);
    }
    if value.len() > MAX_IDENTIFIER_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}
fn snapshot_hex(value: &str) -> Result<(), Failure> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn digest(value: &serde_json::Value) -> Result<String, Failure> {
    let bytes = serde_json::to_vec(value).map_err(|_| Failure::MalformedMessage)?;
    Ok(Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SNAPSHOT: &str = "ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34";
    const ACCOUNT: &str = "account-fp-xyz789";
    const STORE: &str = "store-1";

    fn binding() -> HistoricalBinding<'static> {
        HistoricalBinding {
            snapshot_sha256: SNAPSHOT,
            account_fingerprint: ACCOUNT,
            protected_store_identity: STORE,
        }
    }

    fn row() -> HistoricalRow<'static> {
        HistoricalRow {
            guid: "A1B2C3D4-E5F6-4A7B-8C9D-E0F1A2B3C4D5",
            text: "hello from before the upgrade",
            sender: "friend@example.com",
            peer: "friend@example.com",
            chat_guid: "iMessage;-;friend@example.com",
            date_created_ms: 1_699_000_000_000,
            is_from_me: false,
        }
    }

    #[test]
    fn both_origins_round_trip_canonically() {
        let received = HistoricalArchiveSource::capture(&row(), &binding(), false).unwrap();
        assert!(received.origin() == HistoricalArchiveOrigin::HistoricalReceived);
        let bytes = received.encode().unwrap();
        let decoded =
            HistoricalArchiveSource::decode(&bytes, &binding(), &received.source_sha256().unwrap())
                .unwrap();
        assert_eq!(decoded.encode().unwrap(), bytes);
        let sent_row = HistoricalRow {
            sender: "me@example.com",
            is_from_me: true,
            ..row()
        };
        let sent = HistoricalArchiveSource::capture(&sent_row, &binding(), true).unwrap();
        assert!(sent.origin() == HistoricalArchiveOrigin::HistoricalSent);
        assert_eq!(sent.guid(), row().guid);
        assert_eq!(sent.sent_timestamp(), 1_699_000_000_000);
        assert!(HistoricalArchiveSource::decode(
            &sent.encode().unwrap(),
            &binding(),
            &sent.source_sha256().unwrap()
        )
        .is_ok());
    }

    #[test]
    fn cross_binding_decode_fails_closed() {
        let source = HistoricalArchiveSource::capture(&row(), &binding(), false).unwrap();
        let bytes = source.encode().unwrap();
        let expected = source.source_sha256().unwrap();
        let other_account = HistoricalBinding {
            account_fingerprint: "other-account",
            ..binding()
        };
        assert!(HistoricalArchiveSource::decode(&bytes, &other_account, &expected).is_err());
        let other_store = HistoricalBinding {
            protected_store_identity: "store-2",
            ..binding()
        };
        assert!(HistoricalArchiveSource::decode(&bytes, &other_store, &expected).is_err());
        let other_snapshot = HistoricalBinding {
            snapshot_sha256: "cc12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34",
            ..binding()
        };
        assert!(HistoricalArchiveSource::decode(&bytes, &other_snapshot, &expected).is_err());
        let malformed_snapshot = HistoricalBinding {
            snapshot_sha256: "short",
            ..binding()
        };
        assert!(HistoricalArchiveSource::capture(&row(), &malformed_snapshot, false).is_err());
        let uppercase_snapshot = SNAPSHOT.to_uppercase();
        assert!(HistoricalArchiveSource::capture(
            &row(),
            &HistoricalBinding {
                snapshot_sha256: &uppercase_snapshot,
                ..binding()
            },
            false
        )
        .is_err());
    }

    #[test]
    fn directional_contradictions_reject() {
        assert!(HistoricalArchiveSource::capture(&row(), &binding(), true).is_err());
        let sent_row = HistoricalRow {
            sender: "me@example.com",
            is_from_me: true,
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&sent_row, &binding(), false).is_err());
    }

    #[test]
    fn altered_body_route_time_breaks_canonical_binding() {
        let source = HistoricalArchiveSource::capture(&row(), &binding(), false).unwrap();
        let expected = source.source_sha256().unwrap();
        let changed_row = HistoricalRow {
            text: "changed text",
            ..row()
        };
        let changed = HistoricalArchiveSource::capture(&changed_row, &binding(), false).unwrap();
        // Preserve canonical order and valid row shape. Rejection must be the
        // independent source pin, not a Value reserialization ordering error.
        assert!(matches!(
            HistoricalArchiveSource::decode(&changed.encode().unwrap(), &binding(), &expected),
            Err(Failure::BindingMismatch)
        ));
        assert!(HistoricalArchiveSource::decode(
            &changed.encode().unwrap(),
            &binding(),
            &changed.source_sha256().unwrap()
        )
        .is_ok());
        let route_row = HistoricalRow {
            chat_guid: "iMessage;-;other@example.com",
            ..row()
        };
        let route_source = HistoricalArchiveSource::capture(&route_row, &binding(), false).unwrap();
        assert_ne!(route_source.source_sha256().unwrap(), expected);
        assert!(HistoricalArchiveSource::decode(
            &route_source.encode().unwrap(),
            &binding(),
            &expected
        )
        .is_err());
        let time_row = HistoricalRow {
            date_created_ms: 1_699_000_000_001,
            ..row()
        };
        let time_source = HistoricalArchiveSource::capture(&time_row, &binding(), false).unwrap();
        assert_ne!(time_source.source_sha256().unwrap(), expected);
        assert!(HistoricalArchiveSource::decode(
            &time_source.encode().unwrap(),
            &binding(),
            &expected
        )
        .is_err());
    }

    #[test]
    fn digest_namespaces_differ_from_live_capture() {
        let source = HistoricalArchiveSource::capture(&row(), &binding(), false).unwrap();
        let live_guid = digest(&serde_json::json!([
            "cloud-sync-received-archive-guid-v1",
            row().guid
        ]))
        .unwrap();
        assert_ne!(source.guid_hash().unwrap(), live_guid);
    }

    #[test]
    fn bounds_blank_and_unknown_fields_reject() {
        let too_old = HistoricalRow {
            date_created_ms: MIN_DATE_CREATED_MS - 1,
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&too_old, &binding(), false).is_err());
        let too_new = HistoricalRow {
            date_created_ms: MAX_DATE_CREATED_MS + 1,
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&too_new, &binding(), false).is_err());
        let blank = HistoricalRow {
            text: "   ",
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&blank, &binding(), false).is_err());
        let nul = HistoricalRow {
            text: "a\0b",
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&nul, &binding(), false).is_err());
        let oversized_text = "x".repeat(MAX_TEXT_BYTES + 1);
        let oversized_row = HistoricalRow {
            text: &oversized_text,
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&oversized_row, &binding(), false).is_err());
        let long_guid_text = "g".repeat(MAX_IDENTIFIER_BYTES + 1);
        let long_guid_row = HistoricalRow {
            guid: &long_guid_text,
            ..row()
        };
        assert!(HistoricalArchiveSource::capture(&long_guid_row, &binding(), false).is_err());
        let source = HistoricalArchiveSource::capture(&row(), &binding(), false).unwrap();
        let mut extra =
            serde_json::from_slice::<serde_json::Value>(&source.encode().unwrap()).unwrap();
        extra["unexpected"] = serde_json::json!(1);
        let extra_bytes = serde_json::to_vec(&extra).unwrap();
        let expected = source.source_sha256().unwrap();
        assert!(HistoricalArchiveSource::decode(&extra_bytes, &binding(), &expected).is_err());
        assert!(HistoricalArchiveSource::decode(&[], &binding(), &expected).is_err());
        assert!(
            HistoricalArchiveSource::decode(&source.encode().unwrap(), &binding(), "").is_err()
        );
    }

    #[test]
    fn shared_dart_wire_vectors_match_exact_bytes_and_digests() {
        let mut vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v1.json"
        ))
        .unwrap();
        vectors.extend(
            serde_json::from_str::<Vec<serde_json::Value>>(include_str!(
                "../../test/fixtures/cloud_sync/historical_source_v2.json"
            ))
            .unwrap(),
        );
        vectors.extend(
            serde_json::from_str::<Vec<serde_json::Value>>(include_str!(
                "../../test/fixtures/cloud_sync/historical_source_v3.json"
            ))
            .unwrap(),
        );
        vectors.extend(
            serde_json::from_str::<Vec<serde_json::Value>>(include_str!(
                "../../test/fixtures/cloud_sync/historical_source_v4.json"
            ))
            .unwrap(),
        );
        assert_eq!(vectors.len(), 8);
        for vector in vectors {
            let bytes = vector["canonicalPayload"].as_str().unwrap().as_bytes();
            let source: Source = serde_json::from_slice(bytes).unwrap();
            let bound = HistoricalBinding {
                snapshot_sha256: &source.snapshot_sha256,
                account_fingerprint: &source.account_fingerprint,
                protected_store_identity: &source.protected_store_identity,
            };
            let decoded = HistoricalArchiveSource::decode(
                bytes,
                &bound,
                vector["sourceSha256"].as_str().unwrap(),
            )
            .unwrap();
            assert_eq!(decoded.encode().unwrap(), bytes);
            assert_eq!(
                decoded.guid_hash().unwrap(),
                vector["guidHash"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn frozen_parent_metadata_is_exactly_bound_and_never_receiving_endpoint() {
        let vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v3.json"
        ))
        .unwrap();
        let bytes = vectors[0]["canonicalPayload"].as_str().unwrap().as_bytes();
        let expected = vectors[0]["sourceSha256"].as_str().unwrap();
        let original = HistoricalArchiveSource::decode(bytes, &binding(), expected).unwrap();
        assert_eq!(original.sender(), "friend@example.com");
        assert_eq!(
            original.parent_state().unwrap().2.as_deref(),
            Some("mailto:me@example.com")
        );
        let changes: &[fn(&mut HistoricalParentState)] = &[
            |p| p.1 = Some("different-cloud-guid".into()),
            |p| p.2 = Some("other-owner@example.com".into()),
            |p| p.3 = Some("Different title".into()),
            |p| p.4 = Some(4),
            |p| p.5 = Some("different-read-guid".into()),
            |p| p.6 = Some(1_699_000_000_001),
            |p| p.7 = Some("photo-guid".into()),
            |p| p.8 = !p.8,
            |p| p.9 = Some("existing-record".into()),
            |p| p.10 = !p.10,
            |p| p.11 = Some(STANDARD.encode(b"different saved plist")),
            |p| p.12.push("different-alias".into()),
        ];
        for change in changes {
            let mut changed = HistoricalArchiveSource(original.0.clone());
            change(changed.0.parent_state.as_mut().unwrap());
            let changed_bytes = changed.encode().unwrap();
            let changed_hash = changed.source_sha256().unwrap();
            assert_ne!(changed_hash, expected);
            assert!(matches!(
                HistoricalArchiveSource::decode(&changed_bytes, &binding(), expected),
                Err(Failure::BindingMismatch)
            ));
            assert!(
                HistoricalArchiveSource::decode(&changed_bytes, &binding(), &changed_hash).is_ok()
            );
        }
    }

    #[test]
    fn parent_metadata_format_and_base64_cannot_be_downgraded_or_relabelled() {
        let vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v3.json"
        ))
        .unwrap();
        let original = HistoricalArchiveSource::decode(
            vectors[0]["canonicalPayload"].as_str().unwrap().as_bytes(),
            &binding(),
            vectors[0]["sourceSha256"].as_str().unwrap(),
        )
        .unwrap();
        for format in [FORMAT, GROUP_FORMAT] {
            let mut changed = HistoricalArchiveSource(original.0.clone());
            changed.0.format = format.into();
            assert!(HistoricalArchiveSource::decode(
                &changed.encode().unwrap(),
                &binding(),
                &changed.source_sha256().unwrap()
            )
            .is_err());
        }
        for value in ["Yg", "not-base64"] {
            let mut changed = HistoricalArchiveSource(original.0.clone());
            changed.0.parent_state.as_mut().unwrap().11 = Some(value.into());
            assert!(HistoricalArchiveSource::decode(
                &changed.encode().unwrap(),
                &binding(),
                &changed.source_sha256().unwrap()
            )
            .is_err());
        }
        let mut changed = HistoricalArchiveSource(original.0.clone());
        changed.0.parent_state.as_mut().unwrap().0 = 2;
        assert!(HistoricalArchiveSource::decode(
            &changed.encode().unwrap(),
            &binding(),
            &changed.source_sha256().unwrap()
        )
        .is_err());
        changed.0.parent_state = None;
        assert!(HistoricalArchiveSource::decode(
            &changed.encode().unwrap(),
            &binding(),
            &changed.source_sha256().unwrap()
        )
        .is_err());
    }

    #[test]
    fn group_extension_cannot_be_relabelled_omitted_or_changed() {
        let group = HistoricalGroupMetadata(
            1,
            Some("stored-group".into()),
            vec![
                ("friend@example.com".into(), "iMessage".into()),
                ("other@example.com".into(), "iMessage".into()),
            ],
        );
        let source = HistoricalArchiveSource::capture_group(
            &HistoricalRow {
                chat_guid: "iMessage;+;historical-group",
                ..row()
            },
            &binding(),
            false,
            group.clone(),
        )
        .unwrap();
        let original = source.encode().unwrap();
        let expected = source.source_sha256().unwrap();
        assert!(HistoricalArchiveSource::decode(&original, &binding(), &expected).is_ok());
        for field in ["groupMetadata", "format"] {
            let mut changed: serde_json::Value = serde_json::from_slice(&original).unwrap();
            changed.as_object_mut().unwrap().remove(field);
            assert!(HistoricalArchiveSource::decode(
                &serde_json::to_vec(&changed).unwrap(),
                &binding(),
                &expected
            )
            .is_err());
        }
        for changed in [
            HistoricalGroupMetadata(2, group.1.clone(), group.2.clone()),
            HistoricalGroupMetadata(1, Some(" ".into()), group.2.clone()),
            HistoricalGroupMetadata(1, group.1.clone(), vec![]),
            HistoricalGroupMetadata(
                1,
                group.1.clone(),
                vec![("friend@example.com".into(), "SMS".into())],
            ),
            HistoricalGroupMetadata(
                1,
                group.1.clone(),
                vec![
                    ("friend@example.com".into(), "iMessage".into()),
                    ("mailto:friend@example.com".into(), "iMessage".into()),
                ],
            ),
        ] {
            assert!(
                HistoricalArchiveSource::capture_group(&row(), &binding(), false, changed).is_err()
            );
        }
        let mut changed = group;
        changed.1 = Some("another-group".into());
        let changed = HistoricalArchiveSource::capture_group(
            &HistoricalRow {
                chat_guid: "iMessage;+;historical-group",
                ..row()
            },
            &binding(),
            false,
            changed,
        )
        .unwrap();
        assert!(
            HistoricalArchiveSource::decode(&changed.encode().unwrap(), &binding(), &expected)
                .is_err()
        );
    }
}
