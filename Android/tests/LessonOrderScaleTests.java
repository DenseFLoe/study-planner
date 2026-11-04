package local.studyplanner;

import org.json.*;
import java.util.*;

public final class LessonOrderScaleTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject course(List<String> ids, List<String> preferred) throws Exception {
        JSONArray lessons = new JSONArray();
        for (String id : ids) lessons.put(new JSONObject().put("id", id).put("name", id).put("durationMinutes", 1));
        JSONObject course = new JSONObject().put("manualLessons", lessons);
        if (preferred != null) course.put("lessonOrder", new JSONArray(preferred)); return course;
    }
    // Reference implementation preserves the prior list-based behavior for arbitrary partial orders.
    static List<String> reference(List<String> ids, List<String> preferred) {
        List<String> result = new ArrayList<>();
        if (preferred != null) for (String id : preferred) if (ids.contains(id) && !result.contains(id)) result.add(id);
        for (String id : ids) if (!result.contains(id)) result.add(id); return result;
    }
    static void equivalentOrders() throws Exception {
        Random random = new Random(20261104);
        for (int trial = 0; trial < 150; trial++) {
            List<String> ids = new ArrayList<>(), preferred = trial % 3 == 0 ? null : new ArrayList<>();
            for (int i = 0; i < random.nextInt(100); i++) ids.add("lesson-" + random.nextInt(70));
            if (preferred != null) for (int i = 0; i < random.nextInt(100); i++) preferred.add("lesson-" + random.nextInt(100));
            JSONObject course = course(ids, preferred); String before = course.toString();
            check(CourseTools.order(course).equals(reference(ids, preferred)), "Resolved order changed for partial/duplicate/stale IDs");
            check(before.equals(course.toString()), "Resolving order mutated the course");
        }
    }
    static void largeCatalogAndManualSave() throws Exception {
        List<String> ids = new ArrayList<>(); for (int i = 0; i < 30000; i++) ids.add("lesson-" + i);
        List<String> reversed = new ArrayList<>(ids); Collections.reverse(reversed);
        JSONObject course = course(ids, reversed);
        check(CourseTools.order(course).equals(reversed), "Large reversed catalog was truncated or reordered");
        Planner.updateManualLessons(course, CourseTools.copy(course).getJSONArray("manualLessons"));
        check(CourseTools.order(course).equals(reversed) && course.getInt("totalMinutes") == 30000, "Saving unchanged large catalog lost custom order");
        check(course.getJSONArray("manualLessons").getJSONObject(0).getString("id").equals(ids.get(0)), "Saving moved baseline progress to display order");
        JSONArray parsed = CourseTools.copy(course).getJSONArray("manualLessons");
        parsed.put(new JSONObject().put("id", "new-lesson").put("name", "新增").put("durationMinutes", 1));
        Planner.updateManualLessons(course, parsed); List<String> result = CourseTools.order(course);
        check(result.size() == 30001 && result.subList(0, 30000).equals(reversed) && result.get(30000).equals("new-lesson"), "New lesson did not append after custom order");
        parsed = new JSONArray().put(new JSONObject().put("id", "b").put("name", "b").put("durationMinutes", 1))
            .put(new JSONObject().put("id", "a").put("name", "a").put("durationMinutes", 1));
        course = course(Arrays.asList("a", "b"), Arrays.asList("a", "b"));
        Planner.updateManualLessons(course, parsed);
        check(CourseTools.order(course).equals(Arrays.asList("b", "a")), "Explicit manual reorder was ignored");
        check(course.getJSONArray("manualLessons").getJSONObject(0).getString("id").equals("a"), "Explicit reorder moved source baseline");
    }
    public static void main(String[] args) throws Exception {
        equivalentOrders(); largeCatalogAndManualSave();
        System.out.println("LessonOrderScaleTests: " + checks + " checks passed");
    }
}
