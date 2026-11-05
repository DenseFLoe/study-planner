package local.studyplanner;

import org.json.*;
import java.util.*;

public final class CourseImportDetailsTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception {
        JSONObject snapshot=new JSONObject().put("name","大课程")
            .put("sourceURL","https://account:SYNTHETIC_PASSWORD@example.test/private-path?token=SYNTHETIC_TOKEN#private-fragment");
        JSONArray lessons=new JSONArray();
        for(int i=0;i<53;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","课节"+i)
            .put("subject","数学二").put("stage","强化").put("chapter","第三章")
            .put("published",true).put("durationSeconds",61).put("watchedPercent",25));
        snapshot.put("lessons",lessons).put("netdisk",new JSONObject().put("folderPath","资料/数学")
            .put("duplicates",new JSONObject().put("requiresReview",new JSONArray().put("版本不同").put("时长不同"))))
            .put("netdiskLessons",new JSONObject().put("lesson0",new JSONObject().put("path","数学/01.mp4").put("size",123).put("estimatedDuration",true)));
        String before=SyncLedger.canonical(snapshot);CourseImportDetails details=new CourseImportDetails(snapshot);
        check(details.lessonCount==53&&details.noticeCount==2&&details.count()==55,"Missing optional duplicate arrays lost course details");
        check(details.pageCount()==3&&details.page(0).size()==25&&details.page(2).size()==5,"Detail pagination lost rows");
        check(details.page(0).get(0).contains("版本不同")&&details.page(0).get(1).contains("时长不同"),"Recognition notices were omitted or reordered");
        String lesson=details.page(0).get(2);
        check(lesson.contains("1. 课节0")&&lesson.contains("数学二 / 强化 / 第三章")&&lesson.contains("2 分钟")&&lesson.contains("25.0%"),"Lesson timing or location missing");
        check(lesson.contains("数学/01.mp4")&&lesson.contains("123 字节")&&lesson.contains("估算时长"),"File source details missing");
        check(details.page(Integer.MAX_VALUE).get(4).startsWith("53. 课节52"),"Last-page clamp dropped the last lesson");
        check(details.page(Integer.MIN_VALUE).equals(details.page(0)),"Negative page did not clamp");
        check(details.summary.contains("example.test")&&details.summary.contains("资料/数学"),"Public source label missing");
        String text=details.summary+details.page(0);
        for(String privateValue:new String[]{"SYNTHETIC","account","private-path","private-fragment"})check(!text.contains(privateValue),"Private URL part reached details");
        check(SyncLedger.canonical(snapshot).equals(before),"Detail preparation mutated import data");
        lessons.getJSONObject(0).put("name","后来的名称");check(details.page(0).get(2).contains("课节0"),"Prepared detail text changed under the open dialog");
        try{details.page(0).clear();throw new AssertionError("Detail pages are mutable");}catch(UnsupportedOperationException expected){checks++;}
        JSONObject partial=new JSONObject().put("lessons",new JSONArray().put(JSONObject.NULL).put(new JSONObject().put("name","未知信息")));
        CourseImportDetails incomplete=new CourseImportDetails(partial);
        check(incomplete.count()==2&&incomplete.page(0).get(0).contains("信息不完整"),"Malformed lesson hid the complete directory");
        check(incomplete.page(0).get(1).contains("时长未知")&&incomplete.page(0).get(1).contains("进度 未知"),"Missing duration or progress was invented");
        CourseImportDetails empty=new CourseImportDetails(new JSONObject());
        check(empty.lessonCount==0&&empty.pageCount()==1&&empty.page(99).isEmpty(),"Empty directory failed");
        JSONArray large=new JSONArray();for(int i=0;i<5001;i++)large.put(new JSONObject().put("name","大目录课节"+i));
        CourseImportDetails many=new CourseImportDetails(new JSONObject().put("lessons",large));
        check(many.pageCount()==201&&many.page(200).size()==1&&many.page(200).get(0).contains("大目录课节5000"),"Large directory was truncated");
        CourseImportDetails found=many.find("大目录课节５０００");
        check(found.count()==1&&found.totalCount==5001&&found.page(0).get(0).startsWith("5001."),"Full-width search lost original lesson numbering");
        check(details.find("数学/01.mp4 估算").count()==1,"Combined file path search did not find the original source");
        check(details.find("数学二 第三章").count()==53&&details.find("数学二 冲刺").count()==0,"Lesson metadata search used OR matching");
        check(details.find("版本 不同").count()==1,"Recognition notice was not searchable");
        check(details.find("SYNTHETIC").count()==0,"Private URL components entered the detail search");
        check(details.find("　 \t ")==details&&details.count()==55,"Blank search did not restore the complete directory");
        CourseImportDetails accents=new CourseImportDetails(new JSONObject().put("lessons",new JSONArray().put(new JSONObject().put("name","Résumé ALgebra"))));
        check(accents.find("ＲＥＳＵＭＥ algebra").count()==1,"Case, accent or width normalization changed between import searches");
        JSONObject scan=new JSONObject().put("shareTitle","全部资料").put("sourceURL","https://pan.quark.cn/s/abc123?pwd=SYNTHETIC_PRIVATE")
            .put("entries",new JSONArray()
                .put(new JSONObject().put("name","数学").put("relativePath","数学").put("isDirectory",true))
                .put(new JSONObject().put("fid","OPAQUE_ID").put("name","01.mp4").put("relativePath","数学/01.mp4").put("size",123).put("durationSeconds",61))
                .put(new JSONObject().put("name","讲义.pdf").put("relativePath","数学/讲义.pdf").put("banned",true)));
        String scanBefore=SyncLedger.canonical(scan);CourseImportDetails directory=CourseImportDetails.directory(scan);
        check(directory.title.equals("全部资料")&&directory.summary.contains("1 个目录 · 2 个文件")&&directory.summary.contains("1 项标记不可用"),"Directory summary or provider status was lost");
        check(directory.find("视频 01.mp4").count()==1&&directory.find("视频").count()==1&&directory.find("视频").page(0).get(0).contains("2 分钟"),"Directory video type or duration missing");
        check(directory.find("不可用 讲义").count()==1&&directory.find("文件 讲义").page(0).get(0).contains("大小未知"),"Unavailable or missing-size file disappeared from review");
        check(directory.find("SYNTHETIC_PRIVATE").count()==0&&directory.find("OPAQUE_ID").count()==0,"Private share parameters or provider IDs became searchable");
        check(SyncLedger.canonical(scan).equals(scanBefore),"Directory review mutated scan data");
        for(String flag:new String[]{"banned","badContent","riskType","status"}){
            JSONObject item=new JSONObject().put("name","受限.mp4");item.put(flag,flag.equals("status")?0:flag.equals("riskType")?1:true);
            CourseImportDetails blocked=CourseImportDetails.directory(new JSONObject().put("entries",new JSONArray().put(item)));
            check(blocked.find("不可用").count()==1,"Provider flag was not aligned with course recognition: "+flag);
        }
        check(CourseImportDetails.directory(new JSONObject()).page(99).isEmpty(),"Missing directory entries failed");
        JSONArray directoryRows=new JSONArray();for(int i=0;i<5001;i++)directoryRows.put(new JSONObject().put("name","视频"+i+".mp4").put("relativePath","资料/视频"+i+".mp4"));
        CourseImportDetails largeDirectory=CourseImportDetails.directory(new JSONObject().put("entries",directoryRows));
        check(largeDirectory.pageCount()==201&&largeDirectory.find("视频５０００.mp4").count()==1,"Large directory was truncated or unsearchable");
        JSONArray reviewLessons=new JSONArray();
        for(int i=0;i<8;i++)reviewLessons.put(new JSONObject().put("id","review"+i).put("name","检查"+i)
            .put("published",true).put("requiresDuration",true).put("durationSeconds",60).put("watchedPercent",25));
        reviewLessons.getJSONObject(0).put("name","名称中含需核对，但数据有效");
        reviewLessons.getJSONObject(1).remove("watchedPercent");reviewLessons.getJSONObject(1).put("markedFinished",true);
        reviewLessons.getJSONObject(2).put("published",false).remove("durationSeconds");reviewLessons.getJSONObject(2).remove("watchedPercent");
        reviewLessons.getJSONObject(3).put("requiresDuration",false).remove("durationSeconds");reviewLessons.getJSONObject(3).remove("watchedPercent");
        reviewLessons.getJSONObject(4).put("id","duplicate");reviewLessons.getJSONObject(5).put("id","duplicate");
        reviewLessons.getJSONObject(6).put("durationSeconds",0);reviewLessons.getJSONObject(7).remove("id");
        JSONObject reviewSnapshot=new JSONObject().put("lessons",reviewLessons);String reviewBefore=SyncLedger.canonical(reviewSnapshot);
        CourseImportDetails review=new CourseImportDetails(reviewSnapshot),problems=review.find("",true);
        check(review.reviewCount==5&&problems.count()==5&&problems.totalCount==8,"Review-only mode did not distinguish actual validation problems from lesson names");
        check(problems.page(0).get(0).startsWith("2. 检查1")&&problems.page(0).get(4).startsWith("8. 检查7"),"Problem filtering changed the original lesson numbers");
        check(review.find("检查1",true).count()==1&&review.find("检查2",true).count()==0&&review.find("检查3",true).count()==0,"Problem search treated unpublished or non-timed lessons as missing required data");
        String finished=review.find("检查1",true).page(0).get(0);
        check(finished.contains("网站标记已完成")&&finished.contains("进度 未知")&&finished.contains("缺少观看进度")&&!finished.contains("100.0%"),"Website completion marker fabricated measured progress");
        check(review.find("标识重复",true).count()==2&&review.find("时长无效",true).count()==1&&review.find("标识缺失",true).count()==1,"Invalid or duplicate fields were hidden");
        check(review.find("",false).count()==8&&SyncLedger.canonical(reviewSnapshot).equals(reviewBefore),"Review filtering altered course data or could not restore all rows");
        check(directory.find("",true).count()==0,"Directory availability was mistaken for a malformed course lesson");
        for(Object invalid:new Object[]{-1,101,"invalid"}){
            JSONObject invalidLesson=new JSONObject().put("id","invalid").put("published",false).put("watchedPercent",invalid);
            check(new CourseImportDetails(new JSONObject().put("lessons",new JSONArray().put(invalidLesson))).find("观看进度无效",true).count()==1,"Invalid optional progress escaped review");
        }
        System.out.println("Course import details: "+checks+" checks passed");
    }
}
