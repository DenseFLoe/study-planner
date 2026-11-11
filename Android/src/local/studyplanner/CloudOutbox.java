package local.studyplanner;

import java.io.*;
import java.util.*;

/** Durable complete snapshots, with a database-persisted discard boundary. */
final class CloudOutbox {
    private static String snapshotPrefix(SyncLedger ledger)throws Exception {
        String device=ledger.value.getString("device");
        // Device metadata can be restored from disk. Only a single filename component is allowed.
        if(!device.matches("[A-Za-z0-9_-]{1,64}")||ledger.sequence()<0)
            throw new IOException("待上传快照的设备编号或序号无效");
        return device+"-"+ledger.sequence();
    }
    static void enqueue(File directory,SyncLedger ledger)throws Exception {
        String prefix=snapshotPrefix(ledger);
        if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("无法创建待上传目录");
        File destination=new File(directory,prefix+".json.gz");
        if(destination.exists())return;
        File temporary=File.createTempFile(".pending-",".tmp",directory);
        try{
            try(FileOutputStream out=new FileOutputStream(temporary)){
                CloudSnapshot.write(new FilterOutputStream(out){public void close()throws IOException{flush();}},ledger,CloudSnapshot.header(ledger));
                out.getFD().sync();
            }
            if(!temporary.renameTo(destination))throw new IOException("无法保存待上传文件");
        }finally{temporary.delete();}
    }
    static File prepare(File directory,SyncLedger ledger)throws Exception {
        String prefix=snapshotPrefix(ledger);
        if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("无法创建待上传目录");
        File file=File.createTempFile(prefix+".prepared-",".json.gz",directory);
        boolean saved=false;
        try{
            org.json.JSONObject header=CloudSnapshot.header(ledger).put("archiveID",java.util.UUID.randomUUID().toString().toUpperCase(java.util.Locale.ROOT));
            try(FileOutputStream out=new FileOutputStream(file)){CloudSnapshot.write(new FilterOutputStream(out){public void close()throws IOException{flush();}},ledger,header);out.getFD().sync();}
            saved=true;return file;
        }finally{if(!saved)file.delete();}
    }
    static File[] queued(File directory)throws IOException {
        if(!directory.exists())return new File[0];
        File[] files=directory.listFiles((dir,name)->name.endsWith(".json.gz"));
        if(files==null)throw new IOException("无法读取待上传目录");
        Arrays.sort(files,Comparator.comparingLong(File::lastModified).thenComparing(File::getName));
        return files;
    }
    static void remove(File[] files)throws IOException {
        for(File file:files)if(!file.delete()&&file.exists())throw new IOException("无法清理已处理的待上传文件");
    }
    static void discardReplaced(File directory,SyncLedger ledger)throws Exception {
        long through=ledger.value.optLong("cloudDiscardedSequence",-1);if(through<0)return;
        String prefix=ledger.value.getString("device")+"-",suffix=".json.gz";
        for(File file:queued(directory)){
            String name=file.getName();if(!name.startsWith(prefix))continue;
            long sequence;
            try{String number=name.substring(prefix.length(),name.length()-suffix.length());int marker=number.indexOf(".prepared-");if(marker>=0)number=number.substring(0,marker);sequence=Long.parseLong(number);}
            catch(NumberFormatException error){continue;}
            if(sequence>=0&&sequence<=through)remove(new File[]{file});
        }
    }
}
