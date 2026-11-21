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

local BOARD_TICKS = 40 * 60      -- rocket flight from the silo to the ship, plus a margin
local UNKNOWN_WAIT = 60 * 60     -- guess for a stop that waits for items/signals and was never observed
local SWITCH_MARGIN = 15 * 60    -- a destination booking moves to another ship only if it is this much faster
local DEFAULT_KM_PER_TICK = 100 / 60

local function init_storage()
  storage.passengers = storage.passengers or {}
  storage.bookings = storage.bookings or {}
  storage.holds = storage.holds or {}
  storage.silos = storage.silos or {} -- [silo unit number] = player index holding its rocket
  -- storage.stats[platform index] = {dwell = {[record key] = {avg, n, max}}, leg = {[from \0 to] = {avg, n}},
  --   kmpt (learned km per tick), at_key, at_name, at_tick, tainted, left_from, left_tick}
  storage.stats = storage.stats or {}
end
local busy = {} -- players whose booking is being processed (pausing a ship raises events right away)

-- versions before 0.3.1 could leave a silo switched off after an interrupted launch: switch those back on
local function unfreeze_silos()
  local owned = {}
  for _, b in pairs(storage.bookings) do if b.silo and b.silo.valid then owned[b.silo.unit_number] = true end end
  for _, s in pairs(game.surfaces) do
    for _, silo in pairs(s.find_entities_filtered { type = "rocket-silo" }) do
      if silo.disabled_by_script and not owned[silo.unit_number] then
        silo.disabled_by_script = false
        storage.silos[silo.unit_number] = nil
      end
    end
  end
end

script.on_init(init_storage)
script.on_configuration_changed(function(e)
  init_storage()
  local c = e.mod_changes and e.mod_changes["space-taxi"]
  if c and c.old_version and helpers.compare_versions(c.old_version, "0.3.1") < 0 then unfreeze_silos() end
end)

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
  if not (p and p.valid and p.hub and p.hub.valid and (p.scheduled_for_deletion or 0) == 0) then return false end
  if not p.paused then return true end
  local h = storage.holds[p.index] -- paused by Space Taxi for a passenger: still in automatic mode
  return h ~= nil and h.we_paused
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

---------------------------------------------------------------- learning how long ships really take

local function stats_of(p)
  local st = storage.stats[p.index]
  if not st then st = { dwell = {}, leg = {} }; storage.stats[p.index] = st end
  return st
end

-- running average (recent runs count more), number of samples and maximum
local function learn(t, v)
  if not t.n or t.n == 0 then t.avg, t.n, t.max = v, 1, v
  else t.avg = t.avg + (v - t.avg) * 0.3; t.n = t.n + 1; t.max = math.max(t.max or v, v) end
end

local function rec_key(i, station) return i .. ":" .. tostring(station) end
local function leg_key(a, b) return a .. "\0" .. b end

local STATE = defines.space_platform_state

-- called whenever a ship changes state: measures how long it stays at each stop and how long each flight takes
-- (stops where the ship was paused, by Space Taxi or by hand, are not counted)
local function observe(p)
  if not (p and p.valid) then return end
  local st = stats_of(p)
  local state = p.state
  local loc = p.space_location and p.space_location.name
  if state == STATE.paused then
    if st.at_tick then st.tainted = true else st.left_tick = nil end
  elseif state == STATE.waiting_at_station or state == STATE.waiting_for_departure then
    if st.at_tick and st.at_name == loc then return end -- the same visit (e.g. unpaused again)
    local s = p.schedule
    if not (s and loc) then return end
    if st.left_tick and st.left_from and st.left_from ~= loc then
      local ticks = game.tick - st.left_tick
      local k = leg_key(st.left_from, loc)
      st.leg[k] = st.leg[k] or {}
      learn(st.leg[k], ticks)
      local km = distance(st.left_from, loc)
      if ticks > 0 and km > 0 and km < 1e8 then
        local v = km / ticks
        st.kmpt = st.kmpt and (st.kmpt + (v - st.kmpt) * 0.3) or v
      end
    end
    st.at_tick, st.at_name, st.at_key, st.tainted = game.tick, loc, rec_key(s.current, loc), false
    st.left_tick, st.left_from = nil, nil
  elseif state == STATE.on_the_path or state == STATE.no_path then
    -- the wait conditions are done (with no path the ship is stuck, but its stop is over)
    if st.at_tick then
      if not st.tainted then
        st.dwell[st.at_key] = st.dwell[st.at_key] or {}
        learn(st.dwell[st.at_key], game.tick - st.at_tick)
      end
      st.left_from, st.left_tick = st.at_name, game.tick
      st.at_tick, st.at_name, st.at_key = nil, nil, nil
    end
  end
end

---------------------------------------------------------------- estimating arrival times

-- what a stop's wait conditions guarantee:
--   "none" (leaves at once), "fixed" (only time conditions), "capped" (one OR branch is only a time), "open" (could be forever)
-- returns kind, upper bound in ticks (nil for "open")
local function wait_info(rec)
  local wc = rec and rec.wait_conditions
  if not wc or #wc == 0 then return "none", 0 end
  local bound, all_timed, group = nil, true, nil
  local function close(g)
    if not g then return end
    if g.timed then bound = math.min(bound or g.t, g.t) else all_timed = false end
  end
  for i, c in ipairs(wc) do
    if i == 1 or c.compare_type == "or" then close(group); group = { t = 0, timed = true } end
    if c.type == "time" then group.t = math.max(group.t, c.ticks or 0) else group.timed = false end
  end
  close(group)
  if all_timed then return "fixed", bound end
  if bound then return "capped", bound end
  return "open", nil
end

-- expected wait at record i: what was observed there, else what the conditions say
-- returns ticks, unsure (an "open" stop never observed)
local function est_wait(st, i, rec)
  local d = st.dwell[rec_key(i, rec.station)]
  if d and d.n and d.n > 0 then return d.avg, false end
  local kind, bound = wait_info(rec)
  if kind == "open" then return UNKNOWN_WAIT, true end
  return bound or 0, false
end

local function km_per_tick(st)
  return (st.kmpt and st.kmpt > 0) and st.kmpt or DEFAULT_KM_PER_TICK
end

local function est_travel(st, a, b)
  if not (a and b) or a == b then return 0 end
  local leg = st.leg[leg_key(a, b)]
  if leg and leg.n and leg.n > 0 then return leg.avg end
  return distance(a, b) / km_per_tick(st)
end

-- flight time left to `target` for a ship in flight
local function remaining_travel(p, st, target)
  if st.left_from and st.left_tick then
    local leg = st.leg[leg_key(st.left_from, target)]
    if leg and leg.n and leg.n > 0 then return math.max(0, leg.avg - (game.tick - st.left_tick)) end
  end
  local c = p.space_connection
  if c and p.distance then
    local len, d = c.length, p.distance
    local to_end = (1 - d) * len + distance(c.to.name, target)
    local to_start = d * len + distance(c.from.name, target)
    local last = p.last_visited_space_location
    local km
    if last and last.name == c.from.name then km = to_end
    elseif last and last.name == c.to.name then km = to_start
    else km = math.min(to_end, to_start) end
    return km / km_per_tick(st)
  end
  local from = st.left_from or (p.last_visited_space_location and p.last_visited_space_location.name)
  return est_travel(st, from, target)
end

-- the ship's next visits in order: {i, station, arrive, leave, unsure}, times in ticks from now
local function timeline(p, count)
  local s = p.schedule
  local out = {}
  if not (s and s.records and #s.records > 0) then return out end
  local recs, n, cur = s.records, #s.records, s.current or 1
  local st = stats_of(p)
  local first = recs[cur]
  local loc = p.space_location and p.space_location.name
  local arrive, w, unsure
  w, unsure = est_wait(st, cur, first)
  if loc and loc == first.station then
    arrive = 0
    if st.at_tick and st.at_name == loc then w = math.max(0, w - (game.tick - st.at_tick)) end
  else
    arrive = first.station and remaining_travel(p, st, first.station) or 0
  end
  -- unsure: this stop's own wait is a guess; u: the arrival here depends on such a guess
  local prev = { i = cur, station = first.station, arrive = arrive, leave = arrive + w, unsure = unsure, u = false, here = loc == first.station }
  out[1] = prev
  for k = 1, count - 1 do
    local j = (cur - 1 + k) % n + 1
    local r = recs[j]
    local a = prev.leave + est_travel(st, prev.station, r.station)
    local ww, u = est_wait(st, j, r)
    prev = { i = j, station = r.station, arrive = a, leave = a + ww, unsure = u, u = prev.u or prev.unsure }
    out[#out + 1] = prev
  end
  return out
end

-- a ride on ship p from `here` (to `dest`, if given)
-- returns {platform, pickup, arrive, unsure, hops, stops} or nil; `skip_now` ignores a visit going on right now
local function trip(p, here, dest, skip_now)
  local s = p.schedule
  if not (s and s.records and #s.records > 0) then return nil end
  local n = #s.records
  local tl = timeline(p, 2 * n + 1)
  local at0 = tl[1] and tl[1].here
  for k = 1, n + 1 do
    local v = tl[k]
    if v and v.station == here and not (k == 1 and at0 and skip_now) then
      local stops = at0 and k - 1 or k
      if not dest then return { platform = p, pickup = v.arrive, stops = stops, unsure = v.u } end
      -- after boarding, the ship waits at `here` again (its wait restarts when Space Taxi lets it go)
      local full = est_wait(stats_of(p), v.i, s.records[v.i])
      local shift = (v.arrive + BOARD_TICKS + full) - v.leave
      for m = k + 1, #tl do
        local w = tl[m]
        if w.station == dest then
          return { platform = p, pickup = v.arrive, arrive = w.arrive + shift, unsure = w.u, hops = m - k, stops = stops }
        end
      end
      return nil
    end
  end
  return nil
end

local function faster(a, b)
  if not b then return true end
  if math.abs(a.arrive - b.arrive) > 60 then return a.arrive < b.arrive end
  if a.hops ~= b.hops then return a.hops < b.hops end
  return a.pickup < b.pickup
end

-- ships in automatic mode that have `here` in their schedule, soonest first
local function ships_stopping_at(force, here)
  local out = {}
  for _, p in pairs(force.platforms) do
    if is_auto(p) then
      local t = trip(p, here, nil)
      if t then
        t.at_here = t.stops == 0
        table.insert(out, t)
      end
    end
  end
  table.sort(out, function(a, b) if a.pickup ~= b.pickup then return a.pickup < b.pickup end return a.platform.index < b.platform.index end)
  return out
end

-- the passenger ship that gets you from `here` to `dest` soonest
local function best_ship(force, here, dest)
  local best
  for _, p in pairs(force.platforms) do
    if is_auto(p) and accepts_passengers(p) then
      local t = trip(p, here, dest)
      if t and faster(t, best) then best = t end
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
  table.sort(out, function(a, b) return a.ship.arrive < b.ship.arrive end)
  return out
end

local function fmt_ticks(t)
  local s = math.floor(t / 60 + 0.5)
  if s >= 3600 then return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60) end
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
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
  elseif b.stage == "launched" or b.stage == "docking" then text = { "space-taxi.status-launched", name }
  elseif b.stage == "aboard" then text = { "space-taxi.status-aboard", name, loc_label(b.to) }
  else text = { "space-taxi.status-landing", loc_label(b.to or "nauvis") } end
  local eta, unsure
  if b.platform.valid then
    if b.stage == "seating" or b.stage == "seated" then
      local t = trip(b.platform, b.from, nil, b.missed)
      if t and t.pickup > 0 then eta, unsure = t.pickup, t.unsure end
    elseif b.stage == "aboard" then
      for _, v in ipairs(timeline(b.platform, #(b.platform.schedule and b.platform.schedule.records or {}) + 1)) do
        if v.station == b.to then
          if v.arrive > 0 then eta, unsure = v.arrive, v.u end
          break
        end
      end
    end
  end
  if eta then text = { "", text, "  [color=0.7,0.7,0.7]~" .. fmt_ticks(eta) .. (unsure and " ?" or "") .. "[/color]" } end
  if b.note then text = { "", text, "  [color=1,0.6,0.3]", { "space-taxi." .. b.note }, "[/color]" } end
  f.add { type = "label", caption = text, tooltip = unsure and { "space-taxi.unsure-tip" } or nil }
  if b.stage ~= "launched" and b.stage ~= "docking" and b.stage ~= "landing" then
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
  if not (silo and silo.valid) or b.stage ~= "seated" then return end -- pausing the ship can run step_booking again
  silo.disabled_by_script = false
  -- regular deliveries to a platform go to its hub as a "station"
  local ok = silo.launch_rocket({ type = defines.cargo_destination.station, station = p.hub }, player.character)
  if not ok then
    if silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready then silo.disabled_by_script = true end
    return
  end
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

-- a destination booking is not tied to one ship: until the rocket launches, it moves to whichever ship
-- gets there clearly sooner, or to a passenger ship that is in orbit right now and is no slower
local function rebook(player, b)
  local p = b.platform
  if p.valid and ship_here(p, b.from) and not b.missed then return end -- the booked ship is here: board it
  local best = best_ship(player.force, b.from, b.to)
  if not best or best.platform == p then return end
  local cur = p.valid and is_auto(p) and accepts_passengers(p) and trip(p, b.from, b.to, b.missed)
  if cur and best.arrive > cur.arrive - SWITCH_MARGIN and not ship_here(best.platform, b.from) then return end
  if p.valid then release(p.index, player.index) end
  b.platform, b.missed = best.platform, nil
end

local function book(player, p, to)
  local here = here_of(player)
  if not here then return end
  cancel(player)
  local b = { platform = p, from = here, to = to, stage = "seating", since = game.tick }
  storage.bookings[player.index] = b
  seat(player, b)
  if b.stage == "seated" and ship_here(p, here) then
    busy[player.index] = true
    launch(player, b)
    busy[player.index] = nil
  end
  update_status(player)
end

local function arrived_on_ship(player, b)
  free_silo(b)
  if player.cargo_pod and player.cargo_pod.valid then
    -- on the ship's surface, but the pod is still coming down onto the hub: keep holding the ship
    b.stage, b.note = "docking", nil
    update_status(player)
    return
  end
  release(b.platform.index, player.index)
  if b.to then
    b.stage, b.note = "aboard", nil
    try_land(player, b)
  else
    storage.bookings[player.index] = nil
  end
  update_status(player)
end

local function step_booking_now(player_index)
  local b = storage.bookings[player_index]
  local player = game.get_player(player_index)
  if not b then return end
  if (b.stage == "launched" or b.stage == "docking") and player and player.valid and b.platform.valid and player.physical_surface == b.platform.surface then
    arrived_on_ship(player, b)
    return
  end
  -- the rocket never left (e.g. the launch was interrupted): sit down again and wait for the ship
  if b.stage == "launched" and player and player.valid and game.tick - (b.since or 0) > 90 * 60
    and b.platform.valid and player.physical_surface ~= b.platform.surface and here_of(player) == b.from then
    b.stage, b.note = "seating", nil
  end
  if player and player.valid and b.to and (b.stage == "seating" or b.stage == "seated") then rebook(player, b) end
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

local function step_booking(player_index)
  if busy[player_index] then return end
  busy[player_index] = true
  step_booking_now(player_index)
  busy[player_index] = nil
end

script.on_event(defines.events.on_space_platform_changed_state, function(e)
  observe(e.platform)
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
    arrived_on_ship(player, b)
  elseif surface ~= b.platform.surface and b.stage == "landing" then
    release(b.platform.index, e.player_index)
    storage.bookings[e.player_index] = nil
    update_status(player)
  end
end)

-- the passenger's pod has come down on the ship's hub (or a planet): continue at once
script.on_event(defines.events.on_cargo_pod_finished_descending, function(e)
  if e.player_index and storage.bookings[e.player_index] then step_booking(e.player_index) end
end)

script.on_nth_tick(60, function()
  for pi in pairs(storage.bookings) do step_booking(pi) end
  for idx, h in pairs(storage.holds) do
    if not h.platform.valid then storage.holds[idx] = nil
    elseif game.tick >= h.until_tick then
      local flying = false -- never let the ship go while a passenger's rocket is on its way to it
      for pi in pairs(h.players) do
        local b = storage.bookings[pi]
        if b and (b.stage == "launched" or b.stage == "docking") then flying = true end
      end
      if flying then h.until_tick = game.tick + 60 * 30 end
    end
    if h.platform.valid and game.tick >= h.until_tick then
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

local function add_row(tbl, sprite_name, caption, info, button_caption, tags, unsure)
  local l = tbl.add { type = "label", caption = caption }
  l.style.minimal_width = 160
  if unsure then info = { "", info, " [color=1,0.6,0.3]?[/color]" } end
  local i = tbl.add { type = "label", caption = info, tooltip = unsure and { "space-taxi.unsure-tip" } or nil }
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
          { "space-taxi.via", d.ship.platform.name, "~" .. fmt_ticks(d.ship.arrive), stops_text(d.ship.stops) },
          { "space-taxi.go" }, { space_taxi = "dest", dest = d.name }, d.ship.unsure)
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
        local info = stops_text(s.stops, s.at_here)
        if not s.at_here then info = { "", info, " · ~" .. fmt_ticks(s.pickup) } end
        add_row(t, nil, s.platform.name, info, { "space-taxi.wait" },
          { space_taxi = "ship", platform = s.platform.index }, not s.at_here and s.unsure)
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
    return b and { name = b.platform.name, arrive = b.arrive, pickup = b.pickup, unsure = b.unsure, hops = b.hops, stops = b.stops } or nil
  end,
  ships_stopping_at = function(force, here)
    local out = {}
    for _, s in ipairs(ships_stopping_at(game.forces[force], here)) do table.insert(out, { name = s.platform.name, stops = s.stops, pickup = s.pickup, unsure = s.unsure }) end
    return out
  end,
  destinations = function(force, here)
    local out = {}
    for _, d in ipairs(destinations(game.forces[force], here)) do table.insert(out, { name = d.name, ship = d.ship.platform.name, arrive = d.ship.arrive }) end
    return out
  end,
  wait_info = function(rec) return { wait_info(rec) } end,
  stats = function(idx) return storage.stats[idx] end,
  booking = function(pi)
    local b = storage.bookings[pi]
    return b and { ship = b.platform.valid and b.platform.name, stage = b.stage, to = b.to } or nil
  end,
  set_passengers = function(idx, v) storage.passengers[idx] = v end,
})
