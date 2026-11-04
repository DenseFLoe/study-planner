package local.studyplanner;

import org.json.*;import java.net.URI;import java.util.*;import java.util.regex.*;

/** Recognizes only metadata from the page's own same-origin JSON responses. */
public final class GenericCourseDigest {
 static final String[] NAMES={"name","title","coursename","lessonname","sectionname","chaptername","catalogname","videoname","subjectname","packagename","goodsname","productname","outlinename","kcmc","kjmc","deliveryname"};
 static final String[] IDS={"id","uuid","lessonid","sectionid","catalogid","videoid","chapterid","resourceid","cid","kid"};
 static final Set<String> DURATIONS=new HashSet<>(Arrays.asList("duration","length","seconds","videotime","playtime","timelength","totaltime","totalseconds","videoduration","mediaduration","lessonduration","courseduration","classduration","shichang"));
 static final Set<String> PROGRESS=new HashSet<>(Arrays.asList("percent","progress","rate","watched","schedule","jd","learnpercent","learnprogress","studyprogress","watchprogress","playprogress","finishedpercent","completerate","finishrate"));
 static String normal(String key){return key.toLowerCase(Locale.ROOT).replaceAll("[^\\p{L}\\p{N}]","");}
 static String field(JSONObject object,String... keys){for(String wanted:keys){Iterator<String> names=object.keys();while(names.hasNext()){String key=names.next();Object value=object.opt(key);if(normal(key).equals(wanted)&&value!=null&&value!=JSONObject.NULL&&!(value instanceof Boolean)){String text=String.valueOf(value).trim();if(!text.isEmpty()&&text.length()<=200&&!text.contains("\n"))return text;}}}return "";}
 static Double number(Object value){if(value==null||value==JSONObject.NULL||value instanceof Boolean)return null;try{double n=Double.parseDouble(value.toString().trim());return Double.isFinite(n)?n:null;}catch(Exception e){return null;}}
 public static Double clockSeconds(String value){String raw=value.trim();if(raw.length()>32)return null;String[] parts=raw.split(":");if(parts.length==2||parts.length==3){double total=0;for(String part:parts){Double n=number(part);if(n==null)return null;total=total*60+n;}return total>0?total:null;}Matcher match=Pattern.compile("([0-9]+(?:\\.[0-9]+)?)\\s*(小时|时|分钟|分|秒|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)",Pattern.CASE_INSENSITIVE).matcher(raw);double total=0;while(match.find()){double amount=Double.parseDouble(match.group(1));String unit=match.group(2).toLowerCase(Locale.ROOT);total+=amount*(unit.contains("时")||unit.startsWith("h")?3600:unit.contains("分")||unit.startsWith("m")?60:1);}return total>0?total:null;}
 static class Lesson {String name,id,key,label;Double duration,textDuration,percent,position;boolean finished,explicitPercent;}
 static class Node {JSONObject object;Node parent;boolean array;String source;Lesson lesson;Node(JSONObject object,Node parent,boolean array,String source){this.object=object;this.parent=parent;this.array=array;this.source=source;}}
 static class Draft {String name,source;List<Lesson> lessons=new ArrayList<>();Draft(String name,String source){this.name=name;this.source=source;}}
 static void build(Object value,Node parent,boolean array,String source,int depth,List<Node> nodes){if(depth>=40||nodes.size()>=250000)return;if(value instanceof JSONObject){Node node=new Node((JSONObject)value,parent,array,source);nodes.add(node);Iterator<String> keys=node.object.keys();while(keys.hasNext())build(node.object.opt(keys.next()),node,false,source,depth+1,nodes);}else if(value instanceof JSONArray){JSONArray items=(JSONArray)value;for(int i=0;i<items.length();i++)build(items.opt(i),parent,true,source,depth+1,nodes);}}
 static Lesson lesson(JSONObject object){
  String name=field(object,NAMES);if(name.isEmpty())return null;
  Lesson result=new Lesson();result.name=name;result.id=field(object,IDS);result.key=field(object,"courseid","coursecode","courseuuid","kcdm");result.label=field(object,"coursename","coursetitle");
  List<String> keys=new ArrayList<>();object.keys().forEachRemaining(keys::add);Collections.sort(keys);int percentPriority=-1;
  for(String key:keys){String normal=normal(key);Object value=object.opt(key);
   if(result.duration==null&&result.textDuration==null&&(DURATIONS.contains(normal)||normal.endsWith("duration")||normal.endsWith("seconds")||normal.endsWith("length")||normal.endsWith("shichang"))){result.duration=number(value);if(result.duration==null&&value instanceof String)result.textDuration=clockSeconds((String)value);}
   else if(PROGRESS.contains(normal)||normal.endsWith("percent")||normal.endsWith("progress")||normal.endsWith("rate")){
    String text=value instanceof String?((String)value).trim():"";Double formatted=text.endsWith("%")&&text.length()<=16?number(text.substring(0,text.length()-1)):null;
    Double candidate=formatted!=null?formatted:number(value);boolean explicit=formatted!=null||normal.endsWith("percent");int priority=formatted!=null?2:explicit?1:0;
    if(candidate!=null&&priority>percentPriority){result.percent=candidate;result.explicitPercent=explicit;percentPriority=priority;}
   }else if(result.position==null&&(normal.equals("position")||normal.endsWith("position")||normal.endsWith("currenttime")))result.position=number(value);
   if(Arrays.asList("finished","isfinish","completed","iscompleted","finishstatus").contains(normal)&&Boolean.TRUE.equals(value))result.finished=true;
  }
  return result.duration!=null||result.textDuration!=null||result.percent!=null?result:null;
 }
 public static List<JSONObject> snapshots(JSONArray responses,String pageURL,String title,double now)throws Exception{
  URI page=new URI(pageURL);Map<String,Draft> drafts=new LinkedHashMap<>();for(JSONObject response:Planner.list(responses)){URI url;try{url=new URI(response.getString("url"));}catch(Exception e){continue;}if(WebCourseImport.origin(pageURL)==null||!Objects.equals(WebCourseImport.origin(response.getString("url")),WebCourseImport.origin(pageURL)))continue;List<Node> nodes=new ArrayList<>();try{build(new JSONTokener(response.getString("body")).nextValue(),null,false,WebCourseImport.safeURL(pageURL),0,nodes);}catch(Exception e){continue;}for(Node node:nodes)node.lesson=lesson(node.object);for(Node node:nodes){Lesson lesson=node.lesson;if(lesson==null)continue;String name,key;if(!lesson.key.isEmpty()||!lesson.label.isEmpty()){name=lesson.label.isEmpty()?(nodes.isEmpty()?title:field(nodes.get(0).object,NAMES)):lesson.label;if(name.isEmpty())name=title;key=normal(lesson.key.isEmpty()?name:lesson.key);}else{Node container=node.parent,current=node.parent;int hops=0;while(current!=null&&hops++<12){if(current.array&&current.lesson==null)container=current;current=current.parent;}if(container==null)continue;name="";current=container;hops=0;while(current!=null&&name.isEmpty()&&hops++<3){name=field(current.object,NAMES);current=current.parent;}if(name.isEmpty())name=title.isEmpty()?page.getHost():title;key=normal(name);}Draft draft=drafts.get(key);if(draft==null){draft=new Draft(name,node.source);drafts.put(key,draft);}draft.lessons.add(lesson);}}
  List<JSONObject> snapshots=new ArrayList<>();
  for(Map.Entry<String,Draft> entry:drafts.entrySet()){
   Draft draft=entry.getValue();boolean millis=false,ratio=true,hasPercent=false;
   for(Lesson l:draft.lessons){if(l.duration!=null&&l.duration>36000)millis=true;if(l.percent!=null&&!l.explicitPercent){hasPercent=true;if(l.percent>1)ratio=false;}}
   ratio&=hasPercent;String packageID="generic:"+entry.getKey();Map<String,JSONObject> merged=new LinkedHashMap<>();Set<String> conflicts=new HashSet<>();
   for(Lesson l:draft.lessons){
    String id=packageID+":"+(l.id.isEmpty()?l.name:l.id);
    Double duration=l.textDuration!=null?l.textDuration:l.duration==null?null:l.duration/(millis?1000:1);if(duration!=null&&(duration<1||duration>36000))duration=null;
    double percent=l.percent==null?0:l.percent*(ratio&&!l.explicitPercent?100:1);
    if(l.percent==null&&l.position!=null&&duration!=null&&l.position>0){double position=l.position/(millis?1000:1);if(position<=duration)percent=position/duration*100;}if(percent<0||percent>100)percent=0;
    JSONObject previous=merged.get(id);
    if(previous!=null){
     // Cumulative progress and complete evidence survive later incomplete summaries.
     if(duration!=null){if(previous.has("durationSeconds")&&Math.abs(previous.getDouble("durationSeconds")-duration)>0.001)conflicts.add(id);previous.put("durationSeconds",Math.max(previous.optDouble("durationSeconds",0),duration)).put("requiresDuration",true).put("kind","video");}
     previous.put("watchedPercent",Math.max(previous.getDouble("watchedPercent"),percent)).put("markedFinished",previous.optBoolean("markedFinished")||l.finished);
    }else{
     JSONObject lesson=new JSONObject().put("id",id).put("name",l.name).put("subject","").put("stage","").put("chapter","").put("kind",duration==null?"unknown":"video").put("published",true).put("markedFinished",l.finished).put("requiresDuration",duration!=null).put("watchedPercent",percent);if(duration!=null)lesson.put("durationSeconds",duration);merged.put(id,lesson);
    }
   }
   JSONArray issues=new JSONArray();if(!conflicts.isEmpty())issues.put("同一课节返回了不同的有效时长，请重新打开课程后抓取并核对。");
   snapshots.add(new JSONObject().put("packageID",packageID).put("name",draft.name).put("sourceURL",draft.source).put("fetchedAt",now).put("expectedOutlines",1).put("fetchedOutlines",1).put("lessons",new JSONArray(merged.values())).put("issues",issues));
  }
  snapshots.sort((a,b)->Integer.compare(b.optJSONArray("lessons").length(),a.optJSONArray("lessons").length()));return snapshots;
 }
}
