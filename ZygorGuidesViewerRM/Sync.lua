-- ZygorGuidesViewer "Magnetic" Party Sync — WOTLK 3.3.5a port
-- Adapted from ZygorGuidesViewerClassicTBCAnniv/Sync.lua.
-- All TBC-only APIs replaced with WOTLK-safe equivalents (see phase 3 brief).

-- WOTLK convention (see Pointer.lua, Goal.lua, Functions.lua): use the
-- global `ZygorGuidesViewer`, NOT the `...` chunk args. In 3.3.5a, inner
-- `<Script file="..."/>` tags in files.xml do NOT receive `(name, frame)`
-- from the XML loader, so `local name,ZGV = ...` produces a wrong/stale
-- `ZGV` table.
assert(ZygorGuidesViewer, "ZygorGuidesViewer not loaded before Sync.lua!")
local ZGV = ZygorGuidesViewer
local name = "ZygorGuidesViewerRM"

local Sync = {}
ZGV.Sync = Sync

-- L system: WOTLK uses a custom ZygorGuidesViewer_L("Main") table with
-- a metatable __index fallback that returns the key as a string.
-- (TBC's LibStub("AceLocale-3.0"):GetLocale is NOT used in WOTLK.)
local L = ZygorGuidesViewer_L("Main")

-- Wire prefix MUST be the WOTLK string (not TBC's "zygor7sync").
local PREFIX = "zygorwotlksync"

-- Packet codes for the WOTLK v1 magnetic-sync model. v1 exchanges only
-- two packet types: GS (everyone announces their state) and SR (request
-- that everyone announce).
local PACKETTYPE_GUIDESTATUS   = "GS"  -- every member's guide/step/goal state
local PACKETTYPE_STATUSREQUEST = "SR"  -- "everyone, send me your GS"

local PARTY_STATUS_TIMEOUT = 2.0

-- 20-second periodic re-announce. Acts as the "everyone is still here"
-- heartbeat that lets the magnetic gate recover if a single packet is
-- lost. The step-change debounce (0.3s) is much faster; this is the
-- workhorse fallback.
local HEARTBEAT_PERIOD = 20

-- Step-change debounce window. Coalesces bursts of step transitions
-- (e.g. a multi-step auto-skip) into a single AnnounceStatus call.
local STEP_CHANGE_DEBOUNCE = 0.3

-- Stalled-party threshold: if the local player has been on the same step
-- for STALL_THRESHOLD seconds and party status is complete, emit
-- ZGV_SYNC_STALLED so a future "your party is stuck" UI can surface it.
local STALL_THRESHOLD = 5 * 60  -- 5 minutes

-- 3.3.5a-safe lib imports. AceComm + LibDeflate are vendored in WOTLK
-- Libs/ and loaded via embeds.xml (Phase 1).
local AceComm    = LibStub("AceComm-3.0")
local LibDeflate = LibStub("LibDeflate")

local function acecomm_handler(prefix, message, distribution, sender)
	Sync:OnChatReceived(message, sender)
end

--[[
"MAGNETIC" SYNC:

Everyone synced progresses only when:
 - they're on the same step, and
 - the steps are all completed.

Each step change is announced to other party members.

Packet GS (GuideState):
  "GS"
  "##GU=" <guide title>
  "##ST=" <step number> "," <status> (0=incomplete/1=complete)
  "##GO=" <goal status> "," <goal status...> (0=incomplete/1=complete/2=impossible)

Receiving of GS packet stores party member's guide state indefinitely, until
further GS data, disconnection or leaving the party.

Step progress is halted as long as there are party members' statuses stored,
indicating the current step is still in progress for someone.
--]]

-- =====================================================================
-- LOCAL HELPERS (per brief: NOT methods on ZGV)
-- =====================================================================

-- GetStickiesAt: WOTLK re-implementation.
-- TBC stored parsed stickystart/stickystop markers directly on each step.
-- WOTLK's parser only uses "stickystart"/"stickystop" for `sticky_depth`
-- counting on goals; it does NOT attach stickystart_*/stickystop_* lines
-- to the step. We must walk the raw source to find them.
-- Returns an array of { num = <stepnum>, label = <stickystart label> }.
local function GetStickiesAt(stepnum)
	if not ZGV.CurrentGuide or not ZGV.CurrentGuide.rawdata then return {} end
	if not ZGV.CurrentGuide.steps or not ZGV.CurrentGuide.steps[stepnum] then return {} end

	local stickies = {}
	local raw = ZGV.CurrentGuide.rawdata
	local sn, li = 0, 0
	local in_step = false
	local sticky_depth = 0

	for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		li = li + 1
		local cmd = line:match("^%s*(%S+)")
		if cmd then
			if cmd == "step" then
				sn = sn + 1
				in_step = (sn == stepnum)
			elseif in_step and (cmd == "stickystart" or cmd:match("^stickystart$")) then
				local label = line:match("^%s*stickystart%s+(.-)%s*$")
				sticky_depth = sticky_depth + 1
				stickies[#stickies+1] = { num = stepnum, label = label or "", depth = sticky_depth }
			elseif in_step and (cmd == "stickystop" or cmd:match("^stickystop$")) then
				if sticky_depth > 0 then sticky_depth = sticky_depth - 1 end
			end
		end
	end
	return stickies
end

-- =====================================================================
-- STATE
-- =====================================================================

-- PartyStatus: map party member name -> last received GS packet.
Sync.PartyStatus = {}

-- Debounce timers (cancel-and-reschedule pattern with AceTimer-3.0).
Sync.StepChangeTimer = nil
Sync.complete_party_status_timeout = nil

-- =====================================================================
-- PACKET BUILDERS
-- =====================================================================

local function GetStepStatusString(step)
	-- 4-value contract: (complete, possible, numdone, numneeded) — WOTLK
	-- Goal:IsComplete() was patched in Phase 2 to return 4 values.
	--
	-- Wire-format conversion for each goal action:
	--   * "c" — complete (e.g. accept/turnin/confirm just-done)
	--   * "i" — incomplete, no numeric count (single-shot travel, talk,
	--           goto with no .x coords, or nil numdone)
	--   * "X/Y" — progress with scale. Two flavors:
	--       1. native numneeded (collect/buy/goldcollect/achieve-sub/
	--          kill usekillcount): numdone is either an integer or a
	--          fraction in [0,1]; convert fraction to integer count.
	--       2. synthesized numneeded=100 (ding/level, rep, achieve
	--          without sub, goto with coords): numdone is a fraction
	--          in [0,1] and numneeded is nil. Treat fraction as a
	--          percent 0-100. See synthesis block below.
	local goals = {}
	local req = step:AreRequirementsMet()  -- WOTLK Step:AreRequirementsMet() takes no args.
	for gi, goal in ipairs(step.goals or {}) do
		local completable = req and goal:IsCompleteable() and goal:IsCompleteable()
		local complete, possible, numdone, numneeded = goal:IsComplete()
		-- For fraction-only goals (ding/rep/achieve-no-sub/goto) the 3rd
		-- return is a fraction in [0,1] but numneeded is nil. Synthesize
		-- a percent scale so the wire payload becomes "X/100" (e.g. "75/100"
		-- for "75% of the way to the goal"). This matches the X/Y format
		-- used by collect/buy so receivers render uniformly. If numdone
		-- is also nil (e.g. goto with no .x coords), fall through to "i".
		if not numneeded and numdone and numdone ~= math.floor(numdone) then
			numdone = math.floor(numdone * 100 + 0.5)
			if numdone < 0 then numdone = 0
			elseif numdone > 100 then numdone = 100 end
			numneeded = 100
		end
		local c
		if not completable then
			c = "-"
		elseif complete then
			c = "c"
		elseif possible and numdone and numneeded then
			if numdone ~= math.floor(numdone) then
				-- fraction: convert to integer count, clamped to [0, numneeded]
				numdone = math.floor(numdone * numneeded + 0.5)
				if numdone < 0 then numdone = 0
				elseif numdone > numneeded then numdone = numneeded end
			end
			c = ("%d/%d"):format(numdone, numneeded)
		else
			c = "i"
		end
		goals[gi] = c
	end
	local st_status
	if not req then
		st_status = "x"
	elseif step:IsComplete() then
		st_status = "c"
	else
		st_status = "i"
	end
	return ("%d,%s;%s"):format(step.shared_origin or step.num, st_status, table.concat(goals, ","))
end

local empty_table = {}
function Sync:CreatePacket_GuideStatus()
	local guide_title = ZGV.CurrentGuide and ZGV.CurrentGuide.title or ""

	local st = "##ST=0,0;0"
	local ss = ""
	if ZGV.CurrentStep then
		st = "##ST=" .. GetStepStatusString(ZGV.CurrentStep)

		local stickies = GetStickiesAt(ZGV.CurrentStep.num)
		for i, sticky in ipairs(stickies or empty_table) do
			if #ss == 0 then
				ss = "##SS="
			else
				ss = ss .. "/"
			end
			-- Sticky step in WOTLK is identified by its position; use the
			-- sticky's parent step num + an offset for uniqueness.
			ss = ss .. ("%d,%s;%s"):format(sticky.num, "i", "")
		end
	end

	local packet =
		   PACKETTYPE_GUIDESTATUS
		.. ("##GU=%s"):format(guide_title)
		.. st
		.. ss
		.. ("##CH=%d,%s,%s\n"):format(
			UnitLevel("player"),
			select(2, UnitRace("player")) or "?",
			select(2, UnitClass("player")) or "?")

	return packet
end

function Sync:CreatePacket_StatusRequest()
	return ("%s##\n"):format(PACKETTYPE_STATUSREQUEST)
end

-- =====================================================================
-- PACKET PARSING
-- =====================================================================

function Sync:SplitXXIntoPacket(packet, data)
	local databits = {("##"):split(data)}
	for i, bit in ipairs(databits) do
		local k, v = bit:match("(..)=(.+)")
		if k then
			packet[k] = v
		elseif #bit == 2 then
			packet[k] = true
		end
	end
end

function Sync:OnChatReceived(msg, sender)
	-- Strip realm suffix on 3.3.5a Name-Realm format.
	local sname = sender and sender:match("(.-)%-")
	if sname then sender = sname end
	if sender == UnitName("player") then return end
	self:Debug("|cffaaff00RCV |cffffffff[%s]: |r%s", tostring(sender), tostring(msg))

	if not msg then self:Debug("No packet received") return end

	local msg_decoded = LibDeflate:DecodeForWoWAddonChannel(msg)
	if not msg_decoded then self:Debug("No packet decoded") return end

	local msg_unpacked = LibDeflate:DecompressDeflate(msg_decoded)
	if not msg_unpacked then self:Debug("No packet unpacked") return end

	for chunk in msg_unpacked:gmatch("([^\n]+)\n") do
		local packettype, data = chunk:match("(..)##(.*)")
		if not packettype then
			self:Debug("Bad packet received: ", chunk)
		else
			local packet = { type = packettype, sender = sender, recv_time = GetTime() }
			self:Unpack(packet, data)
			self:HandleReceivedPacket(packet)
		end
	end
end

local dummy_notcompletable = { completable = false }
local dummy_complete = { completable = true, complete = true }
local function grab_goals(goalstring, target)
	local goals = { (","):split(goalstring) }
	target.goals = {}
	for i, g in ipairs(goals) do
		if g == "-" then
			target.goals[i] = dummy_notcompletable
		elseif g == "c" then
			target.goals[i] = dummy_complete
		else
			local done, needed = g:match("(%d+)/(%d+)")
			done = tonumber(done)
			needed = tonumber(needed)
			target.goals[i] = { completable = true, complete = false, done = done, needed = needed }
		end
	end
end

function Sync:Unpack(packet, data)
	if packet.type == PACKETTYPE_GUIDESTATUS then
		self:SplitXXIntoPacket(packet, data)
		packet.guide = packet.GU
		local stepnum, complete, goals = packet.ST:match("(.*),(.*);(.*)")
		packet.stepnum = tonumber(stepnum)
		packet.is_complete = complete == "c"
		packet.is_possible = complete ~= "x"
		if goals then grab_goals(goals, packet) end

		if packet.SS then
			local stickies = { ("/"):split(packet.SS) }
			packet.stickies = {}
			for i, stickystatus in ipairs(stickies) do
				local sn, c, g = stickystatus:match("(.*),(.*);(.*)")
				local stickydata = {}
				stickydata.stepnum = tonumber(sn)
				stickydata.is_complete = c == "c"
				stickydata.is_possible = c ~= "x"
				if g then grab_goals(g, stickydata) end
				packet.stickies[i] = stickydata
			end
		end

		if packet.CH then
			packet.level, packet.race, packet.class = packet.CH:match("(.*),(.*),(.*)")
		end
		packet.level = tonumber(packet.level) or 0
		packet.race = packet.race or "?"
		packet.class = packet.class or "?"
	end
end

-- =====================================================================
-- PACKET HANDLER
-- =====================================================================

function Sync:HandleReceivedPacket(packet)
	if not self:IsEnabled() then return end

	if packet.type == PACKETTYPE_GUIDESTATUS then
		self:Debug("Player %s (%s %s level %d) is on guide %s step %d which is %s.",
			packet.sender,
			packet.race, packet.class, packet.level,
			packet.guide, packet.stepnum,
			packet.is_possible and (packet.is_complete and "complete" or "incomplete") or "impossible")
		self.PartyStatus[packet.sender] = packet
		self:OnPartyStatusChanged()

	elseif packet.type == PACKETTYPE_STATUSREQUEST then
		self:Debug("Status requested, announcing.")
		self:AnnounceStatus()
	end
end

-- =====================================================================
-- PARTY STATUS / GATING
-- =====================================================================

local dummytable = {}
function Sync:OnPartyStatusChanged()
	local s = "Party status:\n"
	for name, status in pairs(self.PartyStatus) do
		local goals = ""
		for gi, gs in ipairs(status.goals or dummytable) do
			if #goals > 0 then goals = goals .. "," end
			goals = goals .. (gs.complete and "c" or (gs.done and ("%d/%d"):format(gs.done, gs.needed)) or (gs.completable and "undone") or "-")
		end
		s = s .. ("- %s: step %d, %s, goals:%s\n"):format(
			name, status.stepnum,
			status.is_possible and (status.is_complete and "COMPLETE" or "incomplete") or "impossible",
			goals)
	end
	self:Debug(s)
	if ZGV.UpdateFrame then ZGV:UpdateFrame() end

	self:DeclarePartyStatusComplete()

	-- Pass force=true to bypass ZGV's 1s throttle on TryToCompleteStep.
	-- We just received authoritative party status from a comm packet, so
	-- re-checking completion now is the whole point of sync.
	if ZGV.TryToCompleteStep then ZGV:TryToCompleteStep(true) end
end

function Sync:DeclarePartyStatusComplete()
	if self.complete_party_status_timeout then
		ZGV:CancelTimer(self.complete_party_status_timeout)
		self.complete_party_status_timeout = nil
	end
end

-- 3.3.5a parties cap at 4 others (plus self) — GetNumGroupMembers() total.
function Sync:IsPartyStatusComplete()
	if not IsInGroup() then return true end
	local n = GetNumGroupMembers()
	for i = 1, n - 1 do
		local status = self.PartyStatus[UnitName("party" .. i)]
		if not status or (self.party_status_request_time and status.recv_time < self.party_status_request_time) then
			return false
		end
	end
	return true
end

function Sync:IsClearToProceed(stepnum)
	if not stepnum then stepnum = ZGV.CurrentStepNum end
	if not self:IsEnabled() or not self:IsSnapping() then return true end
	if not self.PartyStatus or not next(self.PartyStatus) then return true end
	if not ZGV.CurrentGuide then return true end
	local my_title = (ZGV.CurrentGuide.title or ""):gsub("^SHARED\\", "")
	for _, status in pairs(self.PartyStatus) do
		if status.guide and (status.guide:gsub("^SHARED\\", "") == my_title) then
			if status.stepnum and status.stepnum < stepnum then return false end
			if status.stepnum == stepnum and status.is_possible and not status.is_complete then return false end
		end
	end
	return true
end

-- =====================================================================
-- PARTY GOAL STATUS TEXT (for display)
-- =====================================================================

-- Per-member color codes used by GetStepProgressGoalPartyText.
local progress_complete_color   = "|cff00ff00"  -- green
local progress_partial_color    = "|cffff8888"  -- red
local progress_unstarted_color  = "|cff888888"  -- grey

-- GetStepProgressGoalPartyText(stepnum, goalnum)
--
-- Returns a formatted per-member breakdown for a single progress goal, e.g.
--   "|cff00ff00Alice|r, |cffff8888Bob 2/5|r"
-- (no trailing newline). The caller is expected to prepend the goal text
-- and a separator, and to dim-grey the whole line.
--
-- Returns nil when Sync is disabled, the local player is not in a party,
-- or no party members are on the same guide/step with status for this goal.
function Sync:GetStepProgressGoalPartyText(stepnum, goalnum)
	if not self:IsEnabled() or not self.PartyStatus then return end
	local s = ""
	local on_step = 0
	-- Suppress the sub-line when no member has a numeric count to show
	-- AND no member is complete. Both are useless-redundant with the
	-- ahead/behind footer (which already says who's on the step); the
	-- X/Y and complete-green forms are the actual information the user
	-- needs. Without this gate, fraction-only actions like `goto` with
	-- no .x coords or `ding` 2+ levels below the target would render
	-- bare-name sub-lines for every progress goal on the step.
	local has_count = false
	local has_complete = false
	local partysort = {}
	-- 3.3.5a: no LE_PARTY_CATEGORY_HOME; IsInGroup() is the gate.
	if IsInGroup() then
		for i = 1, GetNumGroupMembers() - 1 do
			partysort[#partysort+1] = UnitName("party" .. i)
		end
	else
		for k in pairs(self.PartyStatus) do partysort[#partysort+1] = k end
	end
	local guide_title = (ZGV.CurrentGuide and ZGV.CurrentGuide.title or ""):gsub("^SHARED\\", "")
	for i, name in ipairs(partysort) do
		local status = self.PartyStatus[name]
		if status then
			local matches = status.guide and (status.guide:gsub("^SHARED\\", "") == guide_title)
			if matches then
				local step
				if status.stepnum == stepnum then
					step = status
				elseif status.stickies then
					for _, st in ipairs(status.stickies) do
						if st.stepnum == stepnum then step = st break end
					end
				end
				if step and step.goals and step.goals[goalnum] then
					local goal = step.goals[goalnum]
					if on_step > 0 then s = s .. ", " end
					on_step = on_step + 1
					if goal.complete then
						s = s .. progress_complete_color .. name .. "|r"
						has_complete = true
					elseif goal.done and goal.needed then
						s = s .. (progress_partial_color .. "%s %d/%d|r"):format(name, goal.done, goal.needed)
						has_count = true
					else
						s = s .. progress_unstarted_color .. name .. "|r"
					end
				end
			end
		end
	end
	if on_step > 0 and (has_count or has_complete) then return s end
end

-- =====================================================================
-- AHEAD / BEHIND TEXT
-- =====================================================================

local ahead, behind = {}, {}
function Sync:GetAheadBehind()
	if not ZGV.CurrentStepNum then return nil, "no step" end
	if not self.PartyStatus or not next(self.PartyStatus) then return end
	local wipetable, behindtable = ahead, behind
	for i = 1, #wipetable do wipetable[i] = nil end
	for i = 1, #behindtable do behindtable[i] = nil end
	for _, status in pairs(self.PartyStatus) do
		if status.guide and (status.guide == (ZGV.CurrentGuide and ZGV.CurrentGuide.title) or status.guide:find("SHARED\\", 1, true)) then
			if not status.stepnum or status.stepnum == 0 then
				-- ignore
			elseif status.stepnum < ZGV.CurrentStepNum then
				behindtable[#behindtable+1] = ("%s |cffff8888(-%d)|r"):format(tostring(status.sender or "?"), ZGV.CurrentStepNum - status.stepnum)
			elseif status.stepnum > ZGV.CurrentStepNum then
				wipetable[#wipetable+1] = ("%s |cff88ff88(+%d)|r"):format(tostring(status.sender or "?"), status.stepnum - ZGV.CurrentStepNum)
			end
		end
	end
	if #wipetable > 0 or #behindtable > 0 then
		local s = ""
		if #wipetable > 0 then s = "Ahead: " .. table.concat(wipetable, ", ") end
		if #behindtable > 0 then s = s .. (#s > 0 and "; " or "") .. "Behind: " .. table.concat(behindtable, ", ") end
		return s
	end
end

-- =====================================================================
-- ROLE / MODE HELPERS
-- =====================================================================

function Sync:IsInGroup()
	return IsInGroup()
end

function Sync:IsEnabled()
	return ZGV.db.profile.sync_enabled and self:IsInGroup()
end

function Sync:IsSnapping()
	return self:IsEnabled() and ZGV.db.profile.sync_snap
end

-- =====================================================================
-- WIRE SEND
-- =====================================================================

function Sync:Send(message, ...)
	if not message then return end
	if not self:IsEnabled() then return end

	local message_packed = LibDeflate:CompressDeflate(message)
	if not message_packed then return end
	local message_encoded = LibDeflate:EncodeForWoWAddonChannel(message_packed)
	if not message_encoded then return end

	AceComm:SendCommMessage(PREFIX, message_encoded, "PARTY")
	self:Debug("|cffffaa00SND|r: %s", tostring(message))
	if select("#", ...) > 0 then return self:Send(...) end
end

-- =====================================================================
-- BROADCASTS
-- =====================================================================

function Sync:AnnounceStatus()
	if self:IsInGroup() then
		self:Send(self:CreatePacket_GuideStatus())
		self:Debug("Announcing status.")
	end
end

function Sync:RequestPartyStatus()
	self:Send(self:CreatePacket_StatusRequest())
	self.party_status_request_time = GetTime()
	if self.complete_party_status_timeout then
		ZGV:CancelTimer(self.complete_party_status_timeout)
	end
	self.complete_party_status_timeout = ZGV:ScheduleTimer(function()
		-- Clear out old statuses that didn't get updated recently.
		for n, st in pairs(self.PartyStatus) do
			if st.recv_time < self.party_status_request_time then
				self.PartyStatus[n] = nil
			end
		end
		self:OnPartyStatusChanged()
		self:DeclarePartyStatusComplete("timedout")
	end, PARTY_STATUS_TIMEOUT)
end

function Sync:ResetPartyStatus()
	if not IsInGroup() then
		self.PartyStatus = {}
		return
	end
	self.PartyStatus = self.PartyStatus or {}
	local newps = {}
	local n = GetNumGroupMembers()
	for i = 1, n - 1 do
		local unit = "party" .. i
		if UnitExists(unit) and UnitIsConnected(unit) then
			local name = UnitName(unit)
			newps[name] = self.PartyStatus[name]
		end
	end
	self.PartyStatus = newps
end

-- =====================================================================
-- EVENT HANDLERS
-- =====================================================================

function Sync.OnEvent(self_or_addon, event, ...)
	-- AceEvent-3.0 calls handlers as (self, event, ...).
	-- Accept either signature; route to :ResetPartyStatus + status update.
	if event == "GROUP_ROSTER_UPDATE" or event == "PARTY_MEMBER_DISABLE"
		or event == "PARTY_MEMBER_ENABLE" or event == "PLAYER_ENTERING_WORLD" then
		Sync:ResetPartyStatus()
		Sync:OnPartyStatusChanged()
		if Sync:IsInGroup() then
			Sync:AnnounceStatus()
			Sync:RequestPartyStatus()
		end
	end
end

-- =====================================================================
-- STEP-CHANGE DEBOUNCE
-- =====================================================================

local function on_step_changed()
	if not Sync:IsEnabled() then return end
	Sync._lastStepChangeTime = GetTime()
	Sync:AnnounceStatus()
end

local function on_step_changed_msg(_, _)
	-- Cancel-and-reschedule debounce: collapse bursts of step changes into
	-- a single delayed broadcast. Replaces TBC's ZGV:Throttler.
	if Sync.StepChangeTimer then ZGV:CancelTimer(Sync.StepChangeTimer) end
	Sync.StepChangeTimer = ZGV:ScheduleTimer(on_step_changed, STEP_CHANGE_DEBOUNCE)
end

-- =====================================================================
-- INIT
-- =====================================================================

local function apply_default_profile()
	ZGV.db.profile.sync_enabled = true
	ZGV.db.profile.sync_snap    = true
end

-- Event hooks for party events. Roster changes reset party state and
-- request fresh status from everyone (TBC parity: new joiners see full
-- state in <1s instead of waiting 20s for the heartbeat).
local function register_event_handlers()
	ZGV:AddEventHandler("GROUP_ROSTER_UPDATE", Sync.OnEvent)
	ZGV:AddEventHandler("PARTY_MEMBER_DISABLE", Sync.OnEvent)
	ZGV:AddEventHandler("PARTY_MEMBER_ENABLE", Sync.OnEvent)
	ZGV:AddEventHandler("PLAYER_ENTERING_WORLD", Sync.OnEvent)
end

-- Hooks for in-game progress events. All four call AnnounceStatus
-- when enabled, so the local player's latest state is broadcast
-- without waiting for the 20s heartbeat.
local function register_message_handlers()
	-- Helper: wrap a status-announce + debug handler behind the IsEnabled gate.
	local function reannounce(msg_label)
		return function(_, _, step, goal)
			if Sync:IsEnabled() then
				Sync:Debug("%s: %d %d", msg_label, step, goal)
				Sync:AnnounceStatus()
			end
		end
	end
	ZGV:AddMessageHandler("ZGV_GOAL_COMPLETED",   reannounce("GOAL_COMPLETED"))
	ZGV:AddMessageHandler("ZGV_GOAL_UNCOMPLETED", reannounce("GOAL_UNCOMPLETED"))
	ZGV:AddMessageHandler("ZGV_GOAL_PROGRESS",    reannounce("GOAL_PROGRESS"))
	ZGV:AddMessageHandler("ZGV_STEP_CHANGED", on_step_changed_msg)
end

-- 20s heartbeat: re-announce, request fresh party status, and emit a
-- stall signal if the local player has been on the same step for
-- >STALL_THRESHOLD and the party is fully responsive.
local function start_heartbeat()
	ZGV:ScheduleRepeatingTimer(function()
		if not Sync:IsEnabled() then return end
		Sync:AnnounceStatus()
		Sync:RequestPartyStatus()
		if Sync:IsInGroup() and Sync:IsPartyStatusComplete()
		   and ZGV.CurrentStepNum
		   and (GetTime() - (Sync._lastStepChangeTime or GetTime())) > STALL_THRESHOLD
		then
			local idle = math.floor(GetTime() - Sync._lastStepChangeTime)
			ZGV:SendMessage("ZGV_SYNC_STALLED", ZGV.CurrentStepNum, idle)
			Sync:Debug("ZGV_SYNC_STALLED: step %d idle for %ds", ZGV.CurrentStepNum, idle)
		end
	end, HEARTBEAT_PERIOD)
end

function Sync:Init()
	apply_default_profile()
	self._lastStepChangeTime = GetTime()

	AceComm:RegisterComm(PREFIX, acecomm_handler)
	register_event_handlers()
	register_message_handlers()
	start_heartbeat()
end

-- =====================================================================
-- DEBUG
-- =====================================================================

function Sync:Debug(msg, ...)
	if not ZGV or not ZGV.Debug then return end
	ZGV:Debug("&sync " .. tostring(msg), ...)
end

-- =====================================================================
-- STARTUP REGISTRATION
-- =====================================================================

-- WOTLK startups runner: `for i,startup in ipairs(self.startups) do
-- startup[2](self) end if type(startup) == "table"`. The `after=` table
-- is TBC-only and is ignored by the WOTLK runner.
-- Defensive: `ZGV.startups` may not exist if ZygorGuidesViewer.lua has
-- not yet assigned it (e.g. if Sync.lua is being loaded out of order
-- by a third-party loader, or if a future refactor moves the
-- `me.startups = {}` assignment). Without this guard, login crashes.
ZGV.startups = ZGV.startups or {}
tinsert(ZGV.startups, {
	"Sync startup",
	function(self) Sync:Init() end,
})
