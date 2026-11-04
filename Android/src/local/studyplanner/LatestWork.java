package local.studyplanner;

import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** Only the newest requested result can reach an open UI, including failures. */
final class LatestWork<T> {
    interface Work<T> { T run() throws Exception; }
    private final Executor worker, ui;
    private final Consumer<T> accept;
    private final Consumer<Exception> failure;
    private volatile long generation;
    private volatile boolean closed;
    LatestWork(Executor worker, Executor ui, Consumer<T> accept, Consumer<Exception> failure) {
        this.worker = worker; this.ui = ui; this.accept = accept; this.failure = failure;
    }
    void clear() { generation++; }
    void close() { closed = true; clear(); }
    void submit(Work<T> work) {
        if (closed) return;
        long request = ++generation;
        worker.execute(() -> {
            if (closed || request != generation) return;
            try {
                T result = work.run();
                ui.execute(() -> { if (!closed && request == generation) accept.accept(result); });
            } catch (Exception error) {
                ui.execute(() -> { if (!closed && request == generation) failure.accept(error); });
            }
        });
    }
}
