# typ-glyph

A Claude Code plugin for designing, previewing, generating, and iterating on Garmin TYP file icon glyphs.

## Prerequisites

- Python 3.8+ on PATH (as `python3` or `python`).
- The system `cairo` library, required by `cairosvg` — `pip` cannot install this:
  - macOS: `brew install cairo pango`
  - Debian/Ubuntu: `apt install libcairo2-dev`
  - Windows: install the GTK runtime (e.g., `choco install gtk-runtime`)

The Python packages (`Pillow`, `cairosvg`) install automatically on first run — see the Dependency Check in [`commands/typ-glyph.md`](commands/typ-glyph.md). No manual setup needed.

<details>
<summary>Manual pre-install (optional)</summary>

The commands below require a POSIX shell (bash, zsh, or Git Bash on Windows). Pick **one** option:

```bash
# Option A — uv (bypasses PEP 668 on managed Pythons):
uv pip install --system Pillow cairosvg

# Option B — disposable venv:
VENV_DIR="${TMPDIR:-/tmp}/typ-glyph-venv-$(id -u)"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install Pillow cairosvg     # Unix / macOS
"$VENV_DIR/Scripts/pip.exe" install Pillow cairosvg   # Windows (Git Bash)
```
</details>

## Usage

```bash
# Preview an existing glyph
/typ-glyph render path/to/file.typ.txt 0x6404

# Generate a new Garmin XPM grid from a prompt
/typ-glyph generate a black 15x15 tent with a white border
```
