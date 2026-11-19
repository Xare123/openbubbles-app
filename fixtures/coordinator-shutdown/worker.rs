//! Disconnected owned-input worker prototype. This module has no acquisition,
//! parsing, decryption, persistence, logging, FRB, or projection dependencies.
//! It is intentionally not wired into the application.

use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const MAX_INPUT_BYTES: usize = 64 * 1024;
const SCAN_CHUNK_BYTES: usize = 256;

/// Fixed, content-free result. No input bytes, names, strings, or parsed
/// structures are representable here.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ByteClass {
    Empty,
    AsciiOnly,
    ContainsNonAscii,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Summary {
    class: ByteClass,
    byte_count: u32,
}

/// Deliberately closed errors: no inner error or source-derived text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkerError {
    Cancelled,
    Deadline,
    InputTooLarge,
    OutputClosed,
    WorkerPanicked,
    WorkerStartFailed,
    #[cfg(test)]
    InputDropCheckpointMissing,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkerResult {
    Complete(Summary),
    Failed(WorkerError),
}

#[derive(Clone, Default)]
struct Cancellation(Arc<AtomicBool>);

impl Cancellation {
    fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

/// Owns exactly one bounded input. The only constructor is test-only in this
/// candidate, so no production path can supply acquired data.
struct OwnedSyntheticInput {
    bytes: Vec<u8>,
    #[cfg(test)]
    drop_witness: Option<Arc<AtomicBool>>,
}

impl OwnedSyntheticInput {
    #[cfg(test)]
    fn new(bytes: Vec<u8>, drop_witness: Option<Arc<AtomicBool>>) -> Self {
        Self { bytes, drop_witness }
    }
}

impl Drop for OwnedSyntheticInput {
    fn drop(&mut self) {
        // Release the Vec before raising the test-only drop witness. This is
        // allocator release, not secure zeroization.
        drop(std::mem::take(&mut self.bytes));
        #[cfg(test)]
        if let Some(witness) = &self.drop_witness {
            witness.store(true, Ordering::Release);
        }
    }
}

struct WorkerJob {
    receiver: Option<Receiver<WorkerResult>>,
    join: Option<JoinHandle<()>>,
    cancel: Cancellation,
    deadline: Instant,
    #[cfg(test)]
    drop_checkpoint: Option<Receiver<()>>,
}

impl WorkerJob {
    fn start(
        input: OwnedSyntheticInput,
        cancel: Cancellation,
        deadline: Instant,
        #[cfg(test)] hook: Option<TestHook>,
    ) -> Result<Self, WorkerError> {
        #[cfg(test)]
        {
            Self::start_inner(input, cancel, deadline, hook, None, None, None)
        }
        #[cfg(not(test))]
        {
            Self::start_inner(input, cancel, deadline)
        }
    }

    #[cfg(test)]
    fn start_for_async_owner_test(
        input: OwnedSyntheticInput,
        cancel: Cancellation,
        deadline: Instant,
        hook: TestHook,
    ) -> Result<(Self, Arc<AsyncCompletion>), WorkerError> {
        let completion = Arc::new(AsyncCompletion::default());
        let job = Self::start_inner(
            input,
            cancel,
            deadline,
            Some(hook),
            Some(completion.clone()),
            None,
            None,
        )?;
        Ok((job, completion))
    }

    #[cfg(test)]
    fn start_for_coordinator_test(
        input: OwnedSyntheticInput,
        cancel: Cancellation,
        deadline: Instant,
        gate: Option<CoordinatorTestGate>,
    ) -> Result<(Self, Arc<AsyncCompletion>, Receiver<()>), WorkerError> {
        let completion = Arc::new(AsyncCompletion::default());
        let (done_sender, done_receiver) = mpsc::sync_channel(1);
        let job = Self::start_inner(
            input,
            cancel,
            deadline,
            None,
            Some(completion.clone()),
            gate,
            Some(done_sender),
        )?;
        Ok((job, completion, done_receiver))
    }

    fn start_inner(
        input: OwnedSyntheticInput,
        cancel: Cancellation,
        deadline: Instant,
        #[cfg(test)] hook: Option<TestHook>,
        #[cfg(test)] completion: Option<Arc<AsyncCompletion>>,
        #[cfg(test)] coordinator_gate: Option<CoordinatorTestGate>,
        #[cfg(test)] done_sender: Option<mpsc::SyncSender<()>>,
    ) -> Result<Self, WorkerError> {
        if input.bytes.len() > MAX_INPUT_BYTES {
            drop(input);
            return Err(WorkerError::InputTooLarge);
        }
        if cancel.is_cancelled() {
            drop(input);
            return Err(WorkerError::Cancelled);
        }

        let (sender, receiver) = mpsc::sync_channel(1);
        #[cfg(test)]
        let (drop_checkpoint_sender, drop_checkpoint_receiver) = mpsc::sync_channel(1);
        let worker_cancel = cancel.clone();
        let thread_builder = thread::Builder::new().name("synthetic-owned-worker".to_owned());
        let join = thread_builder
            .spawn(move || {
                #[cfg(test)]
                if let Some(gate) = coordinator_gate.as_ref() {
                    gate.pause();
                }
                let result = classify_then_discard(
                    input,
                    &worker_cancel,
                    deadline,
                    #[cfg(test)] hook.as_ref(),
                );
                #[cfg(test)]
                let _ = drop_checkpoint_sender.send(());
                // classify_then_discard drops the owned input before this
                // test-only checkpoint and before output. Only a fixed
                // summary/error crosses the output channel.
                let _ = sender.send(result);
                #[cfg(test)]
                if let Some(completion) = completion {
                    completion.signal();
                }
                #[cfg(test)]
                if let Some(done_sender) = done_sender {
                    let _ = done_sender.send(());
                }
            })
            .map_err(|_| WorkerError::WorkerStartFailed)?;
        Ok(Self {
            receiver: Some(receiver),
            join: Some(join),
            cancel,
            deadline,
            #[cfg(test)]
            drop_checkpoint: Some(drop_checkpoint_receiver),
        })
    }

    /// Receive if possible, request cancellation on deadline, and always join
    /// the worker before returning. This does not promise a hard wall-clock
    /// bound if the OS does not schedule the worker.
    fn finish(mut self) -> WorkerResult {
        let (received, no_output_error) = match self.receiver.take() {
            Some(receiver) => {
                let remaining = self.deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    (None, WorkerError::Deadline)
                } else {
                    match receiver.recv_timeout(remaining) {
                        Ok(result) => (Some(result), WorkerError::OutputClosed),
                        Err(mpsc::RecvTimeoutError::Timeout) => (None, WorkerError::Deadline),
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            (None, WorkerError::OutputClosed)
                        }
                    }
                }
            }
            None => (None, WorkerError::OutputClosed),
        };

        if received.is_none() {
            self.cancel.cancel();
        }
        let joined = self.join.take().map(|join| join.join()).unwrap_or(Ok(()));
        if joined.is_err() {
            // `join` reports a fixed value only. The process panic hook may
            // already have run; this module does not alter the global hook.
            return WorkerResult::Failed(WorkerError::WorkerPanicked);
        }
        #[cfg(test)]
        if self
            .drop_checkpoint
            .take()
            .is_none_or(|checkpoint| checkpoint.try_recv().is_err())
        {
            return WorkerResult::Failed(WorkerError::InputDropCheckpointMissing);
        }
        match received {
            Some(result) => result,
            None => WorkerResult::Failed(no_output_error),
        }
    }

    #[cfg(test)]
    fn disconnect_output_for_test(&mut self) {
        drop(self.receiver.take());
    }
}

impl Drop for WorkerJob {
    fn drop(&mut self) {
        // Never detach a worker, including when a caller abandons the job.
        self.cancel.cancel();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

const MAX_COORDINATED_JOBS: usize = 1;

struct SupervisedJob {
    job: WorkerJob,
    caller_abandoned: Arc<AtomicBool>,
    #[cfg(test)] gate_release: Option<mpsc::SyncSender<()>>,
}

/// A caller-side cancellation lease. Dropping it only marks abandonment and
/// signals cancellation; it never owns or joins the worker handle.
struct CallerLease {
    cancel: Cancellation,
    caller_abandoned: Arc<AtomicBool>,
}

impl Drop for CallerLease {
    fn drop(&mut self) {
        self.caller_abandoned.store(true, Ordering::Release);
        self.cancel.cancel();
    }
}

/// A bounded, explicit owner for worker jobs. The caller can abandon its
/// future, but this coordinator retains each join handle until `drain` or its
/// own Drop path joins it. One job is permitted to keep the ownership bound
/// concrete in this candidate.
struct WorkerCoordinator {
    jobs: Vec<SupervisedJob>,
}

impl WorkerCoordinator {
    fn new() -> Self {
        Self { jobs: Vec::new() }
    }

    fn supervise(&mut self, job: WorkerJob) -> Result<CallerLease, WorkerJob> {
        #[cfg(test)]
        {
            self.supervise_inner(job, None)
        }
        #[cfg(not(test))]
        {
            self.supervise_inner(job)
        }
    }

    fn supervise_inner(
        &mut self,
        job: WorkerJob,
        #[cfg(test)] gate_release: Option<mpsc::SyncSender<()>>,
    ) -> Result<CallerLease, WorkerJob> {
        if self.jobs.len() >= MAX_COORDINATED_JOBS {
            return Err(job);
        }
        let caller_abandoned = Arc::new(AtomicBool::new(false));
        let lease = CallerLease {
            cancel: job.cancel.clone(),
            caller_abandoned: caller_abandoned.clone(),
        };
        self.jobs.push(SupervisedJob {
            job,
            caller_abandoned,
            #[cfg(test)]
            gate_release,
        });
        Ok(lease)
    }

    /// Collect results and join every supervised worker before returning.
    /// Results from callers that abandoned before drain are collapsed to the
    /// fixed Cancelled refusal, including a Complete already queued internally.
    fn drain(&mut self) -> Vec<WorkerResult> {
        #[cfg(test)]
        for managed in &mut self.jobs {
            if let Some(release) = managed.gate_release.take() {
                let _ = release.try_send(());
            }
        }

        let jobs = std::mem::take(&mut self.jobs);
        jobs.into_iter()
            .map(|managed| {
                let result = managed.job.finish();
                if managed.caller_abandoned.load(Ordering::Acquire) {
                    match result {
                        WorkerResult::Complete(_) => {
                            WorkerResult::Failed(WorkerError::Cancelled)
                        }
                        refusal => refusal,
                    }
                } else {
                    result
                }
            })
            .collect()
    }
}

impl Drop for WorkerCoordinator {
    fn drop(&mut self) {
        // Shutdown fallback never detaches a worker. It is synchronous and may
        // block this owner thread while cooperative work observes cancellation.
        for managed in &self.jobs {
            managed.job.cancel.cancel();
        }
        #[cfg(test)]
        for managed in &mut self.jobs {
            if let Some(release) = managed.gate_release.take() {
                let _ = release.try_send(());
            }
        }
        // Dropping the retained WorkerJobs synchronously joins their threads.
        self.jobs.clear();
    }
}

fn classify_then_discard(
    input: OwnedSyntheticInput,
    cancel: &Cancellation,
    deadline: Instant,
    #[cfg(test)] hook: Option<&TestHook>,
) -> WorkerResult {
    let bytes = &input.bytes;
    let mut contains_non_ascii = false;

    if Instant::now() >= deadline {
        drop(input);
        return WorkerResult::Failed(WorkerError::Deadline);
    }
    if cancel.is_cancelled() {
        drop(input);
        return WorkerResult::Failed(WorkerError::Cancelled);
    }

    for (chunk_index, chunk) in bytes.chunks(SCAN_CHUNK_BYTES).enumerate() {
        if cancel.is_cancelled() {
            drop(input);
            return WorkerResult::Failed(WorkerError::Cancelled);
        }
        if Instant::now() >= deadline {
            drop(input);
            return WorkerResult::Failed(WorkerError::Deadline);
        }
        contains_non_ascii |= chunk.iter().any(|byte| !byte.is_ascii());
        #[cfg(test)]
        if chunk_index == 0 {
            if let Some(hook) = hook {
                hook.pause_after_first_chunk();
            }
        }
    }

    // Completion is linearized at this last cooperative check. Cancellation
    // racing after it cannot retract a result already being sent.
    if cancel.is_cancelled() {
        drop(input);
        return WorkerResult::Failed(WorkerError::Cancelled);
    }
    if Instant::now() >= deadline {
        drop(input);
        return WorkerResult::Failed(WorkerError::Deadline);
    }

    let summary = Summary {
        class: if bytes.is_empty() {
            ByteClass::Empty
        } else if contains_non_ascii {
            ByteClass::ContainsNonAscii
        } else {
            ByteClass::AsciiOnly
        },
        byte_count: bytes.len() as u32,
    };
    drop(input);
    WorkerResult::Complete(summary)
}

#[cfg(test)]
#[derive(Clone)]
struct TestHook {
    reached: mpsc::SyncSender<()>,
    release: Arc<std::sync::Mutex<Receiver<()>>>,
    panic_after_first_chunk: bool,
}

#[cfg(test)]
impl TestHook {
    fn pause_after_first_chunk(&self) {
        let _ = self.reached.send(());
        if self.panic_after_first_chunk {
            panic!("static synthetic worker panic test");
        }
        if let Ok(receiver) = self.release.lock() {
            let _ = receiver.recv_timeout(Duration::from_secs(1));
        }
    }
}

#[cfg(test)]
struct CoordinatorTestGate {
    entered: mpsc::SyncSender<()>,
    exited: mpsc::SyncSender<()>,
    release: Arc<std::sync::Mutex<Receiver<()>>>,
}

#[cfg(test)]
impl CoordinatorTestGate {
    fn pause(&self) {
        let _ = self.entered.send(());
        if let Ok(receiver) = self.release.lock() {
            let _ = receiver.recv_timeout(Duration::from_secs(2));
        }
        let _ = self.exited.send(());
    }
}

#[cfg(test)]
#[derive(Default)]
struct AsyncCompletion {
    complete: AtomicBool,
    waker: std::sync::Mutex<Option<std::task::Waker>>,
}

#[cfg(test)]
impl AsyncCompletion {
    fn signal(&self) {
        self.complete.store(true, Ordering::Release);
        let waker = match self.waker.lock() {
            Ok(mut slot) => slot.take(),
            Err(_) => None,
        };
        // Wake outside the mutex: a custom/reentrant waker must not run while
        // this adapter's lock is held.
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    fn is_complete(&self) -> bool {
        self.complete.load(Ordering::Acquire)
    }

    fn poll_complete(&self, context: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        if self.is_complete() {
            return std::task::Poll::Ready(());
        }
        if let Ok(mut slot) = self.waker.lock() {
            *slot = Some(context.waker().clone());
        }
        if self.is_complete() {
            std::task::Poll::Ready(())
        } else {
            std::task::Poll::Pending
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        future::{poll_fn, Future},
        sync::{atomic::AtomicBool, Arc, Mutex},
        task::{Context, Poll, Wake, Waker},
    };

    struct NoopWake;

    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}

        fn wake_by_ref(self: &Arc<Self>) {}
    }

    fn input(bytes: &[u8], witness: &Arc<AtomicBool>) -> OwnedSyntheticInput {
        OwnedSyntheticInput::new(bytes.to_vec(), Some(witness.clone()))
    }

    fn deadline_after(duration: Duration) -> Instant {
        Instant::now() + duration
    }

    #[test]
    fn success_drops_owned_input_before_content_free_output() {
        let dropped = Arc::new(AtomicBool::new(false));
        let job = WorkerJob::start(
            input(b"synthetic-only", &dropped),
            Cancellation::default(),
            deadline_after(Duration::from_secs(2)),
            None,
        )
        .unwrap();
        let output = job.finish();
        assert_eq!(
            output,
            WorkerResult::Complete(Summary {
                class: ByteClass::AsciiOnly,
                byte_count: b"synthetic-only".len() as u32,
            })
        );
        assert!(dropped.load(Ordering::Acquire));
        assert!(!format!("{output:?}").contains("synthetic-only"));
    }

    #[test]
    fn empty_and_non_ascii_inputs_return_only_fixed_classes() {
        for (bytes, expected, count) in [
            (&b""[..], ByteClass::Empty, 0),
            (&[0xff, 0x00][..], ByteClass::ContainsNonAscii, 2),
        ] {
            let dropped = Arc::new(AtomicBool::new(false));
            let job = WorkerJob::start(
                input(bytes, &dropped),
                Cancellation::default(),
                deadline_after(Duration::from_secs(2)),
                None,
            )
            .unwrap();
            assert_eq!(
                job.finish(),
                WorkerResult::Complete(Summary {
                    class: expected,
                    byte_count: count,
                })
            );
            assert!(dropped.load(Ordering::Acquire));
        }
    }

    #[test]
    fn precancel_drops_input_without_spawning_work() {
        let dropped = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        cancel.cancel();
        assert_eq!(
            WorkerJob::start(
                input(b"sentinel-never-return", &dropped),
                cancel,
                deadline_after(Duration::from_secs(2)),
                None,
            )
            .err().unwrap(),
            WorkerError::Cancelled
        );
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn cancellation_after_first_chunk_is_cooperative_and_joined() {
        let dropped = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        let (reached_tx, reached_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let hook = TestHook {
            reached: reached_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
            panic_after_first_chunk: false,
        };
        let job = WorkerJob::start(
            input(&vec![b'x'; 1024], &dropped),
            cancel.clone(),
            deadline_after(Duration::from_secs(2)),
            Some(hook),
        )
        .unwrap();
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        cancel.cancel();
        release_tx.send(()).unwrap();
        assert_eq!(job.finish(), WorkerResult::Failed(WorkerError::Cancelled));
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn cancellation_at_final_check_prevents_success() {
        let dropped = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        let (reached_tx, reached_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let hook = TestHook {
            reached: reached_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
            panic_after_first_chunk: false,
        };
        let job = WorkerJob::start(
            input(b"one-chunk", &dropped),
            cancel.clone(),
            deadline_after(Duration::from_secs(2)),
            Some(hook),
        )
        .unwrap();
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        cancel.cancel();
        release_tx.send(()).unwrap();
        assert_eq!(job.finish(), WorkerResult::Failed(WorkerError::Cancelled));
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn expired_deadline_returns_fixed_timeout_after_join() {
        let dropped = Arc::new(AtomicBool::new(false));
        let job = WorkerJob::start(
            input(&vec![b'y'; 1024], &dropped),
            Cancellation::default(),
            Instant::now() - Duration::from_millis(1),
            None,
        )
        .unwrap();
        assert_eq!(job.finish(), WorkerResult::Failed(WorkerError::Deadline));
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn deadline_after_first_chunk_cancels_and_joins() {
        let dropped = Arc::new(AtomicBool::new(false));
        let (reached_tx, reached_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let hook = TestHook {
            reached: reached_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
            panic_after_first_chunk: false,
        };
        let job = WorkerJob::start(
            input(b"one-chunk", &dropped),
            Cancellation::default(),
            deadline_after(Duration::from_millis(250)),
            Some(hook),
        )
        .unwrap();
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        thread::sleep(Duration::from_millis(300));
        release_tx.send(()).unwrap();
        assert_eq!(job.finish(), WorkerResult::Failed(WorkerError::Deadline));
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn over_limit_input_is_dropped_without_scanning() {
        let dropped = Arc::new(AtomicBool::new(false));
        assert_eq!(
            WorkerJob::start(
                input(&vec![b'z'; MAX_INPUT_BYTES + 1], &dropped),
                Cancellation::default(),
                deadline_after(Duration::from_secs(2)),
                None,
            )
            .err().unwrap(),
            WorkerError::InputTooLarge
        );
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn closed_output_is_fixed_error_and_worker_still_joins() {
        let dropped = Arc::new(AtomicBool::new(false));
        let mut job = WorkerJob::start(
            input(b"closed-output-sentinel", &dropped),
            Cancellation::default(),
            deadline_after(Duration::from_secs(2)),
            None,
        )
        .unwrap();
        job.disconnect_output_for_test();
        assert_eq!(job.finish(), WorkerResult::Failed(WorkerError::OutputClosed));
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn unexpected_worker_panic_joins_and_maps_without_payload_formatting() {
        let dropped = Arc::new(AtomicBool::new(false));
        let (reached_tx, reached_rx) = mpsc::sync_channel(1);
        let (_release_tx, release_rx) = mpsc::sync_channel(1);
        let hook = TestHook {
            reached: reached_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
            panic_after_first_chunk: true,
        };
        let job = WorkerJob::start(
            input(b"synthetic panic test only", &dropped),
            Cancellation::default(),
            deadline_after(Duration::from_secs(2)),
            Some(hook),
        )
        .unwrap();
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let output = job.finish();
        assert_eq!(output, WorkerResult::Failed(WorkerError::WorkerPanicked));
        assert!(dropped.load(Ordering::Acquire));
        assert!(!format!("{output:?}").contains("synthetic panic test only"));
    }

    #[test]
    fn abandoning_job_cancels_and_joins_in_drop() {
        let dropped = Arc::new(AtomicBool::new(false));
        let job = WorkerJob::start(
            input(&vec![b'w'; 4096], &dropped),
            Cancellation::default(),
            deadline_after(Duration::from_secs(2)),
            None,
        )
        .unwrap();
        drop(job);
        assert!(dropped.load(Ordering::Acquire));
    }

    async fn wait_for_worker_completion(
        job: WorkerJob,
        receiver_observer: Arc<Mutex<Receiver<WorkerResult>>>,
        completion: Arc<AsyncCompletion>,
        future_completed: Arc<AtomicBool>,
    ) {
        // Both values are deliberately used after the await, so the pending
        // future owns the job and observation handle across suspension.
        let owner = (job, receiver_observer);
        poll_fn(|context| completion.poll_complete(context)).await;
        future_completed.store(true, Ordering::Release);
        drop(owner);
    }

    async fn wait_for_coordinator(lease: CallerLease, future_completed: Arc<AtomicBool>) {
        // Use the lease after suspension so the pending caller future owns it.
        let owner = lease;
        std::future::pending::<()>().await;
        future_completed.store(true, Ordering::Release);
        drop(owner);
    }

    #[test]
    fn dropping_async_owner_cancels_joins_and_never_delivers_late_success() {
        let dropped = Arc::new(AtomicBool::new(false));
        let future_completed = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        let (reached_tx, reached_rx) = mpsc::sync_channel(1);
        let (_release_tx, release_rx) = mpsc::sync_channel(1);
        let hook = TestHook {
            reached: reached_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
            panic_after_first_chunk: false,
        };
        let (mut job, completion) = WorkerJob::start_for_async_owner_test(
            input(&vec![b'a'; 1024], &dropped),
            cancel.clone(),
            deadline_after(Duration::from_secs(2)),
            hook,
        )
        .unwrap();
        // Keep an observer alive across async-future cancellation. A fixed
        // Cancelled result may be queued; the property is that no Complete
        // summary is delivered and the sender is gone after the owner joins.
        let receiver_observer = Arc::new(Mutex::new(job.receiver.take().unwrap()));
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let mut future = Box::pin(wait_for_worker_completion(
            job,
            receiver_observer.clone(),
            completion.clone(),
            future_completed.clone(),
        ));
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        assert!(matches!(future.as_mut().poll(&mut context), Poll::Pending));
        assert!(!future_completed.load(Ordering::Acquire));

        // Dropping this waiting future drops its owned WorkerJob. Its Drop
        // requests cancellation and synchronously joins the bounded worker.
        drop(future);

        assert!(cancel.is_cancelled());
        assert!(dropped.load(Ordering::Acquire));
        assert!(completion.is_complete());
        assert!(!future_completed.load(Ordering::Acquire));
        let receiver = receiver_observer.lock().unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_millis(100)).unwrap(),
            WorkerResult::Failed(WorkerError::Cancelled)
        );
        assert!(matches!(
            receiver.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Disconnected)
        ));
    }

    #[test]
    fn caller_future_drop_is_nonjoining_and_coordinator_drain_joins() {
        let dropped = Arc::new(AtomicBool::new(false));
        let future_completed = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (exited_tx, exited_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let gate = CoordinatorTestGate {
            entered: entered_tx,
            exited: exited_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
        };
        let (job, completion, _done_rx) = WorkerJob::start_for_coordinator_test(
            input(&vec![b'c'; 1024], &dropped),
            cancel.clone(),
            deadline_after(Duration::from_secs(5)),
            Some(gate),
        )
        .unwrap();
        let mut coordinator = WorkerCoordinator::new();
        let lease = coordinator
            .supervise_inner(job, Some(release_tx))
            .ok()
            .unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let mut future = Box::pin(wait_for_coordinator(lease, future_completed.clone()));
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        assert!(matches!(future.as_mut().poll(&mut context), Poll::Pending));
        drop(future);

        // These handshakes show caller-drop returned while the worker was
        // still inside the gate, rather than after its bounded gate timeout.
        assert!(cancel.is_cancelled());
        assert!(!dropped.load(Ordering::Acquire));
        assert!(!completion.is_complete());
        assert!(matches!(
            exited_rx.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        assert!(!future_completed.load(Ordering::Acquire));

        let results = coordinator.drain();
        assert_eq!(results, vec![WorkerResult::Failed(WorkerError::Cancelled)]);
        assert!(dropped.load(Ordering::Acquire));
        assert!(completion.is_complete());
        exited_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(!future_completed.load(Ordering::Acquire));
    }

    #[test]
    fn coordinator_drain_suppresses_queued_success_after_caller_abandons() {
        let dropped = Arc::new(AtomicBool::new(false));
        let future_completed = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        let (job, completion, done_rx) = WorkerJob::start_for_coordinator_test(
            input(b"queued synthetic success", &dropped),
            cancel.clone(),
            deadline_after(Duration::from_secs(5)),
            None,
        )
        .unwrap();
        let mut coordinator = WorkerCoordinator::new();
        let lease = coordinator.supervise(job).ok().unwrap();
        // This test-only completion message is sent after the worker has
        // queued its result, establishing the prequeued-success race case.
        done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(completion.is_complete());
        assert!(dropped.load(Ordering::Acquire));

        let mut future = Box::pin(wait_for_coordinator(lease, future_completed.clone()));
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        assert!(matches!(future.as_mut().poll(&mut context), Poll::Pending));
        drop(future);

        assert!(cancel.is_cancelled());
        assert_eq!(
            coordinator.drain(),
            vec![WorkerResult::Failed(WorkerError::Cancelled)]
        );
        assert!(!future_completed.load(Ordering::Acquire));
    }

    #[test]
    fn coordinator_capacity_rejection_returns_job_ownership_to_caller() {
        let first_dropped = Arc::new(AtomicBool::new(false));
        let first_cancel = Cancellation::default();
        let (first_job, _first_completion, first_done) =
            WorkerJob::start_for_coordinator_test(
                input(b"accepted synthetic input", &first_dropped),
                first_cancel,
                deadline_after(Duration::from_secs(10)),
                None,
            )
            .unwrap();
        let mut coordinator = WorkerCoordinator::new();
        let first_lease = coordinator.supervise(first_job).ok().unwrap();
        first_done.recv_timeout(Duration::from_secs(1)).unwrap();

        let rejected_dropped = Arc::new(AtomicBool::new(false));
        let rejected_cancel = Cancellation::default();
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (exited_tx, exited_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let gate = CoordinatorTestGate {
            entered: entered_tx,
            exited: exited_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
        };
        let (rejected_job, rejected_completion, rejected_done) =
            WorkerJob::start_for_coordinator_test(
                input(b"rejected synthetic input", &rejected_dropped),
                rejected_cancel.clone(),
                deadline_after(Duration::from_secs(10)),
                Some(gate),
            )
            .unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        // Capacity refusal returns the exact still-owned WorkerJob; it does
        // not silently join, detach, or drop its input behind the caller.
        let rejected_job = match coordinator.supervise(rejected_job) {
            Err(job) => job,
            Ok(_) => panic!("one-job coordinator accepted a second job"),
        };
        assert!(!rejected_cancel.is_cancelled());
        assert!(!rejected_completion.is_complete());
        assert!(!rejected_dropped.load(Ordering::Acquire));
        assert!(matches!(
            rejected_done.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        assert!(matches!(
            exited_rx.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));

        rejected_cancel.cancel();
        release_tx.send(()).unwrap();
        assert_eq!(
            rejected_job.finish(),
            WorkerResult::Failed(WorkerError::Cancelled)
        );
        assert!(rejected_completion.is_complete());
        assert!(rejected_dropped.load(Ordering::Acquire));
        assert!(rejected_done.recv_timeout(Duration::from_secs(1)).is_ok());
        exited_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        // The accepted success is committed by drain before this later lease
        // drop; cancellation cannot retract an already accepted result.
        assert_eq!(
            coordinator.drain(),
            vec![WorkerResult::Complete(Summary {
                class: ByteClass::AsciiOnly,
                byte_count: b"accepted synthetic input".len() as u32,
            })]
        );
        assert!(first_dropped.load(Ordering::Acquire));
        drop(first_lease);
    }

    #[test]
    fn coordinator_drop_cancels_releases_and_joins_without_lease_drop() {
        let dropped = Arc::new(AtomicBool::new(false));
        let cancel = Cancellation::default();
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (exited_tx, exited_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let gate = CoordinatorTestGate {
            entered: entered_tx,
            exited: exited_tx,
            release: Arc::new(std::sync::Mutex::new(release_rx)),
        };
        let (job, completion, done_rx) = WorkerJob::start_for_coordinator_test(
            input(&vec![b's'; 1024], &dropped),
            cancel.clone(),
            deadline_after(Duration::from_secs(10)),
            Some(gate),
        )
        .unwrap();
        let mut coordinator = WorkerCoordinator::new();
        let _caller_lease = coordinator
            .supervise_inner(job, Some(release_tx))
            .ok()
            .unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let receiver_observer = coordinator.jobs[0].job.receiver.take().unwrap();
        assert!(!dropped.load(Ordering::Acquire));
        assert!(!completion.is_complete());
        assert!(matches!(
            exited_rx.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));

        // Keep _caller_lease alive: this exercises coordinator shutdown's
        // own cancel/release/join path, not CallerLease::Drop cancellation.
        drop(coordinator);

        assert!(cancel.is_cancelled());
        assert!(dropped.load(Ordering::Acquire));
        assert!(completion.is_complete());
        assert!(done_rx.recv_timeout(Duration::from_secs(1)).is_ok());
        exited_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(
            receiver_observer.recv_timeout(Duration::from_secs(1)).unwrap(),
            WorkerResult::Failed(WorkerError::Cancelled)
        );
        assert!(matches!(
            receiver_observer.recv_timeout(Duration::from_secs(1)),
            Err(mpsc::RecvTimeoutError::Disconnected)
        ));
        drop(_caller_lease);
    }

    #[test]
    fn errors_and_panics_are_closed_without_formatting_payloads() {
        for error in [
            WorkerError::Cancelled,
            WorkerError::Deadline,
            WorkerError::InputTooLarge,
            WorkerError::OutputClosed,
            WorkerError::WorkerPanicked,
            WorkerError::WorkerStartFailed,
            WorkerError::InputDropCheckpointMissing,
        ] {
            let rendered = format!("{error:?}");
            assert!(!rendered.contains("private"));
            assert!(!rendered.contains("sentinel"));
        }
    }
}
