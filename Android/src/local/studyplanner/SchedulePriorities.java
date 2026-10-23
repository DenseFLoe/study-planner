package local.studyplanner;

import org.json.*;
import java.util.*;

/** The same four existing preferences and stable ties as the desktop planner. */
final class SchedulePriorities {
    static final String[] RULES={"diversity","dailyWeight","coursePriority","balancedLoad"};
    static final String[] TITLES={"多科混排、分散学习","每日加量","课程优先级","学习量均衡"};
    static final String[] DETAILS={
        "时间允许时，一天安排多个科目，并为后续日期保留混排机会。",
        "按照各课程已有的 1～3 倍加量设置，优先把学习量排到前面的日期。",
        "优先安排课程编辑中设置为较高优先级的课程。",
        "尽量均衡各天的学习量，避免普通时间块集中在少数日期。按节课程仍保持整节和顺序。"
    };
    static final String[] LEVEL_NAMES={"1 级 · 首要偏好","2 级 · 次要偏好","3 级 · 更次要","4 级 · 最后考虑"};
    final int[] levels=new int[4];
    final List<Integer> order=new ArrayList<>();
    SchedulePriorities(JSONObject settings){
        JSONObject saved=settings.optJSONObject("schedulingRuleLevels");
        for(int i=0;i<RULES.length;i++){levels[i]=Math.max(1,Math.min(4,saved==null?i+1:saved.optInt(RULES[i],i+1)));order.add(i);}
        order.sort((a,b)->levels[a]!=levels[b]?Integer.compare(levels[a],levels[b]):Integer.compare(a,b));
    }
    boolean usesDefaultOrder(){for(int i=0;i<order.size();i++)if(order.get(i)!=i)return false;return true;}
    /** Negative means a wins. Only compare soft preferences after deadline urgency. */
    int compare(JSONObject a,JSONObject b,Map<String,Integer> daily,Map<String,Double> demand,
                boolean boosted,double halfA,double halfB,double progressA,double progressB){
        String ai=a.optString("id"),bi=b.optString("id");
        for(int rule:order){int result=0;
            switch(rule){
                case 0:
                    result=Boolean.compare(daily.containsKey(ai),daily.containsKey(bi));break;
                case 1:
                    if(boosted){double targetA=Math.max(1,demand.get(ai)*Planner.dailyWeight(a)),targetB=Math.max(1,demand.get(bi)*Planner.dailyWeight(b));
                        result=Double.compare((daily.getOrDefault(ai,0)+halfA)/targetA,(daily.getOrDefault(bi,0)+halfB)/targetB);}break;
                case 2:
                    result=Integer.compare(b.optInt("priority"),a.optInt("priority"));break;
                case 3:
                    result=Integer.compare(daily.getOrDefault(ai,0),daily.getOrDefault(bi,0));
                    if(result==0)result=Double.compare(progressA,progressB);break;
            }
            if(result!=0)return result;
        }
        return 0;
    }
    JSONObject json()throws JSONException{JSONObject out=new JSONObject();for(int i=0;i<RULES.length;i++)out.put(RULES[i],levels[i]);return out;}
}
