package local.studyplanner;

import org.json.JSONObject;

/** Necessary rest inside hard study windows; never a deficit in learning progress. */
final class ScheduleRestConflict {
    static JSONObject diagnose(long studyMinutes, long blockCount, long availableMinutes, long windowCount) throws Exception {
        // Every disjoint positive window gets one break-free block, even when
        // too short to hold it. Every external gap gets a full rest exemption,
        // even when shorter than 15 minutes. Floating occupancy is ignored by
        // the caller. These optimistic bounds can miss conflicts, not invent one.
        long rest = Math.max(0, blockCount - windowCount) * Planner.BREAK_MINUTES;
        if (studyMinutes <= 0 || studyMinutes > availableMinutes || rest <= availableMinutes - studyMinutes) return null;
        return new JSONObject().put("requiredStudyMinutes", studyMinutes)
            .put("minimumRestMinutes", rest).put("availableMinutes", availableMinutes);
    }

    static String explanation(JSONObject proof) {
        return "剩余学习需要 " + proof.optLong("requiredStudyMinutes") + " 分钟；按现有空档，学习之间至少还需预留 "
            + proof.optLong("minimumRestMinutes") + " 分钟休息，但最多只有 " + proof.optLong("availableMinutes")
            + " 分钟可用。即使暂不扣除浮动事项，也无法同时容纳学习和休息。";
    }

    static String recovery() {
        return "可增加截止日前的可学习时段，或调整固定事项，把完整学习块移到有足够间隔的其他空档。调整后重新排程核对；未排入的学习量与截止日期仍保留。";
    }
}
