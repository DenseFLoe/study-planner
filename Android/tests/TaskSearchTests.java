package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.Executor;

public final class TaskSearchTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty(), course = PlannerTests.course("高数 TEST", 600, DAY, DAY.plusDays(7), 60);
        state.getJSONArray("courses").put(course);
        for (int i = 204; i >= 0; i--) state.getJSONArray("tasks").put(Planner.task(course.getString("id"), Planner.at(DAY.plusDays(i / 100), 480 + i % 100), 1)
            .put("id", String.format(Locale.ROOT, "task-%03d", i)).put("lessonName", "极限 " + i));
        return state;
    }
    static void filteringAndPages() throws Exception {
        JSONObject state = fixture(); String before = SyncLedger.canonical(state);
        TaskSearch.Result all = TaskSearch.find(state, "高数");
        check(all.count() == 205 && all.pageCount() == 3, "Result count or page count wrong");
        check(all.page(0).size() == 100 && all.page(1).size() == 100 && all.page(2).size() == 5, "Results truncated or too many rendered per page");
        check(all.page(0).get(0).id.equals("task-000") && all.page(2).get(4).id.equals("task-204"), "Results not sorted by date");
        check(all.page(-1).isEmpty() && all.page(3).isEmpty(), "Out-of-range page accepted");
        check(TaskSearch.find(state, "ＴＥＳＴ　极限 2026-11-05").count() == 100, "Normalized multi-term/date filtering failed");
        check(TaskSearch.find(state, "高数 2026-11-06").count() == 5, "Date search lost tasks");
        check(TaskSearch.find(state, "English").count() == 0, "Unmatched query returned tasks");
        check(TaskSearch.find(state, "　 ").pageCount() == 0, "Empty query returned all history");
        check(all.page(0).get(0).label().contains("高数 TEST / 极限 0"), "Result omitted course or lesson identity");
        check(before.equals(SyncLedger.canonical(state)), "Search mutated state");
    }
    static void stableTiesAndDetachedHits() throws Exception {
        JSONObject state = fixture(), task = state.getJSONArray("tasks").getJSONObject(0);
        task.put("start", Planner.at(DAY, 480));
        TaskSearch.Result result = TaskSearch.find(state, "高数");
        check(result.page(0).get(0).id.equals("task-000") && result.page(0).get(1).id.equals("task-204"), "Tied timestamps were unstable");
        task.put("lessonName", "后来的变更").put("start", Planner.at(DAY.plusYears(1), 0));
        check(!result.page(0).get(1).label().contains("后来的变更") && Planner.day(result.page(0).get(1).start).equals(DAY), "Results retained mutable task fields");
        task.remove("lessonName");
        check(!TaskSearch.find(state, "2027").page(0).get(0).label().contains(" / "), "Empty lesson name produced an empty suffix");
    }
    static final class Queue implements Executor {
        final Deque<Runnable> work = new ArrayDeque<>();
        public void execute(Runnable value) { work.add(value); }
        void run() { work.remove().run(); }
        void drain() { while (!work.isEmpty()) run(); }
    }
    static void asynchronousQueries() throws Exception {
        JSONObject state = fixture(); Queue worker = new Queue(), ui = new Queue();
        List<TaskSearch.Result> accepted = new ArrayList<>(); List<Exception> errors = new ArrayList<>();
        TaskSearchController controller = new TaskSearchController(worker, ui, accepted::add, errors::add);
        controller.search(state, "高数"); controller.search(state, "2026-11-06"); worker.drain();
        check(accepted.isEmpty(), "Worker touched UI before dispatch"); ui.drain();
        check(accepted.size() == 1 && accepted.get(0).count() == 5, "Queued obsolete query won");
        controller.search(state, "高数"); worker.run(); controller.clear(); ui.drain();
        check(accepted.size() == 1, "Clearing text allowed an in-flight result to reappear");
        controller.search(new JSONObject(), "broken"); worker.run(); controller.search(state, "2026-11-05"); ui.drain();
        check(errors.isEmpty(), "Obsolete failure replaced newer query"); worker.drain(); ui.drain();
        check(accepted.size() == 2 && accepted.get(1).count() == 100, "New query did not recover after failure");
        controller.search(new JSONObject(), "broken"); worker.drain(); ui.drain();
        check(errors.size() == 1, "Current failure was hidden");
        controller.search(state, "高数"); worker.run(); controller.close(); ui.drain();
        controller.search(state, "高数"); worker.drain(); ui.drain();
        check(accepted.size() == 2, "Closed search updated UI");
    }
    public static void main(String[] args) throws Exception {
        filteringAndPages(); stableTiesAndDetachedHits(); asynchronousQueries();
        System.out.println("TaskSearchTests: " + checks + " checks passed");
    }
}
