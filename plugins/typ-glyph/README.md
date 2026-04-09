# typ-glyph

A Claude Code plugin for designing, previewing, generating, and iterating on Garmin TYP file icon glyphs.

## Prerequisites
The plugin natively executes a Python utility for visualization and rasterization.
```bash
# Preferred:
uv pip install --system Pillow cairosvg

# Fallback:
python3 -m venv /tmp/typ-glyph-venv
/tmp/typ-glyph-venv/bin/pip install Pillow cairosvg
```

## Usage

```bash
# Preview an existing glyph
/typ-glyph render path/to/file.typ.txt 0x6404

# Generate a new Garmin XPM grid from a prompt
/typ-glyph generate a black 15x15 tent with a white border
```
