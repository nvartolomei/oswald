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
            assert myCounterValue <= mem.writers[id];

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

            // TODO: optimize recovery condition.

            // Restart recovery.
            goto SnapshotRecovery;
        }
    }
}
