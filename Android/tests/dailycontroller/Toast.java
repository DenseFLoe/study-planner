package android.widget;
/** Test-only toast boundary. */
public final class Toast {
    public static final int LENGTH_SHORT=0;
    public static int shown;
    public static Toast makeText(Object context,CharSequence text,int duration){return new Toast();}
    public void show(){shown++;}
}
