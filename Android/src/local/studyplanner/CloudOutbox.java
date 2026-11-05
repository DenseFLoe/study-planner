package local.studyplanner;

import java.io.*;
import java.util.*;

/** Durable complete snapshots, with a database-persisted discard boundary. */
final class CloudOutbox {
    static void enqueue(File directory,SyncLedger ledger)throws Exception {
        if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("无法创建待上传目录");
        File destination=new File(directory,ledger.value.getString("device")+"-"+ledger.sequence()+".json.gz");
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
            try{sequence=Long.parseLong(name.substring(prefix.length(),name.length()-suffix.length()));}
            catch(NumberFormatException error){continue;}
            if(sequence>=0&&sequence<=through)remove(new File[]{file});
        }
    }
}
