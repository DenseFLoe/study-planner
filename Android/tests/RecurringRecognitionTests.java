package local.studyplanner;

import org.json.JSONObject;
import java.time.LocalDate;

/** A recurrence's weekday list is not an instruction to postpone its first week. */
public final class RecurringRecognitionTests {
    private static int checks;
    private static final LocalDate TODAY = LocalDate.of(2026, 11, 4); // Wednesday
    private static JSONObject event(String text) {
        FixedEventTextParser.Result result = FixedEventTextParser.parse(text, Planner.at(TODAY, 600));
        if (result.drafts.size() != 1) throw new AssertionError(text + ": " + result.messages);
        return result.drafts.get(0).event;
    }
    private static void check(String text, LocalDate start, String weekdays) throws Exception {
        JSONObject value = event(text);
        if (!Planner.day(value.getDouble("startDate")).equals(start)) throw new AssertionError("Wrong recurrence start: " + text);
        if (!value.getJSONArray("weekdays").toString().equals(weekdays)) throw new AssertionError("Start marker leaked into weekdays: " + text);
        Planner.validateEventWindow(value); checks += 3;
    }
    public static void main(String[] args) throws Exception {
        for (String text : new String[]{"每周一、三、五18:00-19:00复习", "每周一、周三、周五18:00-19:00复习", "每星期一、星期三、星期五18:00-19:00复习"})
            check(text, TODAY, "[2,4,6]");
        check("每周一至五18:00-19:00复习", TODAY, "[2,3,4,5,6]");
        check("每周五到周一18:00-19:00复习", TODAY, "[1,2,6,7]");
        check("每周一、三18:00-19:00复习，截止2026年11月6日", TODAY, "[2,4]");
        check("从周五开始，每周一、三18:00-19:00复习", TODAY.plusDays(2), "[2,4]");
        check("每周一、三18:00-19:00复习，从周五开始", TODAY.plusDays(2), "[2,4]");
        check("从下周五起，每周一、三18:00-19:00复习", TODAY.plusDays(9), "[2,4]");
        check("明天起，每周一、三18:00-19:00复习", TODAY.plusDays(1), "[2,4]");
        check("从2026年11月6日开始，每周一、三18:00-19:00复习", TODAY.plusDays(2), "[2,4]");
        check("周五18:00-19:00复习", TODAY.plusDays(2), "[]");
        JSONObject weekly = event("每周一、三、五18:00-19:00复习");
        if (!Planner.occurs(weekly, TODAY) || !Planner.occurs(weekly, TODAY.plusDays(2)) || Planner.occurs(weekly, TODAY.plusDays(1)))
            throw new AssertionError("Current-week occurrences were lost or added");
        checks += 3;
        System.out.println("PASS " + checks + " recurring recognition checks");
    }
}
