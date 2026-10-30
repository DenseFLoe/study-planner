package local.studyplanner;

import android.content.Context;
import android.util.AtomicFile;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Populated exclusively after a successful cloud merge, never by LAN sync or the local scheduler. */
final class CompressedPreviewStore {
    static AtomicFile file(Context c){return new AtomicFile(new File(c.getFilesDir(),"cloud-compressed-preview.json"));}
    static JSONObject read(Context c)throws Exception {
        AtomicFile f=file(c);if(!f.getBaseFile().exists()&&!new File(f.getBaseFile()+".bak").exists())return null;
        try(InputStream in=new CloudSnapshot.LimitedInput(f.openRead(),900000)){JSONObject p=new JSONObject(MainActivity.read(in));CompressedPreview.validate(p);return p;}
    }
    static void receive(Context c,JSONObject state)throws Exception {
        AtomicFile f=file(c);JSONObject preview=state.getJSONObject("settings").optJSONObject(CompressedPreview.FIELD);
        if(preview==null){f.delete();return;}CompressedPreview.validate(preview);byte[] data=preview.toString().getBytes(StandardCharsets.UTF_8);
        if(data.length>900000)throw new IOException("同步的压缩结果超过显示上限");
        FileOutputStream out=f.startWrite();try{out.write(data);f.finishWrite(out);}catch(Exception e){f.failWrite(out);throw e;}
    }
}
