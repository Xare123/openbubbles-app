#[cfg(test)]
mod sensitive_decode_diagnostics_tests {
    use super::*;
    use serde::{Deserialize, Serialize};
    use std::{any::Any, panic::AssertUnwindSafe};

    #[derive(Debug, Deserialize, Serialize)]
    struct PrivatePlistFixture;

    impl CloudKitBytesKind for PrivatePlistFixture {
        type Kind = sealed::PlistKind;
    }

    fn panic_message(payload: Box<dyn Any + Send>) -> String {
        if let Some(message) = payload.downcast_ref::<String>() {
            return message.clone();
        }
        if let Some(message) = payload.downcast_ref::<&str>() {
            return (*message).to_owned();
        }
        String::new()
    }

    #[test]
    fn malformed_decrypted_plist_does_not_enter_panic_text() {
        let private_plaintext = b"private-message-body-fixture";
        let panic = std::panic::catch_unwind(AssertUnwindSafe(|| {
            <PrivatePlistFixture as CloudKitBytes>::from_bytes(private_plaintext.to_vec())
        }))
        .expect_err("fixture is not a valid plist");
        let message = panic_message(panic);

        assert!(message.contains("CloudKit plist deserialization failed"));
        assert!(!message.contains("private-message-body-fixture"));
        assert!(!message.contains(&encode_hex(private_plaintext)));
    }
}
