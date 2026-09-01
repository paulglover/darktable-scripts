--[[
  MOVE BY CAPTURE YEAR

  Moves the selected images into per-year folders under a destination root,
  taking the year from each image's EXIF capture date.

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'move_by_capture_year'" to $CONFIGDIR/luarc
  * the module "move by capture year" appears in the lighttable right panel

  1. select the images to move.

  2. choose the destination root, e.g. /Volumes/Photos.

  3. an image captured on 2025:06:14 is moved to

        <destination root>/2025/

     an image already sitting in that folder is left alone and counted as
     "already in place", so a re-run over a part-migrated selection is safe.

  4. "dry run" reports what would happen without touching anything.  The
     detailed per-image report always goes to the darktable log (start
     darktable with -d lua to see it on the console).

  NOTES
  * only the EXIF capture date is consulted.  an image with no capture date,
    or with a date that cannot be a photograph, is skipped rather than
    guessed at: a wrong year folder is silently wrong, a skip is not.  fix
    the date with darktable's own "image time" module and run again.
  * an image is skipped when another file of the same name already sits in
    the destination, or when its file is missing.
  * duplicates share one file on disk, so two duplicates whose capture dates
    fall in different years are reported as a conflict and left alone.
  * tags are never touched, and darktable moves the XMP sidecar along with
    the image.

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

du.check_min_api_version("7.0.0", "move_by_capture_year")

local MODULE = "move_by_capture_year"
local PS = dt.configuration.running_os == "windows" and "\\" or "/"

-- the oldest year that can hold a photograph.  a camera whose clock has been
-- reset reports 1970, and darktable reports a missing exif date as an all-zero
-- timestamp; either would otherwise create a junk film roll
local EARLIEST_YEAR = 1826

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("move by capture year"),
  purpose = _("move the selected images into per-year folders under a destination root"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local mbcy = {}
mbcy.module_installed = false
mbcy.running = false

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

-- darktable formats the capture date as "YYYY:MM:DD hh:mm:ss", with
-- milliseconds appended since api 9.1.0 -- see exiftime2systime() in the
-- bundled lib/dtutils/string.lua.  a "-" separator is accepted as well
-- purely defensively; only the colon form has been confirmed here.
--
-- returns the year as a string, or nil plus the reason it is unusable
local function capture_year(image)
  local taken = image.exif_datetime_taken
  if taken == nil or taken == "" then
    return nil, _("no capture date")
  end

  local year = string.match(taken, "^%s*(%d%d%d%d)[:%-]%d%d[:%-]%d%d")
  if not year then
    return nil, string.format(_("unreadable capture date '%s'"), tostring(taken))
  end

  local number = tonumber(year)
  if number < EARLIEST_YEAR or number > tonumber(os.date("%Y")) + 1 then
    return nil, string.format(_("implausible capture year %s"), year)
  end

  return year
end

-- helpers: END

-- widgets: BEGIN

-- editable is set explicitly: the entry widgets that other scripts type into
-- do the same rather than relying on the default
local destination_entry = dt.new_widget("entry") {
  text = pref_read("destination", ""),
  placeholder = _("e.g. /Volumes/Photos"),
  editable = true,
  is_password = false,
  tooltip = _("root directory the year folders are created in\nuse the button below to pick it")
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

local dry_run_box = dt.new_widget("check_button") {
  label = _("dry run"),
  tooltip = _("report what would be done without moving anything"),
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
  pref_write("destination", destination_entry.text)
  bool_write("dry_run", dry_run_box.value)
end

-- logged as well as shown: a run that gives up has already written its header
-- to the log, and a header with no conclusion under -d lua says nothing about
-- why the run stopped
local function fail(message)
  dt.print(string.format(_("move by capture year: %s"), message))
  dt.print_log(string.format("%s: GAVE UP (%s)", MODULE, message))
  status_label.label = message
end

-- build the work list: one entry per image, or a skip reason.  everything is
-- resolved before the first move, so the loop below only has effects to apply
local function plan(destination_root)
  local action_images = dt.gui.action_images
  if #action_images == 0 then
    return nil, _("no images selected")
  end

  local work, skipped = {}, {}
  local by_file = {}

  for i = 1, #action_images do
    local image = action_images[i]
    local source = image_path(image)
    local year, reason = capture_year(image)

    if not year then
      skipped[#skipped + 1] = { source = source, reason = reason }
    elseif not df.check_if_file_exists(source) then
      skipped[#skipped + 1] = { source = source, reason = _("file not found") }
    else
      local directory = destination_root .. PS .. year

      local item = {
        image = image,
        source = source,
        year = year,
        directory = directory,
        target = directory .. PS .. image.filename
      }

      -- duplicates share one file on disk: two destinations is a conflict.
      -- their capture dates are separate database rows and can be edited
      -- apart, so this is reachable
      local seen = by_file[source]
      if seen then
        if not same_path(seen.directory, directory) then
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
        reason = _("duplicates of this file were captured in different years")
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
  if mbcy.running then
    dt.print(_("move by capture year: already running"))
    return
  end

  local destination_root = strip_trailing_separator(trim(destination_entry.text))

  if destination_root == "" then
    return fail(_("no destination given"))
  end

  local dry_run = dry_run_box.value

  save_settings()

  -- checked on dry runs too: reporting a clean plan against a destination that
  -- does not exist defeats the point of the dry run
  if not df.test_file(destination_root, "d") then
    return fail(string.format(_("destination is not a directory: %s"), destination_root))
  end

  local plan_result, error_message = plan(destination_root)
  if not plan_result then
    return fail(error_message)
  end

  local work, plan_skips = plan_result.work, plan_result.skipped

  -- logged before the run can give up below: a run with nothing to move is
  -- exactly the one whose reasons the user needs to read
  for i = 1, #plan_skips do
    dt.print_log(string.format("%s: SKIPPED (%s): %s",
      MODULE, plan_skips[i].reason, plan_skips[i].source))
  end

  if #work == 0 then
    return fail(string.format(_("nothing to move, %d skipped"), #plan_skips))
  end

  mbcy.running = true

  local job = dt.gui.create_job(
    string.format(dry_run and _("move by capture year (dry run, %d images)")
                          or _("move by capture year (%d images)"), #work),
    true, stop_move)
  job.percent = 0.0

  local films = {}
  local moved, in_place, skipped, failed = 0, 0, #plan_skips, 0
  local cancelled = false

  dt.print_log(string.format("%s: %s %d images -> %s", MODULE,
    dry_run and "dry run over" or "moving", #work, destination_root))

  local function process_item(item)
    local image = item.image
    local current_directory = strip_trailing_separator(image.path)

    if same_path(current_directory, item.directory) then
      in_place = in_place + 1
      dt.print_log(string.format("%s: already in place: %s", MODULE, item.source))
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
          -- move_image raises on failure rather than returning a status, so
          -- the move is confirmed against the image's own path
          if same_path(strip_trailing_separator(image.path), item.directory) then
            moved = moved + 1
            dt.print_log(string.format("%s: moved: %s -> %s",
              MODULE, item.source, item.target))
          else
            failed = failed + 1
            dt.print_log(string.format("%s: FAILED (move): %s -> %s",
              MODULE, item.source, item.target))
          end
        end
      end
    end
  end

  for index = 1, #work do
    if not job.valid then
      cancelled = true
      break
    end

    -- dt.database.move_image() raises rather than returning a status, and
    -- df.mkdir() yields, so an image can disappear from the library while we
    -- work.  one bad image must not abort the run, strand the progress bar or
    -- leave the module marked as running for the rest of the session
    local ok, item_error = pcall(process_item, work[index])
    if not ok then
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (%s): %s",
        MODULE, tostring(item_error), work[index].source))
    end

    if job.valid then
      job.percent = index / #work
    end
  end

  -- cancelling already destroyed the job
  if job.valid then
    job.valid = false
  end
  mbcy.running = false

  local summary
  if dry_run then
    summary = string.format(_("dry run: %d to move, %d already in place, %d skipped, %d failed"),
      moved, in_place, skipped, failed)
  else
    summary = string.format(_("moved %d, %d already in place, %d skipped, %d failed"),
      moved, in_place, skipped, failed)
  end
  if cancelled then
    summary = string.format(_("cancelled - %s"), summary)
  end

  status_label.label = summary
  dt.print(string.format(_("move by capture year: %s"), summary))
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

mbcy.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    destination_entry.text = ""
    status_label.label = ""
  end,
  dt.new_widget("label") { label = _("destination root"), halign = "start" },
  destination_entry,
  destination_chooser,
  dry_run_box,
  dt.new_widget("button") {
    label = _("move images"),
    tooltip = _("move the selected images into <destination root>/<capture year>"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not mbcy.module_installed then
    dt.register_lib(MODULE, _("move by capture year"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 690 }
    }, mbcy.widget, nil, nil)
    mbcy.module_installed = true
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
