package local.studyplanner;

import org.json.*;
import java.text.Normalizer;
import java.util.*;

/** Read-only search over one state snapshot. UI pages contain at most 100 buttons. */
public final class TaskSearch {
    public static final int PAGE_SIZE = 100;
    public enum Scope {
        UPCOMING("接下来", "今天及以后的未确认安排 · 最近的在前"),
        HISTORY("历史", "已确认记录与往日安排 · 最近的在前"),
        ALL("全部", "全部已排日程 · 按日期从早到晚");
        public final String title, explanation;
        Scope(String title, String explanation) { this.title = title; this.explanation = explanation; }
    }
    public static final class Hit {
        public final String id, courseName, lessonName, progress;
        public final double start, planningStart;
        Hit(JSONObject task, String course) {
            id = task.optString("id"); courseName = course; lessonName = task.optString("lessonName");
            start = task.optDouble("start"); planningStart = Planner.planningStart(task);
            progress = Planner.completionDescription(task);
        }
        public String label() {
            return Planner.date(start) + " " + Planner.clock(planningStart) + " · " + courseName +
                (lessonName.isEmpty() ? "" : " / " + lessonName) + " · " + progress;
        }
    }
    public static final class Result {
        private final List<Hit> hits;
        Result(List<Hit> hits) { this.hits = Collections.unmodifiableList(hits); }
        public int count() { return hits.size(); }
        public int pageCount() { return hits.isEmpty() ? 0 : (hits.size() - 1) / PAGE_SIZE + 1; }
        public List<Hit> page(int index) {
            if (index < 0 || index >= pageCount()) return Collections.emptyList();
            int first = index * PAGE_SIZE;
            return hits.subList(first, Math.min(first + PAGE_SIZE, hits.size()));
        }
    }
    static String normalize(String value) { return Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).trim(); }
    public static Result find(JSONObject state, String query) {
        return find(state, query, Scope.ALL, Planner.now());
    }
    public static Result find(JSONObject state, String query, Scope scope, double now) {
        String normalized = normalize(query); List<Hit> matches = new ArrayList<>();
        if (normalized.isEmpty()) return new Result(matches);
        String[] terms = normalized.split("\\s+"); Map<String, String> courses = new HashMap<>();
        Set<String> active = new HashSet<>(); double today = Planner.at(Planner.day(now), 0);
        for (JSONObject course : Planner.list(state.optJSONArray("courses"))) {
            String id = course.optString("id"); courses.put(id, course.optString("name"));
            if (!course.optBoolean("isArchived")) active.add(id);
        }
        for (JSONObject task : Planner.list(state.optJSONArray("tasks"))) {
            boolean pending = Planner.pending(task);
            if (pending && !active.contains(task.optString("courseID"))) continue;
            boolean upcoming = pending && (task.optDouble("start") >= today || Planner.planningEnd(task) > today);
            if (scope == Scope.UPCOMING && !upcoming || scope == Scope.HISTORY && upcoming) continue;
            String course = courses.getOrDefault(task.optString("courseID"), "已删除课程");
            String text = normalize(course + " " + task.optString("lessonName") + " " + Planner.date(task.optDouble("start")));
            boolean found = true; for (String term : terms) if (!text.contains(term)) { found = false; break; }
            if (found) matches.add(new Hit(task, course));
        }
        Comparator<Hit> dates = Comparator.comparingDouble((Hit hit) -> hit.start);
        if (scope == Scope.HISTORY) dates = dates.reversed();
        matches.sort(dates.thenComparing(hit -> hit.id));
        return new Result(matches);
    }
}
