use rustpush::PushError;

/// Keep hosted renewal tickets available, but do not mistake unrelated
/// validation failures for a successful health check. This does not register a
/// device, save hardware, or make another network request.
pub(crate) fn relay_ticket_after_validation(
    validation: Result<Vec<u8>, PushError>,
    relay_ticket: Option<&str>,
) -> Result<Option<String>, PushError> {
    match validation {
        Ok(_) => Ok(relay_ticket.map(str::to_owned)),
        Err(PushError::RelayError(_, message)) => {
            // Existing callers need the original ticket to renew or replace a
            // hosted device. Returning it is not proof of successful validation.
            if message.contains("Subscription not active!")
                || message.contains("Ticket not activated!")
                || message.contains("Sorry, your hosted device is currently offline!")
            {
                Ok(relay_ticket.map(str::to_owned))
            } else {
                Ok(None)
            }
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TICKET: &str = "TEST-RELAY-TICKET";

    #[test]
    fn successful_validation_returns_only_an_existing_relay_ticket() {
        assert_eq!(
            relay_ticket_after_validation(Ok(vec![1]), Some(TICKET)).unwrap(),
            Some(TICKET.to_owned())
        );
        assert_eq!(
            relay_ticket_after_validation(Ok(vec![1]), None).unwrap(),
            None
        );
    }

    #[test]
    fn unavailable_mac_provider_is_not_a_successful_health_check() {
        for ticket in [None, Some(TICKET)] {
            let result =
                relay_ticket_after_validation(Err(PushError::MacValidationUnavailable), ticket);
            assert!(matches!(result, Err(PushError::MacValidationUnavailable)));
        }
    }

    #[test]
    fn missing_device_is_not_reported_as_a_valid_ticket() {
        let result = relay_ticket_after_validation(Err(PushError::DeviceNotFound), Some(TICKET));
        assert!(matches!(result, Err(PushError::DeviceNotFound)));
    }

    #[test]
    fn unexpected_validation_failure_retains_its_error() {
        let result = relay_ticket_after_validation(Err(PushError::ResourceTimeout), Some(TICKET));
        assert!(matches!(result, Err(PushError::ResourceTimeout)));
    }

    #[test]
    fn network_failure_cannot_trigger_successful_ticket_recovery() {
        let result = relay_ticket_after_validation(
            Err(PushError::IoError(std::io::Error::new(
                std::io::ErrorKind::ConnectionRefused,
                "synthetic connection refused",
            ))),
            Some(TICKET),
        );
        assert!(matches!(result, Err(PushError::IoError(error))
            if error.kind() == std::io::ErrorKind::ConnectionRefused));
    }

    #[test]
    fn hosted_renewal_and_offline_recovery_keep_the_original_ticket() {
        for message in [
            "Subscription not active!",
            "Ticket not activated!",
            "Sorry, your hosted device is currently offline!",
        ] {
            assert_eq!(
                relay_ticket_after_validation(
                    Err(PushError::RelayError(403, message.to_owned())),
                    Some(TICKET),
                )
                .unwrap(),
                Some(TICKET.to_owned())
            );
        }
    }

    #[test]
    fn recovery_message_never_creates_a_missing_ticket() {
        assert_eq!(
            relay_ticket_after_validation(
                Err(PushError::RelayError(
                    403,
                    "Ticket not activated!".to_owned()
                )),
                None,
            )
            .unwrap(),
            None
        );
    }

    #[test]
    fn other_relay_rejections_do_not_return_an_authorized_ticket() {
        for message in ["Invalid token", "Ticket already consumed", "Unknown error"] {
            assert_eq!(
                relay_ticket_after_validation(
                    Err(PushError::RelayError(401, message.to_owned())),
                    Some(TICKET),
                )
                .unwrap(),
                None
            );
        }
    }

    #[cfg(not(target_os = "macos"))]
    #[tokio::test]
    async fn public_validation_api_preserves_the_unavailable_mac_provider_error() {
        use crate::api::api::{validate_relay, JoinedOSConfig};
        use rustpush::macos::{HardwareConfig, MacOSConfig};
        use std::sync::Arc;

        // The public non-macOS provider rejects this synthetic configuration
        // before requesting anything from Apple. No real identity is needed.
        let config = JoinedOSConfig::MacOS(Arc::new(MacOSConfig {
            inner: HardwareConfig {
                product_name: "Macmini9,1".to_owned(),
                io_mac_address: [0; 6],
                platform_serial_number: "TESTSERIAL".to_owned(),
                platform_uuid: "00000000-0000-0000-0000-000000000000".to_owned(),
                root_disk_uuid: "00000000-0000-0000-0000-000000000000".to_owned(),
                board_id: "Mac-TEST".to_owned(),
                os_build_num: "TEST".to_owned(),
                platform_serial_number_enc: vec![],
                platform_uuid_enc: vec![],
                root_disk_uuid_enc: vec![],
                rom: vec![],
                rom_enc: vec![],
                mlb: "TESTMLB".to_owned(),
                mlb_enc: vec![],
            },
            version: "0.0".to_owned(),
            protocol_version: 0,
            device_id: "00000000-0000-0000-0000-000000000000".to_owned(),
            icloud_ua: "test/0".to_owned(),
            aoskit_version: "test/0".to_owned(),
            udid: Some("TEST".to_owned()),
        }));

        let error = validate_relay(&config)
            .await
            .expect_err("an unavailable Mac provider must not pass the public health check");
        assert!(matches!(
            error.downcast_ref::<PushError>(),
            Some(PushError::MacValidationUnavailable)
        ));
    }
}
