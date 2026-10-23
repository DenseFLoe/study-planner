package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;

/** Synthetic witnesses only; never opens a database, UI or network connection. */
public final class JointFloatingSearchTests {
    static final LocalDate DAY=LocalDate.of(2026,9,14);
    static final int BASE=ScheduleFeasibilitySearch.minute(Planner.at(DAY,0));
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject event(int index,int start,int end,int minutes)throws Exception{
        LocalDate day=DAY.plusDays(start/1440);
        return new JSONObject().put("id",Planner.stableID("joint-floating-"+index)).put("title","合成浮动"+index)
            .put("startMinute",start%1440).put("endMinute",end-start/1440*1440).put("floatingDurationMinutes",minutes)
            .put("startDate",Planner.at(day,0)).put("endDate",Planner.at(day,0)).put("weekdays",new JSONArray()).put("color","orange").put("notes","");
    }
    static JSONObject engineState(boolean shortEvent)throws Exception{
        JSONObject state=SchedulePreferenceTests.jointState(new int[][]{{120,90}},1,shortEvent?705:780);
        state.getJSONArray("fixedEvents").put(event(0,540,shortEvent?705:720,shortEvent?5:60));
        if(!shortEvent)state.getJSONArray("fixedEvents").put(event(1,750,780,15));
        return state;
    }
    static JSONArray engineParity()throws Exception{
        List<int[]> orders=new ArrayList<>();SchedulePreferenceTests.permutations(orders,new int[]{0,1,2,3},0);
        JSONArray rows=new JSONArray();
        for(boolean shortEvent:new boolean[]{false,true})for(int[] order:orders){
            JSONObject state=engineState(shortEvent);SchedulePreferenceTests.order(state,order);
            JSONObject before=new JSONObject(state.toString());Planner.replan(state,Planner.at(DAY,480));
            List<JSONObject> tasks=PlannerTests.sortedTasks(state);
            check(tasks.size()==2,"Joint rescue still loses a whole lesson");
            check(tasks.get(1).getDouble("start")==Planner.at(DAY,shortEvent?615:660),"Rest or floating position is wrong");
            check(PlannerTests.totalMinutes(state)==210,"Rescue changed the amount");
            check(state.getJSONArray("androidRisks").length()==0&&state.getJSONArray("androidConflicts").length()==0,"Feasible rescue keeps a shortage");
            check(state.getJSONArray("androidWarnings").length()==0,"Resolved floating failure still warns");
            JSONArray expected=new JSONArray(state.getJSONArray("tasks").toString());Planner.replan(state,Planner.at(DAY,480));
            check(expected.similar(state.getJSONArray("tasks")),"Joint rescue is not repeatable");
            rows.put(new JSONObject().put("state",before).put("tasks",expected));
        }
        return rows;
    }
    static List<ScheduleFeasibilitySearch.Window> windows(int[][] rows){
        List<ScheduleFeasibilitySearch.Window> out=new ArrayList<>();for(int[] row:rows)out.add(new ScheduleFeasibilitySearch.Window(BASE+row[0],BASE+row[1]));return out;
    }
    static boolean fits(int start,int end,int[][] windows){for(int[] w:windows)if(start>=w[0]&&end<=w[1])return true;return false;}
    static JSONObject direct(int number,int[][] lengths,int[][] study,int[][] eventWindows,int[][] events,int floor,int days)throws Exception{
        List<ScheduleFeasibilitySearch.Queue> queues=new ArrayList<>();Map<String,Integer> owners=new HashMap<>();
        for(int c=0;c<lengths.length;c++){
            JSONObject course=PlannerTests.course("合成队列",Arrays.stream(lengths[c]).sum(),DAY,DAY.plusDays(days-1),60)
                .put("id",Planner.stableID("floating-direct-course-"+c));owners.put(course.getString("id"),c);
            List<Planner.Work> work=new ArrayList<>();for(int j=0;j<lengths[c].length;j++)work.add(new Planner.Work(lengths[c][j],"unit"+j,"合成课节"));
            queues.add(new ScheduleFeasibilitySearch.Queue(course,work));
        }
        List<ScheduleFeasibilitySearch.Floating> floating=new ArrayList<>();for(int f=0;f<events.length;f++)
            floating.add(new ScheduleFeasibilitySearch.Floating(DAY.plusDays(events[f][0]/1440),event(f,events[f][0],events[f][1],events[f][2])));
        ScheduleFeasibilitySearch.Solution result=ScheduleFeasibilitySearch.find(queues,windows(study),windows(eventWindows),floating,BASE+floor,BASE);
        JSONArray tasks=new JSONArray(),starts=new JSONArray();
        if(result!=null){
            List<int[]> occupied=new ArrayList<>();int[] positions=new int[lengths.length];int lastEnd=-100000;
            for(JSONObject task:result.tasks){int c=owners.get(task.getString("courseID")),j=positions[c]++;
                int at=ScheduleFeasibilitySearch.minute(task.getDouble("start"))-BASE,n=task.getInt("durationMinutes");
                check(j<lengths[c].length&&n==lengths[c][j]&&task.getString("lessonID").equals("unit"+j),"Lost or reordered lesson "+number);
                check(at>=floor&&at>=lastEnd+15&&at+n<=days*1440&&fits(at,at+n,study),"Invalid study witness "+number);
                lastEnd=at+n;occupied.add(new int[]{at,at+n});tasks.put(new JSONArray(new int[]{c,j,at,n}));
            }
            for(int c=0;c<lengths.length;c++)check(positions[c]==lengths[c].length,"Incomplete queue "+number);
            check(result.floatingStarts.size()==events.length,"Missing or colliding event occurrence "+number);
            for(int f=0;f<events.length;f++){int at=result.floatingStarts.get(f)-BASE,n=events[f][2];
                check(at>=events[f][0]&&at+n<=events[f][1]&&fits(at,at+n,eventWindows),"Invalid event witness "+number);
                starts.put(at);occupied.add(new int[]{at,at+n});}
            occupied.sort(Comparator.comparingInt(row->row[0]));for(int i=1;i<occupied.size();i++)check(occupied.get(i)[0]>=occupied.get(i-1)[1],"Overlapping activities "+number);
        }
        check(ScheduleFeasibilitySearch.find(queues,windows(study),windows(eventWindows),floating,BASE+floor,BASE,0)==null,"Budget exhaustion returned a partial witness");
        return new JSONObject().put("number",number).put("lengths",new JSONArray(lengths)).put("study",new JSONArray(study))
            .put("eventWindows",new JSONArray(eventWindows)).put("events",new JSONArray(events)).put("floor",floor).put("days",days)
            .put("found",result!=null).put("tasks",tasks).put("floating",starts);
    }
    static JSONArray directCases()throws Exception{
        JSONArray rows=new JSONArray();
        for(int i=0;i<72;i++){
            int[][] lengths=i%2==0?new int[][]{{20+(i%4)*5,20}}:new int[][]{{20},{30+(i%3)*5}};
            int[][] study=i%3==0?new int[][]{{0,120}}:new int[][]{{0,45},{60,120}};
            int[][] slots=i%4==0?new int[][]{{0,55},{65,120}}:new int[][]{{0,120}};
            int[][] events={{(i%3)*10,70+(i%3)*10,new int[]{5,15,25}[i%3]},
                            {20+(i%4)*10,110,new int[]{5,10,20}[(i/3)%3]}};
            rows.put(direct(i,lengths,study,slots,events,i%5==0?20:0,1));
        }
        rows.put(direct(72,new int[][]{{60,60}},new int[][]{{0,120},{1440,1560}},new int[][]{{0,120},{1440,1560}},
            new int[][]{{0,90,30},{30,120,15},{1440,1530,30},{1470,1560,5}},0,2));
        rows.put(direct(73,new int[][]{{10,10}},new int[][]{{1420,1440},{1440,1480}},new int[][]{{1420,1480}},
            new int[][]{{1430,1440,5},{1440,1460,5}},1420,2));
        return rows;
    }
    public static void main(String[] args)throws Exception{
        JSONObject fixtures=new JSONObject().put("engine",engineParity()).put("direct",directCases());
        Files.write(Paths.get("Android/build/tests/joint-floating-parity.json"),fixtures.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("PASS "+checks+" joint-floating witness checks; 48 engine and 74 direct cross-platform fixtures");
    }
}
