package local.studyplanner;
import android.app.job.*;

/** Android may defer hourly work while idle; pending snapshots remain durable. */
public final class CloudSyncJob extends JobService {
    public boolean onStartJob(JobParameters parameters){if(!CloudSettings.enabled(this))return false;CloudSync.get(this).request(ok->jobFinished(parameters,!ok));return true;}
    public boolean onStopJob(JobParameters parameters){return true;}
}
