    pub(crate) fn classify_readback_with_wire(&self, remote: &Record, remote_wire: &[u8])
        -> crate::cloud_sync_message_update_stage::MessageUpdateReadbackState {
        crate::cloud_sync_message_update_stage::classify_conditional_update_readback_with_presence(
            &self.predecessor, &self.request, remote, self.protection_metadata, remote_wire)
    }
    pub(crate) fn missing(&self) -> &[MissingLineagePrerequisite] {
        use MissingLineagePrerequisite::*;
        &[TrustedParentBinding, NativeMutationAuthority, DurableObjectBoxAdoption]
    }
