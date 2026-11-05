package local.studyplanner;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class BackgroundCancellationTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static void await(CountDownLatch signal) throws Exception {
        if (!signal.await(5, TimeUnit.SECONDS)) throw new AssertionError("Worker did not reach expected checkpoint");
    }
    static void running(boolean close) throws Exception {
        ExecutorService worker = Executors.newSingleThreadExecutor();
        Queue<Runnable> ui = new ConcurrentLinkedQueue<>();
        List<String> values = new ArrayList<>(); List<Exception> failures = new ArrayList<>();
        LatestWork<String> work = new LatestWork<>(worker, ui::add, values::add, failures::add);
        CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicBoolean cancelled = new AtomicBoolean(), reachedEnd = new AtomicBoolean();
        try {
            work.submit(() -> {
                started.countDown(); await(release);
                try { BackgroundCancellation.check(); }
                catch (CancellationException expected) { cancelled.set(true); throw expected; }
                reachedEnd.set(true); return "obsolete";
            });
            await(started);
            if (close) work.close(); else work.submit(() -> "newest");
            release.countDown();
            // A later save on this same executor must neither inherit cancellation nor an interrupt.
            check(worker.submit(() -> { BackgroundCancellation.check(); return !Thread.currentThread().isInterrupted(); }).get(5, TimeUnit.SECONDS), "Cancellation escaped into later worker job");
            for (Runnable callback; (callback = ui.poll()) != null;) callback.run();
            check(cancelled.get() && !reachedEnd.get(), "Running obsolete work was only hidden, not stopped");
            check(values.equals(close ? Collections.emptyList() : Collections.singletonList("newest")), "Stale result reached UI or newest result lost");
            check(failures.isEmpty(), "Cancellation was shown as a user error");
        } finally { release.countDown(); worker.shutdownNow(); worker.awaitTermination(5, TimeUnit.SECONDS); }
    }
    public static void main(String[] args) throws Exception {
        running(false); running(true);
        Queue<Runnable> worker = new ArrayDeque<>(), ui = new ArrayDeque<>();
        List<String> values = new ArrayList<>(); List<Exception> errors = new ArrayList<>();
        LatestWork<String> work = new LatestWork<>(worker::add, ui::add, values::add, errors::add);
        AtomicInteger executed = new AtomicInteger();
        work.submit(() -> { executed.incrementAndGet(); return "queued"; }); work.clear(); worker.remove().run();
        check(executed.get() == 0 && ui.isEmpty(), "Cancelled queued work still executed");
        work.submit(() -> "old"); worker.remove().run(); work.clear(); ui.remove().run();
        check(values.isEmpty(), "Finished obsolete callback reached UI");
        work.submit(() -> { throw new IllegalArgumentException("current failure"); }); worker.remove().run(); ui.remove().run();
        check(errors.size() == 1, "Current failure disappeared");
        AtomicBoolean outer = new AtomicBoolean();
        try {
            BackgroundCancellation.call(outer::get, () -> {
                BackgroundCancellation.call(() -> false, () -> { outer.set(true); return null; });
                return null;
            });
            throw new AssertionError("Nested scope lost outer cancellation");
        } catch (CancellationException expected) { checks++; }
        BackgroundCancellation.check(); checks++;
        System.out.println("Background cancellation: " + checks + " checks passed");
    }
}
