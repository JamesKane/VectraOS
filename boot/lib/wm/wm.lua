-- /lib/wm/wm.lua: the window manager (M7 step 7d2c, 03 §5.2-5.3): policy
-- over the whole /wsys tree, in Lua. It gives winsrv the key bindings in
-- /lib/wm/keys.ndb, which winsrv matches in its input path, so they work
-- while wm is busy; it follows /wsys/events and places windows: as winsrv
-- puts them while the layout is float, and master-stack (dwm's: the oldest
-- window on the left half, the rest down the right) while it is tile. A
-- binding's verb winsrv cannot do itself comes here as `do N VERB`.

local function slurp(path)
  local f = assert(io.open(path))
  local s = f:read("a")
  f:close()
  return s
end

local function ctl(path, cmd)
  local f = io.open(path, "w")
  if f then
    f:write(cmd)
    f:close()
  end
end

local info = slurp("/wsys/info")
local W, H = tonumber(info:match("width=(%d+)")), tonumber(info:match("height=(%d+)"))

local keys = slurp("/lib/wm/keys.ndb")
ctl("/wsys/keys", keys)
local bindings = 0
for line in keys:gmatch("[^\n]+") do
  if line:match("^bind ") then bindings = bindings + 1 end
end

local layout, order = "float", {} -- the windows, oldest first
local BORDER, TITLE, GAP = 4, 20, 8 -- winsrv's frame, and the gaps between them

-- A window placed by its frame's rectangle.
local function place(id, x, y, w, h)
  local path = "/wsys/windows/" .. id .. "/ctl"
  ctl(path, string.format("move %d %d", x + BORDER, y + BORDER + TITLE))
  ctl(path, string.format("resize %d %d", w - 2 * BORDER, h - 2 * BORDER - TITLE))
end

local function tile()
  local n = #order
  if n > 0 then
    local x0, y0, w, h = GAP, GAP, W - 2 * GAP, H - 2 * GAP
    if n == 1 then
      place(order[1], x0, y0, w, h)
    else
      local mw = (w - GAP) // 2
      place(order[1], x0, y0, mw, h)
      local sh = (h - (n - 2) * GAP) // (n - 1)
      for i = 2, n do
        place(order[i], x0 + mw + GAP, y0 + (i - 2) * (sh + GAP), w - mw - GAP, sh)
      end
    end
  end
  print(string.format("wm: tiled %d windows", n))
end

print(string.format("wm: %d bindings, layout %s", bindings, layout))
for line in io.lines("/wsys/events") do
  local what, id, rest = line:match("^(%a+) (%d+) ?(.*)$")
  id = tonumber(id)
  if what == "new" then
    order[#order + 1] = id
    if layout == "tile" then tile() end
  elseif what == "gone" then
    for i, v in ipairs(order) do
      if v == id then
        table.remove(order, i)
        break
      end
    end
    if layout == "tile" then tile() end
  elseif what == "do" then
    local verb, arg = rest:match("^(%S+) ?(.*)$")
    if verb == "layout" and (arg == "tile" or arg == "float") then
      layout = arg
      print("wm: layout " .. layout)
      if layout == "tile" then tile() end
    elseif verb == "spawn" then
      print("wm: spawn " .. arg .. ": no terminal yet (7f)")
    else
      print("wm: no such verb: " .. rest)
    end
  end
end
