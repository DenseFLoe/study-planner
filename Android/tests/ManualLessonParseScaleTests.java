package local.studyplanner;

import org.json.*;
import java.util.*;

public final class ManualLessonParseScaleTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject lesson(String id, String name, int minutes) throws Exception {
        return new JSONObject().put("id", id).put("name", name).put("durationMinutes", minutes);
    }
    // Previous identity matching rules, kept as a differential oracle for the faster index.
    static List<String> reference(List<JSONObject> old, List<JSONObject> input) throws Exception {
        List<JSONObject> rows = new ArrayList<>(); for (JSONObject row : input) rows.add(CourseTools.copy(row));
        Set<String> used = new HashSet<>();
        for (JSONObject row : rows) for (JSONObject previous : old)
            if (!used.contains(previous.getString("id")) && row.getString("name").equals(previous.getString("name")) && row.getInt("durationMinutes") == previous.getInt("durationMinutes")) {
                row.put("id", previous.getString("id")); used.add(previous.getString("id")); break;
            }
        for (JSONObject row : rows) if (!row.has("id")) {
            List<JSONObject> matches = new ArrayList<>();
            for (JSONObject previous : old) if (!used.contains(previous.getString("id")) && row.getString("name").equals(previous.getString("name"))) matches.add(previous);
            if (matches.size() == 1) { row.put("id", matches.get(0).getString("id")); used.add(matches.get(0).getString("id")); }
        }
        List<JSONObject> unmatched = new ArrayList<>(), remaining = new ArrayList<>();
        for (JSONObject row : rows) if (!row.has("id")) unmatched.add(row);
        for (JSONObject previous : old) if (!used.contains(previous.getString("id"))) remaining.add(previous);
        if (rows.size() == old.size() && unmatched.size() == 1 && remaining.size() == 1) unmatched.get(0).put("id", remaining.get(0).getString("id"));
        else if (!unmatched.isEmpty() && !remaining.isEmpty()) return null;
        List<String> ids = new ArrayList<>(); for (JSONObject row : rows) ids.add(row.optString("id", "NEW")); return ids;
    }
    static void differential() throws Exception {
        Random random = new Random(29032026);
        for (int trial = 0; trial < 300; trial++) {
            List<JSONObject> old = new ArrayList<>(), rows = new ArrayList<>(); int count = 1 + random.nextInt(25);
            for (int i = 0; i < count; i++) old.add(lesson("old-" + (trial % 10 == 0 ? i / 2 : i), "课节:" + random.nextInt(8), 1 + random.nextInt(4)));
            int newCount = 1 + random.nextInt(25);
            for (int i = 0; i < newCount; i++) rows.add(new JSONObject().put("name", "课节:" + random.nextInt(10)).put("durationMinutes", 1 + random.nextInt(5)));
            StringBuilder text = new StringBuilder(); for (JSONObject row : rows) text.append(row.getString("name")).append(':').append(row.getInt("durationMinutes")).append('\n');
            JSONObject course = new JSONObject().put("manualLessons", new JSONArray(old)); String before = course.toString();
            List<String> expected = reference(old, rows);
            try {
                JSONArray actual = Planner.parseManualLessons(text.toString(), course);
                check(expected != null, "Ambiguous edit was accepted");
                Set<String> known = new HashSet<>(), generated = new HashSet<>(); for (JSONObject lesson : old) known.add(lesson.getString("id"));
                List<String> resolved = new ArrayList<>();
                for (JSONObject row : Planner.list(actual)) { String id = row.getString("id"); resolved.add(known.contains(id) ? id : "NEW"); if (!known.contains(id)) check(generated.add(id), "Inserted rows reused a generated identity"); }
                check(resolved.equals(expected), "Indexed matching reassigned existing progress identity");
            } catch (IllegalArgumentException error) { check(expected == null, "Previously unambiguous edit was rejected"); }
            check(before.equals(course.toString()), "Parsing changed existing course metadata");
        }
    }
    static void largeReorder() throws Exception {
        JSONArray old = new JSONArray(); StringBuilder text = new StringBuilder();
        for (int i = 0; i < 10000; i++) old.put(lesson("lesson-" + i, "第" + i + "节", 60));
        for (int i = 9999; i >= 0; i--) text.append("第").append(i).append("节:60\n");
        JSONObject course = new JSONObject().put("manualLessons", old); String before = course.toString();
        JSONArray parsed = Planner.parseManualLessons(text.toString(), course);
        check(parsed.length() == 10000, "Large manual edit lost rows");
        for (int i = 0; i < parsed.length(); i++) check(parsed.getJSONObject(i).getString("id").equals("lesson-" + (9999 - i)), "Large reorder changed identity");
        check(before.equals(course.toString()), "Large edit mutated original course");
    }
    public static void main(String[] args) throws Exception {
        differential(); largeReorder();
        System.out.println("ManualLessonParseScaleTests: " + checks + " checks passed");
    }
}
