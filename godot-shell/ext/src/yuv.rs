//! Limited-range YUV <-> RGB: the decoder's matrices for the compositor's shader, and the
//! encoder the test client draws NV12 with, so a round trip checks both.

/// BT.709 from 720 lines up (or 1280 columns), BT.601 below it: what H.264 carries when the
/// stream does not say, and the usual split.
pub fn is_709(width: u32, height: u32) -> bool {
    height >= 720 || width >= 1280
}

/// (Kr, Kb) of the matrix.
fn k(hd: bool) -> (f32, f32) {
    if hd { (0.2126, 0.0722) } else { (0.299, 0.114) }
}

/// For `rgb = m * (yuv - off)`, with `m` column-major (a GLSL `mat3`) and yuv in 0..1 as sampled:
/// limited range, 16..235 luma and 16..240 chroma.
pub fn coeffs(hd: bool) -> ([f32; 9], [f32; 3]) {
    let (kr, kb) = k(hd);
    let kg = 1.0 - kr - kb;
    let (ys, cs) = (255.0 / 219.0, 255.0 / 224.0);
    let (rv, bu) = (2.0 * (1.0 - kr), 2.0 * (1.0 - kb));
    let (gu, gv) = (bu * kb / kg, rv * kr / kg);
    (
        [ys, ys, ys, 0.0, -gu * cs, bu * cs, rv * cs, -gv * cs, 0.0],
        [16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0],
    )
}

/// Limited-range 8-bit Y, U (Cb), V (Cr) of an RGB pixel.
pub fn rgb_to_yuv(rgb: [u8; 3], hd: bool) -> [u8; 3] {
    let (kr, kb) = k(hd);
    let [r, g, b] = rgb.map(|c| c as f32 / 255.0);
    let y = kr * r + (1.0 - kr - kb) * g + kb * b;
    let u = (b - y) / (2.0 * (1.0 - kb));
    let v = (r - y) / (2.0 * (1.0 - kr));
    let q = |x: f32| x.round().clamp(0.0, 255.0) as u8;
    [q(16.0 + 219.0 * y), q(128.0 + 224.0 * u), q(128.0 + 224.0 * v)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(yuv: [u8; 3], hd: bool) -> [u8; 3] {
        let (m, off) = coeffs(hd);
        let c = yuv.map(|x| x as f32 / 255.0);
        let d = [c[0] - off[0], c[1] - off[1], c[2] - off[2]];
        std::array::from_fn(|i| ((m[i] * d[0] + m[3 + i] * d[1] + m[6 + i] * d[2]).clamp(0.0, 1.0) * 255.0).round() as u8)
    }

    #[test]
    fn decoding_inverts_encoding() {
        let colors = [[255, 255, 255], [255, 255, 0], [0, 255, 255], [0, 255, 0], [255, 0, 255], [255, 0, 0], [0, 0, 255], [0, 0, 0], [60, 60, 60], [200, 120, 40]];
        for hd in [false, true] {
            for c in colors {
                let got = decode(rgb_to_yuv(c, hd), hd);
                for i in 0..3 {
                    assert!((got[i] as i32 - c[i] as i32).abs() <= 3, "hd={hd} {c:?} -> {got:?}");
                }
            }
        }
    }

    #[test]
    fn limited_range_black_and_white() {
        assert_eq!(rgb_to_yuv([0, 0, 0], false), [16, 128, 128]);
        assert_eq!(rgb_to_yuv([255, 255, 255], true), [235, 128, 128]);
        assert!(!is_709(800, 480) && is_709(1280, 720) && is_709(1920, 1080));
    }
}
