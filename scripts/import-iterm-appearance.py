#!/usr/bin/env python3
"""Copy the default iTerm2 profile's appearance to amux's optional local config."""
import json
import os
from pathlib import Path
import plistlib
import re

prefs = Path.home() / 'Library/Preferences/com.googlecode.iterm2.plist'
data = plistlib.loads(prefs.read_bytes())
profiles = data.get('New Bookmarks', [])
profile = next((p for p in profiles if p.get('Guid') == data.get('Default Bookmark Guid')), profiles[0] if profiles else {})
if not profile:
    raise SystemExit('No iTerm2 profiles found')
font = re.fullmatch(r'(.+) ([0-9.]+)', profile.get('Normal Font', 'Monaco 12'))
def palette(mode):
    def color(key):
        value = profile.get(key + ' (' + mode + ')') if profile.get('Use Separate Colors for Light and Dark Mode') else None
        value = value or profile[key]
        return [value.get(c + ' Component', 0) for c in ('Red', 'Green', 'Blue')]
    return {'foreground': color('Foreground Color'), 'background': color('Background Color'),
            'cursor': color('Cursor Color'), 'ansi': [color('Ansi ' + str(i) + ' Color') for i in range(16)]}
result = {'fontName': font[1], 'fontSize': float(font[2]),
          'horizontalSpacing': profile.get('Horizontal Spacing', 1),
          'verticalSpacing': profile.get('Vertical Spacing', 1),
          'antialias': profile.get('ASCII Anti Aliased', True),
          'brightBold': profile.get('Use Bright Bold', True),
          'light': palette('Light'), 'dark': palette('Dark')}
root = Path(os.environ.get('AMUX_HOME', str(Path.home() / '.amux')))
root.mkdir(parents=True, exist_ok=True)
path = root / 'appearance.json'
if path.exists():
    path.with_suffix('.json.bak').write_bytes(path.read_bytes())
path.write_text(json.dumps(result, indent=2) + '\n')
print(f"Imported {profile.get('Name')}: {font[1]} {font[2]} → {path}")
