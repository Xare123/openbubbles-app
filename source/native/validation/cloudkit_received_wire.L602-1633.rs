fn parse_wire_schema(
    frame: &[u8],
    root: Schema,
    remaining: &mut usize,
    diagnostic: &mut ReceivedWireDiagnostic,
) -> Result<Option<Vec<u8>>, PushError> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err(PushError::BadMsg);
    }
    let mut levels = Vec::with_capacity(MAX_DEPTH);
    levels.push(Level::new(root, frame));
    let mut record = None;
    let mut result_code = 0;
    let mut has_error = false;
    let mut server_code = None;
    while let Some(level) = levels.last_mut() {
        diagnostic.schema = level.schema;
        diagnostic.field = None;
        if level.pos == level.bytes.len() {
            diagnostic.reason = WireFailureKind::InvalidShape;
            level.finish()?;
            // A present key (even an empty entry) or tag (even empty text) is
            // protection-management metadata. Cached decryption is not proof
            // that ignoring it is safe. Traverse it first, then hold before
            // the strict fetch can return Found or authorize source staging.
            if level.schema == Schema::ProtectionKeysToRemove && level.seen != 0 {
                diagnostic.reason = WireFailureKind::UnsupportedProtectionMetadata;
                return Err(PushError::BadMsg);
            }
            levels.pop();
            continue;
        }
        diagnostic.reason = WireFailureKind::FieldLimit;
        *remaining = remaining.checked_sub(1).ok_or(PushError::BadMsg)?;
        diagnostic.reason = WireFailureKind::InvalidKey;
        let key = varint(level.bytes, &mut level.pos)?;
        let tag = key >> 3;
        if tag == 0 || tag > 0x1fff_ffff {
            return Err(PushError::BadMsg);
        }
        diagnostic.field = Some(tag as u32);
        diagnostic.reason = WireFailureKind::UnknownField;
        let (kind, repeated) = match rule(level.schema, tag) {
            Ok(rule) => rule,
            Err(error) => {
                if level.schema == Schema::Record {
                    diagnostic.unknown_record = Some(summarize_unknown_record_fields(level.bytes));
                }
                return Err(error); // Diagnostics never relax the original refusal.
            }
        };
        diagnostic.reason = WireFailureKind::WrongWireType;
        if key & 7 != kind.wire() {
            return Err(PushError::BadMsg);
        }
        // Every admitted tag fits 1..=34 except ResponseOperation.211.
        // Its bit63 sentinel is local to the Response level. Record33/34
        // must not alias Record1/2 or the nested protection-removal fields.
        let bit = 1u64 << if tag == 211 { 63 } else { tag as u32 };
        diagnostic.reason = WireFailureKind::DuplicateSingular;
        if !repeated && level.seen & bit != 0 {
            return Err(PushError::BadMsg);
        }
        level.seen |= bit;
        if kind.wire() == 0 {
            diagnostic.reason = WireFailureKind::InvalidScalar;
            let value = varint(level.bytes, &mut level.pos)?;
            if matches!(kind, Kind::U32) && value > u64::from(u32::MAX)
                || matches!(kind, Kind::Bool) && value > 1
                || matches!(kind, Kind::I32)
                    && value > i32::MAX as u64
                    && value < i32::MIN as i64 as u64
            {
                return Err(PushError::BadMsg);
            }
            match (level.schema, tag) {
                (Schema::RecordTimestamps, 1) if value > 2 => {
                    // Apple retains unknown numeric domains. Our narrower read
                    // policy cannot give an unknown domain authority or default
                    // it to record-domain. Absence remains distinct from zero.
                    diagnostic.reason = WireFailureKind::UnsupportedTimestampMetadata;
                    return Err(PushError::BadMsg);
                }
                (Schema::ProtectionRemovalKey, 2) if !(1..=3).contains(&value) => {
                    return Err(PushError::BadMsg);
                }
                (Schema::Operation, 2) if value != 211 => {
                    diagnostic.reason = WireFailureKind::OperationKind;
                    return Err(PushError::BadMsg);
                }
                (Schema::Result, 1) => {
                    if !(1..=4).contains(&value) {
                        diagnostic.reason = WireFailureKind::ResultCode;
                        return Err(PushError::BadMsg);
                    }
                    result_code = value;
                }
                (Schema::ServerError, 1) => {
                    if !matches!(value, 1..=4 | 6..=8) {
                        diagnostic.reason = WireFailureKind::ErrorCode;
                        return Err(PushError::BadMsg);
                    }
                    server_code = Some(value);
                }
                (Schema::ClientError, 1) if !matches!(value, 1..=43 | 46..=62) => {
                    diagnostic.reason = WireFailureKind::ErrorCode;
                    return Err(PushError::BadMsg)
                }
                _ => {}
            }
        } else if kind.wire() == 1 {
            diagnostic.reason = WireFailureKind::TruncatedFixed64;
            take(level.bytes, &mut level.pos, 8)?;
        } else {
            diagnostic.reason = WireFailureKind::InvalidLength;
            let len = usize::try_from(varint(level.bytes, &mut level.pos)?)
                .map_err(|_| PushError::BadMsg)?;
            let bytes = take(level.bytes, &mut level.pos, len)?;
            if matches!(kind, Kind::Text) {
                diagnostic.reason = WireFailureKind::InvalidText;
                std::str::from_utf8(bytes).map_err(|_| PushError::BadMsg)?;
                if level.schema == Schema::Operation
                    && tag == 1
                    && (bytes.is_empty() || bytes.len() > 128)
                {
                    diagnostic.reason = WireFailureKind::InvalidOperationIdentity;
                    return Err(PushError::BadMsg);
                }
            }
            if level.schema == Schema::Result && tag == 2 {
                has_error = true;
            }
            if level.schema == Schema::Retrieve && tag == 1 {
                record = Some(bytes);
            }
            if let Kind::Message(schema) = kind {
                if levels.len() == MAX_DEPTH {
                    diagnostic.reason = WireFailureKind::DepthLimit;
                    return Err(PushError::BadMsg);
                }
                levels.push(Level::new(schema, bytes));
            }
        }
    }
    // Success must carry a record and no error; failed/partial/indeterminate
    // frames must not also carry a record. NOT_FOUND is only meaningful with
    // explicit FAILURE, not an ambiguous PARTIAL/INDETERMINATE result.
    if root == Schema::Response && ((result_code == 1) != record.is_some()
        || (result_code == 1 && has_error)
        || (server_code == Some(3) && result_code != 3))
    {
        *diagnostic = ReceivedWireDiagnostic {
            schema: Schema::Response, field: None, reason: WireFailureKind::ResultConflict,
            unknown_record: None,
        };
        return Err(PushError::BadMsg);
    }
    Ok(record.map(<[u8]>::to_vec))
}

#[cfg(test)]
mod tests {
    use super::*;
    use cloudkit_proto::{Record, ResponseOperation};
    use prost::Message;

    fn vi(mut value: u64) -> Vec<u8> {
        let mut out = Vec::new();
        while value >= 128 {
            out.push((value as u8 & 127) | 128);
            value >>= 7;
        }
        out.push(value as u8);
        out
    }
    fn number(tag: u64, value: u64) -> Vec<u8> {
        [vi(tag << 3), vi(value)].concat()
    }
    fn data(tag: u64, value: &[u8]) -> Vec<u8> {
        [vi((tag << 3) | 2), vi(value.len() as u64), value.to_vec()].concat()
    }
    fn fixed(tag: u64, value: f64) -> Vec<u8> {
        [vi((tag << 3) | 1), value.to_le_bytes().to_vec()].concat()
    }
    fn operation() -> Vec<u8> {
        [
            data(1, b"11111111-2222-4333-8444-555555555555"),
            number(2, 211),
        ]
        .concat()
    }
    fn frame(op: &[u8], result: &[u8], retrieve: Option<&[u8]>) -> Vec<u8> {
        let mut out = [data(2, op), data(3, result)].concat();
        if let Some(retrieve) = retrieve {
            out.extend(data(211, retrieve));
        }
        out
    }
    fn success(record: &[u8]) -> Vec<u8> {
        frame(&operation(), &number(1, 1), Some(&data(1, record)))
    }
    fn field(name: &str, value: &[u8]) -> Vec<u8> {
        [data(1, &data(1, name.as_bytes())), data(2, value)].concat()
    }
    fn record_with_value(value: &[u8]) -> Vec<u8> {
        data(7, &field("msgType", value))
    }
    fn failure(error: &[u8]) -> Vec<u8> {
        [number(1, 3), data(2, error)].concat()
    }
    fn not_found() -> Vec<u8> {
        failure(&data(2, &number(1, 3)))
    }
    fn rejected(frame: &[u8]) {
        assert!(matches!(
            received_record_wire(frame),
            Err(PushError::BadMsg)
        ));
    }

    #[test]
    fn record34_timestamps_preserve_original_record_and_typed_content() {
        let id = [data(1, b"synthetic-record34"), number(2, 1)].concat();
        let zone = [data(1, &id), data(2, &id), number(3, 1)].concat();
        let version = [number(1, (-1i64) as u64), data(2, &[0xff, 0]),
            number(3, (-1i32) as i64 as u64)].concat();
        let timestamps = [number(1, 0), data(2, &[]), data(3, &version)].concat();
        let base = [data(1, b"synthetic-etag"),
            data(2, &[data(1, &id), data(2, &zone)].concat()),
            data(3, &data(1, b"MessageEncryptedV3")), data(24, &[1, 2, 3, 4])].concat();
        // Keep legal reordering so typed support cannot
        // turn this into a reencoding-based original-wire retention test.
        let record = [data(34, &timestamps), base.clone()].concat();
        assert_eq!(data(34, &[]), [0x92, 0x02, 0x00]);
        assert_eq!(received_record_wire(&success(&record)).unwrap(), Some(record.clone()));
        let mut decoded = Record::decode(record.as_slice()).unwrap();
        assert_ne!(decoded.encode_to_vec(), record);
        let metadata = decoded.timestamps.take().unwrap();
        assert_eq!(metadata.domain, Some(0));
        assert_eq!(metadata.creation, Some(Default::default()));
        let modification = metadata.modification.unwrap();
        assert_eq!(modification.timestamp, Some(-1));
        assert_eq!(modification.versionstamp, Some(vec![0xff, 0]));
        assert_eq!(modification.incarnation, Some(-1));
        assert_eq!(decoded, Record::decode(base.as_slice()).unwrap());
    }

    #[test]
    fn record34_presence_domains_and_signed_version_boundaries_remain_exact() {
        let versions = [Vec::new(), number(1, 0), number(1, i64::MIN as u64),
            number(1, i64::MAX as u64), number(1, (-1i64) as u64),
            data(2, &[]), data(2, &[0xff, 0, 0x80]), number(3, 0),
            number(3, i32::MIN as i64 as u64), number(3, i32::MAX as u64),
            number(3, (-1i32) as i64 as u64),
            [number(3, 7), data(2, &[0xff]), number(1, 42)].concat()];
        let mut distinct_presence = Vec::new();
        for domain in [None, Some(0), Some(1), Some(2)] {
            let prefix = domain.map(|value| number(1, value)).unwrap_or_default();
            let domain_only = data(34, &prefix);
            assert_eq!(received_record_wire(&success(&domain_only)).unwrap(), Some(domain_only.clone()));
            distinct_presence.push(domain_only);
            for version in &versions {
                for timestamps in [
                    [prefix.clone(), data(2, version)].concat(),
                    [data(3, version), prefix.clone()].concat(),
                    [data(3, version), prefix.clone(), data(2, version)].concat(),
                ] {
                    let record = data(34, &timestamps);
                    assert_eq!(received_record_wire(&success(&record)).unwrap(), Some(record));
                }
            }
        }
        distinct_presence.extend([data(34, &data(2, &[])),
            data(34, &data(3, &[])), data(34, &data(2, &number(1, 0))),
            data(34, &data(2, &data(2, &[]))), data(34, &data(2, &number(3, 0)))]);
        for (index, raw) in distinct_presence.iter().enumerate() {
            for other in &distinct_presence[index + 1..] { assert_ne!(raw, other); }
        }
        // Nonminimal keys/values remain original, including a present zero.
        let nonminimal = data(34, &[0x88, 0, 0x80, 0]);
        assert_eq!(received_record_wire(&success(&nonminimal)).unwrap(), Some(nonminimal));
    }

    #[test]
    fn record34_unknown_domains_fields_and_numeric_narrowing_stay_closed() {
        for domain in [3, i32::MAX as u64, (-1i32) as i64 as u64,
            i32::MIN as i64 as u64] {
            let wire = success(&data(34, &number(1, domain)));
            rejected(&wire);
            let diagnostic = received_record_wire_diagnostic(&wire).unwrap_err();
            assert_eq!((diagnostic.schema, diagnostic.field, diagnostic.reason),
                (Schema::RecordTimestamps, Some(1), WireFailureKind::UnsupportedTimestampMetadata));
            assert!(diagnostic.unknown_record.is_none());
        }
        for narrowed in [0x8000_0000, u32::MAX as u64, 0x1_0000_0000,
            (i32::MIN as i64 as u64) - 1] {
            for timestamps in [number(1, narrowed), data(2, &number(3, narrowed))] {
                let diagnostic = received_record_wire_diagnostic(&success(&data(34, &timestamps))).unwrap_err();
                assert_eq!(diagnostic.reason, WireFailureKind::InvalidScalar);
            }
        }
        for timestamps in [number(4, 0), data(4, &[]), data(2, &number(4, 0)),
            data(3, &data(4, b"synthetic-private-value"))] {
            let wire = success(&data(34, &timestamps));
            let diagnostic = received_record_wire_diagnostic(&wire).unwrap_err();
            assert_eq!(diagnostic.reason, WireFailureKind::UnknownField);
            assert!(diagnostic.unknown_record.is_none());
            assert!(!diagnostic.to_string().contains("synthetic-private-value"));
            rejected(&wire);
        }
    }

    #[test]
    fn record34_wrong_wires_truncation_and_duplicates_stay_closed() {
        for record in [number(34, 0), fixed(34, 0.0),
            [vi(34 << 3 | 5), vec![0; 4]].concat(),
            [vi(34 << 3 | 2), vi(u64::MAX)].concat(),
            [vi(34 << 3 | 2), vi(2), vec![8]].concat(),
            [vi(34 << 3 | 2), vec![0x80]].concat(),
            [data(34, &[]), data(34, &[])].concat()] {
            rejected(&success(&record));
        }
        for timestamps in [data(1, &[]), number(2, 0), number(3, 0),
            [number(1, 0), number(1, 0)].concat(),
            [data(2, &[]), data(2, &[])].concat(),
            [data(3, &[]), data(3, &[])].concat(),
            vec![8, 0x80], vec![18, 0x80], vec![18, 2, 8]] {
            rejected(&success(&data(34, &timestamps)));
        }
        for version in [data(1, &[]), number(2, 0), data(3, &[]),
            [number(1, 0), number(1, 0)].concat(),
            [data(2, &[]), data(2, &[])].concat(),
            [number(3, 0), number(3, 0)].concat(),
            [vec![8], vec![0xff; 9], vec![2]].concat(),
            vec![8, 0x80], vec![18, 0x80], vec![18, 2, 0], vec![24, 0x80]] {
            for member in [2, 3] { rejected(&success(&data(34, &data(member, &version)))); }
        }
    }

    #[test]
    fn record34_high_tag_tracking_and_existing_protection_holds_do_not_alias() {
        let metadata = data(34, &[number(1, 2), data(2, &[]), data(3, &[])].concat());
        let record = [data(1, b"synthetic-etag"), data(2, &[]), data(31, &[]), metadata.clone()].concat();
        assert_eq!(received_record_wire(&success(&record)).unwrap(), Some(record.clone()));
        for member in [data(1, b"duplicate"), data(2, &[]), data(31, &[]), metadata] {
            let diagnostic = received_record_wire_diagnostic(&success(&[record.clone(), member].concat())).unwrap_err();
            assert_eq!(diagnostic.reason, WireFailureKind::DuplicateSingular);
        }
        // Field33 is deliberately a separate, unchanged policy. Even its empty
        // form must refuse before Found, regardless of supported34's position.
        for chain in [data(33, &[]), data(33, &data(1, &[])), data(33, &data(2, b""))] {
            for raw in [[record.clone(), chain.clone()].concat(), [chain, record.clone()].concat()] {
                let diagnostic = received_record_wire_diagnostic(&success(&raw)).unwrap_err();
                assert_eq!((diagnostic.schema, diagnostic.field, diagnostic.reason),
                    (Schema::Record, Some(33), WireFailureKind::UnknownField));
            }
        }
        for present in [data(1, &[]), data(2, b"")] {
            let raw = [data(34, &[]), data(31, &present)].concat();
            assert_eq!(received_record_wire_diagnostic(&success(&raw)).unwrap_err().reason,
                WireFailureKind::UnsupportedProtectionMetadata);
        }
        let one = success(&record);
        rejected(&[one, data(211, &data(1, &record))].concat());
        rejected(&success(&[record, data(63, &[])].concat()));
    }

    #[test]
    fn record34_nested_fields_consume_the_existing_global_visit_budget() {
        let version = [number(1, 0), data(2, &[]), number(3, 0)].concat();
        let metadata = data(34, &[number(1, 0), data(2, &version)].concat());
        // Seven envelope fields + six Record/Timestamps/Version fields.
        let at_limit = [data(10, b"").repeat(MAX_FIELDS - 13), metadata].concat();
        assert_eq!(received_record_wire(&success(&at_limit)).unwrap(), Some(at_limit.clone()));
        let over = success(&[at_limit, data(10, b"")].concat());
        assert_eq!(received_record_wire_diagnostic(&over).unwrap_err().reason, WireFailureKind::FieldLimit);
        rejected(&over);
    }

    #[test]
    fn record34_narrow_preflight_preserves_opaque_history_without_granting_admission() {
        let record = [number(1000, 1), data(34, &[number(1, 0), data(2, &[])].concat())].concat();
        assert!(validate_record_timestamps_wire(&record).is_ok());
        rejected(&success(&record)); // Narrow validation cannot replace strict admission.
        for raw in [data(33, &[]), data(33, &data(1, &[])), data(31, &data(2, b""))] {
            rejected(&success(&raw));
        }
        for raw in [data(34, &number(1, 3)), data(34, &number(1, 0x1_0000_0000)),
            data(34, &number(4, 1)), data(34, &data(2, &number(4, 1))),
            data(34, &[number(1, 0), number(1, 0)].concat()),
            [data(34, &[]), data(34, &[])].concat(),
            number(34, 0), [vi(34 << 3 | 2), vi(u64::MAX)].concat()] {
            assert!(validate_record_timestamps_wire(&raw).is_err());
        }
        assert!(validate_record_timestamps_wire(&number(1000, 1).repeat(MAX_TIMESTAMP_OUTER_FIELDS)).is_ok());
        assert!(validate_record_timestamps_wire(&number(1000, 1).repeat(MAX_TIMESTAMP_OUTER_FIELDS + 1)).is_err());
        assert!(validate_record_timestamps_wire(&vec![0; MAX_FRAME_BYTES + 1]).is_err());
    }

    #[test]
    fn diagnostics_identify_fixed_schema_rules_without_response_values() {
        let private = b"private-selector-credential-record";
        let unknown = success(&data(63, private));
        let duplicate = success(&[data(1, private), data(1, private)].concat());
        for (raw, expected) in [
            (unknown, (Schema::Record, Some(63), WireFailureKind::UnknownField)),
            (duplicate, (Schema::Record, Some(1), WireFailureKind::DuplicateSingular)),
            (success(&number(1, 1)), (Schema::Record, Some(1), WireFailureKind::WrongWireType)),
        ] {
            let diagnostic = received_record_wire_diagnostic(&raw).unwrap_err();
            assert_eq!((diagnostic.schema, diagnostic.field, diagnostic.reason), expected);
            assert!(!diagnostic.to_string().contains(std::str::from_utf8(private).unwrap()));
            assert!(matches!(received_record_wire(&raw), Err(PushError::BadMsg)));
        }
    }

    #[test]
    fn diagnostics_preserve_success_absence_and_all_existing_rejections() {
        let record = record_with_value(&[number(1, 20), data(2, &[0xff, 0]), number(13, 1)].concat());
        assert_eq!(received_record_wire_diagnostic(&success(&record)).unwrap(), Some(record));
        assert_eq!(received_record_wire_diagnostic(&frame(&operation(), &not_found(), None)).unwrap(), None);
        assert_eq!(received_record_wire_diagnostic(&frame(&operation(), &number(1, 1), None)),
            Err(ReceivedWireDiagnostic {schema: Schema::Response, field: None,
                reason: WireFailureKind::ResultConflict, unknown_record: None}));
    }

    #[test]
    fn exact_schema_path_extracts_original_record_with_system_metadata_and_flags() {
        let id = [data(1, b"synthetic"), number(2, 1)].concat();
        let zone = [data(1, &id), data(2, &id), number(3, 1)].concat();
        let record_id = [data(1, &id), data(2, &zone)].concat();
        let signed = [number(1, 7), number(4, i64::MIN as u64)].concat();
        let text = [number(1, 3), data(7, b"")].concat();
        // Intentionally invalid protobuf, but opaque ciphertext must survive.
        let encrypted = [number(1, 20), data(2, &[0xff, 0, 0x80]), number(13, 1)].concat();
        let date = fixed(1, 123.5);
        let record = [
            data(24, &[1, 2, 3, 4]),
            data(3, &data(1, b"MessageEncryptedV3")),
            data(7, &field("flags", &signed)),
            data(7, &field("sender", &text)),
            data(7, &field("msgProto", &encrypted)),
            data(2, &record_id),
            data(1, b"etag"),
            data(4, &id),
            data(9, &id),
            data(5, &[data(1, &date), data(2, &date)].concat()),
            data(10, b"old-a"),
            data(10, b"old-b"),
            data(11, b"device"),
            data(12, &field("plugin", &text)),
            data(12, &field("plugin2", &text)),
            data(8, &record_id),
            number(15, 1),
            data(13, &[data(1, b"pcs"), data(2, b"tag")].concat()),
            data(22, &[data(1, b"route"), data(2, b"opaque")].concat()),
        ]
        .concat();
        let framed = success(&record);
        assert_eq!(received_record_wire(&framed).unwrap(), Some(record.clone()));
        let decoded = Record::decode(record.as_slice()).unwrap();
        let response = ResponseOperation::decode(framed.as_slice()).unwrap();
        assert_eq!(
            response.record_retrieve_response.unwrap().record.unwrap(),
            decoded
        );
        assert_eq!(
            decoded.record_field[0].value.as_ref().unwrap().signed_value,
            Some(i64::MIN)
        );
        assert_eq!(
            decoded.record_field[1]
                .value
                .as_ref()
                .unwrap()
                .string_value
                .as_deref(),
            Some("")
        );
        assert_eq!(
            decoded.record_field[2]
                .value
                .as_ref()
                .unwrap()
                .bytes_value
                .as_deref(),
            Some(&[0xff, 0, 0x80][..])
        );
    }

    #[test]
    fn duplicate_signed_value_hidden_by_prost_is_rejected() {
        let value = [number(1, 7), number(4, 9), number(4, 1)].concat();
        let record = record_with_value(&value);
        let decoded = Record::decode(record.as_slice()).unwrap();
        assert_eq!(
            decoded.record_field[0].value.as_ref().unwrap().signed_value,
            Some(1)
        );
        rejected(&success(&record));
    }

    #[test]
    fn unknown_value_tag_dropped_by_prost_is_rejected() {
        let clean = record_with_value(&[number(1, 7), number(4, 1)].concat());
        let dirty = record_with_value(&[number(1, 7), number(4, 1), number(99, 1)].concat());
        assert_eq!(
            Record::decode(clean.as_slice()).unwrap(),
            Record::decode(dirty.as_slice()).unwrap()
        );
        rejected(&success(&dirty));
    }

    #[test]
    fn duplicate_value_type_string_bytes_bool_and_date_are_rejected() {
        for value in [
            number(1, 7),
            number(4, 1),
            data(7, b"s"),
            data(2, b"opaque"),
            number(13, 1),
            data(6, &fixed(1, 1.0)),
            fixed(5, 1.0),
        ] {
            rejected(&success(&record_with_value(
                &[value.clone(), value].concat(),
            )));
        }
    }

    #[test]
    fn duplicate_record_retrieve_and_response_singulars_are_rejected() {
        let record = record_with_value(&number(4, 1));
        let retrieve = data(1, &record);
        let good = success(&record);
        for extra in [
            data(211, &retrieve),
            data(2, &operation()),
            data(3, &number(1, 1)),
        ] {
            rejected(&[good.clone(), extra].concat());
        }
        rejected(&frame(
            &operation(),
            &number(1, 1),
            Some(&[retrieve.clone(), retrieve].concat()),
        ));
        for singular in [
            data(1, b"etag"),
            data(2, &[]),
            data(3, &data(1, b"type")),
            data(4, &[]),
            data(5, &[]),
            data(8, &[]),
            data(9, &[]),
            data(11, b"device"),
            data(13, &[]),
            number(15, 0),
            data(22, &[]),
            data(24, b"pcs"),
        ] {
            rejected(&success(&[singular.clone(), singular].concat()));
        }
    }

    #[test]
    fn nested_identity_field_and_metadata_duplicates_and_unknowns_are_rejected() {
        for raw in [
            data(3, &[data(1, b"type"), data(1, b"type")].concat()),
            data(4, &[data(1, b"user"), number(31, 0)].concat()),
            data(2, &data(2, &[number(3, 1), number(3, 1)].concat())),
            data(7, &[data(1, &[]), data(1, &[])].concat()),
            data(7, &[data(2, &[]), data(2, &[])].concat()),
            data(
                7,
                &data(1, &[data(1, b"flags"), data(1, b"flags")].concat()),
            ),
            data(7, &data(1, &number(2, 0))),
            data(5, &data(1, &[fixed(1, 1.0), fixed(1, 2.0)].concat())),
            data(13, &[data(1, b"pcs"), data(1, b"pcs")].concat()),
            number(31, 0),
            data(16, &[]), // shareInfo is deliberately unsupported.
        ] {
            rejected(&success(&raw));
        }
    }

    #[test]
    fn order_nonminimal_varints_and_explicit_empty_are_preserved() {
        // etag key/length and permission value have valid nonminimal varints.
        let record = [0x8a, 0, 0x81, 0, b'e', 0x78, 0x81, 0];
        let framed = [
            data(211, &data(1, &record)),
            data(3, &number(1, 1)),
            data(2, &operation()),
            number(1, 0),
        ]
        .concat();
        assert_eq!(
            received_record_wire(&framed).unwrap(),
            Some(record.to_vec())
        );
        for value in [Vec::new(), data(7, b""), number(4, 0), data(2, b"")] {
            let record = record_with_value(&value);
            assert_eq!(
                received_record_wire(&success(&record)).unwrap(),
                Some(record)
            );
        }
    }

    #[test]
    fn ciphertext_is_not_scanned_as_encrypted_value_or_message_proto() {
        let opaque = [number(3, 1), number(3, 2), number(99, 5), vec![0xff]].concat();
        let record = record_with_value(&[number(1, 7), data(2, &opaque), number(13, 1)].concat());
        assert_eq!(
            received_record_wire(&success(&record)).unwrap(),
            Some(record)
        );
    }

    #[test]
    fn plain_error_frame_is_validated_before_returning_none() {
        let raw = frame(&operation(), &not_found(), None);
        assert!(received_record_wire(&raw).unwrap().is_none());
        let decoded = ResponseOperation::decode(raw.as_slice()).unwrap();
        assert_eq!(
            decoded
                .result
                .unwrap()
                .error
                .unwrap()
                .server_error
                .unwrap()
                .r#type,
            Some(3)
        );
        // Other explicit outcomes return no absence permission here.
        for code in [2, 3, 4] {
            assert!(
                received_record_wire(&frame(&operation(), &number(1, code), None))
                    .unwrap()
                    .is_none()
            );
        }
    }

    #[test]
    fn hidden_result_error_code_and_uuid_duplicates_never_return_none() {
        let op = operation();
        let raw = frame(&op, &not_found(), None);
        for extra in [data(3, &not_found()), data(2, &op)] {
            rejected(&[raw.clone(), extra].concat());
        }
        for result in [
            [number(1, 2), not_found()].concat(),
            [not_found(), data(2, &data(2, &number(1, 3)))].concat(),
            failure(&[data(2, &number(1, 2)), data(2, &number(1, 3))].concat()),
            failure(&data(2, &[number(1, 2), number(1, 3)].concat())),
        ] {
            let raw = frame(&op, &result, None);
            assert_eq!(
                ResponseOperation::decode(raw.as_slice())
                    .unwrap()
                    .result
                    .unwrap()
                    .error
                    .unwrap()
                    .server_error
                    .unwrap()
                    .r#type,
                Some(3)
            );
            rejected(&raw);
        }
        let duplicate_op = [data(1, b"other-request"), op].concat();
        let raw = frame(&duplicate_op, &not_found(), None);
        assert_eq!(
            ResponseOperation::decode(raw.as_slice())
                .unwrap()
                .response
                .unwrap()
                .operation_uuid
                .as_deref(),
            Some("11111111-2222-4333-8444-555555555555")
        );
        rejected(&raw);
    }

    #[test]
    fn unknown_error_identity_tags_and_missing_required_values_are_rejected() {
        for raw in [
            Vec::new(),
            data(3, &not_found()),
            frame(&[], &not_found(), None),
            frame(&data(1, b""), &not_found(), None),
            frame(&operation(), &[], None),
            frame(&operation(), &failure(&data(2, &[])), None),
            frame(&[operation(), number(31, 1)].concat(), &not_found(), None),
            frame(&operation(), &[not_found(), number(31, 1)].concat(), None),
            frame(
                &operation(),
                &failure(&[data(2, &number(1, 3)), number(31, 1)].concat()),
                None,
            ),
            frame(
                &operation(),
                &failure(&data(2, &[number(1, 3), number(31, 1)].concat())),
                None,
            ),
            [frame(&operation(), &not_found(), None), number(31, 1)].concat(),
        ] {
            rejected(&raw);
        }
    }

    #[test]
    fn contradictory_result_and_error_classes_cannot_become_not_found() {
        for code in [1, 2, 4] {
            let result = [number(1, code), data(2, &data(2, &number(1, 3)))].concat();
            rejected(&frame(&operation(), &result, None));
        }
        rejected(&frame(&operation(), &not_found(), Some(&data(1, &[]))));
        rejected(&frame(&operation(), &not_found(), Some(&[])));
        rejected(&frame(&operation(), &number(1, 1), None));
        let server = data(2, &number(1, 3));
        for other in [
            data(1, &number(1, 4)),
            data(7, &[data(1, b"extension"), number(2, 1)].concat()),
        ] {
            rejected(&frame(
                &operation(),
                &failure(&[server.clone(), other].concat()),
                None,
            ));
        }
    }

    #[test]
    fn widths_overflow_and_bool_aliases_are_rejected_before_prost_narrows() {
        let overflow = u64::from(u32::MAX) + 1;
        for value in [number(1, overflow + 7), number(13, 2)] {
            rejected(&success(&record_with_value(&value)));
        }
        rejected(&frame(&operation(), &number(1, overflow + 3), None));
        rejected(&frame(
            &operation(),
            &failure(&data(2, &number(1, overflow + 3))),
            None,
        ));
        rejected(&frame(
            &[data(1, b"id"), number(2, overflow + 211)].concat(),
            &not_found(),
            None,
        ));
        rejected(&frame(
            &operation(),
            &failure(&number(3, u64::from(u32::MAX))),
            None,
        ));
        // Correct sign-extended int32 remains valid, with no normalization.
        assert!(received_record_wire(&frame(
            &operation(),
            &failure(&number(3, (-1i64) as u64)),
            None
        ))
        .unwrap()
        .is_none());
    }

    #[test]
    fn wrong_wire_truncated_utf8_and_overflowing_lengths_are_rejected() {
        for value in [
            vec![0],
            vec![0x80],
            vec![0xff; 10],
            vec![0x08, 0x80],
            vec![0x0a, 0],
            vec![0x25, 0, 0, 0, 0], // type bytes / signed fixed32
            vec![0x29, 0],
            vec![0x3a, 2, b'x'],
            vec![0x3a, 1, 0xff],
            [vec![0x12], vi(u64::MAX)].concat(),
            [vec![0x20], vec![0xff; 9], vec![2]].concat(),
            vec![0x0b, 0x0c], // groups
        ] {
            rejected(&success(&record_with_value(&value)));
        }
        rejected(&[number(211, 0), data(2, &operation()), data(3, &not_found())].concat());
        rejected(&frame(&operation(), &number(1, 1), Some(&number(1, 0))));
        rejected(&frame(&number(1, 1), &not_found(), None));
    }

    #[test]
    fn repeated_lists_assets_and_nested_known_metadata_stay_bounded_and_exact() {
        let asset = [
            data(1, b"owner"),
            number(4, 3),
            data(12, b"raw"),
            data(15, &data(1, b"pcs")),
        ]
        .concat();
        let package = [data(1, &asset), data(2, &asset), data(2, &asset)].concat();
        let value = [
            data(11, &data(7, b"one")),
            data(11, &data(7, b"two")),
            data(8, &[fixed(1, 1.0), data(8, &fixed(1, 2.0))].concat()),
            data(
                9,
                &[number(1, 1), data(2, &data(1, &data(1, b"ref")))].concat(),
            ),
            data(10, &asset),
            data(12, &package),
        ]
        .concat();
        let record = record_with_value(&value);
        assert_eq!(
            received_record_wire(&success(&record)).unwrap(),
            Some(record)
        );
    }

    #[test]
    fn byte_field_and_depth_limits_fail_closed() {
        rejected(&vec![0; MAX_FRAME_BYTES + 1]);
        let many = data(11, &[]).repeat(MAX_FIELDS);
        rejected(&success(&record_with_value(&many)));
        let mut nested = Vec::new();
        for _ in 0..MAX_DEPTH {
            nested = data(11, &nested);
        }
        rejected(&success(&record_with_value(&nested)));
        let small = data(11, &data(11, &number(4, 0)));
        assert!(received_record_wire(&success(&record_with_value(&small))).is_ok());
    }

    #[test]
    fn record31_empty_metadata_preserves_original_record_and_typed_content() {
        let opaque = [number(1, 20), data(2, &[0xff, 0, 0x80]), number(13, 1)].concat();
        let base = [data(1, b"synthetic-etag"),
            data(2, &data(1, &data(1, b"synthetic-record"))),
            data(3, &data(1, b"MessageEncryptedV3")),
            data(7, &field("msgProto", &opaque)), data(24, &[0, 1, 2, 3])].concat();
        // Absent and present-empty remain different original wire values.
        // The current generated Record drops31; it must not replace raw bytes.
        let typed = Record::decode(base.as_slice()).unwrap();
        assert_eq!(received_record_wire(&success(&base)).unwrap(), Some(base.clone()));
        for record in [
            [data(31, &[]), base.clone()].concat(),
            [base.clone(), data(31, &[])].concat(),
            [base.clone(), vec![0xfa, 0x81, 0, 0x80, 0]].concat(),
        ] {
            let raw = received_record_wire(&success(&record)).unwrap().unwrap();
            assert_eq!(raw, record);
            assert_eq!(Record::decode(raw.as_slice()).unwrap(), typed);
            assert_ne!(raw, typed.encode_to_vec());
        }
    }

    #[test]
    fn record31_nonempty_protection_metadata_is_held_before_found() {
        let key = |kind| [data(1, b"synthetic-key"), number(2, kind)].concat();
        for metadata in [data(1, &[]), data(2, b""), data(2, b"synthetic-tag"),
            data(1, &data(1, b"")), data(1, &number(2, 1)),
            data(1, &key(1)), data(1, &key(2)), data(1, &key(3)),
            [data(1, &key(1)), data(1, &key(2)), data(2, b"synthetic-tag")].concat()] {
            let wire = success(&data(31, &metadata));
            assert!(matches!(received_record_wire(&wire), Err(PushError::BadMsg)));
            assert_eq!(received_record_wire_diagnostic(&wire).unwrap_err().to_string(),
                "schema=ProtectionKeysToRemove field=None reason=UnsupportedProtectionMetadata");
        }
    }

    #[test]
    fn record31_wrong_wire_truncation_nested_unknowns_and_duplicates_reject() {
        for (record, reason) in [(number(31, 0), "WrongWireType"),
            (fixed(31, 1.0), "WrongWireType"),
            ([vi((31 << 3) | 5), vec![0; 4]].concat(), "WrongWireType"),
            ([vi((31 << 3) | 2), vi(100), vec![0x42]].concat(), "InvalidLength"),
            ([vi((31 << 3) | 2), vec![0x80]].concat(), "InvalidLength"),
            ([data(31, &[]), data(31, &[])].concat(), "DuplicateSingular")] {
            let wire = success(&record);
            rejected(&wire);
            assert_eq!(received_record_wire_diagnostic(&wire).unwrap_err().to_string(),
                format!("schema=Record field=Some(31) reason={reason}"));
        }
        let key = [data(1, b"synthetic-key"), number(2, 1)].concat();
        for metadata in [number(1, 0), number(2, 0), data(2, &[0xff]),
            data(3, &[]), [data(2, b"a"), data(2, b"b")].concat(),
            data(1, &[data(1, b"a"), data(1, b"b")].concat()),
            data(1, &[number(2, 1), number(2, 1)].concat()),
            data(1, &number(1, 0)), data(1, &data(2, &[])),
            data(1, &data(3, &[])), data(1, &number(2, 0)),
            data(1, &number(2, 4)), data(1, &number(2, 0x1_0000_0001)),
            data(1, &number(2, u64::MAX)),
            data(1, &[vi((1 << 3) | 2), vi(100), vec![0x42]].concat()),
            [data(1, &key), data(2, &[0xff])].concat()] {
            let diagnostic = received_record_wire_diagnostic(&success(&data(31, &metadata)))
                .unwrap_err().to_string();
            assert!(!diagnostic.contains("UnsupportedProtectionMetadata"),
                "malformed content must be validated before the semantic hold");
        }
    }

    #[test]
    fn record31_does_not_relax_critical_duplicates_unknowns_or_bounds() {
        let empty = data(31, &[]);
        for record in [
            [empty.clone(), data(1, b"a"), data(1, b"b")].concat(),
            [empty.clone(), data(2, &[]), data(2, &[])].concat(),
            [empty.clone(), data(3, &[]), data(3, &[])].concat(),
            [empty.clone(), number(1, 0)].concat(),
            [empty.clone(), data(32, &[])].concat(),
            [empty.clone(), data(33, &[])].concat(),
            [empty.clone(), data(63, &[])].concat(),
        ] { rejected(&success(&record)); }
        // Inventory from the same pinned CKDPRecord decoder, not new support.
        // Protection/sharing/lifecycle families remain closed in this patch.
        for unsupported in [16, 17, 18, 21, 23, 26, 29, 30, 32, 33] {
            rejected(&success(&[empty.clone(), data(unsupported, &[])].concat()));
        }
        rejected(&success(&[empty.clone(), number(28, 0)].concat()));
        let duplicated_operation = [operation(), data(1, b"other-operation")].concat();
        rejected(&frame(&duplicated_operation, &number(1, 1), Some(&data(1, &empty))));
        rejected(&frame(&[], &number(1, 1), Some(&data(1, &empty))));
        rejected(&success(&data(31, &data(1, &[]).repeat(MAX_FIELDS))));
    }

    #[test]
    fn record_unknown_diagnostics_report_top_level_shapes_and_keep_refusal() {
        let record = [data(31, &[]), data(33, &[]), data(32, b"opaque"),
            number(37, 123), fixed(35, 456.0),
            [vi(36 << 3 | 5), vec![1, 2, 3, 4]].concat(),
            data(33, &[0xff, 0x80]), data(33, &[]),
            data(7, &field("msgProto", &data(2, &data(63, b"opaque"))))].concat();
        let wire = success(&record);
        rejected(&wire);
        assert_eq!(received_record_wire_diagnostic(&wire).unwrap_err().to_string(),
            "schema=Record field=Some(33) reason=UnknownField unknown_record=[field=33 wire=2 empty=true;field=32 wire=2 empty=false;field=37 wire=0;field=35 wire=1;field=36 wire=5;field=33 wire=2 empty=false] scan=Complete");
    }

    #[test]
    fn record_unknown_diagnostics_never_include_values_lengths_or_nested_shapes() {
        let mut output = None;
        for size in [17, 317, 6001] {
            let private = vec![b'Z'; size];
            let opaque = [data(200, &private), vec![0xff, 0x80, 0x0b]].concat();
            let record = [data(1, &private), data(2, &data(1, &data(1, &private))),
                data(24, &private), data(33, &opaque), data(32, &[])].concat();
            let diagnostic = received_record_wire_diagnostic(&success(&record)).unwrap_err();
            let text = diagnostic.to_string();
            let debug = format!("{diagnostic:?}");
            assert!(!text.contains("ZZZ") && !debug.contains("ZZZ"));
            assert!(!text.contains("field=200") && !text.contains("length"));
            if let Some(expected) = &output { assert_eq!(&text, expected); }
            else { output = Some(text); }
            rejected(&success(&record));
        }
        assert_eq!(output.unwrap(), "schema=Record field=Some(33) reason=UnknownField unknown_record=[field=33 wire=2 empty=false;field=32 wire=2 empty=true] scan=Complete");
        let repeated = success(&data(33, &[]).repeat(100));
        assert_eq!(received_record_wire_diagnostic(&repeated).unwrap_err().to_string(),
            received_record_wire_diagnostic(&success(&data(33, &[]))).unwrap_err().to_string());
    }

    #[test]
    fn record_unknown_diagnostics_mark_truncation_without_claiming_empty_form() {
        for record in [
            [vi(33 << 3 | 2), vec![0x80]].concat(),
            [vi(33 << 3 | 2), vi(1000), vec![1]].concat(),
        ] {
            let diagnostic = received_record_wire_diagnostic(&success(&record)).unwrap_err();
            assert_eq!(diagnostic.to_string(), "schema=Record field=Some(33) reason=UnknownField unknown_record=[field=33 wire=2 empty=unknown] scan=Malformed");
            rejected(&success(&record));
        }
        for wire in [0, 1, 5] {
            let record = [vi(33 << 3 | wire), vec![0x80]].concat();
            let diagnostic = received_record_wire_diagnostic(&success(&record)).unwrap_err();
            assert_eq!(diagnostic.unknown_record.unwrap().stop, RecordScanStop::Malformed);
            rejected(&success(&record));
        }
        for wire in [3, 4, 6, 7] {
            let record = vi(33 << 3 | wire);
            let diagnostic = received_record_wire_diagnostic(&success(&record)).unwrap_err();
            assert_eq!(diagnostic.unknown_record.unwrap().stop, RecordScanStop::UnsupportedWire);
            rejected(&success(&record));
        }
        for bad_key in [vec![0], vec![0x80], vec![0xff; 10], vi(0x2000_0000 << 3)] {
            let record = [data(33, &[]), bad_key].concat();
            let diagnostic = received_record_wire_diagnostic(&success(&record)).unwrap_err();
            assert_eq!(diagnostic.unknown_record.unwrap().stop, RecordScanStop::Malformed);
            rejected(&success(&record));
        }
    }

    #[test]
    fn record_unknown_diagnostics_are_bounded_and_explicitly_partial() {
        let fields = [data(33, &[]), number(37, 938271649).repeat(MAX_FIELDS)].concat();
        let diagnostic = received_record_wire_diagnostic(&success(&fields)).unwrap_err();
        let summary = diagnostic.unknown_record.unwrap();
        assert_eq!(summary.stop, RecordScanStop::FieldLimit);
        assert_eq!(summary.used, 2);
        assert!(!diagnostic.to_string().contains("938271649"));
        let distinct: Vec<u8> = (100..100 + MAX_RECORD_DIAGNOSTIC_SHAPES as u64)
            .flat_map(|tag| data(tag, &[])).collect();
        let diagnostic = received_record_wire_diagnostic(&success(&[data(33, &[]), distinct].concat())).unwrap_err();
        let summary = diagnostic.unknown_record.unwrap();
        assert_eq!(summary.stop, RecordScanStop::ShapeLimit);
        assert_eq!(summary.used, MAX_RECORD_DIAGNOSTIC_SHAPES);
        assert!(diagnostic.to_string().len() < 2048);
        assert_eq!(summarize_unknown_record_fields(&vec![0; MAX_FRAME_BYTES + 1]).stop,
            RecordScanStop::FrameLimit);
    }

    #[test]
    fn record_unknown_diagnostics_are_only_attached_to_existing_record_unknown_refusals() {
        for raw in [success(&number(1, 0)), success(&data(31, &data(2, b""))),
            [frame(&operation(), &not_found(), None), number(63, 1)].concat()] {
            let diagnostic = received_record_wire_diagnostic(&raw).unwrap_err();
            assert!(diagnostic.unknown_record.is_none());
            rejected(&raw);
        }
        let empty31 = data(31, &[]);
        assert_eq!(received_record_wire_diagnostic(&success(&empty31)).unwrap(), Some(empty31));
        assert_eq!(received_record_wire_diagnostic(&frame(&operation(), &not_found(), None)).unwrap(), None);
        for record in [data(33, &[]), data(33, b"opaque"),
            [data(31, &[]), data(33, &[])].concat(),
            [data(33, &[]), data(31, &[])].concat()] { rejected(&success(&record)); }
    }
}
