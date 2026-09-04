local veloce = require("veloce")
local events = veloce.events
local timer = veloce.timer
local vehicle = veloce.vehicle

-- Synthetic demonstration values only. They are not production recommendations.
local low_threshold_volts = 11.5
local recovery_threshold_volts = 12.0
local confirmation_delay_ms = 2000

local current_voltage = nil
local confirmation_timer = nil
local armed = true

local function cancel_confirmation()
  if confirmation_timer ~= nil then
    timer.clear(confirmation_timer)
    confirmation_timer = nil
  end
end

local function publish_shutdown_if_still_low()
  confirmation_timer = nil
  if not armed or current_voltage == nil or
      current_voltage >= recovery_threshold_volts then
    return
  end

  armed = false
  events.publish("host.power.shutdown.request", {
    reason = "low_battery",
  })
end

local function on_battery_voltage(voltage)
  if type(voltage) ~= "number" then
    return
  end
  current_voltage = voltage

  if voltage >= recovery_threshold_volts then
    cancel_confirmation()
    armed = true
    return
  end

  if armed and voltage < low_threshold_volts and confirmation_timer == nil then
    confirmation_timer = timer.set_timeout(
      confirmation_delay_ms,
      publish_shutdown_if_still_low
    )
  end
end

function on_load()
  vehicle.subscribe("vehicle.battery.voltage", on_battery_voltage)
end

function on_unload()
  cancel_confirmation()
end
