--[[
  Richardson-Lucy output sharpening for darktable using GMic

  darktable is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  darktable is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with darktable.  If not, see <http://www.gnu.org/licenses/>.
]]

--[[
  DESCRIPTION
    RL_out_sharp.lua - Richardson-Lucy output sharpening using GMic

    This script provides a new target storage "RL output sharpen".
    Images exported will be sharpened using GMic (RL deblur algorithm)

    It also adds an "RL output sharpening" module to the lighttable.  When
    "sharpen file on disk exports" is enabled there, every image exported
    with the regular "file on disk" storage is sharpened in place, so the
    full darktable variable syntax can be used for the output path and name.

  REQUIRED SOFTWARE
  GMic command line interface (CLI) https://gmic.eu/download.shtml

  USAGE
    * require this script from main lua file
    * in lua preferences, select the GMic cli executable
    * configure RL parameters with the sliders in the "RL output sharpening"
      lighttable module
    * either
      - from "export selected", choose "RL output sharpen"
      - configure output folder and jpg quality
      - configure temp files format and quality, jpg 8bpp (good quality)
        and tif 16bpp (best quality) are supported
      - sharpened images will be stored in jpg format in the output folder
    * or
      - enable "sharpen file on disk exports" in the lighttable module
      - export with "file on disk" as usual; jpg and tif (8/16/32 bit) files
        are sharpened in place, keeping their format, quality and metadata

  EXAMPLE
    set sigma = 0.7, iterations = 10, jpeg output quality = 95,
    to correct blur due to image resize for web usage

  CAVEATS
    GMic is only run on temporary files with plain names, so file names
    containing spaces or commas are fine.
    Metadata (including the ICC profile) is copied back with exiftool if it
    is installed; without it the sharpened files have no metadata.

  BUGS, COMMENTS, SUGGESTIONS
    send to Marco Carrarini, marco.carrarini@gmail.com

  CHANGES
    * 20200308 - initial version
    * 20260921 - Paul Glover (paul@paulglover.net)
      - sharpen "file on disk" exports in place, so the export's own file
        name template, format, quality and metadata are kept
      - per export preset settings, matched by the preset's path template
      - "RL output sharpening" lighttable module next to the export module
      - gmic only sees plain temp file names; spaces and commas in paths work
      - ICC profile copied back with the metadata
      - errors say what went wrong and point to RL_out_sharp.log
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dtsys = require "lib/dtutils.system"

-- module name
local MODULE_NAME = "RL_out_sharp"

-- check API version
du.check_min_api_version("7.0.0", MODULE_NAME)

-- translation
local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
  end

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("RL output sharpening"),
  purpose = _("Richardson-Lucy output sharpening using GMic"),
  author = "Marco Carrarini <marco.carrarini@gmail.com>",
  help = "https://docs.darktable.org/lua/stable/lua.scripts.manual/scripts/contrib/RL_out_sharp"
}

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them

-- OS compatibility
local PS = dt.configuration.running_os == "windows" and  "\\"  or  "/"

local LOG_FILE = dt.configuration.tmp_dir .. PS .. "RL_out_sharp.log"

-- initialize module preferences
if not dt.preferences.read(MODULE_NAME, "initialized", "bool") then
  dt.preferences.write(MODULE_NAME, "sigma", "string", "0.7")
  dt.preferences.write(MODULE_NAME, "iterations", "string", "10")
  dt.preferences.write(MODULE_NAME, "jpg_quality", "string", "95")
  dt.preferences.write(MODULE_NAME, "initialized", "bool", true)
end

-- widgets are created below, the functions only use them at export time
local sigma_slider, iterations_slider, jpg_quality_slider
local output_folder_selector, disk_enable, storage_widget, entry_combo

-- per export preset settings -------------------------------------------------
-- "file on disk" exports are matched to an export preset by their path
-- template.  Exports that match no preset, and the "RL output sharpen"
-- storage, use the default settings.  A preset uses the default settings
-- until it is changed in the module.
local DEFAULT_ENTRY = _("default (other exports)")

local presets = {}            -- ordered list of {name = , template = }
local template_preset = {}    -- template -> preset name
local current_entry = DEFAULT_ENTRY

local function pref_key(entry, name)
  if entry == DEFAULT_ENTRY then
    return name
    end
  return "preset_" .. string.gsub(entry, "[^%w]", "_") .. "_" .. name
  end

local function get_settings(entry)
  if entry ~= DEFAULT_ENTRY and not dt.preferences.read(MODULE_NAME, pref_key(entry, "initialized"), "bool") then
    entry = DEFAULT_ENTRY
    end
  return {
    enabled = dt.preferences.read(MODULE_NAME, pref_key(entry, "disk_enabled"), "bool"),
    sigma = tonumber(dt.preferences.read(MODULE_NAME, pref_key(entry, "sigma"), "string")) or 0.7,
    iterations = tonumber(dt.preferences.read(MODULE_NAME, pref_key(entry, "iterations"), "string")) or 10,
    }
  end

local function save_settings(entry, settings)
  dt.preferences.write(MODULE_NAME, pref_key(entry, "disk_enabled"), "bool", settings.enabled)
  dt.preferences.write(MODULE_NAME, pref_key(entry, "sigma"), "string",
    (string.gsub(string.format("%.2f", settings.sigma), ",", ".")))
  dt.preferences.write(MODULE_NAME, pref_key(entry, "iterations"), "string", string.format("%.0f", settings.iterations))
  if entry ~= DEFAULT_ENTRY then
    dt.preferences.write(MODULE_NAME, pref_key(entry, "initialized"), "bool", true)
    end
  end

-- read the user's export presets and their "file on disk" path templates
-- from data.db.  The template is the last string in the preset's params,
-- after the storage name.
local function load_presets()
  local db = dt.configuration.config_dir .. PS .. "data.db"
  local sqlite = df.check_if_file_exists("/usr/bin/sqlite3") and "/usr/bin/sqlite3" or "sqlite3"
  local p = io.popen(sqlite .. " -readonly " .. df.sanitize_filename(db) ..
    " \"select name, hex(op_params) from presets where operation = 'export' and writeprotect = 0 order by name\" 2>/dev/null")
  if not p then return end

  local new_presets, new_map = {}, {}
  for line in p:lines() do
    local name, hex = string.match(line, "^(.*)|(%x*)$")
    if name then
      local blob = string.gsub(hex, "%x%x", function(h) return string.char(tonumber(h, 16)) end)
      local s = string.find(blob, "\0disk\0", 1, true)
      if s then
        local template
        for str in string.gmatch(string.sub(blob, s + 6), "[\32-\126\128-\255]+") do
          if #str > 1 then template = str end
          end
        if template then
          table.insert(new_presets, {name = name, template = template})
          new_map[template] = name
          end
        end
      end
    end
  p:close()

  if #new_presets > 0 then
    presets, template_preset = new_presets, new_map
    end
  end

-- return the quoted GMic executable, or nil with a message ------------------
local function get_gmic()
  local gmic = dt.preferences.read(MODULE_NAME, "gmic_exe", "string")
  if gmic == "" then
    dt.print(_("RL output sharpen: GMic executable not configured, set it in preferences > lua options"))
    return nil
    end
  if not df.check_if_file_exists(gmic) then
    dt.print(string.format(_("RL output sharpen: GMic executable %s not found"), gmic))
    return nil
    end
  return df.sanitize_filename(gmic)
  end

-- binary file copy, works across volumes ------------------------------------
local function copy_file(from, to)
  local fin = io.open(from, "rb")
  if not fin then return false end
  local fout = io.open(to, "wb")
  if not fout then fin:close() return false end
  while true do
    local block = fin:read(1024 * 1024)
    if not block then break end
    fout:write(block)
    end
  fin:close()
  fout:close()
  return true
  end

-- preserve original image metadata in the output image -----------------------
local function preserve_metadata(original, sharpened)
  local exiftool = df.check_if_bin_exists("exiftool")

  if exiftool then
    dtsys.external_command(df.sanitize_filename(exiftool) ..
      " -q -overwrite_original -tagsFromFile " .. df.sanitize_filename(original) ..
      " -all:all -icc_profile " .. df.sanitize_filename(sharpened) ..
      " >> " .. df.sanitize_filename(LOG_FILE) .. " 2>&1")
  else
    dt.print_log(MODULE_NAME .. " exiftool not found,  metadata not preserved")
  end
end

-- sharpen input into output ----------------------------------------------------
--   options      gmic commands run after the deblur
--   out_ext      extension (and so format) of the file gmic writes
--   out_options  gmic output options, e.g. ",95" or ",uint16,lzw"
-- GMic only sees plain temp file names, since it splits its output
-- argument on commas.  Returns true, or false and an error message.
local function sharpen(gmic, settings, id, input, output, options, out_ext, out_options)
  local sigma_str = string.gsub(string.format("%.2f", settings.sigma), ",", ".")
  local iterations_str = string.format("%.0f", settings.iterations)

  local tmp_in = dt.configuration.tmp_dir .. PS .. "RL_out_sharp_" .. id .. "_in." .. df.get_filetype(input)
  local tmp_out = dt.configuration.tmp_dir .. PS .. "RL_out_sharp_" .. id .. "_out." .. out_ext

  if not copy_file(input, tmp_in) then
    return false, string.format(_("can't read %s"), input)
    end

  local run_cmd = gmic .. " " .. df.sanitize_filename(tmp_in) ..
    " -deblur_richardsonlucy " .. sigma_str .. "," .. iterations_str .. ",1" ..
    options .. " o " .. df.sanitize_filename(tmp_out) .. out_options
  dt.print_log(MODULE_NAME .. ": " .. run_cmd)

  local result = dtsys.external_command(run_cmd .. " > " .. df.sanitize_filename(LOG_FILE) .. " 2>&1")
  if result ~= 0 then
    dt.print_error(MODULE_NAME .. ": command failed: " .. run_cmd)
    os.remove(tmp_in)
    os.remove(tmp_out)
    return false, string.format(_("gmic failed (exit %s), see %s"), tostring(result), LOG_FILE)
    end

  preserve_metadata(tmp_in, tmp_out)

  local ok = copy_file(tmp_out, output)
  os.remove(tmp_in)
  os.remove(tmp_out)
  if not ok then
    return false, string.format(_("can't write %s"), output)
    end
  return true
  end

-- temp export formats: jpg and tif are supported -----------------------------
local function supported(storage, img_format)
  return (img_format.extension == "jpg") or (img_format.extension == "tif")
  end


-- export and sharpen images --------------------------------------------------
local function export2RL(storage, image_table, extra_data)

  local function cleanup()
    for _k, temp_name in pairs(image_table) do os.remove(temp_name) end
    end

  local gmic = get_gmic()
  if not gmic then cleanup() return end

  local output_folder = output_folder_selector.value
  if not output_folder or output_folder == "" then
    dt.print(_("RL output sharpen: no output folder selected, choose one in the export module"))
    dt.print_error(MODULE_NAME .. ": output folder not set")
    cleanup()
    return
    end
  if not df.check_if_file_exists(output_folder) then
    dt.print(string.format(_("RL output sharpen: output folder %s does not exist"), output_folder))
    dt.print_error(MODULE_NAME .. ": output folder does not exist: " .. output_folder)
    cleanup()
    return
    end

  local jpg_quality_str = string.format("%.0f", jpg_quality_slider.value)
  local settings = get_settings(DEFAULT_ENTRY)

  local i = 0
  for image, temp_name in pairs(image_table) do

    i = i + 1
    dt.print(string.format(_("sharpening image %d ..."), i))
    -- create unique filename
    local new_name = df.create_unique_filename(output_folder .. PS .. df.get_basename(temp_name) .. ".jpg")

    local options = " cut 0,255 round"
    if df.get_filetype(temp_name) == "tif" then options = " -/ 256" .. options end

    local ok, err = sharpen(gmic, settings, image.id, temp_name, new_name, options, "jpg", "," .. jpg_quality_str)
    if not ok then
      dt.print(_("RL output sharpen: ") .. err)
      cleanup()
      return
    end

    -- delete temp image
    os.remove(temp_name)

    end

  dt.print(_("finished exporting"))
  end

-- sharpen "file on disk" exports in place ------------------------------------
local function sharpen_disk_export(event, image, filename, format, storage)
  if not storage or storage.plugin_name ~= "disk" then return end

  -- this runs in the export thread, so only data is updated here, not widgets
  local template = storage.filename
  local entry = template and template_preset[template]
  if template and not entry then
    load_presets()
    entry = template_preset[template]
    end
  entry = entry or DEFAULT_ENTRY
  local settings = get_settings(entry)
  if not settings.enabled then return end

  local ext = string.lower(format.extension)
  local options, out_options
  if ext == "jpg" then
    options = " cut 0,255 round"
    out_options = string.format(",%.0f", format.quality)
  elseif ext == "tif" and format.bpp == 8 then
    options = " cut 0,255 round"
    out_options = ",uint8,lzw"
  elseif ext == "tif" and format.bpp == 16 then
    options = " cut 0,65535 round"
    out_options = ",uint16,lzw"
  elseif ext == "tif" then
    options = ""
    out_options = ",float32,lzw"
  else
    dt.print(string.format(_("RL output sharpen: %s files are not supported, %s not sharpened"),
      ext, df.get_filename(filename)))
    return
    end

  local gmic = get_gmic()
  if not gmic then return end

  dt.print(string.format(_("sharpening %s (%s) ..."), df.get_filename(filename), entry))
  local ok, err = sharpen(gmic, settings, image.id, filename, filename, options, ext, out_options)
  if not ok then
    dt.print(_("RL output sharpen: ") .. err)
    end
  end

-- script_manager integration

local function destroy()
  dt.destroy_storage("exp2RL")
  dt.destroy_event(MODULE_NAME, "intermediate-export-image")
  if dt.gui.libs[MODULE_NAME] then dt.gui.libs[MODULE_NAME].visible = false end
end

local function restart()
  dt.register_storage("exp2RL", _("RL output sharpen"), nil, export2RL, supported, nil, storage_widget)
  dt.register_event(MODULE_NAME, "intermediate-export-image", sharpen_disk_export)
  if dt.gui.libs[MODULE_NAME] then dt.gui.libs[MODULE_NAME].visible = true end
end

-- new widgets ----------------------------------------------------------------

output_folder_selector = dt.new_widget("file_chooser_button"){
  title = _("select output folder"),
  tooltip = _("select output folder"),
  value = dt.preferences.read(MODULE_NAME, "output_folder", "string"),
  is_directory = true,
  changed_callback = function(self)
    dt.preferences.write(MODULE_NAME, "output_folder", "string", self.value)
    end
  }

sigma_slider = dt.new_widget("slider"){
  label = _("sigma"),
  tooltip = _("controls the width of the blur that's applied"),
  soft_min = 0.3,
  soft_max = 2.0,
  hard_min = 0.0,
  hard_max = 3.0,
  step = 0.05,
  digits = 2,
  value = 1.0
  }

iterations_slider = dt.new_widget("slider"){
  label = _("iterations"),
  tooltip = _("increase for better sharpening, but slower"),
  soft_min = 0,
  soft_max = 100,
  hard_min = 0,
  hard_max = 100,
  step = 5,
  digits = 0,
  value = 10.0
  }

jpg_quality_slider = dt.new_widget("slider"){
  label = _("output jpg quality"),
  tooltip = _("quality of the output jpg file"),
  soft_min = 70,
  soft_max = 100,
  hard_min = 70,
  hard_max = 100,
  step = 2,
  digits = 0,
  value = 95.0
  }

disk_enable = dt.new_widget("check_button"){
  label = _("sharpen file on disk exports"),
  tooltip = _("sharpen images exported with the \"file on disk\" storage in place,\n" ..
              "using its file name template, format and quality"),
  }

local loading = false   -- true while widgets are being filled in from the settings

local function save_current()
  if loading then return end
  save_settings(current_entry, {
    enabled = disk_enable.value,
    sigma = sigma_slider.value,
    iterations = iterations_slider.value,
    })
  end

local function show_entry(entry)
  current_entry = entry
  local settings = get_settings(entry)
  loading = true
  disk_enable.value = settings.enabled
  sigma_slider.value = settings.sigma
  iterations_slider.value = settings.iterations
  loading = false

  local tooltip = _("exports are matched to a preset by the path template of \"file on disk\"")
  for _k, preset in ipairs(presets) do
    if preset.name == entry then
      tooltip = tooltip .. "\n\n" .. preset.template
      if not dt.preferences.read(MODULE_NAME, pref_key(entry, "initialized"), "bool") then
        tooltip = tooltip .. "\n\n" .. _("using the default settings until changed here")
        end
      end
    end
  entry_combo.tooltip = tooltip
  end

-- fill the combobox with the current export presets
local function refresh_entries()
  load_presets()
  local selected = current_entry
  loading = true
  for i = #entry_combo, 1, -1 do entry_combo[i] = nil end
  entry_combo[1] = DEFAULT_ENTRY
  local index = 1
  for i, preset in ipairs(presets) do
    entry_combo[i + 1] = preset.name
    if preset.name == selected then index = i + 1 end
    end
  entry_combo.value = index
  loading = false
  show_entry(entry_combo.value)
  end

entry_combo = dt.new_widget("combobox"){
  label = _("settings for"),
  changed_callback = function(self)
    if not loading then show_entry(self.value) end
    end,
  DEFAULT_ENTRY
  }

disk_enable.clicked_callback = save_current

storage_widget = dt.new_widget("box"){
  orientation = "vertical",
  output_folder_selector,
  jpg_quality_slider,
  dt.new_widget("label"){label = _("sigma and iterations are the default settings of the RL output sharpening module")}
  }

local lib_widget = dt.new_widget("box"){
  orientation = "vertical",
  entry_combo,
  disk_enable,
  sigma_slider,
  iterations_slider,
  }

-- register new storage -------------------------------------------------------
dt.register_storage("exp2RL", _("RL output sharpen"), nil, export2RL, supported, nil, storage_widget)

-- register the lighttable module, just above the export module ----------------
local module_installed = false

local function install_module()
  if module_installed then return end
  -- the right panel sorts on position descending, so one more than the
  -- export module sits directly above it
  local ok, export_position = pcall(function() return dt.gui.libs.export.position end)
  if not ok or type(export_position) ~= "number" then export_position = 0 end

  dt.register_lib(
    MODULE_NAME,
    _("RL output sharpening"),
    true,
    false,
    {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", export_position + 1}},
    lib_widget,
    function(self, old_view, new_view) refresh_entries() end,
    nil
    )
  module_installed = true
  end

-- darktable_gui_safe is set by darktable's own luarc once gui initialization
-- has finished; registering a lib before that hangs darktable (issue #19197)
if dt.gui.current_view().id == "lighttable" and darktable_gui_safe then
  install_module()
else
  dt.register_event(MODULE_NAME, "view-changed",
    function(event, old_view, new_view)
      if new_view.id == "lighttable" then
        install_module()
        end
      end
    )
  end

-- sharpen file on disk exports -----------------------------------------------
dt.register_event(MODULE_NAME, "intermediate-export-image", sharpen_disk_export)

-- register the new preferences -----------------------------------------------
dt.preferences.register(MODULE_NAME, "gmic_exe", "file",
_("executable for GMic CLI"),
_("select executable for GMic command line version")  , "")

-- set widgets to the last used values at startup -----------------------------
jpg_quality_slider.value = dt.preferences.read(MODULE_NAME, "jpg_quality", "float")
refresh_entries()

-- save values as they change -------------------------------------------------
sigma_slider.changed_callback = save_current
iterations_slider.changed_callback = save_current
jpg_quality_slider.changed_callback = function(self)
  dt.preferences.write(MODULE_NAME, "jpg_quality", "string", string.format("%.0f", self.value))
  end

-- script_manager integration

script_data.destroy = destroy
script_data.destroy_method = "hide"
script_data.restart = restart
script_data.show = restart

return script_data

-- end of script --------------------------------------------------------------

-- vim: shiftwidth=2 expandtab tabstop=2 cindent syntax=lua
-- kate: hl Lua;
