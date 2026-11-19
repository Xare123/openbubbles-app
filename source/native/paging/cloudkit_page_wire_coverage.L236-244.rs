#[test]
fn co_final_original_page_payload_limit_also_counts_tokens() {
    for (size,accepted) in [(CLOUDKIT_MAX_RECORD_CHANGE_PAGE_BYTES,true),
        (CLOUDKIT_MAX_RECORD_CHANGE_PAGE_BYTES+1,false)] {
        let page=[co_data(2,&vec![0;size-7]),co_number(4,3)].concat();
        assert_eq!(page.len(),size);
        assert_eq!(received_wire::record_change_page_wires(&co_bound_frame(page)).is_ok(),accepted);
    }
}
