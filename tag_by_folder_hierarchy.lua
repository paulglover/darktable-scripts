--[[
  TAG BY FOLDER HIERARCHY

  Tags the selected images with a hierarchical tag that mirrors the folder
  they sit in.  Only the deepest folder is tagged: an image in
  Events/Holiday/Christmas gets "Events|Holiday|Christmas" and nothing else.

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'tag_by_folder_hierarchy'" to $CONFIGDIR/luarc
  * the module "tag by folder hierarchy" appears in the lighttable right panel

  1. choose the folder root, e.g. /Volumes/Photos.  Only the part of an
     image's path below that root becomes a tag, so the root itself never
     shows up in the tag tree.

  2. select the images to tag and press "tag images".  With the root above:

        /Volumes/Photos/Events/img1.raw                 -> Events
        /Volumes/Photos/Events/Holiday/img2.raw         -> Events|Holiday
        /Volumes/Photos/Events/Holiday/Xmas/img3.raw    -> Events|Holiday|Xmas

     each image gets exactly one tag, for its own folder.  An image directly
     in the root has no folder to name and is skipped unless a tag prefix is
     set.

  3. "tag prefix" (optional) nests the whole tree under one tag, so with a
     prefix of "Folders" the first image above is tagged "Folders|Events".

  4. "dry run" reports what would happen without attaching anything.  The
     detailed per-image report always goes to the darktable log (start
     darktable with -d lua to see it on the console).

  CATEGORIES

  A folder that holds no images of its own becomes a category rather than a
  tag, which is what tagging only the deepest folder already gives you:
  darktable stores one row per tag name, so attaching "Events|Holiday" does
  not create "Events".  "Events" appears in the tag dictionary as a parent
  node with no images and nothing to attach - the dictionary even offers
  "set as a tag" for it - which is exactly how a category behaves.

  The one thing this module cannot do is anything about a level that already
  exists as a tag: darktable's Lua API exposes a tag's name and synonyms and
  nothing else, so the category flag can be neither read nor set.  Such a
  level is reported and left alone - it may already be a category, and Lua
  cannot tell - so check it in the tagging module's dictionary.

  NOTES
  * this module never moves, renames or deletes anything.  It attaches tags,
    and it never detaches one: an image that was tagged for its old folder
    and has since moved keeps both tags, and the stale one has to go by hand.
  * images outside the folder root are skipped and named in the log.
  * "|" separates tag levels, so a folder name containing one would silently
    add a level.  Those characters, and control characters, become "_".
  * runs of whitespace in a folder name collapse to a single space, so
    "Myrtle Beach  May 2022" tags as "Myrtle Beach May 2022".  A doubled space
    is invisible in the tag dictionary and would make two tags out of what
    reads as one name.
  * on macOS and Windows ".../uk" and ".../UK" are one folder, so a tag that
    differs from an existing one only in case is not created: the run reuses
    the tag the library already has.

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

du.check_min_api_version("7.0.0", "tag_by_folder_hierarchy")

local MODULE = "tag_by_folder_hierarchy"
local PS = dt.configuration.running_os == "windows" and "\\" or "/"

-- windows accepts either separator inside one path; everywhere else a
-- backslash is a legal character in a folder name and must not split one
local COMPONENT_PATTERN = dt.configuration.running_os == "windows"
                          and "[^\\/]+" or "[^/]+"

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("tag by folder hierarchy"),
  purpose = _("tag images with a hierarchical tag matching the folder they sit in"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local tbfh = {}
tbfh.module_installed = false
tbfh.running = false

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
  while #path > 1 and (string.sub(path, -1) == PS or string.sub(path, -1) == "/") do
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

-- the key two names are compared under.  darktable's tags are case sensitive
-- everywhere, but the folders they are built from are not on macos and
-- windows, so two spellings of one folder must not become two tags
local function path_key(name)
  if CASE_INSENSITIVE_FS then
    return string.lower(name)
  end
  return name
end

local function split_tag(name)
  local parts = {}
  for part in string.gmatch(name, "[^|]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function is_internal(name)
  return name == "darktable" or string.sub(name, 1, 10) == "darktable|"
end

-- make a folder name usable as one level of a tag.  a literal "|" is legal in
-- a folder name on every platform this runs on and would silently add a level.
--
-- runs of whitespace collapse to one space before anything else touches them,
-- so a folder named "Myrtle Beach  May 2022" tags as "Myrtle Beach May 2022":
-- a doubled space is invisible in the tag dictionary and makes two tags out of
-- what reads as one name.  collapsing first also turns a tab or a newline into
-- that single space rather than into an underscore
local function sanitize_component(component)
  local clean = string.gsub(component, "|", "_")
  clean = string.gsub(clean, "%s+", " ")
  clean = string.gsub(clean, "%c", "_")
  clean = trim(clean)
  if clean == "" then
    clean = "_"
  end
  return clean
end

local function image_directory(image)
  return strip_trailing_separator(image.path)
end

-- the folder components of directory below root, or nil when it is not below
-- root at all.  an image in the root itself has no components, which is not
-- the same thing as being outside it
local function components_below(directory, root)
  if same_path(directory, root) then
    return {}
  end

  local prefix = root
  if string.sub(prefix, -1) ~= PS then
    prefix = prefix .. PS
  end
  if not same_path(string.sub(directory, 1, #prefix), prefix) then
    return nil
  end

  local parts = {}
  for part in string.gmatch(string.sub(directory, #prefix + 1), COMPONENT_PATTERN) do
    parts[#parts + 1] = part
  end
  return parts
end

-- does the image already carry this tag?  asked of the image rather than of
-- the tag: the image's own list is what says a tag is really attached
local function carries_tag(image, name)
  local tags = dt.tags.get_tags(image)
  for i = 1, #tags do
    if tags[i].name == name then
      return true
    end
  end
  return false
end

-- helpers: END

-- widgets: BEGIN

-- editable is set explicitly: the entry widgets that other scripts type into
-- do the same rather than relying on the default
local root_entry = dt.new_widget("entry") {
  text = pref_read("root", ""),
  placeholder = _("e.g. /Volumes/Photos"),
  editable = true,
  is_password = false,
  tooltip = _("the folder the tag tree starts below\nuse the button underneath to pick it")
}

local root_chooser = dt.new_widget("file_chooser_button") {
  title = _("select folder root"),
  is_directory = true,
  changed_callback = function(widget)
    if widget.value then
      root_entry.text = widget.value
    end
  end
}

local prefix_entry = dt.new_widget("entry") {
  text = pref_read("prefix", ""),
  placeholder = _("optional, e.g. Folders"),
  editable = true,
  is_password = false,
  tooltip = _("nest the whole tree under one tag\n'Folders' turns 'Events|Holiday' into 'Folders|Events|Holiday'")
}

local dry_run_box = dt.new_widget("check_button") {
  label = _("dry run"),
  tooltip = _("report what would be tagged without attaching anything"),
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
  pref_write("root", root_entry.text)
  pref_write("prefix", prefix_entry.text)
  bool_write("dry_run", dry_run_box.value)
end

-- logged as well as shown: a run that gives up has already written its header
-- to the log, and a header with no conclusion under -d lua says nothing about
-- why the run stopped
local function fail(message)
  dt.print(string.format(_("tag by folder hierarchy: %s"), message))
  dt.print_log(string.format("%s: GAVE UP (%s)", MODULE, message))
  status_label.label = message
end

-- every tag name in the library, indexed by its case folded form, so a run on
-- a case insensitive filesystem reuses the tag it made last time instead of
-- adding one that differs only in case.  only ever consulted for names, never
-- for tag objects: walking dt.tags has been seen to yield entries named for a
-- single level of a hierarchy, and one of those must not be attached to
local function tag_names_by_key()
  local index = {}
  if not CASE_INSENSITIVE_FS then
    return index
  end
  for i = 1, #dt.tags do
    local name = dt.tags[i].name
    if not is_internal(name) then
      local key = string.lower(name)
      if not index[key] then
        index[key] = name
      end
    end
  end
  return index
end

-- the name to attach for a candidate: the candidate itself, unless the
-- library already spells it differently in case alone
local function canonical_tag(candidate, library, run)
  if not CASE_INSENSITIVE_FS then
    return candidate
  end

  local key = string.lower(candidate)
  if run[key] then
    return run[key]
  end

  local existing = library[key]
  if existing and existing ~= candidate then
    -- the name has to round trip through find() before it is trusted: an
    -- entry the walk produced that resolves to nothing, or to some other
    -- tag, is not something to attach images to
    local ok, tag = pcall(dt.tags.find, existing)
    if ok and tag and tag.name == existing then
      run[key] = existing
      return existing
    end
  end

  run[key] = candidate
  return candidate
end

-- the directories the library holds images in.  a folder is a category when
-- no image sits in it, and the selection alone cannot answer that: an image
-- in the folder may simply not be selected
local function directories_with_images()
  local found = {}
  for i = 1, #dt.films do
    local film = dt.films[i]
    if #film > 0 then
      found[path_key(strip_trailing_separator(film.path))] = true
    end
  end
  return found
end

-- the levels of the planned tags that no image sits in, so the run can report
-- which folders became categories.  the deepest level of each tag is always a
-- real tag - an image is what put it there - so only the levels above it are
-- considered
local function category_levels(work, root, prefix_depth)
  local seen, levels = {}, {}

  for i = 1, #work do
    local item = work[i]
    local components = item.components
    local acc = nil
    for p = 1, #components - 1 do
      acc = acc and (acc .. "|" .. components[p]) or components[p]
      local key = path_key(acc)
      if not seen[key] then
        seen[key] = true
        -- the prefix levels name no folder at all, so they are categories
        -- whatever the filesystem holds
        local directory = nil
        if p > prefix_depth then
          directory = root
          for d = 1, p - prefix_depth do
            directory = directory .. PS .. item.raw[d]
          end
        end
        levels[#levels + 1] = { name = acc, directory = directory }
      end
    end
  end

  if #levels == 0 then
    return levels
  end

  local with_images = directories_with_images()
  local categories = {}
  for i = 1, #levels do
    local level = levels[i]
    if not (level.directory and with_images[path_key(level.directory)]) then
      -- a level with no images of its own is a category unless the library
      -- already carries it as a real tag, and lua cannot turn one of those
      -- into a category
      local ok, tag = pcall(dt.tags.find, level.name)
      level.existing = ok and tag ~= nil and tag.name == level.name
      categories[#categories + 1] = level
    end
  end

  table.sort(categories, function(a, b) return a.name < b.name end)
  return categories
end

-- build the work list: one entry per selected image, or a skip reason.
--
-- everything is resolved before anything is attached, because creating a tag
-- adds to dt.tags, the collection the case index above is built from
local function plan(root, prefix, job)
  local action_images = dt.gui.action_images
  if #action_images == 0 then
    return nil, _("no images selected")
  end

  -- the selection is snapshotted: it is the gui's, and the gui keeps running
  -- while the database calls below yield
  local images = {}
  for i = 1, #action_images do
    images[#images + 1] = action_images[i]
  end

  local prefix_components = {}
  if prefix ~= "" then
    local parts = split_tag(prefix)
    for i = 1, #parts do
      prefix_components[i] = sanitize_component(parts[i])
    end
  end

  local library = tag_names_by_key()
  local run_index = {}

  local work, skipped = {}, {}
  local tags_seen, tag_count = {}, 0
  local outside = 0

  for i = 1, #images do
    if job and not job.valid then
      return nil, _("cancelled")
    end

    local image = images[i]
    local directory = image_directory(image)
    local source = directory .. PS .. image.filename
    local raw = components_below(directory, root)

    if not raw then
      outside = outside + 1
      skipped[#skipped + 1] = { source = source, reason = _("outside the folder root") }
    elseif #raw == 0 and #prefix_components == 0 then
      skipped[#skipped + 1] = {
        source = source,
        reason = _("in the folder root itself, no folder to name it after")
      }
    else
      local components = {}
      for p = 1, #prefix_components do
        components[#components + 1] = prefix_components[p]
      end
      for p = 1, #raw do
        components[#components + 1] = sanitize_component(raw[p])
      end

      local candidate = table.concat(components, "|")
      local name = canonical_tag(candidate, library, run_index)

      if is_internal(name) then
        skipped[#skipped + 1] = {
          source = source,
          reason = string.format(_("'%s' is one of darktable's internal tags"), name)
        }
      else
        if name ~= candidate then
          dt.print_log(string.format("%s: '%s' spelled '%s' in the library, reusing that",
            MODULE, candidate, name))
        end

        -- the name is re-split: the canonical spelling is what the category
        -- levels have to be read off, not the one the folders gave
        local final_components = split_tag(name)

        if not tags_seen[path_key(name)] then
          tags_seen[path_key(name)] = true
          tag_count = tag_count + 1
        end

        work[#work + 1] = {
          image = image,
          source = source,
          tag = name,
          components = final_components,
          raw = raw,
          already = carries_tag(image, name)
        }
      end
    end

    if job and job.valid then
      job.percent = 0.5 * i / #images
    end
  end

  return {
    work = work,
    skipped = skipped,
    tag_count = tag_count,
    outside = outside,
    selected = #images,
    categories = category_levels(work, root, #prefix_components)
  }
end

local function stop_tagging(job)
  job.valid = false
end

-- everything from the job onwards, so that a raise anywhere inside cannot
-- leave the module latched as running or the progress bar stranded
local function run_once(root, prefix, dry_run)
  local job = dt.gui.create_job(
    dry_run and _("tag by folder hierarchy (dry run)") or _("tag by folder hierarchy"),
    true, stop_tagging)
  tbfh.job = job
  job.percent = 0.0

  dt.print_log(string.format("%s: %s below %s%s", MODULE,
    dry_run and "dry run" or "tagging", root,
    prefix ~= "" and (", prefix '" .. prefix .. "'") or ""))

  -- dt.tags.get_tags() goes to the database and yields, so the plan can be
  -- cancelled and an image can leave the library while it is built
  local plan_result, error_message = plan(root, prefix, job)
  if not plan_result then
    return nil, error_message
  end

  local work, skips = plan_result.work, plan_result.skipped

  -- logged before the run gives up below: a run with nothing to tag is
  -- exactly the one whose reasons the user needs to read
  for i = 1, #skips do
    dt.print_log(string.format("%s: SKIPPED (%s): %s",
      MODULE, skips[i].reason, skips[i].source))
  end

  if #work == 0 then
    if plan_result.outside == plan_result.selected then
      return nil, string.format(_("no selected image is below %s"), root)
    end
    return nil, string.format(_("nothing to tag (%d images skipped - see the log)"), #skips)
  end

  local categories = plan_result.categories
  for i = 1, #categories do
    local level = categories[i]
    if level.existing then
      -- the category flag lives in a column lua cannot read, so an existing
      -- entry may already be a category or may be a plain tag.  the log says
      -- what is actually known rather than guessing at the pessimistic one
      dt.print_log(string.format(
        "%s: '%s' holds no images but already exists in the library; " ..
        "lua cannot read the category flag, so check it in the tag dictionary",
        MODULE, level.name))
    else
      dt.print_log(string.format("%s: category (no images of its own): '%s'",
        MODULE, level.name))
    end
  end

  local tagged, already, failed = 0, 0, 0
  local skipped = #skips
  local cancelled = false

  local function process_item(item)
    if item.already then
      already = already + 1
      dt.print_log(string.format("%s: already tagged '%s': %s",
        MODULE, item.tag, item.source))
      return
    end

    if dry_run then
      tagged = tagged + 1
      dt.print_log(string.format("%s: would tag '%s': %s",
        MODULE, item.tag, item.source))
      return
    end

    -- create() returns the tag that is already there when there is one, so
    -- this neither duplicates a tag nor needs a find() first
    local tag = dt.tags.create(item.tag)
    if not tag then
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (could not create '%s'): %s",
        MODULE, item.tag, item.source))
      return
    end

    dt.tags.attach(tag, item.image)

    -- read back what the image says about itself: attach reports nothing, and
    -- a tag object that accepts the call without changing the database is
    -- exactly what this repository has been bitten by before
    if carries_tag(item.image, item.tag) then
      tagged = tagged + 1
      dt.print_log(string.format("%s: tagged '%s': %s", MODULE, item.tag, item.source))
    else
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (attach did not take): '%s' on %s",
        MODULE, item.tag, item.source))
    end
  end

  for i = 1, #work do
    if not job.valid then
      cancelled = true
      break
    end

    -- dt.tags.create() and attach() raise rather than returning a status, and
    -- they yield, so an image can leave the library while we work.  one bad
    -- image must not abort the run or strand the progress bar
    local item_ok, item_error = pcall(process_item, work[i])
    if not item_ok then
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (%s): %s",
        MODULE, tostring(item_error), work[i].source))
    end

    if job.valid then
      job.percent = 0.5 + 0.5 * i / #work
    end
  end

  -- a stop pressed during the last item leaves the loop by its condition, so
  -- the job is checked here as well
  if not job.valid then
    cancelled = true
  else
    job.valid = false
  end

  local summary
  if dry_run then
    summary = string.format(
      _("dry run: %d to tag with %d tags, %d already tagged, %d categories, %d skipped"),
      tagged, plan_result.tag_count, already, #categories, skipped)
  else
    summary = string.format(
      _("tagged %d with %d tags, %d already tagged, %d categories, %d skipped, %d failed"),
      tagged, plan_result.tag_count, already, #categories, skipped, failed)
  end
  if cancelled then
    summary = string.format(_("cancelled - %s"), summary)
  end

  return summary
end

local function run()
  if tbfh.running then
    dt.print(_("tag by folder hierarchy: already running"))
    return
  end

  local root = strip_trailing_separator(trim(root_entry.text))
  local prefix = trim(prefix_entry.text)
  local dry_run = dry_run_box.value

  if root == "" then
    return fail(_("no folder root given"))
  end
  if prefix ~= "" and is_internal(prefix) then
    return fail(_("refusing to use darktable's internal tags as a prefix"))
  end

  save_settings()

  -- not fatal: an image on an unmounted volume still has a path to read a tag
  -- off, and refusing the whole run over it would be worse than saying so
  if not df.test_file(root, "d") then
    dt.print_log(string.format("%s: note: '%s' is not an existing directory",
      MODULE, root))
  end

  tbfh.running = true
  tbfh.job = nil

  local ok, summary, error_message = pcall(run_once, root, prefix, dry_run)

  -- whatever happened above, the module must not stay latched and the
  -- progress bar must not stay on screen
  if tbfh.job and tbfh.job.valid then
    tbfh.job.valid = false
  end
  tbfh.job = nil
  tbfh.running = false

  if not ok then
    error_message = tostring(summary)
    summary = nil
  end

  if not summary then
    return fail(error_message or _("failed"))
  end

  status_label.label = summary
  dt.print(string.format(_("tag by folder hierarchy: %s"), summary))
  dt.print_log(string.format("%s: %s", MODULE, summary))
end

-- business logic: END

tbfh.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    root_entry.text = ""
    prefix_entry.text = ""
    status_label.label = ""
  end,
  dt.new_widget("label") { label = _("folder root"), halign = "start" },
  root_entry,
  root_chooser,
  dt.new_widget("label") { label = _("tag prefix"), halign = "start" },
  prefix_entry,
  dry_run_box,
  dt.new_widget("button") {
    label = _("tag images"),
    tooltip = _("tag the selected images with the folder they sit in"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not tbfh.module_installed then
    -- 480 puts the module between darktable's own tagging (500) and
    -- geotagging (450) modules, just above "prune flat tags" (475): the right
    -- panel sorts on this number descending, so a higher one sits further up
    dt.register_lib(MODULE, _("tag by folder hierarchy"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 480 }
    }, tbfh.widget, nil, nil)
    tbfh.module_installed = true
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
