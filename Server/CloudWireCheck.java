package local.studyplanner;
import java.nio.file.*;
import java.io.*;
public final class CloudWireCheck {
    public static void main(String[] args)throws Exception{
        try(InputStream in=Files.newInputStream(Path.of(args[0]))){
            CloudSnapshot snapshot=CloudSnapshot.read(in);
            if(snapshot.ledger.materialize().getJSONArray("courses").length()!=1||snapshot.ledger.materialize().getJSONArray("completions").length()!=1)throw new AssertionError("Swift round-trip changed data");
            System.out.println("PASS Swift gzip snapshot -> Java full ledger, confirmations and tombstones");
        }
    }
}
