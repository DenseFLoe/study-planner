package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** Device-local journal, separate from sync rows and exported planner backups. */
final class DailyConsequenceRepository {
    static final int MAX_BYTES=8000000;
    final File file;boolean writeDisabled;
    DailyConsequenceRepository(File file){this.file=file;}
    static JSONObject empty() throws Exception{return new JSONObject().put("version",1).put("days",new JSONArray());}
    synchronized JSONObject load() throws Exception {
        if(!file.exists())return empty();
        try{
            if(Files.size(file.toPath())>MAX_BYTES)throw new IOException("预报历史过大");
            JSONObject journal=new JSONObject(new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8));JSONArray days=journal.getJSONArray("days");
            Set<String> ids=new HashSet<>(),dates=new HashSet<>();if(journal.getInt("version")!=1||days.length()>31)throw new IOException("预报历史版本无效");
            for(JSONObject day:Planner.list(days)){
                if(day.getInt("goalMinutes")<0||day.getInt("confirmedAtCapture")<0||day.getInt("warningMinutes")<30||!Double.isFinite(day.getDouble("capturedAt"))||day.getString("revision").isEmpty()||day.getJSONArray("forecasts").length()>5||!ids.add(day.getString("id"))||!dates.add(Planner.date(day.getDouble("date"))))throw new IOException("预报历史内容无效");
                day.getJSONArray("capturedRecords");day.getJSONArray("plannedToday");day.getJSONArray("celebrated");Planner.validate(day.getJSONObject("baseline"));
                Set<Integer> fractions=new HashSet<>();for(JSONObject forecast:Planner.list(day.getJSONArray("forecasts")))if(!DailyConsequences.fractions(day).contains(forecast.getInt("fraction"))||!fractions.add(forecast.getInt("fraction")))throw new IOException("预报档位无效");
            }
            return journal;
        }catch(Exception e){writeDisabled=true;throw e;}
    }
    synchronized void save(JSONObject journal) throws Exception {
        if(writeDisabled)throw new IOException("原预报历史需要保留");
        List<JSONObject> days=Planner.list(journal.getJSONArray("days"));days.sort(Comparator.comparingDouble(d->d.optDouble("date")));while(days.size()>14)days.remove(0);
        File temp=new File(file.getPath()+".tmp");
        try{
            if(!file.getParentFile().isDirectory()&&!file.getParentFile().mkdirs())throw new IOException("预报目录无法创建");
            while(true){
                try(FileOutputStream bytes=new FileOutputStream(temp)){
                    temp.setReadable(false,false);temp.setWritable(false,false);temp.setReadable(true,true);temp.setWritable(true,true);
                    OutputStream limited=new FilterOutputStream(bytes){int count;@Override public void write(int b)throws IOException{if(++count>MAX_BYTES)throw new IOException("预报历史过大");out.write(b);}
                        @Override public void write(byte[] b,int off,int len)throws IOException{if(count+len>MAX_BYTES)throw new IOException("预报历史过大");count+=len;out.write(b,off,len);}};
                    Writer writer=new OutputStreamWriter(limited,StandardCharsets.UTF_8);SyncJSON.write(writer,new JSONObject().put("version",1).put("days",new JSONArray(days)));writer.flush();bytes.getFD().sync();
                }catch(IOException e){if(temp.length()>=MAX_BYTES-8192&&days.size()>1){days.remove(0);continue;}throw e;}
                break;
            }
            Files.move(temp.toPath(),file.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);
            journal.put("days",new JSONArray(days));
        }finally{Files.deleteIfExists(temp.toPath());}
    }
}
