// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

const POWER_HELPER: &str = "/usr/local/lib/livi/livi-power.sh";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Power {
    Off,
    Reboot,
}

impl Power {
    fn arg(self) -> &'static str {
        match self {
            Power::Off => "poweroff",
            Power::Reboot => "reboot",
        }
    }
}

pub fn owns_host() -> bool {
    std::env::var("LIVI_KIOSK").is_ok_and(|v| v == "1")
}

/// What to run under `sudo -n`: the installer's power script (its own narrow sudoers grant)
/// where there is one, else the root helper, which reboots only.
fn command(action: Power, script: bool, helper: Option<&Path>) -> Option<Vec<String>> {
    if script {
        return Some(vec![POWER_HELPER.into(), action.arg().into()]);
    }
    match (action, helper) {
        (Power::Reboot, Some(h)) => Some(vec![h.display().to_string(), "--reboot".into()]),
        _ => None,
    }
}

pub fn run(action: Power, helper: Option<&Path>) {
    let Some(cmd) = command(action, Path::new(POWER_HELPER).exists(), helper) else {
        eprintln!("[power] helper missing, run the installer again to let LIVI power the host");
        return;
    };
    let action = action.arg();
    // Waited for: once the core exits, its service's leftover processes are killed.
    let ran = Command::new("sudo")
        .arg("-n")
        .args(&cmd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .status();
    match ran {
        Ok(s) if s.success() => println!("[power] host {action} requested"),
        Ok(s) => eprintln!("[power] could not {action}: {s}"),
        Err(e) => eprintln!("[power] could not {action}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_narrowest_grant_runs_it() {
        let h = Path::new("/r/driver/livi-helperd");
        let cases: [(Power, bool, Option<&Path>, Option<&[&str]>); 5] = [
            (
                Power::Reboot,
                true,
                Some(h),
                Some(&[POWER_HELPER, "reboot"]),
            ),
            (Power::Off, true, None, Some(&[POWER_HELPER, "poweroff"])),
            (
                Power::Reboot,
                false,
                Some(h),
                Some(&["/r/driver/livi-helperd", "--reboot"]),
            ),
            (Power::Reboot, false, None, None),
            (Power::Off, false, Some(h), None),
        ];
        for (action, script, helper, want) in cases {
            let want = want.map(|w| w.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            assert_eq!(
                command(action, script, helper),
                want,
                "{action:?} {script} {helper:?}"
            );
        }
    }
}
