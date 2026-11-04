package local.studyplanner;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** All content here is an inert placeholder, never an authentication key. */
public final class SSHKeyImportTests {
    static int checks;
    static final String PLACEHOLDER = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nEXAMPLE_PLACEHOLDER\n-----END OPENSSH PRIVATE KEY-----\n";
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static final class TrackedInput extends ByteArrayInputStream {
        boolean closed;
        TrackedInput(byte[] value) { super(value); }
        public void close() { closed = true; }
        int consumed() { return pos; }
    }
    static void rejects(byte[] bytes) throws Exception {
        TrackedInput input = new TrackedInput(bytes);
        try { CloudSSHConfig.readPrivateKey(input); throw new AssertionError("Invalid key file accepted"); }
        catch (IOException expected) { check(input.closed, "Rejected input was not closed"); check(!expected.toString().contains("EXAMPLE_PLACEHOLDER"), "Failure exposed input contents"); }
    }
    public static void main(String[] args) throws Exception {
        byte[] valid = PLACEHOLDER.getBytes(StandardCharsets.UTF_8);
        TrackedInput input = new TrackedInput(valid);
        check(CloudSSHConfig.readPrivateKey(input).equals(PLACEHOLDER) && input.closed, "Successful read changed contents or leaked stream");
        byte[] boundary = Arrays.copyOf(valid, CloudSSHConfig.MAX_KEY_BYTES); Arrays.fill(boundary, valid.length, boundary.length, (byte)' ');
        input = new TrackedInput(boundary);
        check(CloudSSHConfig.readPrivateKey(input).getBytes(StandardCharsets.UTF_8).length == CloudSSHConfig.MAX_KEY_BYTES && input.closed, "Exact limit rejected or stream leaked");
        byte[] tooLarge = Arrays.copyOf(boundary, CloudSSHConfig.MAX_KEY_BYTES + 10000); input = new TrackedInput(tooLarge);
        try { CloudSSHConfig.readPrivateKey(input); throw new AssertionError("Oversized key accepted"); }
        catch (IOException expected) { check(input.closed && input.consumed() == CloudSSHConfig.MAX_KEY_BYTES + 1, "Reader exceeded bounded lookahead or leaked input"); }
        byte[] invalidUTF8 = Arrays.copyOf(valid, valid.length + 2); invalidUTF8[valid.length] = (byte)0xc3; invalidUTF8[valid.length + 1] = (byte)0x28;
        rejects(invalidUTF8); rejects("ssh-ed25519 EXAMPLE_PUBLIC_KEY".getBytes(StandardCharsets.UTF_8)); rejects(new byte[0]);
        final boolean[] closed = {false};
        InputStream failing = new InputStream() {
            public int read() throws IOException { throw new IOException("Synthetic provider failure"); }
            public void close() { closed[0] = true; }
        };
        try { CloudSSHConfig.readPrivateKey(failing); throw new AssertionError("Provider failure ignored"); }
        catch (IOException expected) { check(closed[0], "Failing provider stream not closed"); }
        try { CloudSSHConfig.readPrivateKey(null); throw new AssertionError("Null provider stream accepted"); }
        catch (IOException expected) { checks++; }
        System.out.println("SSH key import: " + checks + " checks passed");
    }
}
