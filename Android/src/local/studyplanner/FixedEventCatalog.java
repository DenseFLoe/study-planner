package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Read-only rule index, including expired rules that remain in the planner. */
final class FixedEventCatalog {
    static final int PAGE_SIZE = 20;
    enum Scope {
        CURRENT("当前与未来"), HISTORY("历史"), ALL("全部");
        final String title; Scope(String title) { this.title = title; }
    }
    private static final class Entry {
        final String id, text; final double start, end; final boolean historical;
        Entry(JSONObject event, LocalDate today) {
            id = event.optString("id"); start = event.optDouble("startDate"); end = event.optDouble("endDate");
            historical = Planner.day(end).isBefore(today);
            text = TaskSearch.normalize(event.optString("title") + " " + event.optString("notes") + " " +
                    Planner.date(start) + " " + Planner.date(end));
        }
    }
    static final class Page {
        final int count, index, pageCount; final List<String> ids;
        Page(int count, int index, List<String> ids) {
            this.count = count; this.index = index; pageCount = count == 0 ? 0 : (count - 1) / PAGE_SIZE + 1;
            this.ids = Collections.unmodifiableList(ids);
        }
    }
    private final List<Entry> entries = new ArrayList<>();
    private final Map<String, JSONObject> events = new HashMap<>();
    FixedEventCatalog(JSONObject state, LocalDate today) {
        for (JSONObject event : Planner.list(state.optJSONArray("fixedEvents"))) {
            entries.add(new Entry(event, today)); events.put(event.optString("id"), event);
        }
    }
    // Existing event editors copy this read-only snapshot before changing it.
    JSONObject event(String id) { return events.get(id); }
    Page find(String query, Scope scope, int requestedPage) {
        String normalized = TaskSearch.normalize(query);
        String[] terms = normalized.isEmpty() ? new String[0] : normalized.split("\\s+");
        List<Entry> matches = new ArrayList<>();
        for (Entry entry : entries) {
            if (scope == Scope.CURRENT && entry.historical || scope == Scope.HISTORY && !entry.historical) continue;
            boolean found = true; for (String term : terms) if (!entry.text.contains(term)) { found = false; break; }
            if (found) matches.add(entry);
        }
        Comparator<Entry> byDate = scope == Scope.HISTORY ? Comparator.comparingDouble((Entry entry) -> entry.end).reversed() :
                Comparator.comparingDouble(entry -> entry.start);
        matches.sort(byDate.thenComparing(entry -> entry.id));
        int page = matches.isEmpty() ? 0 : Math.max(0, Math.min(requestedPage, (matches.size() - 1) / PAGE_SIZE));
        int first = page * PAGE_SIZE; List<String> ids = new ArrayList<>();
        for (int i = first; i < Math.min(matches.size(), first + PAGE_SIZE); i++) ids.add(matches.get(i).id);
        return new Page(matches.size(), page, ids);
    }
}
