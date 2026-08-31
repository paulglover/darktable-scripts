--[[
  MOVE BY TAG HIERARCHY

  Moves every image carrying a given (hierarchical) tag into a folder tree
  that mirrors the tag tree, then optionally strips the tags that are now
  encoded in the path.

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'move_by_tag_hierarchy'" to $CONFIGDIR/luarc
  * the module "move by tag hierarchy" appears in the lighttable right panel

  1. type the root tag to process, e.g. "Places".  Every image whose tags
     include "Places" or anything below it ("Places|UK|London") is a
     candidate.

  2. choose the destination root, e.g. /Volumes/Photos/Sorted.

  3. an image tagged "Places|UK|London" is moved to

        <destination root>/Places/UK/London/          ("include root tag" on)
        <destination root>/UK/London/                 ("include root tag" off)

     an image tagged only with the root tag lands directly in the
     destination root (or in <destination root>/Places).

  4. after a successful move the tags that are now expressed by the path
     can be detached:
       * "remove hierarchy tags" detaches the root tag and every tag below
         it that the image carries
       * "remove matching flat tags" additionally detaches non-hierarchical
         tags whose name matches one of the path components exactly, e.g. a
         plain "London" tag on an image moved to .../UK/London.  it is off by
         default: a flat tag can easily share a name with a place by accident
         ("nice", "bath"), and detaching a tag cannot be undone

  5. "dry run" reports what would happen without touching anything.  The
     detailed per-image report always goes to the darktable log
     (start darktable with -d lua to see it on the console).

  NOTES
  * an image is skipped when its tags point at two different destinations
    (e.g. "Places|UK" and "Places|France"), when another file of the same
    name already sits in the destination, or when its file is missing.
  * duplicates share one file on disk, so two duplicates wanting different
    destinations are reported as a conflict and left alone.
  * darktable moves the XMP sidecar along with the image.

  LICENSE
  LGPLv2+
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

du.check_min_api_version("7.0.0", "move_by_tag_hierarchy")

local MODULE = "move_by_tag_hierarchy"
local PS = dt.configuration.running_os == "windows" and "\\" or "/"

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("move by tag hierarchy"),
  purpose = _("move tagged images into a folder tree matching the tag tree, then remove the tags"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local mbth = {}
mbth.module_installed = false
mbth.running = false

-- helpers: BEGIN

-- settings are stored as strings rather than with the "bool"/"integer"
-- preference types: an unregistered typed preference that has never been
-- written reads back as false/0, which would silently turn "dry run" off on a
-- fresh install.  a string tells "never set" and "set to false" apart.
local function pref_read(key, default)
  local value = dt.preferences.read(MODULE, key, "string")
  if value == nil or value == "" then
    return default
  end
  return value
end

local function pref_write(key, value)
  dt.preferences.write(MODULE, key, "string", value or "")
end

local function bool_read(key, default)
  local value = dt.preferences.read(MODULE, key, "string")
  if value == "true" then return true end
  if value == "false" then return false end
  return default
end

local function bool_write(key, value)
  dt.preferences.write(MODULE, key, "string", value and "true" or "false")
end

local function trim(str)
  return (string.gsub(str or "", "^%s*(.-)%s*$", "%1"))
end

-- strip trailing path separators, but keep a bare root like "/"
local function strip_trailing_separator(path)
  while #path > 1 and string.sub(path, -1) == PS do
    path = string.sub(path, 1, -2)
  end
  return path
end

-- macos and windows filesystems are normally case insensitive but case
-- preserving, so ".../uk" and ".../UK" are one and the same directory there
local CASE_INSENSITIVE_FS = dt.configuration.running_os ~= "linux"

local function same_path(a, b)
  if CASE_INSENSITIVE_FS then
    return string.lower(a) == string.lower(b)
  end
  return a == b
end

local function split_tag(name)
  local parts = {}
  for part in string.gmatch(name, "[^|]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- make a tag component usable as a directory name on any platform
local function sanitize_component(component)
  local clean = string.gsub(component, '[<>:"/\\|%?%*]', "_")
  clean = string.gsub(clean, "%c", "_")
  clean = trim(clean)
  clean = string.gsub(clean, "[%.%s]+$", "")
  if clean == "" then
    clean = "_"
  end
  return clean
end

local function is_below(tag_name, root)
  return tag_name == root or string.sub(tag_name, 1, #root + 1) == root .. "|"
end

local function tags_below(root)
  local found = {}
  for i = 1, #dt.tags do
    local tag = dt.tags[i]
    if is_below(tag.name, root) then
      found[#found + 1] = tag
    end
  end
  return found
end

local function image_path(image)
  return strip_trailing_separator(image.path) .. PS .. image.filename
end

-- films are cached per run.  dt.films.new() reuses an existing film only when
-- the directory string matches exactly, so a film whose path differs from ours
-- in case alone has to be found by hand: otherwise the library ends up with
-- two film rolls for one directory
local function get_film(path, cache)
  local key = CASE_INSENSITIVE_FS and string.lower(path) or path
  if cache[key] then
    return cache[key]
  end
  for i = 1, #dt.films do
    local film = dt.films[i]
    if same_path(strip_trailing_separator(film.path), path) then
      cache[key] = film
      return film
    end
  end
  cache[key] = dt.films.new(path)
  return cache[key]
end

-- pick the deepest tag below root; return nil plus a reason when the
-- image's tags disagree about where it should go
local function resolve_destination_tag(tag_names)
  local best, best_depth = nil, -1
  for i = 1, #tag_names do
    local depth = #split_tag(tag_names[i])
    if depth > best_depth then
      best, best_depth = tag_names[i], depth
    end
  end
  for i = 1, #tag_names do
    local name = tag_names[i]
    if name ~= best and not is_below(best, name) then
      return nil, string.format(_("conflicting tags '%s' and '%s'"), name, best)
    end
  end
  return best
end

local function detach_tags(image, root, components, remove_hierarchy, remove_flat)
  if not (remove_hierarchy or remove_flat) then
    return 0
  end
  local flat_wanted = {}
  if remove_flat then
    for _, component in ipairs(components) do
      flat_wanted[component] = true
    end
  end
  local removed = 0
  for _, tag in ipairs(dt.tags.get_tags(image)) do
    local name = tag.name
    if string.sub(name, 1, 10) ~= "darktable|" then
      if remove_hierarchy and is_below(name, root) then
        dt.tags.detach(tag, image)
        removed = removed + 1
      elseif remove_flat and not string.find(name, "|", 1, true)
             and flat_wanted[name] then
        dt.tags.detach(tag, image)
        removed = removed + 1
      end
    end
  end
  return removed
end

-- helpers: END

-- widgets: BEGIN

-- editable is set explicitly: the entry widgets that other scripts type into
-- do the same rather than relying on the default
local tag_entry = dt.new_widget("entry") {
  text = pref_read("root_tag", ""),
  placeholder = _("e.g. Places"),
  editable = true,
  is_password = false,
  tooltip = _("root tag to process, e.g. 'Places'\nimages tagged with it or with anything below it are moved")
}

local destination_entry = dt.new_widget("entry") {
  text = pref_read("destination", ""),
  placeholder = _("e.g. /Volumes/Photos/Sorted"),
  editable = true,
  is_password = false,
  tooltip = _("root directory of the destination folder tree\nuse the button below to pick it")
}

local destination_chooser = dt.new_widget("file_chooser_button") {
  title = _("select destination root"),
  is_directory = true,
  changed_callback = function(widget)
    if widget.value then
      destination_entry.text = widget.value
    end
  end
}

local scope_box = dt.new_widget("combobox") {
  label = _("images"),
  tooltip = _("process every tagged image in the library, or only the selected ones"),
  _("all tagged images in library"), _("selected images only")
}
scope_box.selected = tonumber(pref_read("scope", "1")) or 1

local include_root_box = dt.new_widget("check_button") {
  label = _("include root tag in path"),
  tooltip = _("on:  'Places|UK|London' -> <destination>/Places/UK/London\noff: 'Places|UK|London' -> <destination>/UK/London"),
  value = bool_read("include_root", true)
}

local remove_hierarchy_box = dt.new_widget("check_button") {
  label = _("remove hierarchy tags"),
  tooltip = _("after a successful move, detach the root tag and every tag below it"),
  value = bool_read("remove_hierarchy", true)
}

local remove_flat_box = dt.new_widget("check_button") {
  label = _("remove matching flat tags"),
  tooltip = _("also detach non-hierarchical tags whose name matches a component\nof the destination path exactly, e.g. a plain 'London' tag.\noff by default: an unrelated tag can share a name with a place"),
  value = bool_read("remove_flat", false)
}

local dry_run_box = dt.new_widget("check_button") {
  label = _("dry run"),
  tooltip = _("report what would be done without moving anything or changing tags"),
  value = bool_read("dry_run", true)
}

local status_label = dt.new_widget("label") {
  label = "",
  halign = "start",
  ellipsize = "middle"
}

-- widgets: END

-- business logic: BEGIN

local function save_settings()
  pref_write("root_tag", tag_entry.text)
  pref_write("destination", destination_entry.text)
  pref_write("scope", tostring(scope_box.selected))
  bool_write("include_root", include_root_box.value)
  bool_write("remove_hierarchy", remove_hierarchy_box.value)
  bool_write("remove_flat", remove_flat_box.value)
  bool_write("dry_run", dry_run_box.value)
end

local function fail(message)
  dt.print(string.format(_("move by tag hierarchy: %s"), message))
  status_label.label = message
end

-- build the work list: one entry per image, or a skip reason
local function plan(root, destination_root, selected_only, include_root)
  local matched = tags_below(root)
  if #matched == 0 then
    return nil, string.format(_("no tag '%s' found"), root)
  end

  local selection = nil
  if selected_only then
    selection = {}
    local action_images = dt.gui.action_images
    if #action_images == 0 then
      return nil, _("no images selected")
    end
    for _, image in ipairs(action_images) do
      selection[image.id] = true
    end
  end

  -- gather the matching tag names per image
  local candidates, order = {}, {}
  for _, tag in ipairs(matched) do
    for i = 1, #tag do
      local image = tag[i]
      if selection == nil or selection[image.id] then
        local entry = candidates[image.id]
        if not entry then
          entry = { image = image, tag_names = {} }
          candidates[image.id] = entry
          order[#order + 1] = image.id
        end
        entry.tag_names[#entry.tag_names + 1] = tag.name
      end
    end
  end

  local work, skipped = {}, {}
  local by_file = {}
  local root_depth = #split_tag(root)

  for i = 1, #order do
    local entry = candidates[order[i]]
    local image = entry.image
    local source = image_path(image)
    local tag_name, reason = resolve_destination_tag(entry.tag_names)

    if not tag_name then
      skipped[#skipped + 1] = { source = source, reason = reason }
    elseif not df.check_if_file_exists(source) then
      skipped[#skipped + 1] = { source = source, reason = _("file not found") }
    else
      local components = split_tag(tag_name)
      if not include_root then
        for depth = 1, root_depth do
          table.remove(components, 1)
        end
      end

      local directory = destination_root
      for c = 1, #components do
        directory = directory .. PS .. sanitize_component(components[c])
      end

      local item = {
        image = image,
        source = source,
        directory = directory,
        components = components,
        target = directory .. PS .. image.filename
      }

      -- duplicates share one file on disk: two destinations is a conflict
      local seen = by_file[source]
      if seen then
        if seen.directory ~= directory then
          seen.conflict = true
          item.conflict = true
        else
          item.duplicate_of = seen
        end
      else
        by_file[source] = item
      end

      work[#work + 1] = item
    end
  end

  -- turn the conflicts detected above into skips
  local final = {}
  for i = 1, #work do
    local item = work[i]
    local owner = item.duplicate_of or item
    if owner.conflict or item.conflict then
      skipped[#skipped + 1] = {
        source = item.source,
        reason = _("duplicates of this file want different destinations")
      }
    else
      final[#final + 1] = item
    end
  end

  return { work = final, skipped = skipped }
end

local function stop_move(job)
  job.valid = false
end

local function run()
  if mbth.running then
    dt.print(_("move by tag hierarchy: already running"))
    return
  end

  local root = trim(tag_entry.text)
  local destination_root = strip_trailing_separator(trim(destination_entry.text))

  if root == "" then
    return fail(_("no tag given"))
  end
  if root == "darktable" or string.sub(root, 1, 10) == "darktable|" then
    return fail(_("refusing to process darktable's internal tags"))
  end
  if destination_root == "" then
    return fail(_("no destination given"))
  end

  local dry_run = dry_run_box.value
  local include_root = include_root_box.value
  local remove_hierarchy = remove_hierarchy_box.value
  local remove_flat = remove_flat_box.value
  local selected_only = scope_box.selected == 2

  save_settings()

  -- checked on dry runs too: reporting a clean plan against a destination that
  -- does not exist defeats the point of the dry run
  if not df.test_file(destination_root, "d") then
    return fail(string.format(_("destination is not a directory: %s"), destination_root))
  end

  local plan_result, error_message = plan(root, destination_root, selected_only, include_root)
  if not plan_result then
    return fail(error_message)
  end

  local work, plan_skips = plan_result.work, plan_result.skipped
  if #work == 0 and #plan_skips == 0 then
    return fail(string.format(_("no images tagged '%s'"), root))
  end

  mbth.running = true

  local job = dt.gui.create_job(
    string.format(dry_run and _("move by tag hierarchy (dry run, %d images)")
                          or _("move by tag hierarchy (%d images)"), #work),
    true, stop_move)
  job.percent = 0.0

  local films = {}
  local moved, in_place, skipped, failed, untagged = 0, 0, #plan_skips, 0, 0
  local cancelled = false

  dt.print_log(string.format("%s: %s '%s' -> %s", MODULE,
    dry_run and "dry run" or "moving", root, destination_root))

  local function process_item(item)
    local image = item.image
    local current_directory = strip_trailing_separator(image.path)

    if same_path(current_directory, item.directory) then
      in_place = in_place + 1
      dt.print_log(string.format("%s: already in place: %s", MODULE, item.source))
      if not dry_run then
        untagged = untagged + detach_tags(image, root, item.components,
                                          remove_hierarchy, remove_flat)
      end
    -- an orphaned sidecar at the destination would be overwritten as well
    elseif df.check_if_file_exists(item.target)
        or df.check_if_file_exists(item.target .. ".xmp") then
      skipped = skipped + 1
      dt.print_log(string.format("%s: SKIPPED (target exists): %s -> %s",
        MODULE, item.source, item.target))
    elseif dry_run then
      moved = moved + 1
      dt.print_log(string.format("%s: would move: %s -> %s",
        MODULE, item.source, item.target))
    else
      local made = df.mkdir(item.directory)
      if not df.test_file(item.directory, "d") then
        failed = failed + 1
        dt.print_log(string.format("%s: FAILED (mkdir returned %s): %s",
          MODULE, tostring(made), item.directory))
      else
        local film = get_film(item.directory, films)
        if not film then
          failed = failed + 1
          dt.print_log(string.format("%s: FAILED (no film roll for): %s",
            MODULE, item.directory))
        else
          dt.database.move_image(image, film)
          if same_path(strip_trailing_separator(image.path), item.directory) then
            moved = moved + 1
            dt.print_log(string.format("%s: moved: %s -> %s",
              MODULE, item.source, item.target))
            untagged = untagged + detach_tags(image, root, item.components,
                                              remove_hierarchy, remove_flat)
          else
            failed = failed + 1
            dt.print_log(string.format("%s: FAILED (move): %s -> %s",
              MODULE, item.source, item.target))
          end
        end
      end
    end
  end

  for index, item in ipairs(work) do
    if not job.valid then
      cancelled = true
      break
    end

    -- dt.database.move_image() raises rather than returning a status, and
    -- df.mkdir() yields, so an image can disappear from the library while we
    -- work.  one bad image must not abort the run, strand the progress bar or
    -- leave the module marked as running for the rest of the session
    local ok, error_message = pcall(process_item, item)
    if not ok then
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (%s): %s",
        MODULE, tostring(error_message), item.source))
    end

    if job.valid then
      job.percent = index / #work
    end
  end

  for _, skip in ipairs(plan_skips) do
    dt.print_log(string.format("%s: SKIPPED (%s): %s", MODULE, skip.reason, skip.source))
  end

  -- cancelling already destroyed the job
  if job.valid then
    job.valid = false
  end
  mbth.running = false

  local summary
  if dry_run then
    summary = string.format(_("dry run: %d to move, %d already in place, %d skipped, %d failed"),
      moved, in_place, skipped, failed)
  else
    summary = string.format(_("moved %d, %d already in place, %d skipped, %d failed, %d tags removed"),
      moved, in_place, skipped, failed, untagged)
  end
  if cancelled then
    summary = string.format(_("cancelled - %s"), summary)
  end

  status_label.label = summary
  dt.print(string.format(_("move by tag hierarchy: %s"), summary))
  dt.print_log(string.format("%s: %s", MODULE, summary))

  if not dry_run and moved > 0 then
    -- refresh the collect module so the new film rolls show up
    pcall(function()
      local rules = dt.gui.libs.collect.filter()
      dt.gui.libs.collect.filter(rules)
    end)
  end
end

-- business logic: END

mbth.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    tag_entry.text = ""
    destination_entry.text = ""
    status_label.label = ""
  end,
  dt.new_widget("label") { label = _("root tag"), halign = "start" },
  tag_entry,
  dt.new_widget("label") { label = _("destination root"), halign = "start" },
  destination_entry,
  destination_chooser,
  scope_box,
  include_root_box,
  remove_hierarchy_box,
  remove_flat_box,
  dry_run_box,
  dt.new_widget("button") {
    label = _("move images"),
    tooltip = _("move all matching images into the destination tree"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not mbth.module_installed then
    dt.register_lib(MODULE, _("move by tag hierarchy"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 700 }
    }, mbth.widget, nil, nil)
    mbth.module_installed = true
  end
end

local function destroy()
  dt.gui.libs[MODULE].visible = false
end

local function restart()
  dt.gui.libs[MODULE].visible = true
end

-- darktable_gui_safe is set by darktable's own luarc once gui initialization
-- has finished; registering a lib before that hangs darktable (issue #19197)
if dt.gui.current_view().id == "lighttable" and darktable_gui_safe then
  install_module()
else
  -- install as soon as we reach lighttable, whichever view we come from
  dt.register_event(MODULE, "view-changed",
    function(event, old_view, new_view)
      if new_view.id == "lighttable" then
        install_module()
      end
    end
  )
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
