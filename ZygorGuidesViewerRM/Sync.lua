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

-- Packet codes reused 1:1 from TBC for protocol parity.
local PACKETTYPE_GUIDESTATUS   = "GS"  -- our guide/step/goals status
local PACKETTYPE_STATUSREQUEST = "SR"  -- "everyone, send me your GS"
local PACKETTYPE_STEPREQUEST   = "SQ"  -- "master, send me your step source"
local PACKETTYPE_STEPDATA      = "SD"  -- step header (main)
local PACKETTYPE_STEPSTICKY    = "SS"  -- step header (sticky)
local PACKETTYPE_STEPLINE      = "SL"  -- one line of a step
local PACKETTYPE_STEPEND       = "SE"  -- reassembly complete
local PACKETTYPE_SLAVEREQUEST  = "MS"  -- "let me be a slave"

local PARTY_STATUS_TIMEOUT = 2.0

-- 3.3.5a-safe lib imports. AceComm + LibDeflate are vendored in WOTLK
-- Libs/ and loaded via embeds.xml (Phase 1).
local AceComm    = LibStub("AceComm-3.0")
local LibDeflate = LibStub("LibDeflate")

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

-- FormatNiceGuideTitle: strip "\" separators, replace with " - "
local function FormatNiceGuideTitle(title)
	if not title or title == "" then return "" end
	return (title:gsub("\\", " - "))
end

-- TableKeys: emulate the missing TBC ZGV.TableKeys helper.
-- Returns an array of keys of `t`.
local function TableKeys(t)
	local out = {}
	if type(t) ~= "table" then return out end
	for k in pairs(t) do
		out[#out+1] = k
	end
	return out
end

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

-- safe_format: defensive wrapper for the localization fallback case.
-- If the L metatable fallback returns the key as a string and the
-- caller invokes :format() with args, plain string.format ignores
-- extra args when the format string has no %s directives. We still
-- guard so the call never throws.
local function safe_format(s, ...)
	if s == nil then return "" end
	if type(s) ~= "string" then return tostring(s) end
	local ok, out = pcall(string.format, s, ...)
	if ok then return out end
	return s
end

-- =====================================================================
-- STATE
-- =====================================================================

-- PartyStatus: map party member name -> last received GS packet.
Sync.PartyStatus = {}
Sync.SharedGuide = nil
Sync.SharedGuideSource = nil
Sync.StepDataBuffer = nil
Sync.packet_callbacks = {}

-- Debounce timers (cancel-and-reschedule pattern with AceTimer-3.0).
Sync.StepChangeTimer = nil
Sync.SYNC_REBROADCAST_timer = nil
Sync.complete_party_status_timeout = nil

-- Saved AceComm registration to keep callback closure bound to Sync.
Sync._AceCommHandler = nil

-- Popup frames (built lazily; v1 has only the slave-confirm popup).
Sync.SlavePopup = nil
Sync.MasterConfirmPopup = nil
Sync.ReinviteOrStopPopup = nil

-- =====================================================================
-- PACKET BUILDERS
-- =====================================================================

local function GetStepStatusString(step)
	-- 4-value contract: (complete, possible, numdone, numneeded) — WOTLK
	-- Goal:IsComplete() was patched in Phase 2 to return 4 values.
	local goals = {}
	local req = step:AreRequirementsMet()  -- WOTLK Step:AreRequirementsMet() takes no args.
	for gi, goal in ipairs(step.goals or {}) do
		local completable = req and goal:IsCompleteable() and goal:IsCompleteable()
		local complete, possible, numdone, numneeded = goal:IsComplete()
		local c
		if not completable then
			c = "-"
		elseif complete then
			c = "c"
		elseif possible and numdone and numneeded then
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
		.. ("##MS=%d"):format(ZGV.db.profile.share_masterslave or 0)
		.. ("##CH=%d,%s,%s\n"):format(
			UnitLevel("player"),
			select(2, UnitRace("player")) or "?",
			select(2, UnitClass("player")) or "?")

	return packet
end

function Sync:CreatePackets_StepData()
	if not ZGV.CurrentGuide then return end

	local ret = ""

	local guide_title = ZGV.CurrentGuide.title
	local step_num = ZGV.CurrentStepNum

	local steplines = self:GetStepSource(ZGV.CurrentStepNum)
	if not steplines or #steplines == 0 then
		ZGV:Print("Unable to share current step!")
		return
	end

	ret = ret .. ("%s##GU=%s##ST=%d##LA=%s##SL=%d\n"):format(
		PACKETTYPE_STEPDATA, guide_title, step_num,
		(ZGV.CurrentStep and ZGV.CurrentStep.label) or "",
		#steplines)

	for li, line in ipairs(steplines) do
		ret = ret .. ("%s##%d:%d:%s\n"):format(PACKETTYPE_STEPLINE, step_num, li, line)
	end

	local stickies = GetStickiesAt(step_num)
	for i, sticky in ipairs(stickies) do
		local slines = self:GetStepSource(sticky.num)
		if not slines or #slines == 0 then
			ZGV:Print("Unable to share sticky step!")
			return
		end
		ret = ret .. ("%s##ST=%d##LA=%s##SL=%d\n"):format(
			PACKETTYPE_STEPSTICKY, sticky.num, sticky.label or "", #slines)
		for li, line in ipairs(slines) do
			ret = ret .. ("%s##%d:%d:%s\n"):format(PACKETTYPE_STEPLINE, sticky.num, li, line)
		end
	end

	ret = ret .. ("%s##\n"):format(PACKETTYPE_STEPEND)
	return ret
end

function Sync:CreatePacket_StatusRequest()
	return ("%s##\n"):format(PACKETTYPE_STATUSREQUEST)
end

function Sync:CreatePacket_StepRequest()
	return ("%s##\n"):format(PACKETTYPE_STEPREQUEST)
end

function Sync:CreatePacket_SlaveRequest()
	local title = (ZGV.CurrentGuide and ZGV.CurrentGuide.title) or ""
	return ("%s##GU=%s\n"):format(PACKETTYPE_SLAVEREQUEST, title)
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

local function packet_iterator(packet)
	return packet:gmatch("([^\n]+)\n")
end

function Sync:OnChatReceived(msg, channel, sender)
	-- Strip realm suffix on 3.3.5a Name-Realm format.
	local sname, srealm = sender and sender:match("(.*)%-(.*)")
	if sname then sender = sname end
	if sender == UnitName("player") then return end
	self:Debug("|cffaaff00RCV |cffffffff[%s]: |r%s", tostring(sender), tostring(msg))

	if not msg then self:Debug("No packet received") return end

	local msg_decoded = LibDeflate:DecodeForWoWAddonChannel(msg)
	if not msg_decoded then self:Debug("No packet decoded") return end

	local msg_unpacked = LibDeflate:DecompressDeflate(msg_decoded)
	if not msg_unpacked then self:Debug("No packet unpacked") return end

	for chunk in packet_iterator(msg_unpacked) do
		local packettype, data = chunk:match("(..)##(.*)")
		if not packettype then
			self:Debug("Bad packet received: ", chunk)
			return
		end
		local packet = { type = packettype, sender = sender, recv_time = GetTime() }
		self:Unpack(packet, data)
		self:HandleReceivedPacket(packet)
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

		if packet.MS then packet.sharemode = tonumber(packet.MS) end
		if packet.CH then
			packet.level, packet.race, packet.class = packet.CH:match("(.*),(.*),(.*)")
		end
		packet.level = tonumber(packet.level) or 0
		packet.race = packet.race or "?"
		packet.class = packet.class or "?"

	elseif packet.type == PACKETTYPE_STEPDATA then
		self:SplitXXIntoPacket(packet, data)
		packet.guide = packet.GU
		packet.stepnum = tonumber(packet.ST)
		packet.label = packet.LA
		packet.lines = {}
		packet.linecount = tonumber(packet.SL)

	elseif packet.type == PACKETTYPE_STEPSTICKY then
		self:SplitXXIntoPacket(packet, data)
		packet.stepnum = tonumber(packet.ST)
		packet.label = packet.LA
		packet.lines = {}
		packet.linecount = tonumber(packet.SL)

	elseif packet.type == PACKETTYPE_STEPLINE then
		local stepnum, linenum, linestring = data:match("(.-):(.-):(.*)")
		packet.stepnum = tonumber(stepnum)
		packet.linenum = tonumber(linenum)
		packet.linestring = linestring

	elseif packet.type == PACKETTYPE_SLAVEREQUEST then
		self:SplitXXIntoPacket(packet, data)
		packet.guide = packet.GU
	end
end

-- =====================================================================
-- PACKET HANDLER
-- =====================================================================

function Sync:HandleReceivedPacket(packet)
	if packet.type ~= "nonexistent_future_packet" and not self:IsEnabled() then return end

	if packet.type == PACKETTYPE_GUIDESTATUS then
		self:Debug("Player %s (%s %s level %d) is on guide %s step %d which is %s. They are %s.",
			packet.sender,
			packet.race, packet.class, packet.level,
			packet.guide, packet.stepnum,
			packet.is_possible and (packet.is_complete and "complete" or "incomplete") or "impossible",
			({ [0] = "not sharing", [1] = "|cffff8888the master|r", [2] = "|cffffcc00a slave|r" })[packet.sharemode or 0])
		self.PartyStatus[packet.sender] = packet
		self:OnPartyStatusChanged()

		-- Master rebroadcast throttle (5s, debounce via AceTimer).
		if self:IsMaster() and packet.sharemode == 2 and (packet.is_complete or not packet.is_possible) then
			if ZGV.CurrentStepNum ~= packet.stepnum then
				if self.SYNC_REBROADCAST_timer then
					ZGV:CancelTimer(self.SYNC_REBROADCAST_timer)
				end
				self.SYNC_REBROADCAST_timer = ZGV:ScheduleTimer(function()
					self:Debug("Slave is lagging behind, reannouncing.")
					Sync:BroadcastStepContents()
				end, 5)
			end
		end

	elseif packet.type == PACKETTYPE_STEPDATA then
		if not self:IsSlave() then
			self:Debug("I'm not a slave; step data ignored.")
			return
		end

		self:Debug("Player %s sends step %d data (%d goals needed)", packet.sender, packet.stepnum, packet.linecount)
		packet.lines = {}
		local SDB = {}
		self.StepDataBuffer = SDB
		SDB.steps = {}
		SDB.sticky_renum = {}
		SDB.steps[packet.stepnum] = packet
		SDB.mainstepnum = packet.stepnum
		SDB.laststepnum = packet.stepnum

	elseif packet.type == PACKETTYPE_STEPSTICKY then
		if not self:IsSlave() then
			self:Debug("I'm not a slave; sticky data ignored.")
			return
		end

		local SDB = self.StepDataBuffer
		if not SDB then
			self:Debug("Sticky packet before step data; ignored.")
			return
		end
		packet.lines = {}
		packet.sticky = true
		packet.stepnum_shared = SDB.laststepnum + 1
		SDB.steps[packet.stepnum_shared] = packet
		SDB.sticky_renum[packet.stepnum] = packet.stepnum_shared
		SDB.laststepnum = packet.stepnum_shared
		self:Debug("Player %s sends sticky step %d data, saving as step %d", packet.sender, packet.stepnum, packet.stepnum_shared)

	elseif packet.type == PACKETTYPE_STEPLINE then
		if not self:IsSlave() then
			self:Debug("I'm not a slave; step line ignored.")
			return
		end

		local SDB = self.StepDataBuffer
		if not SDB or not SDB.steps then
			self:Debug("Sharing error: line before step header")
			return
		end
		packet.stepnum_shared = SDB.sticky_renum[packet.stepnum]
		local stepbuffer = SDB.steps[packet.stepnum_shared or packet.stepnum]
		if not stepbuffer then
			self:Debug(("Sharing error: data for step %d unexpected!"):format(packet.stepnum))
			return
		end
		if stepbuffer.lines[packet.linenum] then
			self:Debug(("Sharing error: step %d line %d sent twice."):format(packet.stepnum, packet.linenum))
			return
		end
		stepbuffer.lines[packet.linenum] = packet.linestring
		self:Debug("Player %s sends step %d line %d, saved as %d", packet.sender, packet.stepnum, packet.linenum, packet.stepnum_shared or packet.stepnum)

	elseif packet.type == PACKETTYPE_STEPEND then
		local SDB = self.StepDataBuffer
		if not self:IsSlave() then
			self.StepDataBuffer = nil
			self:Debug("I'm not a slave, I don't care about step data.")
			return
		end
		if not SDB or not SDB.steps then
			self:Debug("Sharing error: no step data sent before step_end")
			return
		end

		-- Verify completeness (warn, but don't drop the packet).
		for _, step in pairs(SDB.steps) do
			for li = 1, (step.linecount or 0) do
				if not step.lines[li] then
					self:Debug("Incomplete data received for step %d line %d", step.stepnum, li)
				end
			end
		end

		self:Debug("COMPLETE STEP DATA RECEIVED!")

		-- Reassemble the synthetic guide source.
		local mainstep = SDB.steps[SDB.mainstepnum]
		if not mainstep then
			self:Debug("No main step in buffer; aborting reassembly")
			return
		end

		local guidesource = ""

		-- Filler steps to push this step's content to its real stepnum.
		for i = 1, (mainstep.stepnum or 1) - 1 do
			guidesource = guidesource .. "step\n'\n"
		end

		-- stickystart lines (preserve order from buffer).
		for _, step in pairs(SDB.steps) do
			if step.sticky then
				guidesource = guidesource .. "stickystart " .. (step.label or "") .. "\n"
			end
		end

		-- Steps proper: step lines + shared_origin marker.
		for stepnum = SDB.mainstepnum, 9999 do
			local step = SDB.steps[stepnum]
			if not step then break end
			guidesource = guidesource .. table.concat(step.lines, "\n") .. "\nshared_origin " .. (step.stepnum or stepnum) .. "\n"
		end

		self.SharedGuideSource = guidesource

		-- Use a unique title per shared step in case RegisterGuide refuses
		-- re-registration of the same title.
		local unique_title = ("SHARED\\%s\\%s"):format(mainstep.guide or "guide", tostring(GetTime()))
		ZGV:RegisterGuide(unique_title, guidesource)

		-- Look the guide up by title and set it as the current guide.
		local synthetic = ZGV.GetGuideByTitle and ZGV:GetGuideByTitle(unique_title)
		if synthetic then
			-- WOTLK SetGuide(name, step, temp) — only 3 args, no `fromShared`.
			ZGV:SetGuide(synthetic)
		else
			-- Fallback: set by title.
			ZGV:SetGuide(unique_title)
		end

		-- Try to focus the shared step within the synthetic guide.
		if ZGV.CurrentGuide and ZGV.CurrentGuide.steps then
			for sn, st in ipairs(ZGV.CurrentGuide.steps) do
				if st.shared_origin and tonumber(st.shared_origin) == SDB.mainstepnum then
					if ZGV.SetStepNum then
						ZGV:SetStepNum(sn)
					elseif ZGV.FocusStep then
						ZGV:FocusStep(sn)
					end
					break
				end
			end
		end

		self:Debug("Step data consumed.")

	elseif packet.type == PACKETTYPE_STATUSREQUEST then
		self:Debug("Status requested, announcing.")
		self:AnnounceStatus()

	elseif packet.type == PACKETTYPE_STEPREQUEST then
		if self:IsMaster() then
			self:Debug("Step requested, I'm the master, announcing.")
			self:BroadcastStepContents()
		else
			self:Debug("Step requested, but I'm not the master.")
		end

	elseif packet.type == PACKETTYPE_SLAVEREQUEST then
		if not ZGV.db.profile.sync_enabled then return end
		if ZGV.db.profile.share_masterslave == 2 then return end
		self:ShowSlavePopup(packet.sender, packet.guide, false)
	end

	if self.packet_callbacks[packet.type] then
		self.packet_callbacks[packet.type](packet)
	end
end

-- =====================================================================
-- PARTY STATUS / GATING
-- =====================================================================

local dummytable = {}
function Sync:OnPartyStatusChanged()
	local s = "Party status:\n"
	self.master_present_status = nil
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
		if status.sharemode == 1 then self.master_present_status = status end
	end
	self:Debug(s)
	if ZGV.UpdateFrame then ZGV:UpdateFrame() end
	self:UpdateButtonColor()

	-- Hide slave popup if the master disappears.
	if self.SlavePopup and self.SlavePopup:IsVisible() and not self.master_present_status then
		self.SlavePopup:Hide()
	end

	if self:IsPartyStatusComplete() then self:DeclarePartyStatusComplete() end

	-- Pass force=true to bypass ZGV's 1s throttle on TryToCompleteStep.
	-- We just received authoritative party status from a comm packet, so
	-- re-checking completion now is the whole point of sync.
	if ZGV.TryToCompleteStep then ZGV:TryToCompleteStep(true) end
end

function Sync:DeclarePartyStatusComplete(timeout)
	if self:IsSlave() and not self.master_present_status then
		self:Debug("Party status complete%s, master missing, deactivating slave mode.",
			timeout and " (TIMEOUT)" or "")
		self:Deactivate()
	end
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

local statuscolors  = { [0] = "ffff0000", [1] = "ff00ff00", [2] = "ff888888" }
local statuscolors2 = { [0] = "ffff8888", [1] = "ff00ff00", [2] = "ff888888" }
local statustext    = { [0] = "incomplete", [1] = "complete", [2] = "impossible" }

function Sync:GetStepGoalPartyStatusText(stepnum, goalnum)
	if not self:IsEnabled() or not self.PartyStatus then return end
	local s = ""
	local on_step = 0
	local any_incomplete = false
	local partysort = {}
	-- 3.3.5a: no LE_PARTY_CATEGORY_HOME; IsInGroup() is the gate.
	if IsInGroup() then
		for i = 1, GetNumGroupMembers() - 1 do
			partysort[#partysort+1] = UnitName("party" .. i)
		end
	else
		for k in pairs(self.PartyStatus) do partysort[#partysort+1] = k end
	end
	for i, name in ipairs(partysort) do
		local status = self.PartyStatus[name]
		if status then
			local matches = status.guide and (status.guide:gsub("^SHARED\\", "") == ((ZGV.CurrentGuide and ZGV.CurrentGuide.title or ""):gsub("^SHARED\\", "")))
			if matches then
				local step
				if status.stepnum == stepnum then
					step = status
				elseif status.stickies then
					for _, st in ipairs(status.stickies) do
						if st.stepnum == stepnum then step = st break end
					end
				end
				if step then
					if on_step > 0 then s = s .. ", " end
					on_step = on_step + 1
					local color, display
					local goal = status.goals[goalnum]
					local style = ZGV.db.profile.share_partydisplaystyle or 1
					if style == 1 then
						if not goal then color = 2
						elseif goal.complete then color = 1
						elseif goal.needed then
							color = 0
						else color = 2 end
						s = s .. ("|c%s%s|r"):format(statuscolors2[color] or "ffff00ff", name)
					elseif style == 2 then
						if not goal then color = 2
						elseif goal.complete then color = 1
						elseif goal.needed then color = 0
						else color = 2 end
						s = s .. ("%s (%s)"):format(name, statustext[color] or "unknown")
					else
						if not goal then s = s .. ("%s |cff888888[?]|r"):format(name)
						elseif goal.complete then s = s .. ("%s |cff88ff88[√]|r"):format(name)
						elseif goal.done and goal.needed then s = s .. ("%s |cffff8888[%d/%d]|r"):format(name, goal.done, goal.needed)
						else s = s .. ("%s |cff888888[?]|r"):format(name)
						end
					end
					if status.goals[goalnum] ~= 1 then any_incomplete = true end
				end
			end
		end
	end
	if on_step > 0 then
		local style = ZGV.db.profile.share_partydisplaystyle or 1
		if style == 1 then
			return "Party: " .. s, nil
		else
			return s, statuscolors[any_incomplete and 0 or 1]
		end
	end
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
-- STEP SOURCE EXTRACTION (operates on rawdata, not rawdata_full)
-- =====================================================================

function Sync:GetStepSource(stepnum, fromwriter)
	local t1 = debugprofilestop()
	if not ZGV.CurrentGuide or not ZGV.CurrentGuide.rawdata then return {} end
	local sn, li = 0, 0
	local rawstep = {}
	local in_step = false
	for line in (ZGV.CurrentGuide.rawdata .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		li = li + 1
		local cmd = line:match("^%s*(%S+)")
		if cmd == "step" then
			sn = sn + 1
			in_step = (sn == stepnum)
			if #rawstep > 0 and not in_step then break end
		elseif cmd and (cmd:match("^stickystart$") or cmd:match("^stickystop$") or cmd:match("^stickyst[artop]+$")) then
			in_step = false
		elseif cmd and (line:find("#include", 1, true) or line:find("leechstep", 1, true)) then
			in_step = false
		end
		if in_step then
			rawstep[#rawstep+1] = line
			-- Insert a map line if the step has a map set (TBC parity).
			if cmd == "step" and ZGV.CurrentGuide.steps and ZGV.CurrentGuide.steps[stepnum] and ZGV.CurrentGuide.steps[stepnum].map and not fromwriter then
				rawstep[#rawstep+1] = "map " .. tostring(ZGV.CurrentGuide.steps[stepnum].map)
			end
		end
	end
	local t2 = debugprofilestop()
	self:Debug("Extracting current step source took %.2fms", t2 - t1)
	return rawstep
end

-- =====================================================================
-- ROLE / MODE HELPERS
-- =====================================================================

function Sync:IsInGroup()
	-- 3.3.5a: no category arg. share_fakeparty stored but unused in v1.
	if IsInGroup() then return true end
	-- share_fakeparty is a no-op option in v1 (per brief).
	return false
end

function Sync:IsSlave()
	return self:IsEnabled() and ZGV.db.profile.share_masterslave == 2
end

function Sync:IsMaster()
	return self:IsEnabled() and ZGV.db.profile.share_masterslave == 1
end

function Sync:IsEnabled()
	return ZGV.db.profile.sync_enabled and self:IsInGroup()
end

function Sync:IsSecret()
	-- TBC disabled in retail instances via ZGV.IsRetail. WOTLK skips
	-- this check entirely (per locked decision: no instance gate).
	return false
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
	if self:IsSecret() then return end

	local message_packed = LibDeflate:CompressDeflate(message)
	if not message_packed then return end
	local message_encoded = LibDeflate:EncodeForWoWAddonChannel(message_packed)
	if not message_encoded then return end

	AceComm:SendCommMessage(PREFIX, message_encoded, "PARTY")
	self:Debug("|cffffaa00SND|r: %s", tostring(message))
	if select("#", ...) > 0 then return self:Send(...) end
end

function Sync:SendSelf(message, ...)
	if not message then return end
	local message_packed = LibDeflate:CompressDeflate(message)
	if not message_packed then return end
	local message_encoded = LibDeflate:EncodeForWoWAddonChannel(message_packed)
	if not message_encoded then return end
	AceComm:SendCommMessage(PREFIX, message_encoded, "WHISPER", UnitName("player"))
	self:Debug("|cffffaa00SND (self)|r: %s", tostring(message))
	if select("#", ...) > 0 then return self:SendSelf(...) end
end

-- =====================================================================
-- BROADCASTS
-- =====================================================================

function Sync:AnnounceStatus()
	if self:IsInGroup() then
		self:Send(self:CreatePacket_GuideStatus())
		self:Debug("Announcing status.")
	end
	-- share_fakeparty is a no-op in v1.
end

function Sync:BroadcastStepContents()
	self:Send(self:CreatePackets_StepData())
	self:Debug("Announcing step data.")
end

function Sync:RequestStepContents()
	self:Send(self:CreatePacket_StepRequest())
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

function Sync:RequestSlaveMode()
	self:Send(self:CreatePacket_SlaveRequest())
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
	if self.master_present_status and not newps[self.master_present_status.sender] then
		self.master_present_status = nil
	end
	self.PartyStatus = newps
end

function Sync:GetParty_NotSlaveNames()
	local t = {}
	self.PartyStatus = self.PartyStatus or {}
	for n, s in pairs(self.PartyStatus) do
		if s.sharemode == 0 then tinsert(t, n) end
	end
	return t
end

function Sync:GetParty_SlaveNames()
	local t = {}
	self.PartyStatus = self.PartyStatus or {}
	for n, s in pairs(self.PartyStatus) do
		if s.sharemode == 2 then tinsert(t, n) end
	end
	return t
end

-- =====================================================================
-- MASTER / SLAVE ACTIVATION
-- =====================================================================

function Sync:ActivateAsMaster()
	-- WOTLK has no AceConfig "share_masterslave" option yet (Phase 4).
	-- Write directly to the SavedVariables profile and update mode.
	ZGV.db.profile.sync_enabled = true
	ZGV.db.profile.share_masterslave = 1
	ZGV:SendMessage("ZGV_SHAREMODE", "master")
	self:RequestSlaveMode()
end

function Sync:ActivateAsSlave()
	ZGV.db.profile.sync_enabled = true
	ZGV.db.profile.share_masterslave = 2
	ZGV:SendMessage("ZGV_SHAREMODE", "slave")
end

function Sync:Deactivate()
	local skip_afterwards
	if self:IsMaster() and ZGV.CurrentStep and not ZGV.CurrentStep:AreRequirementsMet() then
		skip_afterwards = true
	end
	ZGV.db.profile.share_masterslave = 0
	if skip_afterwards and ZGV.SkipStep then ZGV:SkipStep() end
	ZGV:SendMessage("ZGV_SHAREMODE", "off")
end

-- =====================================================================
-- POPUP FRAMES (AceGUI-flavored plain Frame; v1 keeps it minimal)
-- =====================================================================

local function make_popup_frame(name, parent)
	local f = CreateFrame("Frame", name, parent or UIParent)
	f:SetSize(360, 140)
	f:SetPoint("CENTER")
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	f:SetBackdropColor(0, 0, 0, 0.85)
	f:Hide()
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.title:SetPoint("TOP", 0, -10)
	f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
	f.text:SetJustifyH("LEFT")
	f.text:SetWidth(340)
	local accept = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	accept:SetSize(120, 24)
	accept:SetPoint("BOTTOMLEFT", 12, 12)
	f.accept = accept
	local decline = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	decline:SetSize(120, 24)
	decline:SetPoint("BOTTOMRIGHT", -12, 12)
	f.decline = decline
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	return f
end

function Sync:ShowSlavePopup(sender, guide, isInitiation)
	if not self.SlavePopup then
		local f = make_popup_frame("ZGVSlaveInvite", UIParent)
		f.accept:SetText(ACCEPT)
		f.decline:SetText(DECLINE)
		f.accept:SetScript("OnClick", function()
			if Sync.SlavePopup then Sync.SlavePopup:Hide() end
			Sync:ActivateAsSlave()
		end)
		f.decline:SetScript("OnClick", function()
			if Sync.SlavePopup then Sync.SlavePopup:Hide() end
		end)
		self.SlavePopup = f
	end
	self.SlavePopup.title:SetText(L["share_tooltip_title"] or "Share Guide")
	local key = isInitiation and "share_invite_slaveinitiated" or "share_invite_received"
	self.SlavePopup.text:SetText(safe_format(L[key], sender or "?", FormatNiceGuideTitle(guide or "")))
	self.SlavePopup:Show()
end

function Sync:ShowMasterPopup()
	if not self.MasterConfirmPopup then
		local f = make_popup_frame("ZGVShareInitiate", UIParent)
		f.accept:SetText(ACCEPT)
		f.decline:SetText(DECLINE)
		f.accept:SetScript("OnClick", function()
			if Sync.MasterConfirmPopup then Sync.MasterConfirmPopup:Hide() end
			Sync:ActivateAsMaster()
		end)
		f.decline:SetScript("OnClick", function()
			if Sync.MasterConfirmPopup then Sync.MasterConfirmPopup:Hide() end
		end)
		self.MasterConfirmPopup = f
	end
	self.MasterConfirmPopup.title:SetText(L["share_tooltip_title"] or "Share Guide")
	self.MasterConfirmPopup.text:SetText(safe_format(L["share_invite_master"],
		FormatNiceGuideTitle((ZGV.CurrentGuide and ZGV.CurrentGuide.title) or "")))
	self.MasterConfirmPopup:Show()
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
			if Sync:IsMaster() then Sync:BroadcastStepContents() end
		else
			Sync:Deactivate()
		end
		Sync:UpdateButtonColor()
	end
end

-- =====================================================================
-- STEP-CHANGE DEBOUNCE
-- =====================================================================

local function on_step_changed()
	if not Sync:IsEnabled() then return end
	-- share_fakeparty is a no-op in v1.
	if Sync:IsMaster() and Sync:IsInGroup() then
		Sync:BroadcastStepContents()
	end
	Sync:AnnounceStatus()
end

local function on_step_changed_msg(_, _, step)
	-- Cancel-and-reschedule debounce: collapse bursts of step changes into
	-- a single 0.3s-delayed broadcast. Replaces TBC's ZGV:Throttler.
	if Sync.StepChangeTimer then ZGV:CancelTimer(Sync.StepChangeTimer) end
	Sync.StepChangeTimer = ZGV:ScheduleTimer(on_step_changed, 0.3)
end

-- =====================================================================
-- INIT
-- =====================================================================

function Sync:Init()
	-- Settings defaults. v1 is auto-sync: enabled by default, no user-facing
	-- options. The settings below are kept for SavedVariables compatibility
	-- (so existing user settings don't break) but the magnetic gate is
	-- always active and there's no master/slave role.
	ZGV.db.profile.sync_enabled         = true
	ZGV.db.profile.share_masterslave    = 0
	ZGV.db.profile.sync_snap            = true
	ZGV.db.profile.share_fakeparty      = 0
	ZGV.db.profile.share_partydisplaystyle = 1
	ZGV.db.profile.sync_dontconfirm     = false

	-- AceComm registration.
	if not self._AceCommHandler then
		self._AceCommHandler = function(prefix, message, distribution, sender)
			Sync:OnChatReceived(message, distribution, sender)
		end
	end
	AceComm:RegisterComm(PREFIX, self._AceCommHandler)

	-- Event hooks.
	ZGV:AddEventHandler("GROUP_ROSTER_UPDATE", Sync.OnEvent)
	ZGV:AddEventHandler("PARTY_MEMBER_DISABLE", Sync.OnEvent)
	ZGV:AddEventHandler("PARTY_MEMBER_ENABLE", Sync.OnEvent)
	ZGV:AddEventHandler("PLAYER_ENTERING_WORLD", Sync.OnEvent)

	-- Message hooks (WOTLK may not fire GOAL_* messages; ZGV_STEP_CHANGED
	-- is the main signal. The 20s heartbeat is the workhorse fallback.)
	ZGV:AddMessageHandler("ZGV_GOAL_COMPLETED", function(_, _, step, goal)
		if Sync:IsEnabled() then
			Sync:Debug("GOAL_COMPLETED: %d %d", step, goal)
			Sync:AnnounceStatus()
		end
	end)
	ZGV:AddMessageHandler("ZGV_GOAL_UNCOMPLETED", function(_, _, step, goal)
		if Sync:IsEnabled() then
			Sync:Debug("GOAL_UNCOMPLETED: %d %d", step, goal)
			Sync:AnnounceStatus()
		end
	end)
	ZGV:AddMessageHandler("ZGV_STEP_CHANGED", on_step_changed_msg)
	ZGV:AddMessageHandler("ZGV_GOAL_PROGRESS", function(_, _, step, goal)
		if Sync:IsEnabled() then
			Sync:Debug("GOAL_PROGRESS: %d %d", step, goal)
			Sync:AnnounceStatus()
		end
	end)

	-- 20s heartbeat: re-announce + request party status.
	ZGV:ScheduleRepeatingTimer(function()
		if Sync:IsEnabled() then
			Sync:AnnounceStatus()
			Sync:RequestPartyStatus()
		end
	end, 20)

	self:UpdateButtonColor()
end

-- =====================================================================
-- MODE / BUTTON COLOR
-- =====================================================================

function Sync:UpdateMode()
	self:Debug("Mode updated: %d", ZGV.db.profile.share_masterslave or 0)
	self:AnnounceStatus()
	self:ResetPartyStatus()
	self:OnPartyStatusChanged()
	self:RequestPartyStatus()
	if self:IsSlave() then
		self:RequestStepContents()
	elseif self:IsMaster() then
		self:BroadcastStepContents()
	end
	self:UpdateButtonColor()
	if ZGV.UpdateFrame then ZGV:UpdateFrame() end
end

function Sync:UpdateButtonColor()
	-- The GuideShareButton is added in Phase 4. Until then, the frame
	-- doesn't exist; just return so we don't spam errors.
	local btn = _G["ZygorGuidesViewerFrame_Skipper_GuideShareButton"]
	if not btn then return end
	local r, g, b, a
	if self:IsInGroup() then
		if self:IsSlave() or self:IsMaster() then
			r, g, b, a = 0, 1, 0, 1
		else
			r, g, b, a = 1, 1, 1, 1
		end
	else
		r, g, b, a = 0.6, 0.6, 0.6, 1
	end
	if self:IsSecret() then r, g, b, a = 1, 1, 0, 1 end
	local normal = btn.GetNormalTexture and btn:GetNormalTexture()
	if normal and normal.SetVertexColor then normal:SetVertexColor(r, g, b, a) end
	local pushed = btn.GetPushedTexture and btn:GetPushedTexture()
	if pushed and pushed.SetVertexColor then pushed:SetVertexColor(r, g, b, a) end
	local prev = _G["ZygorGuidesViewerFrame_Skipper_PrevButton"]
	if prev and prev.SetEnabled then prev:SetEnabled(not self:IsSlave()) end
	local next_ = _G["ZygorGuidesViewerFrame_Skipper_NextButton"]
	if next_ and next_.SetEnabled then next_:SetEnabled(not self:IsSlave()) end
end

-- =====================================================================
-- BUTTON / TOOLTIP / POPUP HANDLERS
-- =====================================================================
-- v1 design: no button, no popup, no options. Sync is automatic when
-- `sync_enabled = true` (the default) and the user is in a party. The
-- entry points below are kept as no-ops so any stale references in
-- other modules (e.g. XML from a skin that may re-add a button in the
-- future) don't crash.

function Sync:OnShareButtonEnter(button)
	-- no-op (no button in v1)
end

function Sync:OnShareButtonClick()
	-- no-op (no button in v1)
end

function Sync:ShowMasterPopup()
	-- no-op (no popup in v1)
end

function Sync:ShowSlavePopup(sender, guide, isInitiation)
	-- no-op (no popup in v1)
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
