package local.studyplanner;

import java.util.*;
import java.util.concurrent.Executor;

public final class DeferredRefreshTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static final class Queue implements Executor {
        final Deque<Runnable> work = new ArrayDeque<>();
        public void execute(Runnable task) { work.add(task); }
        void next() { work.remove().run(); }
    }
    static final class Fixture {
        final Queue worker = new Queue(), ui = new Queue();
        final List<Integer> shown = new ArrayList<>();
        boolean ready = true, busy, fail;
        int disk = 1, reads, failures, statusChanges;
        final DeferredRefresh<Integer> refresh = new DeferredRefresh<>(worker, ui, () -> ready && !busy,
            () -> { reads++; if (fail) throw new IllegalStateException("read failed"); return disk; },
            shown::add, error -> failures++, () -> statusChanges++);
        void complete() { worker.next(); ui.next(); }
    }
    static void requestsDuringWrite() {
        Fixture f = new Fixture(); f.busy = true;
        for (int i = 0; i < 10; i++) { f.disk++; f.refresh.request(); }
        check(f.reads == 0 && f.worker.work.isEmpty(), "Sync read started during write");
        f.busy = false; f.refresh.resume(); f.complete();
        check(f.shown.equals(Collections.singletonList(11)) && f.reads == 1, "Busy sync requests were dropped or duplicated");
        check(!f.refresh.isRunning() && f.worker.work.isEmpty(), "Finished refresh left a spinner/retry");
    }
    static void readOvertakenByWrite() {
        Fixture f = new Fixture(); f.refresh.request(); f.worker.next();
        f.busy = true; f.ui.next();
        check(f.shown.isEmpty() && !f.refresh.isRunning(), "In-flight snapshot overwritten an active edit");
        f.disk = 2; f.busy = false; f.refresh.resume(); f.complete();
        check(f.shown.equals(Collections.singletonList(2)) && f.reads == 2, "Deferred read did not reload committed data");
    }
    static void requestsDuringRead() {
        Fixture f = new Fixture(); f.refresh.request(); f.worker.next();
        for (int i = 0; i < 5; i++) { f.disk++; f.refresh.request(); }
        check(f.worker.work.isEmpty(), "Overlapping refreshes were queued while one was active");
        f.ui.next(); f.complete();
        check(f.reads == 2 && f.shown.get(f.shown.size() - 1) == 6, "Coalesced reread missed latest version");
        check(f.worker.work.isEmpty(), "Every request created a redundant read");
    }
    static void readFailureAndRecovery() {
        Fixture f = new Fixture(); f.fail = true; f.refresh.request(); f.complete();
        check(f.failures == 1 && f.shown.isEmpty(), "Read failure replaced current UI data");
        check(f.worker.work.isEmpty() && !f.refresh.isRunning(), "Failed read entered a retry loop");
        f.fail = false; f.disk = 3; f.refresh.request(); f.complete();
        check(f.shown.equals(Collections.singletonList(3)), "Later request could not recover after failure");
        f.busy = true; f.refresh.request(); f.disk = 4;
        // A rejected save also releases the gate; no successful-write condition is required.
        f.busy = false; f.refresh.resume(); f.complete();
        check(f.shown.get(1) == 4, "Rejected save left the screen stale");
    }
    static void startupAndDestroyedOwner() {
        Fixture f = new Fixture(); f.ready = false; f.refresh.request();
        check(f.worker.work.isEmpty(), "Read started before database setup");
        f.ready = true; f.refresh.resume(); f.complete();
        check(f.shown.equals(Collections.singletonList(1)), "Startup discarded pending request");
        f.refresh.request(); f.worker.next(); int statuses = f.statusChanges;
        f.refresh.close(); f.ui.next(); f.refresh.request(); f.refresh.resume();
        check(f.shown.size() == 1 && f.failures == 0 && f.statusChanges == statuses, "Destroyed owner received callbacks");
        check(f.worker.work.isEmpty() && !f.refresh.isRunning(), "Destroyed owner scheduled another read");
    }
    public static void main(String[] args) {
        requestsDuringWrite(); readOvertakenByWrite(); requestsDuringRead(); readFailureAndRecovery(); startupAndDestroyedOwner();
        System.out.println("DeferredRefreshTests: " + checks + " checks passed");
    }
}
