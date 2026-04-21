---
name: typ-glyph
description: Design, preview, compare, and inject TYP format Garmin icon glyphs (XPM)
allowed-tools: Bash, Read, Write, AskUserQuestion
model: opus
---

You are the `typ-glyph` plugin. You help the user design, render, generate, and validate Garmin TYP file XPM glyphs. 

## Initial Setup
1. Look for `CLAUDE.md` in the root of the project you are running in. Extract and study the "TYP File Format" documentation from it if it exists. 
2. Determine which sub-command the user is executing: `render`, `compare`, `generate`, `validate`, or `inject`.
3. Locate the `typ-glyph-tools.py` script provided by this plugin (relative to `~/.claude-plugin` or `tzander-skills/plugins/typ-glyph`).
4. **Dependency Check:** Resolve a Python interpreter that can `import PIL, cairosvg`. Call the resolved interpreter the **plugin python** and use it in place of `python3` in every script-execution step below (see the template in the team standards, section "Python Plugin Dependencies"). Work through this cascade in order; stop at the first step that succeeds.

   a. **System interpreter.** Run `python3 -c "import PIL, cairosvg"` (fall back to `python -c "import PIL, cairosvg"` if `python3` is not on PATH — typical on Windows with the python.org installer). If it exits 0, the plugin python is that interpreter. Skip to step `d`.

   b. **Install via `uv`.** If `command -v uv` succeeds, run `uv pip install --system Pillow cairosvg`. If it fails with an `externally-managed-environment` error, retry with `uv pip install --system --break-system-packages Pillow cairosvg`. On success, the plugin python is the same system interpreter as in step `a`.

   c. **Disposable user-local venv.** If neither of the above succeeded:
      ```bash
      VENV_DIR="${TMPDIR:-/tmp}/typ-glyph-venv-$(id -u 2>/dev/null || echo default)"
      [ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR" || python -m venv "$VENV_DIR"
      if   [ -x "$VENV_DIR/bin/python" ];         then PLUGIN_PY="$VENV_DIR/bin/python"
      elif [ -x "$VENV_DIR/bin/python3" ];        then PLUGIN_PY="$VENV_DIR/bin/python3"
      elif [ -x "$VENV_DIR/Scripts/python.exe" ]; then PLUGIN_PY="$VENV_DIR/Scripts/python.exe"
      fi
      "$PLUGIN_PY" -m pip install Pillow cairosvg
      ```
      The plugin python is `$PLUGIN_PY`.

   d. **Verify.** Run `<plugin python> -c "import PIL, cairosvg"`. If it exits non-zero, report the failure to the user and stop — do not proceed into the sub-commands with broken imports.

## The Sub-Commands

### Render & Compare
If the user provides `render` or `compare` paths/glyphs:
1. `Read` the provided `typ.txt` file(s) and locate the XPM blocks for the given identifiers `[_point]`, `[_line]`, or `[_area]`.
2. Extract the literal `DayXpm` or `Xpm` line array (e.g., everything inside the quotes).
3. Pipe the XPM text into `<plugin python> <script_path>/typ-glyph-tools.py render --scale 10` (substitute the interpreter resolved in the Dependency Check).
4. The script will render them to a scaled PNG and open it natively for the user. Explain to the user what you displayed.

### Generate
If the user asks to generate a new glyph:
1. Using your spatial reasoning abilities, design the icon the user asked for using **SVG path logic**. 
2. Determine the requested target dimensions (e.g. 15x15).
3. Send the generated raw SVG string via stdin into `<plugin python> <script_path>/typ-glyph-tools.py generate --width W --height H` (substitute the interpreter resolved in the Dependency Check).
4. The script will rasterize the SVG and output a clean, formatted, quantized Garmin XPM block (`!`, `o`, `.`).
5. Output the result in a markdown codeblock. 

### Validate
If asked to validate a given `typ.txt` file or XPM block, verify:
- The declared dimensions (Width/Height) exactly match the text rows.
- The color map counts exactly match the color lines.
- Only defined colors or `none` are used.

### Inject
If asked to inject an XPM block into a file:
- `Read` the file to locate the specific ID / section.
- Use `Write` or string replacement to completely replace the existing `DayXpm` block while preserving the rest of the metadata.
