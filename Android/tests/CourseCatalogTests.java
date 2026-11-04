package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class CourseCatalogTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static final class Queue implements java.util.concurrent.Executor {
        final Deque<Runnable> items=new ArrayDeque<>();
        public void execute(Runnable item){items.add(item);}
        void drain(){while(!items.isEmpty())items.remove().run();}
    }
    static void asynchronousSelectedPages() throws Exception {
        JSONObject old=fixture(),fresh=CourseTools.copy(old);
        String id=old.getJSONArray("courses").getJSONObject(0).getString("id");
        Planner.course(fresh,id).put("initialCompletedMinutes",123);
        Queue worker=new Queue(),ui=new Queue();List<CourseCatalog.Page> accepted=new ArrayList<>();List<Exception> errors=new ArrayList<>();
        LatestWork<CourseCatalog.Page> work=new LatestWork<>(worker,ui,accepted::add,errors::add);
        work.submit(()->new CourseCatalog(old).findSelected("",Collections.singleton(id),0));worker.drain();
        check(accepted.isEmpty(),"Background course lookup touched UI directly");
        work.clear();work.submit(()->new CourseCatalog(fresh).findSelected("",Collections.singleton(id),0));ui.drain();
        check(accepted.isEmpty(),"Old course progress appeared after refresh");worker.drain();ui.drain();
        check(accepted.size()==1&&accepted.get(0).rows.get(0).completedMinutes==123,"Fresh selected progress was lost");
        work.submit(()->{throw new IllegalStateException("old failure");});worker.drain();work.clear();ui.drain();
        check(errors.isEmpty(),"Old search failure replaced a new review");
        work.submit(()->{throw new IllegalStateException("current failure");});worker.drain();ui.drain();
        check(errors.size()==1,"Current search error was hidden");
        work.submit(()->new CourseCatalog(fresh).find("",0));worker.drain();work.close();ui.drain();
        work.submit(()->{throw new IllegalStateException("closed");});worker.drain();ui.drain();
        check(accepted.size()==1&&errors.size()==1,"Closed merge lookup delivered a result or error");
    }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty();
        for (int i = 50; i >= 0; i--) state.getJSONArray("courses").put(
            PlannerTests.course("课程 Test " + i, 600, DAY, DAY.plusDays(i / 10), 60)
                .put("id", new UUID(0x123456789abc4000L, 0x8000000000000000L + i).toString())
                .put("initialCompletedMinutes", i).put("notes", i % 2 == 0 ? "重点复习" : "普通"));
        state.getJSONArray("courses").put(PlannerTests.course("隐藏课程", 60, DAY, DAY, 60).put("isArchived", true));
        return state;
    }
    public static void main(String[] args) throws Exception {
        JSONObject state = fixture(); String before = SyncLedger.canonical(state); CourseCatalog catalog = new CourseCatalog(state);
        CourseCatalog.Page first = catalog.find("", 0), middle = catalog.find("", 1), last = catalog.find("", 2);
        check(first.count == 51 && first.pageCount == 3, "Visible course count includes archive or is truncated");
        check(first.rows.size() == 20 && middle.rows.size() == 20 && last.rows.size() == 11, "Course pages lose results or exceed 20 cards");
        check(first.rows.get(0).completedMinutes == 0 && last.rows.get(10).completedMinutes == 50, "Deadline ordering or progress is wrong");
        Set<String> ids = new HashSet<>(); for (CourseCatalog.Page page : Arrays.asList(first, middle, last)) for (CourseCatalog.Row row : page.rows) ids.add(row.id);
        check(ids.size() == 51, "Course repeated across pages");
        check(catalog.find("ＴＥＳＴ　重点 2026-11-05", 0).count == 5, "Combined normalized name, note and date search failed");
        check(catalog.find("隐藏课程", 0).count == 0, "Archived course appeared in management search");
        check(catalog.find("", 99).index == 2 && catalog.find("", -1).index == 0, "Page did not clamp after course changes");
        CourseCatalog.Page empty = catalog.find("missing", 99);
        check(empty.index == 0 && empty.pageCount == 0 && empty.rows.isEmpty(), "Empty query result has phantom page");
        check(catalog.find("　", 0).count == 51, "Blank full-width query did not restore all courses");
        try { first.rows.clear(); throw new AssertionError("Course page is mutable"); } catch (UnsupportedOperationException expected) { checks++; }
        check(SyncLedger.canonical(state).equals(before), "Catalog mutated course order or planner");
        JSONObject fresh = CourseTools.copy(state), edited = Planner.course(fresh, first.rows.get(0).id);
        edited.put("initialCompletedMinutes", 42);
        check(new CourseCatalog(fresh).find("", 0).rows.get(0).completedMinutes == 42, "New planner snapshot reused stale progress cache");
        check(first.rows.get(0).completedMinutes == 0, "Previously returned page retained mutable progress");
        CourseCatalog.Page noCourses = new CourseCatalog(PlannerTests.empty()).find("", 0);
        check(noCourses.count == 0 && noCourses.rows.isEmpty(), "Empty planner produced cards");
        JSONObject scoped = fixture();
        for (JSONObject course : Planner.list(scoped.getJSONArray("courses")))
            course.put("autoScheduleEnabled", course.optInt("initialCompletedMinutes") % 3 != 0);
        String scopeBefore = SyncLedger.canonical(scoped);
        CourseCatalog scopedCatalog = new CourseCatalog(scoped);
        CourseCatalog.Page paused = scopedCatalog.find("", CourseCatalog.Scope.PAUSED, 99);
        check(paused.count == 17 && paused.index == 0 && paused.rows.size() == 17, "Paused scope failed to clamp a previous page");
        check(scopedCatalog.find("", CourseCatalog.Scope.AUTOMATIC, 0).count == 34, "Automatic scope includes paused or archived courses");
        check(scopedCatalog.find("重点", CourseCatalog.Scope.PAUSED, 0).count == 9, "Keyword and scheduling-state filters did not combine");
        check(scopedCatalog.find("", CourseCatalog.Scope.ALL, 2).rows.size() == 11, "Returning to all courses lost a page");
        check(scopedCatalog.find("missing", CourseCatalog.Scope.PAUSED, 99).pageCount == 0, "Empty scoped search has phantom pages");
        check(SyncLedger.canonical(scoped).equals(scopeBefore), "Filtering changed automatic scheduling or progress");
        JSONObject legacy = PlannerTests.empty(), legacyCourse = PlannerTests.course("旧课程", 60, DAY, DAY, 60);
        legacyCourse.remove("autoScheduleEnabled"); legacy.getJSONArray("courses").put(legacyCourse);
        check(new CourseCatalog(legacy).find("", CourseCatalog.Scope.AUTOMATIC, 0).count == 1, "Legacy missing setting must default to automatic");
        check(new CourseCatalog(legacy).find("", CourseCatalog.Scope.PAUSED, 0).count == 0, "Legacy course appeared paused");
        JSONObject prioritized=fixture();
        for(JSONObject course:Planner.list(prioritized.getJSONArray("courses")))course.put("priority",course.optInt("initialCompletedMinutes")%3+1);
        String priorityBefore=SyncLedger.canonical(prioritized);CourseCatalog ordered=new CourseCatalog(prioritized);
        CourseCatalog.Page high=ordered.find("",CourseCatalog.Scope.ALL,CourseCatalog.Order.PRIORITY,0),second=ordered.find("",CourseCatalog.Scope.ALL,CourseCatalog.Order.PRIORITY,1),third=ordered.find("",CourseCatalog.Scope.ALL,CourseCatalog.Order.PRIORITY,2);
        check(high.rows.get(0).completedMinutes==2&&high.rows.get(16).completedMinutes==50,"High-priority courses are not ordered by deadline and identity");
        check(high.rows.get(17).completedMinutes==1&&third.rows.get(10).completedMinutes==48,"Priority groups or last page lost courses");
        Set<String> sortedIDs=new HashSet<>();for(CourseCatalog.Page part:Arrays.asList(high,second,third))for(CourseCatalog.Row row:part.rows)sortedIDs.add(row.id);
        check(sortedIDs.size()==51&&third.rows.size()==11,"Priority pagination duplicated or omitted courses");
        CourseCatalog.Page filtered=ordered.find("重点",CourseCatalog.Scope.AUTOMATIC,CourseCatalog.Order.PRIORITY,0);
        check(filtered.count==26&&filtered.rows.get(0).completedMinutes==2,"Priority order lost keyword or scope filtering");
        check(ordered.find("",0).rows.get(0).completedMinutes==0,"Switching back to deadlines reused priority order");
        check(ordered.find("none",CourseCatalog.Scope.ALL,CourseCatalog.Order.PRIORITY,99).pageCount==0,"Empty sorted catalog has pages");
        check(ordered.find("",CourseCatalog.Scope.ALL,CourseCatalog.Order.PRIORITY,99).index==2,"Sorted page did not clamp");
        check(priorityBefore.equals(SyncLedger.canonical(prioritized)),"List sorting changed scheduling data");
        Set<String> chosen=new HashSet<>(ids);String archived=state.getJSONArray("courses").getJSONObject(51).getString("id");
        chosen.add(archived);chosen.add("missing");
        CourseCatalog.Page chosenLast=catalog.findSelected("",chosen,99);
        check(chosenLast.count==51&&chosenLast.index==2&&chosenLast.rows.size()==11,"Selected-only pages include missing/archive or truncate the selection");
        check(catalog.findSelected("重点",chosen,0).count==26,"Selected-only view ignored keywords");
        chosen.clear();chosen.add(first.rows.get(0).id);chosen.add(last.rows.get(10).id);
        CourseCatalog.Page across=catalog.findSelected("",chosen,1);
        check(across.count==2&&across.index==0&&across.rows.size()==2,"Selections across distant pages cannot be reviewed together");
        check(across.rows.get(0).id.equals(first.rows.get(0).id)&&across.rows.get(1).id.equals(last.rows.get(10).id),"Selected-only view changed identities or order");
        chosen.remove(first.rows.get(0).id);
        check(catalog.findSelected("",chosen,2).rows.get(0).id.equals(last.rows.get(10).id),"Removing a selected row left stale results");
        check(across.rows.size()==2,"Earlier page changed with the selection");
        chosen.clear();check(catalog.findSelected("",chosen,99).pageCount==0,"Empty selection fell back to all courses");
        check(catalog.find("",0).count==51,"Selected-only filtering changed the full course index");
        check(SyncLedger.canonical(state).equals(before),"Selection filtering mutated planner data");
        asynchronousSelectedPages();
        System.out.println("Course catalog: " + checks + " checks passed");
    }
}
