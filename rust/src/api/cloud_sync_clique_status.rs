//! Unknown trust status must not become false. Admission is nonblocking and
//! still owns the ordinary writer permit during the mutating trust refresh.
use anyhow::anyhow;
use rustpush::PushError;
use std::{future::Future, io::ErrorKind};

pub(super) async fn check<P, Admit, Probe, F>(admit: Admit, probe: Probe) -> anyhow::Result<bool>
where
    Admit: FnOnce() -> Result<P, PushError>,
    Probe: FnOnce(P) -> F,
    F: Future<Output = Result<bool, PushError>>,
{
    let permit = admit().map_err(|error| match error {
        PushError::IoError(error)
            if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
        {
            anyhow!("cloud_sync_v2_pcs_status_busy")
        }
        _ => anyhow!("cloud_sync_v2_pcs_status_failed"),
    })?;
    probe(permit)
        .await
        .map_err(|_| anyhow!("cloud_sync_v2_pcs_status_failed"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[tokio::test]
    async fn gate_busy_errors_reject_before_trust_probe() {
        for kind in [ErrorKind::WouldBlock, ErrorKind::TimedOut] {
            let probes = Cell::new(0);
            let result = check(
                || {
                    Err::<(), _>(PushError::IoError(std::io::Error::new(
                        kind,
                        "private detail",
                    )))
                },
                |_| async {
                    probes.set(probes.get() + 1);
                    Ok(false)
                },
            )
            .await;
            assert_eq!(
                result.unwrap_err().to_string(),
                "cloud_sync_v2_pcs_status_busy"
            );
            assert_eq!(probes.get(), 0);
        }
    }

    #[tokio::test]
    async fn refreshed_true_and_false_stay_distinct_from_unknown() {
        for membership in [true, false] {
            assert_eq!(
                check(|| Ok(()), |_| async { Ok(membership) })
                    .await
                    .unwrap(),
                membership
            );
        }
    }

    #[tokio::test]
    async fn refresh_failure_is_not_cached_false_and_leaks_no_detail() {
        let result = check(
            || Ok(()),
            |_| async {
                Err(PushError::IoError(std::io::Error::new(
                    ErrorKind::Other,
                    "private refresh error",
                )))
            },
        )
        .await;
        assert_eq!(
            result.unwrap_err().to_string(),
            "cloud_sync_v2_pcs_status_failed"
        );
    }

    #[tokio::test]
    async fn invalid_admission_is_not_reported_as_a_trust_decision() {
        let result = check(
            || {
                Err::<(), _>(PushError::IoError(std::io::Error::new(
                    ErrorKind::PermissionDenied,
                    "private token",
                )))
            },
            |_| async {
                panic!("admission failure cannot run trust refresh");
                #[allow(unreachable_code)]
                Ok(false)
            },
        )
        .await;
        assert_eq!(
            result.unwrap_err().to_string(),
            "cloud_sync_v2_pcs_status_failed"
        );
    }
}
