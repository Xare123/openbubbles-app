    pub(crate) fn into_changes_with_original_wire(
        self,
    ) -> Result<Vec<(RecordChange, Option<Vec<u8>>)>, PushError> {
        let wires = self.original_record_wires.ok_or(PushError::BadMsg)?;
        if wires.len() != self.changes.len() { return Err(PushError::BadMsg); }
        for (change, raw) in self.changes.iter().zip(&wires) {
            validate_original_change_pair(change, raw.as_deref())?;
        }
        Ok(self.changes.into_iter().zip(wires).collect())
    }
