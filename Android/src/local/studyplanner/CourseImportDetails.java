package local.studyplanner;

import org.json.*;
import java.util.*;

/** Immutable, paged review text prepared without touching the imported snapshot. */
public final class CourseImportDetails {
    public static final int PAGE_SIZE=25;
    public final String title, summary;
    public final int lessonCount, noticeCount, totalCount;
    private final List<String> entries, searchable;

    public CourseImportDetails(JSONObject snapshot) {
        title=snapshot.optString("name","未命名课程");
        List<String> rows=new ArrayList<>();
        StringBuilder header=new StringBuilder();
        String website=CourseImportCatalog.website(snapshot);
        if(!website.isEmpty())header.append(website);
        JSONObject net=snapshot.optJSONObject("netdisk");
        if(net!=null){
            append(header,net.optString("folderPath"));append(header,net.optString("detection"));
            append(header,"缺失时长估算："+Math.max(0,net.optInt("unknownDurations"))+" 节");
            JSONObject duplicates=net.optJSONObject("duplicates");
            if(duplicates!=null)for(String key:new String[]{"groups","relatedPackages","relatedCourses","requiresReview"}){
                JSONArray notes=duplicates.optJSONArray(key);if(notes==null)continue;
                for(int i=0;i<notes.length();i++)if(notes.opt(i) instanceof String&&!notes.optString(i).isEmpty())
                    rows.add("识别提示："+notes.optString(i));
            }
        }
        noticeCount=rows.size();
        JSONArray lessons=snapshot.optJSONArray("lessons");lessonCount=lessons==null?0:lessons.length();
        JSONObject files=snapshot.optJSONObject("netdiskLessons");
        for(int i=0;i<lessonCount;i++){
            JSONObject lesson=lessons.optJSONObject(i);
            if(lesson==null){rows.add((i+1)+". 课节信息不完整，请重新读取目录。");continue;}
            StringBuilder line=new StringBuilder((i+1)+". "+lesson.optString("name","未命名课节"));
            List<String> location=new ArrayList<>();
            for(String key:new String[]{"subject","stage","chapter"})if(!lesson.optString(key).isEmpty())location.add(lesson.optString(key));
            append(line,String.join(" / ",location));
            double duration=lesson.optDouble("durationSeconds"),progress=lesson.optDouble("watchedPercent");
            String timing=Double.isFinite(duration)&&duration>0&&duration<=Integer.MAX_VALUE*60.0
                ?(long)Math.ceil(duration/60)+" 分钟":"时长未知";
            String watched=Double.isFinite(progress)&&progress>=0&&progress<=100?progress+"%":"未知";
            append(line,(lesson.optBoolean("published")?"已发布":"未发布")+" · "+timing+" · 进度 "+watched);
            JSONObject file=files==null?null:files.optJSONObject(lesson.optString("id"));
            if(file!=null)append(line,file.optString("path")+" · "+Math.max(0,file.optLong("size"))+" 字节"+(file.optBoolean("estimatedDuration")?" · 估算时长":""));
            rows.add(line.toString());
        }
        append(header,"共 "+lessonCount+" 节课 · "+noticeCount+" 条识别提示");
        summary=header.toString();entries=Collections.unmodifiableList(rows);totalCount=rows.size();
        List<String> index=new ArrayList<>();for(String row:rows)index.add(CourseImportCatalog.normalized(row));
        searchable=Collections.unmodifiableList(index);
    }
    private CourseImportDetails(String title,String summary,List<String> rows){
        this.title=title;this.summary=summary;lessonCount=0;noticeCount=0;totalCount=rows.size();
        entries=Collections.unmodifiableList(rows);
        List<String> index=new ArrayList<>();for(String row:rows)index.add(CourseImportCatalog.normalized(row));
        searchable=Collections.unmodifiableList(index);
    }
    public static CourseImportDetails directory(JSONObject scan){
        List<String> rows=new ArrayList<>();JSONArray entries=scan.optJSONArray("entries");
        int folders=0,files=0,unavailable=0;
        if(entries!=null)for(int i=0;i<entries.length();i++){
            JSONObject entry=entries.optJSONObject(i);
            if(entry==null){rows.add((i+1)+". 目录条目信息不完整，请重新读取。");continue;}
            boolean folder=entry.optBoolean("isDirectory");if(folder)folders++;else files++;
            String kind=folder?"目录":NetdiskImport.video(entry)?"视频":"文件";
            StringBuilder line=new StringBuilder((i+1)+". "+kind+" · "+entry.optString("relativePath",entry.optString("name","未命名条目")));
            if(!folder){
                long size=entry.optLong("size",-1);append(line,size<0?"大小未知":size+" 字节");
                Double duration=NetdiskImport.duration(entry);
                if(duration!=null)append(line,(long)Math.ceil(duration/60)+" 分钟");
                else if(NetdiskImport.video(entry))append(line,"时长未知");
            }
            if(!NetdiskImport.playable(entry)){unavailable++;append(line,folder?"网盘标记该目录不可用。":"网盘标记不可用，课程识别将跳过此文件。");}
            rows.add(line.toString());
        }
        String summary="共 "+rows.size()+" 条目 · "+folders+" 个目录 · "+files+" 个文件"+(unavailable==0?"":" · "+unavailable+" 项标记不可用");
        return new CourseImportDetails(scan.optString("shareTitle","分享目录"),summary,rows);
    }
    private CourseImportDetails(CourseImportDetails source,List<String> rows,List<String> index){
        title=source.title;summary=source.summary;lessonCount=source.lessonCount;noticeCount=source.noticeCount;totalCount=source.totalCount;
        entries=Collections.unmodifiableList(rows);searchable=Collections.unmodifiableList(index);
    }
    public CourseImportDetails find(String query){
        String normalized=CourseImportCatalog.normalized(query).trim();if(normalized.isEmpty())return this;
        String[] terms=normalized.split("\\s+");List<String> rows=new ArrayList<>(),index=new ArrayList<>();
        for(int i=0;i<entries.size();i++){
            String text=searchable.get(i);boolean match=true;
            for(String term:terms)if(!text.contains(term)){match=false;break;}
            if(match){rows.add(entries.get(i));index.add(text);}
        }
        return new CourseImportDetails(this,rows,index);
    }
    private static void append(StringBuilder text,String line){if(line.isEmpty())return;if(text.length()>0)text.append('\n');text.append(line);}
    public int count(){return entries.size();}
    public int pageCount(){return entries.isEmpty()?1:(entries.size()-1)/PAGE_SIZE+1;}
    public int pageIndex(int requested){return Math.max(0,Math.min(requested,pageCount()-1));}
    public List<String> page(int requested){int start=pageIndex(requested)*PAGE_SIZE;return entries.subList(start,start+Math.min(PAGE_SIZE,entries.size()-start));}
}
