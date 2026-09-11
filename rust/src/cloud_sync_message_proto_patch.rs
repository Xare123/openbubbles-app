//! Lossless, bounded patching of the three msgProto fields used by mutations.
//! A generated protobuf decode/encode discards unknown fields. Retain all other
//! wire spans verbatim instead. Input is already-decrypted, uncompressed bytes;
//! the caller must validate record type, authority, mutation source and causal
//! predecessor before using this helper. This neither authorizes nor saves.
#![cfg_attr(not(test), allow(dead_code))]

const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_FIELDS: usize = 16 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ProtoPatchError {
    InvalidPatch,
    Malformed,
    UnsupportedWireType,
    AmbiguousField,
    Oversized,
}

/// Replace text and attributed body together for an edit, or retain both for
/// an unsend whose retraction is represented in summary info. Presence and
/// empty values differ: Some("") is an explicit empty edit, None is unchanged.
/// This is a byte operation, not validation of Apple's summary/unsend semantics.
pub(crate) fn patch_message_proto(
    original: &[u8],
    text: Option<&str>,
    attributed_body: Option<&[u8]>,
    summary_info: &[u8],
) -> Result<Vec<u8>, ProtoPatchError> {
    use ProtoPatchError as Error;
    if text.is_some() != attributed_body.is_some() || summary_info.is_empty() {
        return Err(Error::InvalidPatch);
    }
    let patches = [
        (3u64, text.map(str::as_bytes)),
        (4, attributed_body),
        (7, Some(summary_info)),
    ];
    if original.len() > MAX_BYTES
        || patches
            .iter()
            .any(|(_, value)| value.is_some_and(|v| v.len() > MAX_BYTES))
    {
        return Err(Error::Oversized);
    }
    let mut output = Vec::with_capacity(original.len());
    let mut seen = [false; 3];
    let mut position = 0;
    let mut fields = 0;
    while position < original.len() {
        fields += 1;
        if fields > MAX_FIELDS {
            return Err(Error::Oversized);
        }
        let start = position;
        let key = varint(original, &mut position)?;
        let number = key >> 3;
        if number == 0 || number > 0x1fff_ffff {
            return Err(Error::Malformed);
        }
        let kind = key & 7;
        let payload = match kind {
            0 => {
                varint(original, &mut position)?;
                None
            }
            1 => {
                advance(original, &mut position, 8)?;
                None
            }
            2 => {
                let length = usize::try_from(varint(original, &mut position)?)
                    .map_err(|_| Error::Malformed)?;
                let begin = position;
                advance(original, &mut position, length)?;
                Some(&original[begin..position])
            }
            5 => {
                advance(original, &mut position, 4)?;
                None
            }
            // Deprecated groups are retained as unsupported work, never skipped
            // incorrectly or partially serialized. No recursive parser here.
            _ => return Err(Error::UnsupportedWireType),
        };
        if let Some(index) = patches.iter().position(|(field, _)| *field == number) {
            if kind != 2 {
                return Err(Error::Malformed);
            }
            if seen[index] {
                return Err(Error::AmbiguousField);
            }
            seen[index] = true;
            if let Some(replacement) = patches[index].1 {
                if payload != Some(replacement) {
                    append_field(&mut output, number, replacement)?;
                    continue;
                }
            }
        }
        append(&mut output, &original[start..position])?;
    }
    for (index, (number, replacement)) in patches.iter().enumerate() {
        if !seen[index] {
            if let Some(value) = replacement {
                append_field(&mut output, *number, value)?;
            }
        }
    }
    Ok(output)
}

fn varint(input: &[u8], position: &mut usize) -> Result<u64, ProtoPatchError> {
    let mut value = 0u64;
    for index in 0..10 {
        let byte = *input.get(*position).ok_or(ProtoPatchError::Malformed)?;
        *position += 1;
        if index == 9 && byte > 1 {
            return Err(ProtoPatchError::Malformed);
        }
        value |= u64::from(byte & 0x7f) << (index * 7);
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(ProtoPatchError::Malformed)
}

fn advance(input: &[u8], position: &mut usize, length: usize) -> Result<(), ProtoPatchError> {
    *position = position
        .checked_add(length)
        .filter(|end| *end <= input.len())
        .ok_or(ProtoPatchError::Malformed)?;
    Ok(())
}

fn append(output: &mut Vec<u8>, value: &[u8]) -> Result<(), ProtoPatchError> {
    if value.len() > MAX_BYTES - output.len() {
        return Err(ProtoPatchError::Oversized);
    }
    output.extend_from_slice(value);
    Ok(())
}

fn append_field(output: &mut Vec<u8>, number: u64, value: &[u8]) -> Result<(), ProtoPatchError> {
    // These field numbers fit in a one-byte key. Reserve a bounded header,
    // not another payload-sized allocation. Unknown fields never reach here.
    let mut header = vec![((number << 3) | 2) as u8];
    let mut length = value.len();
    while length >= 128 {
        header.push((length as u8 & 0x7f) | 0x80);
        length >>= 7;
    }
    header.push(length as u8);
    append(output, &header)?;
    append(output, value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message as _;
    use rustpush::cloud_messages::cloudmessagesp::MessageProto;

    fn field(number: u64, value: &[u8]) -> Vec<u8> {
        let mut out = vec![];
        append_field(&mut out, number, value).unwrap();
        out
    }

    #[test]
    fn edit_preserves_unknown_and_unedited_wire_spans_exactly() {
        // Field 99 uses a nonminimal but valid varint. Field 76 is opaque data.
        let before = [0x08, 1, 0x98, 0x06, 0x81, 0x00];
        let after = [0x2a, 2, b'b', b'i', 0xe2, 4, 3, 0, 255, 1];
        let original = [
            before.to_vec(),
            field(3, b"old"),
            field(4, b"body"),
            field(7, b"history"),
            after.to_vec(),
        ]
        .concat();
        let copy = original.clone();
        let patched =
            patch_message_proto(&original, Some("new 🎉"), Some(b"new-body"), b"new-history")
                .unwrap();
        assert_eq!(
            patched,
            [
                before.to_vec(),
                field(3, "new 🎉".as_bytes()),
                field(4, b"new-body"),
                field(7, b"new-history"),
                after.to_vec()
            ]
            .concat()
        );
        let decoded = MessageProto::decode(patched.as_slice()).unwrap();
        assert_eq!(decoded.text.as_deref(), Some("new 🎉"));
        assert_eq!(decoded.balloon_bundle_id.as_deref(), Some("bi"));
        assert_eq!(original, copy);
    }

    #[test]
    fn summary_only_keeps_body_and_text_and_adds_absent_summary() {
        let original = [
            field(3, b"keep"),
            field(4, b"exact attributed bytes"),
            vec![0x48, 1],
        ]
        .concat();
        let patched = patch_message_proto(&original, None, None, b"retraction").unwrap();
        assert_eq!(patched, [original, field(7, b"retraction")].concat());
    }

    #[test]
    fn fixed_width_unknowns_remain_verbatim() {
        let original = [0xa1, 6, 0, 1, 2, 3, 4, 5, 6, 7, 0xad, 6, 255, 254, 253, 252];
        assert_eq!(
            patch_message_proto(&original, None, None, b"s").unwrap(),
            [original.to_vec(), field(7, b"s")].concat()
        );
    }

    #[test]
    fn same_patch_is_byte_idempotent_including_nonminimal_known_lengths() {
        let original = [0x1a, 0x81, 0, b'a', 0x22, 1, b'b', 0x3a, 1, b'c'];
        let patched = patch_message_proto(&original, Some("a"), Some(b"b"), b"c").unwrap();
        assert_eq!(patched, original);
        assert_eq!(
            patch_message_proto(&patched, Some("a"), Some(b"b"), b"c").unwrap(),
            patched
        );
    }

    #[test]
    fn explicit_empty_edit_is_not_absence() {
        let original = [field(3, b"old"), field(4, b"body")].concat();
        let patched = patch_message_proto(&original, Some(""), Some(b""), b"history").unwrap();
        let decoded = MessageProto::decode(patched.as_slice()).unwrap();
        assert_eq!(decoded.text.as_deref(), Some(""));
        assert_eq!(decoded.attributed_body.as_deref(), Some(b"".as_slice()));
    }

    #[test]
    fn duplicate_mutable_fields_reject_but_duplicate_unknowns_survive() {
        for number in [3, 4, 7] {
            let original = [field(number, b"one"), field(number, b"two")].concat();
            assert_eq!(
                patch_message_proto(&original, None, None, b"summary"),
                Err(ProtoPatchError::AmbiguousField)
            );
        }
        let unknown = [0x98, 6, 1, 0x98, 6, 2];
        assert_eq!(
            patch_message_proto(&unknown, None, None, b"s").unwrap(),
            [unknown.to_vec(), field(7, b"s")].concat()
        );
    }

    #[test]
    fn malformed_or_unsupported_input_never_returns_partial_patch() {
        for input in [
            &[0u8][..],
            &[0x80],
            &[0x1a, 5, b'a'],
            &[0x18, 1],
            &[0x21, 1],
            &[0x25, 1],
            &[0x38, 1],
            &[0xff; 11],
        ] {
            assert!(patch_message_proto(input, Some("new"), Some(b"body"), b"summary").is_err());
        }
        assert_eq!(
            patch_message_proto(&[0x0b], None, None, b"s"),
            Err(ProtoPatchError::UnsupportedWireType)
        );
        assert_eq!(
            patch_message_proto(&[0x80, 0x80, 0x80, 0x80, 0x10, 0], None, None, b"s"),
            Err(ProtoPatchError::Malformed)
        );
    }

    #[test]
    fn limits_include_output_growth_field_count_and_replacement_inputs() {
        let oversized = vec![0; MAX_BYTES + 1];
        assert_eq!(
            patch_message_proto(&oversized, None, None, b"s"),
            Err(ProtoPatchError::Oversized)
        );
        assert_eq!(
            patch_message_proto(&[], Some("a"), Some(&oversized), b"s"),
            Err(ProtoPatchError::Oversized)
        );
        let many_fields = [0x08, 1].repeat(MAX_FIELDS + 1);
        assert_eq!(
            patch_message_proto(&many_fields, None, None, b"s"),
            Err(ProtoPatchError::Oversized)
        );
        let full = vec![0; MAX_BYTES];
        assert_eq!(
            patch_message_proto(&[], None, None, &full),
            Err(ProtoPatchError::Oversized)
        );
    }

    #[test]
    fn edit_parts_must_be_paired_and_summary_cannot_be_implicitly_cleared() {
        assert_eq!(
            patch_message_proto(&[], Some("a"), None, b"s"),
            Err(ProtoPatchError::InvalidPatch)
        );
        assert_eq!(
            patch_message_proto(&[], None, Some(b"a"), b"s"),
            Err(ProtoPatchError::InvalidPatch)
        );
        assert_eq!(
            patch_message_proto(&[], None, None, b""),
            Err(ProtoPatchError::InvalidPatch)
        );
    }
}
