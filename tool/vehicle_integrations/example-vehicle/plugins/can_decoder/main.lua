local veloce = require("veloce")
local can = veloce.can
local vehicle = veloce.vehicle

local power_states = {
  [0] = "unknown",
  [1] = "asleep",
  [2] = "awake",
  [3] = "active",
}

local function decode_engine_rpm(frame)
  local data = frame.data
  if type(data) ~= "table" or type(data[1]) ~= "number" or
      type(data[2]) ~= "number" then
    return
  end

  -- Synthetic example protocol: unsigned big-endian engine speed.
  vehicle.publish("engine.rpm", data[1] * 256 + data[2])
end

local function decode_vehicle_power(frame)
  local data = frame.data
  if type(data) ~= "table" or type(data[1]) ~= "number" then
    return
  end

  local state = power_states[data[1]]
  if state ~= nil then
    vehicle.publish("vehicle.power.state", state)
  end
end

local function decode_battery_voltage(frame)
  local data = frame.data
  if type(data) ~= "table" or type(data[1]) ~= "number" or
      type(data[2]) ~= "number" then
    return
  end

  local millivolts = data[1] * 256 + data[2]
  vehicle.publish("vehicle.battery.voltage", millivolts / 1000)
end

function on_load()
  can.subscribe({
    bus = "comfort",
    ids = { 0x280 },
    mask = 0x7FF,
  }, decode_engine_rpm)

  -- Synthetic test protocol; these identifiers do not represent a real car.
  can.subscribe({
    bus = "comfort",
    ids = { 0x500 },
    mask = 0x7FF,
  }, decode_vehicle_power)

  can.subscribe({
    bus = "comfort",
    ids = { 0x501 },
    mask = 0x7FF,
  }, decode_battery_voltage)
end
