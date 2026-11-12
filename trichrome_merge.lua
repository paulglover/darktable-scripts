--[[
  TRICHROME MERGE

  Merges three selected RAW frames (one shot each under red, green and blue
  light) into one linear DNG with the trichrome command-line tool, writes it
  beside the frames and imports it into the library.

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  * trichrome 0.6.0 or later (https://github.com/paulglover/trichrome).
    It is looked for on the PATH and in /opt/homebrew/bin, /usr/local/bin and
    /opt/local/bin, since darktable started from the Dock has none of those on
    its PATH.  A different install can be named with the darktablerc line
    lua/executable_paths/trichrome=/path/to/trichrome

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'trichrome_merge'" to $CONFIGDIR/luarc
  * the module "trichrome merge" appears in the lighttable right panel

  1. select the three frames of one shot.  selection order does not matter:
     trichrome takes them in filename order, red light first.

  2. "merge" writes the DNG into the folder of the first frame (in filename
     order), named by the file name pattern, and imports it.  The pattern
     takes darktable's variables, evaluated against that first frame; a
     trailing .dng is optional.

  NOTES
  * no film ID is given to trichrome, so the DNG carries no XMP identifier.
  * the source frames are never deleted, and an existing file is never
    overwritten.
  * $(IMAGE.ID.NEXT) is darktable's guess at the next image id, the highest id
    in the library plus one.  The library never reuses the id of a removed
    image, so the guess can be low; when the imported DNG gets a different id
    it is renamed to carry the real one.
  * darktable is unresponsive to this module, not to the rest of the ui, while
    trichrome runs; a full resolution merge takes some seconds.

  LICENSE
  LGPLv2+
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local ds = require "lib/dtutils.string"
local dsys = require "lib/dtutils.system"

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

du.check_min_api_version("7.0.0", "trichrome_merge")

local MODULE = "trichrome_merge"

local DEFAULT_PATTERN =
  "$(YEAR)$(MONTH)$(DAY)-$(HOUR)$(MINUTE)$(SECOND)-$(IMAGE.ID.NEXT[6]).dng"

-- darktable started from the Dock or Finder only has /usr/bin:/bin:/usr/sbin:/sbin
-- on its PATH, so check_if_bin_exists misses a Homebrew or MacPorts install
local TRICHROME_DIRS = { "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin" }

local LOG_FILE = dt.configuration.tmp_dir .. "/trichrome_merge.log"

-- stands in for $(IMAGE.ID.NEXT[n]) while darktable substitutes the rest of
-- the pattern, so the id can be filled in again once the real one is known.
-- control characters cannot come out of a substitution or be typed into the
-- entry, so they cannot collide with anything
local ID_OPEN, ID_CLOSE = "\1", "\2"

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("trichrome merge"),
  purpose = _("merge a red/green/blue-light RAW triplet into one linear DNG and import it"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local tm = {}
tm.module_installed = false
tm.running = false

-- helpers: BEGIN

local function shell_quote(str)
  return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local function find_trichrome()
  local trichrome = df.check_if_bin_exists("trichrome")
  if trichrome then return trichrome end
  if dt.configuration.running_os == "windows" then return nil end
  for i = 1, #TRICHROME_DIRS do
    local path = TRICHROME_DIRS[i] .. "/trichrome"
    if df.check_if_file_exists(path) then
      df.set_executable_path_preference("trichrome", path)
      return path
    end
  end
  return nil
end

-- the last non-blank line trichrome wrote: its "error: ..." or "FAILED ..."
local function last_log_line()
  local f = io.open(LOG_FILE, "r")
  if not f then return nil end
  local last
  for line in f:lines() do
    if string.match(line, "%S") then last = line end
  end
  f:close()
  return last
end

local function strip_dng(name)
  if string.lower(string.sub(name, -4)) == ".dng" then
    return string.sub(name, 1, -5)
  end
  return name
end

-- the pattern with its $(IMAGE.ID.NEXT) variables replaced by placeholders
-- holding their padding width ("" when unpadded)
local function hide_next_id(pattern)
  local hidden = string.gsub(pattern, "%$%(IMAGE%.ID%.NEXT%[(%d+)%]%)",
    ID_OPEN .. "%1" .. ID_CLOSE)
  hidden = string.gsub(hidden, "%$%(IMAGE%.ID%.NEXT%)", ID_OPEN .. ID_CLOSE)
  return hidden
end

local function fill_id(template, id)
  local filled = string.gsub(template, ID_OPEN .. "(%d*)" .. ID_CLOSE,
    function(width)
      if width == "" then return tostring(id) end
      return string.format("%0" .. width .. "d", id)
    end)
  return filled
end

-- what darktable's own $(IMAGE.ID.NEXT) evaluates to (lib/dtutils/string.lua)
local function predicted_next_id()
  return dt.database[#dt.database].id + 1
end

local function lower_filename(image)
  return string.lower(image.filename)
end

-- the image as ds.build_substitute_list may safely read it.  that helper reads
-- metadata fields such as image.version_name, but darktable only registers a
-- field for the metadata the user has configured, and reading an unregistered
-- one raises ("field not found for type dt_lua_image_t") rather than giving
-- nil.  the proxy turns that into the nil the helper already copes with, and
-- forwards method calls (image:get_tags()) to the real image
local function substitution_view(image)
  return setmetatable({}, {
    __index = function(proxy, key)
      local ok, value = pcall(function() return image[key] end)
      if not ok then return nil end
      if type(value) == "function" then
        return function(self, ...) return value(image, ...) end
      end
      return value
    end
  })
end

-- helpers: END

-- widgets: BEGIN

local function pattern_read()
  local value = dt.preferences.read(MODULE, "pattern", "string")
  if value == nil or value == "" then return DEFAULT_PATTERN end
  return value
end

local pattern_entry = dt.new_widget("entry") {
  tooltip = _("name of the merged file, without a folder.\nvariables are evaluated against the first frame in filename order.\n\n")
    .. ds.get_substitution_tooltip(),
  placeholder = DEFAULT_PATTERN,
  text = pattern_read(),
  editable = true
}

local status_label = dt.new_widget("label") {
  label = "",
  halign = "start",
  ellipsize = "middle"
}

-- widgets: END

-- business logic: BEGIN

local function fail(message)
  dt.print(string.format(_("trichrome merge: %s"), message))
  dt.print_log(string.format("%s: GAVE UP (%s)", MODULE, message))
  status_label.label = message
end

-- settle everything the merge needs before anything runs.  trichrome is
-- external, so while it works darktable processes ui events and the
-- selection, or the images themselves, can change underneath us
local function plan(pattern)
  local action_images = dt.gui.action_images
  if #action_images ~= 3 then
    return nil, string.format(_("select exactly 3 images, not %d"), #action_images)
  end

  -- trichrome's own order: case-insensitive filename, folder ignored.  the
  -- first frame is the one whose metadata the DNG carries, so it is also the
  -- one the pattern is evaluated against and the folder the DNG goes into
  local frames = {}
  for i = 1, #action_images do frames[i] = action_images[i] end
  table.sort(frames, function(a, b)
    if lower_filename(a) ~= lower_filename(b) then
      return lower_filename(a) < lower_filename(b)
    end
    return a.path < b.path
  end)

  local first = frames[1]
  local template = hide_next_id(pattern)

  ds.clear_substitute_list()
  ds.build_substitute_list(substitution_view(first), 1, template)
  template = strip_dng(ds.substitute_list(template))
  ds.clear_substitute_list()

  local predicted = predicted_next_id()
  local name = fill_id(template, predicted)

  if not string.match(name, "%S") then
    return nil, _("the file name pattern gives an empty name")
  end
  if string.find(name, "/", 1, true) then
    return nil, string.format(_("%s is not a file name, it contains a /"), name)
  end

  local sources = {}
  for i = 1, #frames do
    sources[i] = frames[i].path .. "/" .. frames[i].filename
  end

  local directory = first.path
  local output = directory .. "/" .. name .. ".dng"
  if df.check_if_file_exists(output) then
    return nil, string.format(_("%s already exists"), name .. ".dng")
  end

  return {
    sources = sources,
    directory = directory,
    template = template,
    predicted = predicted,
    name = name,
    output = output
  }
end

-- the imported image carries $(IMAGE.ID.NEXT) as predicted before the import.
-- if the library handed out a different id, rename the file to the real one.
-- returns the image's final filename, and a warning when it could not be fixed
local function fix_id(image, item)
  if image.id == item.predicted then return image.filename end

  local wanted = fill_id(item.template, image.id) .. ".dng"
  if wanted == image.filename then return image.filename end

  if df.check_if_file_exists(item.directory .. "/" .. wanted) then
    return image.filename, string.format(
      _("imported as id %d, but %s already exists so it keeps the name %s"),
      image.id, wanted, image.filename)
  end

  dt.print_log(string.format("%s: id %d predicted, got %d: renaming %s -> %s",
    MODULE, item.predicted, image.id, image.filename, wanted))

  -- move_image raises on failure rather than returning a status; the merge
  -- and import have already succeeded, so a failed rename is a warning only
  local ok, err = pcall(dt.database.move_image, image.film, image, wanted)
  if not ok then
    return image.filename, string.format(
      _("imported as id %d, but renaming it to %s failed: %s"),
      image.id, wanted, tostring(err))
  end
  if image.filename ~= wanted then
    return image.filename, string.format(
      _("imported as id %d, but it could not be renamed to %s"),
      image.id, wanted)
  end
  return image.filename
end

local function merge(item, trichrome)
  local command = shell_quote(trichrome)
    .. " --name " .. shell_quote(item.name)
    .. " --out " .. shell_quote(item.directory)
  for i = 1, #item.sources do
    command = command .. " " .. shell_quote(item.sources[i])
  end
  command = command .. " > " .. shell_quote(LOG_FILE) .. " 2>&1"

  dt.print_log(string.format("%s: %s", MODULE, command))
  local result = dsys.external_command(command)
  if result ~= 0 then
    local reason = last_log_line() or string.format(_("exit %s"), tostring(result))
    return nil, string.format(_("trichrome failed: %s"), reason)
  end
  if not df.check_if_file_exists(item.output) then
    return nil, string.format(_("trichrome reported success but wrote no %s"),
      item.output)
  end

  local image = dt.database.import(item.output)
  if not image then
    return nil, string.format(_("%s was written but could not be imported"),
      item.name .. ".dng")
  end

  local filename, warning = fix_id(image, item)
  pcall(dt.gui.views.lighttable.set_image_visible, image)
  return filename, warning
end

local function run()
  if tm.running then
    dt.print(_("trichrome merge: already running"))
    return
  end

  local pattern = pattern_entry.text
  if not string.match(pattern, "%S") then
    pattern = DEFAULT_PATTERN
    pattern_entry.text = pattern
  end
  dt.preferences.write(MODULE, "pattern", "string", pattern)

  local trichrome = find_trichrome()
  if not trichrome then
    return fail(_("trichrome not found, set lua/executable_paths/trichrome in darktablerc"))
  end

  local item, plan_error = plan(pattern)
  if not item then
    return fail(plan_error)
  end

  tm.running = true
  status_label.label = string.format(_("merging into %s..."), item.name .. ".dng")
  local job = dt.gui.create_job(
    string.format(_("trichrome merge to %s"), item.name .. ".dng"))
  job.percent = 0.0

  -- one failure must not leave the progress bar stranded or the module
  -- marked as running for the rest of the session
  local ok, filename, warning = pcall(merge, item, trichrome)

  if job.valid then
    job.valid = false
  end
  tm.running = false

  if not ok then
    return fail(tostring(filename))
  end
  if not filename then
    return fail(warning)
  end

  local summary = string.format(_("merged and imported %s"), filename)
  if warning then
    summary = summary .. " - " .. warning
  end
  status_label.label = summary
  dt.print(string.format(_("trichrome merge: %s"), summary))
  dt.print_log(string.format("%s: %s", MODULE, summary))
end

-- business logic: END

tm.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    pattern_entry.text = DEFAULT_PATTERN
    dt.preferences.write(MODULE, "pattern", "string", DEFAULT_PATTERN)
    status_label.label = ""
  end,
  dt.new_widget("label") {
    label = _("file name pattern"),
    halign = "start"
  },
  pattern_entry,
  dt.new_widget("button") {
    label = _("merge"),
    tooltip = _("merge the three selected RAW frames into one linear DNG beside them, and import it"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not tm.module_installed then
    dt.register_lib(MODULE, _("trichrome merge"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 465 }
    }, tm.widget, nil, nil)
    tm.module_installed = true
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
