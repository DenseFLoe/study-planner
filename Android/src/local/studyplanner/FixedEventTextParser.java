package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;
import java.util.regex.*;

/** Local conservative extraction only. Every candidate must be reviewed in the regular editor. */
public final class FixedEventTextParser {
    static final String NUMBER="[0-9零〇一二两三四五六七八九十]{1,3}",PERIOD="凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|晚间|晚";
    static final String CLOCK="(?:("+PERIOD+")\\s*)?(?<![0-9])([0-9]{1,2})[:：]([0-9]{2})(?![0-9])|(?:("+PERIOD+")\\s*)?("+NUMBER+")\\s*[点时]\\s*(?:(半|一刻|三刻)|([0-9零〇一二两三四五六七八九十]{1,3})分?)?";
    static final String DATE="(?<![0-9:])(?:(20[0-9]{2})[年/\\-])?([0-9]{1,2})[月/\\-]([0-9]{1,2})(?:日|号)?(?![0-9:])";
    static final String RELATIVE="大后天|后天|明天|今天|今日|明日|后日|(?:下下|下|本|这)?(?:周|星期|礼拜)[一二三四五六日天1-7]";
    public static final class Draft {
        public final JSONObject event;public final List<String> warnings;public final String source;
        Draft(JSONObject event,List<String> warnings,String source){this.event=event;this.warnings=new ArrayList<>(new TreeSet<>(warnings));this.source=source;}
    }
    public static final class Result {public final List<Draft> drafts=new ArrayList<>();public final List<String> messages=new ArrayList<>();}
    static List<MatchResult> matches(String pattern,String text){List<MatchResult> out=new ArrayList<>();Matcher m=Pattern.compile(pattern).matcher(text);while(m.find())out.add(m.toMatchResult());return out;}
    static String group(MatchResult m,int n){String s=m.group(n);return s==null?"":s;}
    static boolean has(String pattern,String text){return Pattern.compile(pattern).matcher(text).find();}
    static String normalize(String text){StringBuilder s=new StringBuilder();for(char c:text.toCharArray())s.append(c>=0xff01&&c<=0xff5e?(char)(c-0xfee0):c==0x3000?' ':c);return s.toString();}
    static boolean recurring(String text){return has("每天|每日|每周|每星期|每礼拜|每逢|工作日|周末",text);}
    static int integer(String s){try{return Integer.parseInt(s);}catch(Exception ignored){}if(s.isEmpty())return -1;int ten=s.indexOf('十');if(ten>=0){int a=ten==0?1:digit(s.charAt(0)),b=ten==s.length()-1?0:digit(s.charAt(ten+1));return a<0||b<0?-1:a*10+b;}return s.length()==1?digit(s.charAt(0)):-1;}
    static int digit(char c){int n="零一二三四五六七八九".indexOf(c);return c=='〇'?0:c=='两'?2:n;}
    static int weekday(char c){int n="一二三四五六日".indexOf(c);if(c=='天')n=6;if(c>='1'&&c<='7')n=c-'1';return n;}
    static Set<Integer> weekdays(String text){Set<Integer> out=new TreeSet<>();if(has("每天|每日",text)){out.addAll(Arrays.asList(1,2,3,4,5,6,7));return out;}if(text.contains("工作日")){out.addAll(Arrays.asList(2,3,4,5,6));return out;}if(text.contains("周末")){out.addAll(Arrays.asList(1,7));return out;}
        for(MatchResult m:matches("(?:每(?:周|星期|礼拜)|每逢|周|星期|礼拜)([一二三四五六日天1-7](?:\\s*(?:、|,|，|和|及|到|至|[-~—～])\\s*(?:(?:每)?(?:周|星期|礼拜))?[一二三四五六日天1-7])*)",text)){
            String list=group(m,1);List<Integer> days=new ArrayList<>();for(MatchResult d:matches("[一二三四五六日天1-7]",list))days.add((weekday(group(d,0).charAt(0))+1)%7+1);
            if(has("到|至|[-~—～]",list)&&days.size()==2){int d=days.get(0);for(int i=0;i<7;i++){out.add(d);if(d==days.get(1))break;d=d%7+1;}}else out.addAll(days);
        }return out;
    }
    static LocalDate relative(String s,LocalDate today){String[] days={"今天","今日","明天","明日","后天","后日","大后天"};int[] offsets={0,0,1,1,2,2,3};for(int i=0;i<days.length;i++)if(s.equals(days[i]))return today.plusDays(offsets[i]);int target=weekday(s.charAt(s.length()-1));if(target<0)return null;int delta=target-(today.getDayOfWeek().getValue()-1);if(s.startsWith("下下"))delta+=14;else if(s.startsWith("下"))delta+=7;else if(!s.startsWith("本")&&!s.startsWith("这")&&delta<0)delta+=7;return today.plusDays(delta);}
    static int clock(int hour,int minute,String period){if(period.isEmpty())return hour*60+minute;if(hour>12)return has("凌晨|早上|早晨|上午|中午",period)?-1:hour*60+minute;if(hour==12&&has("晚上|晚间|晚",period))return -1;if(has("下午|傍晚|晚上|晚间|晚",period))return (hour==12?12:hour+12)*60+minute;if(period.equals("中午"))return (hour<11?hour+12:hour)*60+minute;return (hour==12&&period.equals("凌晨")?0:hour)*60+minute;}
    static class Reject extends Exception {Reject(String text){super(text);}}
    static void require(boolean condition,String message)throws Reject{if(!condition)throw new Reject(message);}
    static final class Clock {int minute,hour;String period;MatchResult match;Clock(int minute,int hour,String period,MatchResult match){this.minute=minute;this.hour=hour;this.period=period;this.match=match;}}
    static Draft notice(String source,LocalDate today)throws Exception {
        String text=normalize(source);require(!has("取消|改期|推迟|延期|(?:时间|日期|会议|活动)待定|暂不|另择|任选|之间|时段内|浮动",text),"内容涉及取消、变更或浮动时段，请整理明确的日期与起止时间，或手动添加。");
        List<String> warnings=new ArrayList<>();List<MatchResult> dateMatches=matches(DATE,text),relativeMatches=matches(RELATIVE,text);List<LocalDate> dates=new ArrayList<>();Integer inferred=null;
        for(MatchResult m:dateMatches){String y=group(m,1);int year=y.isEmpty()?(inferred==null?today.getYear():inferred):integer(y),month=integer(group(m,2)),day=integer(group(m,3));LocalDate date;
            try{date=LocalDate.of(year,month,day);}catch(DateTimeException e){throw new Reject("日期不存在，请核对原文中的月、日。");}
            if(y.isEmpty()){if(dates.isEmpty()?date.isBefore(today):date.isBefore(dates.get(dates.size()-1)))year++;try{date=LocalDate.of(year,month,day);}catch(DateTimeException e){throw new Reject("无法确定日期年份，请填写完整年月日。");}warnings.add("原文未写年份，按 "+year+" 年解释，请核对。");}inferred=year;dates.add(date);
        }
        boolean repeat=recurring(text);Set<Integer> weeks=repeat?weekdays(text):new TreeSet<>();require(!repeat||!weeks.isEmpty(),"重复星期不明确，请补充例如“每周一、三”或“每天”。");
        String prefix=dateMatches.isEmpty()?"":text.substring(0,dateMatches.get(0).start());boolean onlyEnd=repeat&&dates.size()==1&&has("(?:截止|截至|直到|至|到)\\s*$",prefix);LocalDate start;
        if(!dates.isEmpty()&&!onlyEnd)start=dates.get(0);else if(!relativeMatches.isEmpty())start=relative(group(relativeMatches.get(0),0),today);else if(repeat)start=today;else throw new Reject("找到了时间，但没有明确日期；请补充今天、明天或具体月日。");
        require(start!=null,"无法确定相对日期，请补充具体日期。");require(repeat||dates.size()<=1,"同一段出现多个日期，请将每项日程分行粘贴。");
        if(!repeat)for(MatchResult m:relativeMatches){String s=group(m,0);LocalDate implied=relative(s,today);boolean bare=s.startsWith("周")||s.startsWith("星期")||s.startsWith("礼拜");require(implied==null||(bare?implied.getDayOfWeek()==start.getDayOfWeek():implied.equals(start)),"同一段出现不一致的日期或星期，请核对或分行粘贴。");}
        LocalDate endDate=start;if(repeat){require(dates.size()<=2,"重复日程包含多组日期，请分段识别。");if(onlyEnd)endDate=dates.get(0);else if(dates.size()==2)endDate=dates.get(1);else{List<MatchResult> durations=matches("(?:持续|共|为期)\\s*([0-9一二三四五六七八九十]{1,3})\\s*周",text);int n=durations.isEmpty()?-1:integer(group(durations.get(0),1));if(n>=1&&n<=520)endDate=start.plusDays(n*7-1);else{endDate=start.plusDays(111);warnings.add("未写重复截止日期，暂按持续 16 周预填，请核对。");}}require(!endDate.isBefore(start),"重复结束日期早于开始日期，请核对。");}
        if(start.isBefore(today))warnings.add("识别日期已过去，请确认是否仍需添加。");if(repeat&&endDate.isBefore(today))warnings.add("重复日程的结束日期已过去，请修改日期。");
        List<MatchResult> times=matches(CLOCK,text);require(!times.isEmpty()&&times.size()<=2,"同一段存在多组时间，请把每项日程分行。");List<Clock> clocks=new ArrayList<>();
        for(MatchResult m:times){boolean colon=!group(m,2).isEmpty();String period=group(m,colon?1:4),suffix=group(m,6);int hour=integer(group(m,colon?2:5));int minute=colon?integer(group(m,3)):suffix.equals("半")?30:suffix.equals("一刻")?15:suffix.equals("三刻")?45:Math.max(0,integer(group(m,7)));require(hour>=0&&hour<=24,"小时超出范围，请核对时间。");require(minute>=0&&minute<=59&&(hour<24||minute==0),"分钟超出范围，请核对时间。");int converted=clock(hour,minute,period);require(converted>=0,"时段与小时不一致，请核对上午、下午或晚上。");clocks.add(new Clock(converted,hour,period,m));}
        Clock first=clocks.get(0);if(first.period.isEmpty()&&first.hour>0&&first.hour<12)warnings.add("原文未说明上午或下午，按 24 小时制解释，请核对。");int end;
        if(clocks.size()==2){Clock second=clocks.get(1);require(has("^\\s*(?:到|至|[-~—–～])\\s*$",text.substring(first.match.end(),second.match.start())),"两处时间不是明确的起止区间，请只保留活动时间，或用到连接。");if(second.period.isEmpty()&&!first.period.isEmpty()&&second.hour<12){int n=clock(second.hour,second.minute%60,first.period);if(n>=0)second.minute=n;}else if(first.period.isEmpty()&&!second.period.isEmpty()&&first.hour<12){int n=clock(first.hour,first.minute%60,second.period);if(n>=0)first.minute=n;}end=second.minute;
        }else{List<MatchResult> durations=matches("(?:持续|时长|共|约|用时)\\s*("+NUMBER+")\\s*(个半小时|小时半|个小时|小时|分钟|分)(?:\\s*("+NUMBER+")\\s*分(?:钟)?)?",text);if(!durations.isEmpty()){MatchResult d=durations.get(0);int amount=integer(group(d,1));String unit=group(d,2);int minutes=unit.contains("小时")?amount*60+(unit.contains("半")?30:0)+Math.max(0,integer(group(d,3))):amount;require(minutes>0,"活动时长必须大于 0，请核对。");end=first.minute+minutes;}else{end=Math.min(first.minute+60,1440);warnings.add("未写结束时间，暂按 "+(end-first.minute)+" 分钟预填，保存前请核对。");}}
        require(first.minute<end&&first.minute<1440&&end<=1440,"结束时间须晚于开始时间；跨午夜活动请拆成两条事项。");String title=title(text);if(title.equals("待命名事项"))warnings.add("未确定事项名称，请在编辑页补充。");
        JSONObject event=new JSONObject().put("id",Planner.id()).put("title",title).put("startMinute",first.minute).put("endMinute",end).put("startDate",Planner.at(start,0)).put("endDate",Planner.at(endDate,0)).put("weekdays",new JSONArray(weeks)).put("excludedDates",new JSONArray()).put("color","orange").put("notes",source);return new Draft(event,warnings,source);
    }
    static String title(String text){for(String pattern:new String[]{"(?:事项|主题|活动名称|会议名称|名称)[：:]\\s*([^\\n，,。；;]{2,60})","(?:召开|举行|开展|举办)\\s*([^\\n，,。；;]{2,60})"}){List<MatchResult> m=matches(pattern,text);if(!m.isEmpty())return group(m.get(0),1).trim();}
        String value=text;for(String p:new String[]{DATE,RELATIVE,CLOCK,"(?:每天|每日|每周|每星期|每礼拜|工作日|周末)(?:[一二三四五六日天1-7、，,到至和及\\- ]*)","(?:持续|时长|共|约|用时)\\s*"+NUMBER+"\\s*(?:小时|分钟|分|周)","[到至~—～]","@所有人"})value=value.replaceAll(p," ");
        for(String chunk:value.split("[\\n，,。；;]")){String s=chunk.replaceAll("^[\\s：:、-]+|[\\s：:、-]+$","");if(!s.isEmpty()&&!Arrays.asList("时间","日期","通知","地点另行通知").contains(s))return s.substring(0,Math.min(60,s.length()));}return "待命名事项";
    }
    public static Result parse(String input,double now){Result result=new Result();String source=input.trim();if(source.isEmpty()){result.messages.add("请先粘贴包含日期和时间的通知或聊天文字。");return result;}if(source.codePointCount(0,source.length())>30000){result.messages.add("一次最多识别 30000 字，请分段粘贴。");return result;}
        String normalized=normalize(source);String[] separated=source.split("[\\n；;。]");int dated=0;for(String s:separated){s=normalize(s);if(has(CLOCK,s)&&(has(DATE,s)||has(RELATIVE,s)||recurring(s)))dated++;}String[] pieces=matches(CLOCK,normalized).size()<=2&&dated<2?new String[]{source}:separated;
        String dateContext="";int rejected=0;LocalDate today=Planner.day(now);Set<String> seen=new HashSet<>();
        for(String raw:pieces){String piece=raw.trim(),text=normalize(piece);if(piece.isEmpty())continue;boolean hasDate=has(DATE,text)||has(RELATIVE,text)||recurring(text);if(hasDate){List<MatchResult> dateMatches=matches(DATE,text);dateMatches.addAll(matches(RELATIVE,text));dateMatches.sort(Comparator.comparingInt(MatchResult::start));StringBuilder b=new StringBuilder();for(MatchResult m:dateMatches)b.append(group(m,0)).append(' ');dateContext=recurring(text)?text.replaceAll(CLOCK,""):b.toString().trim();}if(!has(CLOCK,text))continue;
            try{Draft draft=notice(hasDate||dateContext.isEmpty()?piece:dateContext+"\n"+piece,today);JSONObject e=draft.event;String key=e.getString("title")+"|"+e.getDouble("startDate")+"|"+e.getDouble("endDate")+"|"+e.getInt("startMinute")+"|"+e.getInt("endMinute")+"|"+e.getJSONArray("weekdays");if(seen.add(key))result.drafts.add(draft);}catch(Exception e){rejected++;String message=e instanceof Reject?e.getMessage():"内容无法确定，请核对日期与时间后重试。";if(!result.messages.contains(message))result.messages.add(message);}if(result.drafts.size()==20){result.messages.add("最多展示 20 条候选，请核对后分批添加其余事项。");break;}
        }if(result.drafts.isEmpty()&&rejected==0)result.messages.add("未找到明确的日期和时间。请补充例如明天18:00开会或每周三下午3点到5点上课。");if(rejected>0&&!result.drafts.isEmpty())result.messages.add("部分内容未能确定时间，请核对原文，避免遗漏。");return result;
    }
}
