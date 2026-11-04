package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Read-only rule index, including expired rules that remain in the planner. */
final class FixedEventCatalog {
    static final int PAGE_SIZE = 20;
    static double lastRuleDate(JSONObject event) {
        JSONArray weekdays=event.optJSONArray("weekdays");
        return weekdays==null||weekdays.length()==0?event.optDouble("startDate"):event.optDouble("endDate");
    }
    static String dateRange(JSONObject event) {
        String first=Planner.date(event.optDouble("startDate")),last=Planner.date(lastRuleDate(event));
        return first.equals(last)?first:first+" 至 "+last;
    }
    /** Keep skipped rule days reachable; prefer today/next, then the last occurrence. */
    static LocalDate navigationDay(JSONObject event,LocalDate reference) {
        LocalDate first=Planner.day(event.optDouble("startDate")),last=Planner.day(lastRuleDate(event));
        if(first.isAfter(last))return null;
        LocalDate anchor=reference.isBefore(first)?first:reference.isAfter(last)?last:reference;
        for(int offset=0;offset<7;offset++){
            LocalDate candidate=anchor.plusDays(offset);if(candidate.isAfter(last))break;
            if(Planner.occurs(event,candidate,true))return candidate;
        }
        for(int offset=1;offset<7;offset++){
            LocalDate candidate=anchor.minusDays(offset);if(candidate.isBefore(first))break;
            if(Planner.occurs(event,candidate,true))return candidate;
        }
        return null;
    }
    enum Scope {
        CURRENT("当前与未来"), HISTORY("历史"), ALL("全部");
        final String title; Scope(String title) { this.title = title; }
    }
    private static final class Entry {
        final String id, text; final double start, end; final boolean historical; final int weekdayMask;
        Entry(JSONObject event, LocalDate today) {
            id = event.optString("id"); start = event.optDouble("startDate"); end = lastRuleDate(event);
            historical = Planner.day(end).isBefore(today);
            JSONArray weekdays=event.optJSONArray("weekdays");int mask=0;
            if(weekdays==null||weekdays.length()==0)mask=1<<Planner.weekday(Planner.day(start));
            else for(int i=0;i<weekdays.length();i++){int day=weekdays.optInt(i);if(day>=1&&day<=7)mask|=1<<day;}
            weekdayMask=mask;
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
        return find(query,scope,0,requestedPage);
    }
    Page find(String query, Scope scope, int weekday, int requestedPage) {
        if(weekday<0||weekday>7)throw new IllegalArgumentException("星期筛选应为全部或星期日到星期六。");
        String normalized = TaskSearch.normalize(query);
        String[] terms = normalized.isEmpty() ? new String[0] : normalized.split("\\s+");
        List<Entry> matches = new ArrayList<>();
        for (Entry entry : entries) {
            if (scope == Scope.CURRENT && entry.historical || scope == Scope.HISTORY && !entry.historical) continue;
            if(weekday!=0&&(entry.weekdayMask&(1<<weekday))==0)continue;
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
