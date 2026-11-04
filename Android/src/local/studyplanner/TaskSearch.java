package local.studyplanner;

import org.json.*;
import java.text.Normalizer;
import java.util.*;

/** Read-only search over one state snapshot. UI pages contain at most 100 buttons. */
public final class TaskSearch {
    public static final int PAGE_SIZE = 100;
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
        String normalized = normalize(query); List<Hit> matches = new ArrayList<>();
        if (normalized.isEmpty()) return new Result(matches);
        String[] terms = normalized.split("\\s+"); Map<String, String> courses = new HashMap<>();
        for (JSONObject course : Planner.list(state.optJSONArray("courses"))) courses.put(course.optString("id"), course.optString("name"));
        for (JSONObject task : Planner.list(state.optJSONArray("tasks"))) {
            String course = courses.getOrDefault(task.optString("courseID"), "已删除课程");
            String text = normalize(course + " " + task.optString("lessonName") + " " + Planner.date(task.optDouble("start")));
            boolean found = true; for (String term : terms) if (!text.contains(term)) { found = false; break; }
            if (found) matches.add(new Hit(task, course));
        }
        matches.sort(Comparator.comparingDouble((Hit hit) -> hit.start).thenComparing(hit -> hit.id));
        return new Result(matches);
    }
}
