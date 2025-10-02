/// Safety: Per-counter values are monotonically non-decreasing, and any newly
/// initialized Counter starts from at least the globally observed maximum.
spec SafetyCounterMonotonicity observes eCounterState, eCounterInit {
    var maxObservedValue: int;
    var maxValueByCounter: map[Counter, int];

    start state Observing {
        entry {}

        on eCounterState do (payload: (sender: Counter, value: int, lsn: int)) {
            updateMaxObservedValue(payload.value);
            // Per-counter monotonicity.
            assert payload.value >= maxValueByCounter[payload.sender],
                format("Counter {0} value decreased: prev {1}, now {2}",
                       payload.sender, maxValueByCounter[payload.sender], payload.value);
            maxValueByCounter[payload.sender] = payload.value;
	}

        /// Initialize this counter's baseline to the current global max.
        on eCounterInit do (payload: (sender: Counter)) {
            maxValueByCounter[payload.sender] = maxObservedValue;
        }
    }

    fun updateMaxObservedValue(value: int) {
        if (value > maxObservedValue) {
            maxObservedValue = value;
        }
    }
}
