# Shared names

Use amux normally: Cmd-N creates a normal terminal; scrolling, zoom, spaces,
move/park, and recovery use the existing amux implementation.

Cmd-R (Edit → Rename Pane / Session) names the active pane. When the pane is
connected to a remote session through a naming provider (see below), the name
is shared with that provider. Empty input restores the provider's original
session name (or the automatic local label). Local tiles use the Git project and
branch, omitting `main`/`master`, or the directory name outside a Git repository.
Manual local names remain attached to the tile across amux session recovery.

Connected panes show `session name — location`, for example
`build-agent — staging-east`. The location suffix is display-only: Cmd-R
edits the session name, and disconnecting restores the local pane's label.
The combined title stays within 80 characters, shortening long parts with an
ellipsis while keeping room for both the session and its location.
Names are available before the first remote identity receipt, including new
sessions. Connecting/reconnecting text belongs to the provider's terminal output
while the terminal is unavailable; it is never used as a title or inferred from
the naming cache. Attaching the remote terminal replaces that connection output.

Cmd-Shift-R (Edit → Rename Space) names the current space independently of its
panes. New spaces keep the name entered when creating them; pane names and
directory changes cannot replace it. Empty input restores the space's original
name. In either rename prompt, typing replaces the selected name; Ctrl-U clears
it and Esc cancels.
If a new connection's session identity is not cached yet, saving a rename
refreshes that connection first. Failed saves keep the typed name in the prompt;
Enter retries and Esc cancels.

Names change only when you explicitly rename them. Chat titles and prompt text
are never imported. Renaming never changes a routing name or agent transcript.

A provider can bind an ordinary connection to the containing amux pane with:

```
amux-cli names bind PROVIDER OPAQUE_SELECTOR OWNER_PID
amux-cli names unbind OWNER_PID
```

Bindings expire when the owning process exits, restoring the local name.
Providers are optional executables in `~/.amux/providers.json`:

```json
{"providers":[{"id":"provider","command":["/absolute/path/to/provider","request"]}]}
```

Each subprocess reads one JSON request on stdin and returns one JSON response:

```json
{"version":1,"id":"request-uuid","method":"snapshot","params":{}}
```

The response echoes version/id with `result` or `error: {code,message}`.
Methods: `capabilities`, `snapshot`, `refresh`, `rename`. Snapshot sessions carry
`ref` (immutable), `selector` (initial connection hint), `display_name`,
`override`, `revision`, and `state`. Optional `location_name` supplies a short
location label for the pane's suffix; `location` is the fallback for providers
without it. Local panes and providers without either keep plain titles.
An optional `bindings` list supplies `selector`, `display_name`, `location`, and
`location_name` before an immutable session `ref` is known. These are display
hints only; they cannot enable rename or replace an already resolved identity.
After resolving a selector,
amux holds the immutable ref and never follows a replacement with the same name.
Rename sends `{ref, expected_revision, override}`; null resets to the original name.
An on-demand `refresh` may include `selector` to resolve a pending connection
outside the provider's routine background refresh scope. The returned snapshot
must still establish a unique immutable `ref` before a rename can be sent.
A stale revision is rejected. Providers own their metadata and failure handling.
No provider can launch or stop a terminal through this interface.

Cached names update every five seconds; active provider metadata refreshes every
minute. Failed refreshes retain cached labels. The companion only changes title
options, so it leaves copy mode, scroll position, and terminal processes intact.

# Appearance

`~/.amux/appearance.json` optionally sets font, size, spacing, antialiasing, and
light/dark terminal palettes. Restart amux to apply changes. The helper
`scripts/import-iterm-appearance.py` copies your default iTerm2 profile into this
file, backing up an existing file. Rendering differs between the two apps;
font/contrast can be adjusted independently afterward.

The renderer rounds character advances before applying spacing and uses an
integer baseline, following iTerm2 3.7.3's [font sizing](https://github.com/gnachman/iTerm2/blob/v3.7.3/sources/Fonts/FontSizeEstimator.m)
and [baseline placement](https://github.com/gnachman/iTerm2/blob/v3.7.3/sources/Fonts/PTYFontInfo.m).
For Monaco 12 at 1× spacing this gives 7×17-point cells and a baseline 13 points
below each row's top. This matches geometry; the apps still have different renderers.

Display names are limited to 80 characters. Longer manual or cached names
are truncated automatically rather than rejected.

# Terminal interaction

Drag selects visible text in the containing pane, including mouse-aware TUIs
and SSH sessions. Double-click copies a word; triple-click copies a line.
Selection release sends the text through a local socket to amux, which writes
the macOS clipboard directly; Cmd-C also finishes an active selection. The
handoff preserves whitespace and supports selections up to 8 MiB. When amux
is closed, the helper falls back to `pbcopy` for surviving tmux clients.
With no selection, Cmd-C leaves the clipboard
alone. Remote applications can write the clipboard using OSC 52 through tmux.
Cmd-V, Edit → Paste and the context menu share the same ordered input path;
pasting exits local tmux copy mode before delivering the bracketed text.

Native window resizing debounces the terminal grid and PTY size together, with
the resize timer running during AppKit tracking as well as ordinary events.
Pane zoom keeps its normal behavior without a forced tmux refresh.

Cmd-click opens web links; right-click offers Open Link and Copy Link Address.
Closing Markdown/prose brackets end a URL even at the pane's right edge, so
the next line's prose is not accidentally appended to the target.
