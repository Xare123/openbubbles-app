// This is the sole bridge from a successful strict version lookup into staged
// reconciliation. Keep the original fetched bytes; a typed-only fallback
// would erase absent-vs-present-empty field31 and must not claim an outcome.
fn cloud_sync_message_update_classify_fetched_readback<'a>(
    opened: &NativeConditionalMessageUpdate,
    fetched: &'a rustpush::cloudkit::FetchedRecord,
) -> Result<(
    &'a rustpush::cloudkit_proto::Record,
    crate::cloud_sync_message_update_stage::MessageUpdateReadbackState,
), CloudSyncOutboundSafeCode> {
    let remote = fetched
        .get_raw_record()
        .map_err(|_| CloudSyncOutboundSafeCode::MalformedMessage)?;
    let original_wire = fetched
        .original_record_wire()
        .ok_or(CloudSyncOutboundSafeCode::MalformedMessage)?;
    Ok((remote, opened.classify_readback(remote, original_wire)))
}
