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
        static final class BeamKey {
            final int[] positions;int day=-1,mask,previous=-1;
            BeamKey(int count){positions=new int[count];}
            BeamKey(BeamKey other){positions=other.positions.clone();day=other.day;mask=other.mask;previous=other.previous;}
            @Override public int hashCode(){return 31*(31*(31*Arrays.hashCode(positions)+day)+mask)+previous;}
            @Override public boolean equals(Object value){if(!(value instanceof BeamKey))return false;BeamKey b=(BeamKey)value;return day==b.day&&mask==b.mask&&previous==b.previous&&Arrays.equals(positions,b.positions);}
        }
        static final class BeamNode {
            final BeamKey key;final int end,task,start,parent;final double coverage,earlyCoverage,repetitions;final double[] rank;
            BeamNode(BeamKey key,int end,int task,int start,int parent,double coverage,double earlyCoverage,double repetitions,double[] rank){
                this.key=key;this.end=end;this.task=task;this.start=start;this.parent=parent;this.coverage=coverage;this.earlyCoverage=earlyCoverage;this.repetitions=repetitions;this.rank=rank;
            }
        }
        static final class QueueWindow {
            final int start,end,day;
            QueueWindow(Planner.Span span,int day){start=(int)Math.ceil(span.a/60);end=(int)Math.floor(span.b/60);this.day=day;}
        }
        boolean needsQueueReconstruction(Plan plan){
            Set<Integer> durations=new HashSet<>();for(int size:sizes)durations.add(size);
            if(courses.size()<2||tasks.size()<20||days.size()<7||durations.size()<3)return false;
            int[] lastDay=new int[courses.size()];Arrays.fill(lastDay,-1);
            for(int d=0;d<days.size();d++)for(int t:plan.rows.get(d))lastDay[owners[t]]=d;
            for(int d=0;d<days.size();d++){
                int available=0;for(int c=0;c<courses.size();c++)if(allowed[c][d]&&lastDay[c]>=d)available++;
                Set<Integer> present=new HashSet<>();for(int t:plan.rows.get(d))present.add(owners[t]);
                if(present.size()<Math.min(3,available))return true;
            }
            return false;
        }
        static boolean rankPrecedes(double[] a,double[] b){for(int i=0;i<a.length;i++)if(a[i]!=b[i])return a[i]<b[i];return false;}
        /** Retain alternative complete queue prefixes; only the normal plan score may adopt a result. */
        Plan queueBeam(boolean paceFirst){
            if(courses.size()>6||tasks.size()>600||days.size()>366)return null;
            List<List<Integer>> queues=new ArrayList<>();for(int c=0;c<courses.size();c++){List<Integer> queue=new ArrayList<>();for(int t=0;t<tasks.size();t++)if(owners[t]==c)queue.add(t);queues.add(queue);}
            List<QueueWindow> windows=new ArrayList<>();for(int d=0;d<days.size();d++)for(Planner.Span span:days.get(d).free)windows.add(new QueueWindow(span,d));
            if(windows.isEmpty()||windows.size()>1500)return null;
            int beamWidth=Math.min(32,Math.max(4,60000/Math.max(1,tasks.size()*courses.size())));
            int rest=Planner.BREAK_MINUTES;int[][] suffix=new int[courses.size()][],latest=new int[courses.size()][];
            int[] totalCapacity=new int[courses.size()],lastDay=new int[courses.size()];Arrays.fill(lastDay,-1);Set<Integer> deadlines=new TreeSet<>();
            for(int c=0;c<courses.size();c++){
                suffix[c]=new int[queues.get(c).size()+1];latest[c]=new int[queues.get(c).size()+1];Arrays.fill(latest[c],Integer.MAX_VALUE/4);
                int end=windows.get(windows.size()-1).end;
                for(int p=queues.get(c).size()-1;p>=0;p--){
                    int size=sizes[queues.get(c).get(p)];QueueWindow found=null;
                    for(int w=windows.size()-1;w>=0;w--){QueueWindow span=windows.get(w);if(allowed[c][span.day]&&Math.min(end,span.end)-size>=span.start){found=span;break;}}
                    if(found==null)return null;latest[c][p]=Math.min(end,found.end)-size;end=latest[c][p]-rest;suffix[c][p]=suffix[c][p+1]+size;
                }
                for(QueueWindow w:windows)if(allowed[c][w.day])totalCapacity[c]+=w.end-w.start;
                for(int d=0;d<days.size();d++)if(allowed[c][d])lastDay[c]=d;
                if(lastDay[c]>=0)deadlines.add(lastDay[c]);
            }
            class Guidance {
                Double assessment(BeamKey key,int end){
                    for(int c=0;c<courses.size();c++)if(key.positions[c]<queues.get(c).size()&&end+rest>latest[c][key.positions[c]])return null;
                    for(int cutoff:deadlines){
                        int required=0,blocks=0,capacity=0,regions=0;
                        for(int c=0;c<courses.size();c++)if(lastDay[c]<=cutoff){required+=suffix[c][key.positions[c]];blocks+=queues.get(c).size()-key.positions[c];}
                        for(QueueWindow w:windows)if(w.day<=cutoff&&w.end>end){capacity+=w.end-Math.max(end,w.start);regions++;}
                        if(required+rest*Math.max(0,blocks-regions)>capacity)return null;
                    }
                    double pace=0;
                    for(int c=0;c<courses.size();c++)if(suffix[c][0]>0){
                        int used=0;for(QueueWindow w:windows)if(allowed[c][w.day]&&w.start<end)used+=Math.max(0,Math.min(end,w.end)-w.start);
                        double expected=Math.min(1,(double)used/Math.max(1,totalCapacity[c])*Planner.dailyWeight(courses.get(c)));
                        double completed=(double)(suffix[c][0]-suffix[c][key.positions[c]])/suffix[c][0];pace+=(completed-expected)*(completed-expected);
                    }
                    return pace;
                }
            }
            Guidance guidance=new Guidance();List<BeamNode> nodes=new ArrayList<>();
            nodes.add(new BeamNode(new BeamKey(courses.size()),windows.get(0).start-rest,-1,0,-1,0,0,0,new double[0]));
            List<Integer> beam=new ArrayList<>();beam.add(0);int expansions=0;
            for(int step=0;step<tasks.size();step++){
                if(Thread.currentThread().isInterrupted())return null;
                Map<BeamKey,BeamNode> candidates=new HashMap<>();
                for(int parent:beam){BeamNode previous=nodes.get(parent);
                    for(int c=0;c<courses.size();c++)if(previous.key.positions[c]<queues.get(c).size()){
                        if(++expansions>60000)return null;int t=queues.get(c).get(previous.key.positions[c]),size=sizes[t];QueueWindow found=null;
                        for(QueueWindow w:windows)if(allowed[c][w.day]&&Math.max(previous.end+rest,w.start)+size<=w.end){found=w;break;}
                        if(found==null)continue;int start=Math.max(previous.end+rest,found.start),end=start+size;
                        BeamKey key=new BeamKey(previous.key);key.positions[c]++;
                        if(key.day!=found.day){key.day=found.day;key.mask=0;key.previous=-1;}
                        int count=Math.min(3,Integer.bitCount(key.mask));double gain=(key.mask&(1<<c))==0&&count<3?count:0;
                        double repetitions=previous.repetitions+(key.previous==c?1:0);key.mask|=1<<c;key.previous=c;
                        Double pace=guidance.assessment(key,end);if(pace==null)continue;
                        double coverage=previous.coverage+gain,earlyCoverage=previous.earlyCoverage+gain*(days.size()-found.day);
                        double[] rank=paceFirst?new double[]{pace,-coverage,-earlyCoverage,repetitions,end}:new double[]{-coverage,-earlyCoverage,pace,repetitions,end};
                        BeamNode old=candidates.get(key);if(old!=null&&!rankPrecedes(rank,old.rank))continue;
                        candidates.put(key,new BeamNode(key,end,t,start,parent,coverage,earlyCoverage,repetitions,rank));
                    }
                }
                if(candidates.isEmpty())return null;List<BeamNode> selected=new ArrayList<>(candidates.values());
                selected.sort((a,b)->{
                    if(rankPrecedes(a.rank,b.rank))return -1;if(rankPrecedes(b.rank,a.rank))return 1;
                    for(int c=0;c<courses.size();c++)if(a.key.positions[c]!=b.key.positions[c])return Integer.compare(a.key.positions[c],b.key.positions[c]);
                    int v=Integer.compare(a.key.day,b.key.day);if(v==0)v=Integer.compare(a.key.mask,b.key.mask);return v!=0?v:Integer.compare(a.key.previous,b.key.previous);
                });
                beam=new ArrayList<>();for(int i=0;i<Math.min(beamWidth,selected.size());i++){beam.add(nodes.size());nodes.add(selected.get(i));}
            }
            Plan best=null;
            for(int last:beam){
                List<List<Integer>> rows=new ArrayList<>();for(int d=0;d<days.size();d++)rows.add(new ArrayList<>());double[] starts=new double[tasks.size()];
                int index=last;while(nodes.get(index).parent>=0){BeamNode node=nodes.get(index);rows.get(node.key.day).add(node.task);starts[node.task]=node.start*60.0;index=node.parent;}
                for(List<Integer> row:rows)Collections.reverse(row);Plan result=new Plan(rows,starts,score(rows,starts));
                if(best==null||better(result.score,best.score))best=result;
            }
            return best;
        }
        static final class JointBudget {
            int evaluations,leaves;
            final int perRegion;
            JointBudget(int cost,boolean large){evaluations=Math.min(large?6000:40000,6000000/cost);leaves=Math.min(large?300:2000,600000/cost);perRegion=large?1500:12000;}
        }
        static final class JointChoice {
            final int course,day;final double start;final double[] bound;
            JointChoice(int course,int day,double start,double[] bound){this.course=course;this.day=day;this.start=start;this.bound=bound;}
        }
        /** Destroy/repair up to four days while retaining exact starts outside each neighborhood. */
        Plan jointNeighborhoods(Plan incumbent){
            if(tasks.size()>600||courses.size()>6||days.size()>366)return incumbent;
            Plan best=incumbent;JointBudget limit=new JointBudget(Math.max(1,tasks.size()+days.size()*courses.size()),tasks.size()>24||days.size()>7);
            for(int width:new int[]{4,3,2,1})if(width<=days.size())for(int first=0;first<=days.size()-width;first++){
                if(limit.evaluations<=0||limit.leaves<=0||Thread.currentThread().isInterrupted())return best;
                int last=first+width-1;List<Integer> selected=new ArrayList<>();Set<Integer> present=new HashSet<>();
                for(int d=first;d<=last;d++)for(int t:best.rows.get(d)){selected.add(t);present.add(owners[t]);}
                if(selected.size()<3||selected.size()>12||present.size()>4)continue;
                JointRepair repair=new JointRepair(best,first,last,selected,limit);
                if(repair.possible)repair.visit(repair.floor,0);
                best=repair.best;
            }
            return best;
        }
        final class JointRepair {
            final int first,last,count;final JointBudget limit;
            final List<List<Integer>> queues=new ArrayList<>(),rows=new ArrayList<>();
            final int[] positions=new int[courses.size()];
            final int[][] suffix=new int[courses.size()][],shortestSuffix=new int[courses.size()][];
            final double[][] latest=new double[courses.size()][];
            final double floor,ceiling;final double[] starts;
            int localEvaluations;boolean possible=true;Plan best;
            JointRepair(Plan incumbent,int first,int last,List<Integer> selected,JointBudget limit){
                this.first=first;this.last=last;this.limit=limit;count=selected.size();best=incumbent;
                Integer before=null,after=null;
                for(int d=0;d<first;d++)for(int t:incumbent.rows.get(d))before=t;
                for(int d=last+1;d<days.size()&&after==null;d++)if(!incumbent.rows.get(d).isEmpty())after=incumbent.rows.get(d).get(0);
                floor=before==null?Double.NEGATIVE_INFINITY:incumbent.starts[before]+sizes[before]*60.0+Planner.BREAK_SECONDS;
                ceiling=after==null?Double.POSITIVE_INFINITY:incumbent.starts[after]-Planner.BREAK_SECONDS;
                for(int d=0;d<days.size();d++)rows.add(d>=first&&d<=last?new ArrayList<>():new ArrayList<>(incumbent.rows.get(d)));
                starts=incumbent.starts.clone();localEvaluations=Math.min(limit.perRegion,limit.evaluations);
                for(int c=0;c<courses.size();c++){
                    List<Integer> queue=new ArrayList<>();for(int t:selected)if(owners[t]==c)queue.add(t);queues.add(queue);
                    suffix[c]=new int[queue.size()+1];shortestSuffix[c]=new int[queue.size()+1];Arrays.fill(shortestSuffix[c],Integer.MAX_VALUE);
                    latest[c]=new double[queue.size()+1];Arrays.fill(latest[c],Double.POSITIVE_INFINITY);double end=ceiling;
                    for(int p=queue.size()-1;p>=0;p--){
                        double seconds=sizes[queue.get(p)]*60.0;Double found=null;
                        outer:for(int d=last;d>=first;d--)if(allowed[c][d]){
                            List<Planner.Span> spans=days.get(d).free;
                            for(int k=spans.size()-1;k>=0;k--){Planner.Span span=spans.get(k);
                                if(Math.min(end,span.b)-seconds>=Math.max(floor,span.a)){found=Math.min(end,span.b)-seconds;break outer;}
                            }
                        }
                        if(found==null){possible=false;break;}
                        latest[c][p]=found;end=found-Planner.BREAK_SECONDS;
                        suffix[c][p]=suffix[c][p+1]+sizes[queue.get(p)];
                        shortestSuffix[c][p]=Math.min(shortestSuffix[c][p+1],sizes[queue.get(p)]);
                    }
                }
            }
            // Bounds optimistically let remaining work occupy several days at once.
            // They only prune; the unchanged whole-plan score accepts actual leaves.
            double[] lowerBound(double ready){
                limit.evaluations--;localEvaluations--;
                double[] bound=score(rows,starts);double[][] loads=new double[courses.size()][days.size()];
                for(int d=0;d<days.size();d++)for(int t:rows.get(d))loads[owners[t]][d]+=sizes[t];
                double coverage=0,earlyCoverage=0,boost=0,triple=0;
                for(int d=0;d<days.size();d++){
                    int present=0;
                    for(int c=0;c<courses.size();c++){
                        int left=suffix[c][positions[c]],shortest=shortestSuffix[c][positions[c]];boolean canAdd=false;
                        if(left>0&&d>=first&&d<=last&&allowed[c][d])for(Planner.Span span:days.get(d).free)
                            if(Math.max(ready,span.a)+shortest*60.0<=Math.min(ceiling,span.b)){canAdd=true;break;}
                        if(loads[c][d]>0||canAdd)present++;
                        double weight=Planner.dailyWeight(courses.get(c));
                        if(weight>1){double low=loads[c][d],high=low+(canAdd?left:0),target=targets[c][d];
                            double difference=target<low?low-target:Math.max(0,target-high);
                            boost+=difference*difference;if(weight==3)triple+=difference*difference;
                        }
                    }
                    double count=Math.min(3,present),value=count*(count-1)/2;
                    coverage+=value;earlyCoverage+=value*(days.size()-d);
                }
                int offset=0;if(priorities.usesDefaultOrder()){bound[0]=triple;offset=1;}
                for(int rule:priorities.order)switch(rule){
                    case 0:bound[offset]=-coverage;bound[offset+1]=-earlyCoverage;offset+=3;break;
                    case 1:bound[offset]=boost;offset++;break;
                    case 2:offset++;break;
                    case 3:offset+=2;break;
                }
                return bound;
            }
            void visit(double ready,int placed){
                if(limit.evaluations<=0||localEvaluations<=0||limit.leaves<=0||Thread.currentThread().isInterrupted())return;
                if(placed==count){
                    limit.leaves--;double[] value=score(rows,starts);
                    if(better(value,best.score)){List<List<Integer>> copy=new ArrayList<>();for(List<Integer> row:rows)copy.add(new ArrayList<>(row));best=new Plan(copy,starts.clone(),value);}
                    return;
                }
                int required=0,blocks=0;
                for(int c=0;c<courses.size();c++)if(positions[c]<queues.get(c).size()){
                    if(ready>latest[c][positions[c]])return;
                    required+=suffix[c][positions[c]];blocks+=queues.get(c).size()-positions[c];
                }
                double capacity=0;int regions=0;
                for(int d=first;d<=last;d++)for(Planner.Span span:days.get(d).free){
                    double size=(Math.min(ceiling,span.b)-Math.max(ready,span.a))/60;
                    if(size>0){capacity+=size;regions++;}
                }
                if(required+Planner.BREAK_MINUTES*Math.max(0,blocks-regions)>capacity||!better(lowerBound(ready),best.score))return;
                List<JointChoice> choices=new ArrayList<>();
                generation:for(int c=0;c<courses.size();c++)if(positions[c]<queues.get(c).size()){
                    int t=queues.get(c).get(positions[c]);double seconds=sizes[t]*60.0;
                    for(int d=first;d<=last;d++)if(allowed[c][d]){
                        if(limit.evaluations<=0||localEvaluations<=0)break generation;
                        Double start=null;for(Planner.Span span:days.get(d).free)if(Math.max(ready,span.a)+seconds<=Math.min(ceiling,span.b)){start=Math.max(ready,span.a);break;}
                        if(start==null)continue;
                        rows.get(d).add(t);starts[t]=start;positions[c]++;
                        choices.add(new JointChoice(c,d,start,lowerBound(start+seconds+Planner.BREAK_SECONDS)));
                        positions[c]--;rows.get(d).remove(rows.get(d).size()-1);
                    }
                }
                choices.sort((a,b)->{if(rankPrecedes(a.bound,b.bound))return -1;if(rankPrecedes(b.bound,a.bound))return 1;
                    return a.day!=b.day?Integer.compare(a.day,b.day):Integer.compare(a.course,b.course);});
                for(JointChoice choice:choices){
                    if(limit.evaluations<=0||localEvaluations<=0||limit.leaves<=0)break;
                    if(!better(choice.bound,best.score))continue;
                    int c=choice.course,t=queues.get(c).get(positions[c]);rows.get(choice.day).add(t);starts[t]=choice.start;positions[c]++;
                    visit(choice.start+sizes[t]*60.0+Planner.BREAK_SECONDS,placed+1);
                    positions[c]--;rows.get(choice.day).remove(rows.get(choice.day).size()-1);
                }
            }
        }
        Outcome run()throws Exception{
            double[] baseline=new double[tasks.size()];for(int t=0;t<tasks.size();t++)baseline[t]=tasks.get(t).optDouble("start");
            double[] baselineScore=score(initialRows,baseline);Plan current=new Plan(initialRows,baseline,baselineScore),compact=pack(initialRows);
            if(compact!=null&&better(compact.score,current.score))current=compact;
            List<List<Integer>> paced=redistributed();
            for(List<List<Integer>> rows:Arrays.asList(interleaved(current.rows),paced,interleaved(paced))){
                Plan trial=pack(rows);if(trial!=null&&better(trial.score,current.score))current=trial;
            }
            if(needsQueueReconstruction(current))for(boolean paceFirst:new boolean[]{false,true}){
                Plan trial=queueBeam(paceFirst);if(trial!=null&&better(trial.score,current.score))current=trial;
            }
            Plan interleaved=pack(interleaved(current.rows));if(interleaved!=null&&better(interleaved.score,current.score))current=interleaved;
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
            current=jointNeighborhoods(current);
            List<JSONObject> output=new ArrayList<>();for(int t=0;t<tasks.size();t++)output.add(new JSONObject(tasks.get(t).toString()).put("start",current.starts[t]));
            output.sort(Comparator.comparingDouble(t->t.optDouble("start")));
            return new Outcome(output,better(current.score,baselineScore));
        }
    }
}
