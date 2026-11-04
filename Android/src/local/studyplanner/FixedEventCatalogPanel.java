package local.studyplanner;

import android.text.*;
import android.view.View;
import android.widget.*;
import org.json.*;
import java.time.LocalDate;

final class FixedEventCatalogPanel {
    static void render(MainActivity app, LinearLayout parent) {
        JSONObject snapshot = app.state; LocalDate today = Planner.day(Planner.now());
        EditText query = app.field(parent, "搜索事项名称、备注或起止日期（可组合关键词）", app.eventQuery, false);
        FixedEventCatalog.Scope[] scopes = FixedEventCatalog.Scope.values();
        Spinner scope = app.spinner(parent, "查看范围", new String[]{scopes[0].title, scopes[1].title, scopes[2].title}, app.eventScope.ordinal());
        parent.addView(app.text("历史按日期划分：单次事项看发生日，重复事项看规则结束日；今天仍列在当前范围。筛选不会更改日程。", 12, app.muted));
        parent.addView(app.text("复制为新事项：从日历选中日期或今天开始，不沿用旧跳过日期；保存前可调整并核对冲突。", 12, app.muted));
        TextView count = app.text("正在读取事项…", 12, app.muted); parent.addView(count);
        PlannerUi.Flow top = new PlannerUi.Flow(app), bottom = new PlannerUi.Flow(app); parent.addView(top);
        LinearLayout rows = app.col(); parent.addView(rows); parent.addView(bottom);
        FixedEventCatalog[] index = {null}; FixedEventCatalog.Page[] result = {null};
        Button[] previous = new Button[2], next = new Button[2];
        Runnable controls = () -> { for (int i = 0; i < 2; i++) {
            previous[i].setEnabled(result[0] != null && result[0].index > 0);
            next[i].setEnabled(result[0] != null && result[0].index + 1 < result[0].pageCount);
        }};
        LatestWork<FixedEventCatalog.Page> work = new LatestWork<>(app.worker, app::runOnUiThread, value -> {
            if (app.isDestroyed() || app.body != parent || app.state != snapshot) return;
            result[0] = value; app.eventPage = value.index; rows.removeAllViews();
            count.setText(value.count == 0 ? "当前范围没有匹配规则，可切换范围或清空关键词" :
                    value.count + " 条规则 · 第 " + (value.index + 1) + " / " + value.pageCount + " 页");
            app.run(() -> { for (String id : value.ids) app.eventCard(rows, index[0].event(id), true); });
            controls.run(); query.requestRectangleOnScreen(new android.graphics.Rect(0, 0, query.getWidth(), query.getHeight()), true);
        }, error -> { if (!app.isDestroyed() && app.body == parent) count.setText("读取事项失败：" + error.getMessage()); });
        Runnable[] pending = {null};
        Runnable search = () -> {
            if (pending[0] != null) app.handler.removeCallbacks(pending[0]); work.clear(); result[0] = null;
            rows.removeAllViews(); controls.run(); count.setText("正在读取事项…");
            String term = app.eventQuery; FixedEventCatalog.Scope range = app.eventScope; int page = app.eventPage;
            pending[0] = () -> work.submit(() -> {
                if (index[0] == null) index[0] = new FixedEventCatalog(snapshot, today);
                return index[0].find(term, range, page);
            }); app.handler.postDelayed(pending[0], 200);
        };
        for (int i = 0; i < 2; i++) {
            previous[i] = app.button("上一页", () -> { app.eventPage--; search.run(); });
            next[i] = app.button("下一页", () -> { app.eventPage++; search.run(); });
            PlannerUi.Flow navigation = i == 0 ? top : bottom; navigation.addView(previous[i]); navigation.addView(next[i]);
        }
        app.closeCatalog = () -> { work.close(); if (pending[0] != null) app.handler.removeCallbacks(pending[0]); };
        query.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            public void onTextChanged(CharSequence s, int start, int before, int count) { app.eventQuery = s.toString(); app.eventPage = 0; search.run(); }
            public void afterTextChanged(Editable value) {}
        });
        scope.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                if (app.eventScope != scopes[position]) { app.eventScope = scopes[position]; app.eventPage = 0; search.run(); }
            }
            public void onNothingSelected(AdapterView<?> parent) {}
        });
        top.addView(app.button("清除筛选", () -> {
            app.eventScope = FixedEventCatalog.Scope.CURRENT; app.eventPage = 0;
            scope.setSelection(0); query.setText(""); search.run();
        }));
        search.run();
    }
}
