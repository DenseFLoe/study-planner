package local.studyplanner;

import org.json.*;
import java.util.*;

/** The same four existing preferences and stable ties as the desktop planner. */
final class SchedulePriorities {
    static final String[] RULES={"diversity","dailyWeight","coursePriority","balancedLoad"};
    static final String[] TITLES={"多科混排、分散学习","每日加量","课程优先级","学习量均衡"};
    static final String[] DETAILS={
        "时间允许时，一天尽量安排多个科目并交替学习，同时为后续日期保留混排机会。",
        "按各课程已有的 1～3 倍率提高前面日期的目标学习量；空间不足时允许延后到后续日期。",
        "在其他更高优先级的规则相同时，让课程编辑中设置为较高优先级的课程更早安排。",
        "比较各天的总学习分钟数并尽量均衡；整节课也计入比较，且保持整节完整和顺序。"
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
