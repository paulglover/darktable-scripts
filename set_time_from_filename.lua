--[[
  SET TIME FROM FILENAME

  Sets the capture date of the selected images from a date encoded in their
  filename, for scans and exports that carry no usable EXIF date.

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'set_time_from_filename'" to $CONFIGDIR/luarc
  * the module "set capture time from filename" appears in the lighttable
    right panel

  1. select the images.

  2. "dry run" reports what would happen without changing anything.  The
     detailed per-image report always goes to the darktable log (start
     darktable with -d lua to see it on the console).

  3. "only images with no capture date" leaves images that already have a
     date alone.  On by default: overwriting a date darktable read from the
     file itself is the destructive case, and cannot be undone from here.

  THE FILENAME IS READ AS
  * the first run of eight or more digits, whose first eight are YYYYMMDD:

      P20260104-02.jpg          -> 2026:01:04 00:00:00
      i2026022401.jpg           -> 2026:02:24 00:00:00   (trailing 01 is a
                                                          sequence number)
  * optionally a six digit HHMMSS immediately after it, either glued on or
    separated by one non-digit:

      20240415_115416_IMG.jpg   -> 2024:04:15 11:54:16

  An image whose filename holds no plausible date is skipped.  The date must
  be a real calendar date in a year a photograph could have been taken in, so
  a hash or a serial number does not turn into one by accident.

  NOTES
  * this changes the database, and the XMP sidecar if darktable is writing
    them.  it does not rewrite the EXIF inside the image file.
  * the same value is set by darktable's own "image time" module, which is
    the better tool when one date applies to the whole selection.

  LICENSE
  LGPLv2+
]]

local dt = require "darktable"
local du = require "lib/dtutils"

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

du.check_min_api_version("7.0.0", "set_time_from_filename")

local MODULE = "set_time_from_filename"

-- the oldest year that can hold a photograph.  without a floor, an eight
-- digit serial number becomes a date in year 0000
local EARLIEST_YEAR = 1826

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("set capture time from filename"),
  purpose = _("set the capture date of scans from a date encoded in their filename"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local sttf = {}
sttf.module_installed = false
sttf.running = false

-- helpers: BEGIN

-- settings are stored as strings rather than with the "bool" preference
-- type: an unregistered typed preference that has never been written reads
-- back as false, which would silently turn "dry run" off on a fresh install.
-- a string tells "never set" and "set to false" apart.
local function bool_read(key, default)
  local value = dt.preferences.read(MODULE, key, "string")
  if value == "true" then return true end
  if value == "false" then return false end
  return default
end

local function bool_write(key, value)
  dt.preferences.write(MODULE, key, "string", value and "true" or "false")
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(year, month)
  if month == 2 and year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
    return 29
  end
  return DAYS_IN_MONTH[month]
end

-- os.time() is not used to validate: it returns nil for a pre-1970 date on
-- most platforms, which is exactly the scanned-photograph case this module
-- exists for
local function valid_date(year, month, day)
  if year < EARLIEST_YEAR or year > tonumber(os.date("%Y")) + 1 then
    return false
  end
  if month < 1 or month > 12 then return false end
  return day >= 1 and day <= days_in_month(year, month)
end

local function valid_time(hour, minute, second)
  return hour < 24 and minute < 60 and second < 60
end

-- read a capture date out of a filename.  returns darktable's
-- "YYYY:MM:DD hh:mm:ss", or nil plus the reason there is none
local function parse_datetime(filename)
  local position = 1

  while true do
    local first, last = string.find(filename, "%d+", position)
    if not first then break end

    local run = string.sub(filename, first, last)
    if #run >= 8 then
      local year = tonumber(string.sub(run, 1, 4))
      local month = tonumber(string.sub(run, 5, 6))
      local day = tonumber(string.sub(run, 7, 8))

      if valid_date(year, month, day) then
        local hour, minute, second = 0, 0, 0

        -- the time is either glued to the date in one long run, or follows
        -- it after a single separator.  a run of 9 to 13 digits is a date
        -- with a sequence number stuck to it, not a time
        local clock
        if #run >= 14 then
          clock = string.sub(run, 9, 14)
        elseif #run == 8 then
          local tail = string.match(filename, "^%D(%d%d%d%d%d%d)", last + 1)
          -- a longer run would be something else that merely starts with six
          -- digits, so only an exact six count as a time
          local following = string.match(filename, "^%D(%d+)", last + 1)
          if tail and following and #following == 6 then
            clock = tail
          end
        end

        if clock then
          local h = tonumber(string.sub(clock, 1, 2))
          local m = tonumber(string.sub(clock, 3, 4))
          local s = tonumber(string.sub(clock, 5, 6))
          if valid_time(h, m, s) then
            hour, minute, second = h, m, s
          end
        end

        return string.format("%04d:%02d:%02d %02d:%02d:%02d",
          year, month, day, hour, minute, second)
      end
    end

    position = last + 1
  end

  return nil, _("no date in the filename")
end

-- helpers: END

-- widgets: BEGIN

local only_undated_box = dt.new_widget("check_button") {
  label = _("only images with no capture date"),
  tooltip = _("leave images that already have a capture date alone.\non by default: overwriting a date darktable read from the\nfile itself cannot be undone from here"),
  value = bool_read("only_undated", true)
}

local dry_run_box = dt.new_widget("check_button") {
  label = _("dry run"),
  tooltip = _("report what would be set without changing anything"),
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
  bool_write("only_undated", only_undated_box.value)
  bool_write("dry_run", dry_run_box.value)
end

-- logged as well as shown: a run that gives up has already written its header
-- to the log, and a header with no conclusion under -d lua says nothing about
-- why the run stopped
local function fail(message)
  dt.print(string.format(_("set capture time from filename: %s"), message))
  dt.print_log(string.format("%s: GAVE UP (%s)", MODULE, message))
  status_label.label = message
end

-- build the work list before anything is written, so the loop below only has
-- effects to apply
local function plan(only_undated)
  local action_images = dt.gui.action_images
  if #action_images == 0 then
    return nil, _("no images selected")
  end

  local work, skipped = {}, {}

  for i = 1, #action_images do
    local image = action_images[i]
    local current = image.exif_datetime_taken
    if current == nil then current = "" end

    local wanted, reason = parse_datetime(image.filename)

    if not wanted then
      skipped[#skipped + 1] = { filename = image.filename, reason = reason }
    elseif current ~= "" and only_undated then
      skipped[#skipped + 1] = {
        filename = image.filename,
        reason = string.format(_("already dated %s"), current)
      }
    else
      work[#work + 1] = {
        image = image,
        filename = image.filename,
        current = current,
        wanted = wanted
      }
    end
  end

  return { work = work, skipped = skipped }
end

local function stop_run(job)
  job.valid = false
end

local function run()
  if sttf.running then
    dt.print(_("set capture time from filename: already running"))
    return
  end

  local dry_run = dry_run_box.value
  local only_undated = only_undated_box.value

  save_settings()

  local plan_result, error_message = plan(only_undated)
  if not plan_result then
    return fail(error_message)
  end

  local work, plan_skips = plan_result.work, plan_result.skipped

  -- logged before the run can give up below: a run with nothing to set is
  -- exactly the one whose reasons the user needs to read
  for i = 1, #plan_skips do
    dt.print_log(string.format("%s: SKIPPED (%s): %s",
      MODULE, plan_skips[i].reason, plan_skips[i].filename))
  end

  if #work == 0 then
    return fail(string.format(_("nothing to set, %d skipped"), #plan_skips))
  end

  sttf.running = true

  local job = dt.gui.create_job(
    string.format(dry_run and _("set capture time (dry run, %d images)")
                          or _("set capture time (%d images)"), #work),
    true, stop_run)
  job.percent = 0.0

  local set, unchanged, failed = 0, 0, 0
  local skipped = #plan_skips
  local cancelled = false

  dt.print_log(string.format("%s: %s %d images", MODULE,
    dry_run and "dry run over" or "setting", #work))

  local function process_item(item)
    local was = item.current == "" and "(none)" or item.current

    if item.current == item.wanted then
      unchanged = unchanged + 1
      dt.print_log(string.format("%s: already correct: %s = %s",
        MODULE, item.filename, item.wanted))
    elseif dry_run then
      set = set + 1
      dt.print_log(string.format("%s: would set: %s: %s -> %s",
        MODULE, item.filename, was, item.wanted))
    else
      item.image.exif_datetime_taken = item.wanted
      -- read back rather than trusting the assignment: a write that reports
      -- success while changing nothing must not be counted as a date set
      local now = item.image.exif_datetime_taken
      if now == item.wanted then
        set = set + 1
        dt.print_log(string.format("%s: set: %s: %s -> %s",
          MODULE, item.filename, was, item.wanted))
      else
        failed = failed + 1
        dt.print_log(string.format("%s: FAILED (reads back as %s): %s -> %s",
          MODULE, tostring(now), item.filename, item.wanted))
      end
    end
  end

  for index = 1, #work do
    if not job.valid then
      cancelled = true
      break
    end

    -- darktable can process ui events mid-loop, so an image can disappear
    -- from the library while we work.  one bad image must not abort the run,
    -- strand the progress bar or leave the module marked as running for the
    -- rest of the session
    local ok, item_error = pcall(process_item, work[index])
    if not ok then
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (%s): %s",
        MODULE, tostring(item_error), work[index].filename))
    end

    if job.valid then
      job.percent = index / #work
    end
  end

  -- cancelling already destroyed the job
  if job.valid then
    job.valid = false
  end
  sttf.running = false

  local summary
  if dry_run then
    summary = string.format(_("dry run: %d to set, %d already correct, %d skipped, %d failed"),
      set, unchanged, skipped, failed)
  else
    summary = string.format(_("set %d, %d already correct, %d skipped, %d failed"),
      set, unchanged, skipped, failed)
  end
  if cancelled then
    summary = string.format(_("cancelled - %s"), summary)
  end

  status_label.label = summary
  dt.print(string.format(_("set capture time from filename: %s"), summary))
  dt.print_log(string.format("%s: %s", MODULE, summary))
end

-- business logic: END

sttf.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    status_label.label = ""
  end,
  only_undated_box,
  dry_run_box,
  dt.new_widget("button") {
    label = _("set capture time"),
    tooltip = _("read a date out of each selected image's filename and set it as the capture date"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not sttf.module_installed then
    dt.register_lib(MODULE, _("set capture time from filename"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 470 }
    }, sttf.widget, nil, nil)
    sttf.module_installed = true
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
