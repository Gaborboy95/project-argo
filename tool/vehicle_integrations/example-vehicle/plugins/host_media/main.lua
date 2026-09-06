local veloce = require("veloce")
local last_epoch, last_revision, last_summary

local function read_current()
  -- Event payloads are untrusted hints. Only this permission-checked read is authoritative.
  local state = argo_host.snapshot()
  if state.epoch == last_epoch and state.revision == last_revision then return end
  last_epoch, last_revision = state.epoch, state.revision
  local phone = state.projection.sessions[1]
  local media
  for _, source in ipairs(state.media.sources) do
    if source.sourceId == state.media.activeSourceId then media = source end
  end
  local summary
  if not state.available then
    summary = "Host media unavailable"
  elseif phone == nil then
    summary = "Host media disconnected"
  else
    summary = (phone.protocol or "unknown") .. "/" .. (phone.transport or "unknown")
      .. " | " .. (phone.deviceName or "unknown phone")
      .. " | " .. (media and media.title or "unknown track")
      .. " | " .. (media and media.playbackState or "unknown")
  end
  -- Position-only updates do not spam logs. This explicitly installed demo uses DEBUG.
  if summary ~= last_summary then
    last_summary = summary
    veloce.log.debug(summary)
  end
end

function on_load()
  -- Subscribe before the initial read: safe when already connected or reloaded.
  veloce.events.subscribe("argo.host.state.changed.v1", function(_) read_current() end)
  read_current()
end
-- Veloce owns and removes this generation's event subscription on unload/reload.
