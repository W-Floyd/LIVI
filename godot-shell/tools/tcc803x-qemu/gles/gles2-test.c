// GLES 2 smoke test through the system EGL loader: context, shader, one triangle into a pbuffer (or, with
// "window", a top-most SurfaceFlinger layer), read back, then frames per second for a full-screen draw.
// Run with debug.emu.gles2 naming it (or *).
// usage: gles2-test [width height frames [window]]
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// A SurfaceFlinger layer through libgui's C++ API (4.4 ABI, by symbol): no NDK way to get a window without an APK.
// sp<T> returns go through a hidden result pointer before `this`; Surface's ANativeWindow is found by its magic.
static EGLNativeWindowType sf_window(int w, int h) {
	void *gui = dlopen("libgui.so", RTLD_NOW), *utils = dlopen("libutils.so", RTLD_NOW);
	if (!gui || !utils)
		return NULL;
	void (*client_ctor)(void *) = dlsym(gui, "_ZN7android21SurfaceComposerClientC1Ev");
	void (*inc_strong)(void *, const void *) = dlsym(utils, "_ZNK7android7RefBase9incStrongEPKv");
	void (*string8)(void *, const char *) = dlsym(utils, "_ZN7android7String8C1EPKc");
	void (*create)(void **, void *, void *, uint32_t, uint32_t, int, uint32_t) =
		dlsym(gui, "_ZN7android21SurfaceComposerClient13createSurfaceERKNS_7String8Ejjij");
	void (*open_tx)(void) = dlsym(gui, "_ZN7android21SurfaceComposerClient21openGlobalTransactionEv");
	void (*close_tx)(int) = dlsym(gui, "_ZN7android21SurfaceComposerClient22closeGlobalTransactionEb");
	int (*set_layer)(void *, int) = dlsym(gui, "_ZN7android14SurfaceControl8setLayerEi");
	int (*show)(void *) = dlsym(gui, "_ZN7android14SurfaceControl4showEv");
	void (*get_surface)(void **, void *) = dlsym(gui, "_ZNK7android14SurfaceControl10getSurfaceEv");
	if (!client_ctor || !inc_strong || !string8 || !create || !open_tx || !close_tx || !set_layer || !show || !get_surface)
		return NULL;
	void *client = calloc(1, 1024), *name, *control = NULL, *surface = NULL;   // never freed
	client_ctor(client);
	inc_strong(client, client);   // the first strong ref connects to SurfaceFlinger
	string8(&name, "gles2-test");
	create(&control, client, &name, w, h, 1 /* RGBA_8888 */, 0);
	if (!control)
		return NULL;
	open_tx();
	set_layer(control, 0x7fffffff);
	show(control);
	close_tx(0);
	get_surface(&surface, control);
	for (uint32_t *p = surface; p && p < (uint32_t *)surface + 64; p++)
		if (*p == (('_' << 24) | ('w' << 16) | ('n' << 8) | 'd'))
			return (EGLNativeWindowType)p;
	return NULL;
}

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static GLuint shader(GLenum type, const char *src) {
	GLuint s = glCreateShader(type);
	GLint ok = 0;
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512];
		glGetShaderInfoLog(s, sizeof log, NULL, log);
		fprintf(stderr, "shader: %s\n", log);
		exit(1);
	}
	return s;
}

int main(int argc, char **argv) {
	int w = argc > 2 ? atoi(argv[1]) : 1920, h = argc > 2 ? atoi(argv[2]) : 720, frames = argc > 3 ? atoi(argv[3]) : 20;
	int window = argc > 4 && !strcmp(argv[4], "window");
	EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major, minor, n;
	if (!eglInitialize(d, &major, &minor)) {
		fprintf(stderr, "eglInitialize: %#x\n", eglGetError());
		return 1;
	}
	const EGLint cattr[] = {EGL_SURFACE_TYPE, window ? EGL_WINDOW_BIT : EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
	                        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
	EGLConfig c;
	if (!eglChooseConfig(d, cattr, &c, 1, &n) || n < 1) {
		fprintf(stderr, "no GLES2 config (%#x)\n", eglGetError());
		return 1;
	}
	const EGLint sattr[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE}, xattr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLNativeWindowType win = window ? sf_window(w, h) : NULL;
	if (window && !win) {
		fprintf(stderr, "no SurfaceFlinger window\n");
		return 1;
	}
	EGLSurface s = window ? eglCreateWindowSurface(d, c, win, NULL) : eglCreatePbufferSurface(d, c, sattr);
	EGLContext x = eglCreateContext(d, c, EGL_NO_CONTEXT, xattr);
	if (s == EGL_NO_SURFACE || x == EGL_NO_CONTEXT || !eglMakeCurrent(d, s, s, x)) {
		fprintf(stderr, "surface/context: %#x\n", eglGetError());
		return 1;
	}
	printf("EGL %d.%d %s | %s | %s | GLSL %s\n", major, minor, eglQueryString(d, EGL_VENDOR), glGetString(GL_RENDERER),
	       glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));

	GLuint p = glCreateProgram();
	glAttachShader(p, shader(GL_VERTEX_SHADER, "attribute vec2 pos; varying vec2 uv;\n"
	                                           "void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }"));
	glAttachShader(p, shader(GL_FRAGMENT_SHADER, "precision mediump float; varying vec2 uv; uniform float t;\n"
	                                             "void main() { gl_FragColor = vec4(uv, 0.5 + 0.5 * sin(t), 1.0); }"));
	glBindAttribLocation(p, 0, "pos");
	glLinkProgram(p);
	glUseProgram(p);
	GLint tloc = glGetUniformLocation(p, "t");
	const GLfloat tri[] = {-1, -1, 3, -1, -1, 3};   // one triangle covering the viewport
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
	glEnableVertexAttribArray(0);
	glViewport(0, 0, w, h);

	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glUniform1f(tloc, 0);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	unsigned char px[4];
	glReadPixels(w * 3 / 4, h / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	printf("pixel (%d,%d) = %u %u %u %u (expect ~191 63 127 255), glGetError %#x\n", w * 3 / 4, h / 4, px[0], px[1], px[2],
	       px[3], glGetError());

	double t0 = now();
	for (int i = 0; i < frames; i++) {
		glUniform1f(tloc, i * 0.1f);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		if (window)
			eglSwapBuffers(d, s);
		else
			glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);   // wait for the frame
	}
	double dt = now() - t0;
	printf("%d frames %dx%d in %.2f s: %.1f fps\n", frames, w, h, dt, frames / dt);
	if (window) {
		fflush(stdout);
		sleep(15);   // on screen for a screendump
	}
	return 0;
}
