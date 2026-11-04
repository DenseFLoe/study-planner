package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** A conflict choice consents only to the occupants shown in that review. */
public final class FixedEventEditing {
    private FixedEventEditing() {}

    public static final class ReviewRequired extends IllegalArgumentException {
        public final JSONObject event;
        public final List<Planner.EventConflict> conflicts;
        ReviewRequired(JSONObject event, List<Planner.EventConflict> conflicts) throws Exception {
            super(Planner.conflictMessage(conflicts));
            this.event = CourseTools.copy(event);
            this.conflicts = Collections.unmodifiableList(new ArrayList<>(conflicts));
        }
    }

    static IllegalArgumentException conflict() {
        return new IllegalArgumentException("这条固定事项在编辑期间已有其他修改，与当前草稿冲突。草稿仍保留，最新数据未被覆盖，请重新打开事项后编辑。");
    }

    private static JSONObject current(JSONObject state, JSONObject baseline) throws Exception {
        if (baseline != null) for (JSONObject event : Planner.list(state.getJSONArray("fixedEvents")))
            if (event.getString("id").equals(baseline.getString("id"))) return event;
        throw new IllegalArgumentException("这条固定事项已不存在，请刷新日程后重试。");
    }

    public static void removeFuture(JSONObject state, JSONObject baseline, double now) throws Exception {
        JSONObject latest = current(state, baseline);
        boolean changed = !schedulingInputs(baseline).equals(schedulingInputs(latest));
        for (String key : new String[]{"title", "notes", "color"})
            changed |= !baseline.optString(key, key.equals("color") ? "orange" : "").equals(latest.optString(key, key.equals("color") ? "orange" : ""));
        if (changed) throw new IllegalArgumentException("这条固定事项已更新，未删除未来安排。请重新打开事项核对后再删除。");
        Planner.removeEvent(state, latest.getString("id"), now);
    }

    private static String occurrence(JSONObject event, LocalDate date) throws Exception {
        return SyncLedger.canonical(new JSONArray().put(event.getString("id")).put(event.optString("title"))
            .put(event.getInt("startMinute")).put(event.getInt("endMinute"))
            .put(Planner.floating(event)).put(Planner.occupied(event))
            .put(Planner.occurs(event, date, true)).put(Planner.occurs(event, date)));
    }

    public static void setSkipped(JSONObject state, JSONObject displayed, LocalDate date, boolean skipped, double now) throws Exception {
        JSONObject latest = current(state, displayed);
        // Only this occurrence was reviewed; other days and notes can change independently.
        if (!occurrence(displayed, date).equals(occurrence(latest, date)))
            throw new IllegalArgumentException("这一天的固定事项已有变化，未执行移除或恢复。请刷新日程并核对后重试。");
        Planner.setEventSkipped(state, latest.getString("id"), date, skipped, now);
    }

    static String schedulingInputs(JSONObject event) throws Exception {
        JSONObject value = CourseTools.copy(event);
        for (String key : new String[]{"title", "notes", "color"}) value.remove(key);
        Set<Integer> weekdays = new TreeSet<>();
        JSONArray weeks = event.optJSONArray("weekdays");
        if (weeks != null) for (int i = 0; i < weeks.length(); i++) weekdays.add(weeks.getInt(i));
        Set<String> excluded = new TreeSet<>();
        JSONArray dates = event.optJSONArray("excludedDates");
        if (dates != null) for (int i = 0; i < dates.length(); i++) excluded.add(Planner.day(dates.getDouble(i)).toString());
        value.put("weekdays", new JSONArray(weekdays)).put("excludedDates", new JSONArray(excluded));
        for (String key : new String[]{"startDate", "endDate"}) value.put(key, Planner.day(event.getDouble(key)).toString());
        return SyncLedger.canonical(value);
    }

    static JSONObject resolve(JSONObject state, JSONObject edited, JSONObject baseline) throws Exception {
        JSONObject current = null;
        for (JSONObject event : Planner.list(state.getJSONArray("fixedEvents")))
            if (event.getString("id").equals(edited.getString("id"))) current = event;
        if (baseline == null) {
            if (current != null) throw conflict();
            return CourseTools.copy(edited);
        }
        if (!edited.getString("id").equals(baseline.getString("id"))) throw conflict();
        if (current == null) throw new IllegalArgumentException("这条固定事项已被删除，旧编辑窗口不能重新创建它。草稿仍保留，请关闭窗口后查看最新事项。");
        String old = schedulingInputs(baseline), draft = schedulingInputs(edited), latest = schedulingInputs(current);
        JSONObject merged;
        if (draft.equals(old)) merged = CourseTools.copy(current);
        else if (latest.equals(old) || draft.equals(latest)) merged = CourseTools.copy(edited);
        else throw conflict();
        for (String key : new String[]{"title", "notes", "color"}) {
            String fallback = key.equals("color") ? "orange" : "";
            String before = baseline.optString(key, fallback), after = edited.optString(key, fallback);
            String now = current.optString(key, fallback);
            if (after.equals(before)) merged.put(key, now);
            else if (now.equals(before) || now.equals(after)) merged.put(key, after);
            else throw conflict();
        }
        return merged;
    }

    static List<String> signature(List<Planner.EventConflict> conflicts) throws Exception {
        List<String> result = new ArrayList<>();
        for (Planner.EventConflict c : conflicts) result.add(SyncLedger.canonical(new JSONArray()
            .put(c.eventID).put(c.title).put(c.date.toString()).put(c.start).put(c.end)
            .put(c.requestedStart).put(c.requestedEnd).put(c.floatingMinutes == null ? JSONObject.NULL : c.floatingMinutes).put(c.reason)));
        Collections.sort(result);
        return result;
    }

    public static void save(JSONObject state, JSONObject edited, JSONObject baseline, double now,
                            Set<LocalDate> skipped, Set<LocalDate> skippedLocal,
                            List<Planner.EventConflict> reviewed) throws Exception {
        JSONObject resolved = resolve(state, edited, baseline);
        if (reviewed != null) {
            List<Planner.EventConflict> current = Collections.emptyList();
            try { Planner.saveEvent(CourseTools.copy(state), CourseTools.copy(resolved), now); }
            catch (Planner.EventConflictException error) { current = error.conflicts; }
            if (!signature(current).equals(signature(reviewed))) {
                if (!current.isEmpty()) throw new ReviewRequired(resolved, current);
                throw new IllegalArgumentException("冲突安排已发生变化，原来的跳过选择未保存。请返回修改后重新检查冲突。");
            }
        } else if (!skipped.isEmpty() || !skippedLocal.isEmpty()) {
            throw new IllegalArgumentException("请先核对冲突事项，再选择跳过日期。");
        }
        JSONObject next = CourseTools.copy(state);
        try { Planner.saveEvent(next, resolved, now, skipped, skippedLocal); }
        catch (Planner.EventConflictException error) { throw new ReviewRequired(resolved, error.conflicts); }
        state.put("fixedEvents", next.getJSONArray("fixedEvents"));
    }
}
