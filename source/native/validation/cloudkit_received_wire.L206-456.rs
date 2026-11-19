        // This is strict read grammar only: every nonempty message is held
        // below before returning raw bytes, so it cannot become Found/staged.
        (Record, 31) => Message(ProtectionKeysToRemove),
        (ProtectionKeysToRemove, 1) => return Ok((Message(ProtectionRemovalKey), true)),
        (ProtectionKeysToRemove, 2) => Text,
        (ProtectionRemovalKey, 1) => Bytes,
        (ProtectionRemovalKey, 2) => I32,
        // All members are optional and independent. Preserve exact raw bytes;
        // this does not infer units, epoch, ordering or crypto exclusion.
        (Record, 34) => Message(RecordTimestamps),
        (RecordTimestamps, 1) => I32,
        (RecordTimestamps, 2 | 3) => Message(TimestampVersion),
        (TimestampVersion, 1) => Varint, // int64, ordinary signed varint, not zigzag.
        (TimestampVersion, 2) => Bytes,
        (TimestampVersion, 3) => I32,
        (RecordId, 1) => Message(Identifier),
        (RecordId, 2) => Message(ZoneId),
        (ZoneId, 1 | 2) => Message(Identifier),
        (ZoneId, 3) | (Identifier, 2) => U32,
        (Identifier | Name, 1) => Text,
        (Dates, 1 | 2) => Message(Date),
        (Date, 1) => Fixed64,
        (Field, 1) => Message(Name),
        (Field, 2) => Message(Value),
        (Value, 1) => U32,
        (Value, 2) => Bytes,
        (Value, 4) => Varint, // int64: preserve all 64 bits, including flags.
        (Value, 5) => Fixed64,
        (Value, 6) => Message(Date),
        (Value, 7) => Text,
        (Value, 8) => Message(Coordinate),
        (Value, 9) => Message(Reference),
        (Value, 10) => Message(Asset),
        (Value, 11) => return Ok((Message(Value), true)),
        (Value, 12) => Message(Package),
        (Value, 13) => Bool,
        (Coordinate, 1..=7) => Fixed64,
        (Coordinate, 8) => Message(Date),
        (Reference, 1) => U32,
        (Reference, 2) => Message(RecordId),
        (Asset, 1 | 5 | 7..=9 | 11 | 13 | 21) => Text,
        (Asset, 2 | 3 | 6 | 12 | 17) => Bytes,
        (Asset, 4 | 14 | 18) => Varint,
        (Asset, 10) => Message(RecordId),
        (Asset, 15) => Message(Protection),
        (Package, 1) => Message(Asset),
        (Package, 2) => return Ok((Message(Asset), true)),
        (Protection, 1) => Bytes,
        (Protection, 2) => Text,
        (StableUrl, 1 | 5) => Text,
        (StableUrl, 2..=4) => Bytes,
        _ => return Err(PushError::BadMsg),
    };
    Ok((kind, false))
}

struct Level<'a> {
    schema: Schema,
    bytes: &'a [u8],
    pos: usize,
    seen: u64,
}

impl<'a> Level<'a> {
    fn new(schema: Schema, bytes: &'a [u8]) -> Self {
        Self {
            schema,
            bytes,
            pos: 0,
            seen: 0,
        }
    }

    fn finish(&self) -> Result<(), PushError> {
        use Schema::*;
        let required = match self.schema {
            Response => (1 << 2) | (1 << 3),
            Operation | Result | ClientError | ServerError | Retrieve => 1 << 1,
            _ => 0, // Required record content is checked after raw extraction.
        };
        // Multiple error classes must not let server NOT_FOUND win over a
        // conflicting client/extension failure.
        let error_classes = self.seen & ((1 << 1) | (1 << 2) | (1 << 7));
        if self.seen & required != required
            || (self.schema == Error && error_classes.count_ones() > 1)
        {
            return Err(PushError::BadMsg);
        }
        Ok(())
    }
}

fn varint(bytes: &[u8], pos: &mut usize) -> Result<u64, PushError> {
    let mut value = 0;
    for shift in 0..10 {
        let byte = *bytes.get(*pos).ok_or(PushError::BadMsg)?;
        *pos += 1;
        if shift == 9 && byte > 1 {
            return Err(PushError::BadMsg);
        }
        value |= u64::from(byte & 0x7f) << (7 * shift);
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(PushError::BadMsg)
}

fn take<'a>(bytes: &'a [u8], pos: &mut usize, len: usize) -> Result<&'a [u8], PushError> {
    let end = pos
        .checked_add(len)
        .filter(|end| *end <= bytes.len())
        .ok_or(PushError::BadMsg)?;
    let value = &bytes[*pos..end];
    *pos = end;
    Ok(value)
}

/// Structural diagnostics only, after the Record has already been rejected.
/// Skip top-level values without interpreting nested messages or opaque bytes.
/// No raw bytes, values, identifiers or exact nonzero lengths enter the summary.
fn diagnostic_skip_value(bytes: &[u8], pos: &mut usize, wire: u8)
    -> Result<Option<bool>, RecordScanStop>
{
    let malformed = |_| RecordScanStop::Malformed;
    match wire {
        0 => { varint(bytes, pos).map_err(malformed)?; }
        1 => { take(bytes, pos, 8).map_err(malformed)?; }
        2 => {
            let len = usize::try_from(varint(bytes, pos).map_err(malformed)?)
                .map_err(|_| RecordScanStop::Malformed)?;
            take(bytes, pos, len).map_err(malformed)?;
            return Ok(Some(len == 0));
        }
        5 => { take(bytes, pos, 4).map_err(malformed)?; }
        _ => return Err(RecordScanStop::UnsupportedWire), // Never traverse groups.
    }
    Ok(None)
}

fn summarize_unknown_record_fields(bytes: &[u8]) -> RecordUnknownSummary {
    let mut summary = RecordUnknownSummary {
        fields: [RecordUnknownField::default(); MAX_RECORD_DIAGNOSTIC_SHAPES],
        used: 0, stop: RecordScanStop::Complete,
    };
    if bytes.len() > MAX_FRAME_BYTES {
        summary.stop = RecordScanStop::FrameLimit;
        return summary;
    }
    let mut pos = 0;
    for _ in 0..MAX_FIELDS {
        if pos == bytes.len() { return summary; }
        let key = match varint(bytes, &mut pos) {
            Ok(key) if key >> 3 != 0 && key >> 3 <= 0x1fff_ffff => key,
            _ => { summary.stop = RecordScanStop::Malformed; return summary; }
        };
        let tag = key >> 3;
        let wire = (key & 7) as u8;
        let shape = diagnostic_skip_value(bytes, &mut pos, wire);
        if rule(Schema::Record, tag).is_err() {
            let field = RecordUnknownField { field: tag as u32, wire,
                empty: shape.as_ref().ok().copied().flatten() };
            // Repeated identical shapes do not reveal occurrence counts.
            if !summary.fields[..summary.used].contains(&field) {
                if summary.used == MAX_RECORD_DIAGNOSTIC_SHAPES {
                    summary.stop = RecordScanStop::ShapeLimit;
                    return summary;
                }
                summary.fields[summary.used] = field;
                summary.used += 1;
            }
        }
        if let Err(stop) = shape { summary.stop = stop; return summary; }
    }
    if pos != bytes.len() { summary.stop = RecordScanStop::FieldLimit; }
    summary
}

pub(super) fn received_record_wire(frame: &[u8]) -> Result<Option<Vec<u8>>, PushError> {
    received_record_wire_diagnostic(frame).map_err(|_| PushError::BadMsg)
}

pub(super) fn received_record_wire_diagnostic(
    frame: &[u8],
) -> Result<Option<Vec<u8>>, ReceivedWireDiagnostic> {
    let mut diagnostic = ReceivedWireDiagnostic {
        schema: Schema::Response, field: None, reason: WireFailureKind::FrameLimit,
        unknown_record: None,
    };
    parse_received_record_wire(frame, &mut diagnostic).map_err(|_| diagnostic)
}

fn parse_received_record_wire(
    frame: &[u8],
    diagnostic: &mut ReceivedWireDiagnostic,
) -> Result<Option<Vec<u8>>, PushError> {
    let mut remaining = MAX_FIELDS;
    parse_wire_schema(frame, Schema::Response, &mut remaining, diagnostic)
}

/// Narrow metadata preflight, not strict Record admission. Ordinary history
/// keeps its existing opaque-field policy; exact received fetch still requires
/// received_record_wire on the ORIGINAL response. Never infer Found from this.
/// Hold unresolved outer protection-removal metadata before generated Record
/// decoding can erase it. This cannot recover metadata already reencoded away.
pub(super) fn validate_record_timestamps_wire(raw: &[u8]) -> Result<(), PushError> {
    if raw.len() > MAX_FRAME_BYTES { return Err(PushError::BadMsg); }
    let mut pos = 0;
    let mut remaining = MAX_FIELDS;
    let mut present = false;
    let mut empty_protection_present = false;
    let mut outer_fields = 0;
    while pos < raw.len() {
        outer_fields += 1;
        if outer_fields > MAX_TIMESTAMP_OUTER_FIELDS { return Err(PushError::BadMsg); }
        let key = varint(raw, &mut pos)?;
        let tag = key >> 3;
        if tag == 0 || tag > 0x1fff_ffff { return Err(PushError::BadMsg); }
        if tag == 33 {
            // Even explicit empty chain protection metadata is unsupported.
            return Err(PushError::BadMsg);
        } else if tag == 31 {
            if empty_protection_present || key & 7 != 2 { return Err(PushError::BadMsg); }
            empty_protection_present = true;
            let len = usize::try_from(varint(raw, &mut pos)?).map_err(|_| PushError::BadMsg)?;
            if len != 0 { return Err(PushError::BadMsg); }
            // The established empty31 policy grants no removal/tag authority.
        } else if tag == 34 {
            if present || key & 7 != 2 { return Err(PushError::BadMsg); }
            present = true;
            let len = usize::try_from(varint(raw, &mut pos)?).map_err(|_| PushError::BadMsg)?;
            let bytes = take(raw, &mut pos, len)?;
            let mut diagnostic = ReceivedWireDiagnostic {schema: Schema::RecordTimestamps,
                field: None, reason: WireFailureKind::FrameLimit, unknown_record: None};
            parse_wire_schema(bytes, Schema::RecordTimestamps, &mut remaining, &mut diagnostic)?;
        } else {
            diagnostic_skip_value(raw, &mut pos, (key & 7) as u8).map_err(|_| PushError::BadMsg)?;
        }
    }
    Ok(())
}

/// Original successful record-change page, before its typed outcome escapes.
/// Unknown Record fields stay opaque and are retained byte-exact. This is not
/// exact-record admission, field33 support, or writer authority. The enclosing
/// transport has already bounded/decoded the frame and matched request UUIDs.
