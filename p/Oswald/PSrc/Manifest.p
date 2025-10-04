/// OSWALD Manifest.
///
/// snapshotLsn - The LSN of the last snapshot taken.
///   - snapshotLsn == -1 is a special value meaning "no snapshot taken yet".
///   - snapshotLsn >= 0 means a snapshot was taken at that LSN and all prior log
///     entries are included in that snapshot. snapshotLsn + 1 is the first log
///     chunk considered for recovery. Log entries prior to snapshotLsn are
///     eligible for garbage collection.
type tManifest = (snapshotLsn: int, gcWatermark: int);

/// Manifest paired with its object-store version for CAS semantics.
type tVersionedManifest = (m: tManifest, v: int);

fun manifestKey(): string {
    return "manifest";
}

/// Download manifest; if missing, return default (snapshotLsn=-1, version=0) so
/// caller can attempt exclusive creation.
fun downloadManifest(sender: machine, store: ObjectStore): tVersionedManifest {
    var ret: tVersionedManifest;

    send store, eDownloadRequest, (sender=sender, key=manifestKey());
    receive {
        case eDownloadResponse: (metaResponse: tDownloadResponse) {
            if (metaResponse.value == null) {
                assert metaResponse.version == 0;
                ret = (m=(snapshotLsn=-1,gcWatermark=-1), v=0);
            } else {
                ret = (
                    m=metaResponse.value as tManifest,
                    v=metaResponse.version
                );
            }
        }
    }

    return ret;
}

/// Upload manifest using CAS semantics; returns true if successful.
fun uploadManifest(
    sender: machine,
    store: ObjectStore,
    manifest: tManifest,
    expectedVersion: int
): bool {
    var ret: bool;

    send store, eUploadRequest,
        (sender=sender, key=manifestKey(), value=manifest, expected_version=expectedVersion);
    receive {
        case eUploadResponse: (response: tUploadResponse) {
            ret = response.success;
        }
    }

    return ret;
}
