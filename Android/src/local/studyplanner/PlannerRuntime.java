package local.studyplanner;
import android.content.Context;
import java.util.concurrent.*;

/** One serial database owner shared by UI and a finite sync window; never polls. */
final class PlannerRuntime {
    private static PlannerRuntime instance;
    final PlannerDatabase database;
    final LocalRestoreBackup restoreBackup;
    final ExecutorService worker=Executors.newSingleThreadExecutor(r->new Thread(r,"planner-database"));
    private PlannerRuntime(Context context){Planner.ZONE=CalendarZone.resolve(context);database=new PlannerDatabase(context.getApplicationContext());restoreBackup=new LocalRestoreBackup(new java.io.File(context.getFilesDir(),"restore-recovery.json"));}
    static synchronized PlannerRuntime get(Context context){if(instance==null)instance=new PlannerRuntime(context);return instance;}
}
