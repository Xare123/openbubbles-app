    #[test]
    fn reconcile_consumer_uses_strict_fetched_original_wire_for_staged_classification() {
        use rustpush::cloudkit::CloudKitOp;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let binding = crate::cloud_sync_received_message_update_stage::ReceivedMessageUpdateBinding {
            logical_entity_key_hash: "L".repeat(43),
            server_record_id_hash: "S".repeat(43),
            predecessor_etag_hash: "E".repeat(43),
            mutation_source_sha256: "a".repeat(64),
            mutation_guid_hash: "b".repeat(64),
            target_guid_hash: "c".repeat(64),
            native_predecessor_proof_sha256: "d".repeat(64),
            reflected_snapshot_sha256: "e".repeat(64),
            auth_binding_sha256: "f".repeat(64),
            writer_epoch: 2,
            raw_generation: 7,
        };
        let (predecessor, request) = crate::cloud_sync_message_update_stage::tests::fixture();
        let present_empty_source = [vec![0xfa, 0x01, 0x00], predecessor.encode_to_vec()].concat();
        let stage = crate::cloud_sync_received_message_update_stage::stage_received_message_update_with_wire(
            path.clone(), account.clone(), binding.clone(), &predecessor, &request,
            Some(&present_empty_source),
        ).unwrap();
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            path.clone(), &stage.lease_reference, std::slice::from_ref(&stage.protected_reference),
        ).unwrap();
        let opened = crate::cloud_sync_received_message_update_stage::open_received_message_update(
            path, account, &binding, &stage,
        ).unwrap();
        let native = NativeConditionalMessageUpdate::Received(opened);

        // A strict synthetic fetch is parsed through the same response-wire
        // operation as the live lookup, but does not open a client or network.
        let absent_fetch = update_fetched_record(&predecessor.encode_to_vec()).unwrap();
        assert!(absent_fetch.original_record_wire().is_some());
        assert!(absent_fetch.original_wire_admission().is_none(),
            "fixture isolates the API's raw-wire consumer; lookup admission is separately enforced upstream");
        let (_, state) = cloud_sync_message_update_classify_fetched_readback(&native, &absent_fetch).unwrap();
        assert_eq!(state, crate::cloud_sync_message_update_stage::MessageUpdateReadbackState::Diverged,
            "typed Record equality must not erase absent-vs-present-empty31");

        let reordered_equal = [predecessor.encode_to_vec(), vec![0xfa, 0x01, 0x00]].concat();
        let equal_fetch = update_fetched_record(&reordered_equal).unwrap();
        let (_, state) = cloud_sync_message_update_classify_fetched_readback(&native, &equal_fetch).unwrap();
        assert_eq!(state, crate::cloud_sync_message_update_stage::MessageUpdateReadbackState::NotApplied,
            "known equal field31 presence survives benign outer-field reordering");

        let mut committed = predecessor.clone();
        committed.etag = Some("synthetic-api-committed-etag".into());
        committed.record_field[0] = request.record.as_ref().unwrap().record_field[0].clone();
        let committed_wire = [committed.encode_to_vec(), vec![0xfa, 0x01, 0x00]].concat();
        let committed_fetch = update_fetched_record(&committed_wire).unwrap();
        let (_, state) = cloud_sync_message_update_classify_fetched_readback(&native, &committed_fetch).unwrap();
        assert_eq!(state, crate::cloud_sync_message_update_stage::MessageUpdateReadbackState::Committed,
            "the witnessed production outcome is preserved when the fetched wire agrees");

        for forbidden in [
            [predecessor.encode_to_vec(), vec![0x8a, 0x02, 0x00]].concat(), // field33
            [predecessor.encode_to_vec(), vec![0xfa, 0x01, 0x02, 0x08, 0x00]].concat(), // nonempty31
            [predecessor.encode_to_vec(), vec![0xf8, 0x01, 0x00]].concat(), // wrong31 wire type
            [predecessor.encode_to_vec(), vec![0xfa, 0x01]].concat(), // truncated31
        ] {
            assert!(update_fetched_record(&forbidden).is_none(),
                "strict fetch parser must refuse malformed/unsupported metadata before reconciliation");
        }

        let typed_response = rustpush::cloudkit_proto::ResponseOperation {
            record_retrieve_response: Some(rustpush::cloudkit_proto::RecordRetrieveResponse {
                record: Some(predecessor), ..Default::default()
            }),
            ..Default::default()
        };
        let typed_only = rustpush::cloudkit::FetchRecordOperation::retrieve_response(&typed_response).unwrap();
        assert!(matches!(
            cloud_sync_message_update_classify_fetched_readback(&native, &typed_only),
            Err(CloudSyncOutboundSafeCode::MalformedMessage),
        ), "a typed-only fetch cannot substitute for exact original wire");
    }
