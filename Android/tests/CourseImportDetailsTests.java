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
        System.out.println("Course import details: "+checks+" checks passed");
    }
}
