#!/usr/bin/env python3
import sys
import argparse
import subprocess
import tempfile
import os
import io

def ensure_dependencies():
    try:
        from PIL import Image
        import cairosvg
    except ImportError:
        print("Missing dependencies. Install via: pip install --break-system-packages Pillow cairosvg\n"
              "Or use a venv: python3 -m venv /tmp/typ-venv && /tmp/typ-venv/bin/pip install Pillow cairosvg",
              file=sys.stderr)
        sys.exit(1)
    return Image, cairosvg

def parse_xpm(xpm_lines, Image):
    """Parse XPM lines into a PIL Image. Caller must pass the PIL Image module."""
    colors = {}
    
    # Clean up quotes and commas
    lines = [line.strip().strip(',').strip('"') for line in xpm_lines if '"' in line]
    
    if not lines:
        raise ValueError("No valid XPM data found")
        
    header_parts = lines[0].split()
    if len(header_parts) < 4:
        raise ValueError("Invalid XPM header (need width, height, num_colors, chars_per_pixel)")
    
    width = int(header_parts[0])
    height = int(header_parts[1])
    num_colors = int(header_parts[2])
    chars_per_pixel = int(header_parts[3])
    
    if len(lines) < 1 + num_colors:
        raise ValueError(f"Header declares {num_colors} colors but only {len(lines) - 1} lines follow")
    
    for i in range(1, num_colors + 1):
        color_def = lines[i]
        # "char c color" -> '! c #000000'
        char = color_def[:chars_per_pixel]
        c_index = color_def.find(' c ')
        if c_index == -1:
            raise ValueError(f"Malformed XPM color line (missing ' c ' marker): {color_def!r}")
        color_val = color_def[c_index+3:].strip()
        if color_val.lower() == 'none':
            colors[char] = (0, 0, 0, 0)
        else:
            if color_val.startswith('#'):
                # Extract RGB
                color_val = color_val.lstrip('#')
                if len(color_val) == 6:
                    colors[char] = tuple(int(color_val[j:j+2], 16) for j in (0, 2, 4)) + (255,)
                else:
                    colors[char] = (0, 0, 0, 255)  # Fallback
            else:
                colors[char] = (0, 0, 0, 255)  # Fallback
    # Parse pixels
    img = Image.new('RGBA', (width, height))
    pixels_obj = img.load()
    
    for y, line in enumerate(lines[num_colors + 1:]):
        if y >= height:
            break
        for x in range(width):
            if x*chars_per_pixel < len(line):
                char = line[x*chars_per_pixel:(x+1)*chars_per_pixel]
                if char in colors:
                    pixels_obj[x, y] = colors[char]
                    
    return img

def render_cmd(args):
    Image, _ = ensure_dependencies()
    text = sys.stdin.read()
    img = parse_xpm(text.splitlines(), Image)
    # Scale up
    scale = args.scale
    if scale > 1:
        img = img.resize((img.width * scale, img.height * scale), Image.Resampling.NEAREST)
        
    out = tempfile.NamedTemporaryFile(suffix=".png", prefix="typ_preview_", delete=False)
    out_path = out.name
    out.close()
    img.save(out_path)
    print(f"Rendered to {out_path}")
    open_file(out_path)

def generate_cmd(args):
    Image, cairosvg = ensure_dependencies()
    svg_data = sys.stdin.read()
    
    # Rasterize SVG to PNG bytes
    png_data = cairosvg.svg2png(bytestring=svg_data, output_width=args.width, output_height=args.height)
    
    img = Image.open(io.BytesIO(png_data)).convert("RGBA")
    
    # Quantize to Garmin palette: ! (black), o (white), . (transparent/none)
    # Background must be none if alpha is 0
    xpm_lines = []
    xpm_lines.append(f'"{args.width} {args.height} 3 1"')
    xpm_lines.append('"! c #000000"')
    xpm_lines.append('"o c #FFFFFF"')
    xpm_lines.append('". c none"')
    
    pixels = img.load()
    for y in range(img.height):
        row = ""
        for x in range(img.width):
            r, g, b, a = pixels[x, y]
            if a < 128:
                row += "."
            else:
                brightness = (r + g + b) / 3
                if brightness < 128:
                    row += "!"
                else:
                    row += "o"
        xpm_lines.append(f'"{row}"')
        
    print("\n".join(xpm_lines))

def open_file(path):
    if sys.platform == "darwin":
        subprocess.run(["open", path])
    elif sys.platform == "win32":
        subprocess.run(["cmd", "/c", "start", "", path])
    else:
        subprocess.run(["xdg-open", path])

def validate_cmd(args):
    """Validate XPM data read from stdin."""
    text = sys.stdin.read()
    lines = [line.strip().strip(',').strip('"') for line in text.splitlines() if '"' in line]

    if not lines:
        print("ERROR: No valid XPM data found.", file=sys.stderr)
        sys.exit(1)

    header_parts = lines[0].split()
    if len(header_parts) < 4:
        print(f"ERROR: Invalid XPM header: {lines[0]!r}", file=sys.stderr)
        sys.exit(1)

    width, height, num_colors, cpp = (int(v) for v in header_parts[:4])
    errors = []

    # Validate color definitions
    if len(lines) < 1 + num_colors:
        errors.append(f"Header declares {num_colors} colors but only {len(lines) - 1} lines follow.")
    else:
        defined_chars = set()
        for i in range(1, num_colors + 1):
            color_def = lines[i]
            if ' c ' not in color_def:
                errors.append(f"Color line {i} missing ' c ' marker: {color_def!r}")
            else:
                defined_chars.add(color_def[:cpp])

        # Validate pixel rows
        pixel_lines = lines[1 + num_colors:]
        if len(pixel_lines) != height:
            errors.append(f"Declared height={height} but found {len(pixel_lines)} pixel rows.")

        for row_idx, row in enumerate(pixel_lines):
            if len(row) != width * cpp:
                errors.append(f"Row {row_idx}: expected width {width * cpp} chars, got {len(row)}.")
            if defined_chars:
                for x in range(0, len(row), cpp):
                    ch = row[x:x + cpp]
                    if ch not in defined_chars:
                        errors.append(f"Row {row_idx}, col {x // cpp}: undefined char {ch!r}.")
                        break  # One error per row is enough

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"OK: {width}x{height}, {num_colors} colors, {cpp} char(s)/pixel — all valid.")


def main():
    parser = argparse.ArgumentParser(description="TYP Glyph Tools")
    subparsers = parser.add_subparsers(dest="command")
    
    render_parser = subparsers.add_parser("render")
    render_parser.add_argument("--scale", type=int, default=10)
    
    gen_parser = subparsers.add_parser("generate")
    gen_parser.add_argument("--width", type=int, required=True)
    gen_parser.add_argument("--height", type=int, required=True)

    subparsers.add_parser("validate")
    
    args = parser.parse_args()
    
    if args.command == "render":
        render_cmd(args)
    elif args.command == "generate":
        generate_cmd(args)
    elif args.command == "validate":
        validate_cmd(args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
