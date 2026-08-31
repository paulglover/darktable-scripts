# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Lua modules for darktable. Each `*.lua` at the repo root is a standalone,
self-registering darktable module — there is no build system, no package
manager, and no dependency between the scripts. Requires darktable with Lua API
7.0.0+ (developed against 5.6).

## Verify every API call against the installed darktable

darktable ships no Lua API documentation in the app bundle, and the API changes
between releases. **Do not write darktable API calls from memory.** The
authoritative reference is darktable's own bundled scripts, on macOS at:

```
/Applications/darktable.app/Contents/Resources/share/darktable/lua-scripts/
```

`contrib/` for module patterns, `lib/dtutils*.lua` for the `du`/`df`/`ds`
helpers this code uses, `tools/script_manager.lua` for the `script_data`
contract and widget idioms, and `share/darktable/luarc` for load order. When an
API's behaviour cannot be confirmed from those files, say so rather than
asserting it.

## Commands

Syntax check (the only static check available):

```bash
luac -p move_by_tag_hierarchy.lua
```

Install for manual testing, then **restart darktable** — modules set
`script_data.destroy_method = "hide"`, so script_manager never re-executes the
file and reloading from the module list will not pick up an edit:

```bash
cp move_by_tag_hierarchy.lua ~/.config/darktable/lua/
```

`~/.config/darktable/luarc` holds one `require` line per script. Launch with
`-d lua` to see each module's per-image log on the console:

```bash
/Applications/darktable.app/Contents/MacOS/darktable -d lua
```

## Testing

There is no committed test suite. These modules move real photo files, so
validate logic **before** ever running against a real library, by stubbing
darktable rather than launching it: inject fake `darktable`, `lib/dtutils` and
`lib/dtutils.file` modules through `package.preload`, then `dofile` the script
under plain `lua` and drive it headlessly. The registration path runs on load,
so the stub's `register_lib` captures the widget box; tests then set widget
fields and call the button's `clicked_callback` directly.

The stub needs `__len`/`__index` metatables on the tag and film collections
(darktable exposes them as `#dt.tags` / `dt.tags[i]`, not as Lua arrays), and a
`move_image` that performs a real `os.rename` over temp fixture trees so moves
can be asserted against the filesystem.

Cases worth covering, each of which has produced a real bug here: a destination
directory differing only in case from an existing film roll, an error raised
mid-loop, job cancellation, dry run, duplicates resolving to different
destinations, and a target path that already exists.

Never kill darktable from the shell during testing — ask for a GUI quit so
`library.db` is written cleanly.

## Architecture

### Plan, then execute

`plan()` walks the tags and builds a complete work list of `{image, source,
directory, components, target}` items plus a list of skips, and only then does
the move loop run. This split is load-bearing, not stylistic: detaching a tag
mutates the very collection (`tag[i]`, `dt.tags.get_tags`) that the walk
iterates, so resolving everything up front is what keeps the iteration sound.
Keep destination resolution and conflict detection inside `plan()`; keep
filesystem and database effects inside the loop.

### The move loop must not be able to escape

`dt.database.move_image` raises on failure rather than returning a status, and
`df.mkdir` yields (darktable can process UI events mid-loop, so an image can
disappear from the library underneath the loop). Each item therefore runs
through `pcall`, and the module's `running` flag plus `job.valid` are cleared on
every path. Without that, one bad image strands the progress bar and latches the
module as "already running" for the rest of the session.

Tags are detached only after the move is verified against `image.path`. A
failed move must never leave an image stripped of the tags describing where it
belongs — tag detachment cannot be undone from Lua.

### Case-insensitive filesystems

macOS and Windows are case insensitive but case preserving, so `.../uk` and
`.../UK` are one directory. `dt.films.new()` matches the directory string
exactly, so an existing film roll differing only in case must be found by hand
or the library gains a second film roll for the same directory. All path
comparisons go through `same_path()`; do not compare paths with `==`.

### Module registration

Registering a lighttable lib before darktable finishes GUI initialization hangs
darktable (issue #19197). The global `darktable_gui_safe`, set by darktable's
own luarc, guards the direct-install path; otherwise the module installs from a
`view-changed` handler on first entry to lighttable. Anything that needs the
library to be open (enumerating tags, for example) belongs in `install_module()`,
not at script load time.

### Preferences

Settings persist through *unregistered* `dt.preferences`, landing in
`darktablerc` as `lua/<module>/<key>`. They are stored as strings, not with the
`"bool"`/`"integer"` types, because a typed preference that was never written
reads back as false/0 — which would silently turn a safety default like "dry
run" off on a fresh install. A string distinguishes "never set" from "set to
false".

### Localization

`_()` is the gettext alias. Beware shadowing it: `for _, x in ipairs(t)` inside
a function that also calls `_()` makes the call fail at runtime with "attempt to
call a number value". Use numeric `for i = 1, #t` loops in any scope that
formats a user-facing string.

## Git

`main` is protected on GitHub and rejects direct pushes with admin enforcement.
All changes go through a pull request; required approving reviews is 0, so the
PR can be self-merged.

```bash
git switch -c some-change && git push -u origin some-change && gh pr create --fill
```
