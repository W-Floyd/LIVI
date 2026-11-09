//! Screenshot comparison against goldens, on RGBA8 pixels.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl Rect {
    fn contains(&self, x: u32, y: u32) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }
}

#[derive(Debug, PartialEq)]
pub struct Diff {
    pub differing: usize,
    /// Pixels outside the mask: what `differing` is a share of.
    pub compared: usize,
    /// RGBA8: the golden dimmed to grey, differing pixels in red, masked ones in blue.
    pub image: Vec<u8>,
}

/// A pixel differs when any channel is off by more than `tolerance`. `None` when the sizes differ.
pub fn compare(
    golden: &[u8],
    actual: &[u8],
    width: u32,
    tolerance: u8,
    mask: &[Rect],
) -> Option<Diff> {
    if golden.len() != actual.len() || golden.len() % 4 != 0 || width == 0 {
        return None;
    }
    let mut differing = 0;
    let mut compared = 0;
    let mut image = Vec::with_capacity(golden.len());
    for (i, (g, a)) in golden.chunks_exact(4).zip(actual.chunks_exact(4)).enumerate() {
        let (x, y) = (i as u32 % width, i as u32 / width);
        if mask.iter().any(|r| r.contains(x, y)) {
            image.extend_from_slice(&[0, 0, 160, 255]);
            continue;
        }
        compared += 1;
        if g.iter().zip(a).any(|(g, a)| g.abs_diff(*a) > tolerance) {
            differing += 1;
            image.extend_from_slice(&[255, 0, 0, 255]);
        } else {
            let grey = ((g[0] as u32 + g[1] as u32 + g[2] as u32) / 3 / 3 + 40) as u8;
            image.extend_from_slice(&[grey, grey, grey, 255]);
        }
    }
    Some(Diff { differing, compared, image })
}

#[cfg(test)]
mod tests {
    use super::*;

    const BLACK: [u8; 4] = [0, 0, 0, 255];

    fn img(px: &[[u8; 4]]) -> Vec<u8> {
        px.concat()
    }

    #[test]
    fn compare_cases() {
        let off = |v| [v, 0, 0, 255];
        let all = Rect { x: 0, y: 0, w: 2, h: 2 };
        let right = Rect { x: 1, y: 0, w: 1, h: 2 };
        let cases: &[(&str, Vec<u8>, u8, &[Rect], Option<usize>)] = &[
            ("identical", img(&[BLACK; 4]), 0, &[], Some(0)),
            ("within tolerance", img(&[off(3), BLACK, BLACK, BLACK]), 3, &[], Some(0)),
            ("over tolerance", img(&[off(4), BLACK, BLACK, off(9)]), 3, &[], Some(2)),
            ("masked", img(&[BLACK, off(9), BLACK, off(9)]), 0, &[right], Some(0)),
            ("all masked", img(&[off(9); 4]), 0, &[all], Some(0)),
            ("size mismatch", img(&[BLACK; 3]), 0, &[], None),
        ];
        let golden = img(&[BLACK; 4]);
        for (name, actual, tol, mask, want) in cases {
            let got = compare(&golden, actual, 2, *tol, mask);
            assert_eq!(got.as_ref().map(|d| d.differing), *want, "{name}");
            if let Some(d) = got {
                assert_eq!(d.image.len(), golden.len(), "{name}");
                let masked = mask.iter().map(|r| (r.w * r.h) as usize).sum::<usize>();
                assert_eq!(d.compared, 4 - masked, "{name}");
            }
        }
    }
}
