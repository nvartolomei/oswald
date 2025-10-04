machine ConcurrentCounters {
    var objectStore: ObjectStore;
            var counters: seq[Counter];
            var numRounds: int;
            var numCounters: int;
            var numIncrements: int;
            var maxObservedValue: int;
            var roundIx: int;
            var i: int;
            var doneCounters: int;

    start state Init {
        entry {


            numRounds = 2;
            numCounters = 2;
            numIncrements = 2;

            objectStore = new ObjectStore();
            // gc = new GarbageCollector((store=objectStore,));

            goto work;
        }
    }

    state work {
        entry {
            if (roundIx == numRounds) {
                goto done;
                return;
            }

            if (sizeof(counters) < numCounters) {
                counters += (sizeof(counters), new Counter((parent=this, objectStore=objectStore, numIncrements=numIncrements)));
                goto work;
            }

            if (doneCounters < numCounters) {
                receive {
                    case eCounterDone: (payload: (sender: Counter, value: int)) {
                        print format("Counter {0} done with value {1}", payload.sender, payload.value);
                        if (payload.value > maxObservedValue) {
                            maxObservedValue = payload.value;
                        }
                    }
                }
                doneCounters = doneCounters + 1;
                goto work;
            }

            assert (roundIx + 1) * numCounters * numIncrements == maxObservedValue,
                format("Expected {0} but got {1}", (roundIx + 1) * numCounters * numIncrements, maxObservedValue);

            roundIx = roundIx + 1;
            goto resetRound;
        }
    }

    state resetRound {
        entry {
            doneCounters = 0;
            counters = default(seq[Counter]);
            goto work;
        }
    }

    state done {
        entry {}
    }
}
