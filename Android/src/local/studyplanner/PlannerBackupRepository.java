package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;

/** Device-private, bounded recovery history. Never contains account or sync configuration. */
final class PlannerBackupRepository {
    final File directory;
    int unreadable;
    static final class Entry {
        final String id, summary, deletedCourseID, deletedCourseName;
        final double createdAt;
        Entry(PlannerBackupFile backup) throws Exception {
            id=backup.id(); createdAt=backup.createdAt(); summary=backup.summary();
            deletedCourseID=backup.deletedCourseID();
            JSONObject course=Planner.course(backup.state(),deletedCourseID);
            deletedCourseName=course==null?"":course.optString("name");
        }
    }
    PlannerBackupRepository(File directory) { this.directory=directory; }
    synchronized List<Entry> entries() throws Exception {
        unreadable=0; List<Entry> result=new ArrayList<>();
        if(!directory.exists())return result;
        File[] files=directory.listFiles(); if(files==null)throw new IOException("无法读取本机备份目录。");
        for(File file:files)if(file.getName().endsWith(".json")){
            String id=file.getName().substring(0,file.getName().length()-5);
            if(!Planner.canonicalID(id))continue;
            try { result.add(new Entry(load(id))); } catch(Exception error) { unreadable++; }
        }
        result.sort(Comparator.comparingDouble((Entry e)->e.createdAt).reversed().thenComparing(e->e.id));
        return result;
    }
    synchronized PlannerBackupFile load(String id) throws Exception {
        if(!Planner.canonicalID(id))throw new IOException("备份编号无效。");
        PlannerBackupFile value=PlannerBackupFile.read(new FileInputStream(new File(directory,id+".json")));
        if(!id.equals(value.id()))throw new IOException("备份编号不匹配，原文件已保留。");
        return value;
    }
    synchronized Entry save(JSONObject state,double now,String reason,String deletedCourseID) throws Exception {
        PlannerBackupFile backup=PlannerBackupFile.create(state,now,reason);
        backup.markDeletedCourse(deletedCourseID);
        if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("无法创建本机备份，日程未改动。");
        File temporary=File.createTempFile("backup-",".tmp",directory);
        try {
            temporary.setReadable(false,false);temporary.setWritable(false,false);
            temporary.setReadable(true,true);temporary.setWritable(true,true);
            try(FileOutputStream bytes=new FileOutputStream(temporary)){
                backup.write(new FilterOutputStream(bytes){public void close()throws IOException{flush();}});
                bytes.getFD().sync();
            }
            Files.move(temporary.toPath(),new File(directory,backup.id()+".json").toPath(),StandardCopyOption.ATOMIC_MOVE);
        } finally { Files.deleteIfExists(temporary.toPath()); }
        int retained=0;
        for(Entry entry:entries())if(!entry.id.equals(backup.id())&&++retained>=20)
            Files.delete(new File(directory,entry.id+".json").toPath());
        return new Entry(backup);
    }
    static void restoreCourse(JSONObject current,PlannerBackupFile backup) throws Exception {
        String id=backup.deletedCourseID();JSONObject source=backup.state(),course=Planner.course(source,id);
        if(id.isEmpty()||course==null||containsCourse(current.getJSONArray("courses"),id))
            throw new IllegalArgumentException("课程已存在或备份不包含可恢复的课程，请重新核对。");
        Set<String> restored=new HashSet<>(),existing=new HashSet<>();collectIDs(new JSONArray().put(course),restored);collectIDs(current.getJSONArray("courses"),existing);
        if(!Collections.disjoint(restored,existing))throw new IllegalArgumentException("合并课程的来源已恢复，未重复恢复学习量。");
        JSONObject next=CourseTools.copy(current);
        for(String key:new String[]{"tasks","completions"}){
            Set<String> ids=new HashSet<>();for(JSONObject row:Planner.list(next.getJSONArray(key)))ids.add(row.getString("id"));
            for(JSONObject row:Planner.list(source.getJSONArray(key)))if(id.equals(row.optString("courseID"))){
                if(!ids.add(row.getString("id")))throw new IllegalArgumentException("学习记录已被其他课程使用，未恢复重复记录。");
                next.getJSONArray(key).put(row);
            }
        }
        next.getJSONArray("courses").put(course);Planner.validate(next);
        for(String key:new String[]{"courses","tasks","completions"})current.put(key,next.getJSONArray(key));
    }
    private static boolean containsCourse(JSONArray courses,String id)throws Exception{
        if(courses==null)return false;
        for(JSONObject course:Planner.list(courses))if(id.equals(course.getString("id"))||containsCourse(course.optJSONArray("mergedSources"),id))return true;
        return false;
    }
    private static void collectIDs(JSONArray courses,Set<String> ids)throws Exception{
        if(courses!=null)for(JSONObject course:Planner.list(courses)){ids.add(course.getString("id"));collectIDs(course.optJSONArray("mergedSources"),ids);}
    }
}
