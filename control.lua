-- Space Taxi
-- storage.passengers[platform index] = true/false (nil: use the map setting)
-- storage.bookings[player index] = {platform, from, to, stage, since, warned}
--   stage: "waiting" (for the ship to reach `from`), "launched" (in the rocket), "aboard", "landing"
-- storage.holds[platform index] = {platform, players = {[player index] = true}, until_tick, we_paused}
--   a held ship is paused so it cannot leave while a passenger is boarding or landing

local WINDOW = "space-taxi-window"
local STATUS = "space-taxi-status"
local HUB_FRAME = "space-taxi-hub"
local SILO_FRAME = "space-taxi-silo"

local function init_storage()
  storage.passengers = storage.passengers or {}
  storage.bookings = storage.bookings or {}
  storage.holds = storage.holds or {}
  storage.silos = storage.silos or {} -- [silo unit number] = player index holding its rocket
end
script.on_init(init_storage)
script.on_configuration_changed(init_storage)

---------------------------------------------------------------- helpers

local function loc_name(name)
  local p = prototypes.space_location[name]
  return p and p.localised_name or name
end

local function loc_label(name)
  return { "", "[space-location=" .. name .. "] ", loc_name(name) }
end

local function here_of(player)
  local s = player.physical_surface
  return s and s.planet and s.planet.name or nil
end

local function accepts_passengers(p)
  local v = storage.passengers[p.index]
  if v == nil then return settings.global["space-taxi-default-passengers"].value end
  return v
end

local function is_auto(p)
  return p and p.valid and not p.paused and p.hub and p.hub.valid and (p.scheduled_for_deletion or 0) == 0
end

-- stop names of the schedule, in order, and the index of the current record
local function stops_of(p)
  local s = p.schedule
  local out = {}
  if not s or not s.records then return out, 1 end
  for i, r in ipairs(s.records) do out[i] = r.station or false end
  return out, s.current or 1
end

-- distance between two space locations over the connection graph (Dijkstra, cached per session)
local graph, dist_cache = nil, {}
local function build_graph()
  graph = {}
  for _, c in pairs(prototypes.space_connection) do
    local a, b = c.from.name, c.to.name
    graph[a] = graph[a] or {}; graph[b] = graph[b] or {}
    table.insert(graph[a], { b, c.length }); table.insert(graph[b], { a, c.length })
  end
end
local function distance(a, b)
  if a == b then return 0 end
  local key = a .. "\0" .. b
  if dist_cache[key] then return dist_cache[key] end
  if not graph then build_graph() end
  local d, done = { [a] = 0 }, {}
  while true do
    local best, bd = nil, math.huge
    for n, v in pairs(d) do if not done[n] and v < bd then best, bd = n, v end end
    if not best then break end
    if best == b then break end
    done[best] = true
    for _, e in pairs(graph[best] or {}) do
      local nd = bd + e[2]
      if not d[e[1]] or nd < d[e[1]] then d[e[1]] = nd end
    end
  end
  local r = d[b] or 1e9
  dist_cache[key] = r
  return r
end

-- how many stops until the ship stops at `here` (0 = it is stopped there now)
-- the current record is the stop the ship is at, or the one it is flying to
local function stops_until(p, stops, cur, i)
  local k = (i - cur) % #stops
  if p.space_location and p.space_location.name == stops[cur] then return k end
  return k + 1
end

-- ships in automatic mode that have `here` in their schedule
local function ships_stopping_at(force, here)
  local out = {}
  for _, p in pairs(force.platforms) do
    if is_auto(p) then
      local stops, cur = stops_of(p)
      local best
      for i, s in ipairs(stops) do
        if s == here then
          local n = stops_until(p, stops, cur, i)
          if not best or n < best then best = n end
        end
      end
      if best then table.insert(out, { platform = p, stops = best, at_here = p.space_location and p.space_location.name == here }) end
    end
  end
  table.sort(out, function(a, b) if a.stops ~= b.stops then return a.stops < b.stops end return a.platform.index < b.platform.index end)
  return out
end

-- the most direct passenger ship from `here` to `dest`
-- returns {platform, km, hops, stops} or nil
local function best_ship(force, here, dest)
  local best
  for _, p in pairs(force.platforms) do
    if is_auto(p) and accepts_passengers(p) then
      local stops, cur = stops_of(p)
      local n = #stops
      for i, s in ipairs(stops) do
        if s == here then
          local km, hops, prev = 0, 0, here
          for k = 1, n - 1 do
            local j = (i - 1 + k) % n + 1
            local t = stops[j]
            if t then
              km = km + distance(prev, t); hops = hops + 1; prev = t
              if t == dest then
                local c = { platform = p, km = km, hops = hops, stops = stops_until(p, stops, cur, i) }
                if not best or c.km < best.km - 1e-6 or (math.abs(c.km - best.km) <= 1e-6 and (c.hops < best.hops or (c.hops == best.hops and c.stops < best.stops))) then best = c end
                break
              end
            end
          end
        end
      end
    end
  end
  return best
end

-- every planet reachable by a passenger ship from `here`
local function destinations(force, here)
  local set = {}
  for _, p in pairs(force.platforms) do
    if is_auto(p) and accepts_passengers(p) then
      local stops = stops_of(p)
      local has = false
      for _, s in ipairs(stops) do if s == here then has = true end end
      if has then for _, s in ipairs(stops) do if s and s ~= here and prototypes.space_location[s] then set[s] = true end end end
    end
  end
  local out = {}
  for name in pairs(set) do
    local b = best_ship(force, here, name)
    if b then table.insert(out, { name = name, ship = b }) end
  end
  table.sort(out, function(a, b) return a.ship.km < b.ship.km end)
  return out
end

---------------------------------------------------------------- holding a ship

local function hold(p, player_index)
  local h = storage.holds[p.index]
  if not h then
    h = { platform = p, players = {}, we_paused = false }
    storage.holds[p.index] = h
    if not p.paused then p.paused = true; h.we_paused = true end
  end
  if not h.players[player_index] then
    h.players[player_index] = true
    h.until_tick = game.tick + 60 * settings.global["space-taxi-hold-seconds"].value
  end
end

local function release(p_index, player_index)
  local h = storage.holds[p_index]
  if not h then return end
  if player_index then h.players[player_index] = nil end
  if player_index and next(h.players) then return end
  if h.we_paused and h.platform.valid then h.platform.paused = false end
  storage.holds[p_index] = nil
end

---------------------------------------------------------------- GUI: status line

-- stages: "seating" (no free rocket yet), "seated" (sitting in a rocket, waiting for the ship),
--         "launched", "aboard" (on the ship, flying to the destination), "landing"
local function update_status(player)
  local top = player.gui.top
  if top[STATUS] then top[STATUS].destroy() end
  local b = storage.bookings[player.index]
  if not b then return end
  local f = top.add { type = "frame", name = STATUS, direction = "horizontal", style = "slot_window_frame" }
  f.style.padding = 6
  f.style.vertical_align = "center"
  local name = b.platform.valid and b.platform.name or "?"
  local where = b.platform.valid and b.platform.space_location and loc_label(b.platform.space_location.name) or { "space-taxi.in-flight" }
  local text
  if b.stage == "seating" then
    text = { "space-taxi.status-no-rocket", name }
  elseif b.stage == "seated" then
    text = b.to and { "space-taxi.status-waiting-dest", name, loc_label(b.to), where } or { "space-taxi.status-waiting", name, where }
  elseif b.stage == "launched" then text = { "space-taxi.status-launched", name }
  elseif b.stage == "aboard" then text = { "space-taxi.status-aboard", name, loc_label(b.to) }
  else text = { "space-taxi.status-landing", loc_label(b.to or "nauvis") } end
  if b.note then text = { "", text, "  [color=1,0.6,0.3]", { "space-taxi." .. b.note }, "[/color]" } end
  f.add { type = "label", caption = text }
  if b.stage ~= "launched" and b.stage ~= "landing" then
    local c = f.add { type = "sprite-button", sprite = "utility/close", style = "tool_button_red", tooltip = { "space-taxi.cancel" }, tags = { space_taxi = "cancel" } }
    c.style.size = 24
  end
end

local function free_silo(b)
  if b.silo and b.silo.valid then
    b.silo.disabled_by_script = false
    storage.silos[b.silo.unit_number] = nil
  end
  b.silo, b.pod = nil, nil
end

local function cancel(player)
  local b = storage.bookings[player.index]
  if not b then return end
  if b.stage == "seated" and b.pod and b.pod.valid then pcall(b.pod.set_passenger, nil) end
  free_silo(b)
  if b.platform.valid then release(b.platform.index, player.index) end
  storage.bookings[player.index] = nil
  update_status(player)
end

---------------------------------------------------------------- seating, boarding and landing

local function sorted_silos(player)
  local surface = player.physical_surface
  local pos = player.physical_position
  local silos = surface.find_entities_filtered { type = "rocket-silo", force = player.force }
  table.sort(silos, function(a, b)
    local da = (a.position.x - pos.x) ^ 2 + (a.position.y - pos.y) ^ 2
    local db = (b.position.x - pos.x) ^ 2 + (b.position.y - pos.y) ^ 2
    return da < db
  end)
  return silos
end

local function is_in(pod, player, character)
  if not (pod and pod.valid) then return false end
  local ok, ps = pcall(pod.get_passenger)
  if not ok or not ps then return false end
  return ps == character or ps == player or (ps.valid and ps.object_name == "LuaEntity" and ps.player == player)
end

-- put the player into the rocket of the nearest free silo; the silo is frozen so it cannot launch that rocket elsewhere
local function seat(player, b)
  local character = player.character
  if not (character and character.valid) then b.note = "no-character"; return end
  if here_of(player) ~= b.from then return end
  if player.driving then player.driving = false end
  for _, silo in pairs(sorted_silos(player)) do
    local owner = storage.silos[silo.unit_number]
    if (not owner or owner == player.index) and silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready then
      local pod = silo.rocket and silo.rocket.valid and silo.rocket.attached_cargo_pod
      if pod and pod.valid then
        pcall(pod.set_passenger, character)
        if is_in(pod, player, character) then
          silo.disabled_by_script = true
          storage.silos[silo.unit_number] = player.index
          b.silo, b.pod, b.stage, b.note = silo, pod, "seated", nil
          return
        end
      end
    end
  end
  b.note = "no-rocket"
end

local function ship_here(p, from)
  return p.valid and p.space_location and p.space_location.name == from
    and (p.state == defines.space_platform_state.waiting_at_station or p.state == defines.space_platform_state.waiting_for_departure or p.paused)
end

local function launch(player, b)
  local p, silo = b.platform, b.silo
  hold(p, player.index) -- keep the ship here while the rocket flies (about 35 s)
  silo.disabled_by_script = false
  -- regular deliveries to a platform go to its hub as a "station"
  local ok = silo.launch_rocket({ type = defines.cargo_destination.station, station = p.hub }, player.character)
  if not ok then silo.disabled_by_script = true; return end
  if not is_in(b.pod, player, player.character) then pcall(b.pod.set_passenger, player.character) end
  storage.silos[silo.unit_number] = nil
  b.silo, b.pod = nil, nil
  b.stage, b.since, b.note = "launched", game.tick, nil
end

local function try_land(player, b)
  local p = b.platform
  if not (b.to and p.valid and p.space_location and p.space_location.name == b.to) then return end
  if player.physical_surface ~= p.surface then return end
  hold(p, player.index)
  if player.land_on_planet() then
    b.stage, b.since, b.note = "landing", game.tick, nil
  else
    b.note = "cannot-land"
  end
end

local function book(player, p, to)
  local here = here_of(player)
  if not here then return end
  cancel(player)
  local b = { platform = p, from = here, to = to, stage = "seating", since = game.tick }
  storage.bookings[player.index] = b
  seat(player, b)
  if b.stage == "seated" and ship_here(p, here) then launch(player, b) end
  update_status(player)
end

local function step_booking(player_index)
  local b = storage.bookings[player_index]
  local player = game.get_player(player_index)
  if not b then return end
  if not (player and player.valid) or not b.platform.valid then
    free_silo(b)
    if b.platform.valid then release(b.platform.index, player_index) end
    storage.bookings[player_index] = nil
    if player and player.valid then update_status(player) end
    return
  end
  local p = b.platform
  if b.stage == "seating" or b.stage == "seated" then
    if b.stage == "seated" and not is_in(b.pod, player, player.character) then
      cancel(player) -- the player climbed out of the rocket
      return
    end
    if b.stage == "seating" then seat(player, b) end
    if not (p.space_location and p.space_location.name == b.from) then b.missed = nil end
    if ship_here(p, b.from) and not b.missed then
      if b.stage == "seated" then launch(player, b) else hold(p, player.index) end -- no rocket yet: let the ship wait
    end
  elseif b.stage == "aboard" then try_land(player, b) end
  update_status(player)
end

script.on_event(defines.events.on_space_platform_changed_state, function(e)
  for pi, b in pairs(storage.bookings) do
    if b.platform == e.platform then step_booking(pi) end
  end
end)

script.on_event(defines.events.on_player_changed_surface, function(e)
  local player = game.get_player(e.player_index)
  local b = storage.bookings[e.player_index]
  if not (player and b) then return end
  if not b.platform.valid then step_booking(e.player_index); return end
  local surface = player.physical_surface
  if surface == b.platform.surface and b.stage ~= "aboard" and b.stage ~= "landing" then
    free_silo(b)
    release(b.platform.index, e.player_index)
    if b.to then
      b.stage, b.note = "aboard", nil
      try_land(player, b)
    else
      storage.bookings[e.player_index] = nil
    end
    update_status(player)
  elseif surface ~= b.platform.surface and b.stage == "landing" then
    release(b.platform.index, e.player_index)
    storage.bookings[e.player_index] = nil
    update_status(player)
  end
end)

script.on_nth_tick(60, function()
  for pi in pairs(storage.bookings) do step_booking(pi) end
  for idx, h in pairs(storage.holds) do
    if not h.platform.valid then storage.holds[idx] = nil
    elseif game.tick >= h.until_tick then
      for pi in pairs(h.players) do
        local b = storage.bookings[pi]
        if b and b.stage == "seating" then b.missed = true end -- no rocket in time: wait for the next visit
      end
      if h.we_paused then h.platform.paused = false end
      storage.holds[idx] = nil
    end
  end
end)

---------------------------------------------------------------- GUI: travel window

local function close_window(player)
  if player.gui.screen[WINDOW] then player.gui.screen[WINDOW].destroy() end
end

local function add_row(tbl, sprite_name, caption, info, button_caption, tags)
  local l = tbl.add { type = "label", caption = caption }
  l.style.minimal_width = 160
  local i = tbl.add { type = "label", caption = info }
  i.style.font_color = { 0.75, 0.75, 0.75 }
  tbl.add { type = "button", caption = button_caption, tags = tags, style = "green_button" }
end

local function stops_text(n, at_here)
  if at_here or n == 0 then return { "space-taxi.here-now" } end
  if n == 1 then return { "space-taxi.next-stop" } end
  return { "space-taxi.stops-away", n }
end

local function open_window(player)
  close_window(player)
  local f = player.gui.screen.add { type = "frame", name = WINDOW, direction = "vertical" }
  local bar = f.add { type = "flow", direction = "horizontal" }
  bar.drag_target = f
  bar.add { type = "label", caption = { "space-taxi.title" }, style = "frame_title" }.drag_target = f
  local filler = bar.add { type = "empty-widget", style = "draggable_space_header" }
  filler.style.horizontally_stretchable = true; filler.style.height = 24; filler.drag_target = f
  bar.add { type = "sprite-button", sprite = "utility/close", style = "close_button", tags = { space_taxi = "close" } }
  local inner = f.add { type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding" }
  inner.style.minimal_width = 460

  local here = here_of(player)
  if not here then
    inner.add { type = "label", caption = { "space-taxi.not-on-planet" } }
  else
    inner.add { type = "label", caption = { "space-taxi.you-are-on", loc_label(here) } }
    inner.add { type = "line" }
    inner.add { type = "label", caption = { "space-taxi.section-dest" }, style = "caption_label" }
    local dests = destinations(player.force, here)
    if #dests == 0 then inner.add { type = "label", caption = { "space-taxi.none-dest" } }
    else
      local t = inner.add { type = "table", column_count = 3 }
      t.style.vertical_align = "center"; t.style.horizontal_spacing = 12
      for _, d in ipairs(dests) do
        add_row(t, nil, loc_label(d.name),
          { "space-taxi.via", d.ship.platform.name, d.ship.hops, string.format("%.0f", d.ship.km), stops_text(d.ship.stops) },
          { "space-taxi.go" }, { space_taxi = "dest", dest = d.name })
      end
    end
    inner.add { type = "line" }
    inner.add { type = "label", caption = { "space-taxi.section-ship" }, style = "caption_label" }
    local ships = ships_stopping_at(player.force, here)
    if #ships == 0 then inner.add { type = "label", caption = { "space-taxi.none-ship", loc_label(here) } }
    else
      local t = inner.add { type = "table", column_count = 3 }
      t.style.horizontal_spacing = 12
      for _, s in ipairs(ships) do
        add_row(t, nil, s.platform.name, stops_text(s.stops, s.at_here), { "space-taxi.wait" },
          { space_taxi = "ship", platform = s.platform.index })
      end
    end
  end
  f.force_auto_center()
  player.opened = f
end

local function platform_by_index(force, idx)
  local p = force.platforms[idx]
  if p then return p end
  for _, q in pairs(force.platforms) do if q.index == idx then return q end end
end

script.on_event(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.space_taxi) then return end
  local player = game.get_player(e.player_index)
  local tags = el.tags -- read before the window (and this button) is destroyed
  local what = tags.space_taxi
  if what == "close" then close_window(player)
  elseif what == "open" then open_window(player)
  elseif what == "cancel" then cancel(player)
  elseif what == "ship" then
    local p = platform_by_index(player.force, tags.platform)
    close_window(player)
    if p and is_auto(p) then book(player, p, nil) end
  elseif what == "dest" then
    local here = here_of(player)
    local b = here and best_ship(player.force, here, tags.dest)
    close_window(player)
    if b then book(player, b.platform, tags.dest) end
  end
end)

script.on_event(defines.events.on_gui_closed, function(e)
  if e.element and e.element.valid and e.element.name == WINDOW then e.element.destroy() end
end)

local function toggle(player)
  if player.gui.screen[WINDOW] then close_window(player) else open_window(player) end
end
script.on_event("space-taxi-toggle", function(e) toggle(game.get_player(e.player_index)) end)
script.on_event(defines.events.on_lua_shortcut, function(e)
  if e.prototype_name == "space-taxi" then toggle(game.get_player(e.player_index)) end
end)

---------------------------------------------------------------- GUI: hub "Passengers" switch and silo button

script.on_event(defines.events.on_gui_opened, function(e)
  local player = game.get_player(e.player_index)
  local ent = e.entity
  local rel = player.gui.relative
  if rel[HUB_FRAME] then rel[HUB_FRAME].destroy() end
  if rel[SILO_FRAME] then rel[SILO_FRAME].destroy() end
  if not (ent and ent.valid) then return end
  if ent.type == "space-platform-hub" and ent.surface.platform then
    local p = ent.surface.platform
    local f = rel.add { type = "frame", name = HUB_FRAME, caption = { "space-taxi.title" },
      anchor = { gui = defines.relative_gui_type.space_platform_hub_gui, position = defines.relative_gui_position.right } }
    f.add { type = "checkbox", caption = { "space-taxi.passengers" }, tooltip = { "space-taxi.passengers-tip" },
      state = accepts_passengers(p), tags = { space_taxi = "passengers", platform = p.index } }
  elseif ent.type == "rocket-silo" then
    local f = rel.add { type = "frame", name = SILO_FRAME, caption = { "space-taxi.title" },
      anchor = { gui = defines.relative_gui_type.rocket_silo_gui, position = defines.relative_gui_position.right } }
    f.add { type = "button", caption = { "space-taxi.open" }, tags = { space_taxi = "open" } }
  end
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.space_taxi == "passengers") then return end
  storage.passengers[el.tags.platform] = el.state
end)

---------------------------------------------------------------- for testing

remote.add_interface("space-taxi", {
  best_ship = function(force, here, dest)
    local b = best_ship(game.forces[force], here, dest)
    return b and { name = b.platform.name, km = b.km, hops = b.hops, stops = b.stops } or nil
  end,
  ships_stopping_at = function(force, here)
    local out = {}
    for _, s in ipairs(ships_stopping_at(game.forces[force], here)) do table.insert(out, { name = s.platform.name, stops = s.stops }) end
    return out
  end,
  destinations = function(force, here)
    local out = {}
    for _, d in ipairs(destinations(game.forces[force], here)) do table.insert(out, { name = d.name, ship = d.ship.platform.name, km = d.ship.km }) end
    return out
  end,
  set_passengers = function(idx, v) storage.passengers[idx] = v end,
})
