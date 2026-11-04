package local.studyplanner;
import org.json.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** Scalar controls; negative goals exercise arithmetic, not journal admission. */
public final class DailyConsequenceTargetTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        JSONArray parity=new JSONArray();
        for(int goal:new int[]{0,1,3,4,120,1001,1440,Integer.MAX_VALUE,Integer.MAX_VALUE-1,Integer.MIN_VALUE}){
            JSONObject entry=new JSONObject().put("goalMinutes",goal);String before=entry.toString();
            List<Integer> fractions=DailyConsequences.fractions(entry),expectedFractions=new ArrayList<>();Set<Integer> seen=new HashSet<>();
            for(int fraction:new int[]{0,250,500,750,1000}){int expected=BigInteger.valueOf(goal).multiply(BigInteger.valueOf(fraction)).divide(BigInteger.valueOf(1000)).intValueExact();if(fraction==1000||seen.add(expected))expectedFractions.add(fraction);}
            check(fractions.equals(expectedFractions),"Changed small-goal deduplication");
            for(int fraction:new int[]{-250,0,1,250,500,750,999,1000,2000}){
                BigInteger value=BigInteger.valueOf(goal).multiply(BigInteger.valueOf(fraction)).divide(BigInteger.valueOf(1000));
                if(value.compareTo(BigInteger.valueOf(Integer.MIN_VALUE))<0||value.compareTo(BigInteger.valueOf(Integer.MAX_VALUE))>0)continue;
                int expected=value.intValueExact();if(fraction!=1000&&expected==Integer.MAX_VALUE)continue;
                int threshold=fraction==1000?goal:expected+1;
                check(DailyConsequences.target(entry,fraction)==expected,"Scalar target differs from exact integer arithmetic");
                check(DailyConsequences.threshold(entry,fraction)==threshold,"Changed strict/full threshold");
                boolean atTarget=goal>0&&expected>=threshold,atThreshold=goal>0;
                check(DailyConsequences.achieved(entry,fraction,expected)==atTarget,"Wrong equal-target achievement");
                check(DailyConsequences.achieved(entry,fraction,threshold)==atThreshold,"Wrong threshold achievement");
                parity.put(new JSONObject().put("goal",goal).put("fraction",fraction).put("target",expected).put("threshold",threshold)
                    .put("achievedAtTarget",atTarget).put("achievedAtThreshold",atThreshold).put("fractions",new JSONArray(expectedFractions)));
            }
            check(entry.toString().equals(before),"Scalar evaluation changed input");
        }
        Files.write(Paths.get("Android/build/tests/daily-consequence-target.json"),parity.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("Daily consequence target controls passed: "+checks+"; scalar parity fixtures="+parity.length());
    }
}
