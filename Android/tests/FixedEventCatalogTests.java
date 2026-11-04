package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class FixedEventCatalogTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty();
        for (int i = 46; i >= 0; i--) state.getJSONArray("fixedEvents").put(new JSONObject()
            .put("id", new UUID(0x123456789abc4000L, 0x8000000000000000L + i).toString())
            .put("title", "Meeting " + i).put("notes", i % 2 == 0 ? "复习" : "讨论")
            .put("startDate", Planner.at(DAY.minusDays(40), 0)).put("endDate", Planner.at(DAY.plusDays(i - 24), 0))
            .put("startMinute", 480).put("endMinute", 540).put("weekdays", new JSONArray().put(2)));
        return state;
    }
    public static void main(String[] args) throws Exception {
        JSONObject state = fixture(); String before = SyncLedger.canonical(state);
        FixedEventCatalog catalog = new FixedEventCatalog(state, DAY);
        FixedEventCatalog.Page current = catalog.find("", FixedEventCatalog.Scope.CURRENT, 0);
        FixedEventCatalog.Page history = catalog.find("", FixedEventCatalog.Scope.HISTORY, 0);
        check(current.count == 23 && history.count == 24, "Rule end-day scope boundary is wrong");
        check(current.ids.size() == 20 && catalog.find("", FixedEventCatalog.Scope.CURRENT, 1).ids.size() == 3, "Current rules truncated");
        check(Planner.day(catalog.event(current.ids.get(0)).getDouble("endDate")).equals(DAY), "Today-ending rule omitted or unstable equal-start order");
        check(Planner.day(catalog.event(history.ids.get(0)).getDouble("endDate")).equals(DAY.minusDays(1)), "History not newest-ending first");
        Set<String> ids = new HashSet<>();
        for (FixedEventCatalog.Scope scope : new FixedEventCatalog.Scope[]{FixedEventCatalog.Scope.CURRENT, FixedEventCatalog.Scope.HISTORY})
            for (int page = 0; page < 2; page++) ids.addAll(catalog.find("", scope, page).ids);
        check(ids.size() == 47, "Scopes lose rules");
        check(catalog.find("", FixedEventCatalog.Scope.ALL, 2).ids.size() == 7, "All-rules pagination is truncated");
        check(catalog.find("ＭＥＥＴＩＮＧ　复习", FixedEventCatalog.Scope.ALL, 0).count == 24, "Normalized name and note search failed");
        check(catalog.find("meeting 2026-11-04", FixedEventCatalog.Scope.ALL, 0).count == 1, "End-date search failed");
        check(catalog.find("2026-09-25", FixedEventCatalog.Scope.ALL, 0).count == 47, "Start-date search failed");
        check(catalog.find("复习", FixedEventCatalog.Scope.HISTORY, 0).count == 12, "Query escaped chosen scope");
        FixedEventCatalog.Page empty = catalog.find("missing", FixedEventCatalog.Scope.ALL, 999);
        check(empty.count == 0 && empty.index == 0 && empty.pageCount == 0 && empty.ids.isEmpty(), "Empty result has phantom page");
        check(catalog.find("", FixedEventCatalog.Scope.CURRENT, 999).index == 1 && catalog.find("", FixedEventCatalog.Scope.ALL, -1).index == 0, "Invalid page not clamped");
        check(catalog.find("　", FixedEventCatalog.Scope.ALL, 0).count == 47, "Blank full-width query should show all rules");
        try { current.ids.clear(); throw new AssertionError("Page IDs mutable"); } catch (UnsupportedOperationException expected) { checks++; }
        check(SyncLedger.canonical(state).equals(before), "Catalog mutated saved rules");
        check(new FixedEventCatalog(state, DAY.plusDays(1)).find("", FixedEventCatalog.Scope.HISTORY, 0).count == 25, "New day retained stale range boundary");
        state.put("fixedEvents", new JSONArray());
        check(new FixedEventCatalog(state, DAY).find("", FixedEventCatalog.Scope.ALL, 0).count == 0, "New snapshot retained removed rules");
        check(catalog.event(current.ids.get(0)) != null, "Existing snapshot lost its rule references");
        System.out.println("Fixed event catalog: " + checks + " checks passed");
    }
}
