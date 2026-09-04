local veloce = require("veloce")
local events = veloce.events
local timer = veloce.timer
local vehicle = veloce.vehicle

local suspend_delay_ms = 1500
local current_power_state = "unknown"
local pending_timer = nil
local asleep_episode = false
local request_published = false

local function cancel_pending_timer()
  if pending_timer ~= nil then
    timer.clear(pending_timer)
    pending_timer = nil
  end
end

local function request_suspend_if_still_asleep()
  pending_timer = nil
  if current_power_state ~= "asleep" or not asleep_episode or
      request_published then
    return
  end

  request_published = true
  events.publish("host.power.suspend.request", {
    reason = "vehicle_standby",
  })
end

local function on_vehicle_power_state(state)
  current_power_state = state
  if state == "asleep" then
    if not asleep_episode then
      asleep_episode = true
      request_published = false
    end
    if pending_timer == nil and not request_published then
      pending_timer = timer.set_timeout(
        suspend_delay_ms,
        request_suspend_if_still_asleep
      )
    end
    return
  end

  cancel_pending_timer()
  asleep_episode = false
  request_published = false
end

function on_load()
  vehicle.subscribe("vehicle.power.state", on_vehicle_power_state)
end

function on_unload()
  cancel_pending_timer()
end
