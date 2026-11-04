package local.studyplanner;

import org.json.JSONObject;
import java.io.*;
import java.nio.file.*;

/** One device-private recovery point, written durably before replacing planner data. */
final class LocalRestoreBackup {
    private final File file;
    LocalRestoreBackup(File file) { this.file = file; }
    synchronized PlannerBackupFile load() throws Exception {
        if (!file.isFile()) throw new IOException("尚无恢复前的本机备份。首次从文件恢复日程后会自动保留一份。");
        return PlannerBackupFile.read(new FileInputStream(file));
    }
    synchronized void restore(JSONObject current, PlannerBackupFile.Restore reviewed, double now) throws Exception {
        reviewed.check(current);
        save(PlannerBackupFile.create(current, now, "恢复备份前的手机日程"));
        reviewed.apply(current);
    }
    private void save(PlannerBackupFile backup) throws Exception {
        File parent = file.getAbsoluteFile().getParentFile();
        if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("无法保存恢复前的日程，未执行恢复。");
        File temporary = File.createTempFile("restore-", ".tmp", parent);
        try {
            temporary.setReadable(false, false); temporary.setWritable(false, false);
            temporary.setReadable(true, true); temporary.setWritable(true, true);
            try (FileOutputStream bytes = new FileOutputStream(temporary)) {
                // The backup writer closes its stream; retain the descriptor until fsync completes.
                OutputStream retained = new OutputStream() {
                    public void write(int value) throws IOException { bytes.write(value); }
                    public void write(byte[] value, int offset, int count) throws IOException { bytes.write(value, offset, count); }
                    public void flush() throws IOException { bytes.flush(); }
                    public void close() throws IOException { flush(); }
                };
                backup.write(retained); bytes.getFD().sync();
            }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } finally { Files.deleteIfExists(temporary.toPath()); }
    }
}
