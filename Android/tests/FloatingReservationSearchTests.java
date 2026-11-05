package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public class FloatingReservationSearchTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 5);
    static final double NOW = Planner.at(DAY, 0);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject event(int id, int start, int end, Integer duration) throws Exception {
        JSONObject event = new JSONObject().put("id", String.format(Locale.ROOT, "00000000-0000-0000-0000-%012d", id))
            .put("title", "Synthetic " + id).put("startMinute", start).put("endMinute", end)
            .put("startDate", NOW).put("endDate", NOW).put("weekdays", new JSONArray());
        if (duration != null) event.put("floatingDurationMinutes", duration);
        return event;
    }
    // Each listed start is an independently checked, complete feasible witness.
    // The original latest-first search uses 20,000 attempts without finding it.
    static List<JSONObject> difficult() throws Exception {
        int[][] rows = {{0,65,10}, {0,240,85}, {0,165,15}, {40,290,80}, {175,330,60}, {170,350,30}};
        List<JSONObject> events = new ArrayList<>();
        for (int i = 0; i < rows.length; i++) events.add(event(i + 1, 480 + rows[i][0], 480 + rows[i][1], rows[i][2]));
        return events;
    }
    static void witness(List<JSONObject> events, int[] starts) {
        boolean[] used = new boolean[1440];
        for (int i = 0; i < events.size(); i++) {
            JSONObject event = events.get(i); int start = starts[i], end = start + Planner.occupied(event);
            check(start >= event.optInt("startMinute") && end <= event.optInt("endMinute"), "Witness outside window");
            for (int minute = start; minute < end; minute++) {
                check(!used[minute], "Witness overlaps"); used[minute] = true;
            }
        }
    }
    static void exhaustedSave() throws Exception {
        List<JSONObject> events = difficult();
        witness(events, new int[]{480,495,600,620,720,795});
        JSONObject state = PlannerTests.empty(), draft = events.remove(events.size() - 1);
        state.put("fixedEvents", new JSONArray(events));
        String before = state.toString(), input = draft.toString();
        try { Planner.saveEvent(state, draft, NOW); throw new AssertionError("Unproven save accepted"); }
        catch (Planner.EventConflictException error) {
            check(error.conflicts.size() == 5, "Missing review occupants");
            for (Planner.EventConflict conflict : error.conflicts) {
                check("searchLimit".equals(conflict.reason), "Feasible schedule mislabeled: " + conflict.reason);
                check(conflict.explanation().contains("未证实容量不足") && conflict.reviewHeading().contains("排法待确认"), "Review claimed a proven conflict");
            }
        }
        check(before.equals(state.toString()) && input.equals(draft.toString()), "Failed save changed data");
    }
    static Planner.ReservationResult reserve(List<JSONObject> events, int limit) {
        return Planner.reserveResult(events, new boolean[1440], limit);
    }
    static void budgetBoundaries() throws Exception {
        check(reserve(Collections.emptyList(), 0).status == Planner.ReservationStatus.FEASIBLE, "Empty plan needs no search");
        List<JSONObject> one = Collections.singletonList(event(1, 480, 481, 1));
        check(reserve(one, 0).status == Planner.ReservationStatus.SEARCH_EXHAUSTED, "Zero budget proved failure");
        Planner.ReservationResult last = reserve(one, 1);
        check(last.status == Planner.ReservationStatus.FEASIBLE && last.attempts == 1, "Last allowed attempt lost its witness");
        check(last.placements.get(one.get(0).getString("id")) == 480, "Wrong final witness");
        List<JSONObject> fragmented = Arrays.asList(event(1, 480, 483, 2), event(2, 481, 482, null));
        check(reserve(fragmented, 1).status == Planner.ReservationStatus.SEARCH_EXHAUSTED, "Incomplete traversal proved failure");
        Planner.ReservationResult complete = reserve(fragmented, 2);
        check(complete.status == Planner.ReservationStatus.INFEASIBLE && complete.attempts == 2, "Complete traversal at budget mislabeled");
        check(reserve(Arrays.asList(event(1, 480, 482, 2), event(2, 480, 482, 1)), 0).status == Planner.ReservationStatus.INFEASIBLE, "Nominal bound needs no search");
        check(reserve(Collections.singletonList(event(1, 480, 481, 2)), 0).status == Planner.ReservationStatus.INVALID_INPUT, "Invalid input treated as search exhaustion");
        boolean[] study = new boolean[1440]; study[480] = study[481] = true;
        List<JSONObject> optimizing = Arrays.asList(event(1, 480, 485, 2), event(2, 480, 485, 2));
        Planner.ReservationResult partial = Planner.reserveResult(optimizing, study, 4);
        check(partial.status == Planner.ReservationStatus.FEASIBLE && partial.attempts == 4, "Optimization cutoff discarded a complete witness");
        witness(optimizing, new int[]{partial.placements.get(optimizing.get(0).getString("id")), partial.placements.get(optimizing.get(1).getString("id"))});
        Planner.ReservationResult difficult = reserve(difficult(), Planner.RESERVATION_ATTEMPT_LIMIT);
        check(difficult.status == Planner.ReservationStatus.SEARCH_EXHAUSTED && difficult.attempts == 20000 && difficult.placements == null, "Production limit not exercised");
    }
    // Independent brute force on a six-minute day; no planner ordering, pruning,
    // bounds, or attempt counter. Returns minimum study overlap, or no witness.
    static int oracle(List<JSONObject> events, int index, int busy, int study) {
        if (index == events.size()) return 0;
        JSONObject e = events.get(index);
        if (!Planner.floating(e)) return oracle(events, index + 1, busy, study);
        int best = Integer.MAX_VALUE, duration = e.getInt("floatingDurationMinutes");
        for (int start = e.getInt("startMinute"); start + duration <= e.getInt("endMinute"); start++) {
            int bits = ((1 << duration) - 1) << start;
            if ((busy & bits) != 0) continue;
            int tail = oracle(events, index + 1, busy | bits, study);
            if (tail != Integer.MAX_VALUE) best = Math.min(best, Integer.bitCount(bits & study) + tail);
        }
        return best;
    }
    static void oracleCases() throws Exception {
        Random random = new Random(20261105);
        for (int sample = 0; sample < 400; sample++) {
            List<JSONObject> events = new ArrayList<>();
            int busy = random.nextInt(64), studyBits = random.nextInt(64);
            boolean[] study = new boolean[1440];
            for (int m = 0; m < 6; m++) {
                study[m] = (studyBits & (1 << m)) != 0;
                if ((busy & (1 << m)) != 0) events.add(event(m + 1, m, m + 1, null));
            }
            int count = 1 + random.nextInt(3);
            for (int i = 0; i < count; i++) {
                int start = random.nextInt(6), end = start + 1 + random.nextInt(6 - start);
                events.add(event(10 + i, start, end, 1 + random.nextInt(end - start)));
            }
            int expected = oracle(events, 0, busy, studyBits);
            String before = new JSONArray(events).toString(); boolean[] studyBefore = study.clone();
            for (int limit : new int[]{0, 1, 2, 20000}) {
                Planner.ReservationResult result = Planner.reserveResult(events, study, limit);
                check(result.attempts <= limit, "Attempt budget exceeded");
                if (result.status == Planner.ReservationStatus.INFEASIBLE)
                    check(expected == Integer.MAX_VALUE, "False infeasibility proof at sample " + sample);
                if (result.status == Planner.ReservationStatus.FEASIBLE) {
                    check(expected != Integer.MAX_VALUE, "Impossible witness");
                    int occupied = busy, cost = 0, placed = 0;
                    for (JSONObject e : events) if (Planner.floating(e)) {
                        Integer start = result.placements.get(e.getString("id"));
                        check(start != null && start >= e.getInt("startMinute") && start + Planner.occupied(e) <= e.getInt("endMinute"), "Incomplete/out-of-window witness");
                        int bits = ((1 << Planner.occupied(e)) - 1) << start;
                        check((occupied & bits) == 0, "Overlapping witness");
                        occupied |= bits; cost += Integer.bitCount(bits & studyBits); placed++;
                    }
                    check(result.placements.size() == placed, "Unexpected placement");
                    if (limit == 20000) check(cost == expected, "Study preference changed");
                }
                if (limit == 20000) check((result.status == Planner.ReservationStatus.FEASIBLE) == (expected != Integer.MAX_VALUE)
                    && result.status != Planner.ReservationStatus.SEARCH_EXHAUSTED, "Small complete search disagrees with oracle");
            }
            check(before.equals(new JSONArray(events).toString()) && Arrays.equals(study, studyBefore), "Search mutated inputs");
        }
    }
    static List<Planner.EventConflict> review(JSONObject state, JSONObject draft) throws Exception {
        try { FixedEventEditing.save(state, draft, null, NOW, Collections.emptySet(), Collections.emptySet(), null); }
        catch (FixedEventEditing.ReviewRequired error) { return error.conflicts; }
        throw new AssertionError("Expected reviewed failure");
    }
    static void reviewedRecovery() throws Exception {
        for (boolean skipLocal : new boolean[]{false, true}) {
            List<JSONObject> events = difficult(); JSONObject draft = events.remove(5), state = PlannerTests.empty();
            state.put("fixedEvents", new JSONArray(events)); String before = state.toString();
            List<Planner.EventConflict> reviewed = review(state, draft);
            check(before.equals(state.toString()), "Opening review mutated data");
            EventConflictReview choices = new EventConflictReview(reviewed);
            check(!choices.complete() && choices.remaining() == 1, "Unknown result selected a skip automatically");
            Set<LocalDate> skipped = Collections.singleton(DAY), none = Collections.emptySet();
            FixedEventEditing.save(state, draft, null, NOW, skipLocal ? none : skipped, skipLocal ? skipped : none, reviewed);
            check(state.getJSONArray("fixedEvents").length() == 6, "Explicit skip removed a rule");
            for (JSONObject e : Planner.list(state.getJSONArray("fixedEvents")))
                check(Planner.occurs(e, DAY) == (e.getString("id").equals(draft.getString("id")) == skipLocal), "Skip affected wrong occurrence");
        }
        List<JSONObject> events = difficult(); JSONObject target = events.get(5);
        target.put("excludedDates", new JSONArray().put(NOW));
        JSONObject state = PlannerTests.empty().put("fixedEvents", new JSONArray(events)), displayed = CourseTools.copy(target);
        String before = state.toString(); List<Planner.EventConflict> reviewed;
        try { FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, null); throw new AssertionError("Unreviewed restore accepted"); }
        catch (FixedEventEditing.ReviewRequired error) {
            reviewed = error.conflicts;
            check(reviewed.stream().allMatch(c -> "searchLimit".equals(c.reason)), "Restore claimed proven capacity failure");
        }
        check(before.equals(state.toString()), "Failed restore changed data");
        // A previous capacity review is not consent to this different diagnosis.
        List<Planner.EventConflict> obsolete = new ArrayList<>();
        for (Planner.EventConflict c : reviewed) obsolete.add(new Planner.EventConflict(c.eventID,c.title,c.date,c.start,c.end,c.requestedStart,c.requestedEnd,c.floatingMinutes,"capacity"));
        try { FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, obsolete); throw new AssertionError("Stale consent accepted"); }
        catch (FixedEventEditing.ReviewRequired expected) { check(before.equals(state.toString()), "Stale review changed state"); }
        FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, reviewed);
        for (JSONObject e : Planner.list(state.getJSONArray("fixedEvents")))
            check(Planner.occurs(e, DAY) == e.getString("id").equals(target.getString("id")), "Reviewed recovery skipped wrong event");
    }
    static void warningsAndCancellation() throws Exception {
        JSONObject state = PlannerTests.empty().put("fixedEvents", new JSONArray(difficult()));
        String events = state.getJSONArray("fixedEvents").toString();
        List<String> warnings = Planner.replan(state, NOW);
        check(warnings.size() == 1 && warnings.get(0).contains("未证实容量不足"), "Replan conflated unknown and impossible");
        check(events.equals(state.getJSONArray("fixedEvents").toString()), "Replan changed event rules");
        JSONObject draft = state.getJSONArray("fixedEvents").getJSONObject(5); state.getJSONArray("fixedEvents").remove(5);
        String before = state.toString(), input = draft.toString(); int[] polls = {0};
        try {
            BackgroundCancellation.call(() -> ++polls[0] > 50, () -> { Planner.saveEvent(state, draft, NOW); return null; });
            throw new AssertionError("Long reservation ignored cancellation");
        } catch (java.util.concurrent.CancellationException expected) {
            check(before.equals(state.toString()) && input.equals(draft.toString()), "Cancelled search changed data");
        }
        check(reserve(Collections.singletonList(event(1,480,481,1)), 1).status == Planner.ReservationStatus.FEASIBLE, "Cancellation leaked to next operation");
        JSONObject impossible = PlannerTests.empty().put("fixedEvents", new JSONArray().put(event(1,480,482,2)).put(event(2,480,482,1)));
        warnings = Planner.replan(impossible, NOW);
        check(warnings.size() == 1 && warnings.get(0).contains("无法排入") && !warnings.get(0).contains("待确认"), "Proven failure lost its diagnosis");
    }
    public static void main(String[] args) throws Exception {
        exhaustedSave();
        budgetBoundaries(); oracleCases(); reviewedRecovery(); warningsAndCancellation();
        System.out.println("PASS floating reservation search " + checks + " checks");
    }
}
