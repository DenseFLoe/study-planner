package local.studyplanner;

import org.json.*;
import java.util.*;

/** Immutable searchable file rows; scans and course expansion belong on the worker. */
final class CourseFileSearch {
    static final int PAGE_SIZE = 100;
    static final class Row {
        final String id, name, path;
        final long bytes;
        final boolean hasFile, estimated;
        private final String searchable;
        Row(JSONObject lesson, JSONObject file) {
            id = lesson.optString("id"); name = lesson.optString("name"); hasFile = file != null;
            path = file == null ? "" : file.optString("path"); bytes = file == null ? 0 : file.optLong("size");
            estimated = file != null && file.optBoolean("estimatedDuration");
            searchable = TaskSearch.normalize(name + " " + path);
        }
        String label() { return name + "\n" + path + (hasFile ? "\n" + bytes + " 字节 · " + (estimated ? "估算时长" : "网站时长") : "\n未记录文件信息"); }
    }
    static final class Result {
        private final List<Row> rows;
        Result(List<Row> rows) { this.rows = Collections.unmodifiableList(rows); }
        int count() { return rows.size(); }
        int pageCount() { return rows.isEmpty() ? 0 : (rows.size() - 1) / PAGE_SIZE + 1; }
        List<Row> page(int index) {
            if (index < 0 || index >= pageCount()) return Collections.emptyList();
            int start = index * PAGE_SIZE; return rows.subList(start, Math.min(start + PAGE_SIZE, rows.size()));
        }
    }
    private final List<Row> rows = new ArrayList<>();
    CourseFileSearch(JSONObject course) throws Exception {
        JSONObject files = course.optJSONObject("netdiskLessons");
        for (JSONObject lesson : CourseTools.lessons(course)) rows.add(new Row(lesson, files == null ? null : files.optJSONObject(lesson.optString("id"))));
    }
    Result find(String query) {
        String normalized = TaskSearch.normalize(query); String[] terms = normalized.isEmpty() ? new String[0] : normalized.split("\\s+");
        List<Row> matches = new ArrayList<>();
        for (Row row : rows) {
            boolean found = true; for (String term : terms) if (!row.searchable.contains(term)) { found = false; break; }
            if (found) matches.add(row);
        }
        return new Result(matches);
    }
}
