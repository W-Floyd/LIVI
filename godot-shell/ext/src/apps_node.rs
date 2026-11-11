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
    base: Base<RefCounted>,
}

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok()
}

#[godot_api]
impl AppCatalog {
    /// The apps in `dirs` (data dirs in precedence order; empty for the XDG ones) with the config
    /// at `config_path` applied, as `{id, name, icon, argv, cwd, app_ids, source, timeout_s,
    /// scale}` (`scale` a percentage, 0 for none). Also starts listing Waydroid's apps, when the
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
    fn merged(&self) -> VarArray {
        let empty = Config::default();
        let cfg = self.config.as_ref().unwrap_or(&empty);
        let all: Vec<App> = self.found.iter().chain(&self.waydroid).cloned().collect();
        apps::merge(all, cfg, &self.dirs).iter().map(|a| to_dict(a).to_variant()).collect()
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
