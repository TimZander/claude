#!/usr/bin/env python3
import sys
import argparse
import tempfile
import os
import io
import re

def ensure_dependencies():
    try:
        from PIL import Image
        import cairosvg
    except ImportError:
        print("Missing dependencies. The agent must run: pip install Pillow cairosvg", file=sys.stderr)
        sys.exit(1)
    return Image, cairosvg

def parse_xpm(xpm_lines):
    # Extremely naive XPM parser for TYP
    # Find dimensions
    header = None
    colors = {}
    pixels = []
    
    # Clean up quotes and commas
    lines = [line.strip().strip(',').strip('"') for line in xpm_lines if '"' in line]
    
    if not lines:
        raise ValueError("No valid XPM data found")
        
    header_parts = lines[0].split()
    if len(header_parts) < 3:
        raise ValueError("Invalid XPM header")
    
    width = int(header_parts[0])
    height = int(header_parts[1])
    num_colors = int(header_parts[2])
    chars_per_pixel = int(header_parts[3])
    
    for i in range(1, num_colors + 1):
        color_def = lines[i]
        # "char c color" -> '! c #000000'
        char = color_def[:chars_per_pixel]
        c_index = color_def.find(' c ')
        color_val = color_def[c_index+3:].strip()
        if color_val.lower() == 'none':
            colors[char] = (0, 0, 0, 0)
        else:
            if color_val.startswith('#'):
                # Extract RGB
                color_val = color_val.lstrip('#')
                if len(color_val) == 6:
                    colors[char] = tuple(int(color_val[i:i+2], 16) for i in (0, 2, 4)) + (255,)
                else:
                    colors[char] = (0, 0, 0, 255) # Fallback
            else:
                 colors[char] = (0, 0, 0, 255) # Fallback
                 
    # Parse pixels
    Image, _ = ensure_dependencies()
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
    img = parse_xpm(text.splitlines())
    # Scale up
    scale = args.scale
    if scale > 1:
        img = img.resize((img.width * scale, img.height * scale), Image.Resampling.NEAREST)
        
    out_path = "/tmp/typ_preview.png"
    img.save(out_path)
    print(f"Rendered to {out_path}")
    open_file(out_path)

def generate_cmd(args):
    Image, cairosvg = ensure_dependencies()
    svg_data = sys.stdin.read()
    
    # Rasterize SVG to PNG bytes
    png_data = cairosvg.svg2png(bytestring=svg_data, output_width=args.width, output_height=args.height)
    
    img = Image.open(io.BytesIO(png_data)).convert("RGBA")
    img = img.resize((args.width, args.height), Image.Resampling.BICUBIC)
    
    # Quantize to Garmin pallet: ! (black), o (white), . (transparent/none)
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
        os.system(f"open {path}")
    elif sys.platform == "win32":
        os.system(f"start {path}")
    else:
        os.system(f"xdg-open {path}")

def main():
    parser = argparse.ArgumentParser(description="TYP Glyph Tools")
    subparsers = parser.add_subparsers(dest="command")
    
    render_parser = subparsers.add_parser("render")
    render_parser.add_argument("--scale", type=int, default=10)
    
    gen_parser = subparsers.add_parser("generate")
    gen_parser.add_argument("--width", type=int, required=True)
    gen_parser.add_argument("--height", type=int, required=True)
    
    args = parser.parse_args()
    
    if args.command == "render":
        render_cmd(args)
    elif args.command == "generate":
        generate_cmd(args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
