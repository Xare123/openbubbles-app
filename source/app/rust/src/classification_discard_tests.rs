//! Disconnected synthetic-only adapter. No production entry, fetch, or storage.
//! Extension inputs are already-decrypted synthetic values, NOT metadata-only.
use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, PartialEq, Eq)]
enum Refusal { Cancelled, Malformed, Unsupported, Budget }
#[derive(Debug, PartialEq, Eq)]
struct Counts { outer: [u32; 8], extension: [u32; 6] }

// No source/record/value can escape; errors are closed and content-free.
fn classify(record: &Record, provider: Option<&str>, payload: Option<&[u8]>,
            cancelled: &AtomicBool) -> Result<Counts, Refusal> {
    classify_with_pre_final_cancel_hook(record, provider, payload, cancelled, || {})
}

// Test-adapter-only hook, positioned after all predicates have completed and
// counts exist, immediately before the existing final cancellation check.
fn classify_with_pre_final_cancel_hook<F>(
    record: &Record,
    provider: Option<&str>,
    payload: Option<&[u8]>,
    cancelled: &AtomicBool,
    before_final_cancel_check: F,
) -> Result<Counts, Refusal>
where
    F: FnOnce(),
{
    if cancelled.load(Ordering::Acquire) { return Err(Refusal::Cancelled); }
    if provider.is_some_and(|s| s.len() > 512) || payload.is_some_and(|b| b.len() > 4096) {
        return Err(Refusal::Budget);
    }
    // Must precede first-match msgType predicate: rejects identical/conflicting
    // duplicates and invalid field identifiers with the real shared validator.
    let presence = CloudRawRecordPresence::extract(record).map_err(|_| Refusal::Malformed)?;
    let _ = message_required_presence_masks(&presence);
    let index = match message_outer_type_class(record) {
        "class_0" => 0, "class_1" => 1, "class_2" => 2, "class_3" => 3,
        "class_4" => 4, "class_5" => 5, "class_6" => 6, "class_7" => 7,
        "unsupported" => return Err(Refusal::Unsupported),
        _ => return Err(Refusal::Malformed),
    };
    let ext = match message_extension_class(provider, payload) {
        "no_payload" => 0, "empty_payload" => 1, "url_balloon" => 2,
        "apple_other" => 3, "other_provider" => 4, "provider_absent" => 5,
        _ => return Err(Refusal::Unsupported),
    };
    let mut counts = Counts { outer: [0; 8], extension: [0; 6] };
    counts.outer[index] = 1;
    counts.extension[ext] = 1;
    before_final_cancel_check();
    if cancelled.load(Ordering::Acquire) { return Err(Refusal::Cancelled); }
    Ok(counts)
}

// Synthetic wire boundary only. The real decoder validates wire budgets and
// timestamp shape. Decoded Record remains local and is dropped on every return.
fn classify_wire(raw: &[u8], cancel: &AtomicBool) -> Result<Counts, Refusal> {
    if cancel.load(Ordering::Acquire) { return Err(Refusal::Cancelled); }
    if raw.len() > 8192 { return Err(Refusal::Budget); }
    let record = decode_projection_record(raw).map_err(|_| Refusal::Malformed)?;
    classify(&record, None, None, cancel)
}

fn field(name: &str, value: Value) -> Field {
    Field { identifier: Some(rustpush::cloudkit_proto::record::field::Identifier {
        name: Some(name.to_owned()) }), value: Some(value) }
}
fn record(kind: i64) -> Record {
    Record { record_field: vec![field("msgType", Value {
        r#type: Some(FieldValueType::Int64Type as i32), signed_value: Some(kind),
        ..Default::default() })], ..Default::default() }
}

#[test]
fn duplicate_same_and_conflicting_types_refuse() {
    for kind in [2, 3] {
        let mut r = record(2);
        r.record_field.push(record(kind).record_field.remove(0));
        assert_eq!(classify(&r, None, None, &AtomicBool::new(false)), Err(Refusal::Malformed));
    }
}

#[test]
fn malformed_identifiers_and_type_shape_refuse() {
    let mut r = record(0);
    r.record_field.push(field("", Value::default()));
    assert_eq!(classify(&r, None, None, &AtomicBool::new(false)), Err(Refusal::Malformed));
    let mut r = record(0);
    r.record_field[0].value.as_mut().unwrap().string_value = Some("SYNTHETIC_SECRET".into());
    assert_eq!(classify(&r, None, None, &AtomicBool::new(false)), Err(Refusal::Malformed));
}

#[test]
fn truncated_wire_and_oversize_refuse() {
    for raw in [&[0x80][..], &[0x0a, 0x7f, 0x01][..]] {
        assert_eq!(classify_wire(raw, &AtomicBool::new(false)), Err(Refusal::Malformed));
    }
    assert_eq!(classify_wire(&vec![0; 8193], &AtomicBool::new(false)), Err(Refusal::Budget));
}

#[test]
fn borrowed_canaries_never_appear_in_closed_output() {
    let canary = "SYNTHETIC_BODY_PROVIDER_ID_CANARY";
    let mut r = record(2);
    for name in ["body", "guid", "sender", "chatID"] {
        r.record_field.push(field(name, Value { r#type: Some(FieldValueType::StringType as i32),
            string_value: Some(canary.into()), ..Default::default() }));
    }
    let counts = classify(&r, Some(canary), Some(canary.as_bytes()), &AtomicBool::new(false)).unwrap();
    assert_eq!(counts.outer, [0, 0, 1, 0, 0, 0, 0, 0]);
    assert_eq!(counts.extension, [0, 0, 0, 0, 1, 0]);
    assert!(!format!("{counts:?}").contains(canary));
    // Borrowing intentionally leaves caller's synthetic input intact. This is
    // not a zeroization or original-deletion mechanism.
    assert_eq!(r.record_field[1].value.as_ref().unwrap().string_value.as_deref(), Some(canary));
}

#[test]
fn cancellation_and_errors_have_no_partial_counts() {
    let cancelled = AtomicBool::new(true);
    assert_eq!(classify(&record(0), None, None, &cancelled), Err(Refusal::Cancelled));
    assert_eq!(classify_wire(&[0x80], &cancelled), Err(Refusal::Cancelled));
    assert_eq!(classify(&record(99), None, None, &AtomicBool::new(false)), Err(Refusal::Unsupported));
    assert_eq!(classify(&record(0), Some(&"x".repeat(513)), None, &AtomicBool::new(false)), Err(Refusal::Budget));
}

#[test]
fn valid_wire_uses_actual_decode_and_presence_boundary() {
    let raw = record(1).encode_to_vec();
    assert_eq!(classify_wire(&raw, &AtomicBool::new(false)).unwrap().outer, [0, 1, 0, 0, 0, 0, 0, 0]);
}

// A bounded test-only worker that pauses at the final cancellation boundary.
// Drop always releases and joins, including when an assertion panics.
struct PostWorkWorker {
    entered: std::sync::mpsc::Receiver<()>,
    release: Option<std::sync::mpsc::SyncSender<()>>,
    result: std::sync::mpsc::Receiver<(Result<Counts, Refusal>, Record)>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl PostWorkWorker {
    fn release_and_join(&mut self) -> std::thread::Result<()> {
        if let Some(release) = self.release.take() {
            let _ = release.send(());
        }
        self.join.take().expect("worker handle is present").join()
    }
}

impl Drop for PostWorkWorker {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            let _ = release.send(());
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn spawn_post_work_worker(input: Record, cancelled: std::sync::Arc<AtomicBool>) -> PostWorkWorker {
    use std::sync::mpsc;

    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let (result_tx, result_rx) = mpsc::sync_channel(1);
    let join = std::thread::spawn(move || {
        let result = classify_with_pre_final_cancel_hook(
            &input,
            None,
            None,
            &cancelled,
            || {
                entered_tx.send(()).expect("test is waiting at post-work hook");
                release_rx.recv().expect("RAII guard releases post-work hook");
            },
        );
        result_tx
            .send((result, input))
            .expect("test keeps result receiver until worker joins");
    });

    PostWorkWorker {
        entered: entered_rx,
        release: Some(release_tx),
        result: result_rx,
        join: Some(join),
    }
}

#[test]
fn post_work_cancellation_suppresses_counts_and_preserves_input() {
    use std::sync::Arc;
    use std::time::Duration;

    let input = record(2);
    let caller_input = input.clone();
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut worker = spawn_post_work_worker(input, Arc::clone(&cancelled));
    worker
        .entered
        .recv_timeout(Duration::from_secs(1))
        .expect("actual classifier reached post-work hook");

    cancelled.store(true, Ordering::Release);
    worker.release_and_join().expect("worker completed and joined");
    let (result, observed_input) = worker
        .result
        .recv_timeout(Duration::from_secs(1))
        .expect("joined worker returned closed result and synthetic input");
    assert_eq!(result, Err(Refusal::Cancelled));
    assert_eq!(observed_input, caller_input);
}

#[test]
fn post_work_timeout_cancels_suppresses_counts_and_joins() {
    use std::sync::Arc;
    use std::time::Duration;

    let input = record(3);
    let caller_input = input.clone();
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut worker = spawn_post_work_worker(input, Arc::clone(&cancelled));
    worker
        .entered
        .recv_timeout(Duration::from_secs(1))
        .expect("actual classifier reached post-work hook");
    assert!(matches!(
        worker.result.recv_timeout(Duration::from_millis(25)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    ));

    cancelled.store(true, Ordering::Release);
    worker.release_and_join().expect("timed-out worker completed and joined");
    let (result, observed_input) = worker
        .result
        .recv_timeout(Duration::from_secs(1))
        .expect("joined worker returned closed result and synthetic input");
    assert_eq!(result, Err(Refusal::Cancelled));
    assert_eq!(observed_input, caller_input);
}
