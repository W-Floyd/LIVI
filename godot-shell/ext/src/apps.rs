//! The launcher's catalog: freedesktop desktop entries, Waydroid's apps and the shell's own
//! apps.yaml, merged into one list (PLAN.md, "App launcher"). Pure, so it is tested here; the
//! Godot side is `apps_node`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

/// The desktop name the shell claims for `OnlyShowIn` and `NotShowIn`.
pub const DESKTOP: &str = "LIVI";
/// Seconds a launch may take to show a window. Waydroid's first frame takes most of a minute
/// under QEMU.
pub const TIMEOUT_S: u32 = 20;
pub const WAYDROID_TIMEOUT_S: u32 = 90;

#[derive(Debug, Clone, PartialEq)]
pub struct App {
    /// The desktop file ID without `.desktop`, `waydroid.<package>`, or the apps.yaml key.
    pub id: String,
    pub name: String,
    pub icon: Option<PathBuf>,
    pub argv: Vec<String>,
    pub cwd: Option<String>,
    /// Window app_ids that are this app: the ID, `StartupWMClass`, apps.yaml's `app_id`.
    pub app_ids: Vec<String>,
    pub source: &'static str,
    pub timeout_s: u32,
}

/// The `[Desktop Entry]` group's keys, values unescaped at the string level.
pub fn parse_entry(text: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut in_group = false;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            in_group = line == "[Desktop Entry]";
            continue;
        }
        if !in_group {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            out.entry(k.trim().to_string()).or_insert_with(|| unescape(v.trim()));
        }
    }
    out
}

/// The spec's string escapes; `\;` stays for `list` to split on.
fn unescape(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    let mut it = v.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(o) => {
                out.push('\\');
                out.push(o);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// A `;`-separated list value.
pub fn list(v: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut it = v.chars();
    while let Some(c) = it.next() {
        match c {
            '\\' => match it.next() {
                Some(';') => cur.push(';'),
                Some(o) => {
                    cur.push('\\');
                    cur.push(o);
                }
                None => {}
            },
            ';' => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn is_true(e: &HashMap<String, String>, k: &str) -> bool {
    e.get(k).is_some_and(|v| v == "true")
}

/// `Name[ll_CC]`, then `Name[ll]`, then `Name`, for each of `langs` in order.
pub fn localized<'a>(e: &'a HashMap<String, String>, key: &str, langs: &[String]) -> Option<&'a String> {
    for l in langs {
        let base = l.split(['.', '@']).next().unwrap_or("");
        for want in [base, base.split('_').next().unwrap_or("")] {
            if !want.is_empty()
                && let Some(v) = e.get(&format!("{key}[{want}]"))
            {
                return Some(v);
            }
        }
    }
    e.get(key)
}

/// `Exec` to argv: the spec's quoting, then field codes. No files are passed, so `%f %F %u %U`
/// go; `%i` is `--icon <Icon>`, `%c` the name, `%k` the file. An unknown code is an error.
pub fn exec_argv(exec: &str, name: &str, icon: Option<&str>, file: &str) -> Result<Vec<String>, String> {
    let mut words: Vec<(String, bool)> = Vec::new();
    let mut cur = String::new();
    let mut quoted = false;
    let mut started = false;
    let mut it = exec.chars();
    while let Some(c) = it.next() {
        match c {
            '"' if !quoted => {
                quoted = true;
                started = true;
            }
            '"' => quoted = false,
            '\\' if quoted => match it.next() {
                Some(e @ ('"' | '`' | '$' | '\\')) => cur.push(e),
                Some(o) => return Err(format!("\\{o} in a quoted argument")),
                None => return Err("ends in \\".into()),
            },
            ' ' | '\t' if !quoted => {
                if started || !cur.is_empty() {
                    words.push((std::mem::take(&mut cur), started));
                }
                started = false;
            }
            _ => cur.push(c),
        }
    }
    if quoted {
        return Err("unclosed quote".into());
    }
    if started || !cur.is_empty() {
        words.push((cur, started));
    }
    let mut argv = Vec::new();
    for (w, was_quoted) in words {
        if was_quoted {
            argv.push(w);
            continue;
        }
        match w.as_str() {
            "%f" | "%F" | "%u" | "%U" | "%d" | "%D" | "%n" | "%N" | "%v" | "%m" => continue,
            "%i" => {
                if let Some(i) = icon.filter(|i| !i.is_empty()) {
                    argv.push("--icon".into());
                    argv.push(i.into());
                }
                continue;
            }
            _ => {}
        }
        let mut out = String::new();
        let mut cs = w.chars();
        while let Some(c) = cs.next() {
            if c != '%' {
                out.push(c);
                continue;
            }
            match cs.next() {
                Some('%') => out.push('%'),
                Some('c') => out.push_str(name),
                Some('k') => out.push_str(file),
                Some('f' | 'F' | 'u' | 'U' | 'd' | 'D' | 'n' | 'N' | 'v' | 'm' | 'i') => {}
                Some(o) => return Err(format!("unknown field code %{o}")),
                None => return Err("ends in %".into()),
            }
        }
        argv.push(out);
    }
    if argv.is_empty() {
        return Err("empty Exec".into());
    }
    Ok(argv)
}

/// Whether `prog` runs: an executable path, or a name found on `path` (a `PATH` value).
pub fn on_path(prog: &str, path: &str) -> bool {
    let exe = |p: &Path| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            p.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        p.is_file()
    };
    if prog.contains('/') {
        return exe(Path::new(prog));
    }
    path.split(':').filter(|d| !d.is_empty()).any(|d| exe(&Path::new(d).join(prog)))
}

/// Every `.desktop` under each data dir's `applications/`, by desktop file ID; the first dir
/// that has an ID wins, even when that entry is `Hidden` (which then deletes the others).
pub fn desktop_files(data_dirs: &[PathBuf]) -> Vec<(String, PathBuf)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        let mut entries: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            if p.is_dir() {
                walk(root, &p, out);
            } else if p.extension().is_some_and(|e| e == "desktop")
                && let Ok(rel) = p.strip_prefix(root)
            {
                let id = rel.to_string_lossy().replace('/', "-");
                out.push((id.trim_end_matches(".desktop").to_string(), p));
            }
        }
    }
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for d in data_dirs {
        let root = d.join("applications");
        let mut found = Vec::new();
        walk(&root, &root, &mut found);
        for (id, p) in found {
            if seen.insert(id.clone()) {
                out.push((id, p));
            }
        }
    }
    out
}

/// One desktop entry as an app, or why the launcher leaves it out.
pub fn desktop_app(id: &str, file: &Path, text: &str, data_dirs: &[PathBuf], langs: &[String], path_env: &str) -> Result<App, String> {
    let e = parse_entry(text);
    if e.get("Type").map(String::as_str) != Some("Application") {
        return Err("not an application".into());
    }
    for k in ["NoDisplay", "Hidden", "X-LIVI-Hidden", "Terminal"] {
        if is_true(&e, k) {
            return Err(format!("{k}=true"));
        }
    }
    if let Some(only) = e.get("OnlyShowIn")
        && !list(only).iter().any(|d| d == DESKTOP)
    {
        return Err("OnlyShowIn leaves LIVI out".into());
    }
    if e.get("NotShowIn").is_some_and(|n| list(n).iter().any(|d| d == DESKTOP)) {
        return Err("NotShowIn LIVI".into());
    }
    if let Some(t) = e.get("TryExec")
        && !on_path(t, path_env)
    {
        return Err(format!("TryExec {t} not found"));
    }
    let name = localized(&e, "Name", langs).ok_or("no Name")?.clone();
    let exec = e.get("Exec").ok_or("no Exec")?;
    let icon = e.get("Icon").map(String::as_str);
    let argv = exec_argv(exec, &name, icon, &file.to_string_lossy())?;
    let mut app_ids = vec![id.to_string()];
    if let Some(w) = e.get("StartupWMClass").filter(|w| !w.is_empty()) {
        app_ids.push(w.clone());
    }
    Ok(App {
        id: id.to_string(),
        name,
        icon: icon.and_then(|i| find_icon(i, data_dirs, ICON_PX)),
        argv,
        cwd: e.get("Path").filter(|p| !p.is_empty()).cloned(),
        app_ids,
        source: "desktop",
        timeout_s: if id.starts_with("waydroid.") { WAYDROID_TIMEOUT_S } else { TIMEOUT_S },
    })
}

/// The size a launcher tile draws an icon at; PNGs nearest above it are preferred.
pub const ICON_PX: u32 = 128;

/// An icon by name, in `hicolor` then `pixmaps` of each data dir: SVG first, else the PNG nearest
/// at or above `size`, else the largest. An absolute path is taken as it is.
pub fn find_icon(name: &str, data_dirs: &[PathBuf], size: u32) -> Option<PathBuf> {
    if name.starts_with('/') {
        return Path::new(name).is_file().then(|| PathBuf::from(name));
    }
    let name = name.strip_suffix(".png").or_else(|| name.strip_suffix(".svg")).unwrap_or(name);
    for d in data_dirs {
        let theme = d.join("icons/hicolor");
        let mut best: Option<(u32, PathBuf)> = None;
        let Ok(rd) = std::fs::read_dir(&theme) else { continue };
        for sub in rd.flatten() {
            let dir_name = sub.file_name().to_string_lossy().to_string();
            for ext in ["svg", "png"] {
                let p = sub.path().join("apps").join(format!("{name}.{ext}"));
                if !p.is_file() {
                    continue;
                }
                let score = if ext == "svg" {
                    0
                } else {
                    let s: u32 = dir_name.split(['x', '@']).next().and_then(|s| s.parse().ok()).unwrap_or(0);
                    if s >= size { 1 + s - size } else { 100_000 + size - s }
                };
                if best.as_ref().is_none_or(|(b, bp)| score < *b || (score == *b && p < *bp)) {
                    best = Some((score, p));
                }
            }
        }
        if let Some((_, p)) = best {
            return Some(p);
        }
    }
    for d in data_dirs {
        for ext in ["svg", "png"] {
            let p = d.join("pixmaps").join(format!("{name}.{ext}"));
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

/// `waydroid app list`'s blocks (`Name:`, `packageName:`, ...) as apps launched through Waydroid.
/// Icons are Waydroid's own, from `icons_dir/<package>.png`.
pub fn waydroid_apps(list: &str, icons_dir: &Path) -> Vec<App> {
    let mut out = Vec::new();
    let mut name: Option<String> = None;
    let mut push = |name: &mut Option<String>, pkg: &str| {
        let Some(n) = name.take() else { return };
        let icon = icons_dir.join(format!("{pkg}.png"));
        out.push(App {
            id: format!("waydroid.{pkg}"),
            name: n,
            icon: icon.is_file().then_some(icon),
            argv: vec!["waydroid".into(), "app".into(), "launch".into(), pkg.into()],
            cwd: None,
            app_ids: vec![format!("waydroid.{pkg}")],
            source: "waydroid",
            timeout_s: WAYDROID_TIMEOUT_S,
        });
    };
    for line in list.lines() {
        if let Some(n) = line.strip_prefix("Name:") {
            name = Some(n.trim().to_string());
        } else if let Some(p) = line.strip_prefix("packageName:") {
            push(&mut name, p.trim());
        }
    }
    out
}

/// The shell's apps.yaml.
#[derive(Debug, Default)]
pub struct Config {
    /// These first, in this order; the rest by name.
    pub order: Vec<String>,
    /// By ID: changes to a found app, or a new one when it has `exec`.
    pub apps: BTreeMap<String, Overlay>,
    /// Lists Waydroid's apps while its session runs.
    pub waydroid: bool,
}

#[derive(Debug, Default)]
pub struct Overlay {
    pub name: Option<String>,
    pub icon: Option<String>,
    /// In desktop entry `Exec` syntax.
    pub exec: Option<String>,
    pub app_id: Option<String>,
    pub hidden: bool,
    pub timeout_s: Option<u32>,
}

/// `order: [id, ...]`, `waydroid: bool`, `apps: { <id>: { name, icon, exec, app_id, hidden,
/// timeout_s } }`. Unknown keys are errors, so a typo does not pass silently.
pub fn parse_config(text: &str) -> Result<Config, String> {
    let mut cfg = Config { waydroid: true, ..Default::default() };
    let v: Value = serde_norway::from_str(text).map_err(|e| e.to_string())?;
    let top = match v {
        Value::Null => return Ok(cfg),
        Value::Object(o) => o,
        _ => return Err("not a map".into()),
    };
    let s = |v: &Value, k: &str| v.as_str().map(String::from).ok_or(format!("{k}: not a string"));
    for (k, v) in &top {
        match k.as_str() {
            "order" => cfg.order = v.as_array().ok_or("order: not a list")?.iter().map(|i| s(i, "order")).collect::<Result<_, _>>()?,
            "waydroid" => cfg.waydroid = v.as_bool().ok_or("waydroid: not true or false")?,
            "apps" => {
                for (id, o) in v.as_object().ok_or("apps: not a map")? {
                    let mut ov = Overlay::default();
                    for (f, fv) in o.as_object().ok_or(format!("apps.{id}: not a map"))? {
                        match f.as_str() {
                            "name" => ov.name = Some(s(fv, f)?),
                            "icon" => ov.icon = Some(s(fv, f)?),
                            "exec" => ov.exec = Some(s(fv, f)?),
                            "app_id" => ov.app_id = Some(s(fv, f)?),
                            "hidden" => ov.hidden = fv.as_bool().ok_or(format!("apps.{id}.hidden: not true or false"))?,
                            "timeout_s" => ov.timeout_s = Some(fv.as_u64().ok_or(format!("apps.{id}.timeout_s: not a number"))? as u32),
                            _ => return Err(format!("apps.{id}: unknown key {f}")),
                        }
                    }
                    cfg.apps.insert(id.clone(), ov);
                }
            }
            _ => return Err(format!("unknown key {k}")),
        }
    }
    Ok(cfg)
}

/// Found apps (desktop first: Waydroid writes its own entries, by the same IDs) with the config
/// applied, hidden ones out, `order` first and the rest by name.
pub fn merge(found: Vec<App>, cfg: &Config, data_dirs: &[PathBuf]) -> Vec<App> {
    let mut seen = HashSet::new();
    let mut apps: Vec<App> = found.into_iter().filter(|a| seen.insert(a.id.clone())).collect();
    for (id, o) in &cfg.apps {
        let i = match apps.iter().position(|a| &a.id == id) {
            Some(i) => i,
            None => {
                let Some(exec) = &o.exec else { continue };
                let name = o.name.clone().unwrap_or_else(|| id.clone());
                let Ok(argv) = exec_argv(exec, &name, o.icon.as_deref(), "") else { continue };
                apps.push(App {
                    id: id.clone(),
                    name,
                    icon: None,
                    argv,
                    cwd: None,
                    app_ids: vec![id.clone()],
                    source: "config",
                    timeout_s: TIMEOUT_S,
                });
                apps.len() - 1
            }
        };
        let a = &mut apps[i];
        if let Some(n) = &o.name {
            a.name = n.clone();
        }
        if let Some(e) = &o.exec
            && let Ok(argv) = exec_argv(e, &a.name, o.icon.as_deref(), "")
        {
            a.argv = argv;
        }
        if let Some(icon) = &o.icon {
            a.icon = find_icon(icon, data_dirs, ICON_PX);
        }
        if let Some(w) = &o.app_id {
            a.app_ids.push(w.clone());
        }
        if let Some(t) = o.timeout_s {
            a.timeout_s = t;
        }
    }
    apps.retain(|a| !cfg.apps.get(&a.id).is_some_and(|o| o.hidden));
    let rank = |a: &App| cfg.order.iter().position(|o| o == &a.id).unwrap_or(usize::MAX);
    apps.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())).then_with(|| a.id.cmp(&b.id)));
    apps
}

/// Every desktop entry the launcher shows, from `data_dirs` in precedence order.
pub fn desktop_apps(data_dirs: &[PathBuf], langs: &[String], path_env: &str) -> Vec<App> {
    desktop_files(data_dirs)
        .into_iter()
        .filter_map(|(id, p)| {
            let text = std::fs::read_to_string(&p).ok()?;
            desktop_app(&id, &p, &text, data_dirs, langs, path_env).ok()
        })
        .collect()
}

/// `$XDG_DATA_HOME` (or `~/.local/share`), then `$XDG_DATA_DIRS` (or `/usr/local/share:/usr/share`).
pub fn xdg_data_dirs(env: impl Fn(&str) -> Option<String>) -> Vec<PathBuf> {
    let set = |k: &str| env(k).filter(|v| !v.is_empty());
    let home = set("XDG_DATA_HOME").map(PathBuf::from).or_else(|| set("HOME").map(|h| Path::new(&h).join(".local/share")));
    let rest = set("XDG_DATA_DIRS").unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    home.into_iter().chain(rest.split(':').filter(|d| !d.is_empty()).map(PathBuf::from)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_to_argv() {
        let ok = |exec: &str, want: &[&str]| {
            assert_eq!(exec_argv(exec, "My App", Some("my-icon"), "/a/b.desktop").as_deref(), Ok(want.iter().map(|s| s.to_string()).collect::<Vec<_>>().as_slice()), "{exec}");
        };
        ok("foo", &["foo"]);
        ok("foo %U", &["foo"]);
        ok("foo %f --x", &["foo", "--x"]);
        ok("  foo   --a  ", &["foo", "--a"]);
        ok("foo %i", &["foo", "--icon", "my-icon"]);
        ok("foo --name=%c", &["foo", "--name=My App"]);
        ok("foo %k", &["foo", "/a/b.desktop"]);
        ok("foo 100%%", &["foo", "100%"]);
        ok(r#"foo "a b" "" x"#, &["foo", "a b", "", "x"]);
        ok(r#""/opt/my app/bin" "say \"hi\" \$HOME \\ \`""#, &["/opt/my app/bin", r#"say "hi" $HOME \ `"#]);
        ok("foo --u=%u", &["foo", "--u="]);
        let bad = |exec: &str| assert!(exec_argv(exec, "n", None, "").is_err(), "{exec}");
        bad("");
        bad("%U");
        bad("foo %z");
        bad(r#"foo "open"#);
        bad(r#"foo "\a""#);
        bad("foo 5%");
        // %i without an Icon is dropped.
        assert_eq!(exec_argv("foo %i", "n", None, "").unwrap(), vec!["foo"]);
    }

    #[test]
    fn entry_values() {
        let e = parse_entry("# c\n[Desktop Entry]\nName=A\\sB\nName[de]=De\nName[pt_BR]=Br\nX=1\\\\2\nExec=a\n[Desktop Action new]\nName=Other\nExec=b\n");
        assert_eq!(e["Name"], "A B");
        assert_eq!(e["X"], "1\\2");
        assert_eq!(e["Exec"], "a");
        let l = |s: &[&str]| s.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        for (langs, want) in [
            (l(&[]), "A B"),
            (l(&["de_DE.UTF-8"]), "De"),
            (l(&["pt_BR.UTF-8"]), "Br"),
            (l(&["pt_PT"]), "A B"),
            (l(&["fr", "de"]), "De"),
        ] {
            assert_eq!(localized(&e, "Name", &langs).unwrap(), want, "{langs:?}");
        }
        assert_eq!(list("GNOME;KDE;"), vec!["GNOME", "KDE"]);
        assert_eq!(list("a\\;b;c"), vec!["a;b", "c"]);
    }

    #[test]
    fn which_entries_show() {
        let path = std::env::var("PATH").unwrap_or_default();
        let base = "[Desktop Entry]\nType=Application\nName=T\nExec=t\n";
        for (extra, shown) in [
            ("", true),
            ("NoDisplay=true\n", false),
            ("NoDisplay=false\n", true),
            ("Hidden=true\n", false),
            ("X-LIVI-Hidden=true\n", false),
            ("Terminal=true\n", false),
            ("OnlyShowIn=GNOME;KDE;\n", false),
            ("OnlyShowIn=GNOME;LIVI;\n", true),
            ("NotShowIn=LIVI;\n", false),
            ("NotShowIn=GNOME;\n", true),
            ("TryExec=/nonexistent/livi-test\n", false),
            ("TryExec=sh\n", true),
        ] {
            let r = desktop_app("t", Path::new("/t.desktop"), &format!("{base}{extra}"), &[], &[], &path);
            assert_eq!(r.is_ok(), shown, "{extra:?}: {r:?}");
        }
        for text in ["[Desktop Entry]\nType=Link\nName=T\nURL=x\n", "[Desktop Entry]\nType=Application\nName=T\n", "[Desktop Entry]\nType=Application\nExec=t\n"] {
            assert!(desktop_app("t", Path::new("/t"), text, &[], &[], &path).is_err(), "{text}");
        }
        let a = desktop_app("org.x.Y", Path::new("/t"), &format!("{base}StartupWMClass=yy\nPath=/tmp\n"), &[], &[], &path).unwrap();
        assert_eq!(a.app_ids, vec!["org.x.Y", "yy"]);
        assert_eq!(a.cwd.as_deref(), Some("/tmp"));
        assert_eq!(a.timeout_s, TIMEOUT_S);
    }

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("livi-apps-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn touch(p: &Path, text: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    #[test]
    fn icon_lookup() {
        let d = tmp("icons");
        let (a, b) = (d.join("a"), d.join("b"));
        for f in [
            "a/icons/hicolor/48x48/apps/png48.png",
            "a/icons/hicolor/256x256/apps/png48.png",
            "a/icons/hicolor/48x48/apps/svg.png",
            "a/icons/hicolor/scalable/apps/svg.svg",
            "a/icons/hicolor/32x32/apps/small.png",
            "a/icons/hicolor/64x64/apps/small.png",
            "a/pixmaps/pix.png",
            "b/icons/hicolor/48x48/apps/later.png",
            "b/icons/hicolor/48x48/apps/png48.png",
        ] {
            touch(&d.join(f), "");
        }
        let dirs = vec![a.clone(), b.clone()];
        for (name, size, want) in [
            ("png48", 48, Some("a/icons/hicolor/48x48/apps/png48.png")),
            ("png48", 128, Some("a/icons/hicolor/256x256/apps/png48.png")),
            ("svg", 128, Some("a/icons/hicolor/scalable/apps/svg.svg")),
            ("small", 128, Some("a/icons/hicolor/64x64/apps/small.png")),
            ("pix", 128, Some("a/pixmaps/pix.png")),
            ("pix.png", 128, Some("a/pixmaps/pix.png")),
            ("later", 128, Some("b/icons/hicolor/48x48/apps/later.png")),
            ("missing", 128, None),
        ] {
            assert_eq!(find_icon(name, &dirs, size), want.map(|w| d.join(w)), "{name}@{size}");
        }
        let abs = d.join("a/pixmaps/pix.png");
        assert_eq!(find_icon(&abs.to_string_lossy(), &[], 1), Some(abs));
        assert_eq!(find_icon("/nonexistent.png", &[], 1), None);
    }

    #[test]
    fn earlier_dirs_win_and_hidden_masks() {
        let d = tmp("ids");
        let entry = |name: &str, extra: &str| format!("[Desktop Entry]\nType=Application\nName={name}\nExec=x\n{extra}");
        touch(&d.join("home/applications/a.desktop"), &entry("Home A", ""));
        touch(&d.join("home/applications/gone.desktop"), &entry("Gone", "Hidden=true\n"));
        touch(&d.join("sys/applications/a.desktop"), &entry("Sys A", ""));
        touch(&d.join("sys/applications/gone.desktop"), &entry("Gone", ""));
        touch(&d.join("sys/applications/vendor/sub.desktop"), &entry("Sub", ""));
        touch(&d.join("sys/applications/notes.txt"), "");
        let apps = desktop_apps(&[d.join("home"), d.join("sys")], &[], "");
        let got: Vec<(&str, &str)> = apps.iter().map(|a| (a.id.as_str(), a.name.as_str())).collect();
        assert_eq!(got, vec![("a", "Home A"), ("vendor-sub", "Sub")]);
    }

    #[test]
    fn waydroid_list() {
        let d = tmp("waydroid");
        touch(&d.join("com.android.settings.png"), "");
        let out = "Name: Settings\npackageName: com.android.settings\ncategories:\n\tandroid.intent.category.LAUNCHER\n\nName: Files\npackageName: com.android.documentsui\ncategories:\n";
        let apps = waydroid_apps(out, &d);
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].id, "waydroid.com.android.settings");
        assert_eq!(apps[0].name, "Settings");
        assert_eq!(apps[0].argv, vec!["waydroid", "app", "launch", "com.android.settings"]);
        assert_eq!(apps[0].icon, Some(d.join("com.android.settings.png")));
        assert_eq!(apps[1].icon, None);
        assert_eq!(apps[1].timeout_s, WAYDROID_TIMEOUT_S);
        assert!(waydroid_apps("", &d).is_empty());
    }

    fn app(id: &str, name: &str) -> App {
        App { id: id.into(), name: name.into(), icon: None, argv: vec![id.into()], cwd: None, app_ids: vec![id.into()], source: "desktop", timeout_s: TIMEOUT_S }
    }

    #[test]
    fn config_merge() {
        let cfg = parse_config(
            "order: [z, new]\nwaydroid: false\napps:\n  a: { name: Renamed, app_id: a-window, timeout_s: 5 }\n  b: { hidden: true }\n  new: { name: New, exec: \"run --x %U\" }\n  ghost: { name: Ghost }\n",
        )
        .unwrap();
        assert!(!cfg.waydroid);
        let found = vec![app("b", "Bee"), app("a", "Ay"), app("z", "Zed"), app("c", "cee"), app("a", "dup")];
        let got = merge(found, &cfg, &[]);
        let ids: Vec<&str> = got.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["z", "new", "c", "a"]);
        let a = got.iter().find(|a| a.id == "a").unwrap();
        assert_eq!((a.name.as_str(), a.app_ids.clone(), a.timeout_s), ("Renamed", vec!["a".to_string(), "a-window".to_string()], 5));
        let n = got.iter().find(|a| a.id == "new").unwrap();
        assert_eq!((n.argv.clone(), n.source), (vec!["run".to_string(), "--x".to_string()], "config"));
        assert!(parse_config("bogus: 1\n").is_err());
        assert!(parse_config("").unwrap().waydroid);
        assert!(parse_config("order: [a]\n").unwrap().waydroid);
    }

    #[test]
    fn data_dirs_from_env() {
        let env = |pairs: &'static [(&'static str, &'static str)]| move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
        let p = |v: &[&str]| v.iter().map(PathBuf::from).collect::<Vec<_>>();
        assert_eq!(xdg_data_dirs(env(&[("HOME", "/h")])), p(&["/h/.local/share", "/usr/local/share", "/usr/share"]));
        assert_eq!(xdg_data_dirs(env(&[("HOME", "/h"), ("XDG_DATA_HOME", "/d"), ("XDG_DATA_DIRS", "/x::/y")])), p(&["/d", "/x", "/y"]));
    }
}
