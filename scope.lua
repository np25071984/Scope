-- Cycle windows within the current Space only.
--
-- macOS's Cmd-Tab is an *application* switcher and it spans every Space,
-- which defeats the point of using Spaces at all. This replaces it with a
-- *window* switcher scoped to whatever Space is currently on screen.

require('hs.ipc')  -- enables the `hs -c "..."` command line bridge

local log = hs.logger.new('scope', 'info')

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

  local space, result = hs.spaces.focusedSpace(), {}
  for _, w in ipairs(list) do
    if live[w:id()] then
      result[#result + 1] = w
    else
      -- Drop this app's on-screen tab into the stale entry's slot, so the row
      -- keeps its place in the most-recently-used order. Candidates are held
      -- to the same standard-window and current-Space rules as the filter
      -- itself, since :isWindowAllowed consults the very cache that is stale.
      local app = w:application()
      for _, candidate in ipairs(app and byPid[app:pid()] or {}) do
        if not claimed[candidate:id()]
            and candidate:isStandard()
            and onCurrentSpace(candidate, space) then
          claimed[candidate:id()] = true
          result[#result + 1] = candidate
          break
        end
      end
    end
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

function scope.show(delta)
  if canvas then scope.step(delta); return end

  wins = reconcile(spaceFilter:getWindows(hs.window.filter.sortByFocusedLast))
  if #wins < 2 then return end

  -- Start on the next window, so a quick press-and-release toggles between
  -- the two most recent windows the way Cmd-Tab does.
  idx = (delta > 0) and 2 or #wins

  draw()
  armWatchdog()
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
  onEvent
):start()

-- Reload stays an ordinary hotkey. It has to keep working even if the tap is
-- the thing that broke. Held on the table for the same reason as the tap.
scope.reloadHotkey = hs.hotkey.bind(cfg.reload[1], cfg.reload[2], hs.reload)

-- A handle to poke at from the console: package.loaded.scope.filter
scope.filter = spaceFilter

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
