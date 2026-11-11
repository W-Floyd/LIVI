//! `AppCatalog`: the launcher's catalog (`apps`) and the processes it starts. In Rust rather
//! than `OS.create_process` so the shell owns each child: its own process group (to match
//! windows by PID and to signal everything it forked), its exit status, and its log.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use godot::prelude::*;

use crate::apps::{self, App, Config};
use crate::gs;

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct AppCatalog {
    found: Vec<App>,
    waydroid: Vec<App>,
    dirs: Vec<PathBuf>,
    config: Option<Config>,
    config_error: String,
    /// Set by the Waydroid thread; taken by `poll_scan`.
    waydroid_scan: Option<Arc<Mutex<Option<Vec<App>>>>>,
    children: HashMap<i32, Child>,
    /// The last list `scan` or `poll_scan` gave.
    listed: Vec<App>,
    base: Base<RefCounted>,
}

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok()
}

#[godot_api]
impl AppCatalog {
    /// The apps in `dirs` (data dirs in precedence order; empty for the XDG ones) with the config
    /// at `config_path` applied, as `{id, name, icon, argv, cwd, app_ids, source, timeout_s,
    /// scale, drive_safe}` (`scale` a percentage, 0 for none). Also starts listing Waydroid's apps, when the
    /// config allows and `waydroid` is installed: those arrive through `poll_scan`.
    #[func]
    fn scan(&mut self, dirs: PackedStringArray, config_path: GString) -> VarArray {
        self.dirs = if dirs.is_empty() { apps::xdg_data_dirs(env) } else { dirs.as_slice().iter().map(|d| PathBuf::from(d.to_string())).collect() };
        let text = std::fs::read_to_string(config_path.to_string()).unwrap_or_default();
        self.config_error.clear();
        let cfg = apps::parse_config(&text).unwrap_or_else(|e| {
            self.config_error = format!("{config_path}: {e}");
            godot_error!("apps: {}", self.config_error);
            apps::parse_config("").unwrap_or_default()
        });
        let langs: Vec<String> = ["LC_ALL", "LC_MESSAGES", "LANG"].iter().filter_map(|k| env(k).filter(|v| !v.is_empty())).collect();
        let path = env("PATH").unwrap_or_default();
        self.found = apps::desktop_apps(&self.dirs, &langs, &path);
        if !cfg.waydroid {
            self.waydroid.clear();
        } else if apps::on_path("waydroid", &path) && self.waydroid_scan.is_none() {
            let slot = Arc::new(Mutex::new(None));
            let icons = env("HOME").map(|h| Path::new(&h).join(".local/share/waydroid/data/icons")).unwrap_or_default();
            let out = slot.clone();
            std::thread::spawn(move || {
                let list = waydroid_list().map(|l| apps::waydroid_apps(&l, &icons)).unwrap_or_default();
                *out.lock().unwrap_or_else(|e| e.into_inner()) = Some(list);
            });
            self.waydroid_scan = Some(slot);
        }
        self.config = Some(cfg);
        self.merged()
    }

    /// The whole list again once Waydroid's has arrived since the last call; else null.
    #[func]
    fn poll_scan(&mut self) -> Variant {
        let Some(slot) = &self.waydroid_scan else { return Variant::nil() };
        let Some(list) = slot.lock().unwrap_or_else(|e| e.into_inner()).take() else { return Variant::nil() };
        self.waydroid_scan = None;
        if list == self.waydroid {
            return Variant::nil();
        }
        self.waydroid = list;
        self.merged().to_variant()
    }

    /// The config's parse error from the last scan, or empty.
    #[func]
    fn config_error(&self) -> GString {
        gs(&self.config_error)
    }

    /// Starts `argv` detached in its own process group, with `env` set over the shell's own
    /// (a null value unsets) and output appended to `log` (empty: discarded). The PID, or -1 with
    /// the reason pushed as an error.
    #[func]
    fn launch(&mut self, argv: PackedStringArray, cwd: GString, env: VarDictionary, log: GString) -> i64 {
        let argv: Vec<String> = argv.as_slice().iter().map(|a| a.to_string()).collect();
        let Some((prog, args)) = argv.split_first() else { return -1 };
        let mut cmd = Command::new(prog);
        cmd.args(args).stdin(Stdio::null());
        if !cwd.is_empty() {
            cmd.current_dir(cwd.to_string());
        }
        for (k, v) in env.iter_shared() {
            if v.is_nil() {
                cmd.env_remove(k.to_string());
            } else {
                cmd.env(k.to_string(), v.to_string());
            }
        }
        let log = log.to_string();
        let out = if log.is_empty() {
            None
        } else {
            if let Some(d) = Path::new(&log).parent() {
                let _ = std::fs::create_dir_all(d);
            }
            std::fs::OpenOptions::new().create(true).append(true).open(&log).ok()
        };
        match out.as_ref().map(|f| (f.try_clone(), f.try_clone())) {
            Some((Ok(a), Ok(b))) => cmd.stdout(a).stderr(b),
            _ => cmd.stdout(Stdio::null()).stderr(Stdio::null()),
        };
        #[cfg(unix)]
        std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
        match cmd.spawn() {
            Ok(child) => {
                let pid = child.id() as i32;
                self.children.insert(pid, child);
                pid as i64
            }
            Err(e) => {
                godot_error!("apps: {prog}: {e}");
                -1
            }
        }
    }

    /// -1 while the child runs; its exit status once it has gone (128 + signal when killed); -2
    /// for a PID this catalog did not start, or already reported.
    #[func]
    fn poll(&mut self, pid: i64) -> i64 {
        let Some(c) = self.children.get_mut(&(pid as i32)) else { return -2 };
        match c.try_wait() {
            Ok(None) => -1,
            Ok(Some(st)) => {
                self.children.remove(&(pid as i32));
                #[cfg(unix)]
                if let Some(sig) = std::os::unix::process::ExitStatusExt::signal(&st) {
                    return 128 + sig as i64;
                }
                st.code().unwrap_or(1) as i64
            }
            Err(_) => {
                self.children.remove(&(pid as i32));
                1
            }
        }
    }

    /// A launch with no window yet, `elapsed_ms` in: `{state: "starting" | "slow" | "failed",
    /// reason}`. `exit` is its status once it has gone (`poll`), else -1.
    #[func]
    fn launch_state(elapsed_ms: i64, timeout_s: i64, exit: i64) -> VarDictionary {
        let st = apps::launch_state(elapsed_ms.max(0) as u64, timeout_s.max(0) as u32, (exit >= 0).then_some(exit as i32));
        let (state, reason) = match st {
            apps::Launch::Starting => ("starting", String::new()),
            apps::Launch::Slow => ("slow", String::new()),
            apps::Launch::Failed(r) => ("failed", r),
        };
        let mut d = VarDictionary::new();
        d.set("state", &gs(state));
        d.set("reason", &gs(reason));
        d
    }

    /// The listed app a window is, or "" (`apps::window_owner`): `group` is its client's process
    /// group (-1 unknown), `launching` the apps waiting for a window, `pids` app id -> PID started.
    #[func]
    fn window_owner(&self, app_id: GString, group: i64, launching: PackedStringArray, pids: VarDictionary, fresh: bool) -> GString {
        let launching: Vec<String> = launching.as_slice().iter().map(|s| s.to_string()).collect();
        let launching: Vec<&str> = launching.iter().map(String::as_str).collect();
        let pids: Vec<(String, i32)> = pids.iter_shared().map(|(k, v)| (k.to_string(), v.try_to::<i64>().unwrap_or(-1) as i32)).collect();
        let pids: Vec<(&str, i32)> = pids.iter().map(|(k, v)| (k.as_str(), *v)).collect();
        let group = (group > 0).then_some(group as i32);
        gs(apps::window_owner(&app_id.to_string(), group, &launching, &pids, &self.listed, fresh).unwrap_or_default())
    }

    /// SIGTERM, or SIGKILL with `kill`, to the child's whole process group.
    #[func]
    fn stop(&mut self, pid: i64, kill: bool) {
        #[cfg(target_os = "linux")]
        unsafe {
            libc::kill(-(pid as i32), if kill { libc::SIGKILL } else { libc::SIGTERM });
        }
        #[cfg(not(target_os = "linux"))]
        if let Some(c) = self.children.get_mut(&(pid as i32)) {
            let _ = kill;
            let _ = c.kill();
        }
    }

    /// The process group of `pid`, or -1: a window's client is ours when it is in a group this
    /// catalog started, so apps that fork (launchers, wrapper scripts) still match.
    #[func]
    fn group_of(&self, pid: i64) -> i64 {
        #[cfg(target_os = "linux")]
        {
            let g = unsafe { libc::getpgid(pid as i32) };
            if g > 0 {
                return g as i64;
            }
        }
        let _ = pid;
        -1
    }
}

impl AppCatalog {
    fn merged(&mut self) -> VarArray {
        let empty = Config::default();
        let cfg = self.config.as_ref().unwrap_or(&empty);
        let all: Vec<App> = self.found.iter().chain(&self.waydroid).cloned().collect();
        self.listed = apps::merge(all, cfg, &self.dirs);
        self.listed.iter().map(|a| to_dict(a).to_variant()).collect()
    }
}

fn to_dict(a: &App) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("id", &gs(&a.id));
    d.set("name", &gs(&a.name));
    d.set("icon", &gs(a.icon.as_ref().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()));
    d.set("argv", &a.argv.iter().map(gs).collect::<PackedStringArray>());
    d.set("cwd", &gs(a.cwd.clone().unwrap_or_default()));
    d.set("app_ids", &a.app_ids.iter().map(gs).collect::<PackedStringArray>());
    d.set("source", &gs(a.source));
    d.set("timeout_s", a.timeout_s as i64);
    d.set("scale", a.scale.unwrap_or(0) as i64);
    d.set("drive_safe", a.drive_safe);
    d.set("terminal", a.terminal);
    d
}

/// `waydroid app list` while the session runs; None when it doesn't (the list would be stale, or
/// the call would hang waiting for the container).
fn waydroid_list() -> Option<String> {
    let run = |args: &[&str]| {
        Command::new("waydroid").args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).to_string())
    };
    let status = run(&["status"])?;
    if !status.lines().any(|l| l.starts_with("Session:") && l.contains("RUNNING")) {
        return None;
    }
    run(&["app", "list"])
}

/// The settings portal launched apps read the shell's look from (`portal`): one per process.
#[derive(GodotClass)]
#[class(base = Object, init)]
pub struct AppearancePortal {
    base: Base<Object>,
}

#[godot_api]
impl AppearancePortal {
    /// Keeps the portal served on the session bus from now on (`portal::start`), with this look.
    #[func]
    fn start(dark: bool, accent: Color, reduced_motion: bool) {
        #[cfg(target_os = "linux")]
        crate::portal::start(look(dark, accent, reduced_motion));
        #[cfg(not(target_os = "linux"))]
        let _ = (dark, accent, reduced_motion);
    }

    /// The new look, announced to apps setting by setting.
    #[func]
    fn set_look(dark: bool, accent: Color, reduced_motion: bool) {
        #[cfg(target_os = "linux")]
        crate::portal::set_look(look(dark, accent, reduced_motion));
        #[cfg(not(target_os = "linux"))]
        let _ = (dark, accent, reduced_motion);
    }

    #[func]
    fn serving() -> bool {
        #[cfg(target_os = "linux")]
        return crate::portal::status().0;
        #[cfg(not(target_os = "linux"))]
        false
    }

    /// What the portal's keeper last found: whom it is served as, or why it is not.
    #[func]
    fn status() -> GString {
        #[cfg(target_os = "linux")]
        return gs(crate::portal::status().1);
        #[cfg(not(target_os = "linux"))]
        gs("no portal off Linux")
    }
}

#[cfg(target_os = "linux")]
fn look(dark: bool, accent: Color, reduced_motion: bool) -> crate::portal::Look {
    crate::portal::Look { dark, accent: [accent.r as f64, accent.g as f64, accent.b as f64], reduced_motion }
}
