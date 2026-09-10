//! Immutable plaintext snapshot for CloudKit attachment preparation.
//!
//! Copies the caller handle into a private OS-managed temporary file,
//! verifies that private copy against the original MMCS descriptor on the
//! same handle, and returns a read-only wrapper. The caller keeps its own
//! handle, so later caller mutations do not affect the snapshot. Size zero
//! is legal when the descriptor itself is valid.
//!
//! tempfile_in uses the supplied private app directory, with private file
//! permissions and OS cleanup when the last handle closes. No user path is
//! opened here, and no plaintext file is kept as persistent retry state.
//!
//! No retry authority here: verifying or reopening this snapshot grants no
//! unknown-attempt retry. A separately authorized attempt must still verify
//! the original descriptor and retained plan hash.
#![cfg_attr(not(test), allow(dead_code))]
use rustpush::MMCSFile;
use std::{
    fs::File,
    future::Future,
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
};
/// Fixed failure modes. Messages carry no paths, keys, or content. The
/// original I/O error is intentionally not exposed.
#[derive(Clone, Copy, Debug, thiserror::Error, Eq, PartialEq)]
pub(crate) enum AttachmentSourceFileError {
    #[error("attachment private snapshot unavailable")]
    SnapshotUnavailable,
    #[error("attachment source length mismatch")]
    LengthMismatch,
    #[error("attachment source verification failed")]
    VerificationFailed,
}
/// Private read-only view of the verified snapshot. Holds the only handle to
/// its own temporary source. Closing the wrapper closes the last handle, so
/// the OS removes the file. Only this snapshot is cleaned up.
pub(crate) struct OwnedAttachmentSource {
    file: File,
}
/// Redacted on purpose: never exposes the file handle, path, or content.
impl std::fmt::Debug for OwnedAttachmentSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OwnedAttachmentSource { .. }")
    }
}
impl Read for OwnedAttachmentSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.file.read(buf)
    }
}
impl Seek for OwnedAttachmentSource {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        self.file.seek(pos)
    }
}
/// Copy exactly expected_len bytes from the current source position into a
/// private file inside private_dir, then rewind. The standard Take adapter
/// caps the source at expected_len + 1 so no read can pass the hard bound;
/// io::copy reports the counted total. Short, long, and read or write
/// failures are rejected before any wrapper exists.
fn snapshot_into_private_file<R: Read>(
    source: &mut R,
    expected_len: usize,
    private_dir: &Path,
) -> Result<File, AttachmentSourceFileError> {
    if expected_len as u64 > u32::MAX as u64 {
        return Err(AttachmentSourceFileError::LengthMismatch);
    }
    let limit = expected_len
        .checked_add(1)
        .ok_or(AttachmentSourceFileError::LengthMismatch)? as u64;
    let mut snapshot = tempfile::tempfile_in(private_dir)
        .map_err(|_| AttachmentSourceFileError::SnapshotUnavailable)?;
    let mut limited = source.take(limit);
    let copied = io::copy(&mut limited, &mut snapshot)
        .map_err(|_| AttachmentSourceFileError::SnapshotUnavailable)?;
    if copied != expected_len as u64 {
        return Err(AttachmentSourceFileError::LengthMismatch);
    }
    snapshot
        .flush()
        .map_err(|_| AttachmentSourceFileError::SnapshotUnavailable)?;
    snapshot
        .seek(SeekFrom::Start(0))
        .map_err(|_| AttachmentSourceFileError::SnapshotUnavailable)?;
    Ok(snapshot)
}
/// Internal seam. Copies with the bounded helper above, then runs the given
/// verifier on the same private handle. Production passes the native
/// MMCSFile verify_plaintext_source. Tests pass a synthetic equality
/// check alongside the existing native verifier suite, so no private key
/// fields are exposed merely for tests.
async fn snapshot_then_verify<R, F, Fut>(
    source: &mut R,
    expected_len: usize,
    private_dir: &Path,
    verify: F,
) -> Result<OwnedAttachmentSource, AttachmentSourceFileError>
where
    R: Read + Send,
    F: FnOnce(File) -> Fut,
    Fut: Future<Output = Result<File, AttachmentSourceFileError>>,
{
    let snapshot = snapshot_into_private_file(source, expected_len, private_dir)?;
    let verified = verify(snapshot).await?;
    Ok(OwnedAttachmentSource { file: verified })
}
/// Snapshot the caller handle into a private file, then immediately verify
/// that closed-for-writing private copy with the original IDS descriptor on
/// the same handle. The returned wrapper starts rewound. Reads from the
/// caller handle begin at its current position.
pub(crate) async fn snapshot_verified_source<R: Read + Send>(
    source: &mut R,
    descriptor: &MMCSFile,
    private_dir: &Path,
) -> Result<OwnedAttachmentSource, AttachmentSourceFileError> {
    snapshot_then_verify(
        source,
        descriptor.size,
        private_dir,
        |snapshot| async move {
            descriptor
                .verify_plaintext_source(snapshot)
                .await
                .map_err(|_| AttachmentSourceFileError::VerificationFailed)
        },
    )
    .await
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, SeekFrom};
    async fn fake_verify_equals(
        mut file: File,
        expected: Vec<u8>,
    ) -> Result<File, AttachmentSourceFileError> {
        file.seek(SeekFrom::Start(0))
            .map_err(|_| AttachmentSourceFileError::VerificationFailed)?;
        let mut actual = Vec::new();
        file.read_to_end(&mut actual)
            .map_err(|_| AttachmentSourceFileError::VerificationFailed)?;
        if actual != expected {
            return Err(AttachmentSourceFileError::VerificationFailed);
        }
        file.seek(SeekFrom::Start(0))
            .map_err(|_| AttachmentSourceFileError::VerificationFailed)?;
        Ok(file)
    }
    #[tokio::test]
    async fn copies_exact_bytes_and_rewinds_for_reads() {
        let data = b"synthetic attachment snapshot fixture".to_vec();
        let dir = tempfile::tempdir().unwrap();
        let mut source = Cursor::new(data.clone());
        let mut owned = snapshot_then_verify(&mut source, data.len(), dir.path(), |f| async move {
            fake_verify_equals(f, data.clone()).await
        })
        .await
        .unwrap();
        assert_eq!(owned.stream_position().unwrap(), 0);
        let mut rest = Vec::new();
        owned.read_to_end(&mut rest).unwrap();
        assert_eq!(rest, b"synthetic attachment snapshot fixture");
        assert_eq!(owned.read(&mut [0u8; 1]).unwrap(), 0);
        owned.seek(SeekFrom::Start(0)).unwrap();
        let mut again = Vec::new();
        owned.read_to_end(&mut again).unwrap();
        assert_eq!(again, b"synthetic attachment snapshot fixture");
    }
    #[tokio::test]
    async fn rejects_same_length_wrong_content() {
        let original = b"synthetic attachment snapshot fixture".to_vec();
        let mut tampered = original.clone();
        tampered[0] ^= 0xff;
        let dir = tempfile::tempdir().unwrap();
        let mut source = Cursor::new(tampered.clone());
        let err = snapshot_then_verify(&mut source, tampered.len(), dir.path(), |f| async move {
            fake_verify_equals(f, original.clone()).await
        })
        .await
        .unwrap_err();
        assert_eq!(err, AttachmentSourceFileError::VerificationFailed);
    }
    #[tokio::test]
    async fn rejects_short_and_long_sources() {
        let data = b"synthetic attachment snapshot fixture".to_vec();
        let dir = tempfile::tempdir().unwrap();
        let mut short = Cursor::new(data[..8].to_vec());
        let err = snapshot_then_verify(&mut short, data.len(), dir.path(), |f| async {
            Ok::<File, AttachmentSourceFileError>(f)
        })
        .await
        .unwrap_err();
        assert_eq!(err, AttachmentSourceFileError::LengthMismatch);
        let mut longer = data.clone();
        longer.extend_from_slice(b"0123456789abcdef");
        let mut long = Cursor::new(longer);
        let err = snapshot_then_verify(&mut long, data.len(), dir.path(), |f| async {
            Ok::<File, AttachmentSourceFileError>(f)
        })
        .await
        .unwrap_err();
        assert_eq!(err, AttachmentSourceFileError::LengthMismatch);
    }
    #[tokio::test]
    async fn oversized_source_reads_only_the_single_size_probe_byte() {
        let dir = tempfile::tempdir().unwrap();
        let mut source = Cursor::new(vec![0u8; 128 * 1024]);
        let err = snapshot_then_verify(&mut source, 17, dir.path(), |_file| async {
            panic!("oversized source must not reach verification");
            #[allow(unreachable_code)]
            Ok::<File, AttachmentSourceFileError>(_file)
        })
        .await
        .unwrap_err();
        assert_eq!(err, AttachmentSourceFileError::LengthMismatch);
        assert_eq!(source.position(), 18);
        assert!(std::fs::read_dir(dir.path()).unwrap().next().is_none());
    }

    struct FailRead;
    impl Read for FailRead {
        fn read(&mut self, _buf: &mut [u8]) -> std::io::Result<usize> {
            Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "synthetic read failure",
            ))
        }
    }
    #[tokio::test]
    async fn rejects_read_failure_and_oversized_descriptor() {
        let dir = tempfile::tempdir().unwrap();
        let mut failing = FailRead;
        let err = snapshot_then_verify(&mut failing, 16, dir.path(), |f| async {
            Ok::<File, AttachmentSourceFileError>(f)
        })
        .await
        .unwrap_err();
        assert_eq!(err, AttachmentSourceFileError::SnapshotUnavailable);
        let mut empty = Cursor::new(Vec::new());
        let oversized = u32::MAX as usize + 1;
        let err = snapshot_then_verify(&mut empty, oversized, dir.path(), |f| async {
            Ok::<File, AttachmentSourceFileError>(f)
        })
        .await
        .unwrap_err();
        assert_eq!(err, AttachmentSourceFileError::LengthMismatch);
    }
    #[tokio::test]
    async fn later_mutation_of_original_does_not_affect_snapshot() {
        let data = b"mutable original fixture".to_vec();
        let dir = tempfile::tempdir().unwrap();
        let mut original = Cursor::new(data.clone());
        let mut owned = snapshot_then_verify(&mut original, data.len(), dir.path(), |f| async {
            Ok::<File, AttachmentSourceFileError>(f)
        })
        .await
        .unwrap();
        original.get_mut()[0] ^= 0xff;
        original.set_position(0);
        let mut rest = Vec::new();
        owned.read_to_end(&mut rest).unwrap();
        assert_eq!(rest, data);
    }
    #[tokio::test]
    async fn drop_cleans_only_own_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        {
            let data = b"drop cleanup".to_vec();
            let mut source = Cursor::new(data.clone());
            let owned = snapshot_then_verify(&mut source, data.len(), dir.path(), |f| async {
                Ok::<File, AttachmentSourceFileError>(f)
            })
            .await
            .unwrap();
            drop(owned);
        }
        let entries: Vec<_> = std::fs::read_dir(dir.path()).unwrap().collect();
        assert!(entries.is_empty());
    }
}
