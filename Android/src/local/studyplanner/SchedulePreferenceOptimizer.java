package local.studyplanner;

import org.json.JSONObject;
import java.util.*;

/** Bounded, deterministic, whole-plan preference search; never removes or splits booked work. */
final class SchedulePreferenceOptimizer {
    static final class Outcome {
        final List<JSONObject> tasks;
        final boolean improved;
        Outcome(List<JSONObject> tasks,boolean improved){this.tasks=tasks;this.improved=improved;}
    }
    static Outcome optimize(List<JSONObject> tasks,List<JSONObject> courses,List<Planner.Day> days,
                            SchedulePriorities priorities)throws Exception{
        if(tasks.isEmpty()||days.isEmpty())return new Outcome(tasks,false);
        return new Search(tasks,courses,days,priorities).run();
    }
    private static final class Plan {
        final List<List<Integer>> rows;
        final double[] starts,score;
        Plan(List<List<Integer>> rows,double[] starts,double[] score){this.rows=rows;this.starts=starts;this.score=score;}
    }
    private static final class Search {
        final List<JSONObject> tasks,courses;
        final List<Planner.Day> days;
        final SchedulePriorities priorities;
        final int[] owners,sizes;
        final boolean[][] allowed;
        final double[][] targets;
        final List<List<Integer>> initialRows=new ArrayList<>();
        int budget;

        Search(List<JSONObject> input,List<JSONObject> courses,List<Planner.Day> days,
               SchedulePriorities priorities){
            this.tasks=new ArrayList<>(input);
            this.tasks.sort(Comparator.comparingDouble((JSONObject t)->t.optDouble("start"))
                .thenComparing(t->t.optString("courseID")));
            this.courses=new ArrayList<>(courses);
            this.courses.sort(Comparator.comparing(c->c.optString("id")));
            this.days=days;this.priorities=priorities;
            owners=new int[tasks.size()];sizes=new int[tasks.size()];
            allowed=new boolean[courses.size()][days.size()];
            targets=new double[courses.size()][days.size()];
            Map<String,Integer> indices=new HashMap<>();
            for(int c=0;c<this.courses.size();c++){
                indices.put(this.courses.get(c).optString("id"),c);
                for(int d=0;d<days.size();d++)allowed[c][d]=Planner.eligible(this.courses.get(c),days.get(d).d);
            }
            Map<java.time.LocalDate,Integer> dayIndices=new HashMap<>();
            for(int d=0;d<days.size();d++){initialRows.add(new ArrayList<>());dayIndices.put(days.get(d).d,d);}
            for(int t=0;t<tasks.size();t++){
                owners[t]=indices.get(tasks.get(t).optString("courseID"));sizes[t]=tasks.get(t).optInt("durationMinutes");
                initialRows.get(dayIndices.get(Planner.day(tasks.get(t).optDouble("start")))).add(t);
            }
            for(int c=0;c<this.courses.size();c++){
                int shortest=Integer.MAX_VALUE;double amount=0;
                for(int t=0;t<tasks.size();t++)if(owners[t]==c){shortest=Math.min(shortest,sizes[t]);amount+=sizes[t];}
                if(shortest==Integer.MAX_VALUE)continue;
                List<Integer> learnable=new ArrayList<>();
                for(int d=0;d<days.size();d++)if(allowed[c][d]){
                    for(Planner.Span span:days.get(d).free)if(span.b-span.a>=shortest*60.0){learnable.add(d);break;}
                }
                double target=amount*Planner.dailyWeight(this.courses.get(c))/Math.max(1,learnable.size()),remaining=amount;
                for(int d:learnable){targets[c][d]=Math.min(remaining,target);remaining-=targets[c][d];}
            }
            budget=Math.max(32,Math.min(12_000,6_000_000/Math.max(1,tasks.size()+days.size()*courses.size())));
        }
        static boolean better(double[] a,double[] b){
            for(int i=0;i<a.length;i++)if(Math.abs(a[i]-b[i])>0.000001)return a[i]<b[i];
            return false;
        }
        double[] score(List<List<Integer>> rows,double[] starts){
            double[][] loads=new double[courses.size()][days.size()];double[] totals=new double[days.size()],seen=new double[courses.size()];
            double coverage=0,earlyCoverage=0,repetition=0,inversion=0,early=0;
            for(int d=0;d<days.size();d++){
                Set<Integer> present=new HashSet<>();int previous=-1;double repeats=0;
                for(int t:rows.get(d)){
                    int c=owners[t];double size=sizes[t];loads[c][d]+=size;totals[d]+=size;present.add(c);
                    if(previous==c)repeats++;previous=c;
                    for(int other=0;other<courses.size();other++)if(courses.get(c).optInt("priority")>courses.get(other).optInt("priority"))
                        inversion+=seen[other]*size*(courses.get(c).optInt("priority")-courses.get(other).optInt("priority"));
                    seen[c]+=size;early+=(starts[t]-Planner.at(days.get(0).d,0))/60*size;
                }
                double count=Math.min(3,present.size()),value=count*(count-1)/2;
                coverage+=value;earlyCoverage+=value*(days.size()-d);
                if(present.size()>=2)repetition+=repeats;
            }
            double boost=0,tripleBoost=0,balanced=0,courseBalance=0;
            for(int d=0;d<days.size();d++){
                balanced+=totals[d]*totals[d];
                for(int c=0;c<courses.size();c++){
                    courseBalance+=loads[c][d]*loads[c][d];double weight=Planner.dailyWeight(courses.get(c));
                    if(weight>1){double difference=loads[c][d]-targets[c][d];boost+=difference*difference;if(weight==3)tripleBoost+=difference*difference;}
                }
            }
            List<Double> values=new ArrayList<>();if(priorities.usesDefaultOrder())values.add(tripleBoost);
            for(int rule:priorities.order)switch(rule){
                case 0:values.add(-coverage);values.add(-earlyCoverage);values.add(repetition);break;
                case 1:values.add(boost);break;
                case 2:values.add(inversion);break;
                case 3:values.add(balanced);values.add(courseBalance);break;
            }
            values.add(early);double[] result=new double[values.size()];for(int i=0;i<result.length;i++)result[i]=values.get(i);return result;
        }
        Plan pack(List<List<Integer>> rows){
            budget--;double[] starts=new double[tasks.size()];double cursor=Double.NEGATIVE_INFINITY;
            int[] lastLesson=new int[courses.size()];Arrays.fill(lastLesson,-1);
            for(int d=0;d<days.size();d++){
                int window=0;
                for(int t:rows.get(d)){
                    int c=owners[t];if(!allowed[c][d])return null;
                    if(tasks.get(t).has("lessonID")){if(t<=lastLesson[c])return null;lastLesson[c]=t;}
                    double seconds=sizes[t]*60.0;List<Planner.Span> spans=days.get(d).free;
                    while(window<spans.size()&&Math.max(cursor,spans.get(window).a)+seconds>spans.get(window).b)window++;
                    if(window>=spans.size())return null;
                    starts[t]=Math.max(cursor,spans.get(window).a);cursor=starts[t]+seconds+Planner.BREAK_SECONDS;
                }
            }
            return new Plan(rows,starts,score(rows,starts));
        }
        List<List<Integer>> copyRows(List<List<Integer>> rows,int a,int b){
            List<List<Integer>> copy=new ArrayList<>(rows);copy.set(a,new ArrayList<>(rows.get(a)));
            if(a!=b)copy.set(b,new ArrayList<>(rows.get(b)));return copy;
        }
        // A complete pacing candidate can move an ordered suffix together, crossing
        // plateaus that no single-lesson relocation could improve on its own.
        List<List<Integer>> redistributed(){
            List<List<Integer>> queues=new ArrayList<>(),rows=new ArrayList<>();
            for(int c=0;c<courses.size();c++){List<Integer> queue=new ArrayList<>();for(int t=0;t<tasks.size();t++)if(owners[t]==c)queue.add(t);queues.add(queue);}
            int[] positions=new int[courses.size()],suffix=new int[days.size()+1],lastAllowed=new int[courses.size()];
            for(int c=0;c<courses.size();c++){lastAllowed[c]=-1;for(int d=0;d<days.size();d++)if(allowed[c][d])lastAllowed[c]=d;}
            for(int d=0;d<days.size();d++)rows.add(new ArrayList<>());
            for(int d=days.size()-1;d>=0;d--){
                boolean fits=false;
                outer:for(int c=0;c<courses.size();c++)if(allowed[c][d])for(int t:queues.get(c))
                    for(Planner.Span span:days.get(d).free)if(span.b-span.a>=sizes[t]*60.0){fits=true;break outer;}
                suffix[d]=suffix[d+1]+(fits?1:0);
            }
            int remaining=0;for(int size:sizes)remaining+=size;double cursor=Double.NEGATIVE_INFINITY;
            for(int d=0;d<days.size();d++){
                double quota=(double)remaining/Math.max(1,suffix[d]);int total=0,window=0;int[] daily=new int[courses.size()];
                while(window<days.get(d).free.size()){
                    List<Integer> candidates=new ArrayList<>(),urgent=new ArrayList<>();Planner.Span span=days.get(d).free.get(window);
                    for(int c=0;c<courses.size();c++)if(allowed[c][d]&&positions[c]<queues.get(c).size()){
                        int t=queues.get(c).get(positions[c]);if(Math.max(cursor,span.a)+sizes[t]*60.0<=span.b){candidates.add(c);if(d==lastAllowed[c])urgent.add(c);}
                    }
                    if(candidates.isEmpty()){window++;continue;}
                    if(!urgent.isEmpty())candidates=urgent;else if(total>=quota)break;
                    candidates.sort((a,b)->{
                        if((daily[a]==0)!=(daily[b]==0))return daily[a]==0?-1:1;
                        int v=Integer.compare(daily[a],daily[b]);if(v!=0)return v;
                        v=Double.compare((double)positions[a]/Math.max(1,queues.get(a).size()),(double)positions[b]/Math.max(1,queues.get(b).size()));
                        return v!=0?v:Integer.compare(a,b);
                    });
                    int chosen=candidates.get(0),t=queues.get(chosen).get(positions[chosen]),size=sizes[t];
                    if(urgent.isEmpty()&&total>0&&total+size/2.0>quota)break;
                    rows.get(d).add(t);positions[chosen]++;daily[chosen]+=size;total+=size;remaining-=size;
                    cursor=Math.max(cursor,span.a)+size*60.0+Planner.BREAK_SECONDS;
                }
            }
            return remaining==0?rows:initialRows;
        }
        List<List<Integer>> interleaved(List<List<Integer>> rows){
            boolean diversityFirst=priorities.order.indexOf(0)<priorities.order.indexOf(2);
            List<List<Integer>> result=new ArrayList<>();
            for(List<Integer> row:rows){
                List<List<Integer>> queues=new ArrayList<>();for(int c=0;c<courses.size();c++){List<Integer> queue=new ArrayList<>();for(int t:row)if(owners[t]==c)queue.add(t);queues.add(queue);}
                List<Integer> output=new ArrayList<>();Set<Integer> present=new HashSet<>();int previous=-1;
                while(output.size()<row.size()){
                    List<Integer> candidates=new ArrayList<>();for(int c=0;c<courses.size();c++)if(!queues.get(c).isEmpty())candidates.add(c);
                    final int prev=previous;
                    candidates.sort((a,b)->{
                        int priority=Integer.compare(courses.get(b).optInt("priority"),courses.get(a).optInt("priority"));
                        if(!diversityFirst&&priority!=0)return priority;
                        if(present.contains(a)!=present.contains(b))return present.contains(a)?1:-1;
                        if((prev==a)!=(prev==b))return prev==a?1:-1;
                        return priority!=0?priority:Integer.compare(queues.get(a).get(0),queues.get(b).get(0));
                    });
                    int chosen=candidates.get(0);output.add(queues.get(chosen).remove(0));present.add(chosen);previous=chosen;
                }
                result.add(output);
            }
            return result;
        }
        Outcome run()throws Exception{
            double[] baseline=new double[tasks.size()];for(int t=0;t<tasks.size();t++)baseline[t]=tasks.get(t).optDouble("start");
            double[] baselineScore=score(initialRows,baseline);Plan current=new Plan(initialRows,baseline,baselineScore),compact=pack(initialRows);
            if(compact!=null&&better(compact.score,current.score))current=compact;
            List<List<Integer>> paced=redistributed();
            for(List<List<Integer>> rows:Arrays.asList(interleaved(current.rows),paced,interleaved(paced))){
                Plan trial=pack(rows);if(trial!=null&&better(trial.score,current.score))current=trial;
            }
            boolean changed=true;
            while(changed&&budget>0){
                changed=false;
                int moveFloor=budget/2; // Leave attempts for swaps when full days reject one-way moves.
                move:for(int source=0;source<days.size();source++){
                    for(int position=0;position<current.rows.get(source).size();position++){
                        int t=current.rows.get(source).get(position),c=owners[t];
                        for(int target=0;target<days.size();target++)if(allowed[c][target]){
                            int count=current.rows.get(target).size()-(source==target?1:0);
                            for(int insertion=0;insertion<=count;insertion++){
                                if(budget<=moveFloor)break move;if(source==target&&insertion==position)continue;
                                List<List<Integer>> rows=copyRows(current.rows,source,target);rows.get(source).remove(position);rows.get(target).add(insertion,t);
                                Plan trial=pack(rows);if(trial!=null&&better(trial.score,current.score)){current=trial;changed=true;break move;}
                            }
                        }
                    }
                }
                if(changed)continue;
                // Swaps unlock completely full days; unequal lessons are repacked intact.
                swap:for(int a=0;a<days.size();a++){
                    for(int ai=0;ai<current.rows.get(a).size();ai++){
                        int first=current.rows.get(a).get(ai);
                        for(int b=a;b<days.size();b++)for(int bi=0;bi<current.rows.get(b).size();bi++){
                            if(a==b&&bi<=ai)continue;int second=current.rows.get(b).get(bi);
                            if(owners[first]==owners[second]||!allowed[owners[first]][b]||!allowed[owners[second]][a])continue;
                            if(budget<=0)break swap;
                            List<List<Integer>> rows=copyRows(current.rows,a,b);rows.get(a).set(ai,second);rows.get(b).set(bi,first);
                            Plan trial=pack(rows);if(trial!=null&&better(trial.score,current.score)){current=trial;changed=true;break swap;}
                        }
                    }
                }
            }
            List<JSONObject> output=new ArrayList<>();for(int t=0;t<tasks.size();t++)output.add(new JSONObject(tasks.get(t).toString()).put("start",current.starts[t]));
            output.sort(Comparator.comparingDouble(t->t.optDouble("start")));
            return new Outcome(output,better(current.score,baselineScore));
        }
    }
}
