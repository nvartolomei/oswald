test concurrentCounters [main=ConcurrentCounters]:
    assert LivenessCounterProgress
        , SafetyLsnConsistency
        , SafetyCounterMonotonicity
        , SafetyManifestMonotonicity
        in (union { Counter, AsyncSnapshotWriter }
                , { ObjectStore, Timer }
                , { ConcurrentCounters });
