package local.studyplanner;

import org.json.*;

/** Text-entry regressions: names and IDs must survive more forgiving delimiters. */
public final class ManualLessonTextTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject lesson(String id, String name, int minutes) throws Exception {
        return new JSONObject().put("id", id).put("name", name).put("durationMinutes", minutes);
    }
    static void rejects(String text, int line, String reason) throws Exception {
        JSONObject course = new JSONObject();
        try { Planner.parseManualLessons(text, course); throw new AssertionError("accepted invalid lesson text"); }
        catch (IllegalArgumentException error) {
            check(error.getMessage().startsWith("第 " + line + " 行："), "error identifies the original line: " + error.getMessage());
            check(error.getMessage().contains(reason), "error explains the correction: " + error.getMessage());
            check(course.length() == 0, "rejected input does not mutate the course");
        }
    }
    public static void main(String[] args) throws Exception {
        JSONObject course = new JSONObject().put("manualLessons", new JSONArray()
                .put(lesson("first", "第一章：极限", 60)).put(lesson("second", "English: limits", 30)));
        String before = course.toString();
        JSONArray rows = Planner.parseManualLessons("\n English: limits：３０ \r\n\r第一章：极限:60\n", course);
        check(rows.length() == 2, "blank lines skipped across CRLF, CR and LF");
        check(rows.getJSONObject(0).getString("id").equals("second"), "full-width delimiter retains reordered lesson ID");
        check(rows.getJSONObject(1).getString("id").equals("first"), "ASCII delimiter retains reordered lesson ID");
        check(rows.getJSONObject(0).getString("name").equals("English: limits"), "ASCII punctuation inside title is unchanged");
        check(rows.getJSONObject(1).getString("name").equals("第一章：极限"), "Chinese punctuation inside title is unchanged");
        check(rows.getJSONObject(0).getInt("durationMinutes") == 30, "full-width digits remain accepted");
        check(course.toString().equals(before), "parsing does not mutate source course");
        rows = Planner.parseManualLessons("最短：1\n最长:1440", new JSONObject());
        check(rows.getJSONObject(0).getInt("durationMinutes") == 1 && rows.getJSONObject(1).getInt("durationMinutes") == 1440,
                "inclusive duration bounds accepted");
        rejects("第一节:60\r\n\r\n未填写时长", 3, "名称：分钟");
        rejects("第一节:60\r第二节：30.5", 2, "整数分钟");
        rejects("第一节:60\n第二节:abc", 2, "整数分钟");
        rejects("第一节:60\n第二节:", 2, "整数分钟");
        rejects("名称：999999999999999", 1, "整数分钟");
        rejects("名称：0", 1, "整数分钟");
        rejects("名称：-1", 1, "整数分钟");
        rejects("名称：1441", 1, "整数分钟");
        rejects(":30", 1, "名称不能为空");
        rejects(" ：30", 1, "名称不能为空");
        try { Planner.parseManualLessons("\r\n \r\n", new JSONObject()); throw new AssertionError("accepted empty lesson list"); }
        catch (IllegalArgumentException error) { check(error.getMessage().contains("至少录入一节"), "empty input remains explicit"); }
        System.out.println("Manual lesson text: " + checks + " checks passed");
    }
}
