//! Explicitly enabled Windows-test-only relationship graph for the bounded
//! Chat1 investigation. All Apple identifiers are replaced in memory with
//! run-local numeric symbols before serialization. Message text, subjects,
//! attributed bodies, extension payloads, display names and raw values are
//! never copied into the report.

use super::*;
use rustpush::cloud_messages::{CloudMessage, MessageFlags};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, HashMap};

const ENABLE: &str = "OPENBUBBLES_INSPECT_CHAT1_PSEUDONYMOUS_GRAPH";
const ACKNOWLEDGE: &str = "OPENBUBBLES_ACKNOWLEDGE_LOCAL_PERSONAL_DATA";
const REPORT_SCHEMA: u32 = 2;
const MAX_REPORT_BYTES: usize = 512 * 1024;
const APPLE_EPOCH_UNIX_MILLIS: i64 = 978_307_200_000;
const MAX_REPORTED_CLUSTER_IDENTITIES: usize = MAX_CHAT1_PARTICIPANTS;

pub(super) fn requested() -> Result<bool, ()> {
    let enable = std::env::var_os(ENABLE);
    let acknowledge = std::env::var_os(ACKNOWLEDGE);
    match (enable, acknowledge) {
        (None, None) => Ok(false),
        (Some(enable), Some(acknowledge)) if enable == "1" && acknowledge == "1" => Ok(true),
        _ => Err(()),
    }
}

#[derive(Default)]
struct SymbolTable {
    by_digest: HashMap<String, u32>,
}

impl SymbolTable {
    fn intern(&mut self, value: &str, hasher: &CloudSemanticIdentifierHasher) -> u32 {
        let digest = hasher.server_record_id_hash(value);
        if let Some(existing) = self.by_digest.get(&digest) {
            return *existing;
        }
        let next = u32::try_from(self.by_digest.len() + 1).expect("bounded symbol table");
        self.by_digest.insert(digest, next);
        next
    }

    fn len(&self) -> u32 {
        u32::try_from(self.by_digest.len()).expect("bounded symbol table")
    }
}

#[derive(Serialize)]
struct PseudonymRef {
    present: bool,
    symbol: Option<u32>,
    normalized_symbols: Vec<u32>,
    shape: &'static str,
}

#[derive(Serialize)]
struct MessageRelationshipRow {
    index: u32,
    record: PseudonymRef,
    chat_id: PseudonymRef,
    sender: PseudonymRef,
    destination_caller_id: PseudonymRef,
    msgproto_group_id: PseudonymRef,
    guid: PseudonymRef,
    route_kind: &'static str,
    service_class: &'static str,
    from_me: bool,
    outer_type: i64,
    error: i64,
    created_at_millis: Option<i64>,
    server_modified_at_millis: Option<i64>,
    text_present: bool,
    attributed_body_present: bool,
    extension_payload_present: bool,
    anchor_route_evidence: AnchorRouteEvidence,
}

#[derive(Serialize)]
struct AnchorRouteEvidence {
    exact_route_messages: u32,
    normalized_route_messages: u32,
    group_correlated_messages: u32,
    matched_anchor_messages: u32,
    cluster_messages_including_target: u32,
    from_me_messages: u32,
    incoming_messages: u32,
    observed_sender_count: u32,
    observed_senders_truncated: bool,
    observed_senders: Vec<PseudonymRef>,
    observed_destination_handle_count: u32,
    observed_destination_handles_truncated: bool,
    observed_destination_handles: Vec<PseudonymRef>,
    observed_group_id_count: u32,
    observed_group_ids_truncated: bool,
    observed_group_ids: Vec<PseudonymRef>,
    service_class_counts: BTreeMap<&'static str, u32>,
    route_kind_counts: BTreeMap<&'static str, u32>,
    first_created_at_millis: Option<i64>,
    last_created_at_millis: Option<i64>,
}

#[derive(Serialize)]
struct Chat1RelationshipRow {
    index: u32,
    record: PseudonymRef,
    chat_id: PseudonymRef,
    group_id: PseudonymRef,
    original_group_id: PseudonymRef,
    guid: PseudonymRef,
    last_addressed_handle: PseudonymRef,
    participants: Vec<PseudonymRef>,
    legacy_identifiers: Vec<PseudonymRef>,
    last_seen_message_guid: PseudonymRef,
    service_class: &'static str,
    style: Option<i64>,
    style_class: &'static str,
    last_read_at_millis: Option<i64>,
    server_created_at_millis: Option<i64>,
    server_modified_at_millis: Option<i64>,
}

#[derive(Serialize)]
struct RelationshipReport {
    schema: u32,
    content_exposed: bool,
    raw_identifiers_exposed: bool,
    anchor_sources: u32,
    decoded_anchor_sources: u32,
    skipped_anchor_sources: u32,
    pages_scanned: u32,
    changes_scanned: u32,
    chat_records: u32,
    tombstones: u32,
    other_records: u32,
    terminal_reached: bool,
    symbol_count: u32,
    chat1_field_shape_counts: BTreeMap<String, u32>,
    messages: Vec<MessageRelationshipRow>,
    chats: Vec<Chat1RelationshipRow>,
}

fn fixed_service(value: Option<&str>) -> &'static str {
    match value {
        None => "absent",
        Some("") => "empty",
        Some("iMessage") => "imessage",
        Some("SMS") => "sms",
        Some("RCS") => "rcs",
        Some("iMessageLite") => "imessage_lite",
        Some(_) => "other",
    }
}

fn looks_like_uuid(value: &str) -> bool {
    if value.len() != 36 {
        return false;
    }
    value.bytes().enumerate().all(|(index, byte)| match index {
        8 | 13 | 18 | 23 => byte == b'-',
        _ => byte.is_ascii_hexdigit(),
    })
}

fn value_shape(value: Option<&str>) -> &'static str {
    match value {
        None => "absent",
        Some("") => "empty",
        Some(value) if value.starts_with("iMessage;-;") || value.starts_with("SMS;-;") => {
            "qualified_direct"
        }
        Some(value) if value.starts_with("iMessage;+;") || value.starts_with("SMS;+;") => {
            "qualified_group"
        }
        Some(value) if looks_like_uuid(value) => "uuid",
        Some(value) if value.contains('@') => "email",
        Some(value)
            if value.starts_with('+') && value[1..].bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            "phone"
        }
        Some(value) if value.contains(':') => "uri",
        Some(_) => "opaque",
    }
}

fn pseudonym_ref(
    value: Option<&str>,
    symbols: &mut SymbolTable,
    hasher: &CloudSemanticIdentifierHasher,
) -> PseudonymRef {
    let Some(value) = value else {
        return PseudonymRef {
            present: false,
            symbol: None,
            normalized_symbols: Vec::new(),
            shape: "absent",
        };
    };
    let symbol = (!value.is_empty()).then(|| symbols.intern(value, hasher));
    let mut normalized_symbols = normalized_chat_identity_variants(value)
        .unwrap_or_default()
        .into_iter()
        .filter(|variant| !variant.is_empty())
        .map(|variant| symbols.intern(&variant, hasher))
        .collect::<Vec<_>>();
    normalized_symbols.sort_unstable();
    normalized_symbols.dedup();
    PseudonymRef {
        present: true,
        symbol,
        normalized_symbols,
        shape: value_shape(Some(value)),
    }
}

fn route_kind(value: &str) -> &'static str {
    match message_route_kind(value) {
        Ok(MessageRouteKind::Direct) => "direct",
        Ok(MessageRouteKind::Group) => "group",
        Ok(MessageRouteKind::Bare) => "bare",
        Err(()) => "invalid",
    }
}

fn style_class(value: Option<i64>) -> &'static str {
    match value {
        None => "absent",
        Some(43) => "group",
        Some(45) => "direct",
        Some(_) => "other",
    }
}

fn apple_nanos_to_unix_millis(value: i64) -> Option<i64> {
    value
        .checked_div(1_000_000)?
        .checked_add(APPLE_EPOCH_UNIX_MILLIS)
}

fn apple_seconds_to_unix_millis(value: Option<f64>) -> Option<i64> {
    let value = value?;
    if !value.is_finite() || value < i64::MIN as f64 / 1000.0 || value > i64::MAX as f64 / 1000.0 {
        return None;
    }
    APPLE_EPOCH_UNIX_MILLIS.checked_add((value * 1000.0).floor() as i64)
}

fn apple_millis_to_unix_millis(value: Option<i64>) -> Option<i64> {
    APPLE_EPOCH_UNIX_MILLIS.checked_add(value?)
}

fn verified_message_record(
    storage_directory: &str,
    account_fingerprint: &str,
    generation: u64,
    source: &CloudSyncChat1CorrelationSourceInput,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<Record, &'static str> {
    let scope = CloudNativeProtectionScope::new(
        account_fingerprint.to_owned(),
        CloudNativeStream::Messages,
    )
    .map_err(|_| "message_scope")?;
    let envelope = cloud_sync_unprotect_raw_envelope(
        PathBuf::from(storage_directory),
        &scope,
        CloudNativeStream::Messages,
        generation,
        &source.protected_raw_envelope_reference,
    )
    .map_err(|_| "message_unprotect")?;
    if envelope.generation() != generation
        || envelope.stream() != CloudNativeStream::Messages
        || envelope.kind() != CloudNativeRawEnvelopeKind::EncryptedUpsert
        || envelope.record_type() != Some(CloudMessage::record_type())
        || envelope.raw().is_none()
        || envelope.raw_digest_hex() != source.payload_sha256
        || source
            .payload_length
            .is_some_and(|length| length != envelope.raw_length())
        || envelope.server_modified_at_millis() != source.server_modified_at_millis
    {
        return Err("message_envelope_binding");
    }
    let record_name = envelope
        .record_name()
        .filter(|value| !value.is_empty())
        .ok_or("message_record_name")?;
    if hasher.server_record_id_hash(record_name) != source.record_id_hash {
        return Err("message_record_hash");
    }
    let etag_hash = envelope
        .etag()
        .filter(|value| !value.is_empty())
        .map(|etag| {
            hasher
                .canonical_etag_hash(etag)
                .map(|value| value.value().to_owned())
        })
        .transpose()
        .map_err(|_| "message_etag_hash")?;
    if etag_hash != source.etag_hash {
        return Err("message_etag_binding");
    }
    let raw = envelope.raw().ok_or("message_raw")?;
    preflight_record_wire_budget(raw).map_err(|_| "message_wire_budget")?;
    let record = catch_unwind(AssertUnwindSafe(|| Record::decode(raw)))
        .map_err(|_| "message_record_panic")?
        .map_err(|_| "message_record_decode")?;
    if record_identifier_name(&record) != Some(record_name)
        || record_type_name(&record) != Some(CloudMessage::record_type())
    {
        return Err("message_record_binding");
    }
    Ok(record)
}

fn decode_message(
    record: &Record,
    zone_key: &rustpush::cloudkit::PCSZoneConfig,
) -> Result<CloudMessage, &'static str> {
    let record_key = catch_unwind(AssertUnwindSafe(|| pcs_keys_for_record(record, zone_key)))
        .map_err(|_| "message_record_key_panic")?
        .map_err(|_| "message_record_key")?;
    catch_unwind(AssertUnwindSafe(|| {
        CloudMessage::try_from_record_encrypted(&record.record_field, Some(&record_key))
    }))
    .map_err(|_| "message_typed_panic")?
    .map_err(|_| "message_typed_decode")
}

struct DecodedMessageSource {
    record_name: String,
    message: CloudMessage,
    server_modified_at_millis: Option<i64>,
}

fn message_identity_is_valid(message: &CloudMessage) -> bool {
    identifier(&message.guid).is_some()
        && identifier(&message.chat_id).is_some()
        && [&message.sender, &message.destination_caller_id]
            .iter()
            .all(|value| {
                value.len() <= MAX_CHAT1_SELECTIVE_STRING_BYTES
                    && !value.chars().any(char::is_control)
            })
        && message
            .msg_proto_4
            .as_ref()
            .and_then(|value| value.0.group_id.as_deref())
            .is_none_or(|value| {
                value.len() <= MAX_CHAT1_SELECTIVE_STRING_BYTES && identifier(value).is_some()
            })
}

fn decoded_message_source(
    storage_directory: &str,
    expected_account_fingerprint: &str,
    message_generation: u64,
    source: &CloudSyncChat1CorrelationSourceInput,
    message_zone_key: &rustpush::cloudkit::PCSZoneConfig,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<DecodedMessageSource, &'static str> {
    let record = verified_message_record(
        storage_directory,
        expected_account_fingerprint,
        message_generation,
        source,
        hasher,
    )?;
    let record_name = record_identifier_name(&record)
        .ok_or("probe_message_name")?
        .to_owned();
    let message = decode_message(&record, message_zone_key)?;
    if !message_identity_is_valid(&message) {
        return Err("probe_message_identity");
    }
    Ok(DecodedMessageSource {
        record_name,
        message,
        server_modified_at_millis: source.server_modified_at_millis,
    })
}

fn normalized_identity_overlap(left: &str, right: &str) -> bool {
    let Some(left) = normalized_chat_identity_variants(left) else {
        return false;
    };
    let Some(right) = normalized_chat_identity_variants(right) else {
        return false;
    };
    !left.is_disjoint(&right)
}

fn message_group_id(message: &CloudMessage) -> Option<&str> {
    message
        .msg_proto_4
        .as_ref()
        .and_then(|value| value.0.group_id.as_deref())
        .filter(|value| !value.is_empty())
}

#[derive(Default)]
struct AnchorClusterAccumulator {
    from_me_messages: u32,
    incoming_messages: u32,
    senders: BTreeSet<String>,
    destination_handles: BTreeSet<String>,
    group_ids: BTreeSet<String>,
    service_class_counts: BTreeMap<&'static str, u32>,
    route_kind_counts: BTreeMap<&'static str, u32>,
    first_created_at_millis: Option<i64>,
    last_created_at_millis: Option<i64>,
}

impl AnchorClusterAccumulator {
    fn observe(&mut self, message: &CloudMessage) {
        let from_me = message.flags.contains(MessageFlags::IS_FROM_ME);
        self.from_me_messages = self.from_me_messages.saturating_add(u32::from(from_me));
        self.incoming_messages = self.incoming_messages.saturating_add(u32::from(!from_me));
        if !message.sender.is_empty() {
            self.senders.insert(message.sender.clone());
        }
        if !message.destination_caller_id.is_empty() {
            self.destination_handles
                .insert(message.destination_caller_id.clone());
        }
        if let Some(group_id) = message_group_id(message) {
            self.group_ids.insert(group_id.to_owned());
        }
        let service_count = self
            .service_class_counts
            .entry(fixed_service(Some(&message.service)))
            .or_default();
        *service_count = service_count.saturating_add(1);
        let route_count = self
            .route_kind_counts
            .entry(route_kind(&message.chat_id))
            .or_default();
        *route_count = route_count.saturating_add(1);
        if let Some(created) = apple_nanos_to_unix_millis(message.time) {
            self.first_created_at_millis = Some(
                self.first_created_at_millis
                    .map_or(created, |value| value.min(created)),
            );
            self.last_created_at_millis = Some(
                self.last_created_at_millis
                    .map_or(created, |value| value.max(created)),
            );
        }
    }
}

fn pseudonymize_bounded_set(
    values: &BTreeSet<String>,
    symbols: &mut SymbolTable,
    hasher: &CloudSemanticIdentifierHasher,
) -> (u32, bool, Vec<PseudonymRef>) {
    let count = u32::try_from(values.len()).unwrap_or(u32::MAX);
    let truncated = values.len() > MAX_REPORTED_CLUSTER_IDENTITIES;
    let references = values
        .iter()
        .take(MAX_REPORTED_CLUSTER_IDENTITIES)
        .map(|value| pseudonym_ref(Some(value), symbols, hasher))
        .collect();
    (count, truncated, references)
}

fn anchor_route_evidence(
    target: &CloudMessage,
    anchors: &[CloudMessage],
    symbols: &mut SymbolTable,
    hasher: &CloudSemanticIdentifierHasher,
) -> AnchorRouteEvidence {
    let target_group_id = message_group_id(target);
    let mut exact_route_messages = 0u32;
    let mut normalized_route_messages = 0u32;
    let mut group_correlated_messages = 0u32;
    let mut matched_anchor_messages = 0u32;
    let mut cluster = AnchorClusterAccumulator::default();
    cluster.observe(target);

    for anchor in anchors {
        // The exported anchor set may contain the target source itself. Its
        // evidence is already represented by `target`, so never double count it.
        if anchor.guid == target.guid
            && anchor.chat_id == target.chat_id
            && anchor.time == target.time
        {
            continue;
        }
        let exact_route = anchor.chat_id == target.chat_id;
        let normalized_route = normalized_identity_overlap(&anchor.chat_id, &target.chat_id);
        let group_correlated = target_group_id.is_some_and(|target_group_id| {
            normalized_identity_overlap(target_group_id, &anchor.chat_id)
                || message_group_id(anchor).is_some_and(|anchor_group_id| {
                    normalized_identity_overlap(target_group_id, anchor_group_id)
                })
        });
        exact_route_messages = exact_route_messages.saturating_add(u32::from(exact_route));
        normalized_route_messages =
            normalized_route_messages.saturating_add(u32::from(normalized_route));
        group_correlated_messages =
            group_correlated_messages.saturating_add(u32::from(group_correlated));
        if !normalized_route && !group_correlated {
            continue;
        }
        matched_anchor_messages = matched_anchor_messages.saturating_add(1);
        cluster.observe(anchor);
    }

    let (observed_sender_count, observed_senders_truncated, observed_senders) =
        pseudonymize_bounded_set(&cluster.senders, symbols, hasher);
    let (
        observed_destination_handle_count,
        observed_destination_handles_truncated,
        observed_destination_handles,
    ) = pseudonymize_bounded_set(&cluster.destination_handles, symbols, hasher);
    let (observed_group_id_count, observed_group_ids_truncated, observed_group_ids) =
        pseudonymize_bounded_set(&cluster.group_ids, symbols, hasher);

    AnchorRouteEvidence {
        exact_route_messages,
        normalized_route_messages,
        group_correlated_messages,
        matched_anchor_messages,
        cluster_messages_including_target: matched_anchor_messages.saturating_add(1),
        from_me_messages: cluster.from_me_messages,
        incoming_messages: cluster.incoming_messages,
        observed_sender_count,
        observed_senders_truncated,
        observed_senders,
        observed_destination_handle_count,
        observed_destination_handles_truncated,
        observed_destination_handles,
        observed_group_id_count,
        observed_group_ids_truncated,
        observed_group_ids,
        service_class_counts: cluster.service_class_counts,
        route_kind_counts: cluster.route_kind_counts,
        first_created_at_millis: cluster.first_created_at_millis,
        last_created_at_millis: cluster.last_created_at_millis,
    }
}

fn fixed_chat1_schema_key(field: &rustpush::cloudkit_proto::record::Field) -> Result<String, ()> {
    let name = field
        .identifier
        .as_ref()
        .and_then(|identifier| identifier.name.as_deref())
        .filter(|name| !name.is_empty() && name.len() <= 64 && !name.chars().any(char::is_control))
        .ok_or(())?;
    let public_name = match name {
        "stl" | "filt" | "sqry" | "ste" | "cid" | "gid" | "svc" | "ogid" | "prop" | "ptcpts"
        | "prop001" | "rwm" | "lah" | "guid" | "name" | "proto001" | "gpid" | "gp" => name,
        _ => "other",
    };
    let (wire_type, encrypted) = match field.value.as_ref() {
        None => (-1, "absent"),
        Some(value) => (
            value.r#type.unwrap_or(-1),
            match value.is_encrypted {
                Some(true) => "true",
                Some(false) => "false",
                None => "unset",
            },
        ),
    };
    Ok(format!("{public_name}:{wire_type}:{encrypted}"))
}

#[allow(clippy::too_many_arguments)]
fn chat1_row(
    index: u32,
    record_name: &str,
    record: &Record,
    zone_key: &rustpush::cloudkit::PCSZoneConfig,
    system_fields: Option<&rustpush::cloud_messages::CloudMessageRecordSystemFields>,
    symbols: &mut SymbolTable,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<Chat1RelationshipRow, &'static str> {
    let record_key = catch_unwind(AssertUnwindSafe(|| pcs_keys_for_record(record, zone_key)))
        .map_err(|_| "chat1_record_key_panic")?
        .map_err(|_| "chat1_record_key")?;
    let chat_id = encrypted_string_field(record, &record_key, "cid").map_err(|_| "chat1_cid")?;
    let group_id = encrypted_string_field(record, &record_key, "gid").map_err(|_| "chat1_gid")?;
    let original_group_id =
        encrypted_string_field(record, &record_key, "ogid").map_err(|_| "chat1_ogid")?;
    let guid = encrypted_string_field(record, &record_key, "guid").map_err(|_| "chat1_guid")?;
    let last_addressed_handle =
        encrypted_last_addressed_handle(record, &record_key).map_err(|_| "chat1_lah")?;
    let service = encrypted_string_field(record, &record_key, "svc").map_err(|_| "chat1_svc")?;
    let style = encrypted_i64_field(record, &record_key, "stl").map_err(|_| "chat1_stl")?;
    let last_read = encrypted_i64_field(record, &record_key, "rwm").map_err(|_| "chat1_rwm")?;
    let participants =
        encrypted_participant_uris(record, &record_key).map_err(|_| "chat1_ptcpts")?;
    let properties = encrypted_chat_properties(record, &record_key).map_err(|_| "chat1_prop")?;

    Ok(Chat1RelationshipRow {
        index,
        record: pseudonym_ref(Some(record_name), symbols, hasher),
        chat_id: pseudonym_ref(chat_id.as_deref(), symbols, hasher),
        group_id: pseudonym_ref(group_id.as_deref(), symbols, hasher),
        original_group_id: pseudonym_ref(original_group_id.as_deref(), symbols, hasher),
        guid: pseudonym_ref(guid.as_deref(), symbols, hasher),
        last_addressed_handle: pseudonym_ref(last_addressed_handle.as_deref(), symbols, hasher),
        participants: participants
            .iter()
            .map(|value| pseudonym_ref(Some(value), symbols, hasher))
            .collect(),
        legacy_identifiers: properties
            .legacy_identifiers
            .iter()
            .map(|value| pseudonym_ref(Some(value), symbols, hasher))
            .collect(),
        last_seen_message_guid: pseudonym_ref(
            properties.last_seen_message_guid.as_deref(),
            symbols,
            hasher,
        ),
        service_class: fixed_service(service.as_deref()),
        style,
        style_class: style_class(style),
        last_read_at_millis: last_read.and_then(apple_nanos_to_unix_millis),
        server_created_at_millis: apple_seconds_to_unix_millis(
            system_fields.and_then(|fields| fields.created_at),
        ),
        server_modified_at_millis: apple_seconds_to_unix_millis(
            system_fields.and_then(|fields| fields.modified_at),
        ),
    })
}

pub(super) async fn collect(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: &str,
    expected_account_fingerprint: &str,
    expected_protected_store_identity: &str,
    message_generation: u64,
    message_sources: &[CloudSyncChat1CorrelationSourceInput],
    anchor_message_sources: &[CloudSyncChat1CorrelationSourceInput],
) -> Result<serde_json::Value, &'static str> {
    if !requested().map_err(|_| "probe_enable")?
        || !is_cloud_sync_windows_dev_profile(storage_directory)
        || message_generation == 0
        || message_sources.len() != MAX_MESSAGE_SOURCES
        || !(MAX_MESSAGE_SOURCES..=MAX_ANCHOR_MESSAGE_SOURCES)
            .contains(&anchor_message_sources.len())
        || !valid_sources(message_sources, MAX_MESSAGE_SOURCES)
        || !valid_sources(anchor_message_sources, MAX_ANCHOR_MESSAGE_SOURCES)
    {
        return Err("probe_request");
    }
    let permit = acquire_cloudkit_read_authentication(native_writer_pause_token)
        .map_err(|_| "probe_read_scope")?;
    let before =
        cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.to_owned())
            .await
            .map_err(|_| "probe_auth_before")?;
    if !cloud_sync_auth_identity_remains_exact(
        &before,
        &before,
        expected_account_fingerprint,
        expected_protected_store_identity,
    ) {
        return Err("probe_auth_binding");
    }
    let hasher = cloud_sync_protector::semantic_identifier_hasher(storage_directory.to_owned())
        .map_err(|_| "probe_hasher")?;
    let container = cloud_messages_client
        .get_cached_container_for_read_authentication(&permit)
        .await
        .map_err(|_| "probe_container")?;
    let message_zone = container.private_zone("messageManateeZone".to_owned());
    let message_zone_key = container
        .get_zone_encryption_config_lookup_only(
            &message_zone,
            &cloud_messages_client.keychain,
            &MESSAGES_SERVICE,
        )
        .await
        .map_err(|_| "probe_message_zone_key")?;
    let chat1_zone = container.private_zone("chat1ManateeZone".to_owned());
    let chat1_zone_key = container
        .get_zone_encryption_config_lookup_only(
            &chat1_zone,
            &cloud_messages_client.keychain,
            &MESSAGES_SERVICE,
        )
        .await
        .map_err(|_| "probe_chat1_zone_key")?;

    let target_messages = message_sources
        .iter()
        .map(|source| {
            decoded_message_source(
                storage_directory,
                expected_account_fingerprint,
                message_generation,
                source,
                &message_zone_key,
                &hasher,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut decoded_anchor_messages = Vec::with_capacity(anchor_message_sources.len());
    let mut skipped_anchor_sources = 0u32;
    for source in anchor_message_sources {
        match decoded_message_source(
            storage_directory,
            expected_account_fingerprint,
            message_generation,
            source,
            &message_zone_key,
            &hasher,
        ) {
            Ok(decoded) => decoded_anchor_messages.push(decoded.message),
            Err(_) => skipped_anchor_sources = skipped_anchor_sources.saturating_add(1),
        }
    }

    let mut symbols = SymbolTable::default();
    let mut messages = Vec::with_capacity(target_messages.len());
    for (index, decoded) in target_messages.iter().enumerate() {
        let message = &decoded.message;
        let proto = &message.msg_proto.0;
        let msgproto_group_id = message_group_id(message);
        let anchor_route_evidence =
            anchor_route_evidence(message, &decoded_anchor_messages, &mut symbols, &hasher);
        messages.push(MessageRelationshipRow {
            index: u32::try_from(index).map_err(|_| "probe_message_index")?,
            record: pseudonym_ref(Some(&decoded.record_name), &mut symbols, &hasher),
            chat_id: pseudonym_ref(Some(&message.chat_id), &mut symbols, &hasher),
            sender: pseudonym_ref(Some(&message.sender), &mut symbols, &hasher),
            destination_caller_id: pseudonym_ref(
                Some(&message.destination_caller_id),
                &mut symbols,
                &hasher,
            ),
            msgproto_group_id: pseudonym_ref(msgproto_group_id, &mut symbols, &hasher),
            guid: pseudonym_ref(Some(&message.guid), &mut symbols, &hasher),
            route_kind: route_kind(&message.chat_id),
            service_class: fixed_service(Some(&message.service)),
            from_me: message.flags.contains(MessageFlags::IS_FROM_ME),
            outer_type: message.r#type,
            error: message.error,
            created_at_millis: apple_nanos_to_unix_millis(message.time),
            server_modified_at_millis: apple_millis_to_unix_millis(
                decoded.server_modified_at_millis,
            ),
            text_present: proto.text.as_deref().is_some_and(|value| !value.is_empty()),
            attributed_body_present: proto
                .attributed_body
                .as_ref()
                .is_some_and(|value| !value.is_empty()),
            extension_payload_present: proto
                .payload_data
                .as_ref()
                .is_some_and(|value| !value.is_empty()),
            anchor_route_evidence,
        });
    }

    let mut pages_scanned = 0u32;
    let mut changes_scanned = 0u32;
    let mut tombstones = 0u32;
    let mut other_records = 0u32;
    let mut terminal_reached = false;
    let mut continuation_token = None;
    let mut chats = Vec::new();
    let mut field_shape_counts = BTreeMap::<String, u32>::new();
    for page_index in 0..MAX_CHAT1_SCAN_PAGES {
        let page = cloud_messages_client
            .sync_chat1_discovery_page_for_read_authentication(
                &permit,
                continuation_token.take(),
                Some(MAX_CHAT1_CHANGES_PER_PAGE),
            )
            .await
            .map_err(|_| "probe_chat1_fetch")?;
        if page.changes.len() > MAX_CHAT1_CHANGES_PER_PAGE as usize {
            return Err("probe_chat1_page_cap");
        }
        let complete = page.is_complete();
        let next_token = page.next_token;
        pages_scanned = pages_scanned.checked_add(1).ok_or("probe_page_overflow")?;
        changes_scanned = changes_scanned
            .checked_add(u32::try_from(page.changes.len()).map_err(|_| "probe_change_count")?)
            .ok_or("probe_change_overflow")?;
        for change in page.changes {
            match change.kind {
                CloudMessageRecordKind::Tombstone => {
                    tombstones = tombstones
                        .checked_add(1)
                        .ok_or("probe_tombstone_overflow")?;
                }
                CloudMessageRecordKind::UnsupportedRecordType => {
                    if change.record_type.as_deref() != Some(CloudChat::record_type()) {
                        other_records =
                            other_records.checked_add(1).ok_or("probe_other_overflow")?;
                        continue;
                    }
                    let record_name = change
                        .record_name
                        .as_deref()
                        .filter(|value| !value.is_empty())
                        .ok_or("probe_chat1_name")?;
                    let raw = change
                        .encrypted_record
                        .as_deref()
                        .ok_or("probe_chat1_raw")?;
                    preflight_record_wire_budget(raw).map_err(|_| "probe_chat1_wire_budget")?;
                    let record = catch_unwind(AssertUnwindSafe(|| Record::decode(raw)))
                        .map_err(|_| "probe_chat1_record_panic")?
                        .map_err(|_| "probe_chat1_record_decode")?;
                    if record_identifier_name(&record) != Some(record_name)
                        || record_type_name(&record) != Some(CloudChat::record_type())
                    {
                        return Err("probe_chat1_record_binding");
                    }
                    for field in &record.record_field {
                        let key = fixed_chat1_schema_key(field)
                            .map_err(|_| "probe_chat1_field_schema")?;
                        let count = field_shape_counts.entry(key).or_default();
                        *count = count.checked_add(1).ok_or("probe_field_count_overflow")?;
                    }
                    let index = u32::try_from(chats.len()).map_err(|_| "probe_chat_index")?;
                    chats.push(chat1_row(
                        index,
                        record_name,
                        &record,
                        &chat1_zone_key,
                        change.system_fields.as_ref(),
                        &mut symbols,
                        &hasher,
                    )?);
                }
                CloudMessageRecordKind::EncryptedUpsert
                | CloudMessageRecordKind::MalformedMetadata => {
                    return Err("probe_chat1_record_kind");
                }
            }
        }
        if complete {
            terminal_reached = true;
            break;
        }
        continuation_token = next_token;
        if continuation_token.is_none() {
            return Err("probe_chat1_token");
        }
        if page_index + 1 == MAX_CHAT1_SCAN_PAGES {
            return Err("probe_chat1_budget");
        }
    }
    if !terminal_reached || chats.len() > MAX_CHAT1_SCAN_PAGES * MAX_CHAT1_CHANGES_PER_PAGE as usize
    {
        return Err("probe_chat1_terminal");
    }

    let after =
        cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.to_owned())
            .await
            .map_err(|_| "probe_auth_after")?;
    if !cloud_sync_auth_identity_remains_exact(
        &before,
        &after,
        expected_account_fingerprint,
        expected_protected_store_identity,
    ) {
        return Err("probe_account_changed");
    }

    let report = RelationshipReport {
        schema: REPORT_SCHEMA,
        content_exposed: false,
        raw_identifiers_exposed: false,
        anchor_sources: u32::try_from(anchor_message_sources.len())
            .map_err(|_| "probe_anchor_count")?,
        decoded_anchor_sources: u32::try_from(decoded_anchor_messages.len())
            .map_err(|_| "probe_decoded_anchor_count")?,
        skipped_anchor_sources,
        pages_scanned,
        changes_scanned,
        chat_records: u32::try_from(chats.len()).map_err(|_| "probe_chat_count")?,
        tombstones,
        other_records,
        terminal_reached,
        symbol_count: symbols.len(),
        chat1_field_shape_counts: field_shape_counts,
        messages,
        chats,
    };
    let encoded = serde_json::to_string(&report).map_err(|_| "probe_report_encode")?;
    if encoded.len() > MAX_REPORT_BYTES {
        return Err("probe_report_cap");
    }
    serde_json::from_str(&encoded).map_err(|_| "probe_report_roundtrip")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn relationship_message(
        guid: &str,
        route: &str,
        sender: &str,
        destination_caller_id: &str,
        from_me: bool,
        apple_time_nanos: i64,
    ) -> CloudMessage {
        CloudMessage {
            chat_id: route.to_owned(),
            sender: sender.to_owned(),
            destination_caller_id: destination_caller_id.to_owned(),
            time: apple_time_nanos,
            flags: if from_me {
                MessageFlags::IS_FROM_ME
            } else {
                MessageFlags::default()
            },
            guid: guid.to_owned(),
            service: "iMessage".to_owned(),
            ..Default::default()
        }
    }

    #[test]
    fn pseudonym_reference_never_serializes_source_value() {
        let hasher = CloudSemanticIdentifierHasher::new(b"relationship-probe-fixture").unwrap();
        let mut symbols = SymbolTable::default();
        let source = "iMessage;-;private-person@example.invalid";
        let encoded =
            serde_json::to_string(&pseudonym_ref(Some(source), &mut symbols, &hasher)).unwrap();
        assert!(!encoded.contains(source));
        assert!(!encoded.contains("private-person"));
        assert!(symbols.len() >= 1);
    }

    #[test]
    fn value_shapes_are_fixed_classes_only() {
        assert_eq!(value_shape(None), "absent");
        assert_eq!(value_shape(Some("")), "empty");
        assert_eq!(
            value_shape(Some("iMessage;-;+15555550101")),
            "qualified_direct"
        );
        assert_eq!(value_shape(Some("iMessage;+;group")), "qualified_group");
        assert_eq!(
            value_shape(Some("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")),
            "uuid"
        );
        assert_eq!(value_shape(Some("person@example.invalid")), "email");
        assert_eq!(value_shape(Some("+15555550101")), "phone");
        assert_eq!(value_shape(Some("tel:+15555550101")), "uri");
        assert_eq!(value_shape(Some("opaque")), "opaque");
    }

    #[test]
    fn apple_epoch_conversions_preserve_containing_millisecond() {
        assert_eq!(apple_nanos_to_unix_millis(0), Some(APPLE_EPOCH_UNIX_MILLIS));
        assert_eq!(
            apple_nanos_to_unix_millis(1_999_999),
            Some(APPLE_EPOCH_UNIX_MILLIS + 1)
        );
        assert_eq!(
            apple_seconds_to_unix_millis(Some(1.999_999)),
            Some(APPLE_EPOCH_UNIX_MILLIS + 1_999)
        );
        assert_eq!(
            apple_millis_to_unix_millis(Some(2_345)),
            Some(APPLE_EPOCH_UNIX_MILLIS + 2_345)
        );
        assert_eq!(apple_seconds_to_unix_millis(Some(f64::NAN)), None);
        assert_eq!(apple_seconds_to_unix_millis(None), None);
    }

    #[test]
    fn anchor_cluster_uses_routes_without_serializing_source_values() {
        let target = relationship_message(
            "target-guid",
            "iMessage;-;+15555550101",
            "local@example.invalid",
            "local@example.invalid",
            true,
            3_000_000,
        );
        let anchors = vec![
            target.clone(),
            relationship_message(
                "exact-guid",
                "iMessage;-;+15555550101",
                "first@example.invalid",
                "local@example.invalid",
                false,
                1_000_000,
            ),
            relationship_message(
                "normalized-guid",
                "+15555550101",
                "second@example.invalid",
                "local@example.invalid",
                false,
                2_000_000,
            ),
            relationship_message(
                "unrelated-guid",
                "iMessage;-;+15555550999",
                "unrelated@example.invalid",
                "local@example.invalid",
                false,
                4_000_000,
            ),
        ];
        let hasher = CloudSemanticIdentifierHasher::new(b"anchor-cluster-fixture").unwrap();
        let mut symbols = SymbolTable::default();
        let evidence = anchor_route_evidence(&target, &anchors, &mut symbols, &hasher);

        assert_eq!(evidence.exact_route_messages, 1);
        assert_eq!(evidence.normalized_route_messages, 2);
        assert_eq!(evidence.group_correlated_messages, 0);
        assert_eq!(evidence.matched_anchor_messages, 2);
        assert_eq!(evidence.cluster_messages_including_target, 3);
        assert_eq!(evidence.from_me_messages, 1);
        assert_eq!(evidence.incoming_messages, 2);
        assert_eq!(evidence.observed_sender_count, 3);
        assert!(!evidence.observed_senders_truncated);
        assert_eq!(evidence.observed_destination_handle_count, 1);
        assert_eq!(
            evidence.first_created_at_millis,
            Some(APPLE_EPOCH_UNIX_MILLIS + 1)
        );
        assert_eq!(
            evidence.last_created_at_millis,
            Some(APPLE_EPOCH_UNIX_MILLIS + 3)
        );

        let encoded = serde_json::to_string(&evidence).unwrap();
        for private_value in [
            "+15555550101",
            "local@example.invalid",
            "first@example.invalid",
            "second@example.invalid",
            "unrelated@example.invalid",
        ] {
            assert!(!encoded.contains(private_value));
        }
    }

    #[test]
    fn anchor_cluster_caps_reported_identity_references() {
        let target = relationship_message(
            "target-guid",
            "iMessage;-;+15555550101",
            "local@example.invalid",
            "local@example.invalid",
            true,
            0,
        );
        let anchors = (0..=MAX_REPORTED_CLUSTER_IDENTITIES)
            .map(|index| {
                relationship_message(
                    &format!("anchor-guid-{index}"),
                    "iMessage;-;+15555550101",
                    &format!("person-{index}@example.invalid"),
                    "local@example.invalid",
                    false,
                    i64::try_from(index).unwrap() * 1_000_000,
                )
            })
            .collect::<Vec<_>>();
        let hasher = CloudSemanticIdentifierHasher::new(b"anchor-cap-fixture").unwrap();
        let mut symbols = SymbolTable::default();
        let evidence = anchor_route_evidence(&target, &anchors, &mut symbols, &hasher);

        assert_eq!(
            evidence.observed_sender_count,
            u32::try_from(MAX_REPORTED_CLUSTER_IDENTITIES + 2).unwrap()
        );
        assert!(evidence.observed_senders_truncated);
        assert_eq!(
            evidence.observed_senders.len(),
            MAX_REPORTED_CLUSTER_IDENTITIES
        );
    }
}
