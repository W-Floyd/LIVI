// libGLES_emu.so, bound over /system/lib/egl/libGLES_android.so (overlay/init.emu-egl.rc), chooses the GLES driver
// per process: SwiftShader (GLES 2/3) for the processes named in debug.emu.gles2 (comma-separated, or *), the stock
// libGLES_android (GLES 1.x only) for the rest, so SurfaceFlinger and the other apps keep the renderer they have.
//
// The loader takes a single libGLES_*.so as EGL, GLESv1_CM and GLESv2 at once and resolves every name
// it does not find by dlsym through eglGetProcAddress, so this exports only that. It resolves the GLESv1 table,
// then the GLESv2 one, with the same names: SwiftShader has no GLES 1, so the first pass gets nothing.
// Needs ro.zygote.disable_gl_preload=1: otherwise zygote loads this once, as "zygote", for every app.
#include <android/log.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>

#define TAG "gles_emu"
#define EXPORT __attribute__((visibility("default")))
#define STOCK "/system/vendor/lib/egl/libagl.so"   // the stock libGLES_android, copied by init.emu-egl.rc

typedef void (*fn_t)(void);
static void *egl, *gles2;   // backend libraries (one and the same for libGLES_android)
static fn_t (*backend_gpa)(const char *);
static int swiftshader;
static char *first_gl;      // the first GL name looked up; seeing it again starts the GLESv2 table
static int gl_pass;

static int selected(void) {
	char want[PROP_VALUE_MAX] = "", name[256] = "";
	__system_property_get("debug.emu.gles2", want);
	if (!want[0])
		return 0;
	if (!strcmp(want, "*"))
		return 1;
	FILE *f = fopen("/proc/self/cmdline", "r");
	if (!f)
		return 0;
	size_t n = fread(name, 1, sizeof name - 1, f);   // argv[0], NUL-terminated
	fclose(f);
	name[n] = 0;
	for (char *s = want, *t; (t = strsep(&s, ","));)
		if (*t && !strcmp(t, name))
			return 1;
	return 0;
}

static void *open_emu(const char *lib) {
	char path[64];
	snprintf(path, sizeof path, "/emu-egl/%s", lib);
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!h)
		__android_log_print(ANDROID_LOG_ERROR, TAG, "dlopen %s: %s", path, dlerror());
	return h;
}

__attribute__((constructor)) static void init(void) {
	if (selected()) {
		egl = open_emu("libEGL_swiftshader.so");
		gles2 = egl ? open_emu("libGLESv2_swiftshader.so") : NULL;
		swiftshader = egl && gles2;
	}
	if (!swiftshader && !(egl = gles2 = dlopen(STOCK, RTLD_NOW | RTLD_LOCAL)))
		__android_log_print(ANDROID_LOG_ERROR, TAG, "dlopen %s: %s", STOCK, dlerror());
	backend_gpa = egl ? (fn_t(*)(const char *))dlsym(egl, "eglGetProcAddress") : NULL;
	__android_log_print(ANDROID_LOG_INFO, TAG, "backend %s", swiftshader ? "swiftshader" : "libGLES_android");
}

EXPORT fn_t eglGetProcAddress(const char *name) {
	fn_t f = NULL;
	if (!backend_gpa || !name)
		return NULL;
	if (!strncmp(name, "egl", 3))
		return strcmp(name, "eglGetProcAddress") ? ((f = (fn_t)dlsym(egl, name)) ? f : backend_gpa(name))
		                                         : (fn_t)eglGetProcAddress;
	if (swiftshader) {
		if (!first_gl)
			first_gl = strdup(name), gl_pass = 1;
		else if (gl_pass == 1 && !strcmp(name, first_gl))
			gl_pass = 2;
		if (gl_pass == 1)
			return NULL;
	}
	return (f = (fn_t)dlsym(gles2, name)) ? f : backend_gpa(name);
}
