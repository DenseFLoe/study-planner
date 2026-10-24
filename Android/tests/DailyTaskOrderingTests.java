package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class DailyTaskOrderingTests {
    static final LocalDate DAY = LocalDate.of(2026, 10, 5);
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }

    static JSONObject fixture(int nextMinute) throws Exception {
        JSONObject state = PlannerTests.empty();
        state.getJSONObject("settings").put("availability", new JSONArray()
            .put(PlannerTests.window(2, 1320, 1370)).put(PlannerTests.window(2, 1380, 1440))
            .put(PlannerTests.window(3, 0, 60)));
        int[] lengths = {50, 30, 30};
        for (int i = 0; i < lengths.length; i++) {
            JSONObject course = PlannerTests.course("跨日合成课" + i, lengths[i], DAY, DAY.plusDays(1), lengths[i]);
            state.getJSONArray("courses").put(course);
            double start = i == 2 ? Planner.at(DAY.plusDays(1), nextMinute) : Planner.at(DAY, 1320 + i * 60);
            state.getJSONArray("tasks").put(Planner.task(course.getString("id"), start, lengths[i]));
        }
        return state;
    }

    public static void main(String[] args) throws Exception {
        JSONObject state = fixture(0);
        String original = state.toString();
        try {
            DailyTaskOrdering.swap(state, state.getJSONArray("tasks").getJSONObject(0).getString("id"),
                state.getJSONArray("tasks").getJSONObject(1).getString("id"), Planner.at(DAY, 1260));
            throw new AssertionError("Swap shortened the midnight break to ten minutes");
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().equals(DailyTaskOrdering.NO_SPACE), "Wrong rejection");
            check(state.toString().equals(original), "Rejected swap mutated state");
        }
        state = fixture(5);
        JSONObject nextDay = new JSONObject(state.getJSONArray("tasks").getJSONObject(2).toString());
        DailyTaskOrdering.swap(state, state.getJSONArray("tasks").getJSONObject(0).getString("id"),
            state.getJSONArray("tasks").getJSONObject(1).getString("id"), Planner.at(DAY, 1260));
        List<JSONObject> tasks = PlannerTests.sortedTasks(state);
        check(nextDay.similar(tasks.get(2)), "Swap changed next day's task");
        check(nextDay.getDouble("start") - Planner.end(tasks.get(1)) == 900, "Exact 15-minute boundary rejected");
        for (boolean storedDrafts : new boolean[]{false, true}) {
            state = fixture(0);
            List<JSONObject> generated = PlannerTests.sortedTasks(state);
            List<String> keys = DailyTaskOrdering.keys(generated.subList(0, 2));
            Collections.reverse(keys);
            state.getJSONObject("settings").put("dailyTaskOrders", new JSONArray().put(new JSONObject()
                .put("day", Planner.at(DAY, 0)).put("keys", new JSONArray(keys))));
            if (!storedDrafts) state.put("tasks", new JSONArray());
            List<JSONObject> result = DailyTaskOrdering.apply(state, generated, Collections.emptyList());
            check(new JSONArray(result).similar(new JSONArray(generated)), "Saved order ignored next day's generated work");
        }
        System.out.println("DailyTaskOrderingTests: " + checks + " checks passed");
    }
}
