pub struct CloudKitRecordChangePage {
    pub assets: Vec<AssetGetResponse>,
    pub changes: Vec<RecordChange>,
    pub next_token: Option<Vec<u8>>,
    pub status: i32,
    // Private, one-to-one with changes. Lookup-only V2 pages require original
    // bytes; ordinary legacy paging does not supply this evidence.
    original_record_wires: Option<Vec<Option<Vec<u8>>>>,
}
