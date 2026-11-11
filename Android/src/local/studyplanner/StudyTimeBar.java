package local.studyplanner;

import android.graphics.*;
import android.view.View;
import android.widget.LinearLayout;

/** Wrapped labels plus a decorative two-color bar; daily rows share one scale. */
final class StudyTimeBar {
    static final int TEAL=0xff16877e,ORANGE=0xffc36517;
    static void add(MainActivity app,LinearLayout parent,String title,String summary,
                    String firstLabel,long first,String secondLabel,long second,long scale,long marker){
        LinearLayout box=app.col();box.setPadding(0,app.dp(6),0,app.dp(6));parent.addView(box);
        box.addView(app.text(title,15,app.muted));box.addView(app.text(summary,16,app.ink));
        box.addView(new Bar(app,first,second,scale,marker),new LinearLayout.LayoutParams(-1,app.dp(24)));
        // Separate lines remain readable on narrow screens and with large system text.
        box.addView(app.text("● "+firstLabel+" · "+ScheduleHealthPresentation.duration(first),14,TEAL));
        box.addView(app.text("● "+secondLabel+" · "+ScheduleHealthPresentation.duration(second),14,ORANGE));
    }
    static void overview(MainActivity app,LinearLayout parent,ScheduleHealthPresentation p){
        long remaining=p.health.optLong("remainingMinutes"),planned=p.plannedMinutes();
        add(app,parent,"剩余学习时间",ScheduleHealthPresentation.duration(remaining),"已安排",planned,"未安排",remaining-planned,0,0);
        if(p.health.optLong("pausedMinutes")>0)parent.addView(app.text("未安排中，"+ScheduleHealthPresentation.duration(p.health.optLong("unplacedMinutes"))+"待排入日程，"+
            ScheduleHealthPresentation.duration(p.health.optLong("pausedMinutes"))+"因课程暂停自动排程而未安排。",14,app.muted));
    }
    static void daily(MainActivity app,LinearLayout parent,org.json.JSONObject day,ScheduleHealthPresentation p,String title){
        long minutes=day.optLong("plannedMinutes");
        add(app,parent,title,"已安排 "+ScheduleHealthPresentation.duration(minutes),"提醒线内",Math.min(minutes,p.warningMinutes),
            "超出提醒线",Math.max(0,minutes-p.warningMinutes),p.dailyScale(),p.warningMinutes);
    }
    private static final class Bar extends View {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path clip=new Path();
        final double first,second,scale,marker;
        final float density;
        Bar(MainActivity app,long first,long second,long scale,long marker){
            super(app);this.first=Math.max(0,first);this.second=Math.max(0,second);
            this.scale=Math.max(1,Math.max(scale,this.first+this.second));this.marker=marker;
            density=getResources().getDisplayMetrics().density;
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        }
        @Override protected void onDraw(Canvas canvas){
            super.onDraw(canvas);float w=getWidth(),top=5*density,bottom=getHeight()-5*density;
            RectF track=new RectF(0,top,w,bottom);paint.setColor(0xffe9eeeb);canvas.drawRoundRect(track,5*density,5*density,paint);
            clip.reset();clip.addRoundRect(track,5*density,5*density,Path.Direction.CW);canvas.save();canvas.clipPath(clip);
            float split=(float)(w*first/scale),end=(float)(w*(first+second)/scale);
            paint.setColor(TEAL);canvas.drawRect(0,top,split,bottom,paint);
            paint.setColor(ORANGE);canvas.drawRect(split,top,end,bottom,paint);canvas.restore();
            if(marker>0&&marker<=scale){paint.setColor(0xff47564f);paint.setStrokeWidth(density);
                float x=Math.max(density/2,Math.min(w-density/2,(float)(w*marker/scale)));canvas.drawLine(x,2*density,x,getHeight()-2*density,paint);}
        }
    }
}
