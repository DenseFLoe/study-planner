package local.studyplanner;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.LinearLayout;
import android.widget.ListView;
import java.util.ArrayList;
import java.util.List;

/** One scrolling owner; long collections build only the rows in the viewport. */
final class PlannerListView extends ListView {
    interface Row { void bind(LinearLayout container) throws Exception; }
    private final List<Row> rows = new ArrayList<>();
    private final java.util.function.Consumer<Exception> showError;
    private boolean errorReported;
    private final BaseAdapter adapter = new BaseAdapter() {
        public int getCount() { return rows.size(); }
        public Object getItem(int position) { return rows.get(position); }
        public long getItemId(int position) { return position; }
        public boolean areAllItemsEnabled() { return false; }
        public boolean isEnabled(int position) { return false; }
        public View getView(int position, View recycled, ViewGroup parent) {
            LinearLayout container = recycled instanceof LinearLayout
                ? (LinearLayout) recycled : new LinearLayout(getContext());
            container.setOrientation(LinearLayout.VERTICAL);
            container.removeAllViews();
            try { rows.get(position).bind(container); }
            catch (Exception error) {
                if (!errorReported) {
                    errorReported = true;
                    post(() -> showError.accept(error));
                }
            }
            return container;
        }
    };

    PlannerListView(Context context, java.util.function.Consumer<Exception> showError) {
        super(context);
        this.showError = showError;
        setDivider(null);
        setSelector(android.R.color.transparent);
        setItemsCanFocus(true);
        setClipToPadding(false);
        setAdapter(adapter);
    }

    void addRow(Row row) { rows.add(row); }

    /** Keep small forms alive so asynchronous labels and editor values remain valid. */
    void takeContent(LinearLayout content) {
        if (content.getChildCount() == 0) return;
        List<View> views = new ArrayList<>();
        for (int i = 0; i < content.getChildCount(); i++) views.add(content.getChildAt(i));
        content.removeAllViews();
        for (View view : views) addRow(container -> {
            if (view.getParent() instanceof ViewGroup) ((ViewGroup) view.getParent()).removeView(view);
            container.addView(view);
        });
    }

    void finishContent(LinearLayout content) {
        takeContent(content);
        adapter.notifyDataSetChanged();
    }
}
