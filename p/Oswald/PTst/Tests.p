machine ConcurrentCounters {
    start state Init {
        entry {
            var objectStore: ObjectStore;
            var counters: seq[Counter];
            var numRounds: int;
            var numCounters: int;
            var numIncrements: int;
            var maxObservedValue: int;
            var roundIx: int;
            var i: int;

            numRounds = 2;
            numCounters = 2;
            numIncrements = 10;

            objectStore = new ObjectStore();

            roundIx = 0;
            while (roundIx < numRounds) {
                i = 0;
                while (i < numCounters) {
                    counters += (sizeof(counters), new Counter((parent=this, objectStore=objectStore, numIncrements=numIncrements)));
                    i = i + 1;
                }

                i = 0;
                while (i < numCounters) {
                    receive {
                        case eCounterDone: (payload: (sender: Counter, value: int)) {
                            print format("Counter {0} done with value {1}", payload.sender, payload.value);
                            if (payload.value > maxObservedValue) {
                                maxObservedValue = payload.value;
                            }
                        }
                    }
                    i = i + 1;
                }

                assert (roundIx + 1) * numCounters * numIncrements == maxObservedValue,
                    format("Expected {0} but got {1}", (roundIx + 1) * numCounters * numIncrements, maxObservedValue);

                roundIx = roundIx + 1;
            }
        }
    }
}
