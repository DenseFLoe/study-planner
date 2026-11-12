package local.studyplanner;

import android.app.*;
import android.os.Bundle;
import android.view.*;
import android.widget.*;

/** User-owned verification window; no CAPTCHA, agreement or login UI is bypassed. */
public final class WebsiteUpdateActivity extends Activity {
    WebsiteUpdateRunner runner;
    @Override public void onCreate(Bundle saved){super.onCreate(saved);getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        LinearLayout root=new LinearLayout(this);root.setOrientation(1);int pad=(int)(16*getResources().getDisplayMetrics().density);root.setPadding(pad,pad,pad,pad);
        TextView status=new TextView(this);root.addView(status);Button retry=PlannerUi.compactButton(this,"完成验证，重新更新",()->{if(runner!=null&&!runner.reading)runner.restart();});root.addView(retry);root.addView(PlannerUi.compactButton(this,"关闭",this::finish));setContentView(root);
        String id=getIntent().getStringExtra("courseID");if(id==null){finish();return;}
        runner=new WebsiteUpdateRunner(this,id,true,status::setText,ok->{if(ok)retry.setText("再次更新");});
        runner.start(web->root.addView(web,new LinearLayout.LayoutParams(-1,0,1)));
    }
    @Override protected void onDestroy(){if(runner!=null)runner.close();super.onDestroy();}
}
