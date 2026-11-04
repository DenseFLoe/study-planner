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
        JSONObject legacyState=PlannerTests.empty(),single=fixture().getJSONArray("fixedEvents").getJSONObject(0);
        single.put("title","旧单次").put("startDate",Planner.at(DAY.minusDays(2),0)).put("endDate",Planner.at(DAY.plusDays(30),0))
            .put("weekdays",new JSONArray()).put("excludedDates",new JSONArray().put(Planner.at(DAY.minusDays(2),0)));
        JSONObject repeating=CourseTools.copy(single).put("id",Planner.id()).put("title","重复事项").put("weekdays",new JSONArray().put(2));
        JSONObject today=CourseTools.copy(single).put("id",Planner.id()).put("title","今天单次").put("startDate",Planner.at(DAY,0));
        legacyState.getJSONArray("fixedEvents").put(single).put(repeating).put(today);String original=SyncLedger.canonical(legacyState);
        FixedEventCatalog legacy=new FixedEventCatalog(legacyState,DAY);
        check(legacy.find("旧单次",FixedEventCatalog.Scope.HISTORY,0).count==1,"One-off used a legacy future end date instead of its occurrence day");
        check(legacy.find("旧单次",FixedEventCatalog.Scope.CURRENT,0).count==0,"Expired one-off remains current");
        check(legacy.find("重复事项",FixedEventCatalog.Scope.CURRENT,0).count==1,"Recurring interval was shortened");
        check(legacy.find("旧单次 2026-11-02",FixedEventCatalog.Scope.ALL,0).count==1,"One-off occurrence is not searchable");
        check(legacy.find("旧单次 2026-12-04",FixedEventCatalog.Scope.ALL,0).count==0,"Unused legacy end date is searchable");
        check(legacy.find("重复事项 2026-12-04",FixedEventCatalog.Scope.ALL,0).count==1,"Repeating cutoff is no longer searchable");
        check(legacy.find("今天单次",FixedEventCatalog.Scope.CURRENT,0).count==1&&new FixedEventCatalog(legacyState,DAY.plusDays(1)).find("今天单次",FixedEventCatalog.Scope.HISTORY,0).count==1,"One-off current/history boundary is not its actual day");
        check(FixedEventCatalog.dateRange(single).equals("2026-11-02")&&FixedEventCatalog.dateRange(repeating).equals("2026-11-02 至 2026-12-04"),"Displayed date range disagrees with search and classification");
        check(SyncLedger.canonical(legacyState).equals(original),"Display-only repair modified legacy or skipped rule data");
        JSONObject missing=CourseTools.copy(single);missing.remove("weekdays");
        check(FixedEventCatalog.lastRuleDate(missing)==single.getDouble("startDate"),"Legacy absent weekday list is not treated as a one-off");
        check(catalog.find("",FixedEventCatalog.Scope.ALL,2,2).count==47&&catalog.find("",FixedEventCatalog.Scope.ALL,2,2).ids.size()==7,"Weekday pages truncate matching rules");
        check(catalog.find("",FixedEventCatalog.Scope.ALL,4,99).pageCount==0,"Non-matching weekday retained old pages");
        check(catalog.find("ＭＥＥＴＩＮＧ 复习",FixedEventCatalog.Scope.HISTORY,2,0).count==12,"Weekday bypasses query or history scope");
        check(catalog.find("",FixedEventCatalog.Scope.HISTORY,2,99).index==1,"Weekday result does not clamp the page");
        check(legacy.find("旧单次",FixedEventCatalog.Scope.HISTORY,2,0).count==1,"Skipped single occurrence was removed from its weekday filter");
        check(legacy.find("旧单次",FixedEventCatalog.Scope.HISTORY,4,0).count==0,"One-off used today or end date as its weekday");
        check(legacy.find("",FixedEventCatalog.Scope.CURRENT,4,0).ids.equals(Collections.singletonList(today.getString("id"))),"Wednesday scope lost today's single occurrence");
        check(legacy.find("",FixedEventCatalog.Scope.CURRENT,2,0).ids.equals(Collections.singletonList(repeating.getString("id"))),"Recurring weekday was replaced by its start or end date");
        check(legacy.find("",FixedEventCatalog.Scope.ALL,0,0).count==3,"Clearing weekday did not restore all rules");
        for(int invalid:new int[]{-1,8})try{legacy.find("",FixedEventCatalog.Scope.ALL,invalid,0);throw new AssertionError("Invalid weekday accepted");}catch(IllegalArgumentException expected){checks++;}
        check(SyncLedger.canonical(legacyState).equals(original),"Weekday filtering modified stored rules");
        navigationDays();
        System.out.println("Fixed event catalog: " + checks + " checks passed");
    }

    static void navigationDays()throws Exception{
        JSONObject event=CourseTools.copy(fixture().getJSONArray("fixedEvents").getJSONObject(0))
            .put("startDate",Planner.at(LocalDate.of(2026,11,2),0)).put("endDate",Planner.at(LocalDate.of(2026,11,16),0))
            .put("weekdays",new JSONArray().put(2).put(4));
        for(int[] pair:new int[][]{{1,2},{2,2},{3,4},{4,4},{5,9},{16,16},{30,16}})
            check(FixedEventCatalog.navigationDay(event,LocalDate.of(2026,11,pair[0])).equals(LocalDate.of(2026,11,pair[1])),"Calendar link selected a nonmatching or distant date");
        event.put("endDate",Planner.at(LocalDate.of(2026,11,15),0));
        check(FixedEventCatalog.navigationDay(event,LocalDate.of(2026,11,16)).equals(LocalDate.of(2026,11,11)),"Ended rule uses cutoff instead of last occurrence");
        check(FixedEventCatalog.navigationDay(event,LocalDate.of(2026,11,14)).equals(LocalDate.of(2026,11,11)),"Tail of rule range invents a later occurrence");
        event.put("excludedDates",new JSONArray().put(Planner.at(DAY,720))).put("floatingDurationMinutes",30);
        String before=SyncLedger.canonical(event);
        check(FixedEventCatalog.navigationDay(event,DAY.minusDays(1)).equals(DAY)&&!Planner.occurs(event,DAY),"Skipped floating rule cannot be located for restoration");
        check(SyncLedger.canonical(event).equals(before),"Navigation modified the rule");
        JSONObject single=CourseTools.copy(event).put("weekdays",new JSONArray()).put("endDate",Planner.at(LocalDate.of(2026,11,30),0));
        for(int day:new int[]{1,2,3,30})check(FixedEventCatalog.navigationDay(single,LocalDate.of(2026,11,day)).equals(LocalDate.of(2026,11,2)),"Legacy one-off end date affects navigation");
        single.remove("weekdays");check(FixedEventCatalog.navigationDay(single,DAY).equals(LocalDate.of(2026,11,2)),"Legacy missing weekdays are not treated as a single occurrence");
        JSONObject none=CourseTools.copy(event).put("startDate",Planner.at(DAY.minusDays(1),0)).put("endDate",Planner.at(DAY.minusDays(1),0));
        check(FixedEventCatalog.navigationDay(none,DAY)==null,"No-match short range invented an occurrence");
        none.put("startDate",Planner.at(DAY,0));check(FixedEventCatalog.navigationDay(none,DAY)==null,"Reversed range invented an occurrence");
        none=CourseTools.copy(event).put("weekdays",new JSONArray().put(0).put(8));check(FixedEventCatalog.navigationDay(none,DAY)==null,"Invalid weekdays invented an occurrence");
        LocalDate cutoff=LocalDate.of(2200,11,1);event.put("endDate",Planner.at(cutoff,0)).put("weekdays",new JSONArray().put(1));
        LocalDate last=FixedEventCatalog.navigationDay(event,cutoff.plusDays(30));
        check(last!=null&&!last.isAfter(cutoff)&&Planner.weekday(last)==1&&java.time.temporal.ChronoUnit.DAYS.between(last,cutoff)<7,"Long range navigation did not use the last matching week");
    }
}
