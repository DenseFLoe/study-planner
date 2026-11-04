package local.studyplanner;

import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

public final class StateMutationTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static final class Store implements StateMutation.Store<int[]> {
        int[] value = {0, 0}; int saves;
        public synchronized int[] load() { return value.clone(); }
        public synchronized void save(int[] next) { value = next.clone(); saves++; }
    }
    interface Work { void run() throws Exception; }
    static Thread thread(AtomicReference<Throwable> failure, Work work) {
        Thread thread = new Thread(() -> { try { work.run(); } catch (Throwable error) { failure.compareAndSet(null, error); } });
        thread.setDaemon(true); thread.start(); return thread;
    }
    static void await(CountDownLatch latch) throws Exception {
        if (!latch.await(5, TimeUnit.SECONDS)) throw new AssertionError("Timed out waiting for worker");
    }
    static void join(Thread thread, AtomicReference<Throwable> failure) throws Exception {
        thread.join(5000); check(!thread.isAlive(), "Worker deadlocked");
        if (failure.get() != null) throw new AssertionError("Worker failed", failure.get());
    }
    static void cloudCannotOvertakeSave() throws Exception {
        Store store = new Store(); AtomicReference<Throwable> failure = new AtomicReference<>();
        CountDownLatch editing = new CountDownLatch(1), cloudAttempt = new CountDownLatch(1), release = new CountDownLatch(1);
        Thread foreground = thread(failure, () -> StateMutation.apply(store, value -> {
            editing.countDown(); await(release); value[0]++;
        }));
        await(editing);
        Thread cloud = thread(failure, () -> {
            cloudAttempt.countDown();
            synchronized (store) { int[] latest = store.load(); latest[1]++; store.save(latest); }
        });
        try {
            await(cloudAttempt);
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (cloud.getState() != Thread.State.BLOCKED && cloud.isAlive() && System.nanoTime() < deadline) Thread.yield();
            check(cloud.getState() == Thread.State.BLOCKED, "Cloud commit entered between foreground load and save");
        } finally { release.countDown(); }
        join(foreground, failure); join(cloud, failure);
        check(store.value[0] == 1 && store.value[1] == 1 && store.saves == 2, "Concurrent commit was lost");
    }
    static void repeatedWriters() throws Exception {
        Store store = new Store(); AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread[] writers = new Thread[4];
        for (int i = 0; i < writers.length; i++) {
            final int index = i % 2;
            writers[i] = thread(failure, () -> { for (int n = 0; n < 100; n++) StateMutation.apply(store, value -> value[index]++); });
        }
        for (Thread writer : writers) join(writer, failure);
        check(store.value[0] == 200 && store.value[1] == 200 && store.saves == 400, "Foreground updates were overwritten");
    }
    static void failureAndFreshData() throws Exception {
        Store store = new Store();
        try {
            StateMutation.apply(store, value -> { value[0] = 20; throw new IllegalArgumentException("conflict"); });
            throw new AssertionError("Mutation error swallowed");
        } catch (IllegalArgumentException expected) {
            check(store.saves == 0 && store.value[0] == 0, "Failed mutation committed");
        }
        synchronized (store) { store.save(new int[]{1, 7}); }
        int[] result = StateMutation.apply(store, value -> value[0]++);
        check(result[0] == 2 && result[1] == 7 && store.saves == 2, "Mutation did not reload latest cloud data");
        result[0] = 99;
        check(store.value[0] == 2, "Published state aliases stored value");
    }
    public static void main(String[] args) throws Exception {
        cloudCannotOvertakeSave(); repeatedWriters(); failureAndFreshData();
        System.out.println("StateMutationTests: " + checks + " checks passed");
    }
}
