        fn from_bytes(v: Vec<u8>) -> Self {
            let result = Self::decode(&v[..]);
            if result.is_err() {
                // This input has already been decrypted. Never include it in
                // logs or panic text, even when decoding fails.
                println!("Failed to decode CloudKit protobuf");
            }
            result.unwrap_or_default()
        }
        fn to_bytes(&self) -> Vec<u8> {
            self.encode_to_vec()
        }
    }

    impl<T: Serialize + DeserializeOwned + CloudKitBytesKind<Kind = sealed::PlistKind>> CloudKitBytes for T {
        fn from_bytes(v: Vec<u8>) -> Self {
            match plist::from_bytes(&v) {
                Ok(value) => value,
                Err(_) => panic!("CloudKit plist deserialization failed"),
            }
        }

        fn to_bytes(&self) -> Vec<u8> {
            let mut buf = vec![];
            let cursor = Cursor::new(&mut buf);
            plist::to_writer_binary(cursor, self).expect("Serialization failed!");
            buf
        }
    }
