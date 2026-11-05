package local.studyplanner;

import org.json.*;
import java.util.*;

/** Compare business edits, never archive creation/download time. */
final class CloudReplacement {
    static long modifiedAt(SyncLedger ledger)throws Exception {
        long latest=0,datedVersion=0,legacyVersion=0;
        Iterator<String> keys=ledger.records().keys();
        while(keys.hasNext()){
            JSONObject row=ledger.records().getJSONObject(keys.next());
            // Older legacy rows do not invalidate a later dated ledger revision.
            // Undated edits beyond every dated revision remain ambiguous.
            if(!row.has("modifiedAt")||row.isNull("modifiedAt")||row.optLong("modifiedAt")==0){legacyVersion=Math.max(legacyVersion,row.getLong("version"));continue;}
            long time=SyncLedger.wireInteger(row,"modifiedAt");
            if(time<=0)return -1;
            latest=Math.max(latest,time);datedVersion=Math.max(datedVersion,row.getLong("version"));
        }
        return latest==0||legacyVersion>datedVersion?-1:latest;
    }
    static boolean serverNewer(SyncLedger local,SyncLedger remote)throws Exception {
        long localTime=modifiedAt(local),remoteTime=modifiedAt(remote);
        return localTime>0&&remoteTime>localTime;
    }
    static SyncLedger prepare(SyncLedger local,SyncLedger remote)throws Exception {
        if(!serverNewer(local,remote))throw new IllegalArgumentException("云端课表并未更新，未覆盖手机日程。");
        JSONObject expected=remote.materialize();
        SyncLedger result=new SyncLedger(CourseTools.copy(local.metadata()).put("records",new JSONObject()));
        result.merge(remote.changes(0));
        // Keep cursors monotonic and send removals to already paired peers. These
        // tombstones use the winning snapshot's edit time, not the download time.
        long clock=Math.max(local.value.getLong("clock"),remote.value.getLong("clock"))+1;
        long modified=modifiedAt(remote);
        Iterator<String> keys=local.records().keys();
        while(keys.hasNext()){
            String key=keys.next();if(result.records().has(key))continue;
            JSONObject removed=SyncLedger.shallowCopy(local.records().getJSONObject(key));
            removed.put("deleted",true).put("modifiedAt",modified).put("version",clock).put("device",local.value.getString("device"));
            result.mergeRecord(removed);
        }
        if(!SyncLedger.equivalent(PlannerBackupFile.businessState(expected),PlannerBackupFile.businessState(result.materialize())))
            throw new IllegalStateException("云端课表未能完整还原，手机原数据已保留。");
        result.value.put("cloudDiscardedSequence",Math.max(local.sequence(),local.value.optLong("cloudDiscardedSequence")));
        return result;
    }
}
