//! zwp_text_input_v3 with the shell as the input method. smithay's own manager relays only to an
//! input-method client (zwp_input_method_v2); the shell's keyboard is in process, so it types
//! straight into the focused client's enabled text input.

use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::zwp_text_input_manager_v3::{
    self, ZwpTextInputManagerV3,
};
use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::zwp_text_input_v3::{self, ZwpTextInputV3};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource};

use crate::compositor::State;

/// What the client says of the field it wants text for, as of its last commit.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Field {
    /// zwp_text_input_v3's content_hint bits and content_purpose.
    pub hint: u32,
    pub purpose: u32,
    /// The cursor, surface-local: x, y, width, height.
    pub rect: Option<[i32; 4]>,
    /// The text around the cursor, and the cursor and anchor as byte offsets into it.
    pub surrounding: Option<(String, i32, i32)>,
}

pub const PURPOSE_PASSWORD: u32 = 8;
pub const PURPOSE_PIN: u32 = 9;
pub const HINT_HIDDEN_TEXT: u32 = 0x40;
pub const HINT_SENSITIVE_DATA: u32 = 0x80;

#[derive(Default)]
struct Pending {
    enable: Option<bool>,
    content: Option<(u32, u32)>,
    rect: Option<[i32; 4]>,
    surrounding: Option<(String, i32, i32)>,
}

struct Instance {
    resource: ZwpTextInputV3,
    /// The surface this text input was sent `enter` for, until `leave`.
    entered: Option<WlSurface>,
    enabled: bool,
    field: Field,
    pending: Pending,
    /// Commits so far: each `done` carries it, so the client knows its state was seen.
    serial: u32,
}

/// Every bound text input, and which surface has keyboard focus.
#[derive(Default)]
pub struct TextInputs {
    instances: Vec<Instance>,
    focus: Option<WlSurface>,
    /// (surface, wanted): a text input there was enabled, or disabled, left or destroyed.
    pub changes: Vec<(WlSurface, bool)>,
    /// A tap since the last enable: the next enable of an already enabled field asks again, so a
    /// keyboard put away while the client still wants text comes back when the field is tapped.
    pub rearm: bool,
}

impl TextInputs {
    /// Sends `leave` for the old focus and `enter` for the new to its client's text inputs. A
    /// field enabled under the old focus is released.
    pub fn set_focus(&mut self, surface: Option<WlSurface>) {
        if self.focus == surface {
            return;
        }
        for i in &mut self.instances {
            if let Some(old) = i.entered.take() {
                if i.resource.is_alive() && old.is_alive() {
                    i.resource.leave(&old);
                }
                if std::mem::take(&mut i.enabled) {
                    self.changes.push((old, false));
                }
            }
        }
        self.focus = surface;
        if let Some(s) = self.focus.clone() {
            for i in &mut self.instances {
                enter(i, &s);
            }
        }
    }

    pub fn focus(&self) -> Option<&WlSurface> {
        self.focus.as_ref()
    }

    /// The enabled text input on the focused surface.
    fn active(&self) -> Option<&Instance> {
        let focus = self.focus.as_ref()?;
        self.instances.iter().find(|i| i.enabled && i.entered.as_ref() == Some(focus) && i.resource.is_alive())
    }

    /// The field on `surface`, while its text input is enabled.
    pub fn field(&self, surface: &WlSurface) -> Option<&Field> {
        self.instances.iter().find(|i| i.enabled && i.entered.as_ref() == Some(surface)).map(|i| &i.field)
    }

    /// Whether `client` has bound a text input.
    pub fn bound(&self, client: &Client) -> bool {
        self.instances.iter().any(|i| i.resource.client().as_ref() == Some(client))
    }

    /// Inserts `text` at the cursor of the enabled field. False with none.
    pub fn commit_string(&self, text: &str) -> bool {
        self.send(|r| r.commit_string(Some(text.to_owned())))
    }

    /// Deletes `before` and `after` bytes around the cursor.
    pub fn delete_surrounding(&self, before: u32, after: u32) -> bool {
        self.send(|r| r.delete_surrounding_text(before, after))
    }

    /// Text being composed, shown at the cursor until replaced; `cursor_*` are byte offsets in it.
    pub fn preedit(&self, text: &str, cursor_begin: i32, cursor_end: i32) -> bool {
        self.send(|r| r.preedit_string((!text.is_empty()).then(|| text.to_owned()), cursor_begin, cursor_end))
    }

    fn send(&self, f: impl FnOnce(&ZwpTextInputV3)) -> bool {
        let Some(i) = self.active() else { return false };
        f(&i.resource);
        i.resource.done(i.serial);
        true
    }
}

fn enter(i: &mut Instance, surface: &WlSurface) {
    if i.entered.is_none() && surface.is_alive() && i.resource.id().same_client_as(&surface.id()) {
        i.resource.enter(surface);
        i.entered = Some(surface.clone());
    }
}

impl GlobalDispatch<ZwpTextInputManagerV3, ()> for State {
    fn bind(_: &mut State, _: &DisplayHandle, _: &Client, resource: New<ZwpTextInputManagerV3>, _: &(), init: &mut DataInit<'_, State>) {
        init.init(resource, ());
    }
}

impl Dispatch<ZwpTextInputManagerV3, ()> for State {
    fn request(
        state: &mut State,
        _: &Client,
        _: &ZwpTextInputManagerV3,
        request: zwp_text_input_manager_v3::Request,
        _: &(),
        _: &DisplayHandle,
        init: &mut DataInit<'_, State>,
    ) {
        if let zwp_text_input_manager_v3::Request::GetTextInput { id, .. } = request {
            let resource = init.init(id, ());
            let ti = &mut state.text_input;
            let mut i = Instance { resource, entered: None, enabled: false, field: Field::default(), pending: Pending::default(), serial: 0 };
            if let Some(s) = ti.focus.clone() {
                enter(&mut i, &s);
            }
            ti.instances.push(i);
        }
    }
}

impl Dispatch<ZwpTextInputV3, ()> for State {
    fn request(
        state: &mut State,
        _: &Client,
        resource: &ZwpTextInputV3,
        request: zwp_text_input_v3::Request,
        _: &(),
        _: &DisplayHandle,
        _: &mut DataInit<'_, State>,
    ) {
        use zwp_text_input_v3::Request;
        let ti = &mut state.text_input;
        let Some(i) = ti.instances.iter_mut().find(|i| &i.resource == resource) else { return };
        match request {
            Request::Enable => i.pending.enable = Some(true),
            Request::Disable => i.pending.enable = Some(false),
            Request::SetSurroundingText { text, cursor, anchor } => i.pending.surrounding = Some((text, cursor, anchor)),
            Request::SetContentType { hint, purpose } => {
                use smithay::reexports::wayland_server::WEnum;
                let hint = match hint {
                    WEnum::Value(h) => h.bits(),
                    WEnum::Unknown(u) => u,
                };
                let purpose = match purpose {
                    WEnum::Value(p) => p as u32,
                    WEnum::Unknown(u) => u,
                };
                i.pending.content = Some((hint, purpose));
            }
            Request::SetCursorRectangle { x, y, width, height } => i.pending.rect = Some([x, y, width, height]),
            Request::Commit => {
                i.serial = i.serial.wrapping_add(1);
                let p = std::mem::take(&mut i.pending);
                let was = i.enabled;
                // Only between enter and leave; enable starts the field afresh.
                match p.enable {
                    Some(true) if i.entered.is_some() => {
                        if !was {
                            i.field = Field::default();
                        }
                        i.enabled = true;
                    }
                    Some(false) => i.enabled = false,
                    _ => {}
                }
                if i.enabled {
                    if let Some((hint, purpose)) = p.content {
                        (i.field.hint, i.field.purpose) = (hint, purpose);
                    }
                    if p.rect.is_some() {
                        i.field.rect = p.rect;
                    }
                    if p.surrounding.is_some() {
                        i.field.surrounding = p.surrounding;
                    }
                }
                let Some(surface) = i.entered.clone() else { return };
                if i.enabled != was {
                    ti.rearm = false;
                    ti.changes.push((surface, i.enabled));
                } else if i.enabled && p.enable == Some(true) && std::mem::take(&mut ti.rearm) {
                    ti.changes.push((surface, true));
                }
            }
            // set_text_change_cause has nothing to act on; v2's requests are not offered.
            _ => {}
        }
    }

    fn destroyed(state: &mut State, _: smithay::reexports::wayland_server::backend::ClientId, resource: &ZwpTextInputV3, _: &()) {
        let ti = &mut state.text_input;
        if let Some(n) = ti.instances.iter().position(|i| &i.resource == resource) {
            let i = ti.instances.remove(n);
            if let (true, Some(s)) = (i.enabled, i.entered) {
                ti.changes.push((s, false));
            }
        }
    }
}
