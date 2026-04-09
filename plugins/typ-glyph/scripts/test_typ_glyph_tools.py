#!/usr/bin/env python3
"""Tests for typ-glyph-tools.py"""

import io
import os
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

# Add the scripts directory to sys.path so we can import the module
sys.path.insert(0, os.path.dirname(__file__))

# These tests require Pillow and cairosvg to be installed
from PIL import Image

# Import the functions under test
from importlib.machinery import SourceFileLoader

_mod = SourceFileLoader("typ_glyph_tools", os.path.join(os.path.dirname(__file__), "typ-glyph-tools.py")).load_module()
parse_xpm = _mod.parse_xpm
validate_cmd = _mod.validate_cmd
generate_cmd = _mod.generate_cmd
render_cmd = _mod.render_cmd
ensure_dependencies = _mod.ensure_dependencies

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

VALID_XPM = '''"3 2 3 1"
"! c #000000"
"o c #FFFFFF"
". c none"
"!o."
".o!"'''

VALID_XPM_LINES = VALID_XPM.splitlines()


def _run_script(*args, stdin_text=""):
    """Run typ-glyph-tools.py as a subprocess and capture output."""
    script = os.path.join(os.path.dirname(__file__), "typ-glyph-tools.py")
    result = subprocess.run(
        [sys.executable, script] + list(args),
        input=stdin_text,
        capture_output=True,
        text=True,
    )
    return result


# ---------------------------------------------------------------------------
# parse_xpm tests
# ---------------------------------------------------------------------------

class TestParseXpm(unittest.TestCase):
    """Tests for the parse_xpm function."""

    def test_valid_xpm_dimensions(self):
        img = parse_xpm(VALID_XPM_LINES, Image)
        self.assertEqual(img.size, (3, 2))

    def test_valid_xpm_black_pixel(self):
        img = parse_xpm(VALID_XPM_LINES, Image)
        # Top-left should be black (opaque)
        r, g, b, a = img.getpixel((0, 0))
        self.assertEqual((r, g, b), (0, 0, 0))
        self.assertEqual(a, 255)

    def test_valid_xpm_white_pixel(self):
        img = parse_xpm(VALID_XPM_LINES, Image)
        # (1, 0) should be white
        r, g, b, a = img.getpixel((1, 0))
        self.assertEqual((r, g, b), (255, 255, 255))
        self.assertEqual(a, 255)

    def test_valid_xpm_transparent_pixel(self):
        img = parse_xpm(VALID_XPM_LINES, Image)
        # (2, 0) should be transparent
        _, _, _, a = img.getpixel((2, 0))
        self.assertEqual(a, 0)

    def test_empty_input_raises(self):
        with self.assertRaises(ValueError) as ctx:
            parse_xpm([], Image)
        self.assertIn("No valid XPM data", str(ctx.exception))

    def test_short_header_raises(self):
        with self.assertRaises(ValueError) as ctx:
            parse_xpm(['"3 2 3"'], Image)
        self.assertIn("need width, height, num_colors, chars_per_pixel", str(ctx.exception))

    def test_missing_color_marker_raises(self):
        bad_xpm = ['"3 1 2 1"', '"! #000000"', '". none"', '"!.!"']
        with self.assertRaises(ValueError) as ctx:
            parse_xpm(bad_xpm, Image)
        self.assertIn("missing ' c ' marker", str(ctx.exception))

    def test_insufficient_color_lines_raises(self):
        # Header says 3 colors but only 1 color line follows
        bad_xpm = ['"3 1 3 1"', '"! c #000000"', '"!!!"']
        with self.assertRaises(ValueError) as ctx:
            parse_xpm(bad_xpm, Image)
        self.assertIn("declares 3 colors but only", str(ctx.exception))

    def test_2_chars_per_pixel(self):
        xpm = [
            '"2 1 2 2"',
            '"!! c #000000"',
            '".. c none"',
            '"!!.."',
        ]
        img = parse_xpm(xpm, Image)
        self.assertEqual(img.size, (2, 1))
        r, g, b, a = img.getpixel((0, 0))
        self.assertEqual((r, g, b, a), (0, 0, 0, 255))
        _, _, _, a = img.getpixel((1, 0))
        self.assertEqual(a, 0)


# ---------------------------------------------------------------------------
# validate_cmd tests (via subprocess)
# ---------------------------------------------------------------------------

class TestValidateCmd(unittest.TestCase):
    """Tests for the validate subcommand."""

    def test_valid_xpm_passes(self):
        result = _run_script("validate", stdin_text=VALID_XPM)
        self.assertEqual(result.returncode, 0)
        self.assertIn("OK:", result.stdout)
        self.assertIn("3x2", result.stdout)

    def test_empty_input_fails(self):
        result = _run_script("validate", stdin_text="no quotes here")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No valid XPM data", result.stderr)

    def test_bad_header_fails(self):
        result = _run_script("validate", stdin_text='"3 2 3"\n"! c #000000"\n"!o."')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid XPM header", result.stderr)

    def test_wrong_row_width_detected(self):
        bad = '''"3 2 3 1"
"! c #000000"
"o c #FFFFFF"
". c none"
"!o"
".o!"'''
        result = _run_script("validate", stdin_text=bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected width", result.stderr)

    def test_wrong_row_count_detected(self):
        bad = '''"3 2 3 1"
"! c #000000"
"o c #FFFFFF"
". c none"
"!o."'''
        result = _run_script("validate", stdin_text=bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pixel rows", result.stderr)

    def test_undefined_char_detected(self):
        bad = '''"3 1 2 1"
"! c #000000"
". c none"
"!X."'''
        result = _run_script("validate", stdin_text=bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("undefined char", result.stderr)

    def test_missing_color_marker_detected(self):
        bad = '''"3 1 2 1"
"! #000000"
". c none"
"!.!"'''
        result = _run_script("validate", stdin_text=bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing ' c ' marker", result.stderr)


# ---------------------------------------------------------------------------
# generate_cmd tests (via subprocess)
# ---------------------------------------------------------------------------

class TestGenerateCmd(unittest.TestCase):
    """Tests for the generate subcommand."""

    SIMPLE_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3 3"><rect width="3" height="3" fill="black"/></svg>'

    def test_generates_correct_dimensions(self):
        result = _run_script("generate", "--width", "3", "--height", "3", stdin_text=self.SIMPLE_SVG)
        self.assertEqual(result.returncode, 0)
        lines = [l for l in result.stdout.strip().splitlines() if l.startswith('"')]
        # Header + 3 colors + 3 pixel rows = 7 lines
        self.assertEqual(len(lines), 7)

    def test_header_format(self):
        result = _run_script("generate", "--width", "5", "--height", "5", stdin_text=self.SIMPLE_SVG)
        first_line = result.stdout.strip().splitlines()[0]
        self.assertEqual(first_line, '"5 5 3 1"')

    def test_all_black_svg_produces_bangs(self):
        result = _run_script("generate", "--width", "3", "--height", "3", stdin_text=self.SIMPLE_SVG)
        pixel_rows = result.stdout.strip().splitlines()[4:]  # Skip header + 3 color defs
        for row in pixel_rows:
            content = row.strip('"')
            # All pixels should be ! (black) or very close
            for ch in content:
                self.assertIn(ch, "!o", f"Unexpected char {ch!r} in all-black SVG output")

    def test_all_transparent_svg_produces_dots(self):
        transparent_svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3 3"></svg>'
        result = _run_script("generate", "--width", "3", "--height", "3", stdin_text=transparent_svg)
        pixel_rows = result.stdout.strip().splitlines()[4:]
        for row in pixel_rows:
            content = row.strip('"')
            for ch in content:
                self.assertEqual(ch, ".", f"Expected transparent but got {ch!r}")

    def test_output_is_valid_xpm(self):
        """Generate output should pass its own validator."""
        gen_result = _run_script("generate", "--width", "5", "--height", "5", stdin_text=self.SIMPLE_SVG)
        self.assertEqual(gen_result.returncode, 0)
        val_result = _run_script("validate", stdin_text=gen_result.stdout)
        self.assertEqual(val_result.returncode, 0, f"Validation failed: {val_result.stderr}")


# ---------------------------------------------------------------------------
# render_cmd tests
# ---------------------------------------------------------------------------

class TestRenderCmd(unittest.TestCase):
    """Tests for the render subcommand."""

    def test_render_creates_png(self):
        result = _run_script("render", "--scale", "1", stdin_text=VALID_XPM)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Rendered to", result.stdout)
        # Extract the path from output
        out_path = result.stdout.strip().split("Rendered to ")[-1]
        self.assertTrue(os.path.exists(out_path), f"PNG not found at {out_path}")
        # Verify it's a valid PNG
        img = Image.open(out_path)
        self.assertEqual(img.size, (3, 2))
        os.unlink(out_path)

    def test_render_with_scale(self):
        result = _run_script("render", "--scale", "4", stdin_text=VALID_XPM)
        self.assertEqual(result.returncode, 0)
        out_path = result.stdout.strip().split("Rendered to ")[-1]
        img = Image.open(out_path)
        self.assertEqual(img.size, (12, 8))  # 3*4, 2*4
        os.unlink(out_path)


if __name__ == "__main__":
    unittest.main()
