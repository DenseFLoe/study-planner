package local.studyplanner;

import android.content.Context;
import android.graphics.Typeface;
import android.text.*;
import android.text.style.*;
import android.widget.*;
import java.util.*;
import java.util.regex.*;

/** Deterministic native text rendering. No HTML, WebView, remote images or clickable links. */
final class AssistantMarkdown {
    static CharSequence inline(String raw){
        String text=raw.replaceAll("!?\\[([^\\]]*)\\]\\([^)]*\\)","$1");SpannableStringBuilder out=new SpannableStringBuilder();
        Matcher m=Pattern.compile("\\*\\*(.+?)\\*\\*|`([^`]+)`").matcher(text);int at=0;
        while(m.find()){out.append(text,at,m.start());int start=out.length();out.append(m.group(1)!=null?m.group(1):m.group(2));if(m.group(1)!=null)out.setSpan(new StyleSpan(Typeface.BOLD),start,out.length(),Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);else out.setSpan(new TypefaceSpan("monospace"),start,out.length(),Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);at=m.end();}out.append(text.substring(at));return out;
    }
    static TextView text(Context c,String value,int size){TextView t=new TextView(c);t.setText(inline(value));t.setTextColor(0xff191919);t.setTextSize(size);t.setTextIsSelectable(true);t.setAutoLinkMask(0);t.setPadding(0,5,0,7);return t;}
    static String[] cells(String line){return line.trim().replaceAll("^\\||\\|$","").split("\\|",-1);}
    static void render(Context c,LinearLayout parent,String source){
        String[] lines=source.replace("\r\n","\n").split("\n",-1);StringBuilder paragraph=new StringBuilder();
        for(int i=0;i<lines.length;i++){
            String line=lines[i],trim=line.trim();
            if(trim.startsWith("```")){
                flush(c,parent,paragraph);StringBuilder code=new StringBuilder();while(++i<lines.length&&!lines[i].trim().startsWith("```")){if(code.length()>0)code.append('\n');code.append(lines[i]);}
                TextView t=text(c,"",14);t.setTypeface(Typeface.MONOSPACE);t.setText(code);t.setBackgroundColor(0xfff1f3f5);HorizontalScrollView scroll=new HorizontalScrollView(c);scroll.addView(t);parent.addView(scroll);continue;
            }
            if(i+1<lines.length&&line.contains("|")&&lines[i+1].trim().matches("\\|?\\s*:?-{3,}:?\\s*(?:\\|\\s*:?-{3,}:?\\s*)+\\|?")){
                flush(c,parent,paragraph);TableLayout table=new TableLayout(c);addRow(c,table,cells(line),true);i++;
                while(i+1<lines.length&&lines[i+1].contains("|"))addRow(c,table,cells(lines[++i]),false);
                HorizontalScrollView scroll=new HorizontalScrollView(c);scroll.addView(table);parent.addView(scroll);continue;
            }
            if(trim.isEmpty()){flush(c,parent,paragraph);continue;}
            if(trim.matches("#{1,6} .+")){flush(c,parent,paragraph);TextView t=text(c,trim.replaceFirst("^#{1,6} ",""),19);t.setTypeface(null,Typeface.BOLD);parent.addView(t);continue;}
            if(trim.startsWith("> ")||trim.matches("(?:[-*+] |[0-9]+[.)] ).+")){
                flush(c,parent,paragraph);TextView t=text(c,trim.startsWith("> ")?"│ "+trim.substring(2):trim.replaceFirst("^[-*+] ","• "),16);t.setPadding(12,5,0,7);parent.addView(t);continue;
            }
            if(paragraph.length()>0)paragraph.append('\n');paragraph.append(line);
        }flush(c,parent,paragraph);
    }
    static void flush(Context c,LinearLayout parent,StringBuilder paragraph){if(paragraph.length()>0){parent.addView(text(c,paragraph.toString(),16));paragraph.setLength(0);}}
    static void addRow(Context c,TableLayout table,String[] cells,boolean header){TableRow row=new TableRow(c);for(String cell:cells){TextView t=text(c,cell.trim(),14);t.setPadding(12,8,18,8);if(header)t.setTypeface(null,Typeface.BOLD);row.addView(t);}row.setBackgroundColor(header?0xffe9f3ed:0xfffafafa);table.addView(row);}
}
