/// Liveness: Every Counter that starts (eCounterInit) eventually finishes
/// (eCounterDone).
spec LivenessCounterProgress observes eCounterInit, eCounterDone {
    /// Active (started, not yet completed) counter count.
    var activeCounters: int;

    /// No counters active at system start.
    start state Init {
        entry {
            activeCounters = 0;
            goto Done;
        }
    }

    /// Hot state: Active counters exist and the system must eventually progress.
    /// This state is marked as "hot" for liveness checking, meaning the system
    /// cannot remain in this state indefinitely - it must eventually transition
    /// to the Done state when all counters complete.
    hot state ActiveCountersExist {
        on eCounterInit do {
            activeCounters = activeCounters + 1;
        }

        on eCounterDone do {
            activeCounters = activeCounters - 1;
            if (activeCounters == 0) {
                goto Done;
            }
        }
    }

    /// Cold state: No active counters exist. This is a safe state where the
    /// system can remain indefinitely without violating liveness properties.
    cold state Done {
        on eCounterInit do {
            activeCounters = activeCounters + 1;
            goto ActiveCountersExist;
        }

        on eCounterDone do {
            assert false, "Received eCounterDone when no active counters exist";
        }
    }
}
