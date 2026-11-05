package local.studyplanner;

import org.json.*;
import java.io.*;
import java.util.function.*;

/** Download-first policy, shared by production orchestration and offline regression tests. */
final class CloudSyncEngine {
    interface Store {
        SyncLedger read()throws Exception;
        // Must compare the checkpoint and, for replacement, durably back up before
        // atomically replacing rows and metadata under the same database lock.
        boolean commit(SyncLedger candidate,JSONObject checkpoint,boolean replace)throws Exception;
    }
    interface Remote {
        JSONObject status()throws Exception;
        JSONObject upload(File file)throws Exception;
        CloudSnapshot latest()throws Exception;
    }
    static final class Result {
        final long revision;final boolean changed,again,replaced;
        Result(long revision,boolean changed,boolean again,boolean replaced){this.revision=revision;this.changed=changed;this.again=again;this.replaced=replaced;}
    }
    final Store store;final Remote remote;final File outbox;final String endpoint;
    final DoubleSupplier now;final Consumer<String> status;
    CloudSyncEngine(Store store,Remote remote,File outbox,String endpoint,DoubleSupplier now,Consumer<String> status){
        this.store=store;this.remote=remote;this.outbox=outbox;this.endpoint=endpoint;this.now=now;this.status=status;
    }
    static void checkStatus(JSONObject result)throws Exception {
        if(result.getInt("format")!=1||!CloudSnapshot.validID(result.getString("serverID"))||result.getLong("revision")<0)
            throw new IOException("云端响应无效");
    }
    CloudSnapshot download(String identity,long revision)throws Exception {
        status.accept("正在下载最新云端课表…");
        CloudSnapshot archive=remote.latest();
        if(!identity.equals(archive.header.getString("serverID"))||archive.header.getLong("revision")<revision)
            throw new IOException("云端版本无效");
        return archive;
    }
    void progress(SyncLedger ledger,String identity,long revision,boolean dirty)throws Exception {
        ledger.value.put("cloudProgress",new JSONObject().put("endpoint",endpoint).put("serverID",identity).put("revision",revision)
            .put("uploadedSequence",dirty?-1:ledger.sequence()).put("lastSuccess",now.getAsDouble()));
    }
    Result sync()throws Exception {
        SyncLedger initial=store.read();long sequence=initial.sequence();
        // A crash after replacement must never cause the old outbox to be uploaded.
        CloudOutbox.discardReplaced(outbox,initial);
        JSONObject progress=initial.value.optJSONObject("cloudProgress");
        if(progress!=null&&!endpoint.equals(progress.optString("endpoint")))progress=null;
        JSONObject server=remote.status();checkStatus(server);String identity=server.getString("serverID");long revision=server.getLong("revision");
        if(progress!=null&&(!identity.equals(progress.optString("serverID"))||revision<progress.optLong("revision")))
            throw new IllegalStateException("云端身份或版本变化，待传数据已保留。请核对服务器后重新保存云同步配置。");
        boolean localDirty=progress==null||progress.optLong("uploadedSequence",-1)!=sequence;
        File[] queued=CloudOutbox.queued(outbox);
        if(!localDirty&&queued.length==0&&progress.optLong("revision")==revision)
            return new Result(revision,false,false,false);

        // Compare before sending any local snapshot, so stale local data cannot
        // alter the server revision or manufacture a newer server file timestamp.
        CloudSnapshot archive=revision>0?download(identity,revision):null;
        if(archive!=null){
            revision=archive.header.getLong("revision");
            if(CloudReplacement.serverNewer(initial,archive.ledger)){
                SyncLedger replacement=CloudReplacement.prepare(initial,archive.ledger);
                progress(replacement,identity,revision,false);
                status.accept("云端课表较新，正在备份手机日程并更新…");
                if(!store.commit(replacement,initial.metadata(),true))return new Result(revision,false,true,false);
                CloudOutbox.discardReplaced(outbox,replacement);
                return new Result(revision,true,false,true);
            }
        }
        // A user edit during the comparison deserves a fresh decision, not an
        // upload or replacement based on the earlier local snapshot.
        if(!SyncLedger.equivalent(initial.metadata(),store.read().metadata()))return new Result(revision,false,true,false);
        if(localDirty)CloudOutbox.enqueue(outbox,initial);
        queued=CloudOutbox.queued(outbox);
        for(File file:queued){
            status.accept("正在上传手机课表…");CloudSnapshot.sanitizeSourceURLs(file);
            JSONObject reply=remote.upload(file);checkStatus(reply);
            if(!identity.equals(reply.getString("serverID"))||reply.getLong("revision")<revision)throw new IOException("云端身份或版本变化");
            revision=reply.getLong("revision");
        }
        if(queued.length>0){archive=download(identity,revision);revision=archive.header.getLong("revision");}
        boolean dirty,changed;
        status.accept("正在保存同步结果…");
        while(true){
            SyncLedger current=store.read();JSONObject checkpoint=current.metadata();dirty=current.sequence()!=sequence;
            if(archive!=null)current.merge(archive.ledger.changes(0));
            long beforeRepair=current.sequence();SyncExchange.repairMergedSchedule(current,now.getAsDouble());
            dirty|=current.sequence()!=beforeRepair;changed=current.sequence()!=checkpoint.optLong("sequence");
            progress(current,identity,revision,dirty);
            if(store.commit(current,checkpoint,false))break;
        }
        CloudOutbox.remove(queued);
        return new Result(revision,changed,dirty,false);
    }
}
