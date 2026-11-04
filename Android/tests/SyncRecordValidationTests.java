package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.*;

/** Wire values must remain readable by Swift Codable, including ignored tombstones. */
public final class SyncRecordValidationTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject validRow()throws Exception{
        return new JSONObject().put("kind","tasks").put("id",Planner.stableID("wire-validation-tombstone"))
            .put("payload","e30=").put("deleted",true).put("version",1).put("modifiedAt",1)
            .put("device","wire-validation").put("sequence",1);
    }
    static Map<String,JSONObject> invalidRows()throws Exception{
        Map<String,JSONObject> rows=new LinkedHashMap<>();
        rows.put("invalid base64",validRow().put("payload","!"));
        rows.put("invalid padded-length base64",validRow().put("payload","!!!!"));
        rows.put("unpadded base64",validRow().put("payload","e30"));
        rows.put("numeric base64 payload",validRow().put("payload",1000));
        rows.put("numeric device",validRow().put("device",1234));
        rows.put("oversized decoded payload",validRow().put("payload",Base64.getEncoder().encodeToString(new byte[1_000_001])));
        rows.put("fractional version",validRow().put("version",1.5));
        rows.put("string version",validRow().put("version","1"));
        rows.put("overflowing version",validRow().put("version",new BigInteger("18446744073709551617")));
        rows.put("version safety bound",validRow().put("version",Long.MAX_VALUE-1_000_000));
        rows.put("fractional modifiedAt",validRow().put("modifiedAt",1.5));
        rows.put("string modifiedAt",validRow().put("modifiedAt","1"));
        rows.put("overflowing modifiedAt",validRow().put("modifiedAt",new BigInteger("18446744073709551617")));
        rows.put("modifiedAt safety bound",validRow().put("modifiedAt",Long.MAX_VALUE-1_000_000));
        rows.put("string deleted flag",validRow().put("deleted","true"));
        rows.put("string sequence",validRow().put("sequence","1"));
        rows.put("fractional sequence",validRow().put("sequence",1.5));
        rows.put("overflowing sequence",validRow().put("sequence",new BigInteger("18446744073709551617")));
        for(String field:new String[]{"version","sequence","deleted"})rows.put("null "+field,validRow().put(field,JSONObject.NULL));
        return rows;
    }
    static byte[] packedWithRow(JSONObject row)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(SyncExchangeTests.initial());
        // Append external input only after valid ledger rows have been selected.
        // Malformed sequence values must reach the reader, not ledger.changes().
        JSONObject envelope=CloudSnapshot.header(ledger).put("records",ledger.changes(0).put(row));
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(Writer writer=new OutputStreamWriter(new GZIPOutputStream(bytes),StandardCharsets.UTF_8)){
            SyncJSON.write(writer,envelope);
        }
        return bytes.toByteArray();
    }
    public static void main(String[] args)throws Exception{
        for(Map.Entry<String,JSONObject> sample:invalidRows().entrySet()){
            SyncLedger ledger=new SyncLedger();String before=ledger.value.toString();boolean rejected=false;
            try{ledger.mergeRecord(sample.getValue());}catch(Exception expected){rejected=true;}
            check(rejected,"accepted "+sample.getKey());
            check(before.equals(ledger.value.toString()),"rejected "+sample.getKey()+" changed ledger");
            // Construction failures must fail the test, not masquerade as reader rejection.
            byte[] packed=packedWithRow(sample.getValue());
            try(GZIPInputStream input=new GZIPInputStream(new ByteArrayInputStream(packed))){
                JSONArray rows=new JSONObject(new String(input.readAllBytes(),StandardCharsets.UTF_8)).getJSONArray("records");
                check(SyncLedger.equivalent(rows.getJSONObject(rows.length()-1),sample.getValue()),"fixture changed invalid row: "+sample.getKey());
            }
            rejected=false;try{CloudSnapshot.read(new ByteArrayInputStream(packed));}catch(Exception expected){rejected=true;}
            check(rejected,"archive accepted "+sample.getKey());
        }
        for(Object number:new Object[]{1,1L,1.0,new BigDecimal("1e0")}){
            JSONObject row=validRow().put("version",number).put("modifiedAt",number).put("sequence",number);
            SyncLedger ledger=new SyncLedger();ledger.mergeRecord(row);
            check(ledger.records().length()==1,"integer-valued number rejected");
            check(CloudSnapshot.read(new ByteArrayInputStream(packedWithRow(row))).ledger.records().has(SyncLedger.key(row)),"valid historical row lost");
        }
        JSONObject legacy=validRow();legacy.remove("modifiedAt");SyncLedger ledger=new SyncLedger();ledger.mergeRecord(legacy);
        check(ledger.records().length()==1,"legacy missing modifiedAt rejected");
        JSONObject nullable=validRow().put("modifiedAt",JSONObject.NULL),zero=validRow().put("modifiedAt",0);
        ledger=new SyncLedger();ledger.mergeRecord(nullable);
        check(ledger.records().getJSONObject(SyncLedger.key(nullable)).isNull("modifiedAt"),"optional null timestamp changed");
        check(!SyncLedger.wins(nullable,zero)&&!SyncLedger.wins(zero,nullable),"null timestamp differs from zero for ordering");
        check(!SyncLedger.wins(nullable,legacy)&&!SyncLedger.wins(legacy,nullable),"null timestamp differs from missing for ordering");
        JSONObject newer=validRow().put("modifiedAt",0).put("version",2);
        check(SyncLedger.wins(newer,nullable)&&!SyncLedger.wins(nullable,newer),"null timestamp bypasses version ordering");
        SyncLedger reopened=CloudSnapshot.read(new ByteArrayInputStream(packedWithRow(nullable))).ledger;
        check(reopened.records().getJSONObject(SyncLedger.key(nullable)).isNull("modifiedAt"),"archive lost optional null timestamp");
        JSONObject maximum=validRow().put("payload",Base64.getEncoder().encodeToString(new byte[1_000_000]));
        ledger=new SyncLedger();ledger.mergeRecord(maximum);check(ledger.records().length()==1,"payload at supported limit rejected");
        System.out.println("PASS "+checks+" strict wire checks: malformed tombstones, atomic rejection, exact integers and legacy compatibility");
    }
}
