# Permission Peek — Spike Findings (Task 1)

**Date:** 2026-05-26
**Claude Code version:** 2.1.150
**How captured:** isolated `claude` driven inside a dedicated tmux server
(`tmux -L amuxpeek`, separate from the user's amux on the default socket),
via `tools/capture-permission-prompt.sh`. Prompts forced with a project
`permissions.ask` rule and with non-allowlisted commands. Fixtures in
`app/Tests/Fixtures/`.

## What the rendered prompt actually looks like

`capture-pane -p -J` of a live permission prompt (see `permission-bash-3opt.txt`):

```
 Bash command

   sw_vers
   Show macOS version

 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: sw_vers *
   3. No

 Esc to cancel · Tab to amend · ctrl+e to explain
```

### Confirmed facts (parser inputs)

- **No box-drawing border** around the prompt. The visible "box" is rendered
  with background colors, not `│ ╭ ╮` glyphs, so `capture-pane -p` returns
  plain **space-indented** text. (A full-width `─` horizontal rule separates
  the transcript from the prompt region; a line of all `─` strips to empty.)
- **Selection glyph: `❯` (U+276F).** The selected option line is prefixed
  ` ❯ `; unselected options are indented 3 spaces.
- **Question line: `Do you want to proceed?`** — ends with `?`. One space of
  left padding. Sits immediately above option 1 (no blank line between).
- **Option label format:** `<n>. <label>`. The "don't ask again" label uses a
  **curly apostrophe `’` (U+2019)**, and embeds the command:
  `Yes, and don’t ask again for: sw_vers *`.
- **Footer:** `Esc to cancel · Tab to amend · ctrl+e to explain`.

The parser's anchors (≥2 numbered options, one label starts with "Yes", a
preceding line ending in "?") match both captured fixtures. `stripBorder`
must strip leading/trailing **whitespace** (border glyphs are absent here but
harmless to keep).

## Option-set variants (both are real captures)

| Fixture | Trigger | Options |
|---------|---------|---------|
| `permission-bash.txt` | `echo` forced via `permissions.ask` | `1. Yes` / `2. No` |
| `permission-bash-3opt.txt` | `sw_vers`, not allowlisted | `1. Yes` / `2. Yes, and don’t ask again for: sw_vers *` / `3. No` |

Option count and labels vary by how the prompt was triggered. The popup must
render whatever options are present, by number, verbatim.

## Answer mechanism — VERIFIED

**A bare digit selects AND confirms immediately. No Enter needed.**

- Sent `1` to the 2-option box → "Yes" → `echo` ran (`hello-from-peek`, "Done").
- Sent `3` to the 3-option box → tool rejected → "Interrupted · What should
  Claude do instead?".

So `answerKeys(for: option) == ["\(option.number)"]` is correct — send the
digit token via `tmux send-keys`, nothing else.

## Design-affecting finding: option 3 is plain "No"

The design (and plan) assumed option 3 is **"No, and tell Claude what to do
differently"**, which requires typing feedback — the rationale for mapping
**3 → engage** (switch to that session). **That wording does not appear in
Claude Code 2.1.150 Bash prompts.** Option 3 is a plain **"No"**, which is
fully keystroke-answerable in place (verified above).

Implication: the "reject inherently needs engagement" premise is outdated.
Every current option (Yes / Yes-don't-ask / No) can be answered without
switching. **"Engage" should be a separate affordance, not option 3.**
Needs a quick design decision before Tasks 2/6/8 bake in the old mapping —
e.g. keep `3` as a real in-place "No" and bind engage to its own key in the
popup (or render an extra "Engage" row).

## Not captured (environment limits — deferred, not blocking)

- **Authentic edit/Write prompt** (and whether *it* still says "tell Claude
  what to do differently"): in this environment `Write` is **globally
  allowlisted** (auto-approves), and a global `PreToolUse:Write` hook ("Do not
  edit files on main") intercepts writes before any prompt. Forcing Write via
  `permissions.ask` only yields the generic 2-option Yes/No box, not the
  authentic edit prompt. The parser is validated against the two real Bash
  fixtures, which is sufficient for v1.
- **MCP-tool prompt:** needs a configured MCP server; deferred.

## Reproducing

```
tools/capture-permission-prompt.sh start          # claude in PEEK_DIR on socket amuxpeek
tools/capture-permission-prompt.sh send "Run this bash command: sw_vers"
tools/capture-permission-prompt.sh enter
tools/capture-permission-prompt.sh waitfor "do you want|proceed"
tools/capture-permission-prompt.sh capto app/Tests/Fixtures/permission-bash-3opt.txt
tools/capture-permission-prompt.sh stop
```
