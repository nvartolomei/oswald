event eTimerStart;
event eTimerCancel;
event eTimerTick;

machine Timer {
    var holder: machine;
    var timeoutEvent: event;

    start state Init {
        entry (setup: (user: machine, timeoutEvent: event)) {
            holder = setup.user;
            timeoutEvent = setup.timeoutEvent;
            goto TimerIdle;
        }
    }

    state TimerIdle {
        on eTimerStart do {
            goto TimerTick;
        }
    }

    state TimerTick {
        entry {
            checkTick();
        }
        on eTimerTick do {
            checkTick();
        }
        on eTimerCancel goto TimerIdle;
        ignore eTimerStart;
    }

    fun checkTick() {
        if ($) {
            send holder, timeoutEvent;
            goto TimerIdle;
        } else {
            send this, eTimerTick;
        }
    }
}
