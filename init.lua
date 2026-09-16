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

spaceFilter = hs.window.filter.new()
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
-- Switcher overlay
--------------------------------------------------------------------------------
-- Hand-rolled rather than hs.window.switcher, which lays itself out around
-- window thumbnails and offers no way to cancel. This draws a vertical list of
-- app icons and titles, and supports Esc to dismiss without switching.

scope = {}

-- Everything configurable lives here. Reload with the reload hotkey (or
-- `hs -c 'hs.reload()'`) to pick up changes.
scope.config = {
  -- The modifier you hold while the overlay is open. This drives BOTH the
  -- activation hotkeys and the release-to-select detection; they have to agree
  -- or the overlay opens and then never commits. Use 'alt', 'cmd' or 'ctrl'.
  modifier = 'alt',

  -- Key pressed with the modifier to open the overlay and step forward.
  -- Modifier+shift+this steps backward.
  activate = 'tab',

  -- Keys handled while the overlay has the keyboard. Names come from
  -- hs.keycodes.map -- run `hs -c 'hs.inspect(hs.keycodes.map)'` for the list.
  -- `step` moves the selection forward, or backward when shift is held, so it
  -- covers both directions on its own.
  step   = { 'tab' },
  cancel = { 'escape' },

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

local canvas, wins, idx, tap, watchdog = nil, {}, 1, nil, nil

local function rowY(i) return PAD + (i - 1) * ROW_H end

local function teardown()
  if tap      then tap:stop();      tap      = nil end
  if watchdog then watchdog:stop(); watchdog = nil end
  if canvas   then canvas:delete();  canvas   = nil end
  -- Re-arm the hotkeys that were disabled while the overlay owned the keyboard.
  if scope.hotkeys then
    for _, hk in ipairs(scope.hotkeys) do hk:enable() end
  end
end

function scope.cancel()
  teardown()
end

function scope.commit()
  local target = wins[idx]
  teardown()
  if target then target:focus() end
end

local function highlight()
  if not canvas then return end
  canvas['selection'].frame = {
    x = PAD, y = rowY(idx), w = WIDTH - PAD * 2, h = ROW_H,
  }
end

function scope.step(delta)
  if #wins == 0 then return end
  idx = ((idx - 1 + delta) % #wins) + 1
  highlight()
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
end

local function matches(names, keycode)
  for _, name in ipairs(names) do
    if hs.keycodes.map[name] == keycode then return true end
  end
  return false
end

-- Only Tab and Escape are swallowed; everything else passes through. Everything else passes
-- through untouched: an event tap that eats all input is one Lua error away
-- from a wedged keyboard.
local function onEvent(e)
  local types = hs.eventtap.event.types

  -- Releasing the modifier is the only way to commit. There is deliberately no
  -- accept key: your hand is already on the modifier, so letting go is both
  -- faster and the gesture every other switcher on the platform teaches.
  if e:getType() == types.flagsChanged then
    if not e:getFlags()[cfg.modifier] then scope.commit() end
    return false
  end

  local key = e:getKeyCode()

  if matches(cfg.step, key) then
    scope.step(e:getFlags().shift and -1 or 1); return true
  elseif matches(cfg.cancel, key) then
    scope.cancel(); return true
  end

  return false
end

function scope.show(delta)
  if canvas then scope.step(delta); return end

  wins = spaceFilter:getWindows(hs.window.filter.sortByFocusedLast)
  if #wins < 2 then return end

  -- Start on the next window, so a quick press-and-release toggles between
  -- the two most recent windows the way Cmd-Tab does.
  idx = (delta > 0) and 2 or #wins

  -- Hand the keyboard to the event tap. Carbon hotkeys fire ahead of event
  -- taps, so leaving these enabled would advance the selection twice per press.
  if scope.hotkeys then
    for _, hk in ipairs(scope.hotkeys) do hk:disable() end
  end

  draw()

  tap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged },
    onEvent
  ):start()

  -- Safety net. If the modifier release is ever missed the overlay would sit
  -- there holding Tab and Escape forever.
  watchdog = hs.timer.doAfter(10, function()
    log.w('switcher watchdog fired; tearing down')
    scope.cancel()
  end)
end

--------------------------------------------------------------------------------
-- Bindings
--------------------------------------------------------------------------------
-- Deliberately on Alt-Tab, not Cmd-Tab. If this config ever fails to load you
-- still have the system switcher to get around with. Once you trust it, swap
-- 'alt' for 'cmd' below.

scope.hotkeys = {
  hs.hotkey.bind({ cfg.modifier },            cfg.activate, function() scope.show(1)  end),
  hs.hotkey.bind({ cfg.modifier, 'shift' },   cfg.activate, function() scope.show(-1) end),
}

hs.hotkey.bind(cfg.reload[1], cfg.reload[2], hs.reload)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------
-- Declared here rather than ticked in Hammerspoon's Preferences window so the
-- setting travels with the repo. Hammerspoon registers itself as a macOS login
-- item; the Lua config itself needs no autoload step, since Hammerspoon reads
-- ~/.hammerspoon/init.lua on every launch.
hs.autoLaunch(true)
hs.menuIcon(true)
hs.automaticallyCheckForUpdates(true)

hs.alert.show('scope: config loaded')
log.i('scope loaded; ' .. #spaceFilter:getWindows() .. ' windows in current space')
