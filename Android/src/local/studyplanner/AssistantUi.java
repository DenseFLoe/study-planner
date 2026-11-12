package local.studyplanner;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.*;
import android.graphics.drawable.*;
import android.view.Gravity;
import android.widget.Button;

/** Assistant-only phone chrome; the planner keeps its own visual theme. */
final class AssistantUi {
    static final int WHITE=0xffffffff, INK=0xff202124, MUTED=0xff727783,
        BLUE=0xff4d6bfe, PALE=0xffedf2ff, SURFACE=0xfff5f6f8, LINE=0xffe7e9ee, BUTTON_OUTLINE=0xff3e4656;
    static final int MENU=0, NEW=1, SEND=2, STOP=3, CLOSE=4, CHAT=5;
    static int dp(Context c,int n){return PlannerUi.dp(c,n);}
    static GradientDrawable shape(Context c,int color,int radius){return PlannerUi.shape(c,color,radius);}
    static void tone(Button button,boolean primary){
        PlannerUi.buttonBackground(button,primary?BLUE:SURFACE,primary?0xffc8d2ff:SURFACE,BUTTON_OUTLINE,24,0x224d6bfe);
        button.setTextColor(new ColorStateList(new int[][]{new int[]{-android.R.attr.state_enabled},new int[]{}},new int[]{MUTED,primary?WHITE:INK}));
    }
    static void quiet(Button button){
        PlannerUi.buttonBackground(button,0,SURFACE,BUTTON_OUTLINE,16,0x224d6bfe);
        button.setTextColor(new ColorStateList(new int[][]{new int[]{-android.R.attr.state_enabled},new int[]{}},new int[]{MUTED,BLUE}));
    }
    static Button icon(Context c,int kind,String label,boolean primary,Runnable action){
        Button b=new Button(c);PlannerUi.styleButton(b);b.setText("");b.setContentDescription(label);
        b.setPadding(dp(c,12),dp(c,12),dp(c,12),dp(c,12));b.setGravity(Gravity.CENTER);
        Symbol symbol=new Symbol(kind,primary?WHITE:INK);symbol.setBounds(0,0,dp(c,24),dp(c,24));
        b.setCompoundDrawables(symbol,null,null,null);b.setOnClickListener(v->action.run());
        if(primary)tone(b,true);else quiet(b);return b;
    }
    static final class Symbol extends Drawable {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);final int kind;
        Symbol(int kind,int color){this.kind=kind;paint.setColor(color);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(1.8f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);}
        @Override public void draw(Canvas c){
            c.save();c.translate(getBounds().left,getBounds().top);c.scale(getBounds().width()/24f,getBounds().height()/24f);
            if(kind==MENU){c.drawLine(4,8,20,8,paint);c.drawLine(4,16,14,16,paint);}
            else if(kind==NEW||kind==CHAT){c.drawRoundRect(3,3,21,18,5,5,paint);c.drawLine(7,18,7,22,paint);c.drawLine(7,22,12,18,paint);
                if(kind==NEW){c.drawLine(8,10,16,10,paint);c.drawLine(12,6,12,14,paint);}else{c.drawLine(8,8,16,8,paint);c.drawLine(8,13,13,13,paint);}}
            else if(kind==SEND){c.drawLine(12,19,12,5,paint);c.drawLine(6,11,12,5,paint);c.drawLine(12,5,18,11,paint);}
            else if(kind==STOP){paint.setStyle(Paint.Style.FILL);c.drawRoundRect(6,6,18,18,2,2,paint);}
            else {c.drawLine(6,6,18,18,paint);c.drawLine(18,6,6,18,paint);}c.restore();
        }
        @Override public void setAlpha(int alpha){paint.setAlpha(alpha);invalidateSelf();}
        @Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);invalidateSelf();}
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
}
