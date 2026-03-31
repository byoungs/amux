#!/usr/bin/env python3
"""Add polished overlays to the raw demo GIF.

Style: Menlo (matches terminal), dark pills with subtle border,
clean spacing. Narrative in upper quarter, key badges centered.
"""

import sys
from PIL import Image, ImageDraw, ImageFont

INPUT = sys.argv[1] if len(sys.argv) > 1 else "demo/demo-raw.gif"
OUTPUT = sys.argv[2] if len(sys.argv) > 2 else "demo/demo.gif"
FPS = 25

# Fonts — Menlo to match the terminal and render ⌘ correctly
MENLO = "/System/Library/Fonts/Menlo.ttc"
try:
    FONT_NARR = ImageFont.truetype(MENLO, 20, index=1)     # Bold
    FONT_KEY = ImageFont.truetype(MENLO, 36, index=1)       # Bold
    FONT_TAGLINE = ImageFont.truetype(MENLO, 22, index=1)   # Bold
except Exception:
    FONT_NARR = ImageFont.load_default()
    FONT_KEY = ImageFont.load_default()
    FONT_TAGLINE = ImageFont.load_default()

# Colors
WHITE = (255, 255, 255)
TEXT_LIGHT = (240, 240, 245)        # near-white for narrative
TEXT_BRIGHT = (255, 255, 255)       # pure white for key badges
PILL_BG = (45, 45, 55, 255)        # dark with subtle warmth
PILL_BORDER = (90, 90, 100)        # subtle outline
TAGLINE_BG = (45, 45, 55, 255)

# Overlay definitions: (start, end, type, text)
# Visible timestamps (VHS attach takes ~2s, hidden)
OVERLAYS = [
    # Timestamps matched to actual raw recording transitions:
    # 0-5: grid | 6-12: plan zoomed | 13-17: grid | 17: jump pane 3
    # 18-20: grid | 22-28: review zoomed | 30: split | 32+: grid end

    # Beat 1: Grid — four agents, two need you (grid 0-5)
    (0, 3.5, "narr", "Four agents. Two need you. amux shows you which."),
    (4, 5.5, "key", "⌘ +"),

    # Beat 2: Zoomed into plan — go deep (zoomed 6-12)
    (6.5, 8, "narr", "Go deep. Full screen, one agent."),
    # Badge moment — the key beat
    (8.5, 11.5, "narr",
     "The badge tells you another agent is waiting. No popup. No interruption. You're focused."),
    (11.5, 12.5, "key", "⌘ -"),

    # Beat 3: Back to grid — quick approve (grid 13-17)
    (13, 15.5, "narr", "Permission prompt. Handle it without breaking flow."),
    (15.5, 17, "key", "⌘ 3"),

    # Beat 4: Navigate to code review (grid 18-21)
    (18, 20, "narr", "Code review needs a closer look."),
    (20, 21.5, "key", "⌘ 2"),

    # Beat 5: Zoomed into code review (zoomed 22-28)
    (24, 26.5, "narr", "Side-by-side to respond."),
    (27, 28.5, "key", "⌘ L"),

    # Beat 6: Split view sits (split ~29-31, silence)

    # End card (grid 32+)
    (32, 39, "tagline",
     "amux — manage your attention, not your terminals."),
]


def draw_pill(draw, cx, cy, text, font, text_color, bg_color,
              pad_x=20, pad_y=10, border_color=None):
    """Draw text in a rounded pill with optional border."""
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x1 = cx - tw // 2 - pad_x
    y1 = cy - th // 2 - pad_y
    x2 = cx + tw // 2 + pad_x
    y2 = cy + th // 2 + pad_y
    radius = (y2 - y1) // 2  # fully rounded ends
    draw.rounded_rectangle([x1, y1, x2, y2], radius=radius, fill=bg_color)
    if border_color:
        draw.rounded_rectangle([x1, y1, x2, y2], radius=radius,
                               outline=border_color, width=1)
    draw.text((cx - tw // 2, cy - th // 2), text, font=font, fill=text_color)


def draw_dim(draw, img_w, img_h):
    """Subtle screen dim so overlays pop against terminal content."""
    draw.rectangle([0, 0, img_w, img_h], fill=(0, 0, 0, 90))


def draw_narr(draw, img_w, img_h, text):
    """Narrative text — upper quarter, bold, bordered pill."""
    draw_dim(draw, img_w, img_h)
    draw_pill(draw, img_w // 2, img_h // 4, text, FONT_NARR,
              TEXT_LIGHT, PILL_BG, pad_x=20, pad_y=10, border_color=PILL_BORDER)


def draw_key(draw, img_w, img_h, text):
    """Key badge — centered, bold, bordered pill."""
    draw_dim(draw, img_w, img_h)
    draw_pill(draw, img_w // 2, img_h // 2, text, FONT_KEY,
              TEXT_BRIGHT, PILL_BG, pad_x=32, pad_y=16, border_color=PILL_BORDER)


def draw_tagline(draw, img_w, img_h, text):
    """End card tagline — centered with darkened background."""
    draw.rectangle([0, 0, img_w, img_h], fill=(10, 10, 15, 160))
    draw_pill(draw, img_w // 2, img_h // 2, text, FONT_TAGLINE,
              TEXT_LIGHT, TAGLINE_BG, pad_x=24, pad_y=12, border_color=PILL_BORDER)


def main():
    print(f"Loading {INPUT}...")
    gif = Image.open(INPUT)

    frames = []
    durations = []
    frame_idx = 0

    try:
        while True:
            frame = gif.convert("RGBA")
            img_w, img_h = frame.size
            duration = gif.info.get("duration", 40)
            durations.append(duration)

            t = frame_idx / FPS

            overlay = Image.new("RGBA", (img_w, img_h), (0, 0, 0, 0))
            draw = ImageDraw.Draw(overlay)

            for start, end, kind, text in OVERLAYS:
                if start <= t < end:
                    if kind == "narr":
                        draw_narr(draw, img_w, img_h, text)
                    elif kind == "key":
                        draw_key(draw, img_w, img_h, text)
                    elif kind == "tagline":
                        draw_tagline(draw, img_w, img_h, text)

            frame = Image.alpha_composite(frame, overlay)
            # Flatten to RGB (onto black bg) before palette conversion
            # to preserve overlay colors against dark terminal
            rgb = Image.new("RGB", frame.size, (0, 0, 0))
            rgb.paste(frame, mask=frame.split()[3])
            frames.append(rgb.convert("P", palette=Image.ADAPTIVE, colors=256))

            frame_idx += 1
            gif.seek(gif.tell() + 1)
    except EOFError:
        pass

    import os
    import subprocess
    import tempfile

    print(f"Processed {len(frames)} frames.")

    # Save as PNG frames, then use ffmpeg to assemble a proper GIF
    # (Pillow's GIF writer has palette issues with overlays)
    with tempfile.TemporaryDirectory() as tmpdir:
        print("Saving PNG frames...")
        for i, (frame, dur) in enumerate(zip(frames, durations)):
            # Convert P back to RGB for PNG
            frame.convert("RGB").save(os.path.join(tmpdir, f"frame_{i:05d}.png"))

        # Get the frame rate from durations (they should all be the same)
        avg_dur = sum(durations) / len(durations)
        fps = 1000.0 / avg_dur if avg_dur > 0 else 25

        print(f"Assembling GIF with ffmpeg (fps={fps:.1f})...")
        subprocess.run([
            "ffmpeg", "-y",
            "-framerate", str(fps),
            "-i", os.path.join(tmpdir, "frame_%05d.png"),
            "-vf", "fps=15,scale=900:-1,split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5",
            "-loop", "0",
            OUTPUT,
        ], capture_output=True)

    size = os.path.getsize(OUTPUT)
    print(f"Done! {OUTPUT} ({size / 1024 / 1024:.1f}MB)")


if __name__ == "__main__":
    main()
