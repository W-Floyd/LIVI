//! The shell's own settings portal: `org.freedesktop.portal.Settings` under
//! `org.freedesktop.portal.Desktop` on the session bus, so launched apps follow the shell's look
//! (day or night, accent, reduced motion) and switch live. The real xdg-desktop-portal cannot
//! serve the kiosk: its user unit requires graphical-session.target, which nothing starts there
//! ("startup job failed"), and its backends would read GSettings the shell does not keep. Only
//! Settings is served (and the host Registry GTK checks first); other portal interfaces answer
//! "unknown", which GTK takes as no portal at once instead of waiting on an activation.
//!
//! GTK4 on Wayland takes every `org.gnome.*` setting from a portal that answers, its built-in
//! defaults standing in for the keys left out, so the few with poor defaults (icon theme "gnome",
//! text scaling 0) are served too, and `gtk-theme` turns GTK3 apps dark.

use std::collections::HashMap;
use std::sync::Mutex;

use zbus::object_server::SignalEmitter;
use zbus::fdo::{RequestNameFlags, RequestNameReply};
use zbus::{Connection, OwnedVariant, Variant, interface};

pub const BUS_NAME: &str = "org.freedesktop.portal.Desktop";
pub const PATH: &str = "/org/freedesktop/portal/desktop";

/// What the shell's apps should look like.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Look {
    pub dark: bool,
    /// sRGB, 0 to 1.
    pub accent: [f64; 3],
    pub reduced_motion: bool,
}

impl Default for Look {
    fn default() -> Self {
        Look { dark: false, accent: [0.21, 0.52, 0.89], reduced_motion: false }
    }
}

/// Every setting served, as (namespace, key, value).
pub fn settings(look: &Look) -> Vec<(&'static str, &'static str, Variant<'static>)> {
    let [r, g, b] = look.accent;
    vec![
        // 1 prefers dark, 2 light (0 would be "no preference", which apps read as light).
        ("org.freedesktop.appearance", "color-scheme", Variant::from(if look.dark { 1u32 } else { 2 })),
        ("org.freedesktop.appearance", "accent-color", Variant::from((r, g, b))),
        ("org.freedesktop.appearance", "contrast", Variant::from(0u32)),
        ("org.freedesktop.appearance", "reduced-motion", Variant::from(look.reduced_motion as u32)),
        ("org.gnome.desktop.interface", "color-scheme", Variant::from(if look.dark { "prefer-dark" } else { "default" })),
        ("org.gnome.desktop.interface", "gtk-theme", Variant::from(if look.dark { "Adwaita-dark" } else { "Adwaita" })),
        ("org.gnome.desktop.interface", "icon-theme", Variant::from("Adwaita")),
        ("org.gnome.desktop.interface", "cursor-theme", Variant::from("Adwaita")),
        ("org.gnome.desktop.interface", "cursor-size", Variant::from(24i32)),
        ("org.gnome.desktop.interface", "text-scaling-factor", Variant::from(1.0f64)),
        ("org.gnome.desktop.interface", "enable-animations", Variant::from(!look.reduced_motion)),
        ("org.gnome.desktop.interface", "font-antialiasing", Variant::from("grayscale")),
        ("org.gnome.desktop.interface", "font-hinting", Variant::from("slight")),
        ("org.gnome.desktop.interface", "font-rgba-order", Variant::from("rgb")),
    ]
}

/// Whether `ns` is wanted by ReadAll's `patterns`: none means all; a trailing `*` is a prefix.
pub fn wanted(ns: &str, patterns: &[String]) -> bool {
    patterns.is_empty()
        || patterns.iter().any(|p| p.is_empty() || p == ns || p.strip_suffix('*').is_some_and(|pre| ns.starts_with(pre)))
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.portal.Error")]
enum PortalError {
    #[zbus(error)]
    ZBus(zbus::Error),
    NotFound(String),
}

struct Settings {
    look: Look,
}

impl Settings {
    fn one(&self, namespace: &str, key: &str) -> Result<OwnedVariant, PortalError> {
        settings(&self.look)
            .into_iter()
            .find(|(n, k, _)| *n == namespace && *k == key)
            .map(|(_, _, v)| owned(v))
            .ok_or_else(|| PortalError::NotFound(format!("{namespace} {key}")))
    }
}

fn owned(v: Variant<'_>) -> OwnedVariant {
    v.try_to_owned().expect("a plain value has no fd to fail on")
}

#[interface(name = "org.freedesktop.portal.Settings")]
impl Settings {
    fn read_all(&self, namespaces: Vec<String>) -> HashMap<String, HashMap<String, OwnedVariant>> {
        let mut out: HashMap<String, HashMap<String, OwnedVariant>> = HashMap::new();
        for (n, k, v) in settings(&self.look) {
            if wanted(n, &namespaces) {
                out.entry(n.into()).or_default().insert(k.into(), owned(v));
            }
        }
        out
    }

    /// The deprecated call, whose value comes wrapped in a second variant (libadwaita uses it).
    fn read(&self, namespace: &str, key: &str) -> Result<OwnedVariant, PortalError> {
        let v = self.one(namespace, key)?;
        Ok(owned(Variant::Variant(Box::new(Variant::from(v)))))
    }

    fn read_one(&self, namespace: &str, key: &str) -> Result<OwnedVariant, PortalError> {
        self.one(namespace, key)
    }

    #[zbus(signal)]
    async fn setting_changed(emitter: &SignalEmitter<'_>, namespace: &str, key: &str, value: Variant<'_>) -> zbus::Result<()>;

    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        2
    }
}

/// GTK registers each app here before using any portal; not being sandboxed, there is nothing
/// to record.
struct Registry;

#[interface(name = "org.freedesktop.host.portal.Registry")]
impl Registry {
    fn register(&self, _app_id: &str, _options: HashMap<String, OwnedVariant>) {}

    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        1
    }
}

/// Serves the portal on the bus at `address` (the session bus when None) with `look`. Fails when
/// another process owns the name (a real portal, in a desktop session): the shell's look then
/// reaches apps only through their environment.
pub async fn serve(address: Option<&str>, look: Look) -> Result<Connection, String> {
    let b = match address {
        Some(a) => zbus::connection::Builder::address(a),
        None => zbus::connection::Builder::session(),
    };
    let conn = b
        .serve_at(PATH, Settings { look })
        .serve_at(PATH, Registry)
        .build()
        .await
        .map_err(|e| format!("session bus: {e}"))?;
    // Not queued: a real portal that owns the name keeps it, and this one stays out of its way.
    let reply = conn.request_name_with_flags(BUS_NAME, RequestNameFlags::DO_NOT_QUEUE).await.map_err(|e| format!("{BUS_NAME}: {e}"))?;
    match reply {
        RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner => Ok(conn),
        _ => Err(format!("{BUS_NAME} is another process's")),
    }
}

/// Changes the look, telling apps each setting that changed.
pub async fn update(conn: &Connection, look: Look) -> zbus::Result<()> {
    let iface = conn.object_server().interface::<_, Settings>(PATH).await?;
    let old = std::mem::replace(&mut iface.get_mut().await.look, look);
    let before = settings(&old);
    for (n, k, v) in settings(&look) {
        if before.iter().any(|(bn, bk, bv)| *bn == n && *bk == k && *bv != v) {
            Settings::setting_changed(iface.signal_emitter(), n, k, v).await?;
        }
    }
    Ok(())
}

/// The shell's one portal, for the life of the process.
static SERVED: Mutex<Option<Connection>> = Mutex::new(None);

/// Serves the portal on the session bus unless it already is: "" when it is, else why not.
pub fn start(look: Look) -> String {
    let mut served = SERVED.lock().unwrap_or_else(|e| e.into_inner());
    if served.is_some() {
        return String::new();
    }
    match zbus::block_on(serve(None, look)) {
        Ok(c) => {
            *served = Some(c);
            String::new()
        }
        Err(e) => e,
    }
}

/// The served portal's new look; nothing when it is not served.
pub fn set_look(look: Look) {
    let served = SERVED.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(c) = served.as_ref()
        && let Err(e) = zbus::block_on(update(c, look))
    {
        eprintln!("portal: {e}");
    }
}

pub fn serving() -> bool {
    SERVED.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::process::{Child, Command, Stdio};
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn namespace_patterns() {
        let p = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        for (ns, patterns, want) in [
            ("org.freedesktop.appearance", p(&[]), true),
            ("org.freedesktop.appearance", p(&[""]), true),
            ("org.freedesktop.appearance", p(&["org.freedesktop.appearance"]), true),
            ("org.freedesktop.appearance", p(&["org.gnome.*", "org.freedesktop.appearance"]), true),
            ("org.gnome.desktop.interface", p(&["org.gnome.*"]), true),
            ("org.gnome.desktop.interface", p(&["org.freedesktop.*"]), false),
            ("org.gnome.desktop.interface", p(&["org.gnome.desktop"]), false),
        ] {
            assert_eq!(wanted(ns, &patterns), want, "{ns} {patterns:?}");
        }
    }

    /// A private bus: `dbus-daemon` with a config of its own, so no service is activated.
    struct Bus(Child, String);

    impl Drop for Bus {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn bus() -> Option<Bus> {
        let dir = std::env::temp_dir().join(format!("livi-portal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok()?;
        let conf = dir.join("bus.conf");
        let sock = dir.join("bus");
        std::fs::write(
            &conf,
            format!(
                "<busconfig><type>session</type><listen>unix:path={}</listen><auth>EXTERNAL</auth>\
                 <policy context=\"default\"><allow send_destination=\"*\" eavesdrop=\"true\"/><allow eavesdrop=\"true\"/><allow own=\"*\"/></policy></busconfig>",
                sock.display()
            ),
        )
        .ok()?;
        let mut child = Command::new("dbus-daemon").arg(format!("--config-file={}", conf.display())).args(["--nofork", "--print-address"]).stdout(Stdio::piped()).spawn().ok()?;
        let mut line = String::new();
        BufReader::new(child.stdout.take()?).read_line(&mut line).ok()?;
        Some(Bus(child, line.trim().to_string()))
    }

    async fn call<R: for<'d> zbus::export::serde::Deserialize<'d> + zbus::Type>(c: &Connection, iface: &str, method: &str, body: &(impl zbus::export::serde::Serialize + zbus::Type)) -> zbus::Result<R> {
        let m = c.call_method(Some(BUS_NAME), PATH, Some(iface), method, body).await?;
        m.body().deserialize::<R>()
    }

    const SETTINGS: &str = "org.freedesktop.portal.Settings";
    const SCHEME: (&str, &str) = ("org.freedesktop.appearance", "color-scheme");

    /// The contract apps rely on: color-scheme by each read call, ReadAll by namespace, the
    /// interface's version, NotFound for a missing key, SettingChanged on a day/night flip, and a
    /// second server staying out of the first's way.
    #[test]
    fn portal_contract() {
        let Some(bus) = bus() else {
            eprintln!("skipped: no dbus-daemon");
            return;
        };
        let addr = bus.1.clone();
        let day = Look::default();
        let night = Look { dark: true, accent: [0.9, 0.3, 0.1], ..day };
        let server = zbus::block_on(serve(Some(&addr), day)).expect("serve");
        let client = zbus::block_on(zbus::connection::Builder::address(addr.as_str()).build()).expect("client");
        zbus::block_on(async {
            let v: OwnedVariant = call(&client, SETTINGS, "ReadOne", &SCHEME).await.unwrap();
            assert_eq!(u32::try_from(v).unwrap(), 2);
            let v: OwnedVariant = call(&client, SETTINGS, "Read", &SCHEME).await.unwrap();
            let Variant::Variant(inner) = &*v else { panic!("Read: {v:?}, want a variant in a variant") };
            assert_eq!(**inner, Variant::U32(2));
            let all: HashMap<String, HashMap<String, OwnedVariant>> = call(&client, SETTINGS, "ReadAll", &(vec!["org.freedesktop.*"],)).await.unwrap();
            assert_eq!(all.keys().collect::<Vec<_>>(), ["org.freedesktop.appearance"]);
            assert!(all["org.freedesktop.appearance"].contains_key("accent-color"));
            let ver: OwnedVariant = call(&client, "org.freedesktop.DBus.Properties", "Get", &(SETTINGS, "version")).await.unwrap();
            assert_eq!(u32::try_from(ver).unwrap(), 2);
            let missing = call::<OwnedVariant>(&client, SETTINGS, "ReadOne", &("org.freedesktop.appearance", "nope")).await.unwrap_err();
            assert!(matches!(&missing, zbus::Error::MethodError(n, _, _) if n.as_str() == "org.freedesktop.portal.Error.NotFound"), "{missing:?}");
            // Taken: the second stays out.
            assert!(serve(Some(&addr), day).await.is_err());
        });

        // SettingChanged, read on a thread of its own so a missing signal fails instead of hanging.
        let (tx, rx) = mpsc::channel();
        let listener = client.clone();
        std::thread::spawn(move || {
            zbus::block_on(async move {
                let rule = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).interface(SETTINGS).member("SettingChanged").build().unwrap();
                let mut stream = zbus::MessageStream::for_match_rule(rule, &listener, None).await.unwrap();
                tx.send(None).unwrap();
                loop {
                    let m = std::future::poll_fn(|cx| zbus::export::futures_core::Stream::poll_next(std::pin::Pin::new(&mut stream), cx)).await;
                    let Some(Ok(m)) = m else { return };
                    let (n, k, v): (String, String, OwnedVariant) = m.body().deserialize().unwrap();
                    if tx.send(Some((n, k, v))).is_err() {
                        return;
                    }
                }
            })
        });
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), None, "subscribed");
        zbus::block_on(update(&server, night)).unwrap();
        let mut got = HashMap::new();
        while let Ok(Some((n, k, v))) = rx.recv_timeout(Duration::from_secs(5)) {
            got.insert(format!("{n} {k}"), v);
            if got.len() == 4 {
                break;
            }
        }
        assert_eq!(got.get("org.freedesktop.appearance color-scheme").map(|v| u32::try_from(v.try_clone().unwrap()).unwrap()), Some(1), "{got:?}");
        assert!(got.contains_key("org.freedesktop.appearance accent-color"), "{got:?}");
        assert!(got.contains_key("org.gnome.desktop.interface gtk-theme"), "{got:?}");
        // Unchanged settings are not announced.
        assert!(!got.contains_key("org.freedesktop.appearance reduced-motion"), "{got:?}");
        let v: OwnedVariant = zbus::block_on(call(&client, SETTINGS, "ReadOne", &SCHEME)).unwrap();
        assert_eq!(u32::try_from(v).unwrap(), 1);
    }
}
