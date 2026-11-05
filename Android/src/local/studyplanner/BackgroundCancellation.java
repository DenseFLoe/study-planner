package local.studyplanner;

import java.util.concurrent.Callable;
import java.util.concurrent.CancellationException;
import java.util.function.BooleanSupplier;

/** Cooperative cancellation scoped to one read-only job; never interrupts a shared save worker. */
final class BackgroundCancellation {
    private static final ThreadLocal<BooleanSupplier> current = new ThreadLocal<>();
    static void check() {
        BooleanSupplier signal = current.get();
        if (signal != null && signal.getAsBoolean()) throw new CancellationException();
    }
    static <T> T call(BooleanSupplier signal, Callable<T> work) throws Exception {
        BooleanSupplier previous = current.get();
        current.set(() -> signal.getAsBoolean() || previous != null && previous.getAsBoolean());
        try { check(); T result = work.call(); check(); return result; }
        finally { if (previous == null) current.remove(); else current.set(previous); }
    }
}
