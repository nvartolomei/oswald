/// Safety: Counter state is always the same for the same LSN.
spec SafetyLsnConsistency observes eCounterState {
    /// First-seen counter value per LSN.
    var valueByLsn: map[int, int];

    start state Observing {
        entry {}

        on eCounterState do (payload: (sender: Counter, value: int, lsn: int)) {
            validateCounterValueAtLsn(payload.value, payload.lsn);
        }
    }

    fun validateCounterValueAtLsn(value: int, lsn: int) {
        if (lsn in valueByLsn) {
            assert valueByLsn[lsn] == value,
                format("Mismatching value at LSN {0}: expected {1} got {2}",
                    lsn, valueByLsn[lsn], value);
        } else {
            valueByLsn[lsn] = value;
        }
    }
}
