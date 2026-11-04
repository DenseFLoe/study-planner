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
        check("从下周开始，每周一、三18:00-19:00复习", TODAY.plusDays(5), "[2,4]");
        check("下下周起，工作日18:00-19:00复习", TODAY.plusDays(12), "[2,3,4,5,6]");
        check("从本周开始，每周一、三18:00-19:00复习", TODAY.minusDays(2), "[2,4]");
        check("从这星期起，每周五18:00-19:00复习", TODAY.minusDays(2), "[6]");
        check("从下周开始，每周三18:00-19:00复习，截止2026年12月1日", TODAY.plusDays(5), "[4]");
        check("从下周一开始，每周三18:00-19:00复习", TODAY.plusDays(5), "[4]");
        check("从2027年1月1日周五开始，每周一、三18:00-19:00复习", LocalDate.of(2027,1,1), "[2,4]");
        for(String text:new String[]{"从下周开始，明天起每周一、三18:00-19:00复习", "从下周开始，从2026年11月6日起每周一、三18:00-19:00复习", "明天开始，后天起每周一、三18:00-19:00复习"}){
            FixedEventTextParser.Result result=FixedEventTextParser.parse(text,Planner.at(TODAY,600));
            if(!result.drafts.isEmpty()||result.messages.isEmpty())throw new AssertionError("Conflicting starts accepted: "+text);
            checks++;
        }
        for(LocalDate reference:new LocalDate[]{LocalDate.of(2026,11,8),LocalDate.of(2026,12,31)}){
            FixedEventTextParser.Result result=FixedEventTextParser.parse("下周起每周三18:00-19:00复习",Planner.at(reference,600));
            LocalDate monday=reference.plusDays(8-reference.getDayOfWeek().getValue());
            if(result.drafts.size()!=1||!Planner.day(result.drafts.get(0).event.getDouble("startDate")).equals(monday))
                throw new AssertionError("Next week did not cross the Monday/year boundary");
            checks++;
        }
        JSONObject weekly = event("每周一、三、五18:00-19:00复习");
        if (!Planner.occurs(weekly, TODAY) || !Planner.occurs(weekly, TODAY.plusDays(2)) || Planner.occurs(weekly, TODAY.plusDays(1)))
            throw new AssertionError("Current-week occurrences were lost or added");
        checks += 3;
        for(String text:new String[]{"从下周开始，每周一、三18:00-19:00复习", "从周五开始，每周一、三18:00-19:00复习", "从2026年11月6日到2026年12月1日，每周一、三18:00-19:00复习", "每周一、三、五18:00-19:00复习", "每周一、周三、周五18:00-19:00复习", "截止2026年12月1日，每周一、三18:00-19:00复习", "持续一个半小时，明天18:00复习"}){
            JSONObject value=event(text);
            if(!value.getString("title").equals("复习")||!value.getString("notes").equals(text))throw new AssertionError("Title or original notice damaged: "+text+" => "+value.getString("title"));
            checks+=2;
        }
        for(String text:new String[]{"明天下午三点到五点从零到一复习", "明天下午3:00-5:00从零到一复习"}){
            if(!event(text).getString("title").equals("从零到一复习"))throw new AssertionError("Title connector removed");checks++;
        }
        if(!event("明天18:00，主题：从零开始").getString("title").equals("从零开始"))throw new AssertionError("Explicit title replaced");checks++;
        if(!event("从下周开始，每周一、三18:00-19:00").getString("title").equals("待命名事项"))throw new AssertionError("Date fragment became a title");checks++;
        System.out.println("PASS " + checks + " recurring recognition checks");
    }
}
