package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Bounded rescue search. Only a complete witness replaces a plan; failure means unknown. */
final class ScheduleFeasibilitySearch {
    static final int BREAK = 15, INF = Integer.MAX_VALUE / 4;
    static int minute(double seconds) { return (int)Math.ceil(seconds / 60); }
    static final class Window {
        final int start, end;
        Window(int start, int end) { this.start=start; this.end=end; }
    }
    static final class Queue {
        final String courseID; final int start,end; final List<Planner.Work> work;
        Queue(JSONObject course,List<Planner.Work> work) {
            courseID=course.optString("id"); start=minute(Planner.at(Planner.day(course.optDouble("startDate")),0));
            end=minute(Planner.at(Planner.day(course.optDouble("deadline")),1440)); this.work=work;
        }
    }
    static final class Floating {
        final LocalDate date; final int start,end,minutes;
        Floating(LocalDate date,JSONObject event) {
            this.date=date;start=minute(Planner.at(date,event.optInt("startMinute")));
            end=minute(Planner.at(date,event.optInt("endMinute")));minutes=Planner.occupied(event);
        }
    }
    static final class Solution {
        final List<JSONObject> tasks=new ArrayList<>(); final Map<LocalDate,Integer> floatingStarts=new HashMap<>();
    }
    static final class Key {
        final int[] positions; int floating; boolean lastStudy;
        Key(int n) { positions=new int[n]; }
        Key(Key old) { positions=old.positions.clone();floating=old.floating;lastStudy=old.lastStudy; }
        @Override public int hashCode() { return 31*(31*Arrays.hashCode(positions)+floating)+(lastStudy?1:0); }
        @Override public boolean equals(Object other) {
            if(!(other instanceof Key))return false;Key b=(Key)other;
            return floating==b.floating&&lastStudy==b.lastStudy&&Arrays.equals(positions,b.positions);
        }
    }
    static final class Node {
        final Key key; final int end,parent,choice,start; final double score;
        Node(Key key,int end,int parent,int choice,int start,double score) {
            this.key=key;this.end=end;this.parent=parent;this.choice=choice;this.start=start;this.score=score;
        }
    }
    static List<Window> windows(List<Planner.Day> days) {
        List<Window> out=new ArrayList<>();for(Planner.Day day:days)for(Planner.Span span:day.free)
            out.add(new Window(minute(span.a),(int)Math.floor(span.b/60)));return out;
    }
    static Integer place(List<Window> windows,int after,int minutes,int deadline) {
        int lo=0,hi=windows.size();while(lo<hi){int m=(lo+hi)/2;if(windows.get(m).end<after+minutes)lo=m+1;else hi=m;}
        for(int i=lo;i<windows.size();i++){Window w=windows.get(i);int start=Math.max(after,w.start),end=start+minutes;
            if(end>deadline)return null;if(end<=w.end)return start;}return null;
    }
    static Solution find(List<Queue> queues,List<Window> study,List<Window> eventWindows,List<Floating> floating,int floor,int initial) throws Exception {
        return find(queues,study,eventWindows,floating,floor,initial,250000);
    }
    static Solution find(List<Queue> queues,List<Window> study,List<Window> eventWindows,List<Floating> floating,int floor,int initial,int limit) throws Exception {
        int blocks=0;for(Queue q:queues)blocks+=q.work.size();
        if(queues.isEmpty()||queues.size()>6||blocks>600||study.size()>1500||floating.size()>366)return null;
        for(Floating event:floating)if(event.minutes<BREAK)return null;
        int[][] suffix=new int[queues.size()][],latest=new int[queues.size()][];
        for(int c=0;c<queues.size();c++){
            Queue q=queues.get(c);suffix[c]=new int[q.work.size()+1];latest[c]=new int[q.work.size()+1];Arrays.fill(latest[c],INF);int end=q.end;
            for(int i=q.work.size()-1;i>=0;i--){int n=q.work.get(i).minutes;suffix[c][i]=suffix[c][i+1]+n;Integer start=null;
                for(int w=study.size()-1;w>=0;w--){Window win=study.get(w);int at=Math.min(end,win.end)-n;if(at>=Math.max(win.start,Math.max(q.start,floor))){start=at;break;}}
                if(start==null)return null;latest[c][i]=start;end=start-BREAK;
            }
        }
        int[] floatingCosts=new int[floating.size()+1];
        for(int f=0;f<floating.size();f++){
            Floating event=floating.get(f);int least=INF;
            for(Window win:eventWindows){int first=Math.max(win.start,event.start),last=Math.min(win.end,event.end)-event.minutes;
                for(int at=first;at<=last;at++){int overlap=0;for(Window w:study)overlap+=Math.max(0,Math.min(at+event.minutes,w.end)-Math.max(at,w.start));least=Math.min(least,overlap);}}
            if(least==INF)return null;floatingCosts[f+1]=floatingCosts[f]+least;
        }
        Set<Integer> cutoffs=new TreeSet<>();for(Queue q:queues)cutoffs.add(q.end);List<Integer> deadlines=new ArrayList<>(cutoffs);
        List<Node> nodes=new ArrayList<>();nodes.add(new Node(new Key(queues.size()),initial,-1,-2,initial,0));
        List<Integer> beam=new ArrayList<>();beam.add(0);int expansions=0;
        for(int step=0;step<blocks+floating.size();step++){
            if(Thread.currentThread().isInterrupted())return null;
            Map<Key,Node> candidates=new HashMap<>();
            for(int index:beam){Node previous=nodes.get(index);
                for(int choice=-1;choice<queues.size();choice++){
                    if(++expansions>limit)return null;Key key=new Key(previous.key);Integer start;int minutes;
                    if(choice==-1){if(key.floating>=floating.size())continue;Floating e=floating.get(key.floating);
                        start=place(eventWindows,Math.max(previous.end,e.start),e.minutes,e.end);minutes=e.minutes;key.floating++;key.lastStudy=false;
                    }else{Queue q=queues.get(choice);int position=key.positions[choice];if(position>=q.work.size())continue;minutes=q.work.get(position).minutes;
                        int after=Math.max(floor,Math.max(q.start,previous.end+(key.lastStudy?BREAK:0)));
                        int eventEnd=key.floating<floating.size()?floating.get(key.floating).end-floating.get(key.floating).minutes:INF;
                        start=place(study,after,minutes,Math.min(q.end,eventEnd));key.positions[choice]++;key.lastStudy=true;
                    }
                    if(start==null)continue;int end=start+minutes;Node old=candidates.get(key);if(old!=null&&old.end<=end)continue;
                    double stress=rank(key,end,queues,study,floating,floor,suffix,latest,floatingCosts,deadlines);
                    if(stress>=0)candidates.put(key,new Node(key,end,index,choice,start,stress));
                }
            }
            if(candidates.isEmpty())return null;List<Node> selected=new ArrayList<>(candidates.values());
            selected.sort((a,b)->{int v=Double.compare(a.score,b.score);if(v==0)v=Integer.compare(a.end,b.end);
                for(int c=0;v==0&&c<a.key.positions.length;c++)v=Integer.compare(a.key.positions[c],b.key.positions[c]);
                if(v==0)v=Integer.compare(a.key.floating,b.key.floating);return v!=0?v:Boolean.compare(a.key.lastStudy,b.key.lastStudy);});
            beam=new ArrayList<>();for(int i=0;i<Math.min(128,selected.size());i++){beam.add(nodes.size());nodes.add(selected.get(i));}
        }
        int index=beam.get(0);for(int i:beam)if(nodes.get(i).end<nodes.get(index).end)index=i;
        List<Node> path=new ArrayList<>();while(nodes.get(index).parent>=0){path.add(nodes.get(index));index=nodes.get(index).parent;}
        Collections.reverse(path);Solution result=new Solution();
        for(Node node:path)if(node.choice==-1)result.floatingStarts.put(floating.get(node.key.floating-1).date,node.start);
        else {Queue q=queues.get(node.choice);result.tasks.add(Planner.task(q.courseID,node.start*60.0,q.work.get(node.key.positions[node.choice]-1)));}
        return result;
    }
    static double rank(Key key,int end,List<Queue> queues,List<Window> study,List<Floating> floating,int floor,int[][] suffix,int[][] latest,int[] costs,List<Integer> deadlines) {
        int ready=Math.max(floor,end+(key.lastStudy?BREAK:0));
        for(int c=0;c<queues.size();c++)if(key.positions[c]<queues.get(c).work.size()&&Math.max(ready,queues.get(c).start)>latest[c][key.positions[c]])return -1;
        double stress=0;for(int cutoff:deadlines){int required=0,blocks=0,capacity=0,regions=0;
            for(int c=0;c<queues.size();c++)if(queues.get(c).end<=cutoff){required+=suffix[c][key.positions[c]];blocks+=queues.get(c).work.size()-key.positions[c];}
            if(required==0)continue;for(Window w:study)if(w.end>Math.max(floor,end)&&w.start<cutoff){capacity+=Math.max(0,Math.min(cutoff,w.end)-Math.max(Math.max(floor,end),w.start));regions++;}
            int count=0;while(count<floating.size()&&floating.get(count).end<=cutoff)count++;
            int events=Math.max(0,count-key.floating);if(events>0)capacity-=costs[count]-costs[key.floating];
            required+=BREAK*Math.max(0,blocks-regions-events);if(required>capacity)return -1;stress=Math.max(stress,(double)required/Math.max(1,capacity));
        }return stress;
    }
}
