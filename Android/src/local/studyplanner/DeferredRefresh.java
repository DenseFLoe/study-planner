package local.studyplanner;

import java.util.concurrent.Executor;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;

/** UI-thread owner of coalesced reads. The worker never mutates UI or gate state. */
final class DeferredRefresh<T> {
    interface Reader<T> { T read() throws Exception; }
    private final Executor worker, ui;
    private final BooleanSupplier available;
    private final Reader<T> reader;
    private final Consumer<T> accept;
    private final Consumer<Exception> failure;
    private final Runnable statusChanged;
    private boolean pending, running, closed;

    DeferredRefresh(Executor worker, Executor ui, BooleanSupplier available, Reader<T> reader,
                    Consumer<T> accept, Consumer<Exception> failure, Runnable statusChanged) {
        this.worker = worker; this.ui = ui; this.available = available; this.reader = reader;
        this.accept = accept; this.failure = failure; this.statusChanged = statusChanged;
    }

    boolean isRunning() { return running; }
    void close() { closed = true; pending = false; }
    void request() { if (!closed) { pending = true; resume(); } }

    /** Call when startup or a write finishes, whether that write succeeds or fails. */
    void resume() {
        if (closed || running || !pending || !available.getAsBoolean()) return;
        pending = false; running = true; statusChanged.run();
        worker.execute(() -> {
            T value = null; Exception error = null;
            try { value = reader.read(); } catch (Exception caught) { error = caught; }
            final T result = value; final Exception problem = error;
            ui.execute(() -> complete(result, problem));
        });
    }

    private void complete(T value, Exception error) {
        running = false;
        if (closed) return;
        if (!available.getAsBoolean()) {
            // A write may have started after this read. Read again after it ends.
            pending = true;
        } else if (error == null) accept.accept(value);
        else failure.accept(error); // No automatic retry loop for a failed read.
        statusChanged.run();
        resume();
    }
}
