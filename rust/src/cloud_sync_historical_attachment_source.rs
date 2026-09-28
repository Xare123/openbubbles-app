//! Attachment material from one protected historical source, never an IDS
//! receipt. Decode the retained descriptor without calling the panic-prone
//! legacy FFI helper or reading mutable ObjectBox rows. Byte availability and
//! cryptographic verification belong to the existing private-file preparer.
#![cfg_attr(not(test), allow(dead_code))]

use crate::{
    cloud_sync_historical_media::apple_guid,
    cloud_sync_historical_source::{HistoricalArchiveOrigin, HistoricalArchiveSource},
    cloud_sync_ids_attachment_source::DecodedAttachmentUploadMaterial,
    cloud_sync_outbound::CloudSyncOutboundFailure as Failure,
};
use rustpush::{cloud_messages::AttachmentMeta, Attachment, AttachmentType};
use std::io::Cursor;

/// This returned value contains descriptor/metadata only, not proof of a send
/// or upload permission. Selection and direction come from the exact frozen
/// historical source. The advertised database byte count is not file evidence.
pub(crate) fn historical_attachment_upload_material(
    source: &HistoricalArchiveSource,
    attachment_guid: &str,
) -> Result<DecodedAttachmentUploadMaterial, Failure> {
    let media = source.media().ok_or(Failure::UnsupportedMessage)?;
    media.validate(source.guid(), source.text())?;
    let canonical = apple_guid(attachment_guid, source.guid())?;
    let selected = media
        .4
         .1
        .iter()
        .find(|entry| {
            entry.3.as_deref().is_some_and(|guid| {
                apple_guid(guid, source.guid()).is_ok_and(|guid| guid == canonical)
            })
        })
        .ok_or(Failure::BindingMismatch)?;
    let json = selected.15.as_deref().ok_or(Failure::UnsupportedMessage)?;
    let metadata: serde_json::Value =
        serde_json::from_str(json).map_err(|_| Failure::MalformedMessage)?;
    let xml = metadata
        .get("rustpush")
        .and_then(serde_json::Value::as_str)
        .filter(|xml| !xml.is_empty())
        .ok_or(Failure::UnsupportedMessage)?;
    let attachment: Attachment = plist::from_reader_xml(Cursor::new(xml.as_bytes()))
        .map_err(|_| Failure::MalformedMessage)?;
    let AttachmentType::MMCS(file) = &attachment.a_type else {
        // Inline and CloudKit-only descriptors need their own original-byte
        // proof. Never fabricate MMCS keys or silently omit those rows.
        return Err(Failure::UnsupportedMessage);
    };
    if file.key.len() != 32
        || file.signature.len() != 21
        || file.signature.first() != Some(&0x81)
        || attachment.part > u32::MAX as u64
    {
        return Err(Failure::MalformedMessage);
    }
    bounded_nonempty(&file.object, 8192)?;
    bounded_nonempty(&file.url, 8192)?;
    bounded_nonempty(&attachment.name, 4096)?;
    bounded_nonempty(&attachment.mime, 4096)?;
    bounded_nonempty(&attachment.uti_type, 4096)?;
    // Attachment -> MMCSAttachmentMeta narrows length to u32. Check before it,
    // and before the private snapshot allocates or reads any file bytes.
    let total_bytes = u32::try_from(file.size).map_err(|_| Failure::OversizedMessage)?;
    let name = selected.8.as_deref().unwrap_or(&attachment.name);
    let mime = selected.6.as_deref().unwrap_or(&attachment.mime);
    let uti = selected.5.as_deref().unwrap_or(&attachment.uti_type);
    bounded_nonempty(name, 4096)?;
    bounded_nonempty(mime, 4096)?;
    bounded_nonempty(uti, 4096)?;
    let time = i64::try_from(source.sent_timestamp())
        .ok()
        .and_then(|value| value.checked_sub(978_307_200_000))
        .and_then(|value| value.checked_mul(1_000_000))
        .filter(|value| *value > 0)
        .ok_or(Failure::MalformedMessage)?;
    let user_info: Option<rustpush::cloud_messages::MMCSAttachmentMeta> = (&attachment).into();
    let meta = AttachmentMeta {
        mime_type: Some(mime.to_owned()),
        // The stored snapshot has the message time, not a separate file birth
        // time. Use that stable historical time, never the import wall clock.
        start_date: time,
        total_bytes: i64::from(total_bytes),
        transfer_state: 5,
        is_sticker: false,
        guid: canonical,
        hide_attachment: false,
        user_info: Some(user_info.ok_or(Failure::MalformedMessage)?),
        filename: None,
        extras: Some(rustpush::cloud_messages::AttachmentMetaExtra {
            preview_generation_state: Some(rustpush::cloud_messages::NumOrString::Num(1)),
        }),
        // The parent source's qualified direction is authoritative. Attachment
        // rows can contain an old default flag from a different import path.
        is_outgoing: source.origin() == HistoricalArchiveOrigin::HistoricalSent,
        transfer_name: Some(name.to_owned()),
        version: 1,
        uti: Some(uti.to_owned()),
        created_date: time,
        pathc: Some(name.to_owned()),
        md5: None,
    };
    Ok(DecodedAttachmentUploadMaterial {
        meta,
        file: file.clone(),
        attachment,
    })
}

fn bounded_nonempty(value: &str, maximum: usize) -> Result<(), Failure> {
    if value.is_empty() || value.len() > maximum || value.chars().any(char::is_control) {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::cloud_sync_historical_source::{HistoricalBinding, HistoricalRow};
    use rustpush::MMCSFile;

    const PARENT: &str = "A1B2C3D4-E5F6-4A7B-8C9D-E0F1A2B3C4D5";

    pub(crate) fn descriptor() -> Attachment {
        Attachment {
            a_type: AttachmentType::MMCS(MMCSFile {
                signature: [vec![0x81], vec![0x31; 20]].concat(),
                object: "synthetic-original-object".into(),
                url: "https://example.invalid/synthetic-mmcs".into(),
                key: vec![0x42; 32],
                size: 37,
            }),
            // Neither the reflected GUID suffix nor attributed run messagePart
            // must equal the original transport attachment.part value.
            part: 2,
            uti_type: "public.jpeg".into(),
            mime: "image/jpeg".into(),
            name: "original.jpg".into(),
            iris: false,
        }
    }

    pub(crate) fn source_with(
        descriptor: &Attachment,
        sent: bool,
        mutate: impl FnOnce(&mut crate::cloud_sync_historical_media::HistoricalAttachmentState),
    ) -> HistoricalArchiveSource {
        let vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v4.json"
        ))
        .unwrap();
        let payload: serde_json::Value =
            serde_json::from_str(vectors[0]["canonicalPayload"].as_str().unwrap()).unwrap();
        let mut media: crate::cloud_sync_historical_media::HistoricalMedia =
            serde_json::from_value(payload["media"].clone()).unwrap();
        let mut xml = Vec::new();
        plist::to_writer_xml(&mut xml, descriptor).unwrap();
        let entry = &mut media.4 .1[0];
        entry.5 = Some(descriptor.uti_type.clone());
        entry.6 = Some(descriptor.mime.clone());
        entry.8 = Some(descriptor.name.clone());
        entry.15 =
            Some(serde_json::json!({"rustpush": String::from_utf8(xml).unwrap()}).to_string());
        mutate(entry);
        HistoricalArchiveSource::capture_with_media(
            &HistoricalRow {
                guid: PARENT,
                text: "",
                sender: if sent {
                    "self@example.com"
                } else {
                    "friend@example.com"
                },
                peer: "friend@example.com",
                chat_guid: "iMessage;-;friend@example.com",
                date_created_ms: 1_699_000_000_000,
                is_from_me: sent,
            },
            &HistoricalBinding {
                snapshot_sha256: &"ab".repeat(32),
                account_fingerprint: "synthetic-account",
                protected_store_identity: "synthetic-store",
            },
            sent,
            None,
            None,
            Some(media),
        )
        .unwrap()
    }

    pub(crate) fn guid(source: &HistoricalArchiveSource) -> String {
        source.media().unwrap().4 .1[0].3.clone().unwrap()
    }

    #[test]
    fn frozen_descriptor_keeps_identity_direction_and_historical_time() {
        for sent in [false, true] {
            let source = source_with(&descriptor(), sent, |entry| {
                entry.7 = Some(!sent);
                entry.9 = Some(1024 * 1024); // Advertised count is not byte proof.
            });
            let material = historical_attachment_upload_material(&source, &guid(&source)).unwrap();
            assert_eq!(material.meta.is_outgoing, sent);
            assert_eq!(material.meta.total_bytes, 37);
            assert_eq!(material.meta.start_date, 720_692_800_000_000_000);
            assert_eq!(material.meta.created_date, material.meta.start_date);
            assert_eq!(material.meta.transfer_name.as_deref(), Some("original.jpg"));
            assert!(material.meta.filename.is_none());
            assert!(material.meta.md5.is_none());
            assert_eq!(material.attachment.part, 2);
            assert_eq!(material.file.object, "synthetic-original-object");
        }
    }

    #[test]
    fn selection_requires_the_exact_owned_inventory_part() {
        let source = source_with(&descriptor(), false, |_| {});
        let canonical = apple_guid(&guid(&source), source.guid()).unwrap();
        assert!(historical_attachment_upload_material(&source, &canonical).is_ok());
        for wrong in [
            "missing-guid",
            "at_0_other-owner",
            "at_99_A1B2C3D4-E5F6-4A7B-8C9D-E0F1A2B3C4D5",
        ] {
            assert!(historical_attachment_upload_material(&source, wrong).is_err());
        }
    }

    #[test]
    fn malformed_missing_cloud_only_and_inline_descriptors_do_not_panic_or_invent_material() {
        for metadata in [
            None,
            Some("{}".to_owned()),
            Some("{\"cloud\":\"old-record\"}".to_owned()),
            Some("{\"rustpush\":\"<broken>\"}".to_owned()),
        ] {
            let source = source_with(&descriptor(), false, |entry| entry.15 = metadata);
            assert!(historical_attachment_upload_material(&source, &guid(&source)).is_err());
        }
        let mut inline = descriptor();
        inline.a_type = AttachmentType::Inline(vec![1, 2, 3]);
        let source = source_with(&inline, false, |_| {});
        assert!(matches!(
            historical_attachment_upload_material(&source, &guid(&source)),
            Err(Failure::UnsupportedMessage)
        ));
    }

    #[test]
    fn descriptor_lengths_keys_and_metadata_are_bounded_before_conversion() {
        for mutate in [
            (|file: &mut MMCSFile| file.key.pop().map(|_| ()).unwrap()) as fn(&mut MMCSFile),
            |file| file.signature[0] = 0x82,
            |file| file.signature.clear(),
            |file| file.object.clear(),
            |file| file.url = "bad\0url".into(),
            |file| file.size = (u32::MAX as u64 + 1) as usize,
        ] {
            let mut attachment = descriptor();
            let AttachmentType::MMCS(file) = &mut attachment.a_type else {
                unreachable!()
            };
            mutate(file);
            let source = source_with(&attachment, false, |_| {});
            assert!(historical_attachment_upload_material(&source, &guid(&source)).is_err());
        }
        let source = source_with(&descriptor(), false, |entry| {
            entry.8 = Some("bad\0name".into())
        });
        assert!(historical_attachment_upload_material(&source, &guid(&source)).is_err());
    }

    #[test]
    fn stored_display_metadata_and_original_descriptor_both_survive() {
        let source = source_with(&descriptor(), false, |entry| {
            entry.8 = Some("saved-name.jpg".into());
            entry.6 = None;
            entry.5 = None;
        });
        let material = historical_attachment_upload_material(&source, &guid(&source)).unwrap();
        assert_eq!(
            material.meta.transfer_name.as_deref(),
            Some("saved-name.jpg")
        );
        assert_eq!(material.meta.mime_type.as_deref(), Some("image/jpeg"));
        assert_eq!(material.meta.uti.as_deref(), Some("public.jpeg"));
        assert_eq!(
            material.meta.user_info.unwrap().name.as_deref(),
            Some("original.jpg")
        );
    }

    #[tokio::test]
    async fn decoded_historical_descriptor_verifies_real_private_snapshot_bytes() {
        use std::io::{Read, Seek, SeekFrom};
        let bytes = b"synthetic historical photo bytes";
        let key = vec![0x42; 32];
        let ciphertext = openssl::symm::encrypt(
            openssl::symm::Cipher::aes_256_ctr(),
            &key,
            Some(&[0; 16]),
            bytes,
        )
        .unwrap();
        let prepared = rustpush::prepare_put(
            rustpush::FileContainer::new(Cursor::new(ciphertext)),
            false,
            0x81,
        )
        .await
        .unwrap();
        let mut attachment = descriptor();
        attachment.a_type = AttachmentType::MMCS(MMCSFile {
            signature: prepared.total_sig,
            object: "synthetic-original-object".into(),
            url: "https://example.invalid/synthetic-mmcs".into(),
            key,
            size: bytes.len(),
        });
        let historical = source_with(&attachment, false, |_| {});
        let material =
            historical_attachment_upload_material(&historical, &guid(&historical)).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let mut input = Cursor::new(bytes.to_vec());
        let mut owned = crate::cloud_sync_attachment_source_file::snapshot_verified_source(
            &mut input,
            &material.file,
            directory.path(),
        )
        .await
        .unwrap();
        // Mutating the caller buffer does not change the verified private copy.
        input.get_mut()[0] ^= 1;
        let mut restored = Vec::new();
        owned.read_to_end(&mut restored).unwrap();
        assert_eq!(restored, bytes);
        input.seek(SeekFrom::Start(0)).unwrap();
        assert!(
            crate::cloud_sync_attachment_source_file::snapshot_verified_source(
                &mut input,
                &material.file,
                directory.path(),
            )
            .await
            .is_err()
        );
        drop(owned);
        assert!(std::fs::read_dir(directory.path())
            .unwrap()
            .next()
            .is_none());
    }
}
