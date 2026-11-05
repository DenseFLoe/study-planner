package local.studyplanner;

import org.json.*;
import java.net.URI;
import java.text.Normalizer;
import java.util.*;

/** Public import catalog fields and selection counts; URL credentials never enter search text. */
public final class CourseImportCatalog {
    public static final int PAGE_SIZE=50;
    /** Capture lists are replaced on refresh and remain read-only while a search runs. */
    public static final class SearchResult {
        public final List<JSONObject> source, matches;
        public final String query;
        public SearchResult(List<JSONObject> source,String query) {
            this.source=source;this.query=query;matches=filtered(source,query);
        }
        public boolean isCurrent(List<JSONObject> captures,String term) {return source==captures&&query.equals(term);}
    }
    private static final java.util.regex.Pattern MARKS=java.util.regex.Pattern.compile("\\p{M}+");
    private static final java.util.regex.Pattern WORDS=java.util.regex.Pattern.compile("\\s+");
    private static String normalized(String value) {
        return MARKS.matcher(Normalizer.normalize(value,Normalizer.Form.NFKD)).replaceAll("").toLowerCase(Locale.ROOT);
    }
    public static String website(JSONObject snapshot) {
        try {
            URI url=new URI(WebCourseImport.safeURL(snapshot.optString("sourceURL")));
            if(url.getHost()==null)return "";
            return url.getHost()+(url.getPort()<0||url.getPort()==443?"":":"+url.getPort());
        } catch(Exception invalid) { return ""; }
    }
    public static boolean matches(JSONObject snapshot,String query) {
        String term=normalized(query).trim();if(term.isEmpty())return true;
        StringBuilder text=new StringBuilder(snapshot.optString("name")).append(' ').append(website(snapshot));
        JSONObject netdisk=snapshot.optJSONObject("netdisk");if(netdisk!=null)text.append(' ').append(netdisk.optString("folderPath"));
        for(JSONObject lesson:Planner.list(snapshot.optJSONArray("lessons")))
            for(String key:new String[]{"name","subject","stage","chapter"})text.append(' ').append(lesson.optString(key));
        String haystack=normalized(text.toString());
        for(String word:WORDS.split(term))if(!haystack.contains(word))return false;
        return true;
    }
    public static boolean importable(JSONObject snapshot) {
        return !snapshot.has("refusal")&&WebCourseImport.problem(snapshot)==null;
    }
    public static Set<String> matchingSelectableIDs(List<JSONObject> captures,String query) {
        Set<String> ids=new HashSet<>();
        for(JSONObject snapshot:captures)if(importable(snapshot)&&matches(snapshot,query))ids.add(WebCourseImport.identity(snapshot));
        return ids;
    }
    public static Set<String> retainedSelection(List<JSONObject> captures,Set<String> selected) {
        Set<String> ids=matchingSelectableIDs(captures,"");ids.retainAll(selected);return ids;
    }
    public static List<JSONObject> filtered(List<JSONObject> captures,String query) {
        List<JSONObject> result=new ArrayList<>();for(JSONObject capture:captures)if(matches(capture,query))result.add(capture);return result;
    }
    public static int pageCount(List<JSONObject> filtered) {return filtered.isEmpty()?1:(filtered.size()-1)/PAGE_SIZE+1;}
    public static List<JSONObject> page(List<JSONObject> filtered,int index) {
        int start=Math.max(0,Math.min(index,pageCount(filtered)-1))*PAGE_SIZE;
        return new ArrayList<>(filtered.subList(start,start+Math.min(PAGE_SIZE,filtered.size()-start)));
    }
    public static String summary(List<JSONObject> captures,Set<String> selected,String query) {
        return summary(captures,selected,filtered(captures,query));
    }
    public static String summary(List<JSONObject> captures,Set<String> selected,List<JSONObject> filtered) {
        Set<String> known=new HashSet<>(),visible=new HashSet<>();
        for(JSONObject snapshot:captures)known.add(WebCourseImport.identity(snapshot));
        for(JSONObject snapshot:filtered)visible.add(WebCourseImport.identity(snapshot));
        known.retainAll(selected);Set<String> hidden=new HashSet<>(known);hidden.removeAll(visible);
        return "显示 "+visible.size()+" / "+captures.size()+" 门 · 已选 "+known.size()+" 门"
            +(hidden.isEmpty()?"":"\n其中 "+hidden.size()+" 门在筛选之外，导入时会一并保存；可清除筛选查看，或点“只选搜索结果”。");
    }
}
