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

    /// The "safe" LSN is the last LSN of the log prefix this counter
    /// has complete knowledge of. If GC advances its watermark beyond this LSN,
    /// the counter must perform full recovery, because chunks it read past this
    /// point may have been deleted and re-created.
    ///
    /// It is initialized with the snapshot LSN at recovery and advanced each
    /// time a read or append is validated, as long as the GC watermark hasn't
    /// passed it.
    ///
    /// This mechanism prevents write loss when the counter falls behind and the
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
            var snapshot: tSnapshot;

            // Reset user-defined state.
            mem = default(tCounterState);

            // Recovery.
            versionedManifest = downloadManifest(this, objectStore);
            print format("{0} starting with manifest: {1}", this, versionedManifest);

            if (versionedManifest.m.snapshotLsn >= 0) {
                snapshot = downloadSnapshot(this, objectStore, versionedManifest.m.snapshotLsn);
                if (!snapshot.found) {
                    print format("{0} snapshot at LSN {1} was garbage collected, restarting recovery",
                        this, versionedManifest.m.snapshotLsn);
                    goto SnapshotRecovery;
                }
                mem = snapshot.body as tCounterState;
                print format("{0} recovered snapshot at LSN {1}: {2}",
                    this, versionedManifest.m.snapshotLsn, mem);
            }

            // Snapshot covers the log prefix through snapshotLsn.
            safeLsn = versionedManifest.m.snapshotLsn;

            if (!(id in mem.writers)) {
                mem.writers[id] = 0;
            }

            goto CatchUpRecovery;
        }
    }

    state CatchUpRecovery {
        entry {
            var chunk: tLogChunk;
            var nextLsn: int;

            nextLsn = safeLsn + 1;

            while (true) {
                chunk = downloadChunk(this, objectStore, nextLsn);
                if (chunk.found) {
                    applyChunk(chunk.body as tIncOp);
                    nextLsn = nextLsn + 1;
                } else {
                    break;
                }
            }

            // Post condition:
            //   conflict -> goto SnapshotRecovery
            //   no conflict -> safeLsn = nextLsn - 1
            validateAndAdvanceSafeLsn(nextLsn - 1);

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
            var chunkLsn: int;
            var op: tIncOp;
            var uploadChunkResult: tUploadChunkResult;

            if (safeLsn >= 0) {
                announce eCounterState, (sender=this, value=mem.value, lsn=safeLsn);
            }

            // Assert we never lost our own committed increments.
            assert myCounterValue <= mem.writers[id],
                format("Lost committed increments: expected at least {0}, got {1}",
                    myCounterValue, mem.writers[id]);

            while (mem.writers[id] < numIncrements) {
                chunkLsn = safeLsn + 1;

                op = (writer=id, prevValue=mem.writers[id]);
                uploadChunkResult = uploadChunk(this, objectStore, chunkLsn, op);
                if (!uploadChunkResult.conflict) {
                    // Post condition:
                    //   conflict -> goto SnapshotRecovery
                    //   no conflict -> safeLsn = chunkLsn
                    validateAndAdvanceSafeLsn(chunkLsn);

                    // Apply committed chunk locally.
                    applyChunk(op);
                    myCounterValue = myCounterValue + 1;

                    announce eCounterState, (sender=this, value=mem.value, lsn=safeLsn);

                    if ($) {
                        writeSnapshotAsync(objectStore, safeLsn, mem);
                    }
                } else {
                    // See https://nvartolomei.com/oswald/#writer-writer-conflicts
                    print format("{0} detected conflict during append at LSN {1}", this, chunkLsn);

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
    /// If a change is detected, it validates whether our safeLsn is still at
    /// or above the garbage collection watermark. If not, it triggers a full
    /// recovery to prevent operating on potentially garbage-collected state.
    ///
    /// This prevents write loss scenarios where:
    /// 1. Counter falls behind and relies on old chunks
    /// 2. Garbage collector removes those chunks
    /// 3. Counter attempts to continue from an inconsistent state
    fun validateAndAdvanceSafeLsn(lsn: int) {
        var freshVersionedManifest: tVersionedManifest;

        // A real system would use GET-If-None-Match on the manifest to skip
        // the download when it hasn't changed. Here, we download
        // unconditionally but skip the GC check when the version matches to
        // illustrate that the optimization is sound.
        freshVersionedManifest = downloadManifest(this, objectStore);
        if (freshVersionedManifest.v != versionedManifest.v) {
            print format(
                "{0} detected manifest version change during recovery: {1} -> {2}",
                this, versionedManifest.v, freshVersionedManifest.v
            );

            // The GC watermark has passed safeLsn: chunks after it that we read
            // or wrote may have been deleted and re-created. Restart full recovery.
            //
            // See https://nvartolomei.com/oswald/#writer-garbage-collector-conflicts
            // See https://nvartolomei.com/oswald/#tailer-garbage-collector-conflicts
            if (safeLsn < freshVersionedManifest.m.gcWatermark) {
                goto SnapshotRecovery;
            }

            // Cache the fresh manifest so the next check can take the fast path.
            versionedManifest = freshVersionedManifest;
        }

        // Passed: the GC watermark hasn't passed safeLsn, so no chunk after it
        // has been deleted. Every chunk we read or wrote after safeLsn is
        // therefore canonical (the original PUT for its LSN), not a ghost
        // re-created after collection. Extend the validated history over them.
        safeLsn = lsn;
    }
}
