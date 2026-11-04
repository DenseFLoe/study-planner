package local.studyplanner;

import org.json.*;

/** Merge only fields owned by the settings form; preserve live scheduling state. */
public final class SettingsEditing {
    private SettingsEditing() {}

    static String signature(JSONObject settings, String key) throws Exception {
        if (key.equals("availability")) return SyncLedger.canonical(new JSONArray(Planner.studyWindows(settings)));
        if (key.equals("schedulingRuleLevels")) return SyncLedger.canonical(new SchedulePriorities(settings).json());
        return SyncLedger.canonical(settings.get(key));
    }

    static void validate(JSONObject settings) throws Exception {
        int unit = integer(settings, "minimumScheduleUnit"), notification = integer(settings, "notificationMinute");
        if (unit < 1 || unit > 1440 || notification < 0 || notification >= 1440)
            throw new IllegalArgumentException("请检查最小时间块和每日确认时间。");
        for (JSONObject window : Planner.list(settings.getJSONArray("availability"))) {
            int day = integer(window, "weekday"), start = integer(window, "startMinute"), end = integer(window, "endMinute");
            if (day < 1 || day > 7 || start < 0 || end > 1440 || start >= end)
                throw new IllegalArgumentException("请检查可学习时段的星期和起止时间。");
        }
        JSONObject levels = settings.optJSONObject("schedulingRuleLevels");
        if (levels != null) for (String rule : SchedulePriorities.RULES) if (levels.has(rule)) {
            int level = integer(levels, rule);
            if (level < 1 || level > 4) throw new IllegalArgumentException("排课偏好等级须在 1 到 4 之间。");
        }
    }

    private static int integer(JSONObject value, String key) {
        try { return Planner.exactProgressInteger(value.opt(key)); }
        catch (IllegalArgumentException error) { throw new IllegalArgumentException("学习设置中的分钟、星期与等级必须是有效整数。"); }
    }

    public static JSONObject resolve(JSONObject edited, JSONObject baseline, JSONObject current) throws Exception {
        validate(edited);
        JSONObject merged = CourseTools.copy(current);
        for (String key : new String[]{"minimumScheduleUnit", "notificationMinute", "availability", "schedulingRuleLevels"}) {
            String before = signature(baseline, key), after = signature(edited, key), latest = signature(current, key);
            if (after.equals(before)) continue;
            if (!latest.equals(before) && !latest.equals(after))
                throw new IllegalArgumentException("学习设置在编辑期间已有其他修改，与当前草稿冲突。草稿和最新数据均已保留；请先记录草稿，再点击「恢复已保存设置」查看最新值后重新编辑。");
            // Equivalent window IDs/order must not create a new edit or day anchor.
            if (!latest.equals(after)) merged.put(key, CourseTools.copyValue(edited.get(key)));
        }
        validate(merged);
        return merged;
    }

    public static void save(JSONObject state, JSONObject edited, JSONObject baseline, double now) throws Exception {
        Planner.updateStudySettings(state, resolve(edited, baseline, state.getJSONObject("settings")), now);
    }
}
