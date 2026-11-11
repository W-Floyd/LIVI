#!/usr/bin/env python3
"""Swap red and blue of a screenshot: bochs ignores the RGBA byte order gralloc asks for.
usage: swap-rb.py in.png out.png"""
import sys
from PIL import Image
r, g, b = Image.open(sys.argv[1]).convert("RGB").split()
Image.merge("RGB", (b, g, r)).save(sys.argv[2])
