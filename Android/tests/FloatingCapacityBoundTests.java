package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

public class FloatingCapacityBoundTests {
    private static int checks;
    private static final JSONArray parity = new JSONArray();
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static String id(int value) { return String.format(Locale.ROOT, "00000000-0000-0000-0000-%012d", value); }
    private static JSONObject event(int serial, int start, int end, Integer duration) throws Exception {
        JSONObject value = new JSONObject().put("id", id(serial)).put("title", "Synthetic bound")
            .put("startMinute", start).put("endMinute", end).put("startDate", 0).put("endDate", 0)
            .put("weekdays", new JSONArray());
        if (duration != null) value.put("floatingDurationMinutes", duration);
        return value;
    }
    private static Map<String,Integer> expected(int... pairs) {
        Map<String,Integer> values = new HashMap<>();
        for (int i=0; i<pairs.length; i+=2) values.put(id(pairs[i]), pairs[i+1]);
        return values;
    }
    private static void fixture(String name, int[][] rows, int[][] studyWindows, Map<String,Integer> expected) throws Exception {
        List<JSONObject> events = new ArrayList<>();
        for (int[] row : rows) events.add(event(row[0], row[1], row[2], row[3] == 0 ? null : row[3]));
        boolean[] study = new boolean[1440];
        JSONArray studyMinutes = new JSONArray();
        for (int[] window : studyWindows) for (int minute=window[0]; minute<window[1]; minute++) study[minute] = true;
        for (int minute=0; minute<1440; minute++) if (study[minute]) studyMinutes.put(minute);
        String before = new JSONArray(events).toString();
        boolean[] beforeStudy = study.clone();
        Map<String,Integer> actual = Planner.reserve(events, study);
        check(Objects.equals(actual, expected), name + " witness changed: " + actual);
        check(before.equals(new JSONArray(events).toString()), name + " changed input events");
        check(Arrays.equals(study, beforeStudy), name + " changed study preferences");
        parity.put(new JSONObject().put("name", name).put("events", new JSONArray(events)).put("studyMinutes", studyMinutes)
                   .put("placements", actual == null ? JSONObject.NULL : new JSONObject(actual)));
    }
    public static void main(String[] args) throws Exception {
        int[][] noStudy = new int[0][];
        fixture("latest", new int[][]{{1,540,720,60}}, noStudy, expected(1,660));
        fixture("joint study avoidance", new int[][]{{1,540,660,60},{2,540,780,120}}, new int[][]{{600,660}}, expected(1,540,2,660));
        fixture("cost beats latest", new int[][]{{1,540,720,60}}, new int[][]{{600,720}}, expected(1,540));
        fixture("overlap union boundary", new int[][]{{1,540,660,60},{2,600,720,60}}, noStudy, expected(1,600,2,660));
        fixture("disjoint union boundary", new int[][]{{1,540,600,60},{2,660,720,60},{3,600,660,0}}, noStudy, expected(1,540,2,660));
        fixture("duplicate exact union", new int[][]{{1,540,720,60},{2,540,600,0},{3,540,600,0},{4,565,585,0}}, noStudy, expected(1,660));
        fixture("touching outside obstacles", new int[][]{{1,540,600,60},{2,0,540,0},{3,600,1440,0}}, noStudy, expected(1,540));
        fixture("overlap union overflow", new int[][]{{1,540,660,90},{2,540,660,90}}, noStudy, null);
        fixture("disjoint union overflow", new int[][]{{1,540,600,60},{2,660,720,60},{3,540,600,1}}, noStudy, null);
        fixture("exact subtraction overflow", new int[][]{{1,540,720,90},{2,540,720,75},{3,600,630,0}}, noStudy, null);
        fixture("fragmented continuous interval", new int[][]{{1,540,720,120},{2,600,630,0},{3,615,645,0}}, noStudy, null);
        fixture("full day boundary", new int[][]{{1,0,1440,1440}}, noStudy, expected(1,0));
        fixture("full day minus exact", new int[][]{{1,0,1440,1440},{2,0,1,0}}, noStudy, null);
        fixture("demand above day", new int[][]{{1,0,1440,720},{2,0,1440,721}}, noStudy, null);
        fixture("exact only", new int[][]{{1,540,720,0},{2,600,780,0}}, noStudy, expected());
        fixture("empty", new int[0][], noStudy, expected());
        for (int duration : new int[]{0,-1,61,Integer.MAX_VALUE}) {
            List<JSONObject> invalid = Collections.singletonList(event(1,540,600,duration));
            String before = new JSONArray(invalid).toString();
            check(Planner.reserve(invalid) == null, "invalid duration accepted: " + duration);
            check(before.equals(new JSONArray(invalid).toString()), "invalid event mutated");
        }
        for (int[] window : new int[][]{{600,600},{600,540},{-1,60},{0,1441}}) {
            List<JSONObject> invalid = Collections.singletonList(event(1,window[0],window[1],null));
            String before = new JSONArray(invalid).toString();
            check(Planner.reserve(invalid) == null, "exact-only preflight bypassed");
            check(before.equals(new JSONArray(invalid).toString()), "invalid exact event mutated");
        }
        List<JSONObject> many = new ArrayList<>();
        for (int i=0; i<1441; i++) many.add(event(i+1,0,1,1));
        String before = new JSONArray(many).toString();
        check(Planner.reserve(many) == null, "1441 positive demands accepted");
        check(before.equals(new JSONArray(many).toString()), "many events mutated");
        Files.createDirectories(Paths.get("Android/build/tests"));
        Files.write(Paths.get("Android/build/tests/floating-capacity-bound.json"), parity.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("PASS floating capacity bound " + checks + " checks; " + parity.length() + " deterministic parity fixtures");
    }
}
