package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

public final class CourseSourcePrivacyTests {
    static int checks;
    static final String PRIVATE="https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@pan.quark.cn:443/s/abc123?pwd=SYNTHETIC_PASS&token=SYNTHETIC_TOKEN#/list/share/abcd1234";
    static final String PUBLIC="https://pan.quark.cn/s/abc123#/list/share/abcd1234";
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject netdisk()throws Exception{return new JSONObject().put("pwdID","abc123").put("shareTitle","课程").put("folderPath","基础课")
        .put("sourceURL",PRIVATE).put("fetchedAt",PlannerBackupFileTests.NOW).put("videoCount",2).put("totalBytes",1234)
        .put("unknownDurations",0).put("detection","课程判定").put("futureField",42);}
    static JSONObject fixture()throws Exception{
        JSONObject state=PlannerBackupFileTests.fixture(),course=state.getJSONArray("courses").getJSONObject(0);
        course.put("netdisk",netdisk()).put("lessonOrder",new JSONArray().put("b").put("a")).put("lessonOrderCustomized",true);
        return state;
    }
    static JSONObject payload(JSONObject row)throws Exception{return SyncLedger.payload(row);}
    static void noSecrets(JSONObject object,String message){check(!object.toString().contains("SYNTHETIC_"),message);}
    static void urls()throws Exception{
        check(CourseSourcePrivacy.netdiskURL(PRIVATE).equals(PUBLIC),"Public folder locator lost");
        check(CourseSourcePrivacy.netdiskURL("pan.quark.cn/s/abc123?pwd=SYNTHETIC_PASS").equals("https://pan.quark.cn/s/abc123"),"Scheme-less link not cleaned");
        check(CourseSourcePrivacy.netdiskURL("https://pan.quark.cn/s/abc123#SYNTHETIC_FRAGMENT").equals("https://pan.quark.cn/s/abc123"),"Private fragment retained");
        check(CourseSourcePrivacy.netdiskURL("https://example.com/s/abc123").isEmpty(),"Foreign source accepted as netdisk");
        check(CourseSourcePrivacy.netdiskURL("http://pan.quark.cn/s/abc123").isEmpty(),"Insecure source accepted");
        check(CourseSourcePrivacy.netdiskURL(PUBLIC).equals(PUBLIC),"Public locator is not stable");
    }
    static void nestedAndImmutable()throws Exception{
        JSONObject raw=new JSONObject().put("id",Planner.id()).put("futureField",new JSONObject().put("keep",42)).put("netdisk",netdisk())
            .put("webCourse",new JSONObject().put("sourceURL",PRIVATE).put("netdisk",netdisk()))
            .put("mergedSources",new JSONArray().put(new JSONObject().put("netdisk",netdisk())));
        String before=SyncLedger.canonical(raw);JSONObject clean=CourseSourcePrivacy.course(raw);
        noSecrets(clean,"Nested source leaked");check(before.equals(SyncLedger.canonical(raw)),"Cleanup mutated source");
        check(clean.getJSONObject("futureField").getInt("keep")==42&&clean.getJSONObject("netdisk").getInt("futureField")==42,"Future fields lost");
        check(clean.getJSONObject("netdisk").getString("sourceURL").equals(PUBLIC),"Folder locator changed");
        check(CourseSourcePrivacy.course(clean)==clean,"Clean data unnecessarily copied");
    }
    static void backupsAndProgress()throws Exception{
        JSONObject raw=fixture(),expected=CourseSourcePrivacy.state(raw);String before=SyncLedger.canonical(raw);
        JSONObject loaded=PlannerBackupFile.readLegacyState(new ByteArrayInputStream(raw.toString().getBytes(StandardCharsets.UTF_8)));
        check(SyncLedger.equivalent(loaded,expected),"Legacy load changed fields other than source");
        PlannerBackupFile file=PlannerBackupFile.create(raw,PlannerBackupFileTests.NOW);
        JSONObject restored=PlannerBackupFileTests.read(PlannerBackupFileTests.encoded(file)).state();
        noSecrets(restored,"Backup retained source secrets");
        check(SyncLedger.equivalent(restored.get("completions"),raw.get("completions")),"Backup changed completion history");
        check(restored.getJSONArray("courses").getJSONObject(0).getJSONArray("lessonOrder").toString().equals("[\"b\",\"a\"]"),"Backup changed lesson order");
        check(before.equals(SyncLedger.canonical(raw)),"Backup mutated live state");
    }
    static SyncLedger dirtyLedger()throws Exception{
        JSONObject raw=fixture();SyncLedger ledger=new SyncLedger();ledger.capture(raw);
        for(JSONObject row:Planner.list(ledger.changes(0)))if(row.getString("kind").equals("courses")){
            JSONObject data=payload(row);data.put("netdisk",netdisk());
            ledger.records().getJSONObject(SyncLedger.key(row)).put("payload",Base64.getEncoder().encodeToString(data.toString().getBytes(StandardCharsets.UTF_8)));
        }
        return ledger;
    }
    static void wireAndCapture()throws Exception{
        JSONObject raw=fixture();String before=SyncLedger.canonical(raw);SyncLedger ledger=new SyncLedger();ledger.capture(raw);
        for(JSONObject row:Planner.list(ledger.changes(0)))if(row.getString("kind").equals("courses"))noSecrets(payload(row),"Fresh sync leaked");
        long sequence=ledger.sequence();ledger.capture(raw);check(ledger.sequence()==sequence,"Equivalent cleaned capture created another edit");
        check(before.equals(SyncLedger.canonical(raw)),"Capture mutated source");
        ledger=dirtyLedger();String ledgerBefore=SyncLedger.canonical(ledger.value);
        noSecrets(ledger.materialize(),"Materialized old ledger retained private URL");
        for(JSONObject row:Planner.list(ledger.changes(0)))if(row.getString("kind").equals("courses")){
            noSecrets(payload(row),"Legacy wire leaked");JSONObject original=ledger.records().getJSONObject(SyncLedger.key(row));
            for(String field:new String[]{"id","version","sequence","device","modifiedAt","deleted"})check(SyncLedger.equivalent(row.opt(field),original.opt(field)),"Wire changed "+field);
            JSONObject tombstone=SyncLedger.shallowCopy(original).put("deleted",true),clean=CourseSourcePrivacy.record(tombstone);
            noSecrets(payload(clean),"Tombstone leaked");check(clean.getBoolean("deleted"),"Tombstone revived");
        }
        check(ledgerBefore.equals(SyncLedger.canonical(ledger.value)),"Wire serialization mutated ledger");
        JSONObject opaque=new JSONObject().put("kind","courses").put("payload","").put("deleted",true);
        check(CourseSourcePrivacy.record(opaque)==opaque,"Opaque legacy tombstone changed");
    }
    static JSONObject readArchive(File file)throws Exception{
        try(InputStream in=new GZIPInputStream(new FileInputStream(file));ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] buffer=new byte[8192];for(int n;(n=in.read(buffer))!=-1;)out.write(buffer,0,n);
            return new JSONObject(out.toString("UTF-8"));
        }
    }
    static void queuedArchives()throws Exception{
        Path directory=Files.createTempDirectory("course-source-privacy");File file=directory.resolve("queued.json.gz").toFile();
        try{
            SyncLedger ledger=dirtyLedger();JSONArray rows=new JSONArray();Iterator<String> names=ledger.records().keys();
            while(names.hasNext())rows.put(ledger.records().getJSONObject(names.next()));
            JSONObject original=CloudSnapshot.header(ledger).put("records",rows);
            try(Writer out=new OutputStreamWriter(new GZIPOutputStream(new FileOutputStream(file)),StandardCharsets.UTF_8)){SyncJSON.write(out,original);}
            CloudSnapshot.sanitizeSourceURLs(file);JSONObject clean=readArchive(file);
            check(clean.getString("archiveID").equals(original.getString("archiveID")),"Queue identity changed");
            check(clean.getLong("createdAt")==original.getLong("createdAt"),"Queue time changed");
            JSONArray actual=clean.getJSONArray("records");check(actual.length()==rows.length(),"Queue records lost");
            for(int i=0;i<rows.length();i++)check(SyncLedger.equivalent(actual.getJSONObject(i),CourseSourcePrivacy.record(rows.getJSONObject(i))),"Queue record changed unexpectedly");
            byte[] first=Files.readAllBytes(file.toPath());CloudSnapshot.sanitizeSourceURLs(file);
            check(Arrays.equals(first,Files.readAllBytes(file.toPath())),"Clean queue rewritten");
            try(InputStream input=new FileInputStream(file)){noSecrets(CloudSnapshot.read(input).ledger.materialize(),"Clean archive cannot be imported safely");}
            byte[] broken={1,2,3,4};Files.write(file.toPath(),broken);
            try{CloudSnapshot.sanitizeSourceURLs(file);throw new AssertionError("Broken archive accepted");}catch(IOException expected){checks++;}
            check(Arrays.equals(broken,Files.readAllBytes(file.toPath())),"Failure replaced original queue file");
            check(directory.toFile().list().length==1,"Temporary file leaked");
        }finally{Files.deleteIfExists(file.toPath());Files.deleteIfExists(directory);}
    }
    static void largeQueue()throws Exception{
        Path directory=Files.createTempDirectory("source-privacy-memory");File file=directory.resolve("queued.json.gz").toFile();
        String padding=String.join("",Collections.nCopies(8192,"x"));int count=4000;
        try{
            SyncLedger ledger=new SyncLedger();ledger.capture(PlannerTests.empty());JSONObject header=CloudSnapshot.header(ledger);
            JSONObject setting=ledger.changes(0).getJSONObject(0);
            try(Writer out=new BufferedWriter(new OutputStreamWriter(new GZIPOutputStream(new FileOutputStream(file)),StandardCharsets.UTF_8))){
                String start=header.toString();out.write(start.substring(0,start.length()-1));out.write(",\"records\":[");SyncJSON.write(out,setting);
                for(int i=0;i<count;i++){
                    String id=Planner.id();JSONObject data=new JSONObject().put("id",id).put("netdisk",netdisk()).put("padding",padding);
                    JSONObject row=SyncLedger.shallowCopy(setting).put("kind","courses").put("id",id).put("deleted",true).put("sequence",i+2)
                        .put("payload",Base64.getEncoder().encodeToString(data.toString().getBytes(StandardCharsets.UTF_8)));
                    out.write(',');SyncJSON.write(out,row);
                }
                out.write("]}");
            }
            CloudSnapshot.sanitizeSourceURLs(file);int[] seen={0};JSONObject restored;
            try(Reader in=new BufferedReader(new InputStreamReader(new GZIPInputStream(new FileInputStream(file)),StandardCharsets.UTF_8))){
                restored=SyncJSON.readEnvelope(in,"records",Arrays.asList("format","archiveID","device","createdAt","serverID","revision"),row->{
                    if(row.getString("kind").equals("courses")){seen[0]++;JSONObject data=payload(row);noSecrets(data,"Large queue leaked");
                        check(data.getString("padding").equals(padding)&&row.getInt("sequence")==seen[0]+1,"Large queue changed data or sequence");}
                });
            }
            check(seen[0]==count&&restored.getString("archiveID").equals(header.getString("archiveID")),"Large queue lost records or identity");
            System.out.println("Course source privacy: 4000 queued records cleaned with a 32 MiB heap");
        }finally{Files.deleteIfExists(file.toPath());Files.deleteIfExists(directory);}
    }
    public static void main(String[] args)throws Exception{
        if(args.length>0&&args[0].equals("--large")){largeQueue();return;}
        urls();nestedAndImmutable();backupsAndProgress();wireAndCapture();queuedArchives();
        System.out.println("Course source privacy: "+checks+" checks passed");
    }
}
