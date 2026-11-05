package local.studyplanner;

import android.app.AlertDialog;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import org.json.JSONObject;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;

/** Review and retry a single day's restoration without opening the whole rule editor. */
final class FixedOccurrenceRecoveryPanel {
    private FixedOccurrenceRecoveryPanel() {}

    static void restore(MainActivity host, JSONObject event, LocalDate date) {
        save(host, event, date, null, null);
    }

    private static void save(MainActivity host, JSONObject event, LocalDate date,
                             List<Planner.EventConflict> reviewed, AlertDialog dialog) {
        if (host.busy) return;
        host.run(() -> {
            JSONObject displayed = CourseTools.copy(event);
            List<Planner.EventConflict> consent = reviewed == null ? null : new ArrayList<>(reviewed);
            setSaving(dialog, true);
            host.mutate(state -> FixedEventEditing.restoreOccurrence(state, displayed, date, Planner.now(), consent), true,
                () -> { if (dialog != null) dialog.dismiss(); }, error -> {
                    setSaving(dialog, false);
                    if (error instanceof FixedEventEditing.ReviewRequired) {
                        if (dialog != null) dialog.dismiss();
                        show(host, date, (FixedEventEditing.ReviewRequired) error, reviewed != null);
                    } else host.alert("本日安排未恢复", error.getMessage());
                });
        });
    }

    private static void setSaving(AlertDialog dialog, boolean saving) {
        if (dialog == null) return;
        dialog.setCancelable(!saving);
        dialog.setCanceledOnTouchOutside(!saving);
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(!saving);
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setEnabled(!saving);
    }

    private static void show(MainActivity host, LocalDate date, FixedEventEditing.ReviewRequired issue, boolean refreshed) {
        JSONObject event = issue.event;
        LinearLayout form = host.col();
        form.setPadding(host.dp(20), host.dp(10), host.dp(20), host.dp(10));
        form.addView(host.text(date + " · 待恢复：" + event.optString("title"), 17, host.ink));
        form.addView(host.text(Planner.time(event.optInt("startMinute")) + "–" + Planner.time(event.optInt("endMinute"))
            + (Planner.floating(event) ? " · 浮动占用 " + Planner.occupied(event) + " 分钟" : ""), 14, host.muted));
        form.addView(host.text(refreshed
            ? "当天事项已有变化，列表已更新。本次未恢复或跳过任何事项，请重新核对后再确认。"
            : "本日尚未恢复。核对后可仅临时移除下列事项在这一天的安排，再恢复此事项并重新排程。其他日期保留；临时移除的事项仍可在当天日程中恢复。", 14, host.muted));
        for (Planner.EventConflict conflict : issue.conflicts) {
            LinearLayout item = host.card(form);
            item.addView(host.text(conflict.title, 16, host.ink));
            item.addView(host.text(conflict.timeDescription() + "\n" + conflict.explanation(), 13, host.muted));
        }
        boolean canRestore = FixedEventEditing.canRestoreSkipping(date, issue.conflicts);
        if (!canRestore) form.addView(host.text("这些占用不能自动跳过，请保持临时移除，核对当天安排后再恢复。", 14, host.muted));
        ScrollView scroll = new ScrollView(host); scroll.addView(form);
        AlertDialog dialog = new AlertDialog.Builder(host).setTitle("恢复本日安排前，请核对占用")
            .setView(scroll).setNegativeButton("保持临时移除", null)
            .setPositiveButton("恢复并跳过上列事项", null).create();
        dialog.setOnShowListener(unused -> {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(canRestore);
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
                if (canRestore) save(host, event, date, issue.conflicts, dialog);
            });
        });
        dialog.show();
    }
}
