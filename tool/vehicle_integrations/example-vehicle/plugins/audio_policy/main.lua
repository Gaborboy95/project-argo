local veloce = require("veloce")
local events = veloce.events
local vehicle = veloce.vehicle

local controls = {
  {
    signal = "controls.audio.volume_up.pressed",
    topic = "audio.command.volume.up",
    pressed = false,
  },
  {
    signal = "controls.audio.volume_down.pressed",
    topic = "audio.command.volume.down",
    pressed = false,
  },
  {
    signal = "controls.audio.mute.pressed",
    topic = "audio.command.mute.toggle",
    pressed = false,
  },
  {
    signal = "controls.audio.source_next.pressed",
    topic = "audio.command.source.next",
    pressed = false,
  },
  {
    signal = "controls.audio.source_previous.pressed",
    topic = "audio.command.source.previous",
    pressed = false,
  },
}

local function observe(control)
  vehicle.subscribe(control.signal, function(value)
    local pressed = value == true
    if pressed and not control.pressed then
      events.publish(control.topic, {})
    end
    control.pressed = pressed
  end)
end

function on_load()
  for _, control in ipairs(controls) do
    observe(control)
  end
end
