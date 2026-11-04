package local.studyplanner;

import org.json.*;
import java.util.*;

/** Worker-only index and progress cache for one read-only planner snapshot. */
final class CourseCatalog {
    static final int PAGE_SIZE = 20;
    private final JSONObject state;
    private final List<JSONObject> courses;
    private final Map<String, String> searchText = new HashMap<>();
    private final Map<String, Integer> completed = new HashMap<>();
    static final class Row {
        final String id; final int completedMinutes;
        Row(String id, int completedMinutes) { this.id = id; this.completedMinutes = completedMinutes; }
    }
    static final class Page {
        final int count, index, pageCount; final List<Row> rows;
        Page(int count, int index, List<Row> rows) {
            this.count = count; this.index = index; pageCount = count == 0 ? 0 : (count - 1) / PAGE_SIZE + 1;
            this.rows = Collections.unmodifiableList(rows);
        }
    }
    CourseCatalog(JSONObject state) {
        this.state = state; courses = Planner.list(state.optJSONArray("courses"));
        courses.removeIf(course -> course.optBoolean("isArchived"));
        courses.sort(Comparator.comparingDouble((JSONObject course) -> course.optDouble("deadline")).thenComparing(course -> course.optString("id")));
        for (JSONObject course : courses) searchText.put(course.optString("id"), TaskSearch.normalize(course.optString("name") + " " +
                course.optString("notes") + " " + Planner.date(course.optDouble("deadline"))));
    }
    Page find(String query, int requestedPage) {
        String normalized = TaskSearch.normalize(query); String[] terms = normalized.isEmpty() ? new String[0] : normalized.split("\\s+");
        List<JSONObject> matches = new ArrayList<>();
        for (JSONObject course : courses) {
            String text = searchText.get(course.optString("id")); boolean found = true;
            for (String term : terms) if (!text.contains(term)) { found = false; break; }
            if (found) matches.add(course);
        }
        int page = matches.isEmpty() ? 0 : Math.max(0, Math.min(requestedPage, (matches.size() - 1) / PAGE_SIZE));
        int first = page * PAGE_SIZE; List<Row> rows = new ArrayList<>();
        for (int i = first; i < Math.min(matches.size(), first + PAGE_SIZE); i++) {
            JSONObject course = matches.get(i); String id = course.optString("id");
            rows.add(new Row(id, completed.computeIfAbsent(id, ignored -> Planner.completed(state, course))));
        }
        return new Page(matches.size(), page, rows);
    }
}
