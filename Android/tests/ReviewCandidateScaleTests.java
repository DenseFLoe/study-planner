package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class ReviewCandidateScaleTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 1260);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    /** Frozen traversal used before indexing, for differential compatibility checks. */
    static List<JSONObject> reference(JSONObject state, double now) {
        List<JSONObject> result = new ArrayList<>(); double today = Planner.at(Planner.day(now), 0);
        int minute = (int)((now - today) / 60);
        for (JSONObject task : Planner.list(state.optJSONArray("tasks"))) {
            JSONObject course = Planner.course(state, task.optString("courseID"));
            if (Planner.pending(task) && course != null && !course.optBoolean("isArchived") &&
                    (Planner.planningEnd(task) <= today || minute >= state.getJSONObject("settings").optInt("notificationMinute") && Planner.planningEnd(task) <= now)) result.add(task);
        }
        return result;
    }
    public static void main(String[] args) throws Exception {
        Random random = new Random(20261104);
        for (int run = 0; run < 100; run++) {
            JSONObject state = PlannerTests.empty(); List<String> ids = new ArrayList<>();
            for (int i = 0; i < 15; i++) {
                JSONObject course = PlannerTests.course("课程 " + i, 600, DAY.minusDays(3), DAY.plusDays(3), 60).put("isArchived", random.nextBoolean());
                state.getJSONArray("courses").put(course); ids.add(course.getString("id"));
            }
            ids.add("missing-course");
            // Preserve the first-match behavior even while inspecting a malformed duplicate catalog.
            state.getJSONArray("courses").put(CourseTools.copy(state.getJSONArray("courses").getJSONObject(0)).put("isArchived", true));
            for (int i = 0; i < 80; i++) {
                double start = NOW + (random.nextInt(4000) - 2500) * 60.0;
                JSONObject task = Planner.task(ids.get(random.nextInt(ids.size())), start, 1 + random.nextInt(120));
                if (i % 3 == 0) task.put("floatingWindowStart", start).put("floatingWindowEnd", start + 300 * 60);
                if (i % 7 == 0) task.put("confirmedAt", NOW).put("status", "missed");
                state.getJSONArray("tasks").put(task);
            }
            String before = SyncLedger.canonical(state);
            for (double now : new double[]{Planner.at(DAY, 0), NOW - 1, NOW, NOW + 1})
                check(Planner.review(state, now).equals(reference(state, now)), "Indexed review changed membership, source object identity or order");
            check(SyncLedger.canonical(state).equals(before), "Candidate lookup mutated planner");
        }
        JSONObject large = PlannerTests.empty(); List<JSONObject> expected = new ArrayList<>();
        for (int i = 0; i < 8000; i++) {
            JSONObject course = PlannerTests.course("目录 " + i, 60, DAY.minusDays(2), DAY, 60).put("isArchived", i % 5 == 0);
            large.getJSONArray("courses").put(course);
            JSONObject task = Planner.task(course.getString("id"), Planner.at(DAY.minusDays(1), 480), 60); large.getJSONArray("tasks").put(task);
            if (i % 5 != 0) expected.add(task);
        }
        check(Planner.review(large, NOW).equals(expected), "Large catalog lost or reordered review candidates");
        System.out.println("Review candidate indexing: " + checks + " checks passed");
    }
}
