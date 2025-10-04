event eCounterInit: (sender: Counter);
event eCounterDone: (sender: Counter, value: int);

event eCounterState: (sender: Counter, value: int, lsn: int);

type tWriterId = string;

type tIncOp = (writer: tWriterId, prevValue: int);

/// Counter state: current value and per-writer last applied values for
/// idempotency.
type tCounterState = (value: int, writers: map[tWriterId, int]);

/// Counter is a simple replicated, increment-only counter that uses OSWALD for
/// durable state and synchronization. It showcases how a state machine can be
/// built on top of the OSWALD primitives.
machine Counter {
    var id: tWriterId;

    var parent: machine;
    var objectStore: ObjectStore;
    var versionedManifest: tVersionedManifest;

    /// Log Sequence Number (LSN) to assign to the next log chunk.
    var nextLsn: int;

    /// The "safe" LSN is a checkpoint in the LSN sequence that this counter has
    /// has complete knowledge of. If GC advances the watermark beyond this LSN,
    /// the counter must perform full recovery to avoid operating on potentially
    /// garbage-collected state.
    ///
    /// It is initialized with the snapshot LSN at the time of recovery and
    /// periodically updated to latest LSN as long as we are ahead of the GC
    /// watermark.
    ///
    /// This mechanism prevents write loss when a counter falls behind and the
    /// garbage collector removes chunks under its feet.
    var safeLsn: int;

    /// User state.
    var mem: tCounterState;

    /// Number of increments to perform by this writer.
    var numIncrements: int;

    /// For internal invariants.
    var myCounterValue: int;

    /// Initial state that sets up the counter and begins the recovery process.
    start state Init {
        entry (input: (parent: machine, objectStore: ObjectStore, numIncrements: int)) {
            id = format("{0}", this);

            parent = input.parent;
            objectStore = input.objectStore;
            numIncrements = input.numIncrements;

            announce eCounterInit, (sender=this,);

            goto SnapshotRecovery;
        }
    }

    state SnapshotRecovery {
        entry {
            // Reset user-defined state.
            mem = default(tCounterState);

            // Recovery.
            versionedManifest = downloadManifest(this, objectStore);
            print format("{0} starting with manifest: {1}", this, versionedManifest);

            if (versionedManifest.m.snapshotLsn >= 0) {
                mem = downloadSnapshot(this, objectStore, versionedManifest.m.snapshotLsn) as tCounterState;
                print format("{0} recovered snapshot at LSN {1}: {2}",
                    this, versionedManifest.m.snapshotLsn, mem);
            }

            // Set safeLsn to the current snapshot LSN - this is our "safe point"
            // that we know hasn't been garbage collected yet.
            safeLsn = versionedManifest.m.snapshotLsn;
            nextLsn = versionedManifest.m.snapshotLsn + 1;

            if (!(id in mem.writers)) {
                mem.writers[id] = 0;
            }

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
                    applyChunk(chunk.body as tIncOp);
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
            var op: tIncOp;
            var tUploadChunkResult: tUploadChunkResult;

            if (nextLsn > 0) {
                announce eCounterState, (sender=this, value=mem.value, lsn=nextLsn - 1);
            }

            // Assert we never lost our own committed increments.
            assert myCounterValue <= mem.writers[id],
                format("Lost committed increments: expected at least {0}, got {1}",
                    myCounterValue, mem.writers[id]);

            while (mem.writers[id] < numIncrements) {
                op = (writer=id, prevValue=mem.writers[id]);
                tUploadChunkResult = uploadChunk(this, objectStore, nextLsn, op);
                if (!tUploadChunkResult.conflict) {
                    validateLsnSeqConsistency(nextLsn);

                    // Apply committed chunk locally.
                    applyChunk(op);
                    myCounterValue = myCounterValue + 1;
                    nextLsn = nextLsn + 1;

                    announce eCounterState, (sender=this, value=mem.value, lsn=nextLsn - 1);

                    if ($) {
                        writeSnapshotAsync(objectStore, nextLsn - 1, mem);
                    }
                } else {
                    print format("{0} detected conflict during append at LSN {1}", this, nextLsn);

                    // Catch up with latest state and retry.
                    goto CatchUpRecovery;
                }
            }

            goto Done;
        }
    }

    state Done {
        entry {
            send parent, eCounterDone, (sender=this, value=mem.value);
        }
    }

    fun applyChunk(body: tIncOp) {
        if (!(body.writer in mem.writers)) {
            mem.writers[body.writer] = 0;
        }

        if (mem.writers[body.writer] == body.prevValue) {
            // This operation has not been applied yet.
            mem.value = mem.value + 1;
            mem.writers[body.writer] = mem.writers[body.writer] + 1;
        } else {
            // Duplicate operation, ignore.
        }
    }

    /// Ensures that the manifest has not been updated by another process
    /// (like a garbage collector) while the current operation was in flight.
    /// If a change is detected, it validates whether our safeLsn is still
    /// above the garbage collection watermark. If not, it triggers a full
    /// recovery to prevent operating on potentially garbage-collected state.
    ///
    /// This prevents write loss scenarios where:
    /// 1. Counter falls behind and relies on old chunks
    /// 2. Garbage collector removes those chunks
    /// 3. Counter attempts to continue from an inconsistent state
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

            // Our safe LSN has been garbage collected - restart full recovery.
            // Chunks we depend on may have been garbage collected and we need
            // full recovery.
            //
            // See https://nvartolomei.com/oswald/#writer-garbage-collector-conflicts
            if (safeLsn <= freshVersionedManifest.m.gcWatermark) {
                goto SnapshotRecovery;
            }


        }

        /// No manifest change, GC is surely behind our safe point.
        safeLsn = lsn;
    }
}
