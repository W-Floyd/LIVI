import org.jf.dexlib2.*;
import org.jf.dexlib2.iface.*;
import java.io.*;
import java.util.*;
import org.jf.dexlib2.AccessFlags;

/** Dump class/super/interfaces/methods/fields of dex files as tab-separated lines: C|M|F. */
public class DumpApi {
    public static void main(String[] a) throws Exception {
        PrintWriter w = new PrintWriter(new BufferedWriter(new FileWriter(a[0])));
        for (int i = 1; i < a.length; i++) {
            DexFile d = DexFileFactory.loadDexFile(new File(a[i]), Opcodes.getDefault());
            for (ClassDef c : d.getClasses()) {
                StringBuilder s = new StringBuilder("C\t" + c.getType() + "\t" + c.getSuperclass());
                for (String x : c.getInterfaces()) s.append("\t").append(x);
                w.println(s);
                for (Method m : c.getMethods()) {
                    StringBuilder p = new StringBuilder();
                    for (CharSequence t : m.getParameterTypes()) p.append(t);
                    w.println("M\t" + c.getType() + "\t" + m.getName() + "(" + p + ")" + m.getReturnType() + "\t" + (AccessFlags.FINAL.isSet(m.getAccessFlags()) ? "final" : "-"));
                }
                for (Field f : c.getFields()) w.println("F\t" + c.getType() + "\t" + f.getName() + ":" + f.getType());
            }
        }
        w.close();
    }
}
