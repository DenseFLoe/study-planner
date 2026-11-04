package local.studyplanner;

import org.json.JSONObject;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** Latest query wins; closing the dialog makes queued and in-flight results inert. */
final class TaskSearchController {
    private final LatestWork<TaskSearch.Result> work;
    TaskSearchController(Executor worker, Executor ui, Consumer<TaskSearch.Result> accept, Consumer<Exception> failure) {
        work = new LatestWork<>(worker, ui, accept, failure);
    }
    void clear() { work.clear(); }
    void close() { work.close(); }
    void search(JSONObject state, String query) {
        work.submit(() -> TaskSearch.find(state, query));
    }
}
