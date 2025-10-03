event eCounterInit: (sender: Counter);
event eCounterDone: (sender: Counter, value: int);

event eCounterState: (sender: Counter, value: int, lsn: int);

/// Counter is a simple replicated, increment-only counter that uses OSWALD for
/// durable state and synchronization. It showcases how a state machine can be
/// built on top of the OSWALD primitives.
machine Counter {
    var parent: machine;
    var objectStore: ObjectStore;
    var versionedManifest: tVersionedManifest;

    /// Log Sequence Number (LSN) to assign to the next log chunk.
    var nextLsn: int;

    /// User state: current counter value.
    var value: int;

    /// Number of increment operations left to execute.
    var incrementsLeft: int;

    /// Initial state that sets up the counter and begins the recovery process.
    start state Init {
        entry (input: (parent: machine, objectStore: ObjectStore, numIncrements: int)) {
            parent = input.parent;
            objectStore = input.objectStore;
            incrementsLeft = input.numIncrements;

            announce eCounterInit, (sender=this,);

            goto SnapshotRecovery;
        }
    }

    state SnapshotRecovery {
        entry {
            // Reset user-defined state.
            value = 0;

            // Recovery.
            versionedManifest = downloadManifest(this, objectStore);
            print format("{0} starting with manifest: {1}", this, versionedManifest);

            if (versionedManifest.m.snapshotLsn >= 0) {
                value = downloadSnapshot(this, objectStore, versionedManifest.m.snapshotLsn) as int;
                print format("{0} recovered snapshot at LSN {1}: {2}",
                    this, versionedManifest.m.snapshotLsn, value);
            }

            nextLsn = versionedManifest.m.snapshotLsn + 1;

            goto CatchUpRecovery;
        }
    }

    state CatchUpRecovery {
        entry {
            var manifestAfterCatchUp: tVersionedManifest;
            var chunk: tLogChunk;
            while (true) {
                chunk = downloadChunk(this, objectStore, nextLsn);
                if (chunk.found) {
                    applyChunk(chunk.body);
                    nextLsn = nextLsn + 1;
                } else {
                    break;
                }
            }

            // Check for concurrency conflict.
            validateLsnSeqConsistency(nextLsn);

            if (nextLsn == 0) {
                print "No chunks found, starting fresh.";
            } else {
                print format("Caught up to chunk {0}", nextLsn - 1);
            }

            goto Ready;
        }
    }

    state Ready {
        entry {
            var tUploadChunkResult: tUploadChunkResult;

            if (nextLsn > 0) {
                announce eCounterState, (sender=this, value=value, lsn=nextLsn - 1);
            }

            while (incrementsLeft > 0) {
                tUploadChunkResult = uploadChunk(this, objectStore, nextLsn, "+");
                if (!tUploadChunkResult.conflict) {
                    validateLsnSeqConsistency(nextLsn);

                    // Apply committed chunk locally.
                    applyChunk("+");
                    nextLsn = nextLsn + 1;

                    announce eCounterState, (sender=this, value=value, lsn=nextLsn - 1);

                    if ($) {
                        writeSnapshotAsync(objectStore, nextLsn - 1, value);
                    }
                } else {
                    print format("{0} detected conflict during append at LSN {1}", this, nextLsn);

                    // Catch up with latest state and retry.
                    goto CatchUpRecovery;
                }

                incrementsLeft = incrementsLeft - 1;
            }

            goto Done;
        }
    }

    state Done {
        entry {
            send parent, eCounterDone, (sender=this, value=value);
        }
    }

    fun applyChunk(body: data) {
        assert body == "+";
        value = value + 1;
    }

    /// Ensures that the manifest has not been updated by another process
    /// (like a garbage collector) while the current operation was in flight.
    /// If a change is detected, it triggers a full recovery.
    fun validateLsnSeqConsistency(lsn: int) {
        var freshVersionedManifest: tVersionedManifest;

        // NOTE: Real system would use GET-If-None-Match to avoid re-download
        // when unchanged.
        freshVersionedManifest = downloadManifest(this, objectStore);
        if (freshVersionedManifest.v != versionedManifest.v) {
            print format(
                "{0} detected manifest version change during recovery: {1} -> {2}",
                this, versionedManifest.v, freshVersionedManifest.v
            );

            // TODO: fix recovery condition after fixing the idempotency bug
            // in incrementing but before GC!
            return;

            // Restart recovery.
            goto SnapshotRecovery;
        }
    }
}
