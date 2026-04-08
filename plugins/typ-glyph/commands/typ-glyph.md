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
4. **Dependency Check:** Run `python3 -c "import PIL, cairosvg"`. If it fails, use the Bash tool to `pip install Pillow cairosvg` so the script operates correctly.

## The Sub-Commands

### Render & Compare
If the user provides `render` or `compare` paths/glyphs:
1. `Read` the provided `typ.txt` file(s) and locate the XPM blocks for the given identifiers `[_point]`, `[_line]`, or `[_area]`.
2. Extract the literal `DayXpm` or `Xpm` line array (e.g., everything inside the quotes).
3. Pipe the XPM text into `python3 <script_path>/typ-glyph-tools.py render --scale 10`.
4. The script will render them to a scaled PNG and open it natively for the user. Explain to the user what you displayed.

### Generate
If the user asks to generate a new glyph:
1. Using your spatial reasoning abilities, design the icon the user asked for using **SVG path logic**. 
2. Determine the requested target dimensions (e.g. 15x15).
3. Send the generated raw SVG string via stdin into `python3 <script_path>/typ-glyph-tools.py generate --width W --height H`.
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
