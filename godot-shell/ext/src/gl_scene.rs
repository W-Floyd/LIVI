//! A window's picture drawn on the GPU in Godot's own GL context, into a texture of ours that
//! Godot then samples like any other: dmabuf layers (RGB, or planar YUV converted to RGB) over
//! the shm canvas. Godot's canvas shaders cannot sample the external-only YUV images, and doing
//! it here keeps one texture per window for everything downstream.
//!
//! Godot's renderer caches GL state and skips binds it believes are redundant, so every pass
//! saves what it touches and puts it back.

use std::ffi::{CString, c_char, c_void};

use crate::gl_import::GlImporter;

const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_TEXTURE0: u32 = 0x84C0;
const GL_TEXTURE_BINDING_2D: u32 = 0x8069;
const GL_SAMPLER_BINDING: u32 = 0x8919;
const GL_ACTIVE_TEXTURE: u32 = 0x84E0;
const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_READ_FRAMEBUFFER: u32 = 0x8CA8;
const GL_DRAW_FRAMEBUFFER: u32 = 0x8CA9;
const GL_READ_FRAMEBUFFER_BINDING: u32 = 0x8CAA;
const GL_DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const GL_CURRENT_PROGRAM: u32 = 0x8B8D;
const GL_VERTEX_ARRAY_BINDING: u32 = 0x85B5;
const GL_VIEWPORT: u32 = 0x0BA2;
const GL_COLOR_WRITEMASK: u32 = 0x0C23;
const GL_COLOR_CLEAR_VALUE: u32 = 0x0C22;
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_UNPACK_ROW_LENGTH: u32 = 0x0CF2;
const GL_UNPACK_ALIGNMENT: u32 = 0x0CF5;
const GL_PIXEL_UNPACK_BUFFER: u32 = 0x88EF;
const GL_PIXEL_UNPACK_BUFFER_BINDING: u32 = 0x88EF;
const GL_RGBA: u32 = 0x1908;
const GL_RGBA8: i32 = 0x8058;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
const GL_TRIANGLES: u32 = 0x0004;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_TEXTURE_WRAP_S: u32 = 0x2802;
const GL_TEXTURE_WRAP_T: u32 = 0x2803;
const GL_LINEAR: i32 = 0x2601;
const GL_CLAMP_TO_EDGE: i32 = 0x812F;
const GL_VERTEX_SHADER: u32 = 0x8B31;
const GL_FRAGMENT_SHADER: u32 = 0x8B30;
const GL_COMPILE_STATUS: u32 = 0x8B81;
const GL_LINK_STATUS: u32 = 0x8B82;
const GL_VERSION: u32 = 0x1F02;
/// Capabilities the pass switches off, and with them restores: blend, scissor, depth, cull,
/// stencil, dither, alpha-to-coverage, rasterizer discard.
const CAPS: [u32; 8] = [0x0BE2, 0x0C11, 0x0B71, 0x0B44, 0x0B90, 0x0BD0, 0x809E, 0x8C89];
const UNITS: usize = 3;

#[allow(non_snake_case)]
struct Fns {
    glGetString: unsafe extern "C" fn(u32) -> *const u8,
    glGetIntegerv: unsafe extern "C" fn(u32, *mut i32),
    glGetFloatv: unsafe extern "C" fn(u32, *mut f32),
    glGetBooleanv: unsafe extern "C" fn(u32, *mut u8),
    glIsEnabled: unsafe extern "C" fn(u32) -> u8,
    glEnable: unsafe extern "C" fn(u32),
    glDisable: unsafe extern "C" fn(u32),
    glGenTextures: unsafe extern "C" fn(i32, *mut u32),
    glDeleteTextures: unsafe extern "C" fn(i32, *const u32),
    glBindTexture: unsafe extern "C" fn(u32, u32),
    glTexParameteri: unsafe extern "C" fn(u32, u32, i32),
    glTexImage2D: unsafe extern "C" fn(u32, i32, i32, i32, i32, i32, u32, u32, *const c_void),
    glActiveTexture: unsafe extern "C" fn(u32),
    glGenFramebuffers: unsafe extern "C" fn(i32, *mut u32),
    glDeleteFramebuffers: unsafe extern "C" fn(i32, *const u32),
    glBindFramebuffer: unsafe extern "C" fn(u32, u32),
    glFramebufferTexture2D: unsafe extern "C" fn(u32, u32, u32, u32, i32),
    glCheckFramebufferStatus: unsafe extern "C" fn(u32) -> u32,
    glViewport: unsafe extern "C" fn(i32, i32, i32, i32),
    glClearColor: unsafe extern "C" fn(f32, f32, f32, f32),
    glClear: unsafe extern "C" fn(u32),
    glColorMask: unsafe extern "C" fn(u8, u8, u8, u8),
    glCreateShader: unsafe extern "C" fn(u32) -> u32,
    glShaderSource: unsafe extern "C" fn(u32, i32, *const *const c_char, *const i32),
    glCompileShader: unsafe extern "C" fn(u32),
    glGetShaderiv: unsafe extern "C" fn(u32, u32, *mut i32),
    glGetShaderInfoLog: unsafe extern "C" fn(u32, i32, *mut i32, *mut c_char),
    glDeleteShader: unsafe extern "C" fn(u32),
    glCreateProgram: unsafe extern "C" fn() -> u32,
    glAttachShader: unsafe extern "C" fn(u32, u32),
    glLinkProgram: unsafe extern "C" fn(u32),
    glGetProgramiv: unsafe extern "C" fn(u32, u32, *mut i32),
    glGetProgramInfoLog: unsafe extern "C" fn(u32, i32, *mut i32, *mut c_char),
    glUseProgram: unsafe extern "C" fn(u32),
    glGetUniformLocation: unsafe extern "C" fn(u32, *const c_char) -> i32,
    glUniform1i: unsafe extern "C" fn(i32, i32),
    glUniform3f: unsafe extern "C" fn(i32, f32, f32, f32),
    glUniform4f: unsafe extern "C" fn(i32, f32, f32, f32, f32),
    glUniformMatrix3fv: unsafe extern "C" fn(i32, i32, u8, *const f32),
    glGenVertexArrays: unsafe extern "C" fn(i32, *mut u32),
    glBindVertexArray: unsafe extern "C" fn(u32),
    glDrawArrays: unsafe extern "C" fn(u32, i32, i32),
    glGenSamplers: unsafe extern "C" fn(i32, *mut u32),
    glBindSampler: unsafe extern "C" fn(u32, u32),
    glSamplerParameteri: unsafe extern "C" fn(u32, u32, i32),
    glPixelStorei: unsafe extern "C" fn(u32, i32),
    glBindBuffer: unsafe extern "C" fn(u32, u32),
    glFlush: unsafe extern "C" fn(),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    /// One RGB(A) texture.
    Rgb { opaque: bool },
    /// R8 luma, GR88 chroma.
    Nv12,
    /// Three R8 planes.
    I420,
}

/// One layer to draw: a rectangle of the target, the part of the texture to show in it (0..1),
/// and the plane textures.
pub struct Layer {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub src: [f32; 4],
    pub kind: Kind,
    pub tex: [u32; UNITS],
    /// Use BT.709 rather than BT.601.
    pub hd: bool,
}

/// A window's output: the RGBA texture handed to Godot, and the shm canvas under the layers.
pub struct Target {
    pub tex: u32,
    pub w: i32,
    pub h: i32,
    fbo: u32,
    base: u32,
    /// Generation of the canvas in `base`; 0 for none.
    base_gen: u64,
}

pub struct Scene {
    f: Fns,
    prog: u32,
    vao: u32,
    sampler: u32,
    loc: Locs,
}

struct Locs {
    src: i32,
    mode: i32,
    opaque: i32,
    t: [i32; UNITS],
    m: i32,
    off: i32,
}

/// The shaders, `#version` aside: ES 3.0 on the unit, desktop 3.3 where Godot runs on desktop GL.
const VS: &str = "precision highp float;
uniform vec4 src;
out vec2 uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    uv = mix(src.xy, src.zw, p);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}";
const FS: &str = "precision highp float;
uniform sampler2D t0;
uniform sampler2D t1;
uniform sampler2D t2;
uniform int mode;
uniform int opaque;
uniform mat3 m;
uniform vec3 off;
in vec2 uv;
out vec4 o;
void main() {
    if (mode == 0) {
        vec4 c = texture(t0, uv);
        o = vec4(c.rgb, opaque != 0 ? 1.0 : c.a);
        return;
    }
    float y = texture(t0, uv).r;
    vec2 c = mode == 1 ? texture(t1, uv).rg : vec2(texture(t1, uv).r, texture(t2, uv).r);
    o = vec4(clamp(m * (vec3(y, c) - off), 0.0, 1.0), 1.0);
}";

/// What a pass changes, to put back.
struct Saved {
    prog: i32,
    vao: i32,
    draw_fb: i32,
    read_fb: i32,
    viewport: [i32; 4],
    active: i32,
    tex: [i32; UNITS],
    samp: [i32; UNITS],
    caps: [u8; CAPS.len()],
    mask: [u8; 4],
    clear: [f32; 4],
    row_len: i32,
    align: i32,
    pbo: i32,
}

impl Scene {
    /// Compiles the shaders; needs Godot's GL context current.
    pub fn new(gl: &GlImporter) -> Result<Scene, String> {
        macro_rules! load {
            ($($n:ident),* $(,)?) => {
                Fns { $($n: {
                    let p = gl.proc_address(&CString::new(stringify!($n)).unwrap());
                    if p.is_null() { return Err(format!("missing {}", stringify!($n))); }
                    // SAFETY: a GL entry point cast to its own signature.
                    unsafe { std::mem::transmute(p) }
                },)* }
            };
        }
        let f = load!(
            glGetString, glGetIntegerv, glGetFloatv, glGetBooleanv, glIsEnabled, glEnable, glDisable,
            glGenTextures, glDeleteTextures, glBindTexture, glTexParameteri, glTexImage2D, glActiveTexture,
            glGenFramebuffers, glDeleteFramebuffers, glBindFramebuffer, glFramebufferTexture2D,
            glCheckFramebufferStatus, glViewport, glClearColor, glClear, glColorMask, glCreateShader,
            glShaderSource, glCompileShader, glGetShaderiv, glGetShaderInfoLog, glDeleteShader,
            glCreateProgram, glAttachShader, glLinkProgram, glGetProgramiv, glGetProgramInfoLog, glUseProgram,
            glGetUniformLocation, glUniform1i, glUniform3f, glUniform4f, glUniformMatrix3fv,
            glGenVertexArrays, glBindVertexArray, glDrawArrays, glGenSamplers, glBindSampler,
            glSamplerParameteri, glPixelStorei, glBindBuffer, glFlush,
        );
        // SAFETY: GL calls in the current context; the version string is owned by the driver.
        unsafe {
            let ver = (f.glGetString)(GL_VERSION);
            if ver.is_null() {
                return Err("no GL context is current".into());
            }
            let es = std::ffi::CStr::from_ptr(ver as *const c_char).to_string_lossy().starts_with("OpenGL ES");
            let head = if es { "#version 300 es\n" } else { "#version 330 core\n" };
            let saved = Saved::take(&f);
            let result = (|| {
                let vs = compile(&f, GL_VERTEX_SHADER, &format!("{head}{VS}"))?;
                let fs = compile(&f, GL_FRAGMENT_SHADER, &format!("{head}{FS}"))?;
                let prog = (f.glCreateProgram)();
                (f.glAttachShader)(prog, vs);
                (f.glAttachShader)(prog, fs);
                (f.glLinkProgram)(prog);
                (f.glDeleteShader)(vs);
                (f.glDeleteShader)(fs);
                let mut ok = 0;
                (f.glGetProgramiv)(prog, GL_LINK_STATUS, &mut ok);
                if ok == 0 {
                    let mut log = vec![0 as c_char; 1024];
                    (f.glGetProgramInfoLog)(prog, 1024, std::ptr::null_mut(), log.as_mut_ptr());
                    return Err(format!("link: {}", std::ffi::CStr::from_ptr(log.as_ptr()).to_string_lossy()));
                }
                let u = |n: &str| {
                    let n = CString::new(n).unwrap();
                    (f.glGetUniformLocation)(prog, n.as_ptr())
                };
                let loc = Locs {
                    src: u("src"),
                    mode: u("mode"),
                    opaque: u("opaque"),
                    t: [u("t0"), u("t1"), u("t2")],
                    m: u("m"),
                    off: u("off"),
                };
                let mut vao = 0;
                // Core profile has no default VAO to draw with.
                (f.glGenVertexArrays)(1, &mut vao);
                let mut sampler = 0;
                (f.glGenSamplers)(1, &mut sampler);
                for (p, v) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR), (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)] {
                    (f.glSamplerParameteri)(sampler, p, v);
                }
                Ok((prog, vao, sampler, loc))
            })();
            saved.put(&f);
            let (prog, vao, sampler, loc) = result?;
            Ok(Scene { f, prog, vao, sampler, loc })
        }
    }

    /// A `w`x`h` RGBA texture to draw into.
    pub fn new_target(&self, w: i32, h: i32) -> Result<Target, String> {
        let f = &self.f;
        // SAFETY: GL calls in the current context, state restored after.
        unsafe {
            let saved = Saved::take(f);
            let (mut tex, mut fbo, mut base) = (0, 0, 0);
            (f.glActiveTexture)(GL_TEXTURE0);
            (f.glGenTextures)(1, &mut tex);
            (f.glGenTextures)(1, &mut base);
            for t in [tex, base] {
                (f.glBindTexture)(GL_TEXTURE_2D, t);
                for (p, v) in [(GL_TEXTURE_MIN_FILTER, GL_LINEAR), (GL_TEXTURE_MAG_FILTER, GL_LINEAR), (GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE), (GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)] {
                    (f.glTexParameteri)(GL_TEXTURE_2D, p, v);
                }
            }
            (f.glBindBuffer)(GL_PIXEL_UNPACK_BUFFER, 0);
            (f.glBindTexture)(GL_TEXTURE_2D, tex);
            (f.glTexImage2D)(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, std::ptr::null());
            (f.glGenFramebuffers)(1, &mut fbo);
            (f.glBindFramebuffer)(GL_FRAMEBUFFER, fbo);
            (f.glFramebufferTexture2D)(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
            let status = (f.glCheckFramebufferStatus)(GL_FRAMEBUFFER);
            saved.put(f);
            let t = Target { tex, w, h, fbo, base, base_gen: 0 };
            if status != GL_FRAMEBUFFER_COMPLETE {
                self.free_target(t);
                return Err(format!("a {w}x{h} RGBA target is not renderable (status {status:#x})"));
            }
            Ok(t)
        }
    }

    pub fn free_target(&self, t: Target) {
        // SAFETY: objects this scene created.
        unsafe {
            (self.f.glDeleteFramebuffers)(1, &t.fbo);
            (self.f.glDeleteTextures)(1, &t.tex);
            (self.f.glDeleteTextures)(1, &t.base);
        }
    }

    /// Redraws the target: the canvas (RGBA, `w`x`h`, uploaded when `generation` is new), then `layers`
    /// in order, each replacing what is under it.
    pub fn render(&self, t: &mut Target, canvas: Option<(u64, &[u8])>, layers: &[Layer]) {
        let f = &self.f;
        // SAFETY: GL calls in the current context; every texture is ours or an imported plane.
        unsafe {
            let saved = Saved::take(f);
            for c in CAPS {
                (f.glDisable)(c);
            }
            (f.glColorMask)(1, 1, 1, 1);
            (f.glPixelStorei)(GL_UNPACK_ROW_LENGTH, 0);
            (f.glPixelStorei)(GL_UNPACK_ALIGNMENT, 4);
            (f.glBindBuffer)(GL_PIXEL_UNPACK_BUFFER, 0);
            match canvas {
                Some((generation, px)) if generation != t.base_gen && px.len() >= (t.w * t.h * 4) as usize => {
                    (f.glActiveTexture)(GL_TEXTURE0);
                    (f.glBindTexture)(GL_TEXTURE_2D, t.base);
                    (f.glTexImage2D)(GL_TEXTURE_2D, 0, GL_RGBA8, t.w, t.h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px.as_ptr() as *const c_void);
                    t.base_gen = generation;
                }
                None => t.base_gen = 0,
                _ => {}
            }
            (f.glBindFramebuffer)(GL_FRAMEBUFFER, t.fbo);
            (f.glViewport)(0, 0, t.w, t.h);
            (f.glClearColor)(0.0, 0.0, 0.0, 0.0);
            (f.glClear)(GL_COLOR_BUFFER_BIT);
            (f.glUseProgram)(self.prog);
            (f.glBindVertexArray)(self.vao);
            for u in 0..UNITS {
                (f.glActiveTexture)(GL_TEXTURE0 + u as u32);
                (f.glBindSampler)(u as u32, self.sampler);
                (f.glUniform1i)(self.loc.t[u], u as i32);
            }
            let base = (t.base_gen != 0).then_some(Layer {
                x: 0,
                y: 0,
                w: t.w,
                h: t.h,
                src: [0.0, 0.0, 1.0, 1.0],
                kind: Kind::Rgb { opaque: false },
                tex: [t.base, 0, 0],
                hd: false,
            });
            for l in base.iter().chain(layers) {
                let planes = match l.kind {
                    Kind::Rgb { .. } => 1,
                    Kind::Nv12 => 2,
                    Kind::I420 => 3,
                };
                for u in 0..planes {
                    (f.glActiveTexture)(GL_TEXTURE0 + u as u32);
                    (f.glBindTexture)(GL_TEXTURE_2D, l.tex[u]);
                }
                let (mode, opaque) = match l.kind {
                    Kind::Rgb { opaque } => (0, opaque),
                    Kind::Nv12 => (1, true),
                    Kind::I420 => (2, true),
                };
                (f.glUniform1i)(self.loc.mode, mode);
                (f.glUniform1i)(self.loc.opaque, opaque as i32);
                (f.glUniform4f)(self.loc.src, l.src[0], l.src[1], l.src[2], l.src[3]);
                let (m, off) = crate::yuv::coeffs(l.hd);
                (f.glUniformMatrix3fv)(self.loc.m, 1, 0, m.as_ptr());
                (f.glUniform3f)(self.loc.off, off[0], off[1], off[2]);
                (f.glViewport)(l.x, l.y, l.w, l.h);
                (f.glDrawArrays)(GL_TRIANGLES, 0, 3);
            }
            (f.glFlush)();
            saved.put(f);
        }
    }
}

unsafe fn compile(f: &Fns, kind: u32, src: &str) -> Result<u32, String> {
    // SAFETY: the caller has a current GL context.
    unsafe {
        let s = (f.glCreateShader)(kind);
        let c = CString::new(src).unwrap();
        (f.glShaderSource)(s, 1, &c.as_ptr(), std::ptr::null());
        (f.glCompileShader)(s);
        let mut ok = 0;
        (f.glGetShaderiv)(s, GL_COMPILE_STATUS, &mut ok);
        if ok == 0 {
            let mut log = vec![0 as c_char; 1024];
            (f.glGetShaderInfoLog)(s, 1024, std::ptr::null_mut(), log.as_mut_ptr());
            let msg = std::ffi::CStr::from_ptr(log.as_ptr()).to_string_lossy().into_owned();
            (f.glDeleteShader)(s);
            return Err(format!("shader: {msg}"));
        }
        Ok(s)
    }
}

impl Saved {
    unsafe fn take(f: &Fns) -> Saved {
        // SAFETY: plain state queries in the current context.
        unsafe {
            let geti = |p: u32| {
                let mut v = 0;
                (f.glGetIntegerv)(p, &mut v);
                v
            };
            let mut s = Saved {
                prog: geti(GL_CURRENT_PROGRAM),
                vao: geti(GL_VERTEX_ARRAY_BINDING),
                draw_fb: geti(GL_DRAW_FRAMEBUFFER_BINDING),
                read_fb: geti(GL_READ_FRAMEBUFFER_BINDING),
                viewport: [0; 4],
                active: geti(GL_ACTIVE_TEXTURE),
                tex: [0; UNITS],
                samp: [0; UNITS],
                caps: [0; CAPS.len()],
                mask: [0; 4],
                clear: [0.0; 4],
                row_len: geti(GL_UNPACK_ROW_LENGTH),
                align: geti(GL_UNPACK_ALIGNMENT),
                pbo: geti(GL_PIXEL_UNPACK_BUFFER_BINDING),
            };
            (f.glGetIntegerv)(GL_VIEWPORT, s.viewport.as_mut_ptr());
            (f.glGetBooleanv)(GL_COLOR_WRITEMASK, s.mask.as_mut_ptr());
            (f.glGetFloatv)(GL_COLOR_CLEAR_VALUE, s.clear.as_mut_ptr());
            for (i, c) in CAPS.iter().enumerate() {
                s.caps[i] = (f.glIsEnabled)(*c);
            }
            for u in 0..UNITS {
                (f.glActiveTexture)(GL_TEXTURE0 + u as u32);
                s.tex[u] = geti(GL_TEXTURE_BINDING_2D);
                s.samp[u] = geti(GL_SAMPLER_BINDING);
            }
            (f.glActiveTexture)(s.active as u32);
            s
        }
    }

    unsafe fn put(&self, f: &Fns) {
        // SAFETY: restores state `take` read.
        unsafe {
            for u in 0..UNITS {
                (f.glActiveTexture)(GL_TEXTURE0 + u as u32);
                (f.glBindTexture)(GL_TEXTURE_2D, self.tex[u] as u32);
                (f.glBindSampler)(u as u32, self.samp[u] as u32);
            }
            (f.glActiveTexture)(self.active as u32);
            (f.glBindFramebuffer)(GL_DRAW_FRAMEBUFFER, self.draw_fb as u32);
            (f.glBindFramebuffer)(GL_READ_FRAMEBUFFER, self.read_fb as u32);
            (f.glBindVertexArray)(self.vao as u32);
            (f.glUseProgram)(self.prog as u32);
            (f.glViewport)(self.viewport[0], self.viewport[1], self.viewport[2], self.viewport[3]);
            (f.glColorMask)(self.mask[0], self.mask[1], self.mask[2], self.mask[3]);
            (f.glClearColor)(self.clear[0], self.clear[1], self.clear[2], self.clear[3]);
            for (c, on) in CAPS.iter().zip(self.caps) {
                if on != 0 {
                    (f.glEnable)(*c);
                } else {
                    (f.glDisable)(*c);
                }
            }
            (f.glPixelStorei)(GL_UNPACK_ROW_LENGTH, self.row_len);
            (f.glPixelStorei)(GL_UNPACK_ALIGNMENT, self.align);
            (f.glBindBuffer)(GL_PIXEL_UNPACK_BUFFER, self.pbo as u32);
        }
    }
}
