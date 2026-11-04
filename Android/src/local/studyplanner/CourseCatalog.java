package local.studyplanner;

import org.json.*;
import java.util.*;

/** Worker-only index and progress cache for one read-only planner snapshot. */
final class CourseCatalog {
    enum Scope {
        ALL("全部课程"), AUTOMATIC("自动排程"), PAUSED("已暂停");
        final String title;
        Scope(String title) { this.title = title; }
    }
    enum Order {
        DEADLINE("截止日期优先"), PRIORITY("课程优先级优先");
        final String title; Order(String title) { this.title = title; }
    }
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
        return find(query, Scope.ALL, requestedPage);
    }
    Page find(String query, Scope scope, int requestedPage) {
        return find(query, scope, Order.DEADLINE, requestedPage);
    }
    Page find(String query, Scope scope, Order order, int requestedPage) {
        return find(query, scope, order, requestedPage, null);
    }
    Page findSelected(String query, Set<String> selected, int requestedPage) {
        return find(query, Scope.ALL, Order.DEADLINE, requestedPage, selected);
    }
    private Page find(String query, Scope scope, Order order, int requestedPage, Set<String> includedIDs) {
        String normalized = TaskSearch.normalize(query); String[] terms = normalized.isEmpty() ? new String[0] : normalized.split("\\s+");
        List<JSONObject> matches = new ArrayList<>();
        for (JSONObject course : courses) {
            if (includedIDs != null && !includedIDs.contains(course.optString("id"))) continue;
            boolean automatic = course.optBoolean("autoScheduleEnabled", true);
            if (scope == Scope.AUTOMATIC && !automatic || scope == Scope.PAUSED && automatic) continue;
            String text = searchText.get(course.optString("id")); boolean found = true;
            for (String term : terms) if (!text.contains(term)) { found = false; break; }
            if (found) matches.add(course);
        }
        if (order == Order.PRIORITY) matches.sort(Comparator.comparingInt((JSONObject course) -> course.optInt("priority", 2)).reversed()
            .thenComparingDouble(course -> course.optDouble("deadline")).thenComparing(course -> course.optString("id")));
        int page = matches.isEmpty() ? 0 : Math.max(0, Math.min(requestedPage, (matches.size() - 1) / PAGE_SIZE));
        int first = page * PAGE_SIZE; List<Row> rows = new ArrayList<>();
        for (int i = first; i < Math.min(matches.size(), first + PAGE_SIZE); i++) {
            JSONObject course = matches.get(i); String id = course.optString("id");
            rows.add(new Row(id, completed.computeIfAbsent(id, ignored -> Planner.completed(state, course))));
        }
        return new Page(matches.size(), page, rows);
    }
}
