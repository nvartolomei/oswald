test concurrentCounters [main=ConcurrentCounters]:
    assert LivenessCounterProgress
        , SafetyLsnConsistency
        , SafetyCounterMonotonicity
        in (union { Counter }, { ObjectStore }, { ConcurrentCounters });
