package local.studyplanner;

import org.json.*;
import java.util.*;
import java.text.DecimalFormat;
import static local.studyplanner.AssistantProtocol.*;

/** Bounded display snapshots. Model requests must reference this turn's local evidence. */
final class AssistantChart {
    static final String UNAVAILABLE="图表未生成：数据缺失或格式不支持。可让助手重新查询后生成。";
    static final String INSTRUCTIONS="安卓会根据本轮实际查询自动展示课程进度卡、学习统计卡（每日实际/计划图）、日程核对、排程分析与规则卡；修改预览有独立方案卡。先给简短结论，再解释趋势和下一步，不重复抄写卡片数字，不为填满卡片查询无关数据。额外对比可输出 study-chart 围栏代码块，格式：{\"title\":\"课程进度\",\"kind\":\"bar\",\"unit\":\"分钟\",\"labels\":[\"完成\",\"剩余\"],\"series\":[{\"name\":\"有效进度\",\"values\":[\"E1.data.completed_minutes\",\"E1.data.remaining_minutes\"]}]}。kind 仅 bar、line、donut；values 只允许本轮工具数值路径，不允许数字或表达式。最多3张图、每图31项和4条同单位序列；donut仅1条非负序列、最多7项且总量大于0。标签不可重复，缺失值不能作0。实际用时、有效进度、按开始日统计的计划量不可混淆；无日期记录单独说明。图表是快照，不修改日程。";
    final JSONObject json;final String title,kind,unit,stamp;final String[] labels,names;final double[][] values;
    AssistantChart(JSONObject data)throws Exception{
        json=CourseTools.copy(data);title=shortText(data,"title",100);kind=data.getString("kind");unit=data.getString("unit");stamp=shortText(data,"capturedAt",100);
        if(!Arrays.asList("bar","line","donut").contains(kind)||unit.length()>20)throw invalid();
        labels=strings(data.getJSONArray("labels"),31,60);JSONArray series=data.getJSONArray("series");if(series.length()<1||series.length()>4)throw invalid();
        names=new String[series.length()];values=new double[names.length][labels.length];Set<String> unique=new HashSet<>();
        for(int i=0;i<names.length;i++){JSONObject s=series.getJSONObject(i);names[i]=shortText(s,"name",60);if(!unique.add(names[i]))throw invalid();JSONArray v=s.getJSONArray("values");if(v.length()!=labels.length)throw invalid();for(int j=0;j<labels.length;j++)values[i][j]=number(v.get(j),false);}
        if(kind.equals("donut")&&!supportsDonut())throw invalid();limit(json.toString(),24000);
    }
    static String shortText(JSONObject o,String key,int max)throws Exception{Object raw=o.get(key);if(!(raw instanceof String))throw invalid();String s=(String)raw;if(s.trim().isEmpty()||s.length()>max||s.chars().anyMatch(Character::isISOControl))throw invalid();return s;}
    static double number(Object raw,boolean nonnegative)throws Exception{if(!(raw instanceof Number))throw invalid();double n=((Number)raw).doubleValue();if(!Double.isFinite(n)||Math.abs(n)>1e12||nonnegative&&n<0)throw invalid();return n;}
    static String[] strings(JSONArray a,int max,int length)throws Exception{if(a.length()<1||a.length()>max)throw invalid();String[] out=new String[a.length()];Set<String> unique=new HashSet<>();for(int i=0;i<out.length;i++){out[i]=shortText(object("s",a.get(i)),"s",length);if(!unique.add(out[i]))throw invalid();}return out;}
    boolean supportsDonut(){if(names.length!=1||labels.length>7)return false;double sum=0;for(double n:values[0]){if(n<0)return false;sum+=n;}return sum>0;}
    static String format(double n){return new DecimalFormat("0.##").format(n);}
    static String axis(String s){if(s.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}"))return Integer.parseInt(s.substring(5,7))+"/"+Integer.parseInt(s.substring(8));if(s.matches("[0-9]+ · [0-9]{4}-[0-9]{2}-[0-9]{2}"))return "窗口"+s.split(" · ")[0];return s;}
    String table(){StringBuilder s=new StringBuilder("项目");for(String name:names)s.append('\t').append(name).append(unit.isEmpty()?"":"（"+unit+"）");for(int j=0;j<labels.length;j++){s.append('\n').append(labels[j]);for(double[] v:values)s.append('\t').append(format(v[j]));}return s.toString();}
    static AssistantChart decode(String text){try{limit(text,24000);return new AssistantChart(new JSONObject(text));}catch(Exception e){return null;}}
    static AssistantChart create(String title,String kind,String[] labels,String[] names,double[][] values,String stamp)throws Exception{
        JSONArray series=new JSONArray();for(int i=0;i<names.length;i++)series.put(object("name",names[i],"values",new JSONArray(values[i])));
        return new AssistantChart(object("title",title,"kind",kind,"unit","分钟","labels",new JSONArray(labels),"series",series,"capturedAt",stamp));
    }
    static AssistantChart resolve(String source,List<JSONObject> evidence,String stamp)throws Exception{
        limit(source,16000);JSONObject data=new JSONObject(source);JSONArray series=data.getJSONArray("series");if(series.length()>4)throw invalid();
        for(JSONObject s:Planner.list(series)){JSONArray raw=s.getJSONArray("values"),resolved=new JSONArray();if(raw.length()>31)throw invalid();for(int i=0;i<raw.length();i++){
            Object value=raw.get(i);if(!(value instanceof String))throw invalid();String path=(String)value;
            if(path.length()>160||!path.matches("E[1-9][0-9]*\\.data(?:\\.[A-Za-z_][A-Za-z_0-9]*|\\.(?:0|[1-9][0-9]*))+" )||path.split("\\.").length>12)throw invalid();
            resolved.put(AssistantTools.number(path,evidence));
        }s.put("values",resolved);}data.put("capturedAt",stamp);return new AssistantChart(data);
    }
    static String materialize(String answer,List<JSONObject> evidence,String stamp){
        String[] lines=answer.replace("\r\n","\n").split("\n",-1);List<String> out=new ArrayList<>();int count=0;
        for(int i=0;i<lines.length;i++){String line=lines[i];if(!line.trim().startsWith("```")){out.add(line);continue;}List<String> body=new ArrayList<>();while(++i<lines.length&&!lines[i].trim().equals("```"))body.add(lines[i]);boolean closed=i<lines.length;
            if(!line.trim().equals("```study-chart")){out.add(line);out.addAll(body);if(closed)out.add("```");continue;}
            try{if(!closed||++count>3)throw invalid();AssistantChart chart=resolve(String.join("\n",body),evidence,stamp);out.add("```study-chart");out.add(chart.json.toString());out.add("```");}catch(Exception e){out.add(UNAVAILABLE);}
        }return String.join("\n",out);
    }
    static String plainText(String answer){
        String[] lines=answer.replace("\r\n","\n").split("\n",-1);List<String> out=new ArrayList<>();
        for(int i=0;i<lines.length;i++){String line=lines[i];if(!line.trim().startsWith("```")){out.add(line);continue;}List<String> body=new ArrayList<>();while(++i<lines.length&&!lines[i].trim().equals("```"))body.add(lines[i]);boolean closed=i<lines.length;
            if(line.trim().equals("```study-chart")){AssistantChart c=closed?decode(String.join("\n",body)):null;out.add(c==null?UNAVAILABLE:c.title+"\n"+c.table()+"\n生成时的数据快照 · "+c.stamp);}else{out.add(line);out.addAll(body);if(closed)out.add("```");}
        }return String.join("\n",out);
    }
    static List<AssistantChart> inAnswer(String answer){
        List<AssistantChart> charts=new ArrayList<>();String[] lines=answer.replace("\r\n","\n").split("\n",-1);
        for(int i=0;i<lines.length;i++){String line=lines[i].trim();if(!line.startsWith("```"))continue;List<String> body=new ArrayList<>();while(++i<lines.length&&!lines[i].trim().equals("```"))body.add(lines[i]);if(line.equals("```study-chart")&&i<lines.length){AssistantChart chart=decode(String.join("\n",body));if(chart!=null)charts.add(chart);}}
        return charts;
    }
    boolean sameData(AssistantChart other){return unit.equals(other.unit)&&Arrays.equals(labels,other.labels)&&Arrays.equals(names,other.names)&&Arrays.deepEquals(values,other.values);}
}
