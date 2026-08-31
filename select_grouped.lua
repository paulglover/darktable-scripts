--[[
  SELECT GROUPED

  Adds "select grouped" and "select ungrouped" to the lighttable select
  module, so a collection can be narrowed by group membership.

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'select_grouped'" to $CONFIGDIR/luarc
  * two buttons appear in the "select" module in the lighttable right panel

  "select grouped" selects the images of the current collection that share a
  group with at least one other image.  "select ungrouped" selects the rest.

  NOTES
  * grouping is a property of the library, not of the collection.  an image
    whose only group partner is outside the current collection still counts as
    grouped.
  * darktable gives every image a group, so an image on its own is a group of
    one.  "grouped" therefore means the group has a second member, not that the
    image has a group.
  * both buttons walk the whole collection and ask the database for each
    image's group, so a large collection takes a moment.  the progress bar in
    the left panel can cancel the walk.

  LICENSE
  LGPLv2+
]]

local dt = require "darktable"
local du = require "lib/dtutils"

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

du.check_min_api_version("7.0.0", "select_grouped")

local MODULE = "select_grouped"

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("select grouped"),
  purpose = _("select the images of a collection that are, or are not, part of a group"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local sg = {}
sg.shortcuts_registered = false

-- helpers: BEGIN

local function is_grouped(image)
  return #image:get_group_members() > 1
end

local function stop_job(job)
  job.valid = false
end

-- collects the images whose group membership matches want_grouped.
--
-- the walk is a numeric for loop on purpose: "for _, image in ipairs(images)"
-- would shadow the gettext alias _() for the rest of this function
local function select_by_grouping(images, want_grouped, title)
  local job = dt.gui.create_job(title, true, stop_job)
  local selection = {}
  local examined = 0
  local failed = 0
  local cancelled = false

  for i = 1, #images do
    if not job.valid then
      cancelled = true
      break
    end

    -- get_group_members goes to the database and yields, so darktable can
    -- process ui events mid-loop and an image can disappear from the library
    -- underneath us.  one bad image must not abort the walk or strand the
    -- progress bar
    local ok, grouped = pcall(is_grouped, images[i])
    if ok then
      if grouped == want_grouped then
        selection[#selection + 1] = images[i]
      end
    else
      failed = failed + 1
      dt.print_log(string.format("%s: FAILED (%s): image %d", MODULE, tostring(grouped), i))
    end

    examined = i
    job.percent = i / #images
  end

  -- cancelling already destroyed the job
  if job.valid then
    job.valid = false
  end

  local summary = string.format(_("selected %d of %d images"), #selection, #images)
  if cancelled then
    -- the partial selection is still applied, so say what it covers
    summary = string.format(_("cancelled after %d of %d images - %s"),
      examined, #images, summary)
  end
  if failed > 0 then
    summary = string.format(_("%s, %d could not be read"), summary, failed)
  end

  dt.print(string.format("%s: %s", title, summary))
  dt.print_log(string.format("%s: %s: %s", MODULE, title, summary))

  -- return table of images to set the selection to
  return selection
end

-- helpers: END

local function select_grouped_images(event, images)
  return select_by_grouping(images, true, _("select grouped images"))
end

local function select_ungrouped_images(event, images)
  return select_by_grouping(images, false, _("select ungrouped images"))
end

dt.gui.libs.select.register_selection(MODULE .. "_grouped", _("select grouped"),
  select_grouped_images,
  _("select the images of this collection that are grouped with another image"))

dt.gui.libs.select.register_selection(MODULE .. "_ungrouped", _("select ungrouped"),
  select_ungrouped_images,
  _("select the images of this collection that are not grouped with any other image"))

-- the buttons act on the collection darktable hands them.  the shortcuts have
-- no such context, so they act on the current collection themselves
if not dt.query_event(MODULE .. "_grouped", "shortcut") then
  dt.register_event(MODULE .. "_grouped", "shortcut",
    function(event, shortcut)
      dt.gui.selection(select_grouped_images(event, dt.collection))
    end, _("select grouped")
  )
  dt.register_event(MODULE .. "_ungrouped", "shortcut",
    function(event, shortcut)
      dt.gui.selection(select_ungrouped_images(event, dt.collection))
    end, _("select ungrouped")
  )
  sg.shortcuts_registered = true
end

local function destroy()
  dt.gui.libs.select.destroy_selection(MODULE .. "_grouped")
  dt.gui.libs.select.destroy_selection(MODULE .. "_ungrouped")
  if sg.shortcuts_registered then
    dt.destroy_event(MODULE .. "_grouped", "shortcut")
    dt.destroy_event(MODULE .. "_ungrouped", "shortcut")
    sg.shortcuts_registered = false
  end
end

script_data.destroy = destroy

return script_data
