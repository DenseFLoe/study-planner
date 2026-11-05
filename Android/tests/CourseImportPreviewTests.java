package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicInteger;

public final class CourseImportPreviewTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        LocalDate day = LocalDate.of(2026, 11, 5); double now = Planner.at(day, 480);
        JSONObject source = PlannerTests.empty();
        for (int weekday = 1; weekday <= 7; weekday++) source.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(weekday, 540, 1020));
        JSONObject snapshot = ImportParityTests.snapshot(50, 0, now);
        CourseImportRequest request = new CourseImportRequest(Collections.singletonList(snapshot),
            Collections.singleton(WebCourseImport.identity(snapshot)), null, Planner.at(day.plusDays(7), 0));
        String before = source.toString(), captureBefore = snapshot.toString();
        CourseImportPreview preview = CourseImportPreview.calculate(source, request, now);
        check(preview.schedule.count() > 0 && preview.schedule.plannedMinutes == preview.schedule.remainingMinutes, "Valid import preview lost planned lessons");
        check(source.toString().equals(before) && snapshot.toString().equals(captureBefore), "Preview modified planner or captured progress");
        for (int limit : new int[]{1, 3, 8, 12}) {
            AtomicInteger polls = new AtomicInteger();
            try {
                BackgroundCancellation.call(() -> polls.incrementAndGet() >= limit,
                    () -> CourseImportPreview.calculate(source, request, now));
                throw new AssertionError("Import preview ignored cancellation at checkpoint " + limit);
            } catch (CancellationException expected) { checks++; }
            check(source.toString().equals(before) && snapshot.toString().equals(captureBefore), "Cancelled preview changed source data");
        }
        // Exercise cancellation inside the planner's multi-day loop, after calculation has started.
        JSONObject longPlan = CourseTools.copy(source);
        longPlan.getJSONArray("courses").put(PlannerTests.course("长计划", 6000, day, day.plusYears(2), 60));
        String longBefore = longPlan.toString(); AtomicInteger polls = new AtomicInteger();
        try {
            BackgroundCancellation.call(() -> polls.incrementAndGet() >= 50, () -> Planner.replan(longPlan, now));
            throw new AssertionError("Planner did not stop during long preview");
        } catch (CancellationException expected) { checks++; }
        check(polls.get() == 50 && longPlan.toString().equals(longBefore), "Planner published partial schedule before cancellation");
        CourseImportPreview next = CourseImportPreview.calculate(source, request, now);
        check(next.schedule.plannedMinutes == preview.schedule.plannedMinutes, "Later preview inherited cancelled scope");
        System.out.println("Course import preview: " + checks + " checks passed");
    }
}
