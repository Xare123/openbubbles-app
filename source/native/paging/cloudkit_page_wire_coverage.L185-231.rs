fn co_bound_frame(page: Vec<u8>) -> Vec<u8> {
    let operation=cloudkit_proto::Operation { operation_uuid:Some(OPERATION_UUID_A.into()),
        r#type:Some(213),..Default::default() };
    [co_data(2,&operation.encode_to_vec()),co_data(3,&co_number(1,1)),co_data(213,&page)].concat()
}
fn co_large_change(size: usize) -> Vec<u8> {
    let mut fill=size.saturating_sub(12);
    loop {
        let change=co_data(5,&co_data(1000,&vec![0;fill]));
        if change.len()==size{return change;}
        if change.len()<size{fill+=size-change.len();}else{fill-=change.len()-size;}
    }
}
#[test]
fn co_extra_original_byte_limits_allow_multi_record_page_above_single_record_limit() {
    let quarter=CLOUDKIT_MAX_RECORD_CHANGE_PAGE_BYTES/4-256;
    let change=co_large_change(quarter);
    let mut page=co_data(1,&change).repeat(4);page.extend(co_number(4,3));
    assert!(page.len()>CLOUDKIT_MAX_RECORD_CHANGE_BYTES);
    assert_eq!(received_wire::record_change_page_wires(&co_bound_frame(page)).unwrap().len(),4);
    // Raw change accounting at the exact existing24MiB aggregate cap, then1B over.
    let mut page=co_data(1,&co_large_change(quarter+1));
    page.extend(co_data(1,&change).repeat(3));page.extend(co_number(4,3));
    assert!(received_wire::record_change_page_wires(&co_bound_frame(page)).is_err());
    for (size,accepted) in [(CLOUDKIT_MAX_RECORD_CHANGE_BYTES,true),(CLOUDKIT_MAX_RECORD_CHANGE_BYTES+1,false)] {
        let page=[co_data(1,&co_large_change(size)),co_number(4,3)].concat();
        assert_eq!(received_wire::record_change_page_wires(&co_bound_frame(page)).is_ok(),accepted);
    }
}
#[test]
fn co_extra_original_page_count_and_shared_work_boundaries_are_closed() {
    for (count,accepted) in [(200,true),(201,false)] {
        let page=[co_data(1,&co_data(5,&[])).repeat(count),co_number(4,3)].concat();
        assert_eq!(received_wire::record_change_page_wires(&co_bound_frame(page)).is_ok(),accepted);
    }
    // Frame+operation+result+page wrappers consume40 visits for16records;
    // distribute the remaining shared1Mi visits within existing64Ki/Record.
    for (extra,accepted) in [(0,true),(1,false)] {
        let mut page=Vec::new();
        for index in 0..16 {
            let count=if index<15{65536}else{65496+extra};
            page.extend(co_data(1,&co_data(5,&co_number(1000,1).repeat(count))));
        }
        page.extend(co_number(4,3));
        assert_eq!(received_wire::record_change_page_wires(&co_bound_frame(page)).is_ok(),accepted);
    }
}
