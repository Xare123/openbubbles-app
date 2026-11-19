//! Pure pre-prost validation of one ORIGINAL, unframed ResponseOperation.
//! Returns the exact Record bytes at field 211 -> field 1, never a reencoding.
//! None means a validated non-success frame has no retrieve payload; it is NOT
//! NotFound proof. The caller must still match the operation UUID and classify
//! the status, then bind record/account/zone/ETag and inspect required fields.
//!
//! Validates identity/result/error branches even when no record is returned.
//! Record submessages use cloudkit.proto and the pinned Apple grammar below. Unknown
//! tags, duplicate singulars, wrong wire types, truncation and numeric narrowing
//! fail with BadMsg. Field-name uniqueness and type/payload consistency remain
//! the inspector's job. Absent and explicit empty values are never normalized.
//!
//! Scope is conservative: other response payloads, Record.shareInfo (16), and
//! nonempty Record.protectionInfoKeysToRemove (31) is unsupported. Empty31 is
//! preserved; no key removal or protection-tag instruction is applied or ignored.
//! Record.chainProtectionInfoKeysToRemove (33) remains unsupported even when empty.
//! Record.timestamps (34) retains version components and presence only: no date,
//! ordering or cryptographic authority. Unknown domains/nested fields are held.
//! The unrelated ResponseOperation.header payload is opaque;
//! it cannot provide identity or a result and is still decoded by the caller.
//! bytesValue/PCS/asset bytes are opaque, including encrypted EncryptedValue.
//! Decrypted scalar and MessageProto validation belongs to the inspector.
//!
//! No I/O, decryption, logging or authority. At most 8 MiB input, 4096 validator
//! field visits, 16 active message levels; one final Record-sized allocation only.
//! An already-refused Record unknown field permits a separate diagnostic walk:
//! at most 4096 top-level visits and 32 distinct shapes, with no nested traversal.
//! Any legal field order and non-minimal, non-overflowing varints are accepted.

use crate::PushError;

const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
const MAX_FIELDS: usize = 4096;
const MAX_DEPTH: usize = 16;
const MAX_RECORD_DIAGNOSTIC_SHAPES: usize = 32;
// Matches ordinary projection's existing outer field budget. Exact response
// admission still shares its original 4096 visits across the complete frame.
const MAX_TIMESTAMP_OUTER_FIELDS: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Schema {
    Response,
    Operation,
    Result,
    Error,
    ClientError,
    ServerError,
    Extension,
    Retrieve,
    Record,
    RecordId,
    ZoneId,
    Identifier,
    Name,
    Dates,
    Date,
    Field,
    Value,
    Coordinate,
    Reference,
    Asset,
    Package,
    Protection,
    ProtectionKeysToRemove,
    ProtectionRemovalKey,
    RecordTimestamps,
    TimestampVersion,
    StableUrl,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WireFailureKind {
    FrameLimit,
    FieldLimit,
    DepthLimit,
    InvalidKey,
    UnknownField,
    WrongWireType,
    DuplicateSingular,
    InvalidScalar,
    InvalidLength,
    TruncatedFixed64,
    InvalidText,
    InvalidOperationIdentity,
    OperationKind,
    ResultCode,
    ErrorCode,
    InvalidShape,
    ResultConflict,
    UnsupportedProtectionMetadata,
    UnsupportedTimestampMetadata,
}

/// Protocol structure only. No response values, identifiers or error text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct ReceivedWireDiagnostic {
    schema: Schema,
    field: Option<u32>,
    reason: WireFailureKind,
    unknown_record: Option<RecordUnknownSummary>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
struct RecordUnknownField {
    field: u32,
    wire: u8,
    empty: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
// Complete describes top-level framing only, not semantic or cardinality validity.
enum RecordScanStop { Complete, FrameLimit, FieldLimit, ShapeLimit, Malformed, UnsupportedWire }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RecordUnknownSummary {
    fields: [RecordUnknownField; MAX_RECORD_DIAGNOSTIC_SHAPES],
    used: usize,
    stop: RecordScanStop,
}

impl std::fmt::Display for ReceivedWireDiagnostic {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(out, "schema={:?} field={:?} reason={:?}", self.schema, self.field, self.reason)?;
        if let Some(summary) = &self.unknown_record {
            write!(out, " unknown_record=[")?;
            for (index, field) in summary.fields[..summary.used].iter().enumerate() {
                if index != 0 { write!(out, ";")?; }
                write!(out, "field={} wire={}", field.field, field.wire)?;
                if field.wire == 2 {
                    match field.empty {
                        Some(empty) => write!(out, " empty={empty}")?,
                        None => write!(out, " empty=unknown")?,
                    }
                }
            }
            write!(out, "] scan={:?}", summary.stop)?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Varint,
    U32,
    I32,
    Bool,
    Bytes,
    Text,
    Fixed64,
    Message(Schema),
}

impl Kind {
    fn wire(self) -> u64 {
        match self {
            Self::Varint | Self::U32 | Self::I32 | Self::Bool => 0,
            Self::Fixed64 => 1,
            Self::Bytes | Self::Text | Self::Message(_) => 2,
        }
    }
}

/// Closed schema table, not a generic unknown-field skipper.
fn rule(schema: Schema, tag: u64) -> Result<(Kind, bool), PushError> {
    use Kind::*;
    use Schema::*;
    let kind = match (schema, tag) {
        (Response, 1) => U32,
        (Response, 2) => Message(Operation),
        (Response, 3) => Message(Result),
        (Response, 4) => Bytes,
        (Response, 211) => Message(Retrieve),
        (Operation, 1) => Text,
        (Operation, 2) => U32,
        (Operation, 3 | 4) => Bool,
        (Result, 1) => U32,
        (Result, 2) => Message(Error),
        (Error, 1) => Message(ClientError),
        (Error, 2) => Message(ServerError),
        (Error, 3) => I32,
        (Error, 4..=6) => Text,
        (Error, 7) => Message(Extension),
        (ClientError | ServerError, 1) => U32,
        (Extension, 1) => Text,
        (Extension, 2) => U32,
        (Extension, 3) => Bytes,
        (Retrieve, 1) => Message(Record),
        (Retrieve, 2) => Bool,
        (Record, 1 | 11) => Text,
        (Record, 2 | 8) => Message(RecordId), // ShareIdentifier has the same schema.
        (Record, 3) => Message(Name),
        (Record, 4 | 9) => Message(Identifier),
        (Record, 5) => Message(Dates),
        (Record, 7 | 12) => return Ok((Message(Field), true)),
        (Record, 10) => return Ok((Text, true)),
        (Record, 13) => Message(Protection),
        (Record, 15) => U32,
        (Record, 22) => Message(StableUrl),
        (Record, 24) => Bytes,
