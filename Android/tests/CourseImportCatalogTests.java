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
    static final class GuardedCapture extends JSONObject {
        boolean blocked;
        GuardedCapture(JSONObject value)throws Exception{super(value.toString());}
        @Override public Object opt(String key){if(blocked)throw new AssertionError("UI re-read capture metadata: "+key);return super.opt(key);}
        @Override public Object get(String key){if(blocked)throw new AssertionError("UI re-read capture metadata: "+key);return super.get(key);}
    }
    static void preparedRows()throws Exception{
        JSONObject first=course("alpha.test").put("existingCourses",new JSONArray()
            .put(new JSONObject().put("id","saved-course").put("name","已有数学"))
            .put(JSONObject.NULL).put(new JSONObject().put("name","missing ID")));
        GuardedCapture guarded=new GuardedCapture(first);
        JSONObject second=course("beta.test");
        List<JSONObject> captures=Arrays.asList(guarded,second);
        CourseImportCatalog.SearchResult result=new CourseImportCatalog.SearchResult(captures,"alpha.test");
        String id=WebCourseImport.identity(guarded),otherID=WebCourseImport.identity(second);
        guarded.blocked=true;
        CourseImportCatalog.Row row=result.row(CourseImportCatalog.page(result.matches,0).get(0));
        check(row.name.equals("数学 Algebra")&&row.lessonCount==2&&row.website.equals("alpha.test"),"Prepared card lost display fields");
        check(row.problem==null&&row.id.equals(id),"Prepared card changed selection identity or validity");
        check(row.existing.size()==1&&row.existing.get(0).id.equals("saved-course")&&row.existing.get(0).name.equals("已有数学"),"Prepared existing-plan navigation lost or retained malformed targets");
        Set<String> selected=new HashSet<>(Arrays.asList(id,otherID,"missing"));
        check(result.summary(selected).contains("显示 1 / 2 门 · 已选 2 门")&&result.summary(selected).contains("其中 1 门在筛选之外"),"Cached summary lost hidden selections");
        selected.remove(otherID);check(!result.summary(selected).contains("筛选之外"),"Cached summary did not follow new selection");
        check(selected.contains("missing"),"Cached summary mutated selection");
        try{row.existing.clear();throw new AssertionError("Prepared row navigation can be mutated");}catch(UnsupportedOperationException expected){checks++;}
        for(Object lessons:new Object[]{null,JSONObject.NULL,"broken",new JSONArray().put(JSONObject.NULL).put(42)}){
            JSONObject invalid=course("alpha.test");if(lessons==null)invalid.remove("lessons");else invalid.put("lessons",lessons);
            CourseImportCatalog.SearchResult review=new CourseImportCatalog.SearchResult(Collections.singletonList(invalid),"algebra");
            check(review.matches.size()==1&&review.row(invalid).problem!=null,"Incomplete course disappeared from search or looked complete");
            check(review.selectableIDs.isEmpty()&&review.groups.isEmpty(),"Malformed lessons entered batch selection");
        }
        JSONObject refused=course("alpha.test").put("refusal",JSONObject.NULL);
        CourseImportCatalog.SearchResult review=new CourseImportCatalog.SearchResult(Collections.singletonList(refused),"");
        check(review.row(refused).problem!=null&&!review.row(refused).problem.isEmpty()&&review.selectableIDs.isEmpty(),"Null refusal accidentally enabled import");
        java.util.concurrent.atomic.AtomicInteger polls=new java.util.concurrent.atomic.AtomicInteger();
        JSONObject many=course("alpha.test");JSONArray lessons=new JSONArray();
        for(int i=0;i<500;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","数学"));
        many.put("lessons",lessons);
        try{
            BackgroundCancellation.call(()->polls.incrementAndGet()>=10,()->new CourseImportCatalog.SearchResult(Collections.singletonList(many),"数学"));
            throw new AssertionError("Obsolete lesson search did not stop");
        }catch(java.util.concurrent.CancellationException expected){check(polls.get()==10,"Search cancellation was delayed until all lessons finished");}
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
        for(int i=250;i<253;i++)large.add(course("example.test").put("name","课程"+i).put("packageID","generic:"+i));
        List<JSONObject> filtered=CourseImportCatalog.filtered(large,"");
        check(CourseImportCatalog.pageCount(filtered)==6,"Catalog page count wrong");
        check(CourseImportCatalog.page(filtered,0).size()==50&&CourseImportCatalog.page(filtered,1).get(0)==large.get(50),"Page boundary changed order");
        check(CourseImportCatalog.page(filtered,Integer.MAX_VALUE).size()==3,"Last page overflow or clamp failed");
        check(CourseImportCatalog.page(filtered,Integer.MIN_VALUE).get(0)==large.get(0),"Negative page did not clamp");
        check(CourseImportCatalog.page(Collections.emptyList(),99).isEmpty()&&CourseImportCatalog.pageCount(Collections.emptyList())==1,"Empty page failed");
        List<JSONObject> copy=CourseImportCatalog.page(filtered,0);copy.clear();check(filtered.size()==253,"Page view mutated complete results");
        Set<String> acrossPages=new HashSet<>();for(int page:new int[]{0,2})for(JSONObject item:CourseImportCatalog.page(filtered,page))acrossPages.add(WebCourseImport.identity(item));
        check(acrossPages.size()==100&&CourseImportCatalog.summary(large,acrossPages,filtered).contains("已选 100 门"),"Cross-page selection count lost");
        check(CourseImportCatalog.matchingSelectableIDs(large,"").size()==253,"Bulk selection was limited to a page");
        check(CourseImportCatalog.filtered(large,"课程137").size()==1&&CourseImportCatalog.pageCount(CourseImportCatalog.filtered(large,"课程137"))==1,"Search did not reduce pages");
        Deque<Runnable> background=new ArrayDeque<>(),ui=new ArrayDeque<>();
        List<CourseImportCatalog.SearchResult> delivered=new ArrayList<>();List<Exception> failures=new ArrayList<>();
        LatestWork<CourseImportCatalog.SearchResult> work=new LatestWork<>(background::add,ui::add,delivered::add,failures::add);
        work.submit(()->new CourseImportCatalog.SearchResult(large,"课程137"));background.remove().run();
        work.submit(()->new CourseImportCatalog.SearchResult(large,"课程252"));background.remove().run();
        ui.remove().run();check(delivered.isEmpty(),"Old search result replaced the latest query");
        ui.remove().run();CourseImportCatalog.SearchResult latest=delivered.get(0);
        check(latest.matches.size()==1&&latest.matches.get(0)==large.get(252),"Latest result omitted its final-page course");
        check(latest.isCurrent(large,"课程252")&&!latest.isCurrent(large,"课程137"),"Query identity accepted stale results");
        List<JSONObject> refreshed=new ArrayList<>(large);
        check(!latest.isCurrent(refreshed,"课程252"),"Refreshed catalog reused the old search result");
        work.submit(()->new CourseImportCatalog.SearchResult(refreshed,"课程137"));background.remove().run();work.close();ui.remove().run();
        check(delivered.size()==1&&failures.isEmpty(),"Closed import search updated the screen");
        List<JSONObject> folders=new ArrayList<>();
        for(int i=0;i<65;i++)for(int j=0;j<2;j++)folders.add(course("pan.quark.cn").put("packageID","quark:folder:"+i+":"+j)
            .put("netdisk",new JSONObject().put("folderPath","组"+i+"/课程"+j)));
        JSONObject refused=course("pan.quark.cn").put("packageID","quark:refused").put("refusal","incomplete")
            .put("netdisk",new JSONObject().put("folderPath","组42/不完整"));folders.add(refused);
        CourseImportCatalog.SearchResult grouped=new CourseImportCatalog.SearchResult(folders,"");
        check(grouped.groups.size()==66&&grouped.selectableIDs.size()==130,"Directory grouping included incomplete captures or omitted valid courses");
        check(CourseImportCatalog.groupPageCount(grouped.groups)==4&&CourseImportCatalog.groupPage(grouped.groups,0).size()==20,"Directory controls were not bounded");
        check(CourseImportCatalog.groupPage(grouped.groups,Integer.MAX_VALUE).size()==6&&CourseImportCatalog.groupPage(grouped.groups,Integer.MIN_VALUE).get(0).path.isEmpty(),"Directory page bounds failed");
        CourseImportCatalog.SearchResult narrow=new CourseImportCatalog.SearchResult(folders,"组42");
        check(narrow.groups.size()==2&&narrow.selectableIDs.size()==2&&narrow.groups.get(1).path.equals("组42"),"Directory batches escaped the search scope");
        Set<String> review=new HashSet<>(Collections.singleton(WebCourseImport.identity(folders.get(0))));
        review.addAll(narrow.groups.get(1).ids);check(review.size()==3,"Directory batch lost a selection outside the search");
        review.removeAll(narrow.groups.get(1).ids);check(review.equals(Collections.singleton(WebCourseImport.identity(folders.get(0)))),"Removing a directory batch cleared hidden choices");
        check(CourseImportCatalog.groupPage(Collections.emptyList(),99).isEmpty(),"Empty directory page failed");
        try{grouped.groups.get(0).ids.clear();throw new AssertionError("Cached group identities are mutable");}catch(UnsupportedOperationException expected){checks++;}
        JSONObject nested=course("pan.quark.cn").put("netdisk",new JSONObject().put("folderPath","/资料//高数/基础班"));
        List<CourseImportCatalog.Group> ancestors=CourseImportCatalog.groups(Collections.singletonList(nested));
        check(ancestors.size()==3&&ancestors.get(2).path.equals("资料/高数"),"Nested directory ancestors or redundant separators were mishandled");
        preparedRows();
        System.out.println("Course import catalog: "+checks+" checks passed");
    }
}
