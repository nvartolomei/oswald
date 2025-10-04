test concurrentCounters [main=ConcurrentCounters]:
    assert LivenessCounterProgress
        , SafetyLsnConsistency
        , SafetyCounterMonotonicity
        in (union { Counter, AsyncSnapshotWriter, GarbageCollector }
                , { ObjectStore, Timer }
                , { ConcurrentCounters });
