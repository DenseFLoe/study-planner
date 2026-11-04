package local.studyplanner;

import org.json.JSONObject;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** Latest query wins; closing the dialog makes queued and in-flight results inert. */
final class TaskSearchController {
    private final Executor worker, ui;
    private final Consumer<TaskSearch.Result> accept;
    private final Consumer<Exception> failure;
    private volatile long generation;
    private volatile boolean closed;
    TaskSearchController(Executor worker, Executor ui, Consumer<TaskSearch.Result> accept, Consumer<Exception> failure) {
        this.worker = worker; this.ui = ui; this.accept = accept; this.failure = failure;
    }
    void clear() { generation++; }
    void close() { closed = true; clear(); }
    void search(JSONObject state, String query) {
        if (closed) return;
        long request = ++generation;
        worker.execute(() -> {
            if (closed || request != generation) return;
            try {
                TaskSearch.Result result = TaskSearch.find(state, query);
                ui.execute(() -> { if (!closed && request == generation) accept.accept(result); });
            } catch (Exception error) {
                ui.execute(() -> { if (!closed && request == generation) failure.accept(error); });
            }
        });
    }
}
