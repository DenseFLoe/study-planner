package local.studyplanner;

import org.json.JSONObject;
import java.util.*;

/** Title sorting must remain compatible and finish on untrusted long input. */
public final class CourseSortSecurityTests {
    static int checks;
    static void check(boolean condition,String message){checks++;if(!condition)throw new AssertionError(message);}

    static void ordered(String... names)throws Exception {
        List<JSONObject> input=new ArrayList<>();
        for(int i=names.length-1;i>=0;i--)input.add(new JSONObject().put("id","lesson-"+i).put("name",names[i]));
        List<JSONObject> sorted=CourseTools.intelligent(input);
        for(int i=0;i<names.length;i++)check(sorted.get(i).getString("name").equals(names[i]),"Unexpected lesson order at "+i);
    }

    static void key(String input,String text,String... numbers){
        CourseTools.SortKey key=new CourseTools.SortKey(input);
        check(key.text.equals(text),"Unexpected normalized title");
        check(key.numbers.equals(Arrays.asList(numbers)),"Unexpected lesson numbers");
    }

    static void normalTitles()throws Exception {
        ordered("第２章 第２课 60fps.mkv","第2章 第10课1080p.mp4","第十章 第2课.mp4");
        ordered("第1课（上）.mp4","第1课（中）.mp4","第1课（下）.mp4");
        ordered("课２ 1080p.mp4","课10 4k.mkv");
        // Adjacent metadata must still match even after a preceding tag ended in a digit.
        key("h26460fps","");
        key("60h264fps","fps","60");
        key("124k","","12");
        key("1080p60fps","");
        key("零第十章","零第章","10");
    }

    static String repeat(char c,int count){char[] chars=new char[count];Arrays.fill(chars,c);return new String(chars);}

    static void longTitles()throws Exception {
        final Throwable[] failure=new Throwable[1];
        Thread worker=new Thread(()->{
            try{
                String digits=repeat('0',500000),chinese=repeat('〇',100000);
                key(digits+"x","x","0");
                key(chinese+"x",chinese+"x");
                key(digits+"fps","");
                key(chinese+"章","章","0");
            }catch(Throwable error){failure[0]=error;}
        },"long-course-title-regression");
        // A regressed matcher must fail the test without keeping the JVM alive.
        worker.setDaemon(true);worker.start();worker.join(5000);
        check(!worker.isAlive(),"Sorting long course titles exceeded five seconds");
        if(failure[0]!=null)throw new AssertionError("Long title sorting failed",failure[0]);
    }

    public static void main(String[] args)throws Exception {
        normalTitles();longTitles();
        System.out.println("Course sort security tests passed: "+checks+" checks");
    }
}
