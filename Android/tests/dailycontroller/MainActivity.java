package local.studyplanner;

import org.json.JSONObject;
import java.io.File;
import java.util.*;

/** Test-only UI boundary; executes the real controller and filesystem repository, not Android widgets. */
final class MainActivity {
    final File folder;final Preferences preferences=new Preferences();
    final List<Runnable> callbacks=new ArrayList<>();
    JSONObject state;int page=4,renders;Object consequencePanel=new Object();boolean destroyed,queueCallbacks;
    MainActivity(File folder){this.folder=folder;}
    File getFilesDir(){return folder;}
    Preferences getPreferences(int mode){return preferences;}
    boolean isDestroyed(){return destroyed;}
    void runOnUiThread(Runnable runnable){if(queueCallbacks)callbacks.add(runnable);else runnable.run();}
    void drain(){List<Runnable> pending=new ArrayList<>(callbacks);callbacks.clear();for(Runnable callback:pending)callback.run();}
    void render(){renders++;}
    void alert(String title,String message){renders++;}
    static final class Preferences {int getInt(String key,int fallback){return fallback;}}
}
