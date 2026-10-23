package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;

/** Behavioral checks plus synthetic fixtures compared against the Swift planner. */
public final class SchedulePreferenceTests {
    static final LocalDate TODAY=LocalDate.of(2026,9,14);
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject state(int[] amounts,int days)throws Exception{
        JSONObject state=PlannerTests.empty();state.getJSONObject("settings").put("availability",StudySettingsTests.windows(480,1080));
        for(int c=0;c<amounts.length;c++){
            JSONObject course=PlannerTests.course("模拟课程"+c,amounts[c],TODAY,TODAY.plusDays(days-1),60)
                .put("id",Planner.stableID("preference-course-"+c)).put("type","不定时录播课程").put("color","blue").put("notes","");
            JSONArray lessons=new JSONArray();for(int i=0;i<amounts[c]/60;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","模拟课节").put("durationMinutes",60));
            course.put("manualLessons",lessons);state.getJSONArray("courses").put(course);
        }
        return state;
    }
    static void order(JSONObject state,int... rules)throws Exception{
        JSONObject levels=new JSONObject();for(int i=0;i<rules.length;i++)levels.put(SchedulePriorities.RULES[rules[i]],i+1);
        state.getJSONObject("settings").put("schedulingRuleLevels",levels);
    }
    static void replan(JSONObject state)throws Exception{Planner.replan(state,Planner.at(TODAY,480));}
    static int[] loads(JSONObject state,int days)throws Exception{
        int[] loads=new int[days];for(JSONObject task:Planner.list(state.getJSONArray("tasks")))
            for(int d=0;d<days;d++)if(Planner.day(task.getDouble("start")).equals(TODAY.plusDays(d)))loads[d]+=task.getInt("durationMinutes");return loads;
    }
    static void intact(JSONObject state)throws Exception{
        check(state.getJSONArray("androidRisks").length()==0,"Lost feasible learning amount");
        PlannerTests.invariant(state,Planner.at(TODAY,480));
        for(JSONObject course:Planner.list(state.getJSONArray("courses"))){
            int amount=0;List<String> lessons=new ArrayList<>();
            for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(task.getString("courseID").equals(course.getString("id"))){amount+=task.getInt("durationMinutes");lessons.add(task.optString("lessonID"));}
            check(amount==Planner.remaining(state,course),"Changed a course's booked amount");
            JSONArray source=course.getJSONArray("manualLessons");List<String> expected=new ArrayList<>();for(int i=0;i<source.length();i++)expected.add(source.getJSONObject(i).getString("id"));
            check(lessons.equals(expected),"Changed whole-lesson sequence");
        }
    }
    static void behavior()throws Exception{
        JSONObject state=state(new int[]{600},5);replan(state);
        check(Arrays.equals(loads(state,5),new int[]{120,120,120,120,120}),"Default must balance whole lessons too");intact(state);
        state=state(new int[]{120,120,120},3);order(state,3,0,1,2);replan(state);
        check(Arrays.equals(loads(state,3),new int[]{120,120,120}),"Balance must compare combined daily loads");intact(state);
        state=state(new int[]{240},4);state.getJSONArray("courses").getJSONObject(0).put("dailyStudyWeight",2);
        replan(state);check(Arrays.equals(loads(state,4),new int[]{120,120,0,0}),"Single-course diversity cancelled a default boost");intact(state);
        order(state,1,3,0,2);replan(state);check(Arrays.equals(loads(state,4),new int[]{120,120,0,0}),"Boost first did not advance lessons");intact(state);
        order(state,3,1,0,2);replan(state);check(Arrays.equals(loads(state,4),new int[]{60,60,60,60}),"Lower boost overrode higher balance");intact(state);
        state=state(new int[]{180,180},1);state.getJSONArray("courses").getJSONObject(0).put("priority",3);state.getJSONArray("courses").getJSONObject(1).put("priority",1);
        order(state,2,0,1,3);replan(state);List<JSONObject> tasks=Planner.list(state.getJSONArray("tasks"));String high=state.getJSONArray("courses").getJSONObject(0).getString("id");
        for(int i=0;i<3;i++)check(tasks.get(i).getString("courseID").equals(high),"Priority first must book high priority first");intact(state);
        state.getJSONObject("settings").remove("schedulingRuleLevels");replan(state);tasks=Planner.list(state.getJSONArray("tasks"));
        for(int i=1;i<tasks.size();i++)check(!tasks.get(i).getString("courseID").equals(tasks.get(i-1).getString("courseID")),"Diversity first must alternate different priorities");intact(state);
        state=state(new int[]{480,240,240},4);state.getJSONArray("courses").getJSONObject(0).put("deadline",Planner.at(TODAY,0));replan(state);
        for(int d=1;d<4;d++)check(PlannerTests.owners(state,TODAY.plusDays(d)).size()==2,"One tight deadline suppressed later diversity");intact(state);
        // No empty destination exists; a swap must exchange intact ordered lessons.
        state=state(new int[]{120,120},2);List<JSONObject> courses=Planner.list(state.getJSONArray("courses"));
        List<Planner.Day> days=new ArrayList<>();List<JSONObject> input=new ArrayList<>();
        for(int d=0;d<2;d++)days.add(new Planner.Day(TODAY.plusDays(d),Collections.singletonList(new Planner.Span(Planner.at(TODAY.plusDays(d),480),Planner.at(TODAY.plusDays(d),615)))));
        for(int i=0;i<4;i++)input.add(Planner.task(courses.get(i/2).getString("id"),Planner.at(TODAY.plusDays(i/2),480+i%2*75),60).put("lessonID","lesson"+(i%2)));
        SchedulePreferenceOptimizer.Outcome result=SchedulePreferenceOptimizer.optimize(input,courses,days,new SchedulePriorities(state.getJSONObject("settings")));
        check(result.improved&&result.tasks.size()==4,"Full-day swap failed");
        for(int d=0;d<2;d++){Set<String> owners=new HashSet<>();for(JSONObject task:result.tasks)if(Planner.day(task.getDouble("start")).equals(TODAY.plusDays(d)))owners.add(task.getString("courseID"));check(owners.size()==2,"Full day remains monopolized");}
    }
    static void permutations(List<int[]> out,int[] order,int depth){
        if(depth==order.length){out.add(order.clone());return;}
        for(int i=depth;i<order.length;i++){int temp=order[i];order[i]=order[depth];order[depth]=temp;permutations(out,order,depth+1);temp=order[i];order[i]=order[depth];order[depth]=temp;}
    }
    static void parity()throws Exception{
        List<int[]> orders=new ArrayList<>();permutations(orders,new int[]{0,1,2,3},0);JSONArray fixtures=new JSONArray();
        for(int[] rules:orders){
            JSONObject state=state(new int[]{180,240,120},4);order(state,rules);
            int[][] durations={{90,30,60},{60,90,30,60},{30,60,30}};
            for(int c=0;c<3;c++){
                JSONObject course=state.getJSONArray("courses").getJSONObject(c).put("priority",new int[]{3,1,2}[c]);
                if(c==0)course.put("dailyStudyWeight",2).put("deadline",Planner.at(TODAY.plusDays(2),0));
                if(c==2)course.put("startDate",Planner.at(TODAY.plusDays(1),0));
                JSONArray lessons=new JSONArray();for(int i=0;i<durations[c].length;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","模拟课节").put("durationMinutes",durations[c][i]));
                course.put("manualLessons",lessons);
            }
            state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.stableID("preference-fixed")).put("title","模拟固定事项")
                .put("startMinute",540).put("endMinute",600).put("startDate",Planner.at(TODAY.plusDays(1),0)).put("endDate",Planner.at(TODAY.plusDays(1),0)).put("weekdays",new JSONArray()));
            JSONObject before=new JSONObject(state.toString());replan(state);intact(state);
            JSONArray tasks=new JSONArray(state.getJSONArray("tasks").toString());
            replan(state);check(tasks.similar(state.getJSONArray("tasks")),"Non-deterministic rule permutation: "+Arrays.toString(rules));
            fixtures.put(new JSONObject().put("state",before).put("tasks",tasks));
        }
        Files.write(Paths.get("Android/build/tests/schedule-preference-parity.json"),fixtures.toString().getBytes(StandardCharsets.UTF_8));
    }
    static JSONObject denseState()throws Exception{
        JSONObject state=state(new int[0],21);state.getJSONObject("settings").put("availability",StudySettingsTests.windows(480,1200));
        int[][] lengths={
            {45,20,70,15,35,55,25,60,30,50,40,65,20,55,35,45,30,60,25,50},
            new int[20],new int[30],new int[18]
        };
        for(int i=0;i<20;i++)lengths[1][i]=new int[]{150,165,135,180}[i%4];
        for(int i=0;i<30;i++)lengths[2][i]=new int[]{45,65,35}[i%3];
        for(int i=0;i<18;i++)lengths[3][i]=new int[]{75,95,55}[i%3];
        for(int c=0;c<4;c++){
            int amount=0;for(int size:lengths[c])amount+=size;
            JSONObject course=PlannerTests.course("合成课程"+c,amount,TODAY,TODAY.plusDays(new int[]{7,17,20,20}[c]),60)
                .put("id",Planner.stableID("dense-course-"+c)).put("type","不定时录播课程").put("priority",c==0?2:3).put("color","blue").put("notes","");
            JSONArray lessons=new JSONArray();for(int i=0;i<lengths[c].length;i++)lessons.put(new JSONObject().put("id","unit"+i).put("name","合成课节").put("durationMinutes",lengths[c][i]));
            course.put("manualLessons",lessons);state.getJSONArray("courses").put(course);
        }
        state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.stableID("dense-fixed-A")).put("title","合成固定事项甲")
            .put("startMinute",540).put("endMinute",660).put("startDate",Planner.at(TODAY,0)).put("endDate",Planner.at(TODAY.plusDays(20),0)).put("weekdays",new JSONArray("[2,4,6]")));
        state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.stableID("dense-fixed-B")).put("title","合成固定事项乙")
            .put("startMinute",480).put("endMinute",1020).put("startDate",Planner.at(TODAY,0)).put("endDate",Planner.at(TODAY.plusDays(20),0)).put("weekdays",new JSONArray("[3]")));
        return state;
    }
    static void denseParity()throws Exception{
        JSONArray fixtures=new JSONArray();
        for(boolean balanced:new boolean[]{false,true}){
            JSONObject state=denseState();if(balanced)order(state,3,0,1,2);
            JSONObject before=new JSONObject(state.toString());replan(state);intact(state);
            int diverse=0;for(int d=0;d<7;d++)if(PlannerTests.owners(state,TODAY.plusDays(d)).size()>=3)diverse++;
            if(!balanced)check(diverse>=5,"Dense queues still monopolize early days: "+diverse);
            fixtures.put(new JSONObject().put("state",before).put("tasks",new JSONArray(state.getJSONArray("tasks").toString())));
        }
        Files.write(Paths.get("Android/build/tests/dense-preference-parity.json"),fixtures.toString().getBytes(StandardCharsets.UTF_8));
    }
    /** Synthetic whole-lesson queues for the joint-repair experiments. */
    static JSONObject jointState(int[][] lengths,int days,int end)throws Exception{
        JSONObject state=state(new int[0],days);state.getJSONObject("settings").put("availability",StudySettingsTests.windows(480,end));
        for(int c=0;c<lengths.length;c++){
            int amount=0;for(int size:lengths[c])amount+=size;
            JSONObject course=PlannerTests.course("合成科目"+c,amount,TODAY,TODAY.plusDays(days-1),60)
                .put("id",Planner.stableID("experiment-course-"+c)).put("type","不定时录播课程").put("color","blue").put("notes","");
            JSONArray lessons=new JSONArray();for(int i=0;i<lengths[c].length;i++)lessons.put(new JSONObject().put("id","unit"+i).put("name","合成课节").put("durationMinutes",lengths[c][i]));
            course.put("manualLessons",lessons);state.getJSONArray("courses").put(course);
        }
        return state;
    }
    /** Replan once more and require an identical task list. */
    static JSONArray stable(JSONObject state,String label)throws Exception{
        JSONArray snapshot=new JSONArray(state.getJSONArray("tasks").toString());replan(state);
        check(snapshot.similar(state.getJSONArray("tasks")),label+" replan is not deterministic");return snapshot;
    }
    static void jointBehavior()throws Exception{
        // tight-6: single moves and two-lesson swaps stalled at three mixed days; the
        // joint repair must mix all four days with no same-subject neighbour.
        JSONObject state=jointState(new int[][]{{75,75,60},{90,90,75},{30,60,30,30}},4,675);
        replan(state);intact(state);int mixed=0;
        for(int d=0;d<4;d++){
            List<JSONObject> row=PlannerTests.dayTasks(state,TODAY.plusDays(d));
            if(PlannerTests.owners(state,TODAY.plusDays(d)).size()>=2)mixed++;
            for(int i=1;i<row.size();i++)check(!row.get(i).getString("courseID").equals(row.get(i-1).getString("courseID")),"tight6 keeps one subject adjacent on day "+d);
        }
        check(mixed==4,"tight6 left a single-subject day: "+mixed);stable(state,"tight6");
        // tight-1: per-day coverage C(min(3,subjects),2) must reach 8 over four days.
        state=jointState(new int[][]{{75,90,30,45},{45,60,75},{60,75,30}},4,675);
        replan(state);intact(state);int coverage=0;
        for(int d=0;d<4;d++){int count=Math.min(3,PlannerTests.owners(state,TODAY.plusDays(d)).size());coverage+=count*(count-1)/2;}
        check(coverage==8,"tight1 coverage changed: "+coverage);stable(state,"tight1");
        // triple: the default order must still keep a full 180-minute course-0 day.
        state=jointState(new int[][]{{60,60,60},{60,60,60},{60,60}},3,750);
        state.getJSONArray("courses").getJSONObject(0).put("dailyStudyWeight",3);
        replan(state);intact(state);String boosted=state.getJSONArray("courses").getJSONObject(0).getString("id");int total=0;
        for(JSONObject task:PlannerTests.dayTasks(state,TODAY))if(task.getString("courseID").equals(boosted))total+=task.getInt("durationMinutes");
        check(total==180,"triple default boost lost the first-subject day: "+total);stable(state,"triple");
    }
    static JSONObject jointFixture(JSONObject state,String label)throws Exception{
        JSONObject before=new JSONObject(state.toString());replan(state);intact(state);
        return new JSONObject().put("state",before).put("tasks",stable(state,label));
    }
    static void jointParity()throws Exception{
        List<int[]> orders=new ArrayList<>();permutations(orders,new int[]{0,1,2,3},0);JSONArray fixtures=new JSONArray();
        int[][][] lengths={{{75,75,60},{90,90,75},{30,60,30,30}},{{75,90,30,45},{45,60,75},{60,75,30}}};
        for(int[][] values:lengths)for(int[] rules:orders){JSONObject state=jointState(values,4,675);order(state,rules);fixtures.put(jointFixture(state,"joint rule order "+Arrays.toString(rules)));}
        JSONObject triple=jointState(new int[][]{{60,60,60},{60,60,60},{60,60}},3,750);
        triple.getJSONArray("courses").getJSONObject(0).put("dailyStudyWeight",3);fixtures.put(jointFixture(triple,"joint default triple"));
        check(fixtures.length()==49,"Joint fixture count changed: "+fixtures.length());
        Files.write(Paths.get("Android/build/tests/joint-preference-parity.json"),fixtures.toString().getBytes(StandardCharsets.UTF_8));
    }
    public static void main(String[] args)throws Exception{behavior();parity();denseParity();jointBehavior();jointParity();System.out.println("PASS "+checks+" preference checks, 24 rule permutations, 2 dense and 49 joint cross-platform fixtures");}
}
