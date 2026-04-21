# typ-glyph

A Claude Code plugin for designing, previewing, generating, and iterating on Garmin TYP file icon glyphs.

## Prerequisites
The plugin natively executes a Python utility for visualization and rasterization and depends on `Pillow` and `cairosvg`. The plugin will install these automatically on first run (see the Dependency Check in `commands/typ-glyph.md`) — you do not need to install them ahead of time.

If you prefer to pre-install, pick **one** of:
```bash
# Option A — uv (bypasses PEP 668 on managed Pythons):
uv pip install --system Pillow cairosvg

# Option B — disposable venv (works everywhere):
python3 -m venv "${TMPDIR:-/tmp}/typ-glyph-venv-$(id -u)"
# On Unix/macOS:
"${TMPDIR:-/tmp}/typ-glyph-venv-$(id -u)"/bin/pip install Pillow cairosvg
# On Windows (Git Bash): replace bin/pip with Scripts/pip.exe
```

## Usage

```bash
# Preview an existing glyph
/typ-glyph render path/to/file.typ.txt 0x6404

# Generate a new Garmin XPM grid from a prompt
/typ-glyph generate a black 15x15 tent with a white border
```
