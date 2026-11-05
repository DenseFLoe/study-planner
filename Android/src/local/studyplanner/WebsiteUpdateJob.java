package local.studyplanner;

import android.app.job.*;

public final class WebsiteUpdateJob extends JobService {
    private boolean stopped;
    public boolean onStartJob(JobParameters parameters){stopped=false;WebsiteUpdates.due(this,()->{if(!stopped)jobFinished(parameters,false);});return true;}
    public boolean onStopJob(JobParameters parameters){stopped=true;WebsiteUpdateRunner runner=WebsiteUpdateRunner.current;if(runner!=null&&!runner.interactive)runner.close();return true;}
}
