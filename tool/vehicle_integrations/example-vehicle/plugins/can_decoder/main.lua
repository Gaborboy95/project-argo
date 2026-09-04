local veloce = require("veloce")
local can = veloce.can
local vehicle = veloce.vehicle

local function decode_engine_rpm(frame)
  local data = frame.data
  if type(data) ~= "table" or type(data[1]) ~= "number" or
      type(data[2]) ~= "number" then
    return
  end

  -- Synthetic example protocol: unsigned big-endian engine speed.
  vehicle.publish("engine.rpm", data[1] * 256 + data[2])
end

function on_load()
  can.subscribe({
    bus = "comfort",
    ids = { 0x280 },
    mask = 0x7FF,
  }, decode_engine_rpm)
end
