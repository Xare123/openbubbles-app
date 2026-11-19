pub(super) fn record_change_page_wires(frame: &[u8]) -> Result<Vec<Option<&[u8]>>, PushError> {
    const PAGE_BYTES: usize = super::CLOUDKIT_MAX_RECORD_CHANGE_PAGE_BYTES;
    // Deliberately tighter total CPU budget for original-wire processing.
    // Record checks keep their existing per-record visit/timestamp caps too.
    const PAGE_FIELDS: usize = 1024 * 1024;
    fn fields<'a>(raw: &'a [u8], budget: &mut usize,
        mut visit: impl FnMut(u64, u8, &'a [u8], Option<u64>, &mut usize) -> Result<(), PushError>)
        -> Result<(), PushError>
    {
        let mut pos = 0;
        while pos < raw.len() {
            *budget = budget.checked_sub(1).ok_or(PushError::BadMsg)?;
            let key = varint(raw, &mut pos)?;
            let tag = key >> 3;
            if tag == 0 || tag > 0x1fff_ffff { return Err(PushError::BadMsg); }
            let wire = (key & 7) as u8;
            let (bytes, scalar) = match wire {
                0 => (&[][..], Some(varint(raw, &mut pos)?)),
                1 => (take(raw, &mut pos, 8)?, None),
                2 => {
                    let len = usize::try_from(varint(raw, &mut pos)?).map_err(|_| PushError::BadMsg)?;
                    (take(raw, &mut pos, len)?, None)
                }
                5 => (take(raw, &mut pos, 4)?, None),
                _ => return Err(PushError::BadMsg),
            };
            visit(tag, wire, bytes, scalar, budget)?;
        }
        Ok(())
    }
    fn singular(seen: &mut u64, tag: u64) -> Result<(), PushError> {
        let bit = 1u64.checked_shl(tag as u32).ok_or(PushError::BadMsg)?;
        if *seen & bit != 0 { return Err(PushError::BadMsg); }
        *seen |= bit;
        Ok(())
    }
    fn schema(raw: &[u8], kind: Schema, budget: &mut usize) -> Result<(), PushError> {
        let mut diagnostic = ReceivedWireDiagnostic { schema: kind, field: None,
            reason: WireFailureKind::FrameLimit, unknown_record: None };
        parse_wire_schema(raw, kind, budget, &mut diagnostic).map(|_| ())
    }
    if frame.len() > super::CLOUDKIT_MAX_RESPONSE_FRAME_BYTES { return Err(PushError::BadMsg); }
    let mut budget = PAGE_FIELDS;
    let mut root_seen = 0;
    let mut page = None;
    fields(frame, &mut budget, |tag, wire, bytes, scalar, budget| {
        let bit_tag = if tag == 213 { 63 } else { tag };
        singular(&mut root_seen, bit_tag)?;
        match (tag, wire) {
            (1, 0) if scalar.unwrap() <= u32::MAX as u64 => Ok(()),
            (2, 2) => {
                let mut seen = 0;
                fields(bytes, budget, |tag, wire, value, scalar, _| {
                    singular(&mut seen, tag)?;
                    match (tag, wire) {
                        (1, 2) if !value.is_empty() && value.len() <= 128
                            && std::str::from_utf8(value).is_ok() => Ok(()),
                        (2, 0) if scalar == Some(213) => Ok(()),
                        (3 | 4, 0) if scalar.unwrap() <= 1 => Ok(()),
                        _ => Err(PushError::BadMsg),
                    }
                })?;
                if seen & 6 != 6 { return Err(PushError::BadMsg); }
                Ok(())
            }
            (3, 2) => {
                schema(bytes, Schema::Result, budget)?;
                // Existing operation classifier handles failure/partial results
                // before this successful-response extraction is called.
                let mut code = None;
                fields(bytes, budget, |tag, _, _, value, _| {
                    if tag == 1 { code = value; }
                    if tag == 2 { return Err(PushError::BadMsg); }
                    Ok(())
                })?;
                if code != Some(1) { return Err(PushError::BadMsg); }
                Ok(())
            }
            (4, 2) => Ok(()), // Bundled assets/header are independently decoded.
            (213, 2) if bytes.len() <= PAGE_BYTES => { page = Some(bytes); Ok(()) }
            _ => Err(PushError::BadMsg),
        }
    })?;
    if root_seen & ((1 << 2) | (1 << 3) | (1 << 63)) != ((1 << 2) | (1 << 3) | (1 << 63)) {
        return Err(PushError::BadMsg);
    }
    let mut records = Vec::new();
    let mut page_seen = 0;
    let mut aggregate = 0usize;
    fields(page.ok_or(PushError::BadMsg)?, &mut budget, |tag, wire, bytes, scalar, budget| {
        if tag != 1 { singular(&mut page_seen, tag)?; }
        match (tag, wire) {
            (1, 2) => {
                if records.len() >= super::CLOUDKIT_DEFAULT_MAX_CHANGES_PER_PAGE as usize
                    || bytes.len() > super::CLOUDKIT_MAX_RECORD_CHANGE_BYTES { return Err(PushError::BadMsg); }
                aggregate = aggregate.checked_add(bytes.len()).and_then(|n| n.checked_add(256)).ok_or(PushError::BadMsg)?;
                if aggregate > PAGE_BYTES { return Err(PushError::BadMsg); }
                let mut seen = 0;
                let mut record = None;
                fields(bytes, budget, |tag, wire, value, scalar, budget| {
                    singular(&mut seen, tag)?;
                    match (tag, wire) {
                        (1, 2) => schema(value, Schema::RecordId, budget),
                        (2, 2) if std::str::from_utf8(value).is_ok() => Ok(()),
                        (3, 2) => schema(value, Schema::Name, budget),
                        (4, 0) if scalar.unwrap() <= i32::MAX as u64
                            || scalar.unwrap() >= i32::MIN as i64 as u64 => Ok(()),
                        (5, 2) => {
                            validate_record_timestamps_wire(value)?;
                            let mut identity_seen = 0;
                            fields(value, budget, |tag, wire, nested, _, budget| {
                                match tag {
                                    1 | 2 | 3 => singular(&mut identity_seen, tag)?,
                                    _ => {},
                                }
                                match (tag, wire) {
                                    (1, 2) if std::str::from_utf8(nested).is_ok() => Ok(()),
                                    (2, 2) => schema(nested, Schema::RecordId, budget),
                                    (3, 2) => schema(nested, Schema::Name, budget),
                                    (1..=3, _) => Err(PushError::BadMsg),
                                    _ => Ok(()), // Other Record data remains opaque.
                                }
                            })?;
                            record = Some(value);
                            Ok(())
                        }
                        _ => Err(PushError::BadMsg),
                    }
                })?;
                records.push(record);
                Ok(())
            }
            (2 | 3, 2) => Ok(()), // Tokens remain byte-exact in the typed page.
            (4, 0) if scalar.unwrap() <= i32::MAX as u64
                || scalar.unwrap() >= i32::MIN as i64 as u64 => Ok(()),
            (6, 0) if scalar.unwrap() <= 1 => Ok(()),
            // Shares/deltas/obligations/attributes and unknown wrappers have
            // no supported page-consumer contract here. Never erase them.
            _ => Err(PushError::BadMsg),
        }
    })?;
    if page_seen & (1 << 4) == 0 { return Err(PushError::BadMsg); }
    Ok(records)
}

