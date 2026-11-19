#![cfg(test)]

//! Standalone synthetic native-owner/reaper lifecycle model.
//! No app, FRB, acquisition, persistence, logging, or CloudKit linkage.

use std::{
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
        Arc, Condvar, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const MAX_SYNTHETIC_BYTES: usize = 128;
const COMMAND_CAPACITY: usize = 2; // one Start plus one Quiesce signal
const REAPER_POLL: Duration = Duration::from_millis(5);
const TEST_GATE_FAILSAFE: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    Ready,
    Quiescing,
    Quiesced,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Outcome {
    Complete { byte_count: u16 },
    Cancelled,
    StartFailed,
    WorkerPanicked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ServiceError {
    AtCapacity,
    Quiescing,
    TooLarge,
    QueueFull,
    ReaperUnavailable,
    NotQuiesced,
    ReaperPanicked,
    StateBusy,
}

#[derive(Default)]
struct Metrics {
    owned_copies: AtomicUsize,
    workers_started: AtomicUsize,
    workers_joined: AtomicUsize,
    quiescence_acks: AtomicUsize,
}

struct LifecycleState {
    phase: Phase,
    reserved: bool,
}

struct Control {
    state: Mutex<LifecycleState>,
    changed: Condvar,
    metrics: Arc<Metrics>,
}

impl Control {
    fn phase(&self) -> Result<Phase, ServiceError> {
        self.state
            .try_lock()
            .map(|state| state.phase)
            .map_err(|_| ServiceError::StateBusy)
    }

    fn reserve(self: &Arc<Self>) -> Result<AdmissionReservation, ServiceError> {
        let mut state = self.state.try_lock().map_err(|_| ServiceError::StateBusy)?;
        if state.phase != Phase::Ready {
            return Err(ServiceError::Quiescing);
        }
        if state.reserved {
            return Err(ServiceError::AtCapacity);
        }
        state.reserved = true;
        Ok(AdmissionReservation {
            control: Some(self.clone()),
        })
    }

    fn begin_quiesce(&self) -> Result<bool, ServiceError> {
        let mut state = self.state.try_lock().map_err(|_| ServiceError::StateBusy)?;
        let first_request = state.phase == Phase::Ready;
        if first_request {
            state.phase = Phase::Quiescing;
        }
        self.changed.notify_all();
        Ok(first_request)
    }

    fn begin_quiesce_for_owner(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        let first_request = state.phase == Phase::Ready;
        if first_request {
            state.phase = Phase::Quiescing;
        }
        self.changed.notify_all();
        first_request
    }

    fn reservation_present(&self) -> bool {
        self.state.lock().unwrap().reserved
    }

    fn phase_blocking_for_owner(&self) -> Phase {
        self.state.lock().unwrap().phase
    }

    fn mark_quiesced_if_empty(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.phase == Phase::Quiescing && !state.reserved {
            state.phase = Phase::Quiesced;
            self.metrics
                .quiescence_acks
                .fetch_add(1, Ordering::AcqRel);
            self.changed.notify_all();
            true
        } else {
            false
        }
    }

    fn release_reservation(&self) {
        let mut state = self.state.lock().unwrap();
        state.reserved = false;
        self.changed.notify_all();
    }

    fn wait_for_quiesced(&self, timeout: Duration) -> bool {
        let state = self.state.lock().unwrap();
        let (state, _) = self
            .changed
            .wait_timeout_while(state, timeout, |state| state.phase != Phase::Quiesced)
            .unwrap();
        state.phase == Phase::Quiesced
    }
}

/// A reservation is acquired before the synthetic owned Vec is copied.
struct AdmissionReservation {
    control: Option<Arc<Control>>,
}

impl AdmissionReservation {
    fn submit_synthetic(
        mut self,
        command_tx: &SyncSender<Command>,
        source: &[u8],
        drop_witness: Arc<AtomicBool>,
        gate: Option<TestWorkerGate>,
    ) -> Result<RequestLease, ServiceError> {
        let control = self.control.as_ref().expect("live reservation").clone();
        if control.phase()? != Phase::Ready {
            return Err(ServiceError::Quiescing);
        }
        if source.len() > MAX_SYNTHETIC_BYTES {
            return Err(ServiceError::TooLarge);
        }

        // This is the only copy in the model, and it follows reservation.
        control
            .metrics
            .owned_copies
            .fetch_add(1, Ordering::AcqRel);
        let input = SyntheticInput {
            bytes: Some(source.to_vec()),
            drop_witness: Some(drop_witness),
        };

        // Quiesce may win after reservation but before the copy. If it wins
        // after this check, the reaper still owns the permit and rejects the
        // queued Start before spawning. No ack can pass the reserved bit.
        if control.phase()? != Phase::Ready {
            drop(input);
            return Err(ServiceError::Quiescing);
        }

        let (result_tx, result_rx) = mpsc::sync_channel(1);
        let cancel = Arc::new(AtomicBool::new(false));
        let permit = AdmissionReservation {
            control: self.control.take(),
        };
        let request = QueuedRequest {
            input: Some(input),
            permit: Some(permit),
            cancel: cancel.clone(),
            result_tx: Some(result_tx),
            gate,
        };
        match command_tx.try_send(Command::Start(request)) {
            Ok(()) => Ok(RequestLease {
                cancel,
                result_rx,
            }),
            Err(TrySendError::Full(Command::Start(request))) => {
                drop(request);
                Err(ServiceError::QueueFull)
            }
            Err(TrySendError::Disconnected(Command::Start(request))) => {
                drop(request);
                Err(ServiceError::ReaperUnavailable)
            }
            Err(TrySendError::Full(Command::Quiesce))
            | Err(TrySendError::Disconnected(Command::Quiesce)) => {
                unreachable!("only Start is submitted by admission")
            }
        }
    }
}

impl Drop for AdmissionReservation {
    fn drop(&mut self) {
        if let Some(control) = self.control.take() {
            control.release_reservation();
        }
    }
}

struct SyntheticInput {
    bytes: Option<Vec<u8>>,
    drop_witness: Option<Arc<AtomicBool>>,
}

impl Drop for SyntheticInput {
    fn drop(&mut self) {
        drop(self.bytes.take());
        if let Some(witness) = self.drop_witness.take() {
            witness.store(true, Ordering::Release);
        }
    }
}

struct TestWorkerGate {
    entered: SyncSender<()>,
    release_rx: Receiver<()>,
    release_tx: SyncSender<()>,
    release_on_quiesce: bool,
}

struct ReaperPause {
    entered: SyncSender<()>,
    release_rx: Receiver<()>,
}

struct QueuedRequest {
    input: Option<SyntheticInput>,
    permit: Option<AdmissionReservation>,
    cancel: Arc<AtomicBool>,
    result_tx: Option<SyncSender<Outcome>>,
    gate: Option<TestWorkerGate>,
}

impl QueuedRequest {
    fn into_parts(
        mut self,
    ) -> (
        SyntheticInput,
        AdmissionReservation,
        Arc<AtomicBool>,
        SyncSender<Outcome>,
        Option<TestWorkerGate>,
    ) {
        let input = self.input.take().expect("queued input");
        let permit = self.permit.take().expect("queued permit");
        let cancel = self.cancel.clone();
        let result_tx = self.result_tx.take().expect("queued result sender");
        let gate = self.gate.take();
        drop(self);
        (input, permit, cancel, result_tx, gate)
    }
}

impl Drop for QueuedRequest {
    fn drop(&mut self) {
        drop(self.input.take());
        drop(self.permit.take());
    }
}

enum Command {
    Start(QueuedRequest),
    Quiesce,
}

struct ActiveWorker {
    join: Option<JoinHandle<()>>,
    done_rx: Receiver<Outcome>,
    permit: Option<AdmissionReservation>,
    cancel: Arc<AtomicBool>,
    result_tx: SyncSender<Outcome>,
    gate_release: Option<(SyncSender<()>, bool)>,
}

impl Drop for ActiveWorker {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Release);
        if let Some((release, _)) = self.gate_release.take() {
            let _ = release.try_send(());
        }
        if let Some(join) = self.join.take() {
            // Reaper panic/unwind cleanup still owns and joins the worker.
            let _ = join.join();
            self.permit.take();
        }
    }
}

#[derive(Clone)]
struct ServiceHandle {
    control: Arc<Control>,
    command_tx: SyncSender<Command>,
}

impl ServiceHandle {
    fn try_reserve(&self) -> Result<AdmissionReservation, ServiceError> {
        self.control.reserve()
    }

    fn try_admit_synthetic(
        &self,
        source: &[u8],
        drop_witness: Arc<AtomicBool>,
        gate: Option<TestWorkerGate>,
    ) -> Result<RequestLease, ServiceError> {
        self.try_reserve()?.submit_synthetic(
            &self.command_tx,
            source,
            drop_witness,
            gate,
        )
    }

    fn request_shutdown(&self) -> Result<ShutdownTicket, ServiceError> {
        let first_request = self.control.begin_quiesce()?;
        if first_request {
            // The command is only a wakeup. The phase is authoritative. If
            // Start already occupies the bounded queue, the reaper observes
            // Quiescing while it drains that request.
            match self.command_tx.try_send(Command::Quiesce) {
                Ok(()) | Err(TrySendError::Full(Command::Quiesce)) => {}
                Err(TrySendError::Disconnected(Command::Quiesce)) => {
                    // No ack will be fabricated; the shared state stays Q.
                }
                Err(TrySendError::Full(Command::Start(_)))
                | Err(TrySendError::Disconnected(Command::Start(_))) => {
                    unreachable!("shutdown only submits Quiesce")
                }
            }
        }
        Ok(ShutdownTicket {
            control: self.control.clone(),
        })
    }
}

struct RequestLease {
    cancel: Arc<AtomicBool>,
    result_rx: Receiver<Outcome>,
}

impl RequestLease {
    fn try_result(&self) -> Result<Option<Outcome>, ServiceError> {
        match self.result_rx.try_recv() {
            Ok(outcome) => Ok(Some(outcome)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(ServiceError::ReaperUnavailable),
        }
    }
}

impl Drop for RequestLease {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Release);
    }
}

#[derive(Clone)]
struct ShutdownTicket {
    control: Arc<Control>,
}

impl ShutdownTicket {
    fn phase(&self) -> Result<Phase, ServiceError> {
        self.control.phase()
    }

    /// Native-owner/test harness wait only. Async callers should poll the
    /// shared phase through a nonblocking adapter, not block an executor.
    fn wait_timeout(&self, timeout: Duration) -> bool {
        self.control.wait_for_quiesced(timeout)
    }
}

struct NativeOwner {
    control: Arc<Control>,
    command_tx: SyncSender<Command>,
    reaper_join: Option<JoinHandle<()>>,
    #[cfg(test)] pause_release: Option<SyncSender<()>>,
}

impl NativeOwner {
    fn start() -> Result<Self, ServiceError> {
        Self::start_inner(None, None)
    }

    fn start_paused_for_test() -> Result<(Self, Receiver<()>, SyncSender<()>), ServiceError> {
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let pause = ReaperPause {
            entered: entered_tx,
            release_rx,
        };
        let owner = Self::start_inner(Some(pause), Some(release_tx.clone()))?;
        Ok((owner, entered_rx, release_tx))
    }

    fn start_inner(
        pause: Option<ReaperPause>,
        #[cfg(test)] pause_release: Option<SyncSender<()>>,
    ) -> Result<Self, ServiceError> {
        let control = Arc::new(Control {
            state: Mutex::new(LifecycleState {
                phase: Phase::Ready,
                reserved: false,
            }),
            changed: Condvar::new(),
            metrics: Arc::new(Metrics::default()),
        });
        let (command_tx, command_rx) = mpsc::sync_channel(COMMAND_CAPACITY);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let reaper_control = control.clone();
        let reaper = thread::Builder::new()
            .name("synthetic-native-reaper".to_owned())
            .spawn(move || reaper_loop(reaper_control, command_rx, ready_tx, pause))
            .map_err(|_| ServiceError::ReaperUnavailable)?;
        match ready_rx.recv_timeout(Duration::from_secs(1)) {
            Ok(()) => Ok(Self {
                control,
                command_tx,
                reaper_join: Some(reaper),
                #[cfg(test)]
                pause_release,
            }),
            Err(_) => {
                // A readiness timeout is not permission to join a live reaper
                // in Ready. Request orderly stop and release its test gate first.
                control.begin_quiesce_for_owner();
                let _ = command_tx.try_send(Command::Quiesce);
                #[cfg(test)]
                if let Some(release) = pause_release {
                    let _ = release.try_send(());
                }
                let _ = reaper.join();
                Err(ServiceError::ReaperUnavailable)
            }
        }
    }

    fn handle(&self) -> ServiceHandle {
        ServiceHandle {
            control: self.control.clone(),
            command_tx: self.command_tx.clone(),
        }
    }

    fn phase(&self) -> Result<Phase, ServiceError> {
        self.control.phase()
    }

    fn wait_ack_timeout(&self, timeout: Duration) -> bool {
        self.control.wait_for_quiesced(timeout)
    }

    /// Called only by the non-executor native harness after quiescence ack.
    fn join_after_ack(&mut self) -> Result<(), ServiceError> {
        if self.control.phase_blocking_for_owner() != Phase::Quiesced {
            return Err(ServiceError::NotQuiesced);
        }
        if let Some(join) = self.reaper_join.take() {
            join.join().map_err(|_| ServiceError::ReaperPanicked)?;
        }
        Ok(())
    }

    fn workers_joined(&self) -> usize {
        self.control.metrics.workers_joined.load(Ordering::Acquire)
    }

    fn ack_count(&self) -> usize {
        self.control
            .metrics
            .quiescence_acks
            .load(Ordering::Acquire)
    }
}

impl Drop for NativeOwner {
    fn drop(&mut self) {
        if self.reaper_join.is_none() {
            return;
        }
        if self.control.begin_quiesce_for_owner() {
            let _ = self.command_tx.try_send(Command::Quiesce);
        }
        #[cfg(test)]
        if let Some(release) = self.pause_release.take() {
            let _ = release.try_send(());
        }
        // This owner is the native/root harness, not an async caller. The
        // join is intentionally synchronous and never occurs under state lock.
        if let Some(join) = self.reaper_join.take() {
            let _ = join.join();
        }
    }
}

struct WindowModel {
    hidden_to_tray: bool,
    final_exit_requested: bool,
}

impl WindowModel {
    fn new() -> Self {
        Self {
            hidden_to_tray: false,
            final_exit_requested: false,
        }
    }

    fn close_to_tray(&mut self) {
        self.hidden_to_tray = true;
    }

    fn final_exit(&mut self, handle: &ServiceHandle) -> Result<ShutdownTicket, ServiceError> {
        self.final_exit_requested = true;
        request_shutdown_retry(handle)
    }
}

// Test-harness retry only: the service API itself keeps the fixed StateBusy
// response rather than blocking callers behind the lifecycle mutex.
fn request_shutdown_retry(handle: &ServiceHandle) -> Result<ShutdownTicket, ServiceError> {
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match handle.request_shutdown() {
            Err(ServiceError::StateBusy) if Instant::now() < deadline => thread::yield_now(),
            result => return result,
        }
    }
}

fn reaper_loop(
    control: Arc<Control>,
    command_rx: Receiver<Command>,
    ready_tx: SyncSender<()>,
    pause: Option<ReaperPause>,
) {
    let _ = ready_tx.try_send(());
    if let Some(pause) = pause {
        let _ = pause.entered.try_send(());
        let _ = pause.release_rx.recv_timeout(TEST_GATE_FAILSAFE);
    }

    let mut active: Option<ActiveWorker> = None;
    loop {
        if let Some(worker) = active.as_mut() {
            if control.phase_blocking_for_owner() == Phase::Quiescing {
                worker.cancel.store(true, Ordering::Release);
                if let Some((release, release_on_quiesce)) = worker.gate_release.as_ref() {
                    if *release_on_quiesce {
                        let _ = release.try_send(());
                    }
                }
            }

            match worker.done_rx.try_recv() {
                Ok(outcome) => {
                    let mut worker = active.take().expect("active worker");
                    let joined = worker.join.take().expect("worker join handle").join();
                    control
                        .metrics
                        .workers_joined
                        .fetch_add(1, Ordering::AcqRel);
                    drop(worker.permit.take());
                    let final_outcome = if joined.is_err() {
                        Outcome::WorkerPanicked
                    } else {
                        outcome
                    };
                    let _ = worker.result_tx.try_send(final_outcome);
                }
                Err(TryRecvError::Disconnected) => {
                    let mut worker = active.take().expect("active worker");
                    let _ = worker.join.take().expect("worker join handle").join();
                    control
                        .metrics
                        .workers_joined
                        .fetch_add(1, Ordering::AcqRel);
                    drop(worker.permit.take());
                    let _ = worker.result_tx.try_send(Outcome::WorkerPanicked);
                }
                Err(TryRecvError::Empty) => {}
            }
        }

        if active.is_none() && control.phase_blocking_for_owner() == Phase::Quiescing {
            // Drain any queued Start. Each request owns its input and permit,
            // so dropping it releases bytes first and reservation second.
            loop {
                match command_rx.try_recv() {
                    Ok(Command::Start(request)) => drop(request),
                    Ok(Command::Quiesce) => {}
                    Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
                }
            }
            if control.mark_quiesced_if_empty() {
                return;
            }
        }

        match command_rx.recv_timeout(REAPER_POLL) {
            Ok(Command::Quiesce) => {}
            Ok(Command::Start(request)) => {
                if control.phase_blocking_for_owner() != Phase::Ready
                    || request.cancel.load(Ordering::Acquire)
                {
                    drop(request);
                    continue;
                }
                active = spawn_owned_worker(request, &control);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                if control.phase_blocking_for_owner() != Phase::Quiescing {
                    continue;
                }
            }
        }
    }
}

fn spawn_owned_worker(request: QueuedRequest, control: &Arc<Control>) -> Option<ActiveWorker> {
    let (input, permit, cancel, result_tx, gate) = request.into_parts();
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let worker_control = control.clone();
    let (worker_gate, gate_release) = match gate {
        Some(gate) => (
            Some((gate.entered, gate.release_rx)),
            Some((gate.release_tx, gate.release_on_quiesce)),
        ),
        None => (None, None),
    };
    let worker_cancel = cancel.clone();
    let worker = thread::Builder::new()
        .name("synthetic-owned-worker".to_owned())
        .spawn(move || {
            worker_control
                .metrics
                .workers_started
                .fetch_add(1, Ordering::AcqRel);
            if let Some((entered, release_rx)) = worker_gate {
                let _ = entered.try_send(());
                let _ = release_rx.recv_timeout(TEST_GATE_FAILSAFE);
            }
            let phase = worker_control.phase_blocking_for_owner();
            let outcome = if worker_cancel.load(Ordering::Acquire) || phase != Phase::Ready {
                Outcome::Cancelled
            } else {
                let byte_count = input.bytes.as_ref().map_or(0, |bytes| bytes.len() as u16);
                Outcome::Complete { byte_count }
            };
            drop(input);
            let _ = done_tx.try_send(outcome);
        });

    match worker {
        Ok(join) => Some(ActiveWorker {
            join: Some(join),
            done_rx,
            permit: Some(permit),
            cancel,
            result_tx,
            gate_release,
        }),
        Err(_) => {
            // Closure capture destruction drops input before the reaper-held
            // permit; no JoinHandle was created or transferred.
            drop(permit);
            let _ = result_tx.try_send(Outcome::StartFailed);
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn witness() -> Arc<AtomicBool> {
        Arc::new(AtomicBool::new(false))
    }

    fn gated_worker(release_on_quiesce: bool) -> (TestWorkerGate, Receiver<()>, SyncSender<()>) {
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        (
            TestWorkerGate {
                entered: entered_tx,
                release_rx,
                release_tx: release_tx.clone(),
                release_on_quiesce,
            },
            entered_rx,
            release_tx,
        )
    }

    #[test]
    fn reserve_then_quiesce_rejects_before_copy_and_ack_waits_for_release() {
        let mut owner = NativeOwner::start().unwrap();
        let handle = owner.handle();
        let reservation = handle.try_reserve().unwrap();
        let ticket = request_shutdown_retry(&handle).unwrap();
        assert_eq!(owner.control.phase_blocking_for_owner(), Phase::Quiescing);

        let dropped = witness();
        let result = reservation.submit_synthetic(
            &handle.command_tx,
            b"must-not-be-copied-after-close",
            dropped.clone(),
            None,
        );
        assert!(matches!(result, Err(ServiceError::Quiescing)));
        assert!(!dropped.load(Ordering::Acquire));
        assert!(ticket.wait_timeout(Duration::from_secs(1)));
        assert_eq!(ticket.phase().unwrap(), Phase::Quiesced);
        assert_eq!(owner.ack_count(), 1);
        owner.join_after_ack().unwrap();
    }

    #[test]
    fn quiesce_before_admission_rejects_without_allocating() {
        let mut owner = NativeOwner::start().unwrap();
        let handle = owner.handle();
        let ticket = request_shutdown_retry(&handle).unwrap();
        let dropped = witness();
        assert!(matches!(
            handle.try_admit_synthetic(b"closed", dropped.clone(), None),
            Err(ServiceError::Quiescing)
        ));
        assert!(!dropped.load(Ordering::Acquire));
        assert!(ticket.wait_timeout(Duration::from_secs(1)));
        assert_eq!(owner.ack_count(), 1);
        owner.join_after_ack().unwrap();
    }

    #[test]
    fn queued_dropped_waiter_is_disposed_before_quiescence_ack() {
        let (mut owner, reaper_entered, reaper_release) =
            NativeOwner::start_paused_for_test().unwrap();
        let handle = owner.handle();
        reaper_entered.recv_timeout(Duration::from_secs(1)).unwrap();
        let dropped = witness();
        let request = handle
            .try_admit_synthetic(b"queued synthetic request", dropped.clone(), None)
            .unwrap();
        assert_eq!(owner.control.metrics.owned_copies.load(Ordering::Acquire), 1);
        drop(request); // cancellation-only; queued input remains service-owned
        let ticket = request_shutdown_retry(&handle).unwrap();
        assert_eq!(owner.control.phase_blocking_for_owner(), Phase::Quiescing);
        assert!(!ticket.wait_timeout(Duration::from_millis(10)));
        assert!(!dropped.load(Ordering::Acquire));
        assert_eq!(owner.control.metrics.workers_started.load(Ordering::Acquire), 0);

        reaper_release.try_send(()).unwrap();
        assert!(ticket.wait_timeout(Duration::from_secs(1)));
        assert!(dropped.load(Ordering::Acquire));
        assert_eq!(owner.control.metrics.workers_started.load(Ordering::Acquire), 0);
        assert_eq!(owner.ack_count(), 1);
        owner.join_after_ack().unwrap();
    }

    #[test]
    fn duplicate_shutdown_is_idempotent_and_ack_follows_worker_join() {
        let mut owner = NativeOwner::start().unwrap();
        let handle = owner.handle();
        let dropped = witness();
        let (gate, entered, _manual_release) = gated_worker(true);
        let mut request = handle
            .try_admit_synthetic(b"active synthetic work", dropped.clone(), Some(gate))
            .unwrap();
        entered.recv_timeout(Duration::from_secs(1)).unwrap();

        let first = request_shutdown_retry(&handle).unwrap();
        let second = request_shutdown_retry(&handle).unwrap();
        assert!(matches!(
            owner.control.phase_blocking_for_owner(),
            Phase::Quiescing | Phase::Quiesced
        ));
        assert!(first.wait_timeout(Duration::from_secs(1)));
        assert_eq!(first.phase().unwrap(), Phase::Quiesced);
        assert_eq!(second.phase().unwrap(), Phase::Quiesced);
        assert_eq!(owner.workers_joined(), 1);
        assert_eq!(owner.ack_count(), 1);
        assert!(dropped.load(Ordering::Acquire));
        assert_eq!(request.try_result().unwrap(), Some(Outcome::Cancelled));
        owner.join_after_ack().unwrap();
    }

    #[test]
    fn timeout_observation_stays_quiescing_until_manual_gate_release() {
        let mut owner = NativeOwner::start().unwrap();
        let handle = owner.handle();
        let dropped = witness();
        let (gate, entered, release) = gated_worker(false);
        let request = handle
            .try_admit_synthetic(b"held synthetic work", dropped.clone(), Some(gate))
            .unwrap();
        entered.recv_timeout(Duration::from_secs(1)).unwrap();
        let ticket = request_shutdown_retry(&handle).unwrap();

        // A caller's wait deadline has expired while the deterministic worker
        // gate remains held. Timeout is only Pending; it cannot fabricate ack.
        assert_eq!(owner.control.phase_blocking_for_owner(), Phase::Quiescing);
        assert!(!ticket.wait_timeout(Duration::from_millis(10)));
        assert_eq!(owner.control.phase_blocking_for_owner(), Phase::Quiescing);
        assert_eq!(owner.workers_joined(), 0);
        assert_eq!(owner.ack_count(), 0);
        assert!(!dropped.load(Ordering::Acquire));

        release.try_send(()).unwrap();
        assert!(ticket.wait_timeout(Duration::from_secs(1)));
        assert_eq!(ticket.phase().unwrap(), Phase::Quiesced);
        assert_eq!(owner.workers_joined(), 1);
        assert!(dropped.load(Ordering::Acquire));
        assert_eq!(request.try_result().unwrap(), Some(Outcome::Cancelled));
        owner.join_after_ack().unwrap();
    }

    #[test]
    fn close_to_tray_hides_but_final_exit_requests_quiescence() {
        let mut owner = NativeOwner::start().unwrap();
        let handle = owner.handle();
        let mut window = WindowModel::new();

        window.close_to_tray();
        assert!(window.hidden_to_tray);
        assert!(!window.final_exit_requested);
        assert_eq!(owner.control.phase_blocking_for_owner(), Phase::Ready);

        let ticket = window.final_exit(&handle).unwrap();
        assert!(window.final_exit_requested);
        assert!(matches!(
            owner.control.phase_blocking_for_owner(),
            Phase::Quiescing | Phase::Quiesced
        ));
        assert!(ticket.wait_timeout(Duration::from_secs(1)));
        assert_eq!(ticket.phase().unwrap(), Phase::Quiesced);
        owner.join_after_ack().unwrap();
    }
}
