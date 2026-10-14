//! Opt-in provider boundary. Does not persist state, select hardware, or grant
//! authentication. The default build does not include this module.
use crate::{macos::HardwareConfig, PushError};
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, OnceLock},
};

pub type ValidationResult = Pin<Box<dyn Future<Output = Result<Vec<u8>, PushError>> + Send>>;

pub trait MacValidationProvider: Send + Sync {
    fn generate(&self, hardware: HardwareConfig) -> ValidationResult;
}

static PROVIDER: OnceLock<Arc<dyn MacValidationProvider>> = OnceLock::new();

/// Install before starting any authentication. A process cannot replace the
/// provider after binding it to its isolated profile. Restart to change it.
pub fn install(provider: Arc<dyn MacValidationProvider>) -> Result<(), PushError> {
    PROVIDER
        .set(provider)
        .map_err(|_| PushError::MacValidationUnavailable)
}

pub(crate) fn current() -> Option<&'static Arc<dyn MacValidationProvider>> {
    PROVIDER.get()
}
