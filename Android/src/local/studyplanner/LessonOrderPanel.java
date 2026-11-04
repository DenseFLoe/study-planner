package local.studyplanner;

import android.text.*;
import android.widget.*;
import java.util.*;

/** Bounded checkbox rendering; selection belongs to the draft and survives filtering/paging. */
final class LessonOrderPanel {
    final LinearLayout view;
    private final MainActivity app;
    private final List<String> order;
    private final Set<String> selected, movable, deleted;
    private final LessonOrderList index;
    private final EditText query;
    private final TextView summary;
    private final LinearLayout rows;
    private final ScrollView scroll;
    private final Button previous, next, clear;
    private LessonOrderList.Page result;
    private int page;

    LessonOrderPanel(MainActivity app, List<String> order, Map<String, String> names,
                     Set<String> selected, Set<String> movable, Set<String> deleted) {
        this.app = app; this.order = order; this.selected = selected; this.movable = movable; this.deleted = deleted;
        index = new LessonOrderList(names); view = app.col();
        query = app.field(view, "搜索课节名称（可组合关键词）", "", false);
        summary = app.text("", 12, app.muted); view.addView(summary);
        rows = app.col(); scroll = new ScrollView(app); scroll.addView(rows);
        view.addView(scroll, new LinearLayout.LayoutParams(-1, app.dp(240)));
        PlannerUi.Flow navigation = new PlannerUi.Flow(app); view.addView(navigation);
        previous = app.button("上一页", () -> { page--; refresh(); });
        next = app.button("下一页", () -> { page++; refresh(); });
        clear = app.button("清空全部选择", () -> { selected.clear(); refresh(); });
        navigation.addView(previous); navigation.addView(next); navigation.addView(clear);
        query.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            public void onTextChanged(CharSequence s, int start, int before, int count) { page = 0; refresh(); }
            public void afterTextChanged(Editable value) {}
        });
        refresh();
    }
    void refresh() {
        result = index.find(order, query.getText().toString(), page); page = result.index;
        rows.removeAllViews();
        for (LessonOrderList.Row row : result.rows) {
            CheckBox box = new CheckBox(app);
            box.setText(row.position + ". " + row.name + (movable.contains(row.id) ? "" : "（已完成）"));
            box.setChecked(selected.contains(row.id));
            box.setOnCheckedChangeListener((button, checked) -> {
                if (checked) selected.add(row.id); else selected.remove(row.id);
                summarize();
            });
            rows.addView(box);
        }
        previous.setEnabled(page > 0); next.setEnabled(page + 1 < result.pageCount);
        summarize(); scroll.scrollTo(0, 0);
    }
    private void summarize() {
        summary.setText(result.count + " / " + order.size() + " 节" + (result.count == 0 ? " · 无匹配结果" :
                " · 第 " + (page + 1) + " / " + result.pageCount + " 页") + "\n已选 " + selected.size() +
                " 节（含其他页和筛选外）· 待删除 " + deleted.size() + " 节\n序号对应完整列表；移动或删除作用于全部已选课节。");
        clear.setEnabled(!selected.isEmpty());
    }
}
