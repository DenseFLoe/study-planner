package local.studyplanner;

import org.json.*;
import java.util.*;

/** Raw input survives refreshes, including partially typed or invalid time ranges. */
final class SettingsDraft {
    final JSONObject baseline;
    String unit, notification;
    final String[] availability = new String[7];
    JSONObject levels;
    private final String original;

    SettingsDraft(JSONObject settings) throws Exception {
        baseline = new JSONObject();
        for (String key : new String[]{"minimumScheduleUnit", "notificationMinute", "availability", "schedulingRuleLevels"})
            if (settings.has(key)) baseline.put(key, CourseTools.copyValue(settings.get(key)));
        unit = Integer.toString(settings.getInt("minimumScheduleUnit"));
        notification = Planner.time(settings.getInt("notificationMinute"));
        Arrays.fill(availability, "");
        for (int i = 0; i < 7; i++) for (JSONObject window : Planner.list(settings.getJSONArray("availability")))
            if (window.getInt("weekday") == (i + 1) % 7 + 1)
                availability[i] += (availability[i].isEmpty() ? "" : ", ") + Planner.time(window.getInt("startMinute")) + "-" + Planner.time(window.getInt("endMinute"));
        levels = new SchedulePriorities(settings).json();
        original = SyncLedger.canonical(input());
    }

    private JSONObject input() throws Exception {
        return new JSONObject().put("unit", unit).put("notification", notification)
            .put("availability", new JSONArray(Arrays.asList(availability))).put("levels", CourseTools.copy(levels));
    }

    boolean isDirty() throws Exception { return !original.equals(SyncLedger.canonical(input())); }

    JSONObject snapshot() throws Exception { return input().put("baseline", CourseTools.copy(baseline)); }

    static SettingsDraft restore(JSONObject saved) throws Exception {
        SettingsDraft draft = new SettingsDraft(saved.getJSONObject("baseline"));
        draft.unit = saved.getString("unit"); draft.notification = saved.getString("notification");
        JSONArray rows = saved.getJSONArray("availability");
        if (rows.length() != 7) throw new IllegalArgumentException("设置草稿的星期数据不完整。");
        for (int i = 0; i < 7; i++) draft.availability[i] = rows.getString(i);
        draft.levels = CourseTools.copy(saved.getJSONObject("levels"));
        return draft;
    }

    JSONObject editedSettings() throws Exception {
        int minimum;
        try { minimum = Integer.parseInt(unit.trim()); }
        catch (NumberFormatException error) { throw new IllegalArgumentException("请填写整数分钟的最小时间块。"); }
        JSONObject edited = CourseTools.copy(baseline).put("minimumScheduleUnit", minimum)
            .put("notificationMinute", Planner.minute(notification.trim())).put("schedulingRuleLevels", CourseTools.copy(levels));
        JSONArray windows = new JSONArray();
        for (int i = 0; i < 7; i++) {
            String line = Planner.normalizeTimeText(availability[i]).trim().replace('–', '-').replace('—', '-').replace('−', '-');
            if (line.isEmpty()) continue;
            for (String token : line.split("[,，]", -1)) {
                String[] parts = token.trim().split("-", -1);
                if (parts.length != 2) throw new IllegalArgumentException("时段格式应为 08:00-12:00，多个时段用逗号分隔。");
                windows.put(new JSONObject().put("id", Planner.id()).put("weekday", (i + 1) % 7 + 1)
                    .put("startMinute", Planner.minute(parts[0].trim())).put("endMinute", Planner.minute(parts[1].trim())));
            }
        }
        edited.put("availability", windows); SettingsEditing.validate(edited); return edited;
    }
}
