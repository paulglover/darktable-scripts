--[[
  PRUNE ANCESTOR TAGS

  Removes the hierarchical tags an image no longer needs because a deeper tag
  on the same image already says the same thing: an image tagged
  "Places|USA|Virginia|Roanoke" does not also need "Places", "Places|USA" or
  "Places|USA|Virginia".

  AUTHOR
  Paul Glover (paul@paulglover.net)

  ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
  None.

  USAGE
  * copy this file to $CONFIGDIR/lua/ (or install it with script_manager)
  * add "require 'prune_ancestor_tags'" to $CONFIGDIR/luarc
  * the module "prune ancestor tags" appears in the lighttable right panel

  1. select the images.

  2. "dry run" reports what would happen without changing anything.  The
     detailed per-tag report always goes to the darktable log (start darktable
     with -d lua to see it on the console).

  WHAT COUNTS AS REDUNDANT
  A tag is redundant on an image when another tag on that same image begins
  with it and continues with a "|".  Only whole levels match, and only from
  the root:

      Places|USA          is redundant beside Places|USA|Virginia
      Places              is redundant beside Places|USA|Virginia
      Styles|Film         is NOT redundant beside Film Details|Film|Fujifilm
      Subjects|Nature     is NOT redundant beside Subjects|Nature (itself)

  An image carrying several leaves under one tree keeps every one of them and
  loses only the levels above.  Tagged with all six of these, it keeps the last
  three:

      Subjects|Outdoors                            detached
      Subjects|Outdoors|Nature                     detached
      Subjects|Outdoors|Nature|Landscape           detached
      Subjects|Outdoors|Nature|Landscape|Details   kept
      Subjects|Outdoors|Nature|Landscape|Rocks     kept
      Subjects|Outdoors|Nature|Plants              kept

  NOTES
  * this only detaches tags from images.  no tag is ever deleted from the
    library, so a tag left attached to nothing stays until darktable's own
    "delete unused tags" is run.
  * darktable's internal tags ("darktable|...") are never detached, and never
    used to justify detaching anything else.
  * the plan is built per image, from that image's own tags, so select whole
    groups before a run.  two group members carrying the same tags stay the
    same only if both are selected; pruning one without the other makes them
    diverge.
  * matching is case sensitive, because darktable's tags are: "Places|UK" and
    "places|uk" are two different tags and neither covers the other.
  * detaching a tag cannot be undone from Lua.  Dry run is on by default; back
    up ~/.config/darktable/library.db before a real run.

  LICENSE
  LGPLv2+
]]

local dt = require "darktable"
local du = require "lib/dtutils"

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

du.check_min_api_version("7.0.0", "prune_ancestor_tags")

local MODULE = "prune_ancestor_tags"

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("prune ancestor tags"),
  purpose = _("detach the hierarchical tags a deeper tag on the same image already covers"),
  author = "Paul Glover (paul@paulglover.net)",
  help = ""
}

local pat = {}
pat.module_installed = false
pat.running = false

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

local function is_internal(name)
  return name == "darktable" or string.sub(name, 1, 10) == "darktable|"
end

-- is "ancestor" a whole-level prefix of "descendant"?  the trailing separator
-- check is what makes this a path comparison rather than a string one:
-- without it "Places|US" would swallow "Places|USA|Virginia", and "Styles" any
-- tag merely beginning with those letters
local function is_ancestor(ancestor, descendant)
  local length = #ancestor
  return #descendant > length
     and string.sub(descendant, 1, length) == ancestor
     and string.sub(descendant, length + 1, length + 1) == "|"
end

-- every tag acted on is looked up again by its full name.  get_tags() reports
-- a hierarchy under its whole path, so unlike prune_flat_tags -- which walks
-- dt.tags and has to tell a real flat tag from an entry merely named like one
-- -- this module is not resolving an ambiguity, only refusing to detach
-- through an object whose name does not come back as itself.  the read-back
-- after the detach is what actually decides whether anything happened
local function resolve_tag(name)
  local ok, tag = pcall(dt.tags.find, name)
  if not ok then
    return nil, string.format(_("find failed (%s)"), tostring(tag))
  end
  if not tag then
    return nil, _("no tag of that name in the library")
  end
  if tag.name ~= name then
    return nil, string.format(_("name resolves to a different tag '%s'"), tag.name)
  end
  return tag
end

-- the tag names an image says it carries, darktable's own ones left out
local function image_tag_names(image)
  local tags = dt.tags.get_tags(image)
  local names = {}
  for i = 1, #tags do
    local name = tags[i].name
    if not is_internal(name) then
      names[#names + 1] = name
    end
  end
  return names
end

-- how many levels a name has.  select() rather than a second return value,
-- because "local _, n = string.gsub(...)" would shadow the gettext alias
local function depth(name)
  return select(2, string.gsub(name, "|", "")) + 1
end

-- which of these names another one covers, and the deepest name that does the
-- covering.  quadratic in the tags on one image, which is a handful
local function redundant_names(names)
  local depths = {}
  for i = 1, #names do
    depths[i] = depth(names[i])
  end

  local redundant = {}
  for i = 1, #names do
    local covered_by, covered_depth = nil, 0
    for n = 1, #names do
      if n ~= i and is_ancestor(names[i], names[n]) then
        -- the deepest coverer is the informative one to name in the log, and
        -- depth is a level count, not a byte length: a long name three levels
        -- down is shallower than a short one five levels down.  the name
        -- breaks ties so the log does not depend on the order get_tags()
        -- happened to return
        if not covered_by
           or depths[n] > covered_depth
           or (depths[n] == covered_depth and names[n] < covered_by) then
          covered_by, covered_depth = names[n], depths[n]
        end
      end
    end
    if covered_by then
      redundant[#redundant + 1] = { name = names[i], because = covered_by }
    end
  end
  table.sort(redundant, function(a, b) return a.name < b.name end)
  return redundant
end

-- helpers: END

-- widgets: BEGIN

local dry_run_box = dt.new_widget("check_button") {
  label = _("dry run"),
  tooltip = _("report what would be detached without changing any tag"),
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
  bool_write("dry_run", dry_run_box.value)
end

-- logged as well as shown: a run that gives up has already written its header
-- to the log, and a header with no conclusion under -d lua says nothing about
-- why the run stopped
local function fail(message)
  dt.print(string.format(_("prune ancestor tags: %s"), message))
  dt.print_log(string.format("%s: GAVE UP (%s)", MODULE, message))
  status_label.label = message
end

-- build the work list before anything is detached: detaching mutates the very
-- collections walked here, and get_tags() yields, so everything an image says
-- about itself is read while it is still intact.
--
-- the job is passed in because that yield is also what lets the user cancel:
-- one get_tags() per selected image is a long silent wait over a big selection
local function plan(job)
  local action_images = dt.gui.action_images
  if #action_images == 0 then
    return nil, _("no images selected")
  end

  local work, tidy = {}, 0

  for i = 1, #action_images do
    if job and not job.valid then
      return nil, _("cancelled while reading tags")
    end

    local image = action_images[i]
    local redundant = redundant_names(image_tag_names(image))
    if #redundant == 0 then
      tidy = tidy + 1
    else
      work[#work + 1] = {
        image = image,
        filename = image.filename,
        detach = redundant
      }
    end

    if job and job.valid then
      job.percent = 0.5 * i / #action_images
    end
  end

  return { work = work, tidy = tidy, selected = #action_images }
end

local function stop_run(job)
  job.valid = false
end

-- everything from the job onwards, so that a raise anywhere inside cannot
-- leave the module latched as running or the progress bar stranded
local function run_once(dry_run)
  local job = dt.gui.create_job(
    dry_run and _("prune ancestor tags (dry run)") or _("prune ancestor tags"),
    true, stop_run)
  pat.job = job
  job.percent = 0.0

  local plan_result, error_message = plan(job)
  if not plan_result then
    return nil, error_message
  end

  local work, tidy = plan_result.work, plan_result.tidy

  if #work == 0 then
    return nil, string.format(_("nothing to detach, %d images already tidy"), tidy)
  end

  local planned = 0
  for i = 1, #work do
    planned = planned + #work[i].detach
  end

  dt.print_log(string.format("%s: %s %d redundant tags on %d of %d selected images",
    MODULE, dry_run and "dry run over" or "detaching", planned, #work, plan_result.selected))

  local detached, changed, refused, failed = 0, 0, 0, 0
  local cancelled = false

  -- one find() per distinct name for the whole run: the selection resolves to
  -- far fewer names than attachments.  only successes are cached -- find() is
  -- pcall'd because it can raise, and memoising one transient raise would
  -- silently skip that tag for the rest of the run
  local resolved = {}

  local function tag_for(name)
    local cached = resolved[name]
    if cached then
      return cached
    end
    local tag, reason = resolve_tag(name)
    if tag then
      resolved[name] = tag
    end
    return tag, reason
  end

  -- detaches issued for the current item but not yet read back.  it lives out
  -- here so that a raise between the detach call and the verification can
  -- still attribute the changes that already landed: detaching cannot be
  -- undone, and a change with no record of it is the worst outcome available
  local in_flight = {}

  local function process_item(item)
    in_flight = {}

    local any = false
    for n = 1, #item.detach do
      local name = item.detach[n].name
      local tag, reason = tag_for(name)

      if not tag then
        refused = refused + 1
        dt.print_log(string.format("%s: REFUSED (%s): '%s' on %s",
          MODULE, reason, name, item.filename))
      elseif dry_run then
        detached = detached + 1
        any = true
        dt.print_log(string.format("%s: would detach '%s' from %s (covered by '%s')",
          MODULE, name, item.filename, item.detach[n].because))
      else
        dt.tags.detach(tag, item.image)
        -- logged here rather than after the read-back below: the tag is
        -- already gone from the database and nothing can put it back, so the
        -- log line must not be contingent on the rest of this function running
        dt.print_log(string.format("%s: detached '%s' from %s (covered by '%s')",
          MODULE, name, item.filename, item.detach[n].because))
        in_flight[#in_flight + 1] = item.detach[n]
      end
    end

    if dry_run then
      if any then changed = changed + 1 end
      return
    end

    if #in_flight == 0 then
      return
    end

    -- what actually happened, read back from the image.  the count in the
    -- summary comes from here and not from the number of calls made: a detach
    -- that reports success while changing nothing is the failure this module
    -- has to be able to see
    local after = {}
    local names = image_tag_names(item.image)
    for n = 1, #names do
      after[names[n]] = true
    end

    local gone = 0
    for n = 1, #in_flight do
      if after[in_flight[n].name] then
        failed = failed + 1
        dt.print_log(string.format("%s: FAILED (still attached): '%s' on %s",
          MODULE, in_flight[n].name, item.filename))
      else
        gone = gone + 1
      end
    end

    detached = detached + gone
    if gone > 0 then
      changed = changed + 1
    end
    in_flight = {}
  end

  for index = 1, #work do
    if not job.valid then
      cancelled = true
      break
    end

    -- dt.tags.detach() raises rather than returning a status, and it yields,
    -- so darktable can process ui events and an image can disappear from the
    -- library mid-loop.  one bad image must not abort the run
    local ok, item_error = pcall(process_item, work[index])
    if not ok then
      -- whatever raised, the detaches that already landed are named line by
      -- line in the log above and are counted here, so the summary can never
      -- understate a change that cannot be undone
      local landed = #in_flight
      detached = detached + landed
      if landed > 0 then
        changed = changed + 1
      end
      failed = failed + (#work[index].detach - landed)
      in_flight = {}
      dt.print_log(string.format("%s: FAILED (%s): %s (%d of %d detached before the failure)",
        MODULE, tostring(item_error), work[index].filename,
        landed, #work[index].detach))
    end

    if job.valid then
      job.percent = 0.5 + 0.5 * index / #work
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
    summary = string.format(_("dry run: %d tags to detach from %d images, %d already tidy, %d refused"),
      detached, changed, tidy, refused)
  else
    summary = string.format(_("detached %d tags from %d images, %d already tidy, %d refused, %d failed"),
      detached, changed, tidy, refused, failed)
  end
  if cancelled then
    summary = string.format(_("cancelled - %s"), summary)
  end

  return summary
end

local function run()
  if pat.running then
    dt.print(_("prune ancestor tags: already running"))
    return
  end

  local dry_run = dry_run_box.value

  save_settings()

  -- latched before plan(), not after: plan() calls get_tags(), which yields,
  -- so without this the button can be pressed again and a second run started
  -- over the same images while the first is still reading them
  pat.running = true
  pat.job = nil

  local ok, summary, error_message = pcall(run_once, dry_run)

  -- whatever happened above, the module must not stay latched and the
  -- progress bar must not stay on screen
  if pat.job and pat.job.valid then
    pat.job.valid = false
  end
  pat.job = nil
  pat.running = false

  if not ok then
    error_message = tostring(summary)
    summary = nil
  end

  if not summary then
    return fail(error_message or _("failed"))
  end

  status_label.label = summary
  dt.print(string.format(_("prune ancestor tags: %s"), summary))
  dt.print_log(string.format("%s: %s", MODULE, summary))
end

-- business logic: END

pat.widget = dt.new_widget("box") {
  orientation = "vertical",
  reset_callback = function()
    status_label.label = ""
  end,
  dry_run_box,
  dt.new_widget("button") {
    label = _("prune ancestor tags"),
    tooltip = _("detach the tags a deeper tag on the same image already covers"),
    clicked_callback = run
  },
  status_label
}

local function install_module()
  if not pat.module_installed then
    -- 473 sits just under prune_flat_tags (475): the right panel sorts on this
    -- number descending, so a higher one is further up
    dt.register_lib(MODULE, _("prune ancestor tags"), true, true, {
      [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 473 }
    }, pat.widget, nil, nil)
    pat.module_installed = true
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
