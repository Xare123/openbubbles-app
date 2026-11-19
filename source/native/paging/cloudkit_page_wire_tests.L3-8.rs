fn co_data(tag: u64, bytes: &[u8]) -> Vec<u8> {
    [encode_uleb128((tag << 3) | 2), encode_uleb128(bytes.len() as u64), bytes.to_vec()].concat()
}
fn co_number(tag: u64, value: u64) -> Vec<u8> {
    [encode_uleb128(tag << 3), encode_uleb128(value)].concat()
}
