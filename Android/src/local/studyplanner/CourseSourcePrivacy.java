package local.studyplanner;

import org.json.*;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.*;
import java.util.*;

/** Remove private URL components without changing course data or sync record identities. */
public final class CourseSourcePrivacy {
    private static boolean identifier(String value) {
        int count=value.codePointCount(0,value.length());
        return count>=4&&count<=64&&value.codePoints().allMatch(Character::isLetterOrDigit);
    }
    static String netdiskURL(String value) {
        try {
            String text=value.trim();
            if(text.contains("..")||text.matches("(?s).*[\"'<>\\\\`{}|^].*"))return "";
            URI url=new URI(text.contains("://")?text:"https://"+text);
            String host=url.getHost();
            if(!"https".equalsIgnoreCase(url.getScheme())||host==null||
                !Arrays.asList("pan.quark.cn","www.quark.cn","quark.cn").contains(host.toLowerCase(Locale.ROOT)))return "";
            String share=null,folder=null;String[] path=url.getPath().split("/");
            for(int i=0;i+1<path.length;i++)if(path[i].equals("s")){if(identifier(path[i+1]))share=path[i+1];break;}
            if(share==null)return "";
            if(url.getFragment()!=null){String[] fragment=url.getFragment().split("/");
                for(int i=0;i+1<fragment.length;i++)if(fragment[i].equals("share")){if(identifier(fragment[i+1]))folder=fragment[i+1];break;}}
            return "https://pan.quark.cn/s/"+share+(folder==null?"":"#/list/share/"+folder);
        } catch(Exception invalid) { return ""; }
    }
    static String netdiskShare(String value) {
        String safe=netdiskURL(value);if(safe.isEmpty())return "";
        String path=URI.create(safe).getPath();return path.substring(path.lastIndexOf('/')+1);
    }
    static String netdiskFolder(String value) {
        String safe=netdiskURL(value);if(safe.isEmpty())return "";
        String fragment=URI.create(safe).getFragment();return fragment==null?"":fragment.substring(fragment.lastIndexOf('/')+1);
    }

    private static JSONObject metadata(JSONObject source,boolean netdisk)throws Exception {
        JSONObject result=SyncLedger.shallowCopy(source);boolean changed=false;
        Object raw=source.opt("sourceURL");
        if(raw instanceof String){String safe=netdisk?netdiskURL((String)raw):WebCourseImport.safeURL((String)raw);
            if(!safe.equals(raw)){result.put("sourceURL",safe);changed=true;}}
        if(!netdisk&&source.optJSONObject("netdisk")!=null){JSONObject old=source.getJSONObject("netdisk"),clean=metadata(old,true);
            if(clean!=old){result.put("netdisk",clean);changed=true;}}
        return changed?result:source;
    }

    static JSONObject course(JSONObject source)throws Exception {
        JSONObject result=SyncLedger.shallowCopy(source);boolean changed=false;
        for(String field:new String[]{"webCourse","netdisk"}){
            JSONObject old=source.optJSONObject(field);if(old==null)continue;
            JSONObject clean=metadata(old,field.equals("netdisk"));
            if(clean!=old){result.put(field,clean);changed=true;}
        }
        JSONArray merged=source.optJSONArray("mergedSources");
        if(merged!=null){JSONArray clean=new JSONArray();boolean nested=false;
            for(int i=0;i<merged.length();i++){Object old=merged.get(i),item=old instanceof JSONObject?course((JSONObject)old):old;
                clean.put(item);nested|=item!=old;}
            if(nested){result.put("mergedSources",clean);changed=true;}
        }
        return changed?result:source;
    }

    static JSONObject state(JSONObject source)throws Exception {
        JSONArray courses=source.optJSONArray("courses");if(courses==null)return source;
        JSONArray clean=new JSONArray();boolean changed=false;
        for(int i=0;i<courses.length();i++){JSONObject old=courses.getJSONObject(i),item=course(old);clean.put(item);changed|=item!=old;}
        return changed?SyncLedger.shallowCopy(source).put("courses",clean):source;
    }

    static JSONObject record(JSONObject source)throws Exception {
        if(!"courses".equals(source.optString("kind"))||!(source.opt("payload") instanceof String))return source;
        JSONObject original;
        try {
            byte[] bytes=Base64.getDecoder().decode(source.getString("payload"));
            String text=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
            JSONTokener tokens=new JSONTokener(text);Object value=tokens.nextValue();
            if(!(value instanceof JSONObject)||tokens.nextClean()!=0)return source;
            original=(JSONObject)value;
        } catch(JSONException|IllegalArgumentException|CharacterCodingException invalid) {
            // Leave malformed/opaque historical payloads to the existing protocol validator.
            return source;
        }
        JSONObject clean=course(original);if(clean==original)return source;
        return SyncLedger.shallowCopy(source).put("payload",Base64.getEncoder().encodeToString(clean.toString().getBytes(StandardCharsets.UTF_8)));
    }
}
