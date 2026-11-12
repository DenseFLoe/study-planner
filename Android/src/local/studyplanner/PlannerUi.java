package local.studyplanner;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.TextView;

/** Material-inspired tokens and native components; no dependency on a web renderer. */
final class PlannerUi {
    static final int BACKGROUND=0xfff5f7f8, SURFACE=0xffffffff, INK=0xff20312e,
        MUTED=0xff60716b, PRIMARY=0xff286b57, TONAL=0xffe5efe9,
        OUTLINE=0xffdce4df, RIPPLE=0x24286b57;
    static int dp(Context context,int value){return Math.round(value*context.getResources().getDisplayMetrics().density);}
    static GradientDrawable shape(Context context,int color,int radius){
        GradientDrawable shape=new GradientDrawable();shape.setColor(color);shape.setCornerRadius(dp(context,radius));return shape;
    }
    static RippleDrawable ripple(Context context,int color,int radius){
        return new RippleDrawable(ColorStateList.valueOf(RIPPLE),shape(context,color,radius),shape(context,SURFACE,radius));
    }
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
            }else if(kind==6||kind==7){
                float from=kind==6?14:10,to=kind==6?9:15;
                c.drawLine(from,6,to,12,paint);c.drawLine(to,12,from,18,paint);
            }else if(kind==8){
                paint.setStyle(Paint.Style.FILL);for(int y=5;y<=19;y+=7)c.drawCircle(12,y,1.6f,paint);
            }else if(kind==9){
                c.drawRoundRect(3,3,21,17,3,3,paint);c.drawLine(7,17,7,22,paint);c.drawLine(7,22,12,17,paint);
                c.drawLine(7,8,17,8,paint);c.drawLine(7,12,13,12,paint);
            }else if(kind==10){
                c.drawLine(3,19,8,5,paint);c.drawLine(8,5,13,19,paint);c.drawLine(5,14,11,14,paint);
                c.drawLine(16,10,22,10,paint);c.drawLine(19,10,19,19,paint);
            }else if(kind==11){
                android.graphics.Path cloud=new android.graphics.Path();cloud.moveTo(7,19);cloud.cubicTo(-1,19,0,9,7,9);
                cloud.cubicTo(7,1,19,1,19,10);cloud.cubicTo(25,10,25,19,18,19);cloud.close();c.drawPath(cloud,paint);
            }else if(kind==12){
                c.drawRoundRect(3,4,21,9,1.5f,1.5f,paint);c.drawRoundRect(5,9,19,21,1,1,paint);c.drawLine(9,13,15,13,paint);
            }else if(kind==13){
                c.drawCircle(12,12,9,paint);c.drawLine(12,6,12,12,paint);c.drawLine(12,12,16,15,paint);
            }else if(kind==14){
                c.drawArc(4,4,20,20,205,145,false,paint);c.drawLine(20,6,20,11,paint);c.drawLine(20,11,15,11,paint);
                c.drawArc(4,4,20,20,25,145,false,paint);c.drawLine(4,18,4,13,paint);c.drawLine(4,13,9,13,paint);
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
        button.setSingleLine(false);
        button.setMaxLines(Integer.MAX_VALUE);
        button.setEllipsize(null);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        int minHeight=Math.round(48*density);
        button.setMinHeight(minHeight);
        button.setMinimumHeight(minHeight);
        int horizontal=Math.round(16*density),vertical=Math.round(10*density);
        button.setPadding(horizontal,vertical,horizontal,vertical);
        button.setGravity(Gravity.CENTER);
        button.setStateListAnimator(null);
        button.setBackgroundTintList(null);
        buttonTone(button,false);
    }
    static void buttonTone(Button button,boolean primary){
        Context context=button.getContext();StateListDrawable surfaces=new StateListDrawable();
        surfaces.addState(new int[]{-android.R.attr.state_enabled},shape(context,0xffebefed,16));
        surfaces.addState(new int[]{},shape(context,primary?PRIMARY:TONAL,16));
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(primary?0x33ffffff:RIPPLE),surfaces,shape(context,SURFACE,16)));
        button.setTextColor(new ColorStateList(new int[][]{new int[]{-android.R.attr.state_enabled},new int[]{}},new int[]{0xff7b8781,primary?SURFACE:PRIMARY}));
    }
    static void quietButton(Button button){
        button.setBackground(ripple(button.getContext(),android.graphics.Color.TRANSPARENT,16));
        button.setTextColor(PRIMARY);
    }
    static void styleField(EditText field){
        Context context=field.getContext();field.setTextSize(16);field.setTextColor(INK);field.setHintTextColor(MUTED);
        field.setMinimumHeight(dp(context,52));field.setPadding(dp(context,14),dp(context,12),dp(context,14),dp(context,12));
        StateListDrawable background=new StateListDrawable();
        GradientDrawable focused=shape(context,SURFACE,12);focused.setStroke(dp(context,2),PRIMARY);
        GradientDrawable normal=shape(context,SURFACE,12);normal.setStroke(dp(context,1),OUTLINE);
        background.addState(new int[]{android.R.attr.state_focused},focused);background.addState(new int[]{},normal);
        field.setBackgroundTintList(null);field.setBackground(background);
    }
    static View iconButton(Context context,int kind,String description,Runnable action){
        FrameLayout target=new FrameLayout(context);target.setMinimumWidth(dp(context,48));target.setMinimumHeight(dp(context,48));
        target.addView(new Icon(context,kind,PRIMARY),new FrameLayout.LayoutParams(dp(context,22),dp(context,22),Gravity.CENTER));
        target.setBackground(ripple(context,android.graphics.Color.TRANSPARENT,24));target.setFocusable(true);
        target.setContentDescription(description);target.setOnClickListener(v->action.run());
        target.setAccessibilityDelegate(new View.AccessibilityDelegate(){
            @Override public void onInitializeAccessibilityNodeInfo(View host,android.view.accessibility.AccessibilityNodeInfo info){
                super.onInitializeAccessibilityNodeInfo(host,info);info.setClassName(Button.class.getName());
            }
        });return target;
    }
    static View navigationItem(Context context,int icon,String label,boolean active,Runnable action){
        LinearLayout item=new LinearLayout(context);item.setOrientation(LinearLayout.VERTICAL);item.setGravity(Gravity.TOP|Gravity.CENTER_HORIZONTAL);
        item.setPadding(dp(context,2),dp(context,10),dp(context,2),dp(context,8));item.setMinimumHeight(dp(context,76));
        FrameLayout indicator=new FrameLayout(context);indicator.setBackground(shape(context,active?TONAL:android.graphics.Color.TRANSPARENT,18));
        indicator.addView(new Icon(context,icon,active?PRIMARY:MUTED),new FrameLayout.LayoutParams(dp(context,24),dp(context,24),Gravity.CENTER));
        item.addView(indicator,new LinearLayout.LayoutParams(dp(context,56),dp(context,32)));
        TextView text=new TextView(context);text.setText(label.equals("固定课表")?"课表":label);text.setTextSize(12);text.setTextColor(active?PRIMARY:MUTED);
        text.setTypeface(Typeface.create(active?"sans-serif-medium":"sans-serif",Typeface.NORMAL));text.setGravity(Gravity.CENTER);
        text.setPadding(0,dp(context,4),0,0);item.addView(text,new LinearLayout.LayoutParams(-1,-2));
        item.setSelected(active);item.setFocusable(true);item.setContentDescription(label+(active?"，已选中":""));
        item.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        text.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        item.setBackground(ripple(context,android.graphics.Color.TRANSPARENT,16));item.setOnClickListener(v->action.run());return item;
    }

    /** Wrap-content actions flow onto another line when text or screen width requires it. */
    static final class Flow extends ViewGroup {
        private final int gap;
        Flow(Context context){super(context);gap=dp(context,8);}
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
