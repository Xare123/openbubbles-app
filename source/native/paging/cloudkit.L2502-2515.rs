fn validate_original_change_pair(change: &RecordChange, raw: Option<&[u8]>) -> Result<(), PushError> {
    match (&change.record, raw) {
        (Some(typed), Some(raw)) if Record::decode(raw)? == *typed => {},
        (None, None) => {},
        _ => return Err(PushError::BadMsg),
    }
    if let Some(record) = change.record.as_ref() {
        if record.record_identifier.as_ref().is_some_and(|inner| Some(inner) != change.identifier.as_ref())
            || record.etag.as_ref().is_some_and(|etag| Some(etag) != change.etag.as_ref())
            || change.record_type.as_ref().is_some_and(|kind| Some(kind) != record.r#type.as_ref())
        { return Err(PushError::BadMsg); }
    }
    Ok(())
}
