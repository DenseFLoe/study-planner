package local.studyplanner;

import android.app.Instrumentation;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.concurrent.atomic.AtomicInteger;

/** Synthetic rows only: never opens or changes the user's planner database. */
public final class ScrollInstrumentation extends Instrumentation {
    public void onCreate(Bundle args) { super.onCreate(args); start(); }
    private void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    public void onStart() {
        Bundle result = new Bundle();
        try {
            runOnMainSync(this::verifyRows);
            result.putString("stream", "PASS: lazy viewport construction, recycling, last row, actions and retained form values\n");
            finish(-1, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL: " + error + "\n");
            finish(1, result);
        }
    }
    private void verifyRows() {
        AtomicInteger built = new AtomicInteger(), clicked = new AtomicInteger(-1);
        PlannerListView list = new PlannerListView(getTargetContext(), error -> { throw new AssertionError(error); });
        LinearLayout content = new LinearLayout(getTargetContext());
        for (int i = 0; i < 1000; i++) {
            final int index = i;
            list.addRow(container -> {
                built.incrementAndGet();
                Button action = new Button(getTargetContext());
                action.setText("测试课程 " + index);
                action.setMinHeight(120);
                action.setOnClickListener(view -> clicked.set(index));
                container.addView(action);
            });
        }
        TextView retained = new TextView(getTargetContext());
        retained.setText("保留编辑值");
        content.addView(retained);
        list.finishContent(content);
        check(built.get() == 0, "offscreen rows were eagerly created");
        int width = View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY);
        int height = View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY);
        list.measure(width, height); list.layout(0, 0, 600, 800);
        check(built.get() > 0 && built.get() < 40, "viewport built the entire collection");
        LinearLayout recycled = (LinearLayout) list.getAdapter().getView(0, null, list);
        list.getAdapter().getView(999, recycled, list);
        check(recycled.getChildCount() == 1, "recycling accumulated old controls");
        recycled.getChildAt(0).performClick();
        check(clicked.get() == 999, "recycled button retained the wrong row action");
        for (int i = 0; i < 12; i++) {
            list.setSelection(i % 2 == 0 ? 999 : 0);
            list.measure(width, height); list.layout(0, 0, 600, 800);
        }
        check(built.get() < 400, "jump scrolling built offscreen rows");
        list.getAdapter().getView(1000, recycled, list);
        retained.setText("异步更新仍可见");
        list.getAdapter().getView(0, recycled, list);
        list.getAdapter().getView(1000, recycled, list);
        check(retained.getParent() == recycled && retained.getText().toString().equals("异步更新仍可见"), "form state lost during recycling");
    }
}
