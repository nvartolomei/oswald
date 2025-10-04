/// Safety: Manifests don't time travel backwards.
spec SafetyManifestMonotonicity observes eObjectUpdated {
    var prevManifest: tManifest;
    start state Observing {
        entry {
            prevManifest = (snapshotLsn=-1, gcWatermark=-1);
        }

        on eObjectUpdated do (payload: (key: string, value: data, version: int)) {
            var manifest: tManifest;

            if (payload.key != manifestKey()) {
                return;
            }

            manifest = payload.value as tManifest;

            assert manifest.snapshotLsn >= manifest.gcWatermark;
            assert manifest.snapshotLsn >= prevManifest.snapshotLsn;
            assert manifest.gcWatermark >= prevManifest.gcWatermark;

            prevManifest = manifest;
        }
    }
}
