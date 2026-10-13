-- Cycle windows within the current Space only.
--
-- macOS's Cmd-Tab is an *application* switcher and it spans every Space,
-- which defeats the point of using Spaces at all. This replaces it with a
-- *window* switcher scoped to whatever Space is currently on screen.

require('hs.ipc')  -- enables the `hs -c "..."` command line bridge

local log = hs.logger.new('scope', 'info')

--------------------------------------------------------------------------------
-- Tracing
--------------------------------------------------------------------------------
-- The list the overlay shows is the filter's cache run through three repairs
-- (ghosts, reconcile, promoteFocused), any of which can move a row. When the
-- order comes out wrong, the trace shows each stage's list and every decision
-- that fed it, so the stage that did it can be read straight off the console.
--
-- Off by default; it costs an Accessibility query per window per stage. Turn
-- it on without reloading, so the history leading up to a bad order survives:
--   hs -c "package.loaded.scope.log.setLogLevel('debug')"
-- and back off with 'info'. Output lands in the Hammerspoon console.

local function tracing() return log.getLogLevel() >= 4 end

-- Never throws: a ghost is a destroyed window, and tracing must not be the
-- thing that breaks the switcher.
local function describe(w)
  local ok, s = pcall(function()
    local app, title = w:application(), w:title() or ''
    local cut = utf8.offset(title, 41)
    if cut then title = title:sub(1, cut - 1) .. '…' end
    return string.format('%s %s "%s"', w:id(), app and app:name() or '?', title)
  end)
  return ok and s or ('<' .. tostring(s) .. '>')
end

--------------------------------------------------------------------------------
-- Window filter
--------------------------------------------------------------------------------
-- Built once at load time, NOT inside the hotkey callback. The filter
-- subscribes to focus events to maintain most-recently-used ordering; building
-- it per keypress would both lose that history and stall for ~100ms.

local spaceFilter = hs.window.filter.new()
  :setCurrentSpace(true)                               -- the whole point: current Space only
  :setDefaultFilter{ allowRoles = 'AXStandardWindow' } -- real windows only

-- allowRoles matters more than it looks. Several apps park invisible helper
-- windows in every Space to render popups -- Microsoft Teams' Notification
-- Center keeps a 680x932 one titled literally "Window". They report subrole
-- AXDialog rather than AXStandardWindow, so restricting roles drops all of
-- them at once, instead of blacklisting each app by name as you find it.
-- The tradeoff: genuine dialogs (Save sheets, permission prompts) are also
-- excluded, which is what you want in a window switcher.

-- Electron apps answer Accessibility queries slowly and can make the switcher
-- feel janky. Add offenders here if you notice lag.
-- spaceFilter:rejectApp('Slack')

--------------------------------------------------------------------------------
-- Keeping the list honest about tabs
--------------------------------------------------------------------------------
-- macOS native window tabbing gives every tab its own window and exposes only
-- the frontmost one to Accessibility; the tabs behind it are absent from the
-- application's window list entirely. Switching tabs therefore swaps one
-- window for another without emitting the created/destroyed notifications that
-- hs.window.filter maintains its cache from, so the cache goes on naming the
-- tab that happened to be up when it last heard anything.
--
-- Terminal is where this shows: leave it on one tab, switch away, come back,
-- and another tab is in front, because the row scope committed to was a window
-- that is no longer on screen. The row is mislabelled for the same reason.
--
-- Asking each application directly always reflects the tab that is up now. It
-- costs ~10ms for a Space's worth of apps against ~100ms to rebuild the filter,
-- and unlike a rebuild it leaves the most-recently-used ordering alone.

local function onCurrentSpace(win, space)
  for _, s in ipairs(hs.spaces.windowSpaces(win) or {}) do
    if s == space then return true end
  end
  return false
end

-- A swapped-out tab still answers Accessibility queries -- it reports itself
-- visible, standard and correctly framed -- so the one thing that gives it
-- away is that its own application has stopped listing it.
--
-- Returns the list, and which stale entry each swapped-in window replaced, so
-- that the replacement can be ranked by the time the row last saw use.
local function reconcile(list)
  local byPid = {}
  for _, w in ipairs(list) do
    local app = w:application()
    local pid = app and app:pid()
    if pid and not byPid[pid] then byPid[pid] = app:allWindows() end
  end

  local live = {}
  for _, windows in pairs(byPid) do
    for _, w in ipairs(windows) do live[w:id()] = true end
  end

  -- Windows the list already accounts for, so that a stale entry is never
  -- replaced by a window sitting elsewhere in the same list.
  local claimed = {}
  for _, w in ipairs(list) do
    if live[w:id()] then claimed[w:id()] = true end
  end

  local space, result, replaced = hs.spaces.focusedSpace(), {}, {}
  for _, w in ipairs(list) do
    if live[w:id()] then
      result[#result + 1] = w
    else
      -- Drop this app's on-screen tab into the stale entry's slot, so the row
      -- keeps its place in the most-recently-used order. Candidates are held
      -- to the same standard-window and current-Space rules as the filter
      -- itself, since :isWindowAllowed consults the very cache that is stale.
      local app, swapped = w:application(), nil
      for _, candidate in ipairs(app and byPid[app:pid()] or {}) do
        if not claimed[candidate:id()]
            and candidate:isStandard()
            and onCurrentSpace(candidate, space) then
          claimed[candidate:id()] = true
          result[#result + 1] = candidate
          replaced[candidate:id()] = w
          swapped = candidate
          break
        end
      end

      if tracing() then
        if swapped then
          log.d('reconcile: stale ' .. describe(w) .. ' -> ' .. describe(swapped))
        else
          local seen = {}
          for _, c in ipairs(app and byPid[app:pid()] or {}) do
            seen[#seen + 1] = string.format('%s%s', describe(c),
              claimed[c:id()] and ' [claimed]'
              or not c:isStandard() and ' [not standard]'
              or not onCurrentSpace(c, space) and ' [other Space]' or '')
          end
          log.d('reconcile: stale ' .. describe(w) .. ' dropped; candidates: '
            .. (#seen > 0 and table.concat(seen, ', ') or 'none'))
        end
      end
    end
  end

  return result, replaced
end

--------------------------------------------------------------------------------
-- Keeping the list honest about closed tabs
--------------------------------------------------------------------------------
-- Closing the frontmost tab destroys its window, and the filter drops it --
-- but the tab that comes forward in its place is never registered. The filter
-- learns about an app's windows from creation and focus-change notifications,
-- and a tab swap sends neither; worse, its per-app record of the focused
-- window still points at the destroyed one, so later activations of the app
-- re-focus a dead window instead of looking again. Terminal with its last row
-- closed then vanishes from the list entirely, and reconcile cannot rescue it:
-- reconcile only asks apps that still have a row.
--
-- So a destroyed window leaves a ghost behind: a stale entry, slotted into the
-- list where the closed tab used to rank, that reconcile swaps for whichever
-- tab is up now exactly as it does for any other stale entry. A ghost with
-- nothing to swap in -- the window really was the app's last on this Space,
-- or its successor has since been registered and is claimed -- is dropped.
--
-- The ranking needs focus times, which the filter keeps but does not expose,
-- so scope records its own from the filter's focus events. Those miss the
-- ghost's app for the same reason the filter does, so its activations are
-- picked up from the application watcher instead.

local focusedAt, ghosts = {}, {}   -- window id -> time; pid -> { win, at }

-- Every window scope has stamped, with the pid and Space it had then, for
-- ranking tab groups. See groupFocused.
local tabs = {}   -- window id -> { win, pid, space }

local function stamp(win, now)
  local id = win:id()
  if not id then return end
  focusedAt[id] = now
  local spaces = hs.spaces.windowSpaces(win)
  tabs[id] = { win = win, pid = win:pid(), space = spaces and spaces[1] }
end

local function onFocused(win)
  stamp(win, hs.timer.secondsSinceEpoch())
  if tracing() then log.d('focused ' .. describe(win)) end
end

local function onDestroyed(win)
  local pid = win:pid()
  if not pid then return end
  local id = win:id()
  ghosts[pid] = { win = win, at = id and focusedAt[id] or 0 }
  if id then focusedAt[id] = nil; tabs[id] = nil end
  if tracing() then log.d('destroyed ' .. describe(win) .. '; ghost for pid ' .. pid) end
end

local function onAppEvent(_, event, app)
  if event ~= hs.application.watcher.activated then return end
  local now = hs.timer.secondsSinceEpoch()
  local ghost = app and ghosts[app:pid()]
  if ghost then ghost.at = now end

  -- The filter's focus events miss any tab it has not registered, so an
  -- activation is the only sign such a tab was used. See byRecency.
  local front = app and app:focusedWindow()
  if front then stamp(front, now) end
  if tracing() then
    log.d('activated ' .. (app and app:name() or '?') .. (ghost and ' (ghost re-timed)' or ''))
  end
end

-- Each ghost goes in front of the first entry focused less recently than it.
-- Entries scope has no time for were last focused before it loaded, which is
-- before any ghost could have been made.
local function withGhosts(list)
  if not next(ghosts) then return list end

  local pending = {}
  for _, ghost in pairs(ghosts) do pending[#pending + 1] = ghost end
  table.sort(pending, function(a, b) return a.at > b.at end)

  local result, g = {}, 1
  for _, w in ipairs(list) do
    while pending[g] and pending[g].at > (focusedAt[w:id()] or 0) do
      result[#result + 1] = pending[g].win; g = g + 1
    end
    result[#result + 1] = w
  end
  for i = g, #pending do result[#result + 1] = pending[i].win end

  return result
end

-- A ghost has done its job only if reconcile put a window of its app into the
-- list that the filter itself did not supply.
local function pruneGhosts(cached, list)
  local known = {}
  for _, w in ipairs(cached) do known[w:id()] = true end

  local adopted = {}
  for _, w in ipairs(list) do
    if not known[w:id()] then adopted[w:pid()] = true end
  end

  for pid, ghost in pairs(ghosts) do
    if not adopted[pid] then
      ghosts[pid] = nil
      if tracing() then log.d('ghost pruned: ' .. describe(ghost.win)) end
    end
  end
end

--------------------------------------------------------------------------------
-- Keeping the list honest about which tab a row was used through
--------------------------------------------------------------------------------
-- reconcile repairs which window a row names, but not where the row ranks:
-- the filter ranks a tab group by the last time it saw the *stale* tab
-- focused. Bring the application forward on a different tab -- by committing
-- to the row reconcile swapped in, or by clicking it -- and the filter hears
-- nothing, because the tab it would hear about is not one it knows. The row
-- then sinks one place with every other switch, and Terminal used a moment ago
-- ends up last, below windows left untouched for minutes.
--
-- scope's own focus times know better: the application watcher stamps the
-- activated app's front window, registered or not. So after reconcile the
-- list is re-ranked by those times, with a swapped-in tab inheriting its
-- stale entry's time -- the row was last used whenever either was. Windows
-- scope has no time for were last focused before it loaded, so they sink
-- below every timed one and keep the filter's order among themselves.

local function lastFocused(w)
  local id = w:id()
  if focusedAt[id] then return focusedAt[id] end
  local ghost = ghosts[w:pid()]
  return ghost and ghost.win:id() == id and ghost.at or 0
end

-- That still loses any tab used in between. Use Terminal through tab B, move to
-- tab C, and the row is now C, or a stale A swapped for C: neither was focused
-- when B was, so a window untouched since outranks the Terminal just used. A
-- tab swap may also hand the filter C as a brand-new window, with no time at
-- all, and the row drops to the bottom.
--
-- So a row ranks by the newest time across its whole tab group: every stamped
-- window of the same app that is now swapped out, shares the row's frame, and
-- was on this Space when it was stamped. A swapped-out tab still reports its
-- group's frame but no Space at all, which is why the Space has to be the one
-- recorded at the time -- maximized windows of one app on two Spaces share a
-- frame too.
local function groupFocused(w, at, space)
  local pid, id, frame = w:pid(), w:id(), nil
  for tid, tab in pairs(tabs) do
    local t = focusedAt[tid]
    if tid ~= id and t and t > at and tab.pid == pid and tab.space == space then
      local ok, member = pcall(function()
        frame = frame or w:frame()
        return #(hs.spaces.windowSpaces(tab.win) or {}) == 0
          and tab.win:frame():equals(frame)
      end)
      if ok and member then
        if tracing() then log.d('tab group: ' .. describe(w) .. ' ranked by ' .. describe(tab.win)) end
        at = t
      end
    end
  end
  return at
end

local function byRecency(list, replaced)
  local rows, space = {}, hs.spaces.focusedSpace()
  for i, w in ipairs(list) do
    local stale = replaced[w:id()]
    local at = math.max(lastFocused(w), stale and lastFocused(stale) or 0)
    rows[i] = { win = w, i = i, at = groupFocused(w, at, space) }
  end

  table.sort(rows, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.i < b.i
  end)

  local result = {}
  for i, row in ipairs(rows) do result[i] = row.win end
  return result
end

-- One stage of scope.show's pipeline, a row per line. The age is scope's own
-- focus time, which is what withGhosts and byRecency rank against; '-' means
-- scope has not seen the window focused since it loaded.
local function dump(stage, list)
  local now, lines = hs.timer.secondsSinceEpoch(), { stage .. ':' }
  for i, w in ipairs(list) do
    local at = focusedAt[w:id()]
    lines[#lines + 1] = string.format('  %d. %s  %s', i, describe(w),
      at and string.format('%.1fs ago', now - at) or '-')
  end
  log.d(table.concat(lines, '\n'))
end

--------------------------------------------------------------------------------
-- Keeping the list honest about which window is current
--------------------------------------------------------------------------------
-- The filter's most-recently-used order is a cache fed by focus-change
-- notifications, and scope.show can read it before the notification for the
-- switch that just happened has been processed -- which is exactly the case
-- the quick toggle exists for, a second press straight after the first. The
-- cache then still ranks the *previous* window first, so the slot scope.show
-- skips as "the one I am already on" is the one it was supposed to land on,
-- and reaching it takes a lap through the whole list instead.
--
-- hs.window.focusedWindow() is a live Accessibility query rather than a
-- cache, so it settles the disagreement. Moving it to the front and leaving
-- everything else in place repairs precisely the one-event lag the race
-- produces: [Firefox, Terminal, Code] with Terminal focused becomes
-- [Terminal, Firefox, Code], which is the true order rather than a patched-up
-- first slot.
--
-- This runs after reconcile, not before: reconcile can swap a stale tab entry
-- for a different window object, and matching against an entry that is then
-- replaced would put the wrong window in front. The focused window is by
-- definition live, so reconcile passes it through untouched.
local function promoteFocused(list)
  local focused = hs.window.focusedWindow()
  if not focused then return list end

  local at
  for i, w in ipairs(list) do
    if w:id() == focused:id() then at = i; break end
  end

  -- Absent from the list -- a dialog, another Space, an app with no standard
  -- window -- means there is nothing to correct against; take the cache's word.
  if not at or at == 1 then return list end

  local result = { focused }
  for i, w in ipairs(list) do
    if i ~= at then result[#result + 1] = w end
  end

  return result
end

--------------------------------------------------------------------------------
-- Switcher overlay
--------------------------------------------------------------------------------
-- Hand-rolled rather than hs.window.switcher, which lays itself out around
-- window thumbnails and offers no way to cancel. This draws a vertical list of
-- app icons and titles, and supports Esc to dismiss without switching.
--
-- Everything here is local to this file. scope is required into somebody
-- else's init.lua, and a stray global named `scope` or `spaceFilter` in the
-- shared Lua state is exactly the kind of collision that is silent and then
-- baffling. The module table is returned at the bottom, which is also what
-- keeps it -- and through it the event tap -- alive: package.loaded holds the
-- only reference once the chunk has run.

local scope = {}

-- Everything configurable lives here. Reload with the reload hotkey (or
-- `hs -c 'hs.reload()'`) to pick up changes.
scope.config = {
  -- The modifier you hold while the overlay is open. This drives BOTH the
  -- activation hotkeys and the release-to-select detection; they have to agree
  -- or the overlay opens and then never commits. Use 'alt', 'cmd' or 'ctrl'.
  modifier = 'cmd',

  -- Key pressed with the modifier to open the overlay and step forward.
  -- Modifier+shift+this steps backward.
  activate = 'tab',

  -- Keys handled while the overlay has the keyboard. Names come from
  -- hs.keycodes.map -- run `hs -c 'hs.inspect(hs.keycodes.map)'` for the list.
  -- `step` moves the selection forward, or backward when shift is held, so it
  -- covers both directions on its own.
  step   = { 'tab' },
  cancel = { 'escape' },

  -- Pointer support while the overlay is open: hovering a row selects it,
  -- clicking one switches to it, clicking anywhere else dismisses. The
  -- modifier stays held throughout, exactly as it does for the keyboard.
  mouse = true,

  -- After a Space switch, focus the window you last used on that Space when
  -- macOS has left nothing there focused.
  refocus = true,

  -- Standalone hotkeys, given as { modifiers, key }.
  reload = { { 'alt', 'shift' }, 'r' },

  -- Appearance.
  rowHeight = 54,
  iconSize  = 36,
  padding   = 10,
  width     = 620,
  radius    = 16,
}

local cfg = scope.config
local ROW_H, ICON, PAD  = cfg.rowHeight, cfg.iconSize, cfg.padding
local WIDTH, RADIUS     = cfg.width, cfg.radius
local TEXT_X = PAD + 12 + ICON + 14

local COLOR = {
  backdrop  = { white = 0.09, alpha = 0.94 },
  border    = { white = 1,    alpha = 0.13 },
  highlight = { red = 0.29, green = 0.40, blue = 0.90, alpha = 0.90 },
  title     = { white = 1,    alpha = 0.98 },
  subtitle  = { white = 1,    alpha = 0.52 },
}

local canvas, wins, idx, watchdog = nil, {}, 1, nil

local function rowY(i) return PAD + (i - 1) * ROW_H end

-- The inverse of rowY: which row is under a point in screen coordinates, or
-- nil when the point is outside the overlay altogether -- including the
-- padding bands above the first row and below the last. hs.canvas:frame() and
-- hs.eventtap.event:location() are both in Hammerspoon's flipped, top-left
-- origin screen space, so the two compare directly on every display.
local function rowAt(point)
  if not canvas then return nil end
  local f = canvas:frame()
  if point.x < f.x or point.x >= f.x + f.w then return nil end
  if point.y < f.y or point.y >= f.y + f.h then return nil end
  local i = math.floor((point.y - f.y - PAD) / ROW_H) + 1
  if i < 1 or i > #wins then return nil end
  return i
end

local function teardown()
  if watchdog then watchdog:stop(); watchdog = nil end
  if canvas   then canvas:delete(); canvas   = nil end
  if scope.mouseTap then scope.mouseTap:stop() end
end

function scope.cancel()
  teardown()
end

-- Safety net, rearmed on every interaction. If the modifier release is ever
-- missed the overlay would sit there holding Tab and Escape forever; the timer
-- bounds how long it can do that. Rearming rather than running down from the
-- moment it opened is what makes the overlay usable with the mouse, where
-- picking a row takes longer than a keystroke.
local function armWatchdog()
  if watchdog then watchdog:stop(); watchdog = nil end
  if not canvas then return end
  watchdog = hs.timer.doAfter(10, function()
    log.w('switcher watchdog fired; tearing down')
    scope.cancel()
  end)
end

function scope.isOpen()
  return canvas ~= nil
end

function scope.commit()
  local target = wins[idx]
  if tracing() then log.d('commit ' .. idx .. ': ' .. (target and describe(target) or 'none')) end
  teardown()
  if target then target:focus() end
end

function scope.commitTo(i)
  idx = i
  scope.commit()
end

local function highlight()
  if not canvas then return end
  canvas['selection'].frame = {
    x = PAD, y = rowY(idx), w = WIDTH - PAD * 2, h = ROW_H,
  }
end

-- The one place the selection moves. Both the keyboard and the pointer come
-- through here, so the highlight is only redrawn when the row actually
-- changes -- hover fires a hundred times a second and would otherwise repaint
-- on every one of them.
function scope.select(i)
  if i == idx then return end
  idx = i
  highlight()
  armWatchdog()
end

function scope.step(delta)
  if #wins == 0 then return end
  scope.select(((idx - 1 + delta) % #wins) + 1)
end

local function draw()
  local height = PAD * 2 + #wins * ROW_H
  local screen = hs.screen.mainScreen():frame()

  canvas = hs.canvas.new{
    x = screen.x + (screen.w - WIDTH) / 2,
    y = screen.y + (screen.h - height) / 2,
    w = WIDTH,
    h = height,
  }
  canvas:level(hs.canvas.windowLevels.popUpMenu)

  canvas:appendElements{
    type = 'rectangle', action = 'strokeAndFill',
    fillColor = COLOR.backdrop, strokeColor = COLOR.border, strokeWidth = 1,
    roundedRectRadii = { xRadius = RADIUS, yRadius = RADIUS },
  }

  canvas:appendElements{
    id = 'selection', type = 'rectangle', action = 'fill',
    fillColor = COLOR.highlight,
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
    frame = { x = PAD, y = rowY(1), w = WIDTH - PAD * 2, h = ROW_H },
  }

  for i, w in ipairs(wins) do
    local app  = w:application()
    local y    = rowY(i)
    local icon = app and hs.image.imageFromAppBundle(app:bundleID() or '')

    if icon then
      canvas:appendElements{
        type = 'image', image = icon, imageScaling = 'scaleProportionally',
        frame = { x = PAD + 12, y = y + (ROW_H - ICON) / 2, w = ICON, h = ICON },
      }
    end

    canvas:appendElements{
      type = 'text', text = w:title() or '(untitled)',
      textColor = COLOR.title, textSize = 14, textFont = '.AppleSystemUIFont',
      textLineBreak = 'truncateTail',
      frame = { x = TEXT_X, y = y + 9, w = WIDTH - TEXT_X - PAD - 12, h = 20 },
    }

    canvas:appendElements{
      type = 'text', text = (app and app:name()) or '',
      textColor = COLOR.subtitle, textSize = 11, textFont = '.AppleSystemUIFont',
      textLineBreak = 'truncateTail',
      frame = { x = TEXT_X, y = y + 29, w = WIDTH - TEXT_X - PAD - 12, h = 16 },
    }
  end

  highlight()
  canvas:show()

  if cfg.mouse then scope.mouseTap:start() end
end

local function matches(names, keycode)
  for _, name in ipairs(names) do
    if hs.keycodes.map[name] == keycode then return true end
  end
  return false
end

-- Activation goes through this tap rather than hs.hotkey because the Dock owns
-- Cmd-Tab and will not yield it: hs.hotkey cannot even register the
-- combination, since Carbon hotkeys lose to whatever the Dock has claimed.
-- Event taps see keys before the Dock does, so one persistent tap both opens
-- the overlay and drives it once open.
--
-- Only the activation combination, Tab and Escape are ever swallowed;
-- everything else returns false and passes straight through. If this function
-- throws, Hammerspoon lets the event through untouched, so a broken handler
-- degrades to the system switcher rather than to a dead keyboard.
-- macOS switches off a tap whose handler keeps it waiting, and the event
-- that timed out goes on to the Dock: the system switcher comes up in place of
-- the overlay. Hammerspoon turns the tap back on without a word to Lua, so
-- there is nothing to catch afterwards. Timing the handler itself is the next
-- best thing; a warning here, always on, marks the press that came close.
local SLOW_EVENT = 0.2   -- seconds; macOS gives up at around one

local function timed(handler)
  return function(e)
    local t0 = hs.timer.absoluteTime()
    local ok, result = pcall(handler, e)
    local took = (hs.timer.absoluteTime() - t0) / 1e9
    if took > SLOW_EVENT then
      log.w(string.format('key handler took %.0fms; macOS may have passed this key on', took * 1000))
    end
    if not ok then error(result, 0) end
    return result
  end
end

local function onEvent(e)
  local types = hs.eventtap.event.types
  local flags = e:getFlags()

  if canvas then
    -- Releasing the modifier is the only way to commit. There is deliberately
    -- no accept key: your hand is already on the modifier, so letting go is
    -- both faster and the gesture every other switcher on the platform teaches.
    if e:getType() == types.flagsChanged then
      if not flags[cfg.modifier] then scope.commit() end
      return false
    end

    local key = e:getKeyCode()
    if matches(cfg.step, key) then
      scope.step(flags.shift and -1 or 1); return true
    elseif matches(cfg.cancel, key) then
      scope.cancel(); return true
    end
    return false
  end

  -- Overlay closed: the only thing worth reacting to is the activation combo.
  if e:getType() == types.keyDown
      and flags[cfg.modifier]
      and e:getKeyCode() == hs.keycodes.map[cfg.activate] then
    scope.show(flags.shift and -1 or 1)
    return true
  end

  return false
end

-- The pointer gets its own tap, and its own handler. Its own tap because
-- mouseMoved fires continuously and this one only runs while the overlay is
-- up, so a switcher that is on screen for a second at a time costs nothing the
-- rest of the day. Its own handler because onEvent reads a keycode off every
-- event once the overlay is open, which a mouse event does not carry.
--
-- hs.canvas has mouse tracking of its own, and it is the wrong tool here:
-- clickActivating defaults to true, so a click would bring Hammerspoon forward
-- and take the focus we are about to hand to the target window, and turning it
-- off changes the canvas's AXSubrole -- which this module would then have to
-- keep out of its own window filter. Hit-testing the frame in Lua leaves the
-- canvas transparent to both the mouse and Accessibility.
local function onMouse(e)
  local types = hs.eventtap.event.types
  local t = e:getType()

  -- Movement is never swallowed; returning true here would freeze the cursor.
  if t == types.mouseMoved or t == types.leftMouseDragged then
    local i = rowAt(e:location())
    if i then scope.select(i) end   -- off the overlay, the selection stays put
    return false
  end

  -- Both halves of the click are swallowed, so neither reaches the window
  -- underneath -- which, the overlay being a popup over somebody else's
  -- window, is nearly always something you did not mean to click. The decision
  -- waits for the release, the way menus and the system switcher do.
  if t == types.leftMouseDown then return true end

  if t == types.leftMouseUp then
    local i = rowAt(e:location())
    if i then scope.commitTo(i) else scope.cancel() end
    return true
  end

  return false
end

-- The current Space's windows, most recently used first: the filter's cache
-- with every repair but promoteFocused applied. Returns each stage as well, for
-- the trace.
local function currentWindows()
  local cached = spaceFilter:getWindows(hs.window.filter.sortByFocusedLast)
  local ghosted = withGhosts(cached)
  local reconciled, replaced = reconcile(ghosted)
  pruneGhosts(cached, reconciled)
  return byRecency(reconciled, replaced), cached, ghosted, reconciled
end

function scope.show(delta)
  if canvas then scope.step(delta); return end

  local t0 = hs.timer.absoluteTime()
  local ranked, cached, ghosted, reconciled = currentWindows()
  wins = promoteFocused(ranked)

  if tracing() then
    local focused = hs.window.focusedWindow()
    log.d(string.format('show; ranked in %.0fms; focused %s',
      (hs.timer.absoluteTime() - t0) / 1e6, focused and describe(focused) or 'none'))
    dump('filter', cached)
    if ghosted ~= cached then dump('withGhosts', ghosted) end
    dump('reconcile', reconciled)
    dump('byRecency', ranked)
    if wins ~= ranked then dump('promoteFocused', wins) end
  end

  if #wins < 2 then return end

  -- Start on the next window, so a quick press-and-release toggles between
  -- the two most recent windows the way Cmd-Tab does.
  idx = (delta > 0) and 2 or #wins

  draw()
  armWatchdog()
end

--------------------------------------------------------------------------------
-- Keeping focus on the Space you arrive in
--------------------------------------------------------------------------------
-- Switching Spaces does not reliably move the keyboard with you. The app that
-- was active on the Space you left stays active when it has nothing here --
-- Finder after a click on the desktop is the usual one -- so you arrive with
-- your last window in front but not focused, and typing goes nowhere until a
-- Cmd-Tab hands it back.
--
-- scope already knows which window you used last on this Space: it is the
-- first row the switcher would draw. So after a Space change, if nothing on
-- the new Space has focus, that window gets it.
--
-- Only then. A window on this Space that already has focus is left alone,
-- because a Space change is just as often the result of choosing a window --
-- a Dock click, a notification, an app opening something -- and overriding
-- that would undo what you just did. The cost is one case scope cannot help:
-- when the app active on the Space you left also has a window here, macOS
-- focuses that window, and scope cannot tell it from one you picked.
--
-- The check waits for the switch to settle. The animation has to finish,
-- macOS has to make whatever activation it is going to make, and the filter
-- has to catch up with the new Space; rearming the timer on every change also
-- collapses a quick run of switches into one check on the Space you end on.

local REFOCUS_DELAY, refocusTimer = 0.3, nil

local function refocus()
  refocusTimer = nil
  if canvas then return end

  local space = hs.spaces.focusedSpace()
  local focused = hs.window.focusedWindow()
  if focused and focused:isStandard() and onCurrentSpace(focused, space) then
    if tracing() then log.d('refocus: ' .. describe(focused) .. ' already focused') end
    return
  end

  -- The filter's notion of the current Space can lag the switch, so each
  -- candidate is checked against the Space actually on screen.
  local target, ranked = nil, (currentWindows())
  for _, w in ipairs(ranked) do
    if onCurrentSpace(w, space) then target = w; break end
  end

  if tracing() then
    dump('refocus candidates', ranked)
    log.d(string.format('refocus: Space %s, focused %s -> %s', space,
      focused and describe(focused) or 'none', target and describe(target) or 'none'))
  end
  if target then target:focus() end
end

local function onSpaceChanged()
  if refocusTimer then refocusTimer:stop() end
  refocusTimer = hs.timer.doAfter(REFOCUS_DELAY, refocus)
end

--------------------------------------------------------------------------------
-- Bindings
--------------------------------------------------------------------------------
-- Both taps are kept on the scope table rather than in file locals so that
-- they always have a strong reference; an event tap that gets collected stops
-- firing.
--
-- The mouse tap is built first and started by draw, not here: it only needs to
-- run while there is an overlay to point at, and draw is reached through the
-- key tap below, which must not find it missing.
scope.mouseTap = hs.eventtap.new({
  hs.eventtap.event.types.mouseMoved,
  hs.eventtap.event.types.leftMouseDragged,
  hs.eventtap.event.types.leftMouseDown,
  hs.eventtap.event.types.leftMouseUp,
}, onMouse)

scope.eventTap = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged },
  timed(onEvent)
):start()

-- The ghost bookkeeping's feeds. The filter subscriptions are held by the
-- filter itself; the application watcher needs the same strong reference as
-- the taps.
spaceFilter:subscribe(hs.window.filter.windowFocused, onFocused)
spaceFilter:subscribe(hs.window.filter.windowDestroyed, onDestroyed)
scope.appWatcher = hs.application.watcher.new(onAppEvent):start()

-- Held for the same reason as the taps.
if cfg.refocus then
  scope.spaceWatcher = hs.spaces.watcher.new(onSpaceChanged):start()
end

-- Reload stays an ordinary hotkey. It has to keep working even if the tap is
-- the thing that broke. Held on the table for the same reason as the tap.
scope.reloadHotkey = hs.hotkey.bind(cfg.reload[1], cfg.reload[2], hs.reload)

-- Handles to poke at from the console: package.loaded.scope.filter, and
-- package.loaded.scope.log for switching the trace on and off.
scope.filter = spaceFilter
scope.log = log

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------
-- hs.autoLaunch, hs.menuIcon and hs.automaticallyCheckForUpdates are
-- Hammerspoon-wide preferences, not scope's to decide for the config that
-- requires it. install.sh writes them into a freshly created init.lua, where
-- they are visible and editable; an init.lua that already existed is left to
-- make its own call. autoLaunch is the one that matters here, since it is what
-- brings scope back after a reboot.
--
-- No alert on load either, for the same reason: a module has no business
-- interrupting its host on every reload. The log line is enough, and
-- `hs -c 'package.loaded.scope ~= nil'` answers the same question on demand.
log.i('scope loaded; ' .. #spaceFilter:getWindows() .. ' windows in current space')

return scope
