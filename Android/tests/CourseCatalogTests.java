package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class CourseCatalogTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
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
        System.out.println("Course catalog: " + checks + " checks passed");
    }
}
