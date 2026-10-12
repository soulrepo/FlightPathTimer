-- FlightPathTimer: flight times on the taxi map tooltip and a countdown while flying.
-- Written for the 1.12 client (Lua 5.0): no '#', use table.getn / math.mod, scripts use this/arg1/event.

local ADDON = "FlightPathTimer"

-- Seconds of flight per unit of taxi-map distance, used until a continent has a recorded flight.
local DEFAULT_RATE = 1500
-- Flights shorter than this are treated as aborted and not recorded.
local MIN_RECORD_SECONDS = 10
-- How long to wait for UnitOnTaxi after picking a destination.
local PENDING_TIMEOUT = 10

local DB
local pending     -- { origin, dest, distance, continent, hops, at } between click and takeoff
local flight      -- { origin, dest, distance, continent, start, duration, known }

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffFlightPathTimer|r: " .. msg)
end

local function FormatTime(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local m = math.floor(seconds / 60)
    local s = math.floor(math.mod(seconds, 60))
    return string.format("%d:%02d", m, s)
end

local function RouteKey(origin, dest)
    return origin .. " -> " .. dest
end

-------------------------------------------------------------------------------
-- Taxi map helpers (only valid while the flight map is open)
-------------------------------------------------------------------------------

local function CurrentNodeName()
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            return TaxiNodeName(i)
        end
    end
    return nil
end

local function CurrentContinent()
    -- SetMapToCurrentZone moves the world map, so only do it while the map is hidden.
    if not (WorldMapFrame and WorldMapFrame:IsVisible()) then
        SetMapToCurrentZone()
    end
    return GetCurrentMapContinent() or 0
end

-- Sum of hop lengths in taxi-map coordinates, plus the number of hops.
local function PathDistance(index)
    local hops = GetNumRoutes and GetNumRoutes(index) or 0
    local total = 0
    if hops and hops > 0 and TaxiGetSrcX then
        for h = 1, hops do
            local dx = TaxiGetDestX(index, h) - TaxiGetSrcX(index, h)
            local dy = TaxiGetDestY(index, h) - TaxiGetSrcY(index, h)
            total = total + math.sqrt(dx * dx + dy * dy)
        end
        return total, hops
    end
    -- Fallback: straight line from the current node.
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            local x1, y1 = TaxiNodePosition(i)
            local x2, y2 = TaxiNodePosition(index)
            local dx, dy = x2 - x1, y2 - y1
            return math.sqrt(dx * dx + dy * dy), 1
        end
    end
    return 0, 1
end

-------------------------------------------------------------------------------
-- Duration lookup
-------------------------------------------------------------------------------

-- Returns duration, source. Only "flown" (this exact direction, recorded by us) counts as exact.
-- The return flight and FlightTracker's times (it saves both directions on landing) are estimates.
local function LookupRecorded(origin, dest)
    local t = DB.flights[RouteKey(origin, dest)]
    if t then return t, "flown" end
    t = DB.flights[RouteKey(dest, origin)]
    if t then return t, "return" end
    if FlightTrackerDB and FlightTrackerDB.flights then
        t = FlightTrackerDB.flights[RouteKey(origin, dest)] or FlightTrackerDB.flights[RouteKey(dest, origin)]
        if t then return t, "flighttracker" end
    end
    return nil
end

local function RateFor(continent)
    local r = DB.rates[continent]
    if r and r.dist > 0 then
        return r.time / r.dist
    end
    return DEFAULT_RATE
end

-- Returns duration, isExact, source ("flown", "return", "flighttracker" or "distance")
local function GetFlightTime(origin, dest, distance, continent)
    if origin and dest then
        local t, source = LookupRecorded(origin, dest)
        if t then return t, source == "flown", source end
    end
    if distance and distance > 0 then
        return distance * RateFor(continent), false, "distance"
    end
    return nil, false
end

local ESTIMATE_LABEL = {
    ["return"] = "estimate from return flight",
    flighttracker = "estimate from FlightTracker",
    distance = "estimate",
}

-------------------------------------------------------------------------------
-- In-flight timer frame
-------------------------------------------------------------------------------

local timer = CreateFrame("Frame", "FlightPathTimerFrame", UIParent)
timer:SetWidth(220)
timer:SetHeight(52)
timer:SetFrameStrata("MEDIUM")
timer:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
timer:SetBackdropColor(0, 0, 0, 0.75)
timer:SetBackdropBorderColor(0.4, 0.8, 1, 0.9)
timer:SetMovable(true)
timer:EnableMouse(true)
timer:RegisterForDrag("LeftButton")
timer:SetClampedToScreen(true)
timer:Hide()

timer.dest = timer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
timer.dest:SetPoint("TOPLEFT", timer, "TOPLEFT", 8, -7)
timer.dest:SetPoint("TOPRIGHT", timer, "TOPRIGHT", -8, -7)
timer.dest:SetJustifyH("LEFT")

timer.bar = CreateFrame("StatusBar", nil, timer)
timer.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
timer.bar:SetStatusBarColor(0.25, 0.65, 1)
timer.bar:SetPoint("BOTTOMLEFT", timer, "BOTTOMLEFT", 7, 7)
timer.bar:SetPoint("BOTTOMRIGHT", timer, "BOTTOMRIGHT", -7, 7)
timer.bar:SetHeight(16)
timer.bar:SetMinMaxValues(0, 1)

timer.bar.bg = timer.bar:CreateTexture(nil, "BACKGROUND")
timer.bar.bg:SetAllPoints(timer.bar)
timer.bar.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
timer.bar.bg:SetVertexColor(0.1, 0.1, 0.1, 0.8)

timer.text = timer.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
timer.text:SetPoint("CENTER", timer.bar, "CENTER", 0, 0)

local function SavePosition()
    local point, _, relPoint, x, y = timer:GetPoint()
    DB.pos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition()
    timer:ClearAllPoints()
    local p = DB.pos
    if p then
        timer:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        timer:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
end

timer:SetScript("OnDragStart", function()
    if not DB.locked then this:StartMoving() end
end)
timer:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    SavePosition()
end)

local throttle = 0
timer:SetScript("OnUpdate", function()
    throttle = throttle + arg1
    if throttle < 0.1 then return end
    throttle = 0
    if not flight then this:Hide() return end

    local elapsed = GetTime() - flight.start
    if flight.duration and flight.duration > 0 then
        local remaining = flight.duration - elapsed
        local prefix = flight.known and "" or "~"
        if remaining >= 0 then
            this.text:SetText(prefix .. FormatTime(remaining) .. " remaining")
        else
            this.text:SetText("Arriving... (+" .. FormatTime(-remaining) .. ")")
        end
        this.bar:SetValue(math.min(elapsed / flight.duration, 1))
    else
        this.text:SetText(FormatTime(elapsed) .. " elapsed")
        this.bar:SetValue(0)
    end
end)

local function ShowTimer()
    if not DB.showTimer or not flight then return end
    local name = string.gsub(flight.dest, ",.*$", "")
    timer.dest:SetText(name)
    timer:Show()
end

-------------------------------------------------------------------------------
-- Flight lifecycle
-------------------------------------------------------------------------------

local function StartFlight()
    local p = pending
    pending = nil
    local duration, known = GetFlightTime(p.origin, p.dest, p.distance, p.continent)
    flight = {
        origin = p.origin, dest = p.dest, distance = p.distance, continent = p.continent,
        start = GetTime(), duration = duration, known = known,
    }
    DB.active = flight  -- survives /reload mid-flight
    ShowTimer()
end

local function EndFlight()
    local f = flight
    flight = nil
    DB.active = nil
    timer:Hide()
    if not f or not f.origin then return end

    local duration = GetTime() - f.start
    if duration < MIN_RECORD_SECONDS then return end

    DB.flights[RouteKey(f.origin, f.dest)] = math.floor(duration + 0.5)

    if f.distance and f.distance > 0 and f.continent then
        local r = DB.rates[f.continent] or { time = 0, dist = 0 }
        r.time = r.time + duration
        r.dist = r.dist + f.distance
        DB.rates[f.continent] = r
    end

    if f.duration and f.duration > 0 and DB.verbose then
        Print(string.format("Landed at %s in %s (expected %s%s).", f.dest, FormatTime(duration),
            f.known and "" or "~", FormatTime(f.duration)))
    end
end

local monitor = CreateFrame("Frame")
local monitorElapsed = 0
monitor:Hide()
monitor:SetScript("OnUpdate", function()
    monitorElapsed = monitorElapsed + arg1
    if monitorElapsed < 0.2 then return end
    monitorElapsed = 0

    local onTaxi = UnitOnTaxi("player")
    if pending then
        if onTaxi then
            StartFlight()
        elseif GetTime() - pending.at > PENDING_TIMEOUT then
            pending = nil
        end
    elseif flight then
        if not onTaxi then EndFlight() end
    else
        this:Hide()
    end
end)

-------------------------------------------------------------------------------
-- Taxi map hooks
-------------------------------------------------------------------------------

local function HookTaxiMap()
    local origTake = TakeTaxiNode
    TakeTaxiNode = function(index)
        if TaxiNodeGetType(index) == "REACHABLE" then
            local distance, hops = PathDistance(index)
            pending = {
                origin = CurrentNodeName(),
                dest = TaxiNodeName(index),
                distance = distance,
                hops = hops,
                continent = CurrentContinent(),
                at = GetTime(),
            }
            monitor:Show()
        end
        return origTake(index)
    end

    local origEnter = TaxiNodeOnButtonEnter
    TaxiNodeOnButtonEnter = function(button)
        origEnter(button)
        local index = button:GetID()
        if not index or TaxiNodeGetType(index) ~= "REACHABLE" then return end

        local distance, hops = PathDistance(index)
        local duration, known, source = GetFlightTime(CurrentNodeName(), TaxiNodeName(index), distance, CurrentContinent())
        if duration then
            if known then
                GameTooltip:AddLine("Flight time: " .. FormatTime(duration), 0.4, 0.8, 1)
            else
                GameTooltip:AddLine("Flight time: ~" .. FormatTime(duration) .. " (" .. ESTIMATE_LABEL[source] .. ")", 0.7, 0.7, 0.7)
            end
        end
        if hops and hops > 1 then
            GameTooltip:AddLine("Stops: " .. (hops - 1), 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end
end

-------------------------------------------------------------------------------
-- Events and slash commands
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == ADDON then
        FlightPathTimerDB = FlightPathTimerDB or {}
        DB = FlightPathTimerDB
        DB.flights = DB.flights or {}
        DB.rates = DB.rates or {}
        if DB.showTimer == nil then DB.showTimer = true end
        if DB.locked == nil then DB.locked = false end
        if DB.verbose == nil then DB.verbose = false end
        RestorePosition()
        HookTaxiMap()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Resume the countdown after a /reload or relog mid-flight.
        if DB.active and UnitOnTaxi("player") and DB.active.start <= GetTime() then
            flight = DB.active
            ShowTimer()
            monitor:Show()
        elseif DB.active and not UnitOnTaxi("player") then
            DB.active = nil
        end
    end
end)

SLASH_FLIGHTPATHTIMER1 = "/fpt"
SLASH_FLIGHTPATHTIMER2 = "/flightpathtimer"
SlashCmdList["FLIGHTPATHTIMER"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "lock" then
        DB.locked = true
        Print("Timer locked.")
    elseif msg == "unlock" then
        DB.locked = false
        Print("Timer unlocked. Drag it to move it.")
    elseif msg == "test" then
        timer.dest:SetText("Test flight")
        flight = flight or { dest = "Test flight", start = GetTime(), duration = 90, known = true }
        timer:Show()
        Print("Showing a test timer. Use /fpt hide to close it.")
    elseif msg == "hide" then
        if flight and not flight.origin then flight = nil end
        timer:Hide()
    elseif msg == "toggle" then
        DB.showTimer = not DB.showTimer
        Print("In-flight timer " .. (DB.showTimer and "on." or "off."))
    elseif msg == "verbose" then
        DB.verbose = not DB.verbose
        Print("Landing messages " .. (DB.verbose and "on." or "off."))
    elseif msg == "reset" then
        DB.flights = {}
        DB.rates = {}
        Print("Forgot all recorded flight times.")
    else
        local n = 0
        for _ in pairs(DB.flights) do n = n + 1 end
        Print(n .. " routes recorded. Commands: /fpt lock | unlock | test | hide | toggle | verbose | reset")
    end
end
