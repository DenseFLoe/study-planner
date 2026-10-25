package local.studyplanner;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/** Two equal columns of settings tiles; every visible child is measured and laid out as an exact square. */
final class SettingsTileGrid extends ViewGroup {
    private static final int GAP_DP=12;
    private final int gap;
    private int side;

    SettingsTileGrid(Context context){
        super(context);
        gap=Math.round(GAP_DP*getResources().getDisplayMetrics().density);
    }

    @Override protected LayoutParams generateDefaultLayoutParams(){
        return new LayoutParams(LayoutParams.WRAP_CONTENT,LayoutParams.WRAP_CONTENT);
    }

    @Override protected void onMeasure(int widthSpec,int heightSpec){
        int widthMode=MeasureSpec.getMode(widthSpec);
        int widthSize=MeasureSpec.getSize(widthSpec);
        // Reserve the inter-column gap once, then split the rest evenly between two columns.
        int available=widthSize-getPaddingLeft()-getPaddingRight()-gap;
        if(widthMode==MeasureSpec.UNSPECIFIED){
            // Without a parent width, fall back to the largest natural child size as the square side.
            side=0;
            for(int i=0;i<getChildCount();i++){
                View child=getChildAt(i);
                if(child.getVisibility()==GONE)continue;
                child.measure(MeasureSpec.makeMeasureSpec(0,MeasureSpec.UNSPECIFIED),MeasureSpec.makeMeasureSpec(0,MeasureSpec.UNSPECIFIED));
                side=Math.max(side,Math.max(child.getMeasuredWidth(),child.getMeasuredHeight()));
            }
        }else side=Math.max(0,available/2);
        int exact=MeasureSpec.makeMeasureSpec(side,MeasureSpec.EXACTLY);
        int visible=0;
        // Every visible tile gets the same EXACTLY square, so a trailing odd tile is never stretched.
        for(int i=0;i<getChildCount();i++){
            View child=getChildAt(i);
            if(child.getVisibility()==GONE)continue;
            child.measure(exact,exact);
            visible++;
        }
        int rows=(visible+1)/2;
        int columns=Math.min(2,visible);
        int contentWidth=columns*side+(columns>1?gap:0);
        int contentHeight=rows>0?rows*side+(rows-1)*gap:0;
        setMeasuredDimension(
                resolveSize(getPaddingLeft()+getPaddingRight()+contentWidth,widthSpec),
                resolveSize(getPaddingTop()+getPaddingBottom()+contentHeight,heightSpec));
    }

    @Override protected void onLayout(boolean changed,int l,int t,int r,int b){
        int left=getPaddingLeft();
        int top=getPaddingTop();
        int step=side+gap;
        int index=0;
        for(int i=0;i<getChildCount();i++){
            View child=getChildAt(i);
            if(child.getVisibility()==GONE)continue;
            int x=left+(index%2)*step;
            int y=top+(index/2)*step;
            child.layout(x,y,x+side,y+side);
            index++;
        }
    }
}
