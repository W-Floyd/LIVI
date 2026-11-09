"""Text measurement and line breaking with the vendor's fonts, shared by layout and render."""
from PIL import ImageFont


class Fonts:
    def __init__(self, regular, bold):
        self.files = {"regular": regular, "bold": bold}
        self._cache = {}

    def get(self, weight, px):
        k = (weight, int(round(px)))
        if k not in self._cache:
            self._cache[k] = ImageFont.truetype(self.files[weight], max(1, k[1]))
        return self._cache[k]


def wrap(font, text, width, max_lines):
    """Greedy word wrap to `width` px; the last kept line is cut with an ellipsis."""
    lines = []
    if width is not None:
        width += SLACK
    for para in text.split("\n"):
        words, line = para.split(" "), ""
        for w in words:
            trial = (line + " " + w).strip() if line else w
            if width is None or font.getlength(trial) <= width or not line:
                line = trial
            else:
                lines.append(line)
                line = w
        lines.append(line)
    if max_lines and len(lines) > max_lines:
        lines = lines[:max_lines]
        last = lines[-1]
        while last and width is not None and font.getlength(last + "…") > width:
            last = last[:-1]
        lines[-1] = last + "…"
    return lines


SLACK = 1.5  # px: rects are rounded to whole pixels, text measured at its exact width.


def single(font, text, width):
    """One line, cut with an ellipsis to fit `width` px (Android's singleLine)."""
    text = text.replace("\n", " ")
    if width is not None:
        width += SLACK
    if width is None or font.getlength(text) <= width:
        return text
    while text and font.getlength(text + "…") > width:
        text = text[:-1]
    return text + "…"


def block(fonts, spec, density, avail_w_px):
    """Lines and metrics for a text spec: (lines, width px, height px, ascent px, line height px)."""
    font = fonts.get(spec["weight"], spec["size_px"])
    asc, desc = font.getmetrics()
    lh = (asc + desc) * spec.get("line_mult", 1.0) + spec.get("line_extra_px", 0.0)
    if spec.get("single_line") or spec.get("max_lines") == 1:
        lines = [single(font, spec["string"], avail_w_px)]
    else:
        lines = wrap(font, spec["string"], avail_w_px, spec.get("max_lines"))
    w = max((font.getlength(l) for l in lines), default=0)
    h = (asc + desc) + lh * (len(lines) - 1)
    return lines, w, h, asc, lh
