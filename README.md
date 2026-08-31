# darktable-scripts

Lua modules for [darktable](https://www.darktable.org/).

## move_by_tag_hierarchy

Moves every image carrying a hierarchical tag into a folder tree that mirrors
the tag tree, then optionally detaches the tags that the path now expresses.

An image tagged `Places|UK|London` is moved to:

| include root tag in path | destination |
| --- | --- |
| on | `<destination root>/Places/UK/London/` |
| off | `<destination root>/UK/London/` |

An image tagged only with the root tag lands in the destination root itself
(or in `<destination root>/Places`).

### Requirements

darktable with Lua API 7.0.0 or newer. Developed and tested against darktable
5.6 on macOS. No external software.

### Installation

Copy the script into darktable's config directory and require it:

```bash
cp move_by_tag_hierarchy.lua ~/.config/darktable/lua/
echo 'require "move_by_tag_hierarchy"' >> ~/.config/darktable/luarc
```

Or install it with `script_manager`. Either way, restart darktable — the module
uses `destroy_method = "hide"`, so script_manager does not re-execute the file
and a reload from the module list will not pick up a changed script.

**move by tag hierarchy** then appears in the lighttable right panel. It may be
collapsed; click the header to open it.

### Usage

1. **root tag** — the tag to process, e.g. `Places`. Every image tagged with it
   or with anything below it (`Places|UK|London`) is a candidate.
2. **destination root** — the top of the folder tree, e.g.
   `/Volumes/Photos/Sorted`. The button below the field opens a directory
   chooser.
3. **images** — process every tagged image in the library, or only the selected
   ones.
4. **include root tag in path** — see the table above.
5. **remove hierarchy tags** — after a verified move, detach the root tag and
   every tag below it that the image carries.
6. **remove matching flat tags** — additionally detach non-hierarchical tags
   whose name exactly matches a path component, e.g. a plain `London` tag on an
   image moved to `.../UK/London`. Off by default: a flat tag can share a name
   with a place by accident (`nice`, `bath`), and detaching a tag cannot be
   undone.
7. **dry run** — report what would happen without moving anything or changing
   tags. On by default.

The status line reports
`moved N, N already in place, N skipped, N failed, N tags removed`. The
per-image detail always goes to the darktable log; start darktable with
`-d lua` to see it on the console.

The run is cancellable from the progress bar. Each image is committed
individually, so stopping partway leaves the already-moved images done and the
rest untouched.

### Which tag decides the destination

The deepest matching tag wins. An image tagged both `Places|UK` and
`Places|UK|London` goes to `.../UK/London`, because the first is an ancestor of
the second. An image tagged `Places|UK` and `Places|France` is skipped — those
disagree about where it should go.

Tag components are sanitized for use as directory names: `<>:"/\|?*`, control
characters, and trailing dots and spaces are replaced or trimmed.

### What is skipped

- tags pointing at two different destinations
- another file, **or an orphaned XMP sidecar**, already at the target path
- the image's file is missing on disk
- duplicates sharing one file on disk that want different destinations — the
  file is left alone rather than moved under one duplicate's tags

Skips and failures are counted separately: a skip means the image was left
alone deliberately, a failure means something went wrong (`mkdir` failed, no
film roll could be created, or darktable raised while moving). Both are logged
with a reason.

### Notes

- Tags are detached only after the move has been verified, so a failed move
  never leaves an image stripped of the tags that describe where it belongs.
- darktable moves the XMP sidecar along with the image.
- On macOS and Windows, paths that differ only in case name the same directory.
  The module accounts for this: a destination differing only in case from an
  existing film roll reuses that film roll instead of creating a second one for
  the same directory.
- `darktable`'s own internal tags are never processed or detached.
- Settings persist between sessions in `darktablerc` under
  `lua/move_by_tag_hierarchy/`.

### A word of caution

This module moves files on disk. Run it with **dry run** on first and read the
log before committing to a real run, and make sure you have a backup of both
your photos and `~/.config/darktable/library.db`.

## License

LGPLv2+
