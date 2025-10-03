fun snapshotKey(lsn: int): string {
    return format("snapshot/{0}", lsn);
}

/// Download snapshot at given LSN.
/// Precondition: snapshot at given LSN exists.
fun downloadSnapshot(
    sender: machine,
    store: ObjectStore,
    lsn: int
): data {
    var ret: data;

    send store, eDownloadRequest, (sender=sender, key=snapshotKey(lsn));
    receive {
        case eDownloadResponse: (metaResponse: tDownloadResponse) {
            assert metaResponse.success;
            ret = metaResponse.value as data;
        }
    }

    return ret;
}

/// Asynchronously write snapshot at given LSN.
fun writeSnapshotAsync(
    store: ObjectStore,
    lsn: int,
    body: data
) {
    new AsyncSnapshotWriter((store=store, lsn=lsn, body=body));
}

/// Machine that uploads a snapshot and records it in the manifest.
machine AsyncSnapshotWriter {
    var store: ObjectStore;
    var lsn: int;

    start state UploadSnapshot {
        entry (input: (store: ObjectStore, lsn: int, body: data)) {
            store = input.store;
            lsn = input.lsn;

            send input.store, eUploadRequest,
                (sender=this, key=snapshotKey(input.lsn), value=input.body, expected_version=0);
            receive {
                case eUploadResponse: (response: tUploadResponse) {
                    if (response.success) {
                        print format("{0} wrote snapshot at LSN {1}", this, input.lsn);
                        goto UpdateManifest;
                    } else {
                        print format("{0} failed to write snapshot at LSN {1}", this, input.lsn);
                        goto Done;
                    }
                }
            }
        }
    }

    state UpdateManifest {
        entry {
            var currentManifest: tVersionedManifest;
            var newManifest: tManifest;
            var success: bool;

            // Update manifest to reflect new snapshot.
            currentManifest = downloadManifest(this, store);
            if (currentManifest.m.snapshotLsn < lsn) {
                newManifest = currentManifest.m;
                newManifest.snapshotLsn = lsn;
                success = uploadManifest(this, store, newManifest, currentManifest.v);
                if (success) {
                    print format("{0} updated manifest to snapshot LSN {1}", this, lsn);
                } else {
                    print format("{0} failed to update manifest to snapshot LSN {1}, will retry", this, lsn);
                    goto UpdateManifest;
                }
            } else {
                print format("{0} skipping manifest update; current snapshot LSN {1} >= {2}",
                    this, currentManifest.m.snapshotLsn, lsn);
            }

            goto Done;
        }
    }

    state Done {
        entry {
            send this, halt;
        }
    }
}
