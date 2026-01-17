-- ShamanForge: sandbox-safe bootstrap + slash/macro compatibility for Turtle WoW (1.12, Lua 5.0)

local __SF_REAL_G = _G
local __SF_REAL_G_SOURCE = "initial"

local function __sf_resolve_real_g()
  local envs = {}
  if type(getfenv) == "function" then
    envs[#envs + 1] = getfenv(0)
  end
  if type(getfenv) == "function" then
    if type(CreateFrame) == "function" then
      envs[#envs + 1] = getfenv(CreateFrame)
    end
    if type(ChatEdit_SendText) == "function" then
      envs[#envs + 1] = getfenv(ChatEdit_SendText)
    end
    if type(RunScript) == "function" then
      envs[#envs + 1] = getfenv(RunScript)
    end
  end

  local function resolve_env(env)
    if type(env) ~= "table" then
      return nil, nil
    end
    if rawget(env, "_G") == env then
      return env, "direct"
    end
    local mt = getmetatable(env)
    if mt and type(mt.__index) == "table" then
      local idx = mt.__index
      if rawget(idx, "_G") == idx then
        return idx, "metatable"
      end
    end
    return nil, nil
  end

  for _, env in ipairs(envs) do
    local resolved, source = resolve_env(env)
    if resolved then
      __SF_REAL_G_SOURCE = source
      return resolved
    end
  end

  __SF_REAL_G_SOURCE = "fallback"
  return _G
end

__SF_REAL_G = __sf_resolve_real_g()

pcall(setfenv, 1, __SF_REAL_G)

rawset(__SF_REAL_G, "__SF_DIAG_MARKER", "SF_BOOT_OK")

local ShamanForge = rawget(__SF_REAL_G, "ShamanForge")
if type(ShamanForge) ~= "table" then
  ShamanForge = {}
  rawset(__SF_REAL_G, "ShamanForge", ShamanForge)
end

if type(rawget(__SF_REAL_G, "ShamanForgeDB")) ~= "table" then
  rawset(__SF_REAL_G, "ShamanForgeDB", {})
end

if type(rawget(__SF_REAL_G, "ShamanForgeCharDB")) ~= "table" then
  rawset(__SF_REAL_G, "ShamanForgeCharDB", {})
end

ShamanForge.__hooks = ShamanForge.__hooks or { RunLine = false, ChatEdit = false }
ShamanForge.SuperWoW_LOS_MASK = ShamanForge.SuperWoW_LOS_MASK or 272

local function __sf_print(msg)
  if type(__SF_REAL_G.DEFAULT_CHAT_FRAME) == "table" and type(__SF_REAL_G.DEFAULT_CHAT_FRAME.AddMessage) == "function" then
    __SF_REAL_G.DEFAULT_CHAT_FRAME:AddMessage(msg)
  elseif type(__SF_REAL_G.print) == "function" then
    __SF_REAL_G.print(msg)
  end
end

local function __sf_get_netstats()
  if type(GetNetStats) == "function" then
    local bandwidthIn, bandwidthOut, lagHome, lagWorld = GetNetStats()
    return bandwidthIn, bandwidthOut, lagHome, lagWorld
  end
  return nil
end

local function __sf_get_queue_window()
  local _, _, lagHome, lagWorld = __sf_get_netstats()
  local lag = lagWorld or lagHome or 0
  local jitter = 0
  local windowMs
  if type(__SF_REAL_G.NP_SpellQueueWindowMs) == "number" then
    windowMs = __SF_REAL_G.NP_SpellQueueWindowMs
  elseif type(GetCVar) == "function" then
    local cvarWindow = tonumber(GetCVar("SpellQueueWindow"))
    if cvarWindow and cvarWindow > 0 then
      windowMs = cvarWindow
    end
  end
  if not windowMs then
    windowMs = lag + jitter
  end
  return windowMs / 1000, lag, jitter, windowMs
end

local function __sf_nampower_available()
  return type(QueueSpellByName) == "function"
end

local function __sf_get_nampower_version()
  if type(GetNampowerVersion) == "function" then
    local major, minor, patch = GetNampowerVersion()
    return tostring(major) .. "." .. tostring(minor) .. "." .. tostring(patch)
  end
  return nil
end

function ShamanForge:QueueSpell(spellName)
  if type(spellName) ~= "string" or spellName == "" then
    return false
  end
  if __sf_nampower_available() then
    local ok = pcall(QueueSpellByName, spellName)
    return ok
  end
  return false
end

function ShamanForge:RotationStep()
  local db = rawget(__SF_REAL_G, "ShamanForgeDB")
  local spellName = db and db.TestSpellName
  if type(spellName) == "string" and spellName ~= "" then
    return self:QueueSpell(spellName)
  end
  return false
end

function ShamanForge:PrintDiag()
  local marker = rawget(__SF_REAL_G, "__SF_DIAG_MARKER")
  local envSource = __SF_REAL_G_SOURCE
  local hasSlash = type(__SF_REAL_G.SlashCmdList) == "table" and type(__SF_REAL_G.SlashCmdList.SHAMANFORGE) == "function"
  local hash = __SF_REAL_G.hash_SlashCmdList
  local hashSf = type(hash) == "table" and hash["sf"]
  local hasQueue = __sf_nampower_available()
  local window, lag, jitter, windowMs = __sf_get_queue_window()
  local npVersion = __sf_get_nampower_version()
  local cvarQueueCooldown
  local cvarQueueGcd
  if type(GetCVar) == "function" then
    cvarQueueCooldown = GetCVar("QueueOnCooldown")
    cvarQueueGcd = GetCVar("QueueOnGCD")
  end
  local castSpellId
  local castRemainingMs
  local gcdRemainingMs
  if type(GetCastInfo) == "function" then
    local castInfo = GetCastInfo()
    if castInfo then
      castSpellId = castInfo.spellId
      castRemainingMs = castInfo.castRemainingMs
      gcdRemainingMs = castInfo.gcdRemainingMs
    end
  end

  __sf_print("[ShamanForge] marker=" .. tostring(marker))
  __sf_print("[ShamanForge] env_source=" .. tostring(envSource))
  __sf_print("[ShamanForge] table=" .. tostring(rawget(__SF_REAL_G, "ShamanForge")) .. " type=" .. type(rawget(__SF_REAL_G, "ShamanForge")))
  __sf_print("[ShamanForge] RotationStep=" .. tostring(rawget(__SF_REAL_G, "ShamanForge_RotationStep")) .. " type=" .. type(rawget(__SF_REAL_G, "ShamanForge_RotationStep")))
  __sf_print("[ShamanForge] slash registered=" .. tostring(hasSlash) .. " hash_sf=" .. tostring(hashSf))
  __sf_print("[ShamanForge] hooks RunLine=" .. tostring(self.__hooks.RunLine) .. " ChatEdit=" .. tostring(self.__hooks.ChatEdit))
  __sf_print("[ShamanForge] NamPower queue=" .. tostring(hasQueue) .. " version=" .. tostring(npVersion) .. " ping_ms=" .. tostring(lag or 0) .. " jitter_ms=" .. tostring(jitter) .. " window_ms=" .. tostring(windowMs) .. " window_s=" .. string.format("%.3f", window))
  __sf_print("[ShamanForge] SuperWoW_LOS_MASK=" .. tostring(self.SuperWoW_LOS_MASK))
  __sf_print("[ShamanForge] cast spell_id=" .. tostring(castSpellId) .. " cast_remaining_ms=" .. tostring(castRemainingMs) .. " gcd_remaining_ms=" .. tostring(gcdRemainingMs))
  if cvarQueueCooldown or cvarQueueGcd then
    __sf_print("[ShamanForge] CVars QueueOnCooldown=" .. tostring(cvarQueueCooldown) .. " QueueOnGCD=" .. tostring(cvarQueueGcd))
  end
end

local function __sf_handle_slash(msg)
  local text = msg or ""
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" then
    return ShamanForge:RotationStep()
  end
  if text == "diag" or text == "debug" then
    ShamanForge:PrintDiag()
    return true
  end
  if text == "help" then
    __sf_print("[ShamanForge] /sf - run one decision step")
    __sf_print("[ShamanForge] /sf diag - diagnostics")
    __sf_print("[ShamanForge] /sf debug - diagnostics")
    return true
  end
  return ShamanForge:RotationStep()
end

rawset(__SF_REAL_G, "ShamanForge_RotationStep", function()
  return ShamanForge:RotationStep()
end)

local function __sf_register_slash()
  if type(__SF_REAL_G.SlashCmdList) ~= "table" then
    __SF_REAL_G.SlashCmdList = {}
  end
  __SF_REAL_G.SLASH_SHAMANFORGE1 = "/sf"
  __SF_REAL_G.SLASH_SHAMANFORGE2 = "/shamanforge"
  __SF_REAL_G.SlashCmdList.SHAMANFORGE = __sf_handle_slash

  if type(__SF_REAL_G.hash_SlashCmdList) == "table" then
    __SF_REAL_G.hash_SlashCmdList["sf"] = "SHAMANFORGE"
    __SF_REAL_G.hash_SlashCmdList["shamanforge"] = "SHAMANFORGE"
  end
end

__sf_register_slash()

local function __sf_parse_macro_line(line)
  if type(line) ~= "string" then
    return nil, nil
  end
  local cmd, rest = string.match(line, "^%s*/%s*(%S+)%s*(.-)%s*$")
  return cmd, rest
end

local function __sf_try_handle_line(line)
  local cmd, rest = __sf_parse_macro_line(line)
  if not cmd then
    return false
  end
  cmd = string.lower(cmd)
  if cmd == "sf" or cmd == "shamanforge" then
    __sf_handle_slash(rest)
    return true
  end
  return false
end

if type(__SF_REAL_G.RunLine) == "function" and not ShamanForge.__hooks.RunLine then
  local __sf_orig_runline = __SF_REAL_G.RunLine
  __SF_REAL_G.RunLine = function(line, ...)
    if __sf_try_handle_line(line) then
      return true
    end
    return __sf_orig_runline(line, ...)
  end
  ShamanForge.__hooks.RunLine = true
end

if type(__SF_REAL_G.ChatEdit_SendText) == "function" and not ShamanForge.__hooks.ChatEdit then
  local __sf_orig_chat_send = __SF_REAL_G.ChatEdit_SendText
  __SF_REAL_G.ChatEdit_SendText = function(editBox, addHistory, ...)
    if editBox and type(editBox.GetText) == "function" then
      local text = editBox:GetText()
      if __sf_try_handle_line(text) then
        if type(editBox.SetText) == "function" then
          editBox:SetText("")
        end
        if type(__SF_REAL_G.ChatEdit_OnEscapePressed) == "function" then
          __SF_REAL_G.ChatEdit_OnEscapePressed(editBox)
        end
        return
      end
    end
    return __sf_orig_chat_send(editBox, addHistory, ...)
  end
  ShamanForge.__hooks.ChatEdit = true
end

rawset(__SF_REAL_G, "ShamanForge", ShamanForge)
rawset(__SF_REAL_G, "ShamanForgeDB", rawget(__SF_REAL_G, "ShamanForgeDB"))
rawset(__SF_REAL_G, "ShamanForgeCharDB", rawget(__SF_REAL_G, "ShamanForgeCharDB"))
