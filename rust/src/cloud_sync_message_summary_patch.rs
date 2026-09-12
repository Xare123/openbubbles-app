//! Bounded, native binary-plist summary patching, without a typed summary roundtrip.
//! Input must be decrypted and uncompressed. This helper grants no write authority,
//! performs no I/O, and does not validate attributed-body content or mutation origin.
//! Unknown plist values survive semantically; existing body Data bytes survive exactly.
#![cfg_attr(not(test), allow(dead_code))]

use plist::{Dictionary, Value};
use std::{
    collections::BTreeSet,
    io::{self, Cursor, Write},
};

const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_HISTORY: usize = 4096; // Total snapshots across all parts, including seeds.
const MAX_PARTS: usize = 4096;
const MAX_NODES: usize = 65_536;
const MAX_DEPTH: usize = 64;
const MAX_APPLE_SECONDS: f64 = (253_402_300_799_999i64 - 978_307_200_000) as f64 / 1000.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SummaryRange {
    pub lo: u32,
    pub le: u32,
}

pub(crate) struct SummaryEditBasis {
    pub body: Vec<u8>,
    pub timestamp: f64,
    pub range: SummaryRange,
}

#[derive(Clone, Copy)]
pub(crate) enum SummaryChange<'a> {
    Edit {
        part: u32,
        /// Confirmed immediate predecessor, not necessarily the first-ever body.
        original_body: &'a [u8],
        /// Exact retained timestamp: Apple seconds or legacy whole Unix milliseconds.
        original_timestamp: f64,
        /// Original part range, never a range inferred from replacement text.
        original_range: SummaryRange,
        replacement_body: &'a [u8],
        /// Confirmed prepared timestamp in Apple-epoch seconds, never wall time.
        replacement_timestamp: f64,
    },
    Unsend {
        part: u32,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SummaryPatchError {
    UnsupportedEncoding,
    Malformed,
    Oversized,
    InvalidPatch,
    InconsistentHistory,
    SourceMismatch,
    RetractedPart,
    TimestampConflict,
}

use SummaryPatchError as Error;

/// None means absent summary; Some(empty) is malformed. Native bplist00 only.
/// Exact retries return the original bytes after all validation. A retry must
/// identify the immediately preceding snapshot, even if newer edits exist.
pub(crate) fn patch_message_summary(
    original: Option<&[u8]>,
    change: SummaryChange<'_>,
) -> Result<Vec<u8>, SummaryPatchError> {
    let mut root = match original {
        Some(bytes) => {
            validate_binary(bytes)?;
            Value::from_reader(Cursor::new(bytes))
                .map_err(|_| Error::Malformed)?
                .into_dictionary()
                .ok_or(Error::Malformed)?
        }
        None => Dictionary::new(),
    };
    let (edited, retracted, history_count) = validate_summary(&root)?;
    match change {
        SummaryChange::Unsend { part } => {
            if retracted.contains(&part) {
                return Ok(original.ok_or(Error::Malformed)?.to_vec());
            }
            if retracted.len() >= MAX_PARTS {
                return Err(Error::Oversized);
            }
            push_part(&mut root, "rp", part);
        }
        SummaryChange::Edit {
            part,
            original_body,
            original_timestamp,
            original_range,
            replacement_body,
            replacement_timestamp,
        } => {
            if original_body.len() > MAX_BYTES || replacement_body.len() > MAX_BYTES {
                return Err(Error::Oversized);
            }
            if original_body.is_empty()
                || replacement_body.is_empty()
                || history_apple_seconds(original_timestamp).is_none()
                || !valid_time(replacement_timestamp)
                || original_range.lo.checked_add(original_range.le).is_none()
            {
                return Err(Error::InvalidPatch);
            }
            if retracted.contains(&part) {
                return Err(Error::RetractedPart);
            }
            if replacement_timestamp
                <= history_apple_seconds(original_timestamp).ok_or(Error::InvalidPatch)?
            {
                return Err(Error::TimestampConflict);
            }
            let key = part.to_string();
            let ranges = dictionary(&root, "otr")?;
            if let Some(range) = ranges.and_then(|d| d.get(&key)) {
                if read_range(range)? != original_range {
                    return Err(Error::SourceMismatch);
                }
            } else if edited.contains(&part) {
                // Do not invent missing original geometry for an existing history.
                return Err(Error::InconsistentHistory);
            }
            let histories = dictionary(&root, "ec")?;
            let old_history = histories
                .and_then(|d| d.get(&key))
                .and_then(Value::as_array);
            if let Some(history) = old_history {
                for (index, entry) in history.iter().enumerate() {
                    let (time, body) = revision(entry)?;
                    if history_apple_seconds(time) == Some(replacement_timestamp) {
                        if body != replacement_body {
                            return Err(Error::TimestampConflict);
                        }
                        if index == 0
                            || revision(&history[index - 1])? != (original_timestamp, original_body)
                        {
                            return Err(Error::SourceMismatch);
                        }
                        return Ok(original.ok_or(Error::Malformed)?.to_vec());
                    }
                }
                let last = revision(history.last().ok_or(Error::InconsistentHistory)?)?;
                if replacement_timestamp <= history_apple_seconds(last.0).ok_or(Error::Malformed)? {
                    return Err(Error::TimestampConflict);
                }
                if last != (original_timestamp, original_body) {
                    return Err(Error::SourceMismatch);
                }
            }
            let added = if old_history.is_some() { 1 } else { 2 };
            if history_count + added > MAX_HISTORY
                || (!edited.contains(&part) && edited.len() >= MAX_PARTS)
            {
                return Err(Error::Oversized);
            }
            let histories = dict_mut(&mut root, "ec");
            if !histories.contains_key(&key) {
                histories.insert(
                    key.clone(),
                    Value::Array(vec![new_revision(original_body, original_timestamp)]),
                );
            }
            histories
                .get_mut(&key)
                .and_then(Value::as_array_mut)
                .ok_or(Error::Malformed)?
                .push(new_revision(replacement_body, replacement_timestamp));
            if !edited.contains(&part) {
                push_part(&mut root, "ep", part);
            }
            let ranges = dict_mut(&mut root, "otr");
            if !ranges.contains_key(&key) {
                let mut range = Dictionary::new();
                range.insert("lo".into(), Value::Integer(original_range.lo.into()));
                range.insert("le".into(), Value::Integer(original_range.le.into()));
                ranges.insert(key, Value::Dictionary(range));
            }
        }
    }
    // Also covers growth of otr when all its existing ranges are untouched parts.
    validate_summary(&root)?;
    let mut output = LimitedOutput(Vec::new());
    Value::Dictionary(root)
        .to_writer_binary(&mut output)
        .map_err(|_| Error::Oversized)?;
    // Ensure our result also meets the input structural/expansion limits.
    validate_binary(&output.0)?;
    Ok(output.0)
}

/// Resolves the exact immediate predecessor required to append an edit. A
/// fresh history is seeded from the current attributed body and message time;
/// an existing history must provide both its last revision and original range.
/// The caller still has to prove that the returned body is the current body.
pub(crate) fn resolve_edit_basis(
    original: Option<&[u8]>,
    part: u32,
    fallback_body: &[u8],
    fallback_timestamp: f64,
    fallback_range: SummaryRange,
) -> Result<SummaryEditBasis, SummaryPatchError> {
    if fallback_body.is_empty()
        || fallback_body.len() > MAX_BYTES
        || history_apple_seconds(fallback_timestamp).is_none()
        || fallback_range.lo.checked_add(fallback_range.le).is_none()
    {
        return Err(Error::InvalidPatch);
    }
    let root = match original {
        Some(bytes) => {
            validate_binary(bytes)?;
            Value::from_reader(Cursor::new(bytes))
                .map_err(|_| Error::Malformed)?
                .into_dictionary()
                .ok_or(Error::Malformed)?
        }
        None => Dictionary::new(),
    };
    let (edited, retracted, _) = validate_summary(&root)?;
    if retracted.contains(&part) {
        return Err(Error::RetractedPart);
    }
    let key = part.to_string();
    let range = dictionary(&root, "otr")?.and_then(|ranges| ranges.get(&key));
    let history = dictionary(&root, "ec")?
        .and_then(|histories| histories.get(&key))
        .and_then(Value::as_array);
    match history {
        Some(history) => {
            if !edited.contains(&part) {
                return Err(Error::InconsistentHistory);
            }
            let range = range
                .ok_or(Error::InconsistentHistory)
                .and_then(read_range)?;
            let (timestamp, body) = revision(history.last().ok_or(Error::InconsistentHistory)?)?;
            Ok(SummaryEditBasis {
                body: body.to_vec(),
                timestamp,
                range,
            })
        }
        None => {
            if edited.contains(&part) || range.is_some() {
                return Err(Error::InconsistentHistory);
            }
            Ok(SummaryEditBasis {
                body: fallback_body.to_vec(),
                timestamp: fallback_timestamp,
                range: fallback_range,
            })
        }
    }
}

fn dictionary<'a>(root: &'a Dictionary, key: &str) -> Result<Option<&'a Dictionary>, Error> {
    root.get(key)
        .map(|v| v.as_dictionary().ok_or(Error::Malformed))
        .transpose()
}

fn dict_mut<'a>(root: &'a mut Dictionary, key: &str) -> &'a mut Dictionary {
    if !root.contains_key(key) {
        root.insert(key.into(), Value::Dictionary(Dictionary::new()));
    }
    // Every existing relevant field was validated before mutation.
    root.get_mut(key).unwrap().as_dictionary_mut().unwrap()
}

fn push_part(root: &mut Dictionary, key: &str, part: u32) {
    if !root.contains_key(key) {
        root.insert(key.into(), Value::Array(vec![]));
    }
    root.get_mut(key)
        .unwrap()
        .as_array_mut()
        .unwrap()
        .push(Value::Integer(part.into()));
}

fn part_key(key: &str) -> Result<u32, Error> {
    let part = key.parse::<u32>().map_err(|_| Error::Malformed)?;
    if part.to_string() != key {
        return Err(Error::Malformed);
    }
    Ok(part)
}

fn unsigned(value: &Value) -> Result<u32, Error> {
    value
        .as_unsigned_integer()
        .and_then(|n| u32::try_from(n).ok())
        .ok_or(Error::Malformed)
}

fn parts(root: &Dictionary, key: &str) -> Result<BTreeSet<u32>, Error> {
    let mut set = BTreeSet::new();
    if let Some(value) = root.get(key) {
        let values = value.as_array().ok_or(Error::Malformed)?;
        if values.len() > MAX_PARTS {
            return Err(Error::Oversized);
        }
        for value in values {
            if !set.insert(unsigned(value)?) {
                return Err(Error::InconsistentHistory);
            }
        }
    }
    Ok(set)
}

fn valid_time(time: f64) -> bool {
    time.is_finite() && time > 0.0 && time <= MAX_APPLE_SECONDS
}

// Match the reader's two supported, non-overlapping timestamp domains.
// Compare chronology in Apple seconds but never rewrite a retained `d` value.
// New revisions are emitted in Apple's native seconds format only.
fn history_apple_seconds(time: f64) -> Option<f64> {
    if valid_time(time) {
        Some(time)
    } else if time.is_finite()
        && time >= 978_307_200_000.0
        && time <= 253_402_300_799_999.0
        && time.fract() == 0.0
    {
        Some((time - 978_307_200_000.0) / 1000.0)
    } else {
        None
    }
}

fn revision(value: &Value) -> Result<(f64, &[u8]), Error> {
    let entry = value.as_dictionary().ok_or(Error::Malformed)?;
    let time = entry
        .get("d")
        .and_then(Value::as_real)
        .ok_or(Error::Malformed)?;
    let body = entry
        .get("t")
        .and_then(Value::as_data)
        .ok_or(Error::Malformed)?;
    if history_apple_seconds(time).is_none() || body.is_empty() {
        return Err(Error::Malformed);
    }
    Ok((time, body))
}

fn read_range(value: &Value) -> Result<SummaryRange, Error> {
    let range = value.as_dictionary().ok_or(Error::Malformed)?;
    let lo = unsigned(range.get("lo").ok_or(Error::Malformed)?)?;
    let le = unsigned(range.get("le").ok_or(Error::Malformed)?)?;
    lo.checked_add(le).ok_or(Error::Malformed)?;
    Ok(SummaryRange { lo, le })
}

fn validate_summary(root: &Dictionary) -> Result<(BTreeSet<u32>, BTreeSet<u32>, usize), Error> {
    let edited = parts(root, "ep")?;
    let retracted = parts(root, "rp")?;
    let mut actual = BTreeSet::new();
    let mut count = 0;
    if let Some(histories) = dictionary(root, "ec")? {
        if histories.len() > MAX_PARTS {
            return Err(Error::Oversized);
        }
        for (key, value) in histories {
            actual.insert(part_key(key)?);
            let entries = value.as_array().ok_or(Error::Malformed)?;
            count += entries.len();
            if count > MAX_HISTORY {
                return Err(Error::Oversized);
            }
            // Existing singleton histories are accepted by the converter. Append
            // still requires an exact predecessor; only a fresh history is seeded.
            if entries.is_empty() {
                return Err(Error::InconsistentHistory);
            }
            let mut previous = None;
            for entry in entries {
                let (time, _) = revision(entry)?;
                let chronological = history_apple_seconds(time).ok_or(Error::Malformed)?;
                if previous.is_some_and(|last| chronological <= last) {
                    return Err(Error::InconsistentHistory);
                }
                previous = Some(chronological);
            }
        }
    }
    if actual != edited {
        return Err(Error::InconsistentHistory);
    }
    if let Some(ranges) = dictionary(root, "otr")? {
        if ranges.len() > MAX_PARTS {
            return Err(Error::Oversized);
        }
        for (key, range) in ranges {
            part_key(key)?;
            read_range(range)?;
        }
    }
    Ok((edited, retracted, count))
}

fn new_revision(body: &[u8], time: f64) -> Value {
    let mut entry = Dictionary::new();
    entry.insert("t".into(), Value::Data(body.to_vec()));
    entry.insert("d".into(), Value::Real(time));
    Value::Dictionary(entry)
}

struct LimitedOutput(Vec<u8>);
impl Write for LimitedOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_BYTES - self.0.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "summary exceeds limit",
            ));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

// The stable plist Value API does not expose a bounded event reader. This small
// binary framing preflight bounds expansion/depth before that parser allocates,
// rejects duplicate dictionary keys before Value can collapse them, and requires
// an exact object table + offsets + terminal trailer (no ignored suffix bytes).
fn be(bytes: &[u8]) -> Result<usize, Error> {
    if bytes.is_empty() || bytes.len() > 8 {
        return Err(Error::Malformed);
    }
    let value = bytes.iter().fold(0u64, |n, b| (n << 8) | u64::from(*b));
    usize::try_from(value).map_err(|_| Error::Oversized)
}

struct Object<'a> {
    kind: u8,
    data: &'a [u8],
}

fn validate_binary(bytes: &[u8]) -> Result<(), Error> {
    if bytes.len() > MAX_BYTES {
        return Err(Error::Oversized);
    }
    if bytes.is_empty() {
        return Err(Error::Malformed);
    }
    if !bytes.starts_with(b"bplist00") {
        return Err(Error::UnsupportedEncoding);
    }
    if bytes.len() < 41 {
        return Err(Error::Malformed);
    }
    let trailer = &bytes[bytes.len() - 32..];
    let offset_size = usize::from(trailer[6]);
    let ref_size = usize::from(trailer[7]);
    if trailer[..6] != [0; 6]
        || ![1, 2, 4, 8].contains(&offset_size)
        || ![1, 2, 4, 8].contains(&ref_size)
    {
        return Err(Error::Malformed);
    }
    let count = be(&trailer[8..16])?;
    let root = be(&trailer[16..24])?;
    let table = be(&trailer[24..32])?;
    if count > MAX_NODES {
        return Err(Error::Oversized);
    }
    if count == 0
        || root >= count
        || table < 9
        || table.checked_add(count * offset_size) != Some(bytes.len() - 32)
    {
        return Err(Error::Malformed);
    }
    let mut offsets = Vec::with_capacity(count);
    for field in bytes[table..bytes.len() - 32].chunks_exact(offset_size) {
        let offset = be(field)?;
        if offset < 8 || offset >= table {
            return Err(Error::Malformed);
        }
        offsets.push(offset);
    }
    let mut sorted = offsets.clone();
    sorted.sort_unstable();
    if sorted[0] != 8 || sorted.windows(2).any(|w| w[0] == w[1]) {
        return Err(Error::Malformed);
    }
    sorted.push(table);
    let mut objects = Vec::with_capacity(count);
    for offset in offsets {
        let next = sorted[sorted
            .binary_search(&offset)
            .map_err(|_| Error::Malformed)?
            + 1];
        let kind = bytes[offset] >> 4;
        let info = bytes[offset] & 15;
        let mut start = offset + 1;
        let mut length = usize::from(info);
        if matches!(kind, 4 | 5 | 6 | 10 | 13) && info == 15 {
            let marker = *bytes.get(start).ok_or(Error::Malformed)?;
            if marker >> 4 != 1 || marker & 15 > 3 {
                return Err(Error::Malformed);
            }
            let width = 1usize << (marker & 15);
            start += 1;
            length = be(bytes.get(start..start + width).ok_or(Error::Malformed)?)?;
            start += width;
        }
        let size = match kind {
            0 if info == 8 || info == 9 => 0,
            1 if info <= 4 => 1usize << info,
            2 if info == 2 || info == 3 => 1usize << info,
            3 if info == 3 => 8,
            4 | 5 => length,
            6 => length.checked_mul(2).ok_or(Error::Oversized)?,
            8 if info < 8 => usize::from(info) + 1,
            10 => length.checked_mul(ref_size).ok_or(Error::Oversized)?,
            13 => length.checked_mul(2 * ref_size).ok_or(Error::Oversized)?,
            _ => return Err(Error::Malformed),
        };
        if start.checked_add(size) != Some(next) {
            return Err(Error::Malformed);
        }
        objects.push(Object {
            kind,
            data: &bytes[start..next],
        });
    }
    if objects[root].kind != 13 {
        return Err(Error::Malformed);
    }
    let mut remaining_nodes = MAX_NODES;
    let mut remaining_bytes = MAX_BYTES;
    walk(
        &objects,
        root,
        ref_size,
        0,
        &mut remaining_nodes,
        &mut remaining_bytes,
    )
}

fn walk(
    objects: &[Object<'_>],
    id: usize,
    width: usize,
    depth: usize,
    nodes: &mut usize,
    bytes: &mut usize,
) -> Result<(), Error> {
    if depth >= MAX_DEPTH {
        return Err(Error::Oversized);
    }
    *nodes = nodes.checked_sub(1).ok_or(Error::Oversized)?;
    let object = objects.get(id).ok_or(Error::Malformed)?;
    *bytes = bytes
        .checked_sub(object.data.len())
        .ok_or(Error::Oversized)?;
    if object.kind == 10 || object.kind == 13 {
        let refs = object.data.chunks_exact(width);
        let key_count = if object.kind == 13 { refs.len() / 2 } else { 0 };
        let mut keys = BTreeSet::new();
        for (index, field) in refs.enumerate() {
            let child = be(field)?;
            if index < key_count {
                let key = objects.get(child).ok_or(Error::Malformed)?;
                let text = match key.kind {
                    5 if key.data.is_ascii() => {
                        String::from_utf8(key.data.to_vec()).map_err(|_| Error::Malformed)?
                    }
                    6 => String::from_utf16(
                        &key.data
                            .chunks_exact(2)
                            .map(|c| u16::from_be_bytes([c[0], c[1]]))
                            .collect::<Vec<_>>(),
                    )
                    .map_err(|_| Error::Malformed)?,
                    _ => return Err(Error::Malformed),
                };
                if !keys.insert(text) {
                    return Err(Error::InconsistentHistory);
                }
            }
            walk(objects, child, width, depth + 1, nodes, bytes)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(value: Value) -> Vec<u8> {
        let mut bytes = vec![];
        value.to_writer_binary(&mut bytes).unwrap();
        bytes
    }
    fn decode(bytes: &[u8]) -> Dictionary {
        Value::from_reader(Cursor::new(bytes))
            .unwrap()
            .into_dictionary()
            .unwrap()
    }
    fn range() -> SummaryRange {
        SummaryRange { lo: 12, le: 8 }
    }
    fn edit<'a>(
        part: u32,
        body: &'a [u8],
        time: f64,
        replacement: &'a [u8],
        next: f64,
    ) -> SummaryChange<'a> {
        SummaryChange::Edit {
            part,
            original_body: body,
            original_timestamp: time,
            original_range: range(),
            replacement_body: replacement,
            replacement_timestamp: next,
        }
    }
    fn first() -> Vec<u8> {
        patch_message_summary(None, edit(2, b"original\0\xff", 100.25, b"edit-one", 110.5)).unwrap()
    }
    fn unsend(bytes: Option<&[u8]>, part: u32) -> Result<Vec<u8>, Error> {
        patch_message_summary(bytes, SummaryChange::Unsend { part })
    }

    fn singleton() -> Vec<u8> {
        let mut root = decode(&first());
        let history = dict_mut(&mut root, "ec")
            .get_mut("2")
            .unwrap()
            .as_array_mut()
            .unwrap();
        history.remove(0);
        history[0]
            .as_dictionary_mut()
            .unwrap()
            .insert("future".into(), Value::Data(vec![0, 255]));
        encode(Value::Dictionary(root))
    }

    #[test]
    fn singleton_append_requires_exact_predecessor_and_keeps_existing_entry() {
        let input = singleton();
        let before = decode(&input);
        let change = edit(2, b"edit-one", 110.5, b"later", 120.0);
        let output = patch_message_summary(Some(&input), change).unwrap();
        let after = decode(&output);
        let history = dictionary(&after, "ec")
            .unwrap()
            .unwrap()
            .get("2")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(
            &history[..1],
            dictionary(&before, "ec")
                .unwrap()
                .unwrap()
                .get("2")
                .unwrap()
                .as_array()
                .unwrap()
        );
        assert_eq!(revision(&history[1]).unwrap(), (120.0, b"later".as_slice()));
        for key in ["ep", "otr", "rp"] {
            assert_eq!(after.get(key), before.get(key));
        }
        assert_eq!(
            patch_message_summary(Some(&output), change).unwrap(),
            output
        );
        for (body, time) in [
            (b"wrong".as_slice(), 110.5),
            (b"edit-one".as_slice(), 110.25),
        ] {
            assert_eq!(
                patch_message_summary(Some(&input), edit(2, body, time, b"later", 120.0)),
                Err(Error::SourceMismatch)
            );
        }
    }

    #[test]
    fn singleton_unsend_preserves_history_and_metadata_without_seeding() {
        let input = singleton();
        let output = unsend(Some(&input), 2).unwrap();
        let mut after = decode(&output);
        assert_eq!(
            after.remove("rp"),
            Some(Value::Array(vec![Value::Integer(2u32.into())]))
        );
        assert_eq!(after, decode(&input));
        assert_eq!(unsend(Some(&output), 2).unwrap(), output);
    }

    #[test]
    fn fresh_edit_still_seeds_original_and_replacement() {
        let root = decode(&first());
        let history = dictionary(&root, "ec")
            .unwrap()
            .unwrap()
            .get("2")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(
            revision(&history[0]).unwrap(),
            (100.25, b"original\0\xff".as_slice())
        );
        assert_eq!(
            revision(&history[1]).unwrap(),
            (110.5, b"edit-one".as_slice())
        );
        assert_eq!(
            read_range(dictionary(&root, "otr").unwrap().unwrap().get("2").unwrap()).unwrap(),
            range()
        );
    }

    #[test]
    fn legacy_millisecond_history_is_preserved_when_appending_native_seconds() {
        let mut root = decode(&first());
        let history = dict_mut(&mut root, "ec")
            .get_mut("2")
            .unwrap()
            .as_array_mut()
            .unwrap();
        for entry in history.iter_mut() {
            let entry = entry.as_dictionary_mut().unwrap();
            let time = entry.get("d").unwrap().as_real().unwrap();
            entry.insert("d".into(), Value::Real(time * 1000.0 + 978_307_200_000.0));
        }
        let retained_history = history.clone();
        let input = encode(Value::Dictionary(root));
        let change = edit(2, b"edit-one", 978_307_310_500.0, b"third", 120.25);
        let output = patch_message_summary(Some(&input), change).unwrap();
        let after = decode(&output);
        let history = dictionary(&after, "ec")
            .unwrap()
            .unwrap()
            .get("2")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(&history[..2], retained_history.as_slice());
        assert_eq!(
            revision(&history[2]).unwrap(),
            (120.25, b"third".as_slice())
        );
        assert_eq!(
            patch_message_summary(Some(&output), change).unwrap(),
            output
        );
        let unsent = unsend(Some(&input), 2).unwrap();
        assert_eq!(
            dictionary(&decode(&unsent), "ec").unwrap(),
            dictionary(&decode(&input), "ec").unwrap()
        );
        assert_eq!(
            patch_message_summary(
                Some(&input),
                edit(2, b"edit-one", 978_307_310_500.0, b"third", 109.0)
            ),
            Err(Error::TimestampConflict)
        );
        assert!(history_apple_seconds(978_307_310_500.5).is_none());
        assert!(history_apple_seconds(MAX_APPLE_SECONDS + 1.0).is_none());
    }

    #[test]
    fn unknown_values_old_bytes_ranges_and_other_parts_survive() {
        let mut root = decode(&first());
        let mut unknown = Dictionary::new();
        unknown.insert("opaque".into(), Value::Data(vec![0, 255, 31]));
        unknown.insert("uid".into(), Value::Uid(plist::Uid::new(42)));
        root.insert("future".into(), Value::Dictionary(unknown.clone()));
        let ec = dict_mut(&mut root, "ec");
        let history = ec.get_mut("2").unwrap().as_array_mut().unwrap();
        history[0]
            .as_dictionary_mut()
            .unwrap()
            .insert("future-entry".into(), Value::Dictionary(unknown));
        history[1]
            .as_dictionary_mut()
            .unwrap()
            .insert("bcg".into(), Value::String("retain".into()));
        ec.insert(
            "7".into(),
            Value::Array(vec![
                new_revision(b"other-old", 20.0),
                new_revision(b"other-new", 21.0),
            ]),
        );
        push_part(&mut root, "ep", 7);
        let mut other_range = Dictionary::new();
        other_range.insert("lo".into(), Value::Integer(1u32.into()));
        other_range.insert("le".into(), Value::Integer(3u32.into()));
        other_range.insert("future-range".into(), Value::Boolean(true));
        dict_mut(&mut root, "otr").insert("7".into(), Value::Dictionary(other_range.clone()));
        dict_mut(&mut root, "otr").insert("9".into(), Value::Dictionary(other_range));
        push_part(&mut root, "rp", 8);
        let input = encode(Value::Dictionary(root.clone()));
        let output = patch_message_summary(
            Some(&input),
            edit(2, b"edit-one", 110.5, b"edit-two", 120.75),
        )
        .unwrap();
        let after = decode(&output);
        for key in ["future", "otr", "ep", "rp"] {
            assert_eq!(after.get(key), root.get(key));
        }
        let old = dictionary(&root, "ec").unwrap().unwrap();
        let new = dictionary(&after, "ec").unwrap().unwrap();
        assert_eq!(old.get("7"), new.get("7"));
        let history = new.get("2").unwrap().as_array().unwrap();
        assert_eq!(&history[..2], old.get("2").unwrap().as_array().unwrap());
        assert_eq!(
            revision(&history[0]).unwrap(),
            (100.25, b"original\0\xff".as_slice())
        );
        assert_eq!(
            revision(&history[2]).unwrap(),
            (120.75, b"edit-two".as_slice())
        );
        assert_eq!(
            read_range(
                dictionary(&after, "otr")
                    .unwrap()
                    .unwrap()
                    .get("2")
                    .unwrap()
            )
            .unwrap(),
            range()
        );
    }

    #[test]
    fn unedited_and_edited_unsend_are_idempotent_and_preserve_everything_else() {
        let empty = unsend(None, 3).unwrap();
        assert_eq!(decode(&empty).len(), 1); // No injected default fields.
        assert_eq!(unsend(Some(&empty), 3).unwrap(), empty);
        let input = first();
        let output = unsend(Some(&input), 2).unwrap();
        let mut after = decode(&output);
        assert_eq!(
            after.remove("rp"),
            Some(Value::Array(vec![Value::Integer(2u32.into())]))
        );
        assert_eq!(after, decode(&input));
        assert_eq!(unsend(Some(&output), 2).unwrap(), output);
        assert_eq!(
            patch_message_summary(Some(&output), edit(2, b"edit-one", 110.5, b"later", 120.0)),
            Err(Error::RetractedPart)
        );
        let other = unsend(Some(&output), 9).unwrap();
        assert_eq!(
            parts(&decode(&other), "rp").unwrap(),
            BTreeSet::from([2, 9])
        );
    }

    #[test]
    fn replay_requires_exact_source_and_target_even_with_newer_history() {
        let input = first();
        let retry = edit(2, b"original\0\xff", 100.25, b"edit-one", 110.5);
        assert_eq!(patch_message_summary(Some(&input), retry).unwrap(), input);
        let newer =
            patch_message_summary(Some(&input), edit(2, b"edit-one", 110.5, b"later", 120.0))
                .unwrap();
        assert_eq!(patch_message_summary(Some(&newer), retry).unwrap(), newer);
        assert_eq!(
            patch_message_summary(Some(&input), edit(2, b"wrong", 100.25, b"edit-one", 110.5)),
            Err(Error::SourceMismatch)
        );
        assert_eq!(
            patch_message_summary(
                Some(&input),
                edit(2, b"original\0\xff", 100.0, b"edit-one", 110.5)
            ),
            Err(Error::SourceMismatch)
        );
        assert_eq!(
            patch_message_summary(
                Some(&input),
                edit(2, b"original\0\xff", 100.25, b"conflict", 110.5)
            ),
            Err(Error::TimestampConflict)
        );
    }

    #[test]
    fn timestamps_predecessors_and_original_range_fail_closed() {
        let input = first();
        for next in [100.0, 110.5] {
            assert_eq!(
                patch_message_summary(Some(&input), edit(2, b"edit-one", 110.5, b"later", next)),
                Err(Error::TimestampConflict)
            );
        }
        assert_eq!(
            patch_message_summary(
                Some(&input),
                edit(2, b"original\0\xff", 100.25, b"later", 120.0)
            ),
            Err(Error::SourceMismatch)
        );
        for time in [0.0, -1.0, f64::NAN, f64::INFINITY, MAX_APPLE_SECONDS + 1.0] {
            assert_eq!(
                patch_message_summary(None, edit(0, b"old", time, b"new", 120.0)),
                Err(Error::InvalidPatch)
            );
            assert_eq!(
                patch_message_summary(None, edit(0, b"old", 1.0, b"new", time)),
                Err(Error::InvalidPatch)
            );
        }
        let mut change = edit(2, b"edit-one", 110.5, b"later", 120.0);
        if let SummaryChange::Edit { original_range, .. } = &mut change {
            original_range.lo += 1;
        }
        assert_eq!(
            patch_message_summary(Some(&input), change),
            Err(Error::SourceMismatch)
        );
        if let SummaryChange::Edit { original_range, .. } = &mut change {
            *original_range = SummaryRange {
                lo: u32::MAX,
                le: 1,
            };
        }
        assert_eq!(
            patch_message_summary(Some(&input), change),
            Err(Error::InvalidPatch)
        );
    }

    #[test]
    fn first_edit_reuses_existing_original_range_without_losing_range_extensions() {
        let mut root = decode(&first());
        root.remove("ec");
        root.remove("ep");
        dict_mut(&mut root, "otr")
            .get_mut("2")
            .unwrap()
            .as_dictionary_mut()
            .unwrap()
            .insert("future".into(), Value::String("keep me".into()));
        let input = encode(Value::Dictionary(root.clone()));
        let output =
            patch_message_summary(Some(&input), edit(2, b"old", 1.25, b"new", 2.5)).unwrap();
        assert_eq!(decode(&output).get("otr"), root.get("otr"));
        let mut missing_range = decode(&first());
        missing_range.remove("otr");
        let input = encode(Value::Dictionary(missing_range));
        assert_eq!(
            patch_message_summary(Some(&input), edit(2, b"edit-one", 110.5, b"later", 120.0)),
            Err(Error::InconsistentHistory)
        );
    }

    #[test]
    fn malformed_parts_ranges_and_existing_timestamps_reject_even_on_unsend() {
        for key in ["02", "+2", "-1", "4294967296", "", "2 "] {
            let mut root = decode(&first());
            let ec = dict_mut(&mut root, "ec");
            let history = ec.remove("2").unwrap();
            ec.insert(key.into(), history);
            assert_eq!(
                unsend(Some(&encode(Value::Dictionary(root))), 1),
                Err(Error::Malformed)
            );
        }
        for value in [
            Value::Integer((-1i64).into()),
            Value::Real(2.0),
            Value::String("2".into()),
            Value::Integer(u64::MAX.into()),
        ] {
            let mut root = decode(&first());
            root.insert("rp".into(), Value::Array(vec![value]));
            assert_eq!(
                unsend(Some(&encode(Value::Dictionary(root))), 1),
                Err(Error::Malformed)
            );
        }
        for mode in 0..5 {
            let mut root = decode(&first());
            let range = dict_mut(&mut root, "otr")
                .get_mut("2")
                .unwrap()
                .as_dictionary_mut()
                .unwrap();
            match mode {
                0 => {
                    range.remove("lo");
                }
                1 => {
                    range.insert("le".into(), Value::Real(3.0));
                }
                2 => {
                    range.insert("lo".into(), Value::Integer(u32::MAX.into()));
                }
                _ => {
                    let entry = dict_mut(&mut root, "ec")
                        .get_mut("2")
                        .unwrap()
                        .as_array_mut()
                        .unwrap()[0]
                        .as_dictionary_mut()
                        .unwrap();
                    if mode == 3 {
                        entry.insert("d".into(), Value::Real(0.0));
                    } else {
                        entry.insert("t".into(), Value::Data(vec![]));
                    }
                }
            }
            assert_eq!(
                unsend(Some(&encode(Value::Dictionary(root))), 1),
                Err(Error::Malformed)
            );
        }
    }

    #[test]
    fn unknown_scalar_types_and_unicode_dictionary_keys_are_preserved() {
        let mut root = Dictionary::new();
        root.insert(
            "未来 🎉".into(),
            Value::Array(vec![
                Value::Integer((-10i64).into()),
                Value::Integer(u64::MAX.into()),
                Value::Real(1.125),
                Value::Uid(plist::Uid::new(1024)),
                Value::Date(plist::Date::from_xml_format("2026-01-01T00:00:00Z").unwrap()),
                Value::Boolean(true),
                Value::String("héllo".into()),
                Value::Data(vec![]),
            ]),
        );
        let input = encode(Value::Dictionary(root.clone()));
        let output = unsend(Some(&input), 0).unwrap();
        let mut after = decode(&output);
        after.remove("rp");
        assert_eq!(after, root);
    }

    #[test]
    fn malformed_relevant_fields_and_ambiguous_history_reject() {
        let good = decode(&first());
        for key in ["ec", "ep", "otr", "rp"] {
            let mut root = good.clone();
            root.insert(key.into(), Value::Boolean(false));
            assert_eq!(
                unsend(Some(&encode(Value::Dictionary(root))), 1),
                Err(Error::Malformed)
            );
        }
        for field in ["t", "d"] {
            let mut root = good.clone();
            dict_mut(&mut root, "ec")
                .get_mut("2")
                .unwrap()
                .as_array_mut()
                .unwrap()[0]
                .as_dictionary_mut()
                .unwrap()
                .insert(field.into(), Value::String("bad".into()));
            assert_eq!(
                unsend(Some(&encode(Value::Dictionary(root))), 1),
                Err(Error::Malformed)
            );
        }
        for mode in 0..6 {
            let mut root = good.clone();
            match mode {
                0 => {
                    root.remove("ep");
                }
                1 => push_part(&mut root, "ep", 2),
                2 => push_part(&mut root, "ep", 3),
                3 => {
                    dict_mut(&mut root, "ec").insert("2".into(), Value::Array(vec![]));
                }
                4 => {
                    dict_mut(&mut root, "ec").insert(
                        "2".into(),
                        Value::Array(vec![new_revision(b"a", 2.0), new_revision(b"b", 2.0)]),
                    );
                }
                _ => {
                    dict_mut(&mut root, "ec").insert(
                        "2".into(),
                        Value::Array(vec![new_revision(b"a", 2.0), new_revision(b"b", 1.0)]),
                    );
                }
            }
            assert_eq!(
                unsend(Some(&encode(Value::Dictionary(root))), 1),
                Err(Error::InconsistentHistory)
            );
        }
    }

    #[test]
    fn framing_rejects_suffixes_duplicate_keys_non_dictionary_and_compression() {
        let good = first();
        for tail in [b"garbage".as_slice(), &[0], b"</plist>"] {
            let mut bad = good.clone();
            bad.extend_from_slice(tail);
            assert!(unsend(Some(&bad), 0).is_err());
        }
        for end in [0, 7, good.len() - 1] {
            assert!(unsend(Some(&good[..end]), 0).is_err());
        }
        assert_eq!(
            unsend(Some(&encode(Value::Array(vec![]))), 0),
            Err(Error::Malformed)
        );
        assert_eq!(
            unsend(Some(b"\x1f\x8bcompressed"), 0),
            Err(Error::UnsupportedEncoding)
        );
        assert_eq!(
            unsend(Some(b"<plist><dict/></plist>bad"), 0),
            Err(Error::UnsupportedEncoding)
        );
        // Two distinct serialized keys become identical without altering framing.
        let mut root = Dictionary::new();
        root.insert("aa".into(), Value::Boolean(true));
        root.insert("bb".into(), Value::Boolean(false));
        let mut duplicate = encode(Value::Dictionary(root));
        let index = duplicate.windows(3).position(|w| w == b"\x52bb").unwrap();
        duplicate[index + 1..index + 3].copy_from_slice(b"aa");
        assert_eq!(unsend(Some(&duplicate), 0), Err(Error::InconsistentHistory));
    }

    #[test]
    fn limits_cover_input_output_bodies_history_and_nesting() {
        assert_eq!(
            unsend(Some(&vec![0; MAX_BYTES + 1]), 0),
            Err(Error::Oversized)
        );
        assert_eq!(
            patch_message_summary(None, edit(0, b"old", 1.0, &vec![1; MAX_BYTES + 1], 2.0)),
            Err(Error::Oversized)
        );
        assert_eq!(
            patch_message_summary(None, edit(0, b"old", 1.0, &vec![1; MAX_BYTES], 2.0)),
            Err(Error::Oversized)
        );
        let mut root = decode(&first());
        let entries = (0..MAX_HISTORY)
            .map(|i| new_revision(b"x", i as f64 + 1.0))
            .collect();
        dict_mut(&mut root, "ec").insert("2".into(), Value::Array(entries));
        let input = encode(Value::Dictionary(root));
        assert_eq!(
            patch_message_summary(
                Some(&input),
                edit(2, b"x", MAX_HISTORY as f64, b"y", MAX_HISTORY as f64 + 1.0)
            ),
            Err(Error::Oversized)
        );
        let mut deep = Value::Boolean(true);
        for _ in 0..MAX_DEPTH {
            deep = Value::Array(vec![deep]);
        }
        let mut root = Dictionary::new();
        root.insert("deep".into(), deep);
        assert_eq!(
            unsend(Some(&encode(Value::Dictionary(root))), 0),
            Err(Error::Oversized)
        );
    }
}
