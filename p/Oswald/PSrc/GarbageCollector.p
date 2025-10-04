event eGCStart;

/// GarbageCollector is a machine that periodically advances the GC watermark
/// and deletes obsolete objects from the ObjectStore.
machine GarbageCollector {
    var store: ObjectStore;
    var timer: Timer;

    // Not required for correctness. Optimization for the model checker.
    var lowerBound: int;

    start state Init {
        entry (input: (store: ObjectStore)) {
            store = input.store;
            timer = new Timer((user=this, timeoutEvent=eGCStart));
            goto Idle;
        }
    }

    state Idle {
        entry {
            send timer, eTimerStart;
        }

        on eGCStart do {
            if (advanceGcWatermark(this, store)) {
                goto Reclaim;
            } else {
                // No advancement, restart timer and wait.
                goto Idle;
            }
        }
    }

    state Reclaim {
        entry {
            lowerBound = removeObsoleteObjects(this, store, lowerBound);
            goto Idle;
        }
    }
}


/// Advances the GC watermark to the latest snapshot LSN.
/// Returns true if the watermark was advanced.
fun advanceGcWatermark(caller: machine, store: ObjectStore): bool {
    var currentManifest: tVersionedManifest;
    var newManifest: tManifest;
    var manifestUploaded: bool;

    while (!manifestUploaded) {
        currentManifest = downloadManifest(caller, store);
        if (currentManifest.m.snapshotLsn == currentManifest.m.gcWatermark) {
            return false;
        }

        newManifest = currentManifest.m;
        newManifest.gcWatermark = currentManifest.m.snapshotLsn;
        manifestUploaded =
            uploadManifest(caller, store, newManifest, currentManifest.v);
    }

    print format("{0} advanced GC watermark to {1}", caller, newManifest.gcWatermark);

    return true;
}

/// Remove snapshots and chunks below the GC watermark.
/// Returns the new lower bound under which all objects have been removed
/// to optimize future calls.
fun removeObsoleteObjects(caller: machine, store: ObjectStore, lowerBound: int): int {
    var manifest: tVersionedManifest;
    var gcWm: int;
    var i: int;

    manifest = downloadManifest(caller, store);
    gcWm = manifest.m.gcWatermark;

    if (gcWm <= 0) {
        print format("{0} no objects to remove, GC watermark {1}", caller, gcWm);
        return gcWm;
    }

    print format("{0} removing objects below watermark {1}", caller, gcWm);
    i = gcWm;

    // Remove objects in descending order to increase the chance of a recently
    // created reader missing an object.
    //
    // A real implementation can implement this in a more efficient way,
    // e.g., batching deletions, listing objects, etc.
    while (i > lowerBound) {
        removeChunk(caller, store, i);
        if (i < gcWm) {
            removeSnapshot(caller, store, i);
        }
        i = i - 1;
    }

    return gcWm;
}
