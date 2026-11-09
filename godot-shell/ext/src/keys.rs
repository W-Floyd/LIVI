//! Godot's physical keycodes to the evdev codes Wayland clients get. Physical, so a key means
//! its position on a US layout and the client's keymap decides the character.

/// Godot's `Key` enum: letters and digits are their ASCII codes, the rest are SPECIAL | n.
const SPECIAL: i64 = 1 << 22;

/// The evdev code (`KEY_*` in linux/input-event-codes.h), or `None` for keys with no mapping.
pub fn evdev(godot: i64) -> Option<u32> {
    const LETTERS: [u32; 26] = [
        30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
    ];
    Some(match godot {
        65..=90 => LETTERS[(godot - 65) as usize],
        49..=57 => (godot - 49 + 2) as u32, // 1 to 9 are KEY_1 (2) to KEY_9 (10)
        48 => 11,
        32 => 57,
        45 => 12,
        61 => 13,
        91 => 26,
        93 => 27,
        59 => 39,
        39 => 40,
        96 => 41,
        92 => 43,
        44 => 51,
        46 => 52,
        47 => 53,
        k if k & SPECIAL != 0 => match k & !SPECIAL {
            0x01 => 1,   // Escape
            0x02 => 15,  // Tab
            0x04 => 14,  // Backspace
            0x05 => 28,  // Enter
            0x06 => 96,  // keypad Enter
            0x07 => 110, // Insert
            0x08 => 111, // Delete
            0x0D => 102, // Home
            0x0E => 107, // End
            0x0F => 105, // Left
            0x10 => 103, // Up
            0x11 => 106, // Right
            0x12 => 108, // Down
            0x13 => 104, // Page up
            0x14 => 109, // Page down
            0x15 => 42,  // Shift (left)
            0x16 => 29,  // Ctrl (left)
            0x17 => 125, // Meta (left)
            0x18 => 56,  // Alt (left)
            0x19 => 58,  // Caps lock
            n @ 0x1C..=0x25 => 59 + (n - 0x1C) as u32, // F1 to F10
            0x26 => 87, // F11
            0x27 => 88, // F12
            _ => return None,
        },
        _ => return None,
    })
}

/// Godot's mouse button index to the evdev button code.
pub fn evdev_button(index: i64) -> Option<u32> {
    Some(match index {
        1 => 0x110, // BTN_LEFT
        2 => 0x111, // BTN_RIGHT
        3 => 0x112, // BTN_MIDDLE
        8 => 0x113, // BTN_SIDE (Godot's XBUTTON1)
        9 => 0x114, // BTN_EXTRA
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_map_to_evdev() {
        let cases = [
            (65, Some(30)),          // A
            (90, Some(44)),          // Z
            (81, Some(16)),          // Q
            (49, Some(2)),           // 1
            (48, Some(11)),          // 0
            (32, Some(57)),          // space
            (SPECIAL | 0x01, Some(1)), // Escape
            (SPECIAL | 0x05, Some(28)), // Enter
            (SPECIAL | 0x0F, Some(105)), // Left
            (SPECIAL | 0x1C, Some(59)), // F1
            (SPECIAL | 0x25, Some(68)), // F10
            (SPECIAL | 0x27, Some(88)), // F12
            (SPECIAL | 0x7F, None),
            (1, None),
        ];
        for (godot, want) in cases {
            assert_eq!(evdev(godot), want, "godot key {godot:#x}");
        }
    }

    #[test]
    fn buttons_map_to_evdev() {
        let cases = [(1, Some(0x110)), (2, Some(0x111)), (3, Some(0x112)), (4, None)];
        for (index, want) in cases {
            assert_eq!(evdev_button(index), want, "button {index}");
        }
    }
}
