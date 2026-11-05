package local.studyplanner;

import org.json.*;
import java.util.*;

public final class CourseImportCatalogTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject course(String host)throws Exception {
        JSONObject value=ImportParityTests.snapshot(0,0,ImportParityTests.now).put("packageID","generic:course42").put("name","数学 Algebra")
            .put("sourceURL","https://"+host+"/course?token=SYNTHETIC_PRIVATE");
        value.getJSONArray("lessons").getJSONObject(0).put("name","Résumé 极限").put("subject","数学二").put("stage","强化").put("chapter","第三章");
        return value;
    }
    public static void main(String[] args)throws Exception {
        JSONObject a=course("alpha.test"),b=course("beta.test:8443");List<JSONObject> courses=Arrays.asList(a,b);
        for(String query:new String[]{"", " \t ", "ＡＬＧＥＢＲＡ　数学二", "resume 强化 第三章", "alpha.test 极限"})
            check(CourseImportCatalog.matches(a,query),"Visible fields were not searchable: "+query);
        check(!CourseImportCatalog.matches(a,"极限 冲刺"),"Combined terms became OR matching");
        check(CourseImportCatalog.website(b).equals("beta.test:8443"),"Distinct port omitted");
        check(CourseImportCatalog.website(course("alpha.test:443")).equals("alpha.test"),"Default port was not canonical");
        check(CourseImportCatalog.matchingSelectableIDs(courses,"8443").equals(Collections.singleton(WebCourseImport.identity(b))),"Source selection collided");
        a.put("sourceURL","https://account:SYNTHETIC_PASSWORD@alpha.test/private-path?token=SYNTHETIC_PRIVATE#private-fragment");
        for(String term:new String[]{"SYNTHETIC", "account", "private-path", "private-fragment"})check(!CourseImportCatalog.matches(a,term),"Private URL field became searchable");
        check(CourseImportCatalog.website(a).equals("alpha.test"),"Private URL fields reached display");
        JSONObject net=course("pan.quark.cn").put("netdisk",new JSONObject().put("folderPath","资料/高数/基础班"));
        check(CourseImportCatalog.matches(net,"资料 基础班 极限"),"Netdisk folder search lost");
        Set<String> chosen=new HashSet<>(Arrays.asList(WebCourseImport.identity(a),WebCourseImport.identity(b),"missing"));
        String summary=CourseImportCatalog.summary(courses,chosen,"alpha.test");
        check(summary.contains("显示 1 / 2 门")&&summary.contains("已选 2 门")&&summary.contains("其中 1 门在筛选之外"),"Hidden selection count wrong");
        check(!CourseImportCatalog.summary(courses,chosen,"").contains("筛选之外"),"Blank search hid selected courses");
        Set<String> retained=CourseImportCatalog.retainedSelection(courses,chosen);
        check(retained.equals(new HashSet<>(Arrays.asList(WebCourseImport.identity(a),WebCourseImport.identity(b)))),"Refresh lost valid choices or kept missing choice");
        check(chosen.contains("missing"),"Catalog mutated caller's selection");
        b.getJSONArray("issues").put("incomplete");
        check(CourseImportCatalog.retainedSelection(courses,chosen).equals(Collections.singleton(WebCourseImport.identity(a))),"Incomplete refreshed course stayed selected");
        check(CourseImportCatalog.matches(b,"beta.test"),"Incomplete course hidden from review");
        check(CourseImportCatalog.matchingSelectableIDs(courses,"beta.test").isEmpty(),"Incomplete course included in bulk selection");
        a.put("refusal","duration missing");check(CourseImportCatalog.matchingSelectableIDs(courses,"").isEmpty(),"Refused course selectable");
        check(CourseImportCatalog.retainedSelection(Collections.singletonList(course("alpha.test")),Collections.emptySet()).isEmpty(),"Refresh invented a selection");
        List<JSONObject> large=new ArrayList<>();for(int i=0;i<250;i++){JSONObject item=course("example.test").put("name","课程"+i).put("packageID","generic:"+i);large.add(item);}
        check(CourseImportCatalog.matchingSelectableIDs(large,"课程１３７ 第三章").equals(Collections.singleton(WebCourseImport.identity(large.get(137)))),"Large catalog search broadened selection");
        System.out.println("Course import catalog: "+checks+" checks passed");
    }
}
