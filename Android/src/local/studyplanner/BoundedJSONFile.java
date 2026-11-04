package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.*;

/** Bounded strict UTF-8 object reader for local files; takes ownership of the stream. */
final class BoundedJSONFile {
    static JSONObject read(InputStream input, long maximum, String label) throws Exception {
        if (input == null) throw new IOException("无法打开" + label);
        if (maximum < 0 || maximum == Long.MAX_VALUE) throw new IllegalArgumentException("无效的文件大小限制");
        StringBuilder text = new StringBuilder(); int depth = 0; boolean quoted = false, escaped = false;
        try (Reader reader = new BufferedReader(new InputStreamReader(new CloudSnapshot.LimitedInput(input, maximum),
                StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)))) {
            char[] buffer = new char[8192]; int count;
            while ((count = reader.read(buffer)) != -1) {
                for (int i = 0; i < count; i++) {
                    char c = buffer[i];
                    if (c == 0) throw new IOException(label + "含有无效字符");
                    if (quoted) { if (escaped) escaped = false; else if (c == '\\') escaped = true; else if (c == '"') quoted = false; }
                    else if (c == '"') quoted = true;
                    else if (c == '{' || c == '[') { if (++depth > 64) throw new IOException(label + "嵌套层级过深"); }
                    else if (c == '}' || c == ']') depth--;
                }
                text.append(buffer, 0, count);
            }
        }
        JSONTokener tokens = new JSONTokener(text.toString()); JSONObject value = new JSONObject(tokens);
        if (tokens.nextClean() != 0) throw new IOException(label + "含有多余内容");
        return value;
    }

}
