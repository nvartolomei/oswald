// expected_version values:
//   - -1: do not check version, always upload
//   -  0: upload only if object does not exist
//   - >0: upload only if object exists and has the expected version
type tUploadRequest = (sender: machine, key: string, value: data, expected_version: int);
type tUploadResponse = (success: bool, current_version: int);

event eUploadRequest: tUploadRequest;
event eUploadResponse: tUploadResponse;

type tDownloadRequest = (sender: machine, key: string);
type tDownloadResponse = (success: bool, value: data, version: int);

event eDownloadRequest: tDownloadRequest;
event eDownloadResponse: tDownloadResponse;

type tDeleteRequest = (sender: machine, key: string);
type tDeleteResponse = (success: bool);

event eDeleteRequest: tDeleteRequest;
event eDeleteResponse: tDeleteResponse;

type Value = (body: data, version: int);

machine ObjectStore {
    var objects: map[string, Value];

    start state Init {
        entry {}

        on eUploadRequest do (payload: tUploadRequest) {
            var current_value: Value;

            if (payload.key in objects) {
                current_value = objects[payload.key];

                if (payload.expected_version == -1 || current_value.version == payload.expected_version) {
                    objects[payload.key] = (body=payload.value, version=current_value.version + 1);
                    send payload.sender, eUploadResponse, (success=true, current_version=objects[payload.key].version);
                } else {
                    send payload.sender, eUploadResponse, (success=false, current_version=current_value.version);
                }
            } else {
                if (payload.expected_version == 0 || payload.expected_version == -1) {
                    objects[payload.key] = (body=payload.value, version=1);
                    send payload.sender, eUploadResponse, (success=true, current_version=1);
                } else {
                    send payload.sender, eUploadResponse, (success=false, current_version=0);
                }
            }
	    }

        on eDownloadRequest do (payload: tDownloadRequest) {
            var value: Value;

            if (payload.key in objects) {
                value = objects[payload.key];
                send payload.sender, eDownloadResponse, (success=true, value=value.body, version=value.version);
            } else {
                send payload.sender, eDownloadResponse, (success=false, value=null, version=0);
            }
        }

        on eDeleteRequest do (payload: tDeleteRequest) {
            objects -= (payload.key);
            send payload.sender, eDeleteResponse, (success=true,);
        }
    }
}
