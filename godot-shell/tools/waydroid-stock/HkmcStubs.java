package com.livi.waydroid;

import android.content.Context;
import java.lang.reflect.*;
import java.util.*;

/** Runtime helpers the patched app calls instead of the vendor framework. */
public final class HkmcStubs {
    private HkmcStubs() {}

    /** Context.getSystemService with a fallback for vendor-only service names. */
    public static Object get(Context c, String name) {
        Object o = c.getSystemService(name);
        if (o != null) return o;
        if ("dipo".equals(name)) {
            try {
                Class<?> i = Class.forName("android.dipo.IDiPOManager");
                return Class.forName("android.dipo.DiPOManager").getConstructor(Context.class, i).newInstance(c, proxy(i));
            } catch (Throwable t) { /* fall through */ }
        }
        return null;
    }

    /** Service.startForeground with an icon: A13 rejects the empty Notification the stock app posts. */
    @SuppressWarnings("deprecation")
    public static void startForeground(android.app.Service s, int id, android.app.Notification n) {
        if (n.icon == 0) n.icon = android.R.drawable.ic_dialog_info;
        s.startForeground(id, n);
    }

    /** An interface implementation that answers every call with a default value. */
    public static Object proxy(Class<?> i) {
        return Proxy.newProxyInstance(i.getClassLoader(), new Class<?>[] {i}, (p, m, a) -> {
            switch (m.getName()) {
                case "equals": return p == a[0];
                case "hashCode": return System.identityHashCode(p);
                case "toString": return "stub:" + i.getName();
            }
            return dflt(m.getReturnType());
        });
    }

    /** New instance of a stub class via its smallest constructor, arguments zeroed. */
    public static Object instance(Class<?> k) {
        try {
            Constructor<?>[] cs = k.getConstructors();
            Constructor<?> best = null;
            for (Constructor<?> c : cs) if (best == null || c.getParameterTypes().length < best.getParameterTypes().length) best = c;
            if (best == null) return null;
            Class<?>[] pt = best.getParameterTypes();
            Object[] args = new Object[pt.length];
            for (int n = 0; n < pt.length; n++) args[n] = pt[n].isPrimitive() ? dflt(pt[n]) : null;
            return best.newInstance(args);
        } catch (Throwable t) { return null; }
    }

    static Object dflt(Class<?> r) {
        if (r == void.class) return null;
        if (r == boolean.class) return false;
        if (r == int.class) return 0;
        if (r == long.class) return 0L;
        if (r == float.class) return 0f;
        if (r == double.class) return 0d;
        if (r == short.class) return (short) 0;
        if (r == byte.class) return (byte) 0;
        if (r == char.class) return (char) 0;
        if (r == String.class) return "";
        if (r.isArray()) return Array.newInstance(r.getComponentType(), r.getComponentType().isPrimitive() ? 16 : 0);
        if (r == List.class || r == Collection.class) return new ArrayList<Object>();
        if (r == Map.class) return new HashMap<Object, Object>();
        if (r.isInterface()) return proxy(r);
        return null;
    }
}
