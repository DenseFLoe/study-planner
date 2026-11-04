package local.studyplanner;

import java.util.*;

/** A display index only; positions always refer to the full, current draft order. */
final class LessonOrderList {
    static final int PAGE_SIZE = 50;
    private final Map<String, String> names, searchable = new HashMap<>();
    static final class Row {
        final String id, name; final int position;
        Row(String id, String name, int position) { this.id = id; this.name = name; this.position = position; }
    }
    static final class Page {
        final int count, index, pageCount; final List<Row> rows;
        Page(int count, int index, List<Row> rows) {
            this.count = count; this.index = index; pageCount = count == 0 ? 0 : (count - 1) / PAGE_SIZE + 1;
            this.rows = Collections.unmodifiableList(rows);
        }
    }
    LessonOrderList(Map<String, String> names) {
        this.names = new HashMap<>(names);
        names.forEach((id, name) -> searchable.put(id, TaskSearch.normalize(name)));
    }
    Page find(List<String> order, String query, int requestedPage) {
        String term = TaskSearch.normalize(query);
        String[] terms = term.isEmpty() ? new String[0] : term.split("\\s+");
        List<Integer> matches = new ArrayList<>();
        for (int position = 0; position < order.size(); position++) {
            String id = order.get(position), text = searchable.get(id);
            if (text == null) text = TaskSearch.normalize(id);
            boolean found = true;
            for (String word : terms) if (!text.contains(word)) { found = false; break; }
            if (found) matches.add(position);
        }
        int page = matches.isEmpty() ? 0 : Math.max(0, Math.min(requestedPage, (matches.size() - 1) / PAGE_SIZE));
        List<Row> rows = new ArrayList<>(); int first = page * PAGE_SIZE;
        for (int i = first; i < Math.min(matches.size(), first + PAGE_SIZE); i++) {
            int position = matches.get(i); String id = order.get(position);
            rows.add(new Row(id, names.getOrDefault(id, id), position + 1));
        }
        return new Page(matches.size(), page, rows);
    }
}
