--[[-----------------------------------------------------------------------------
ShamanForge v1.5.1 (Perfected)
- NamPower CVar Safety Protocol (Snapshot + Differential Restore + Crash/Zone FSM)
- Smart Queue Manager (World Latency + Jitter -> QueueWindow)
- SuperWoW LoS Engine (TraceLine 0x110 + Double-Ray)
- Totem Tracking v2 (ObjectList + GUID owner + TTL fallback), no GetTotemInfo
- PvP Reactive Layer (Interrupt Sniper / Grounding / Tremor) + Manual RotationStep()
Lua 5.0: global localization + no per-frame table allocations from our side
-----------------------------------------------------------------------------]]--

-- ====== Real UI global export (sandbox-proof, Lua 5.0) =======================
--
-- В некоторых сборках Turtle WoW (VanillaFixes/SuperMacro/прочие моды) аддоны
-- могут выполняться в отдельном environment table (setfenv). Тогда глобалы,
-- созданные в getfenv(0), не видны из /run.
--
-- Паттерн ниже НЕ пытается "угадать" что такое _G по одному признаку.
-- Мы:
--  1) берём env аддона (env0)
--  2) если у env0 есть metatable.__index == table, считаем её "базовой" (UI)
--  3) публикуем API в env0 И в базовую таблицу, чтобы /run и макросы видели
--
local __env0 = getfenv(0)
local __mt   = getmetatable(__env0)
local __base = (__mt and type(__mt.__index) == 'table') and __mt.__index or __env0

-- Доп. кандидат (иногда _G в env0 реально указывает на базовую таблицу)
local __g1 = rawget(__env0, '_G')
if type(__g1) == 'table' and __g1 ~= __env0 then
  __base = __g1
end

local function __pub(t, k, v)
  if type(t) == 'table' then rawset(t, k, v) end
end

-- Собираем/создаём канонические таблицы
local __SS  = rawget(__env0, 'ShamanForge') or rawget(__base, 'ShamanForge')
local __DB  = rawget(__env0, 'ShamanForgeDB') or rawget(__base, 'ShamanForgeDB')
local __CDB = rawget(__env0, 'ShamanForgeCharDB') or rawget(__base, 'ShamanForgeCharDB')

if type(__SS)  ~= 'table' then __SS  = {} end
if type(__DB)  ~= 'table' then __DB  = {} end
if type(__CDB) ~= 'table' then __CDB = {} end

-- Публикация в env аддона и в "базу" (то, что обычно видит /run)
__pub(__env0, 'ShamanForge', __SS)
__pub(__env0, 'ShamanForgeDB', __DB)
__pub(__env0, 'ShamanForgeCharDB', __CDB)

__pub(__base, 'ShamanForge', __SS)
__pub(__base, 'ShamanForgeDB', __DB)
__pub(__base, 'ShamanForgeCharDB', __CDB)
__pub(__base, 'ShamanForge_151', __SS)

-- Маркер (быстрый тест из /run)
__pub(__base, '__SF_DIAG_MARKER', 'SF_BOOT_OK')

-- Макро-энтрипоинты
local function __SF_RotationStep() if __SS and __SS.RotationStep then return __SS.RotationStep() end end
local function __SF_GetNet()       if __SS and __SS.GetNet       then return __SS.GetNet()       end end
local function __SF_GetTotems()    if __SS and __SS.GetTotems    then return __SS.GetTotems()    end end

__pub(__base, 'ShamanForge_RotationStep', __SF_RotationStep)
__pub(__base, 'ShamanForge_GetNet', __SF_GetNet)
__pub(__base, 'ShamanForge_GetTotems', __SF_GetTotems)

-- Диагностический вызов
__pub(__base, 'ShamanForge_DIAG', function()
  local p = rawget(__base, 'print') or print
  p('__SF_DIAG_MARKER=', rawget(__base, '__SF_DIAG_MARKER'),
    'env0.ShamanForge=', rawget(__env0, 'ShamanForge'),
    'base.ShamanForge=', rawget(__base, 'ShamanForge'),
    'base.RotationStep=', rawget(__base, 'ShamanForge_RotationStep'))
end)

-- Видимый BOOT-пинг
do
  local uief = rawget(__base, 'UIErrorsFrame')
  if uief and uief.AddMessage then pcall(uief.AddMessage, uief, 'ShamanForge: BOOT OK') end
  local chat = rawget(__base, 'DEFAULT_CHAT_FRAME')
  if chat and chat.AddMessage then pcall(chat.AddMessage, chat, '|cff33ff99ShamanForge|r: BOOT OK') end
end


-- ====== Puppeteer/SuperMacro macro-visibility bridge =========================
-- Некоторые песочницы макросов не читают переменные напрямую (name lookup),
-- а используют getglobal()/setglobal() и/или SlashCmdList. Поэтому мы:
--  1) дублируем экспорт через setglobal (если есть)
--  2) даём чат-команды /sf и /shamanforge, чтобы вообще не зависеть от /run.

local __setglobal = rawget(__base, 'setglobal') or rawget(__env0, 'setglobal')
local function __setg(k, v)
  if type(__setglobal) == 'function' then
    pcall(__setglobal, k, v)
  end
end

-- Дублируем ключевые экспорты через setglobal
__setg('ShamanForge', __SS)
__setg('ShamanForgeDB', __DB)
__setg('ShamanForgeCharDB', __CDB)
__setg('__SF_DIAG_MARKER', rawget(__base, '__SF_DIAG_MARKER'))
__setg('ShamanForge_RotationStep', rawget(__base, 'ShamanForge_RotationStep'))
__setg('ShamanForge_GetNet',       rawget(__base, 'ShamanForge_GetNet'))
__setg('ShamanForge_GetTotems',    rawget(__base, 'ShamanForge_GetTotems'))
__setg('ShamanForge_DIAG',         rawget(__base, 'ShamanForge_DIAG'))

-- Slash command entrypoints: /sf [step|diag|on|off]
local __SlashCmdList = rawget(__base, 'SlashCmdList') or rawget(__env0, 'SlashCmdList')
local __string = rawget(__base, 'string') or string
local __strlower = (__string and __string.lower) or (string and string.lower)

if type(__SlashCmdList) == 'table' then
  __setg('SLASH_SHAMANFORGE1', '/sf')
  __setg('SLASH_SHAMANFORGE2', '/shamanforge')

  __SlashCmdList['SHAMANFORGE'] = function(msg)
    msg = tostring(msg or '')
    local m = __strlower and __strlower(msg) or msg

    if m == 'diag' then
      local f = rawget(__base, 'ShamanForge_DIAG')
      if type(f) == 'function' then f() end
      return
    end

    if m == 'off' then
      if __SS and __SS.SetReactive then __SS.SetReactive(false) end
      return
    end
    if m == 'on' then
      if __SS and __SS.SetReactive then __SS.SetReactive(true) end
      return
    end

    -- default: one rotation step
    local step = rawget(__base, 'ShamanForge_RotationStep')
    if type(step) == 'function' then
      step()
    elseif __SS and __SS.RotationStep then
      __SS.RotationStep()
    end
  end

  -- Ensure /sf is registered in hash_SlashCmdList (Vanilla chat parser)
  local __import = rawget(__base, "ChatFrame_ImportListToHash") or rawget(__env0, "ChatFrame_ImportListToHash") or ChatFrame_ImportListToHash
  if type(__import) == "function" then pcall(__import) end

  local __hash = rawget(__base, "hash_SlashCmdList") or rawget(__env0, "hash_SlashCmdList")
  if type(__hash) == "table" then
    __hash["/sf"] = "SHAMANFORGE"
    __hash["/shamanforge"] = "SHAMANFORGE"
  end
end

-- ====== Global localization (Lua 5.0) =======================================
local _G              = getfenv(0)
local tostring        = _G.tostring
local tonumber        = _G.tonumber
local type            = _G.type
local select          = _G.select
local pcall           = _G.pcall
local getfenv         = _G.getfenv
local setfenv         = _G.setfenv

local math            = _G.math
local math_abs        = math.abs
local math_floor      = math.floor
local math_min        = math.min
local math_max        = math.max

local string          = _G.string
local strlower        = string.lower
local strfind         = string.find

local CreateFrame     = _G.CreateFrame
local DEFAULT_CHAT_FRAME = _G.DEFAULT_CHAT_FRAME

local GetTime         = _G.GetTime
local GetNetStats     = _G.GetNetStats

local GetCVar         = _G.GetCVar
local SetCVar         = _G.SetCVar

local UnitExists      = _G.UnitExists
local UnitName        = _G.UnitName
local UnitClass       = _G.UnitClass
local UnitIsEnemy     = _G.UnitIsEnemy
local UnitIsPlayer    = _G.UnitIsPlayer
local UnitIsUnit      = _G.UnitIsUnit
local UnitHealth      = _G.UnitHealth
local UnitHealthMax   = _G.UnitHealthMax
local UnitMana        = _G.UnitMana
local UnitManaMax     = _G.UnitManaMax
local UnitDebuff      = _G.UnitDebuff
local UnitBuff        = _G.UnitBuff

local GetWeaponEnchantInfo = _G.GetWeaponEnchantInfo
local SpellStopCasting     = _G.SpellStopCasting

local GetSpellCooldown     = _G.GetSpellCooldown
local IsUsableSpell        = _G.IsUsableSpell
local GetSpellBookItemInfo = _G.GetSpellBookItemInfo
local GetSpellBookItemName = _G.GetSpellBookItemName
local CastSpell            = _G.CastSpell

-- SuperWoW / SuperAPI (may be nil if not injected)
local TraceLine        = _G.TraceLine
local UnitPosition     = _G.UnitPosition
local UnitCastingInfo  = _G.UnitCastingInfo

local ObjectList       = _G.ObjectList
local ObjectGUID       = _G.ObjectGUID
local ObjectName       = _G.ObjectName
local ObjectType       = _G.ObjectType
local ObjectIsTotem    = _G.ObjectIsTotem
local ObjectIsAlive    = _G.ObjectIsAlive

-- Turtle Spell DB optional fallback (if present)
local TurtleSpellDB_GetSpell = _G.TurtleSpellDB_GetSpell

-- ====== Addon tables =========================================================
if not _G.ShamanForgeDB then _G.ShamanForgeDB = {} end
if not _G.ShamanForgeCharDB then _G.ShamanForgeCharDB = {} end

local DB  = _G.ShamanForgeDB
local CDB = _G.ShamanForgeCharDB

if not _G.ShamanForge then _G.ShamanForge = {} end
local SS = _G.ShamanForge

-- ====== Constants ============================================================
local BOOKTYPE_SPELL = "spell"

local STATE_INIT   = 0
local STATE_ACTIVE = 1
local STATE_PAUSED = 2
local STATE_STOP   = 3

-- SuperWoW LoS mask: 0x110 (WMO + Terrain). Lua 5.0 НЕ поддерживает hex-литералы 0x...
-- поэтому задаём маску в десятичном виде.
local LOS_MASK = 272

-- Timers (seconds)
local UPDATE_NET_EVERY     = 0.20
local UPDATE_TOTEMS_EVERY  = 0.25
local UPDATE_REACTIVE_EVERY= 0.07  -- interrupt/grd checks ~14Hz (light)

-- Jitter window
local PING_SAMPLES = 10

-- NamPower deadband/rate limit
local NP_MIN_APPLY_INTERVAL = 0.25
local NP_DEADBAND_MS        = 5

-- GCD probe: use a low-impact spell if present; fallback handled
local GCD_PROBE_SPELLID = 2484 -- Earthbind Totem

-- PvP reactive safety
local FAKECAST_GUARD_SEC = 0.20

-- ====== Spell IDs (static, known vanilla) ===================================
-- NOTE: Turtle custom spells should be set in DB if needed.
local SPELL = {
  -- Interrupt / Shocks
  EARTH_SHOCK_R1  = 8042,
  FROST_SHOCK_R1  = 8056,

  -- Totems
  EARTHBIND_TOTEM = 2484,
  TREMOR_TOTEM    = 8143,
  SEARING_TOTEM   = 10438,
  POISON_CLEANSE  = 8166,
  DISEASE_CLEANSE = 8170,
  GROUNDING_TOTEM = 8177,

  -- Enhancer core
  STORMSTRIKE     = 17364,

  -- Weapon imbue (rank 4 windfury as reference)
  WINDFURY_WEAPON_R4 = 16362,
}

-- “Families” for auto-detection by name (last rank in spellbook wins)
local AUTO_FAMILY = {
  -- ru/en (you can extend if you play in another locale)
  WINDFURY_WEAPON = { "Windfury Weapon", "Неистовство ветра" },
  LIGHTNING_SHIELD= { "Lightning Shield", "Молниеносный щит" },
  EARTH_SHOCK     = { "Earth Shock", "Удар земли" },
  FROST_SHOCK     = { "Frost Shock", "Ледяной шок" },
  GRACE_OF_AIR    = { "Grace of Air Totem", "Тотем грации воздуха" },

  -- Turtle custom (best effort; set exact IDs in DB if you want 100%)
  WATER_SHIELD    = { "Water Shield", "Водяной щит" },
  MOLTEN_BLAST    = { "Molten Blast", "Расплавленный взрыв" },
}

-- Totem durations (seconds) – TTL fallback
local TOTEM_TTL = {
  [SPELL.EARTHBIND_TOTEM] = 45,
  [SPELL.TREMOR_TOTEM]    = 120,
  [SPELL.SEARING_TOTEM]   = 60,
  [SPELL.POISON_CLEANSE]  = 120,
  [SPELL.DISEASE_CLEANSE] = 120,
  [SPELL.GROUNDING_TOTEM] = 45,
}

-- Totem slots (logical)
local TOTEM_SLOT_EARTH = 1
local TOTEM_SLOT_FIRE  = 2
local TOTEM_SLOT_WATER = 3
local TOTEM_SLOT_AIR   = 4

-- ====== Default DB ===========================================================
if DB.cfg == nil then DB.cfg = {} end
local CFG = DB.cfg

if CFG.enableNamPower == nil then CFG.enableNamPower = true end
if CFG.enableReactive == nil then CFG.enableReactive = true end
if CFG.enableLoS == nil then CFG.enableLoS = true end
if CFG.enableTotems == nil then CFG.enableTotems = true end

-- Tunables
if CFG.minBufferMs == nil then CFG.minBufferMs = 60 end
if CFG.queueMinMs  == nil then CFG.queueMinMs  = 120 end
if CFG.queueMaxMs  == nil then CFG.queueMaxMs  = 420 end
if CFG.extraSafetyMs == nil then CFG.extraSafetyMs = 60 end

-- LoS offsets (yards)
if CFG.eyeZ   == nil then CFG.eyeZ   = 1.70 end
if CFG.headZ  == nil then CFG.headZ  = 1.40 end
if CFG.feetZ  == nil then CFG.feetZ  = 0.20 end

-- Optional: if you know your Turtle custom spellIDs, set them here once
if DB.customSpellID == nil then DB.customSpellID = {} end
local CUSTOM = DB.customSpellID
-- CUSTOM.WATER_SHIELD = <yourID>
-- CUSTOM.MOLTEN_BLAST = <yourID>

-- ====== Internal state =======================================================
local state = STATE_INIT
local playerGUID = nil

-- Spellbook maps
local spellIndexByID = {}
local lastRankIDByFamily = {} -- resolved “max rank” by family key
local gcdProbeIndex = nil

-- NamPower state
local npAvailable = false
local npSnapshot = nil         -- [cvar]=string
local npChanged  = nil         -- [cvar]=string
local npDirty    = 0           -- persisted flag
local npLastApplyTime = 0
local npWantedQueueMs = nil
local npLastAppliedQueueMs = nil

-- CVars we may use (only those that exist)
local NP_KEYS = {
  "NP_SpellQueueWindowMs", "NP_QueueWindow",
  "NP_MinBufferTimeMs",
  "NP_QueueInstantSpells",
  "NP_QueueChannelSpells", "NP_ChannelQueueWindowMs",
  "NP_QueueTargetingSpells", "NP_TargetingQueueWindowMs",
  "NP_QueueSpellsOnCooldown", "NP_CooldownQueueWindowMs",
  "NP_QueueSpellsOnGCD",
}

local npPresent = {} -- [key]=true/false

-- Net sampling
local netAccum = 0
local pingSamples = {}
local pingPos = 1
local pingCount = 0

local lastWorldPingMs = 0
local lastJitterMs = 0

-- Totem tracker
local totemAccum = 0
local totems = {
  [TOTEM_SLOT_EARTH] = { spellID = 0, guid = nil, expires = 0 },
  [TOTEM_SLOT_FIRE]  = { spellID = 0, guid = nil, expires = 0 },
  [TOTEM_SLOT_WATER] = { spellID = 0, guid = nil, expires = 0 },
  [TOTEM_SLOT_AIR]   = { spellID = 0, guid = nil, expires = 0 },
}
local pendingTotemSlot = 0
local pendingTotemSpell = 0
local pendingTotemUntil = 0

-- Reactive loop
local reactiveAccum = 0
local lastInterruptTime = 0

-- ====== Utils ================================================================
local function Chat(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ShamanForge|r: "..msg)
  end
end

local function NowMs()
  return GetTime() * 1000
end

local function Clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

-- Safe get world latency (some clients return 3, others 4)
local function GetWorldLatencyMs()
  local a, b, c, d = GetNetStats()
  -- Typical possibilities:
  -- 3 returns: down/up/latency  -> c
  -- 4+ returns: ..., home, world -> d
  local w = d or c or 0
  if type(w) ~= "number" then w = tonumber(w) or 0 end
  return w
end

-- ====== Spellbook scan: build spellID -> index map ===========================
local function BuildSpellbookMaps()
  -- wipe without allocating new table
  for k in pairs(spellIndexByID) do spellIndexByID[k] = nil end
  for k in pairs(lastRankIDByFamily) do lastRankIDByFamily[k] = nil end

  local i = 1
  while true do
    local st, id = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
    if not st then break end
    if id and type(id) == "number" then
      spellIndexByID[id] = i
    end

    -- Family auto-detection: last seen rank in spellbook wins
    local name = GetSpellBookItemName(i, BOOKTYPE_SPELL)
    if name and name ~= "" and id and type(id) == "number" then
      -- iterate our families
      for famKey, aliases in pairs(AUTO_FAMILY) do
        local j = 1
        while aliases[j] do
          if name == aliases[j] then
            lastRankIDByFamily[famKey] = id
            break
          end
          j = j + 1
        end
      end
    end

    i = i + 1
  end

  -- GCD probe
  gcdProbeIndex = spellIndexByID[GCD_PROBE_SPELLID]
  if not gcdProbeIndex then
    -- fallback: any known spell that exists
    gcdProbeIndex = spellIndexByID[SPELL.EARTHBIND_TOTEM] or spellIndexByID[SPELL.EARTH_SHOCK_R1] or nil
  end
end

-- ====== GCD check ============================================================
local function IsGCDReady()
  if not gcdProbeIndex then return true end
  local start, dur, enabled = GetSpellCooldown(gcdProbeIndex, BOOKTYPE_SPELL)
  if enabled ~= 1 then return true end
  if not start or start == 0 or not dur or dur == 0 then
    return true
  end
  local t = GetTime()
  return (start + dur) <= t
end

-- ====== Cast by spellID safely (via spellbook index) =========================
local function IsUsableByIndex(idx)
  if not idx then return false end
  local ok, usable, nomana = pcall(IsUsableSpell, idx, BOOKTYPE_SPELL)
  if ok then
    if usable then return true end
    return false
  end
  -- fallback: try with name (slower but safe)
  local name = GetSpellBookItemName(idx, BOOKTYPE_SPELL)
  if not name then return false end
  ok, usable, nomana = pcall(IsUsableSpell, name)
  if ok and usable then return true end
  return false
end

local function IsReadyByIndex(idx)
  if not idx then return false end
  local start, dur, enabled = GetSpellCooldown(idx, BOOKTYPE_SPELL)
  if enabled ~= 1 then return true end
  if not start or start == 0 or not dur or dur == 0 then
    return true
  end
  return (start + dur) <= GetTime()
end

-- Remaining cooldown in milliseconds (0 if ready)
local function RemainMsByIndex(idx)
  if not idx then return 0 end
  local start, dur, enabled = GetSpellCooldown(idx, BOOKTYPE_SPELL)
  if enabled ~= 1 then return 0 end
  if not start or start == 0 or not dur or dur == 0 then return 0 end
  local t = GetTime()
  local rem = (start + dur) - t
  if rem <= 0 then return 0 end
  return math_floor(rem * 1000)
end

local function GCDRemainMs()
  if not gcdProbeIndex then return 0 end
  return RemainMsByIndex(gcdProbeIndex)
end


local function CastBySpellID(spellID)
  if not spellID or spellID == 0 then return false end
  local idx = spellIndexByID[spellID]
  if not idx then return false end

  -- NamPower queue window aware gating:
  -- If NP is available, we allow attempting the cast slightly early (within queue window)
  -- so button-spam reliably queues the correct spell.
  local queueMs = (npLastAppliedQueueMs or npWantedQueueMs or 0)
  if npAvailable and queueMs and queueMs > 0 then
    local gcdRem  = GCDRemainMs()
    local spellRem= RemainMsByIndex(idx)
    if gcdRem > queueMs then return false end
    if spellRem > queueMs then return false end
  else
    -- strict vanilla gating
    if not IsGCDReady() then return false end
    if not IsReadyByIndex(idx) then return false end
  end

  if not IsUsableByIndex(idx) then return false end
  CastSpell(idx, BOOKTYPE_SPELL)
  return true
end

-- Resolve “max rank” for a family, prefer custom explicit ID if set
local function GetFamilyMaxID(famKey, customKey)
  if customKey and CUSTOM[customKey] and CUSTOM[customKey] ~= 0 then
    return CUSTOM[customKey]
  end
  return lastRankIDByFamily[famKey]
end

-- ====== NamPower detection & safe CVar layer =================================
local function NP_Detect()
  if not CFG.enableNamPower then
    npAvailable = false
    return
  end

  npAvailable = false
  for i = 1, #NP_KEYS do
    npPresent[NP_KEYS[i]] = false
  end

  -- If GetCVar errors on unknown CVar, pcall will fail.
  for i = 1, #NP_KEYS do
    local k = NP_KEYS[i]
    local ok = pcall(GetCVar, k)
    if ok then
      npPresent[k] = true
      npAvailable = true
    end
  end
end

local function NP_Snapshot()
  if not npAvailable then return end
  npSnapshot = {}
  npChanged  = {}

  for i = 1, #NP_KEYS do
    local k = NP_KEYS[i]
    if npPresent[k] then
      local v = GetCVar(k)
      if v ~= nil then
        npSnapshot[k] = tostring(v)
      end
    end
  end

  -- persist “dirty” recovery data (crash-safe best effort)
  if CDB.npGuard == nil then CDB.npGuard = {} end
  CDB.npGuard.snapshot = npSnapshot
  CDB.npGuard.dirty = 1
end

local function NP_MarkCleanIfPossible()
  if CDB.npGuard then
    CDB.npGuard.dirty = 0
  end
end

local function NP_SafeSet(k, v)
  if not npAvailable then return false end
  if not npPresent[k] then return false end
  if not v then return false end
  v = tostring(v)

  -- deadband for numbers
  local old = GetCVar(k)
  if old ~= nil and v == tostring(old) then
    return false
  end

  local ok = pcall(SetCVar, k, v)
  if ok then
    npChanged[k] = v
    -- persist dirty state
    if CDB.npGuard then CDB.npGuard.dirty = 1 end
    return true
  end
  return false
end

local function NP_ApplyQueueMs(queueMs)
  if not npAvailable then return end

  local now = GetTime()
  if (now - npLastApplyTime) < NP_MIN_APPLY_INTERVAL then return end

  -- clamp and deadband
  queueMs = Clamp(queueMs, CFG.queueMinMs, CFG.queueMaxMs)

  if npLastAppliedQueueMs and math_abs(queueMs - npLastAppliedQueueMs) <= NP_DEADBAND_MS then
    return
  end

  npLastApplyTime = now
  npLastAppliedQueueMs = queueMs

  -- Prefer NP_SpellQueueWindowMs, fallback to NP_QueueWindow
  if npPresent["NP_SpellQueueWindowMs"] then
    NP_SafeSet("NP_SpellQueueWindowMs", queueMs)
  elseif npPresent["NP_QueueWindow"] then
    NP_SafeSet("NP_QueueWindow", queueMs)
  end

  -- Keep useful toggles if present
  if npPresent["NP_MinBufferTimeMs"] then
    NP_SafeSet("NP_MinBufferTimeMs", CFG.minBufferMs)
  end
  if npPresent["NP_QueueInstantSpells"] then
    NP_SafeSet("NP_QueueInstantSpells", 1)
  end
  if npPresent["NP_QueueSpellsOnCooldown"] then
    NP_SafeSet("NP_QueueSpellsOnCooldown", 1)
  end
  if npPresent["NP_QueueSpellsOnGCD"] then
    NP_SafeSet("NP_QueueSpellsOnGCD", 1)
  end
end

local function NP_PauseQueue()
  if not npAvailable then return end
  -- Critical: keep it minimal during unload.
  if npPresent["NP_SpellQueueWindowMs"] then
    NP_SafeSet("NP_SpellQueueWindowMs", 0)
  elseif npPresent["NP_QueueWindow"] then
    NP_SafeSet("NP_QueueWindow", 0)
  end
end

local function NP_RestoreSnapshotDifferential()
  if not npAvailable then return end
  if not npSnapshot then return end
  if not npChanged then return end

  for k, changedVal in pairs(npChanged) do
    local orig = npSnapshot[k]
    if orig ~= nil and tostring(changedVal) ~= tostring(orig) then
      pcall(SetCVar, k, tostring(orig))
    end
  end

  NP_MarkCleanIfPossible()
end

local function NP_RecoverIfDirty()
  if not CDB.npGuard then return end
  if CDB.npGuard.dirty ~= 1 then return end
  local snap = CDB.npGuard.snapshot
  if not snap then return end

  -- Try to restore the last known snapshot (after a crash)
  for k, v in pairs(snap) do
    pcall(SetCVar, k, tostring(v))
  end
  CDB.npGuard.dirty = 0
  Chat("Восстановил NamPower CVar snapshot после некорректного завершения.")
end

-- ====== Net jitter sampling ==================================================
local function UpdateNet()
  local w = GetWorldLatencyMs()
  lastWorldPingMs = w

  -- ring buffer (no allocations)
  pingSamples[pingPos] = w
  pingPos = pingPos + 1
  if pingPos > PING_SAMPLES then pingPos = 1 end
  if pingCount < PING_SAMPLES then pingCount = pingCount + 1 end

  -- jitter = max-min of window
  local mn = pingSamples[1] or w
  local mx = mn
  local i = 2
  while i <= pingCount do
    local v = pingSamples[i]
    if v then
      if v < mn then mn = v end
      if v > mx then mx = v end
    end
    i = i + 1
  end
  lastJitterMs = mx - mn

  -- smart queue: ping + safety + half jitter, clamped
  local q = w + CFG.extraSafetyMs + math_floor(lastJitterMs * 0.5)
  npWantedQueueMs = q
end

-- ====== LoS Engine ===========================================================
local function GetUnitPos(unit)
  if not UnitPosition then return nil end
  local x, y, z, mapID = UnitPosition(unit)
  if not x or not y or not z then return nil end
  return x, y, z, mapID
end

local function LoS_DoubleRay(targetUnit)
  if not CFG.enableLoS then return true end
  if not TraceLine or not UnitPosition then return true end

  local px, py, pz, pm = GetUnitPos("player")
  if not px then return false end

  local tx, ty, tz, tm = GetUnitPos(targetUnit)
  if not tx then return false end
  if pm and tm and pm ~= tm then return false end

  -- eye -> head & eye -> feet
  local eyeZ  = pz + CFG.eyeZ
  local headZ = tz + CFG.headZ
  local feetZ = tz + CFG.feetZ

  local hit1 = TraceLine(px, py, eyeZ, tx, ty, headZ, LOS_MASK)
  if hit1 == false then return true end

  local hit2 = TraceLine(px, py, eyeZ, tx, ty, feetZ, LOS_MASK)
  if hit2 == false then return true end

  return false
end

-- ====== Totem Tracking v2 ====================================================
local function IsLikelyTotemObject(obj)
  if ObjectIsTotem then
    return ObjectIsTotem(obj) and true or false
  end
  if ObjectType then
    local t = ObjectType(obj)
    if t == "TOTEM" or t == 8 then return true end
  end
  if ObjectName then
    local n = ObjectName(obj)
    if n and n ~= "" then
      local ln = strlower(n)
      if strfind(ln, "totem", 1, true) or strfind(ln, "тотем", 1, true) then
        return true
      end
    end
  end
  return false
end

local function Totem_ClearSlot(slot)
  local s = totems[slot]
  s.spellID = 0
  s.guid = nil
  s.expires = 0
end

local function Totem_SetSlot(slot, spellID, guid, expires)
  local s = totems[slot]
  s.spellID = spellID or 0
  s.guid = guid
  s.expires = expires or 0
end

local function Totem_SlotForSpell(spellID)
  if spellID == SPELL.EARTHBIND_TOTEM or spellID == SPELL.TREMOR_TOTEM then
    return TOTEM_SLOT_EARTH
  elseif spellID == SPELL.SEARING_TOTEM then
    return TOTEM_SLOT_FIRE
  elseif spellID == SPELL.POISON_CLEANSE or spellID == SPELL.DISEASE_CLEANSE then
    return TOTEM_SLOT_WATER
  elseif spellID == SPELL.GROUNDING_TOTEM then
    return TOTEM_SLOT_AIR
  end
  return 0
end

local function Totem_IsAlive(slot)
  local s = totems[slot]
  if not s.guid then
    return (s.expires and s.expires > GetTime()) and true or false
  end
  if ObjectIsAlive then
    local ok, alive = pcall(ObjectIsAlive, s.guid)
    if ok and alive ~= nil then
      return alive and true or false
    end
  end
  return (s.expires and s.expires > GetTime()) and true or false
end

local function Totem_Scan()
  if not CFG.enableTotems then return end
  if not ObjectList or not ObjectGUID or not UnitExists then return end
  if not playerGUID then return end

  -- expire TTL
  local now = GetTime()
  if totems[TOTEM_SLOT_EARTH].expires ~= 0 and totems[TOTEM_SLOT_EARTH].expires <= now then Totem_ClearSlot(TOTEM_SLOT_EARTH) end
  if totems[TOTEM_SLOT_FIRE].expires  ~= 0 and totems[TOTEM_SLOT_FIRE].expires  <= now then Totem_ClearSlot(TOTEM_SLOT_FIRE)  end
  if totems[TOTEM_SLOT_WATER].expires ~= 0 and totems[TOTEM_SLOT_WATER].expires <= now then Totem_ClearSlot(TOTEM_SLOT_WATER) end
  if totems[TOTEM_SLOT_AIR].expires   ~= 0 and totems[TOTEM_SLOT_AIR].expires   <= now then Totem_ClearSlot(TOTEM_SLOT_AIR)   end

  local list = ObjectList()
  if not list then return end

  -- pending assignment window
  local pending = (pendingTotemSlot ~= 0 and pendingTotemUntil > now)

  local i = 1
  while list[i] do
    local obj = list[i]
    if obj then
      local guid = ObjectGUID(obj)
      if guid then
        -- owner pattern: UnitExists(guid.."owner") -> ownerGUID (SuperWoW behavior)
        local ok, ownerGUID = UnitExists(guid.."owner")
        if ok and ownerGUID and ownerGUID == playerGUID then
          -- likely one of our objects; filter totems
          if IsLikelyTotemObject(obj) then
            if pending then
              -- bind first matching owned totem object to pending slot if slot empty or guid differs
              local s = totems[pendingTotemSlot]
              if not s.guid or s.guid ~= guid then
                local ttl = TOTEM_TTL[pendingTotemSpell] or 120
                Totem_SetSlot(pendingTotemSlot, pendingTotemSpell, guid, now + ttl)
                pendingTotemSlot = 0
                pendingTotemSpell = 0
                pendingTotemUntil = 0
                pending = false
              end
            end
          end
        end
      end
    end
    i = i + 1
  end
end

-- ====== SuperWoW CASTEVENT (best-effort) =====================================
local function OnUnitCastEvent()
  -- SuperWoW typically exposes UNIT_CASTEVENT with globals arg1..argN (1.12 style).
  -- We treat it best-effort. If absent/mismatched, it simply won't bind pending totem.
  local casterGUID = _G.arg1
  local spellID    = _G.arg4

  if not casterGUID or not spellID then return end
  if casterGUID ~= playerGUID then return end
  if type(spellID) ~= "number" then spellID = tonumber(spellID) or 0 end
  if spellID == 0 then return end

  local slot = Totem_SlotForSpell(spellID)
  if slot ~= 0 then
    -- mark pending: next scan will bind to GUID
    pendingTotemSlot = slot
    pendingTotemSpell = spellID
    pendingTotemUntil = GetTime() + 0.75

    local ttl = TOTEM_TTL[spellID] or 120
    -- update TTL immediately even before GUID resolves
    Totem_SetSlot(slot, spellID, totems[slot].guid, GetTime() + ttl)
  end
end

-- ====== Reactive PvP layer ===================================================
-- Minimal interrupt classification (you can extend)
local HEAL_KEYWORDS = { "heal", "flash", "greater", "touch", "regrowth", "holy light", "healing", "исцел", "вспыш", "велик", "свет небес", "целебн" }
local CC_KEYWORDS   = { "polymorph", "fear", "hibernate", "cyclone", "roots", "sap", "овц", "страх", "корни", "сон" }

local function MatchKeywords(spellName, keywords)
  if not spellName or spellName == "" then return false end
  local s = strlower(spellName)
  local i = 1
  while keywords[i] do
    if strfind(s, keywords[i], 1, true) then return true end
    i = i + 1
  end
  return false
end

local function InterruptPriority(spellName)
  if MatchKeywords(spellName, HEAL_KEYWORDS) then return 3 end
  if MatchKeywords(spellName, CC_KEYWORDS) then return 2 end
  return 1
end

local function Reactive_InterruptSniper()
  if not CFG.enableReactive then return false end
  if not UnitCastingInfo then return false end
  if not UnitExists("target") then return false end
  if not UnitIsEnemy("player", "target") then return false end

  -- SuperWoW UnitCastingInfo returns start/end in ms
  local spell, rank, displayName, icon, startMs, endMs = UnitCastingInfo("target")
  if not spell or not endMs or not startMs then return false end

  local nowMs = NowMs()
  local elapsed = (nowMs - startMs) * 0.001
  if elapsed < FAKECAST_GUARD_SEC then return false end

  local remainingMs = endMs - nowMs
  if remainingMs < 0 then return false end

  local pingMs = lastWorldPingMs
  local window = pingMs + 60

  if remainingMs <= window then
    -- throttle interrupts
    local now = GetTime()
    if (now - lastInterruptTime) < 0.20 then return false end

    -- LoS check (optional)
    if CFG.enableLoS and not LoS_DoubleRay("target") then
      return false
    end

    -- stop our cast if needed (best-effort)
    pcall(SpellStopCasting)

    if CastBySpellID(SPELL.EARTH_SHOCK_R1) then
      lastInterruptTime = now
      return true
    end
  end

  return false
end


local function Reactive_Grounding()
  if not CFG.enableReactive then return false end
  if not UnitCastingInfo then return false end
  if not UnitExists("target") then return false end
  if not UnitIsEnemy("player", "target") then return false end
  if not UnitExists("targettarget") or not UnitIsUnit("targettarget", "player") then return false end

  local spell, rank, displayName, icon, startMs, endMs = UnitCastingInfo("target")
  if not spell or not endMs then return false end

  if Totem_IsAlive(TOTEM_SLOT_AIR) and totems[TOTEM_SLOT_AIR].spellID == SPELL.GROUNDING_TOTEM then
    return false
  end

  if CFG.enableLoS and not LoS_DoubleRay("target") then
    return false
  end

  if CastBySpellID(SPELL.GROUNDING_TOTEM) then return true end
  return false
end


local function Reactive_TremorContext()
  if not CFG.enableReactive then return false end
  if not UnitExists("target") then return false end
  if not UnitIsEnemy("player", "target") then return false end

  local _, class = UnitClass("target")
  if not class then return false end

  -- Warlock/Priest/Warrior -> Tremor
  if class == "WARLOCK" or class == "PRIEST" or class == "WARRIOR" then
    if Totem_IsAlive(TOTEM_SLOT_EARTH) and totems[TOTEM_SLOT_EARTH].spellID == SPELL.TREMOR_TOTEM then
      return false
    end
    if CastBySpellID(SPELL.TREMOR_TOTEM) then return true end
  end

  return false
end

-- ====== Manual DPS rotation entrypoint

-- ====== Manual DPS rotation entrypoint

-- ====== Manual DPS rotation entrypoint-- ====== Manual DPS rotation entrypoint ======================================
function SS.RotationStep()
  if state ~= STATE_ACTIVE then return end
  if not UnitExists("target") then return end
  if not UnitIsEnemy("player", "target") then return end


  -- Reactive layer is ONLY executed on button press (RotationStep)
  if CFG.enableReactive then
    if Reactive_InterruptSniper() then return end
    if Reactive_Grounding() then return end
    if Reactive_TremorContext() then return end
  end

  -- 1) Weapon imbue: maintain Windfury Weapon
  local hasMH = false
  if GetWeaponEnchantInfo then
    local mh = GetWeaponEnchantInfo()
    hasMH = mh and true or false
  end
  if not hasMH then
    -- prefer detected max rank, else fallback to known R4
    local wf = GetFamilyMaxID("WINDFURY_WEAPON") or SPELL.WINDFURY_WEAPON_R4
    if CastBySpellID(wf) then return end
  end

  -- 2) Shield logic (Turtle): Water Shield <60% mana else Lightning Shield
  local mana = UnitMana("player") or 0
  local manam = UnitManaMax("player") or 1
  local manaPct = (manam > 0) and (mana / manam) or 1

  if manaPct < 0.60 then
    local ws = GetFamilyMaxID("WATER_SHIELD", "WATER_SHIELD")
    if ws and CastBySpellID(ws) then return end
  else
    local ls = GetFamilyMaxID("LIGHTNING_SHIELD")
    if ls and CastBySpellID(ls) then return end
  end

  -- 3) Totems (context-aware) – light and safe (no spam if already alive)
  -- Earth: vs Warlock/Priest/Warrior -> Tremor else Earthbind
  local _, class = UnitClass("target")
  if class == "WARLOCK" or class == "PRIEST" or class == "WARRIOR" then
    if not (Totem_IsAlive(TOTEM_SLOT_EARTH) and totems[TOTEM_SLOT_EARTH].spellID == SPELL.TREMOR_TOTEM) then
      if CastBySpellID(SPELL.TREMOR_TOTEM) then return end
    end
  else
    if not (Totem_IsAlive(TOTEM_SLOT_EARTH) and totems[TOTEM_SLOT_EARTH].spellID == SPELL.EARTHBIND_TOTEM) then
      if CastBySpellID(SPELL.EARTHBIND_TOTEM) then return end
    end
  end

  -- Fire: only Searing
  if not (Totem_IsAlive(TOTEM_SLOT_FIRE) and totems[TOTEM_SLOT_FIRE].spellID == SPELL.SEARING_TOTEM) then
    if CastBySpellID(SPELL.SEARING_TOTEM) then return end
  end

  -- Water: Poison/Disease cleansing only if needed
  local needPoison = false
  local needDisease= false
  local i = 1
  while true do
    local deb = UnitDebuff("player", i)
    if not deb then break end
    local l = strlower(deb)
    -- very rough; better: match by debuff type if your client provides it
    if strfind(l, "poison", 1, true) or strfind(l, "яд", 1, true) then needPoison = true end
    if strfind(l, "disease",1,true) or strfind(l, "болез",1,true) then needDisease = true end
    i = i + 1
  end
  if needPoison then
    if not (Totem_IsAlive(TOTEM_SLOT_WATER) and totems[TOTEM_SLOT_WATER].spellID == SPELL.POISON_CLEANSE) then
      if CastBySpellID(SPELL.POISON_CLEANSE) then return end
    end
  elseif needDisease then
    if not (Totem_IsAlive(TOTEM_SLOT_WATER) and totems[TOTEM_SLOT_WATER].spellID == SPELL.DISEASE_CLEANSE) then
      if CastBySpellID(SPELL.DISEASE_CLEANSE) then return end
    end
  end

  -- Air: Grounding if target is casting at us, else Grace of Air
  if UnitExists("targettarget") and UnitIsUnit("targettarget", "player") and UnitCastingInfo then
    if not (Totem_IsAlive(TOTEM_SLOT_AIR) and totems[TOTEM_SLOT_AIR].spellID == SPELL.GROUNDING_TOTEM) then
      if CastBySpellID(SPELL.GROUNDING_TOTEM) then return end
    end
  else
    local goa = GetFamilyMaxID("GRACE_OF_AIR")
    if goa then
      if not (Totem_IsAlive(TOTEM_SLOT_AIR) and totems[TOTEM_SLOT_AIR].spellID == goa) then
        if CastBySpellID(goa) then return end
      end
    end
  end

  -- 4) Damage core
  -- Stormstrike on cooldown
  if CastBySpellID(SPELL.STORMSTRIKE) then return end

  -- Molten Blast (Turtle custom) on cooldown if configured/detected
  local mb = GetFamilyMaxID("MOLTEN_BLAST", "MOLTEN_BLAST")
  if mb and CastBySpellID(mb) then return end

  -- Execute (<5%): Earth Shock R1
  local hp = UnitHealth("target") or 0
  local hpm= UnitHealthMax("target") or 1
  if hpm > 0 and (hp / hpm) <= 0.05 then
    CastBySpellID(SPELL.EARTH_SHOCK_R1)
    return
  end

  -- Frost shock R1 as kite tool (simple heuristic): if target is moving away and not slowed -> (we can’t reliably detect; keep manual)
  -- Earth shock max rank as generic filler (prefer detected max)
  local esMax = GetFamilyMaxID("EARTH_SHOCK")
  if esMax and CastBySpellID(esMax) then return end
end

-- ====== Public getters =======================================================
function SS.GetNet()
  return lastWorldPingMs, lastJitterMs, npWantedQueueMs
end

function SS.GetTotems()
  return totems
end

-- ====== Frame scripts =========================================================
local frame = CreateFrame("Frame", "ShamanForgeFrame", UIParent)

local function OnEvent()
  local event = _G.event

  if event == "ADDON_LOADED" then
    -- In 1.12 arg1 contains addon folder name; we initialize on first ADDON_LOADED that matches our frame existence.
    -- Safe init once:
    if CDB._inited then return end
    CDB._inited = 1

    NP_Detect()
    if npAvailable then
      NP_RecoverIfDirty()
      NP_Snapshot()
      Chat("NamPower обнаружен. Протокол безопасности активен.")
    else
      Chat("NamPower не обнаружен. Работаю без NP_* оптимизаций.")
    end

    -- Build spell maps once UI is up (spellbook may still fill later; we rebuild on ENTERING)
    BuildSpellbookMaps()

    -- Get player GUID via UnitExists("player") extended pattern if available; fallback to name
    local ok, guid = UnitExists("player")
    if ok and guid then playerGUID = guid end

    state = STATE_INIT

    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_LEAVING_WORLD")
    frame:RegisterEvent("PLAYER_LOGOUT")

    -- SuperWoW event (best effort)
    frame:RegisterEvent("UNIT_CASTEVENT")

    Chat("Загружен. /run ShamanForge.RotationStep() для ручного шага ротации.")


    -- Failsafe: перехватываем /sf чтобы команда НИКОГДА не улетала на сервер
    -- (в некоторых клиентах / кастомных сборках hash_SlashCmdList не обновляется).
    if type(_G.RunLine) == 'function' and not _G.__SF_RunLineHooked then
      _G.__SF_RunLineHooked = true
      _G.__SF_RunLineOrig = _G.RunLine
      _G.RunLine = function(...)
        local a = _G.arg
        local text = a and a[1]
        if type(text) == 'string' then
          local _, _, cmd, rest = strfind(text, '^%s*/(%S+)%s*(.*)$')
          if cmd then
            cmd = strlower(cmd)
            if cmd == 'sf' or cmd == 'shamanforge' then
              -- дергаем наш handler напрямую
              if type(__SlashCmdList) == 'table' and type(__SlashCmdList.SHAMANFORGE) == 'function' then
                __SlashCmdList.SHAMANFORGE(rest)
                return
              end
            end
          end
        end
        return _G.__SF_RunLineOrig(...)
      end
    end

    if type(_G.ChatEdit_SendText) == 'function' and not _G.__SF_ChatHooked then
      _G.__SF_ChatHooked = true
      _G.__SF_ChatEdit_SendTextOrig = _G.ChatEdit_SendText
      _G.ChatEdit_SendText = function(editBox)
        local text = editBox and editBox.GetText and editBox:GetText() or ''
        if type(text) == 'string' then
          local _, _, cmd, rest = strfind(text, '^%s*/(%S+)%s*(.*)$')
          if cmd then
            cmd = strlower(cmd)
            if cmd == 'sf' or cmd == 'shamanforge' then
              if type(__SlashCmdList) == 'table' and type(__SlashCmdList.SHAMANFORGE) == 'function' then
                __SlashCmdList.SHAMANFORGE(rest)
                editBox:SetText('')
                return
              end
            end
          end
        end
        return _G.__SF_ChatEdit_SendTextOrig(editBox)
      end
    end

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- world stable -> active
    state = STATE_ACTIVE

    -- refresh GUID
    local ok, guid = UnitExists("player")
    if ok and guid then playerGUID = guid end

    BuildSpellbookMaps()

    -- restore queue if needed
    if npAvailable then
      -- apply an initial net sample quickly
      UpdateNet()
      if npWantedQueueMs then
        NP_ApplyQueueMs(npWantedQueueMs)
      end
    end

  elseif event == "PLAYER_LEAVING_WORLD" then
    -- pause (avoid doing work / avoid spamming SetCVar)
    state = STATE_PAUSED
    if npAvailable then
      NP_PauseQueue()
    end

  elseif event == "PLAYER_LOGOUT" then
    state = STATE_STOP
    if npAvailable then
      NP_RestoreSnapshotDifferential()
    end

  elseif event == "UNIT_CASTEVENT" then
    OnUnitCastEvent()
  end
end

local function OnUpdate()
  if state ~= STATE_ACTIVE then return end

  -- Net manager
  netAccum = netAccum + _G.arg1
  if netAccum >= UPDATE_NET_EVERY then
    netAccum = 0
    UpdateNet()
    if npAvailable and npWantedQueueMs then
      NP_ApplyQueueMs(npWantedQueueMs)
    end
  end

  -- Totem tracker
  totemAccum = totemAccum + _G.arg1
  if totemAccum >= UPDATE_TOTEMS_EVERY then
    totemAccum = 0
    Totem_Scan()
  end
  -- Reactive layer: disabled in OnUpdate (button-press only)
end

frame:SetScript("OnEvent", OnEvent)
frame:SetScript("OnUpdate", OnUpdate)
frame:RegisterEvent("ADDON_LOADED")

-- ====== Simple toggle helpers =================================================
function SS.SetReactive(on)
  CFG.enableReactive = on and true or false
  Chat("Reactive слой: "..(CFG.enableReactive and "ON" or "OFF"))
end

function SS.SetNamPower(on)
  CFG.enableNamPower = on and true or false
  Chat("NamPower менеджер: "..(CFG.enableNamPower and "ON" or "OFF"))
end

function SS.SetLoS(on)
  CFG.enableLoS = on and true or false
  Chat("LoS проверки: "..(CFG.enableLoS and "ON" or "OFF"))
end

