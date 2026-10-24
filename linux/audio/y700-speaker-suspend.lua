-- y700-speaker-suspend.lua -- WirePlumber 0.5 hook. NOT INSTALLED (2026-10-16): see linux/audio/SUSPEND.md.
-- Installed as /usr/local/share/wireplumber/scripts/y700-speaker-suspend.lua, loaded by that absolute
-- path from /etc/wireplumber/wireplumber.conf.d/90-y700-speaker-suspend.conf (y700-speaker-suspend.conf
-- here). Never run: no Lua interpreter was available, not even for a syntax check.
--
-- Why: an ALSA sink that PipeWire reports as "idle" is NOT closed. WirePlumber gives every ALSA node
-- node.pause-on-idle = false (monitors/alsa.lua:189-190), so PipeWire neither pauses nor removes it from
-- the graph when it goes idle (impl-node.c:312, :480 in 1.6.2): the PCM keeps running on silence until
-- the session manager suspends it. On this tablet that means the q6apm stream + device graphs running in
-- the ADSP (one write-done GPR message per 480-frame period = ~100 messages/s), both aw882xx amplifiers
-- powered (they unmute at prepare and mute at hw_free), and PipeWire's ALSA timer at ~47 wakeups/s.
-- The stock node/suspend-node.lua sends ONE "Suspend" command after session.suspend-timeout-seconds
-- (default 5 s) and never looks again. PipeWire 1.6.0-1.6.2 (Ubuntu 26.04 ships 1.6.2-1ubuntu1.2)
-- refuses that command with -EBUSY while a port of the node has a link with a pending operation
-- (upstream bb0efd777, reverted for 1.6.3 as 1689b441d); nothing retries it, and the sink then stays
-- idle-but-open until something plays again. The refusal never reaches WirePlumber as an error (the
-- server drops a method's return value: pw_resource_notify -> spa_hook_list_call returns a hook count),
-- so the only way to notice it is to look at the node state again, which is what this does.
--
-- What it does: only for the built-in speaker sink. When the sink is STILL idle GRACE_MS after the stock
-- timeout, send Suspend again, up to MAX_RETRIES times RETRY_MS apart, then give up until the sink runs
-- again. A running or already suspended sink is never touched, and session.suspend-timeout-seconds = 0
-- (suspend disabled on purpose) is honoured. When the stock suspend works, this hook only arms and
-- cancels a timer per idle period.

log = Log.open_topic ("s-y700-suspend")

local HW = "alsa_output.platform-sound.HiFi__Speaker__sink"
local GRACE_MS = 3000      -- after the stock timeout, before the first extra Suspend
local RETRY_MS = 3000
local MAX_RETRIES = 5

local pending = nil

local function cancel ()
  if pending ~= nil then
    pending:destroy ()
    pending = nil
  end
end

local function bound (node)
  return (node:get_active_features () & Feature.Proxy.BOUND) ~= 0
end

local function arm (node, delay_ms, tries)
  pending = Core.timeout_add (delay_ms, function ()
    pending = nil
    if not bound (node) or node ["state"] ~= "idle" then
      return false
    end
    if tries >= MAX_RETRIES then
      log:warning (node, string.format (
          "%s still idle after %d extra Suspend commands; leaving it until it runs again", HW, tries))
      return false
    end
    log:notice (node, string.format (
        "%s idle but not suspended; sending Suspend again (%d/%d)", HW, tries + 1, MAX_RETRIES))
    node:send_command ("Suspend")
    arm (node, RETRY_MS, tries + 1)
    -- false (G_SOURCE_REMOVE): one-shot source, the next one is a new timeout
    return false
  end)
end

SimpleEventHook {
  name = "node/y700-speaker-suspend",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-state-changed" },
      Constraint { "media.class", "=", "Audio/Sink" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    if node.properties ["node.name"] ~= HW then
      return
    end
    -- any state change ends the previous watch (running again, suspended, error)
    cancel ()
    local new_state = event:get_properties () ["event.subject.new-state"]
    if new_state ~= "idle" then
      return
    end
    local timeout = tonumber (node.properties ["session.suspend-timeout-seconds"]) or 5
    if timeout == 0 then
      return
    end
    arm (node, math.floor (timeout * 1000) + GRACE_MS, 0)
  end
}:register ()

log:notice ("y700-speaker-suspend loaded: re-sends Suspend to " .. HW .. " if it stays idle")
