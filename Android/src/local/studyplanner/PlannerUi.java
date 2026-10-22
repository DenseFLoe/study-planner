package local.studyplanner;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;

/** Small native UI primitives shared by the calendar and bottom navigation. */
final class PlannerUi {
    static final class Icon extends View {
        private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int kind;
        Icon(Context context,int kind,int color){
            super(context);this.kind=kind;paint.setColor(color);paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(1.7f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        }
        @Override protected void onDraw(Canvas c){
            super.onDraw(c);c.save();c.scale(getWidth()/24f,getHeight()/24f);
            if(kind==0){
                c.drawRoundRect(3,5,21,22,3,3,paint);c.drawLine(3,10,21,10,paint);
                c.drawLine(8,2,8,7,paint);c.drawLine(16,2,16,7,paint);
                c.drawLine(7,14,10,14,paint);c.drawLine(14,14,17,14,paint);c.drawLine(7,18,10,18,paint);
            }else if(kind==1){
                c.drawRoundRect(4,3,20,22,2,2,paint);c.drawLine(8,3,8,22,paint);
                c.drawLine(11,8,17,8,paint);c.drawLine(11,12,17,12,paint);
            }else if(kind==2){
                c.drawRoundRect(3,3,21,21,3,3,paint);c.drawLine(3,9,21,9,paint);
                c.drawLine(9,9,9,21,paint);c.drawLine(15,9,15,21,paint);c.drawLine(3,15,21,15,paint);
            }else if(kind==3){
                c.drawCircle(12,12,7,paint);c.drawCircle(12,12,2.5f,paint);
                for(int i=0;i<8;i++){c.save();c.rotate(i*45,12,12);c.drawLine(12,2,12,5,paint);c.restore();}
            }else if(kind==5){
                c.drawRoundRect(3,15,7,21,1.2f,1.2f,paint);
                c.drawRoundRect(10,11,14,21,1.2f,1.2f,paint);
                c.drawRoundRect(17,7,21,21,1.2f,1.2f,paint);
                c.drawLine(5,12,11,8,paint);c.drawLine(11,8,18,4,paint);
            }else{
                // kind 4: search magnifier; unknown kinds fall back to it.
                c.drawCircle(10,10,6.5f,paint);c.drawLine(15,15,21,21,paint);
            }
            c.restore();
        }
    }

    /** Shared compact pill button for native screens. */
    static Button compactButton(Context context,String label,Runnable action){
        Button button=new Button(context);
        button.setText(label);
        styleButton(button);
        button.setLayoutParams(new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT,LinearLayout.LayoutParams.WRAP_CONTENT));
        button.setOnClickListener(v->action.run());
        return button;
    }

    /** Apply the one shared native button look; safe to call again after changing state text. */
    static void styleButton(Button button){
        float density=button.getResources().getDisplayMetrics().density;
        button.setTextSize(14);
        button.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));
        button.setAllCaps(false);
        button.setSingleLine(true);
        button.setMaxLines(1);
        button.setEllipsize(TextUtils.TruncateAt.END);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        int minHeight=Math.round(40*density);
        button.setMinHeight(minHeight);
        button.setMinimumHeight(minHeight);
        int horizontal=Math.round(12*density),vertical=Math.round(6*density);
        button.setPadding(horizontal,vertical,horizontal,vertical);
        button.setGravity(Gravity.CENTER);
        button.setStateListAnimator(null);
        button.setBackgroundTintList(null);
        GradientDrawable shape=new GradientDrawable();
        shape.setShape(GradientDrawable.RECTANGLE);
        shape.setCornerRadius(999*density);
        shape.setColor(0xffe8f5ed);
        GradientDrawable mask=new GradientDrawable();
        mask.setShape(GradientDrawable.RECTANGLE);
        mask.setCornerRadius(999*density);
        mask.setColor(0xffffffff);
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0xffc5efd7),shape,mask));
        button.setTextColor(new ColorStateList(new int[][]{new int[]{-android.R.attr.state_enabled},new int[]{}},new int[]{0xff888888,0xff191919}));
    }

    /** Wrap-content actions flow onto another line when text or screen width requires it. */
    static final class Flow extends ViewGroup {
        private final int gap;
        Flow(Context context){super(context);gap=Math.round(6*getResources().getDisplayMetrics().density);}
        @Override protected LayoutParams generateDefaultLayoutParams(){return new LayoutParams(LayoutParams.WRAP_CONTENT,LayoutParams.WRAP_CONTENT);}
        @Override protected void onMeasure(int widthSpec,int heightSpec){
            int limit=MeasureSpec.getMode(widthSpec)==MeasureSpec.UNSPECIFIED?Integer.MAX_VALUE:MeasureSpec.getSize(widthSpec);
            int available=Math.max(0,limit-getPaddingLeft()-getPaddingRight());
            int x=0,y=0,lineHeight=0,maxWidth=0;
            for(int i=0;i<getChildCount();i++){
                View child=getChildAt(i);if(child.getVisibility()==GONE)continue;
                measureChild(child,widthSpec,heightSpec);int w=child.getMeasuredWidth(),h=child.getMeasuredHeight();
                if(x>0&&x+w>available){maxWidth=Math.max(maxWidth,x-gap);y+=lineHeight+gap;x=0;lineHeight=0;}
                x+=w+gap;lineHeight=Math.max(lineHeight,h);
            }
            maxWidth=Math.max(maxWidth,Math.max(0,x-gap));
            setMeasuredDimension(resolveSize(maxWidth+getPaddingLeft()+getPaddingRight(),widthSpec),resolveSize(y+lineHeight+getPaddingTop()+getPaddingBottom(),heightSpec));
        }
        @Override protected void onLayout(boolean changed,int l,int t,int r,int b){
            int left=getPaddingLeft(),x=left,y=getPaddingTop(),lineHeight=0,right=r-l-getPaddingRight();
            for(int i=0;i<getChildCount();i++){
                View child=getChildAt(i);if(child.getVisibility()==GONE)continue;
                int w=child.getMeasuredWidth(),h=child.getMeasuredHeight();
                if(x>left&&x+w>right){x=left;y+=lineHeight+gap;lineHeight=0;}
                child.layout(x,y,x+w,y+h);x+=w+gap;lineHeight=Math.max(lineHeight,h);
            }
        }
    }
}
