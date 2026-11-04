package local.studyplanner;

import org.json.*;
import java.time.LocalDate;

/** Optimistic preview plus a save guard, so a remote swap cannot accidentally be undone. */
final class DailyTaskSwapDraft {
    final JSONObject preview;
    private final String sourceID, targetID, before, after;
    private final LocalDate day;

    DailyTaskSwapDraft(JSONObject state, String sourceID, String targetID, double now) throws Exception {
        this.sourceID = sourceID; this.targetID = targetID;
        JSONObject source = null;
        for (JSONObject task : Planner.list(state.getJSONArray("tasks"))) if (task.getString("id").equals(sourceID)) source = task;
        if (source == null) throw new IllegalArgumentException("该任务已不存在，请刷新后重试。");
        day = Planner.day(source.getDouble("start")); before = signature(state);
        preview = CourseTools.copy(state); DailyTaskOrdering.swap(preview, sourceID, targetID, now);
        after = signature(preview);
    }

    private String signature(JSONObject state) throws Exception {
        JSONObject tasks = new JSONObject(); JSONArray orders = new JSONArray();
        for (JSONObject task : Planner.list(state.getJSONArray("tasks")))
            if (Planner.pending(task) && day.equals(Planner.day(task.getDouble("start")))) tasks.put(task.getString("id"), task);
        JSONArray saved = state.getJSONObject("settings").optJSONArray("dailyTaskOrders");
        if (saved != null) for (JSONObject order : Planner.list(saved)) if (day.equals(Planner.day(order.getDouble("day")))) orders.put(order);
        return SyncLedger.canonical(new JSONObject().put("tasks", tasks).put("orders", orders));
    }

    void apply(JSONObject current, double now) throws Exception {
        if (day.isBefore(Planner.day(now))) throw new IllegalArgumentException("保存时已跨到新一天，不能交换往日任务。请核对最新日程。");
        String latest = signature(current);
        if (after.equals(latest)) return;
        if (!before.equals(latest)) throw new IllegalArgumentException("当天任务或顺序在保存前已有更新，未覆盖最新安排。请核对后重新交换。");
        DailyTaskOrdering.swap(current, sourceID, targetID, now);
    }
}
