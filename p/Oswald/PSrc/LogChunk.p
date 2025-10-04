/// Downloaded log chunk (found=false => no object present at that LSN).
type tLogChunk = (body: data, found: bool);

/// Result of attempted append (conflict=true => CAS failed / already exists).
type tUploadChunkResult = (conflict: bool);

fun logChunkKey(lsn: int): string {
    return format("chunk/{0}", lsn);
}

fun downloadChunk(sender: machine, store: ObjectStore, lsn: int): tLogChunk {
    var ret: tLogChunk;

    send store, eDownloadRequest, (sender=sender, key=logChunkKey(lsn));
    receive {
        case eDownloadResponse: (response: tDownloadResponse) {
            ret = (body=response.value, found=response.success);
        }
    }

    return ret;
}

fun uploadChunk(sender: machine, store: ObjectStore, lsn: int, body: data): tUploadChunkResult {
    var ret: tUploadChunkResult;

    send store, eUploadRequest, (sender=sender, key=logChunkKey(lsn), value=body, expected_version=0);
    receive {
        case eUploadResponse: (metaResponse: tUploadResponse) {
            if (metaResponse.success) {
                ret = (conflict=false,);
            } else {
                ret = (conflict=true,);
            }
        }
    }

    return ret;
}

fun removeChunk(sender: machine, store: ObjectStore, lsn: int) {
    send store, eDeleteRequest, (sender=sender, key=logChunkKey(lsn));
    receive {
        case eDeleteResponse: (response: tDeleteResponse) {}
    }
}
