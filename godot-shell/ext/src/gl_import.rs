//! dmabuf → EGLImage → GL texture, in Godot's own GL context. An EGLImage belongs to the
//! display it was made on, so this runs where Godot renders (the main thread, in Godot's
//! default render-thread mode). EGL is loaded at run time: nothing is linked.

use std::ffi::{CStr, c_char, c_void};
use std::os::fd::AsRawFd;

use smithay::backend::allocator::Buffer;
use smithay::backend::allocator::dmabuf::Dmabuf;

type Display = *mut c_void;
type Image = *mut c_void;

const EGL_NONE: i32 = 0x3038;
const EGL_WIDTH: i32 = 0x3057;
const EGL_HEIGHT: i32 = 0x3056;
const EGL_LINUX_DMA_BUF_EXT: u32 = 0x3270;
const EGL_LINUX_DRM_FOURCC_EXT: i32 = 0x3271;
const EGL_DEVICE_EXT: i32 = 0x322C;
const EGL_DRM_RENDER_NODE_FILE_EXT: i32 = 0x3377;
/// Per plane: fd, offset, pitch, modifier low, modifier high.
const PLANE_ATTRS: [[i32; 5]; 4] = [
    [0x3272, 0x3273, 0x3274, 0x3443, 0x3444],
    [0x3275, 0x3276, 0x3277, 0x3445, 0x3446],
    [0x3278, 0x3279, 0x327A, 0x3447, 0x3448],
    [0x3440, 0x3441, 0x3442, 0x3449, 0x344A],
];
const DRM_FORMAT_MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;

const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_TEXTURE_BINDING_2D: u32 = 0x8069;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_TEXTURE_WRAP_S: u32 = 0x2802;
const GL_TEXTURE_WRAP_T: u32 = 0x2803;
const GL_LINEAR: i32 = 0x2601;
const GL_CLAMP_TO_EDGE: i32 = 0x812F;

#[allow(non_snake_case)]
struct Fns {
    eglGetCurrentDisplay: unsafe extern "C" fn() -> Display,
    eglCreateImageKHR: unsafe extern "C" fn(Display, *mut c_void, u32, *mut c_void, *const i32) -> Image,
    eglDestroyImageKHR: unsafe extern "C" fn(Display, Image) -> u32,
    eglQueryDmaBufFormatsEXT: Option<unsafe extern "C" fn(Display, i32, *mut i32, *mut i32) -> u32>,
    eglQueryDmaBufModifiersEXT:
        Option<unsafe extern "C" fn(Display, i32, i32, *mut u64, *mut u32, *mut i32) -> u32>,
    eglQueryDisplayAttribEXT: Option<unsafe extern "C" fn(Display, i32, *mut isize) -> u32>,
    eglQueryDeviceStringEXT: Option<unsafe extern "C" fn(*mut c_void, i32) -> *const c_char>,
    glEGLImageTargetTexture2DOES: unsafe extern "C" fn(u32, Image),
    glGenTextures: unsafe extern "C" fn(i32, *mut u32),
    glDeleteTextures: unsafe extern "C" fn(i32, *const u32),
    glBindTexture: unsafe extern "C" fn(u32, u32),
    glTexParameteri: unsafe extern "C" fn(u32, u32, i32),
    glGetIntegerv: unsafe extern "C" fn(u32, *mut i32),
}

pub struct GlImporter {
    f: Fns,
    display: Display,
}

/// A dmabuf format the importer can sample as an ordinary 2D texture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Format {
    pub fourcc: u32,
    pub modifier: u64,
}

impl GlImporter {
    /// Fails when EGL isn't there, no context is current on this thread, or dmabuf import
    /// isn't supported.
    pub fn new() -> Result<GlImporter, String> {
        // SAFETY: dlopen/dlsym with static names; symbols are cast to their EGL/GL types.
        unsafe {
            let lib = libc::dlopen(c"libEGL.so.1".as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL);
            if lib.is_null() {
                return Err("libEGL.so.1 not found".into());
            }
            let sym = |n: &CStr| libc::dlsym(lib, n.as_ptr());
            let gpa = sym(c"eglGetProcAddress");
            let cur_ctx = sym(c"eglGetCurrentContext");
            let cur_dpy = sym(c"eglGetCurrentDisplay");
            if gpa.is_null() || cur_ctx.is_null() || cur_dpy.is_null() {
                return Err("libEGL lacks eglGetProcAddress".into());
            }
            let gpa: unsafe extern "C" fn(*const c_char) -> *mut c_void = std::mem::transmute(gpa);
            let cur_ctx: unsafe extern "C" fn() -> *mut c_void = std::mem::transmute(cur_ctx);
            if cur_ctx().is_null() {
                return Err("no EGL context is current here; Godot renders on another thread".into());
            }
            let p = |n: &CStr| gpa(n.as_ptr());
            macro_rules! req {
                ($n:literal) => {{
                    let f = p($n);
                    if f.is_null() {
                        return Err(format!("missing {}", $n.to_string_lossy()));
                    }
                    std::mem::transmute(f)
                }};
            }
            macro_rules! opt {
                ($n:literal) => {{
                    let f = p($n);
                    (!f.is_null()).then(|| std::mem::transmute(f))
                }};
            }
            let f = Fns {
                eglGetCurrentDisplay: std::mem::transmute(cur_dpy),
                eglCreateImageKHR: req!(c"eglCreateImageKHR"),
                eglDestroyImageKHR: req!(c"eglDestroyImageKHR"),
                eglQueryDmaBufFormatsEXT: opt!(c"eglQueryDmaBufFormatsEXT"),
                eglQueryDmaBufModifiersEXT: opt!(c"eglQueryDmaBufModifiersEXT"),
                eglQueryDisplayAttribEXT: opt!(c"eglQueryDisplayAttribEXT"),
                eglQueryDeviceStringEXT: opt!(c"eglQueryDeviceStringEXT"),
                glEGLImageTargetTexture2DOES: req!(c"glEGLImageTargetTexture2DOES"),
                glGenTextures: req!(c"glGenTextures"),
                glDeleteTextures: req!(c"glDeleteTextures"),
                glBindTexture: req!(c"glBindTexture"),
                glTexParameteri: req!(c"glTexParameteri"),
                glGetIntegerv: req!(c"glGetIntegerv"),
            };
            let display = (f.eglGetCurrentDisplay)();
            Ok(GlImporter { f, display })
        }
    }

    /// Formats and modifiers EGL imports that a `sampler2D` can read; external-only ones are
    /// left out, as Godot's canvas shaders cannot sample them.
    pub fn formats(&self) -> Vec<Format> {
        let (Some(qf), Some(qm)) = (self.f.eglQueryDmaBufFormatsEXT, self.f.eglQueryDmaBufModifiersEXT)
        else {
            return Vec::new();
        };
        let mut out = Vec::new();
        // SAFETY: two-call queries into buffers of the reported size.
        unsafe {
            let mut n = 0;
            if qf(self.display, 0, std::ptr::null_mut(), &mut n) == 0 || n <= 0 {
                return out;
            }
            let mut fourccs = vec![0i32; n as usize];
            qf(self.display, n, fourccs.as_mut_ptr(), &mut n);
            for &fourcc in &fourccs[..n as usize] {
                let mut m = 0;
                qm(self.display, fourcc, 0, std::ptr::null_mut(), std::ptr::null_mut(), &mut m);
                if m <= 0 {
                    // Only implicit modifiers.
                    out.push(Format { fourcc: fourcc as u32, modifier: DRM_FORMAT_MOD_INVALID });
                    continue;
                }
                let mut mods = vec![0u64; m as usize];
                let mut ext = vec![0u32; m as usize];
                qm(self.display, fourcc, m, mods.as_mut_ptr(), ext.as_mut_ptr(), &mut m);
                for i in 0..m as usize {
                    if ext[i] == 0 {
                        out.push(Format { fourcc: fourcc as u32, modifier: mods[i] });
                    }
                }
            }
        }
        out
    }

    /// The render node behind Godot's display, for dmabuf feedback; none for a software device.
    pub fn render_node(&self) -> Option<libc::dev_t> {
        let (qa, qs) = (self.f.eglQueryDisplayAttribEXT?, self.f.eglQueryDeviceStringEXT?);
        // SAFETY: EGL_EXT_device_query; the string is owned by EGL.
        unsafe {
            let mut dev: isize = 0;
            if qa(self.display, EGL_DEVICE_EXT, &mut dev) == 0 || dev == 0 {
                return None;
            }
            let s = qs(dev as *mut c_void, EGL_DRM_RENDER_NODE_FILE_EXT);
            if s.is_null() {
                return None;
            }
            let mut st: libc::stat = std::mem::zeroed();
            (libc::stat(s, &mut st) == 0).then_some(st.st_rdev)
        }
    }

    pub fn import(&self, dmabuf: &Dmabuf) -> Result<Image, String> {
        let size = dmabuf.size();
        let format = dmabuf.format();
        let modifier: u64 = format.modifier.into();
        let mut attrs = vec![EGL_WIDTH, size.w, EGL_HEIGHT, size.h, EGL_LINUX_DRM_FOURCC_EXT, format.code as i32];
        let planes = dmabuf.handles().zip(dmabuf.offsets()).zip(dmabuf.strides());
        for (i, ((fd, offset), stride)) in planes.enumerate().take(4) {
            let a = PLANE_ATTRS[i];
            attrs.extend([a[0], fd.as_raw_fd(), a[1], offset as i32, a[2], stride as i32]);
            if dmabuf.has_modifier() {
                attrs.extend([a[3], (modifier & 0xffff_ffff) as i32, a[4], (modifier >> 32) as i32]);
            }
        }
        attrs.push(EGL_NONE);
        // SAFETY: attribute list is EGL_NONE-terminated; the fds stay open for the call.
        let image = unsafe {
            (self.f.eglCreateImageKHR)(self.display, std::ptr::null_mut(), EGL_LINUX_DMA_BUF_EXT, std::ptr::null_mut(), attrs.as_ptr())
        };
        if image.is_null() {
            return Err(format!("EGL refused a {}x{} dmabuf, format {:?}", size.w, size.h, format));
        }
        Ok(image)
    }

    pub fn destroy_image(&self, image: Image) {
        // SAFETY: an image this importer created.
        unsafe { (self.f.eglDestroyImageKHR)(self.display, image) };
    }

    pub fn new_texture(&self) -> u32 {
        let mut tex = 0;
        self.with_bound(|f| unsafe {
            (f.glGenTextures)(1, &mut tex);
            (f.glBindTexture)(GL_TEXTURE_2D, tex);
            (f.glTexParameteri)(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            (f.glTexParameteri)(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            (f.glTexParameteri)(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            (f.glTexParameteri)(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        });
        tex
    }

    /// Points `tex` at `image`'s pixels: no copy.
    pub fn attach(&self, tex: u32, image: Image) {
        self.with_bound(|f| unsafe {
            (f.glBindTexture)(GL_TEXTURE_2D, tex);
            (f.glEGLImageTargetTexture2DOES)(GL_TEXTURE_2D, image);
        });
    }

    pub fn delete_texture(&self, tex: u32) {
        // SAFETY: a texture this importer created.
        unsafe { (self.f.glDeleteTextures)(1, &tex) };
    }

    /// Runs `f` and puts back the texture Godot had bound, so its renderer's state holds.
    fn with_bound(&self, f: impl FnOnce(&Fns)) {
        let mut was = 0;
        // SAFETY: plain GL state calls in the current context.
        unsafe { (self.f.glGetIntegerv)(GL_TEXTURE_BINDING_2D, &mut was) };
        f(&self.f);
        unsafe { (self.f.glBindTexture)(GL_TEXTURE_2D, was as u32) };
    }
}
