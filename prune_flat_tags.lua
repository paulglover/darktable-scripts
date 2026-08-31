--[[
  PRUNE FLAT TAGS

  Finds flat (non-hierarchical) tags whose name also appears somewhere in a
  hierarchical tag, and removes them: a plain "London" tag is redundant once
  the image is tagged "Places|UK|London".

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'prune_flat_tags'" to $CONFIGDIR/luarc
  * the module "prune flat tags" appears in the lighttable right panel

  1. "match" decides what counts as a match.  With "any level of a hierarchy"
     the flat tag "UK" matches "Places|UK|London"; with "leaf level only" only
     "London" does.

  2. "action" decides what happens to a matching flat tag:

       * "detach where the hierarchy tag is present" (the safe one) detaches
         the flat tag only from those images that already carry a hierarchical
         tag containing the name, so nothing an image says about itself is
         lost.  The tag itself is deleted only once no image is left carrying
         it.

       * "delete the tag from the library" deletes the flat tag outright,
         which detaches it from every image, including images that have no
         hierarchical tag saying the same thing.

  3. "dry run" reports what would happen without changing anything.  The
     detailed per-tag report always goes to the darktable log (start darktable
     with -d lua to see it on the console).

  NOTES
  * matching is case sensitive unless "ignore case" is on.  darktable's tags
    are case sensitive, so "london" and "London" are two different tags.
  * darktable's own internal tags ("darktable|...") are never looked at, from
    either side of the comparison.
  * deleting or detaching a tag cannot be undone from Lua.  Dry run is on by
    default; back up ~/.config/darktable/library.db before a real run.

  LICENSE
  LGPLv2+
]]

local dt = require "darktable"
local du = require "lib/dtutils"

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

du.check_min_api_version("7.0.0", "prune_flat_tags")

local MODULE = "prune_flat_tags"

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("prune flat tags"),
  purpose = _("remove flat tags whose name is already expressed by a hierarchical tag"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local pft = {}
pft.module_installed = false
pft.running = false

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

local function is_internal(name)
  return name == "darktable" or string.sub(name, 1, 10) == "darktable|"
end

local function is_flat(name)
  return not string.find(name, "|", 1, true)
end

local function split_tag(name)
  local parts = {}
  for part in string.gmatch(name, "[^|]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- helpers: END

-- widgets: BEGIN

local match_box = dt.new_widget("combobox") {
  label = _("match"),
  tooltip = _("any level:  flat 'UK' matches 'Places|UK|London'\nleaf level: only flat 'London' does"),
  _("any level of a hierarchy"), _("leaf level only")
}
match_box.selected = tonumber(pref_read("match", "1")) or 1

local ignore_case_box = dt.new_widget("check_button") {
  label = _("ignore case"),
  tooltip = _("treat 'london' and 'London' as the same name\noff by default: darktable's tags are case sensitive"),
  value = bool_read("ignore_case", false)
}

local action_box = dt.new_widget("combobox") {
  label = _("action"),
  tooltip = _("detach: remove the flat tag only from images that already carry\na hierarchical tag saying the same thing, and delete the tag\nonce no image is left carrying it\ndelete: remove the flat tag from every image and the library"),
  _("detach where the hierarchy tag is present"), _("delete the tag from the library")
}
action_box.selected = tonumber(pref_read("action", "1")) or 1

local dry_run_box = dt.new_widget("check_button") {
  label = _("dry run"),
  tooltip = _("report what would be done without changing any tag"),
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
  pref_write("match", tostring(match_box.selected))
  pref_write("action", tostring(action_box.selected))
  bool_write("ignore_case", ignore_case_box.value)
  bool_write("dry_run", dry_run_box.value)
end

local function fail(message)
  dt.print(string.format(_("prune flat tags: %s"), message))
  status_label.label = message
end

-- does this image carry a hierarchical tag that contains the component?
local function image_has_component(image, wanted, leaf_only, ignore_case)
  local tags = dt.tags.get_tags(image)
  for i = 1, #tags do
    local name = tags[i].name
    if not is_internal(name) and not is_flat(name) then
      local parts = split_tag(name)
      for p = (leaf_only and #parts or 1), #parts do
        local component = ignore_case and string.lower(parts[p]) or parts[p]
        if component == wanted then
          return true, name
        end
      end
    end
  end
  return false
end

-- build the work list: one entry per matching flat tag.
--
-- everything is resolved before anything is changed, because detaching or
-- deleting a tag mutates the very collections walked here (dt.tags, tag[i])
local function plan(leaf_only, ignore_case, safe_mode, job)
  local flat, components = {}, {}

  for i = 1, #dt.tags do
    local tag = dt.tags[i]
    local name = tag.name
    if not is_internal(name) then
      if is_flat(name) then
        flat[#flat + 1] = tag
      else
        local parts = split_tag(name)
        for p = (leaf_only and #parts or 1), #parts do
          local key = ignore_case and string.lower(parts[p]) or parts[p]
          local entry = components[key]
          if not entry then
            entry = {}
            components[key] = entry
          end
          -- only kept to name a match in the log
          if #entry < 3 then
            entry[#entry + 1] = name
          end
        end
      end
    end
  end

  if #flat == 0 then
    return nil, _("no flat tags in the library")
  end

  local items = {}
  for i = 1, #flat do
    if job and not job.valid then
      return nil, _("cancelled")
    end

    local tag = flat[i]
    local key = ignore_case and string.lower(tag.name) or tag.name
    local matches = components[key]

    if matches then
      -- the tag's image collection is snapshotted: detaching mutates it
      local images = {}
      for n = 1, #tag do
        images[#images + 1] = tag[n]
      end

      local item = {
        tag = tag,
        name = tag.name,
        matches = matches,
        images_total = #images,
        detach = {},
        kept = 0
      }

      if safe_mode then
        for n = 1, #images do
          if image_has_component(images[n], key, leaf_only, ignore_case) then
            item.detach[#item.detach + 1] = images[n]
          else
            item.kept = item.kept + 1
          end
        end
        -- an empty tag, or one emptied by the detaching above, has nothing
        -- left to say and goes with it
        item.delete = item.kept == 0
      else
        item.delete = true
      end

      items[#items + 1] = item
    end

    if job and job.valid then
      job.percent = 0.5 * i / #flat
    end
  end

  return { items = items, flat_count = #flat }
end

local function stop_prune(job)
  job.valid = false
end

local function run()
  if pft.running then
    dt.print(_("prune flat tags: already running"))
    return
  end

  local dry_run = dry_run_box.value
  local leaf_only = match_box.selected == 2
  local ignore_case = ignore_case_box.value
  local safe_mode = action_box.selected == 1

  save_settings()

  pft.running = true

  local job = dt.gui.create_job(
    dry_run and _("prune flat tags (dry run)") or _("prune flat tags"),
    true, stop_prune)
  job.percent = 0.0

  dt.print_log(string.format("%s: %s, matching %s, %s", MODULE,
    dry_run and "dry run" or "pruning",
    leaf_only and "leaf level only" or "any level",
    safe_mode and "detaching where the hierarchy tag is present"
              or "deleting matching flat tags"))

  -- get_tags() goes to the database and yields, so the plan can be cancelled
  -- and an image can disappear from the library while it is built
  local ok, plan_result, error_message = pcall(plan, leaf_only, ignore_case, safe_mode, job)
  if not ok then
    error_message = tostring(plan_result)
    plan_result = nil
  end

  if not plan_result then
    if job.valid then
      job.valid = false
    end
    pft.running = false
    return fail(error_message)
  end

  local items = plan_result.items
  if #items == 0 then
    job.valid = false
    pft.running = false
    return fail(string.format(_("no flat tag matches a hierarchical tag (%d flat tags checked)"),
      plan_result.flat_count))
  end

  local deleted, kept, detached, failed = 0, 0, 0, 0
  local cancelled = false

  local function process_item(item)
    if dry_run then
      if item.delete then
        deleted = deleted + 1
      else
        kept = kept + 1
      end
      detached = detached + #item.detach
      dt.print_log(string.format("%s: would %s '%s' (%d of %d images, matches %s)",
        MODULE,
        item.delete and "delete" or "detach from",
        item.name,
        item.delete and item.images_total or #item.detach,
        item.images_total,
        item.matches[1]))
      return
    end

    -- deleting a tag detaches it from every image by itself, so only the safe
    -- mode has anything to detach
    for n = 1, #item.detach do
      dt.tags.detach(item.tag, item.detach[n])
      detached = detached + 1
    end

    if item.delete then
      dt.tags.delete(item.tag)
      deleted = deleted + 1
      dt.print_log(string.format("%s: deleted '%s' (was on %d images, matches %s)",
        MODULE, item.name, item.images_total, item.matches[1]))
    else
      kept = kept + 1
      dt.print_log(string.format("%s: kept '%s' (detached from %d of %d images, %d without a hierarchical tag)",
        MODULE, item.name, #item.detach, item.images_total, item.kept))
    end
  end

  for i = 1, #items do
    if not job.valid then
      cancelled = true
      break
    end

    -- dt.tags.detach() and dt.tags.delete() raise rather than returning a
    -- status, and they yield, so an image can disappear from the library
    -- while we work.  one bad tag must not abort the run, strand the progress
    -- bar or leave the module marked as running for the rest of the session
    local item_ok, item_error = pcall(process_item, items[i])
    if not item_ok then
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (%s): %s",
        MODULE, tostring(item_error), items[i].name))
    end

    if job.valid then
      job.percent = 0.5 + 0.5 * i / #items
    end
  end

  -- cancelling already destroyed the job
  if job.valid then
    job.valid = false
  end
  pft.running = false

  local summary
  if dry_run then
    summary = string.format(_("dry run: %d tags to delete, %d to keep, %d detachments, %d failed"),
      deleted, kept, detached, failed)
  else
    summary = string.format(_("deleted %d tags, kept %d, %d detachments, %d failed"),
      deleted, kept, detached, failed)
  end
  if cancelled then
    summary = string.format(_("cancelled - %s"), summary)
  end

  status_label.label = summary
  dt.print(string.format(_("prune flat tags: %s"), summary))
  dt.print_log(string.format("%s: %s", MODULE, summary))
end

-- business logic: END

pft.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    status_label.label = ""
  end,
  match_box,
  ignore_case_box,
  action_box,
  dry_run_box,
  dt.new_widget("button") {
    label = _("prune flat tags"),
    tooltip = _("remove the flat tags whose name a hierarchical tag already carries"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not pft.module_installed then
    dt.register_lib(MODULE, _("prune flat tags"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 710 }
    }, pft.widget, nil, nil)
    pft.module_installed = true
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
