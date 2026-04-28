local repo = 'https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/'
local Library      = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager  = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Camera            = workspace.CurrentCamera

local lp = Players.LocalPlayer

-- Bypass void death instantly
pcall(function() workspace.FallenPartsDestroyHeight = -9e9 end)

-- ============================================================
-- connection manager
-- tracks every connection so panic key can kill everything
-- ============================================================
local conns = {}
local function reg(key, conn)
    if conns[key] then pcall(function() conns[key]:Disconnect() end) end
    conns[key] = conn
    return conn
end
local function unreg(key)
    if conns[key] then pcall(function() conns[key]:Disconnect() end) conns[key] = nil end
end
local function panicDisconnect()
    for k, c in pairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    conns = {}
end

-- ============================================================
-- player cache
-- refreshes every 60 frames instead of querying every call
-- ============================================================
local playerCache = {}
local cacheFrame = 0
local CACHE_INTERVAL = 60

local function refreshCache()
    playerCache = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            playerCache[p.Name] = p
        end
    end
end
refreshCache()

-- ============================================================
-- RakNet Ghost Visuals & Hook
-- ============================================================
local ghostModel = nil
local groundParts = {}
local attachments = {}
local vfxConn = nil

local PI2 = math.pi * 2
local OUTER_RADIUS, INNER_RADIUS = 3.2, 1.8
local OUTER_SPEED, INNER_SPEED = 2.5, -3.5
local GROUND_OFFSET, SPARK_INTERVAL = 3.1, 0.05

local lightningColor = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(100, 180, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 40, 200)),
})

local sparkSize = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(0.5, 0.08), NumberSequenceKeypoint.new(1, 0)})
local ringSizeOuter = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 0)})
local ringSizeInner = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.07), NumberSequenceKeypoint.new(1, 0)})

local function rakhook(packet)
	if packet.PacketId == 0x1B then
		local buf = packet.AsBuffer
		buffer.writeu32(buf, 1, 0xFFFFFFFF)
		packet:SetData(buf)
	end
end

local function makeSparks(parent)
	local att = Instance.new("Attachment", parent)
	local sparks = Instance.new("ParticleEmitter", att)
	sparks.Color = lightningColor
	sparks.LightEmission, sparks.LightInfluence = 1, 0
	sparks.Size = sparkSize
	sparks.Lifetime = NumberRange.new(0.1, 0.3)
	sparks.Rate = 0
	sparks.Speed = NumberRange.new(5, 20)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.RotSpeed, sparks.Rotation = NumberRange.new(-360, 360), NumberRange.new(0, 360)
	return att
end

local function makeRingDot(px, py, pz, sz, col, sparksSize)
	local dot = Instance.new("Part")
	dot.Anchored, dot.CanCollide, dot.CanTouch, dot.CanQuery, dot.CastShadow = true, false, false, false, false
	dot.Size, dot.Shape, dot.Material = Vector3.new(sz, sz, sz), Enum.PartType.Ball, Enum.Material.Neon
	dot.Color, dot.CFrame = col, CFrame.new(px, py, pz)
	dot.Parent = workspace
	local att = Instance.new("Attachment", dot)
	local em = Instance.new("ParticleEmitter", att)
	em.Color, em.LightEmission, em.LightInfluence = lightningColor, 1, 0
	em.Size, em.Lifetime, em.Rate = sparksSize, NumberRange.new(0.1, 0.2), 10
	em.Speed, em.SpreadAngle = NumberRange.new(1, 5), Vector2.new(180, 180)
	return dot
end

local function removeGhost()
	if vfxConn then vfxConn:Disconnect(); vfxConn = nil end
	for _, p in ipairs(groundParts) do if p.dot then p.dot:Destroy() end end
	groundParts, attachments = {}, {}
	if ghostModel then ghostModel:Destroy(); ghostModel = nil end
end

local function createGhost(pos)
	removeGhost()
	local char = lp.Character; if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end

	local offset = pos - hrp.Position
	char.Archivable = true
	local ghost = char:Clone()
	char.Archivable = false
	if not ghost then return end

	ghost.Name = "GhostMarker"
	for _, v in ipairs(ghost:GetDescendants()) do
		pcall(function()
			if v:IsA("Script") or v:IsA("LocalScript") or v:IsA("ModuleScript") or v:IsA("Animator") then v:Destroy() end
		end)
	end

	local hum = ghost:FindFirstChildOfClass("Humanoid")
	if hum then hum:Destroy() end

	for _, v in ipairs(ghost:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Anchored, v.CanCollide, v.CanTouch, v.CanQuery, v.CastShadow = true, false, false, false, false
			v.Transparency, v.Material, v.Color = 0, Enum.Material.SmoothPlastic, Color3.fromRGB(0, 20, 80)
			v.CFrame = v.CFrame + offset
			if v.Name ~= "HumanoidRootPart" then
				for e = 1, 3 do table.insert(attachments, makeSparks(v)) end
			end
		end
	end

	local ghostHRP = ghost:FindFirstChild("HumanoidRootPart")
	if ghostHRP then ghostHRP.Transparency = 1; ghostHRP.CFrame = CFrame.new(pos) * (hrp.CFrame - hrp.CFrame.Position) end

	local hl = Instance.new("Highlight", ghost)
	hl.FillColor, hl.FillTransparency = Color3.fromRGB(0, 60, 180), 0
	hl.OutlineColor, hl.OutlineTransparency = Color3.fromRGB(0, 120, 255), 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = ghost

	ghost.Parent = workspace
	ghostModel = ghost

	local rCount, iCount = 32, 20
	local gy = pos.Y - GROUND_OFFSET
	local outerCol, innerCol = Color3.fromRGB(0, 100, 255), Color3.fromRGB(150, 210, 255)

	for i = 1, rCount do
		local a = (i / rCount) * PI2
		table.insert(groundParts, {dot = makeRingDot(pos.X + math.cos(a) * OUTER_RADIUS, gy, pos.Z + math.sin(a) * OUTER_RADIUS, 0.25, outerCol, ringSizeOuter), baseAngle = a, isOuter = true})
	end
	for i = 1, iCount do
		local a = (i / iCount) * PI2
		table.insert(groundParts, {dot = makeRingDot(pos.X + math.cos(a) * INNER_RADIUS, gy, pos.Z + math.sin(a) * INNER_RADIUS, 0.15, innerCol, ringSizeInner), baseAngle = a, isOuter = false})
	end

	local sparkTimer = 0
	vfxConn = RunService.Heartbeat:Connect(function(dt)
		if not ghostModel or not ghostModel.Parent then return end
		local t = tick()
		local pulse = math.abs(math.sin(t * 2))
		hl.FillColor = Color3.fromRGB(0, math.floor(40 + pulse * 30), math.floor(160 + pulse * 60))
		hl.OutlineColor, hl.OutlineTransparency = Color3.fromRGB(0, math.floor(100 + pulse * 60), 255), pulse * 0.3

		for _, entry in ipairs(groundParts) do
			if entry.dot and entry.dot.Parent then
				local radius = entry.isOuter and OUTER_RADIUS or INNER_RADIUS
				local speed = entry.isOuter and OUTER_SPEED or INNER_SPEED
				local a = entry.baseAngle + t * speed
				local wave = math.abs(math.sin(t * 5 + entry.baseAngle)) * 0.2
				entry.dot.CFrame = CFrame.new(pos.X + math.cos(a) * radius, gy + wave, pos.Z + math.sin(a) * radius)
				entry.dot.Transparency = math.abs(math.sin(t * 6 + entry.baseAngle)) * 0.4
				entry.dot.Color = entry.isOuter and Color3.fromRGB(0, math.floor(80 + pulse * 60), 255) or Color3.fromRGB(math.floor(120 + pulse * 60), math.floor(180 + pulse * 40), 255)
			end
		end

		sparkTimer = sparkTimer + dt
		if sparkTimer >= SPARK_INTERVAL then
			sparkTimer = 0
			if #attachments > 0 then
				for b = 1, math.random(2, 5) do
					local pick = attachments[math.random(1, #attachments)]
					if pick and pick.Parent then
						local emitter = pick:FindFirstChildOfClass("ParticleEmitter")
						if emitter then emitter:Emit(math.random(8, 25)) end
					end
				end
			end
		end
	end)
end

local function toggleRakNetDesync(v)
    if v then
        -- NOTE: root() is defined later in the file, so we inline the lookup here
        local char = lp.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            createGhost(hrp.Position)
        end
        local ok, err = pcall(function() raknet.add_send_hook(rakhook) end)
        if not ok then
            warn("[void master] raknet hook failed: " .. tostring(err))
        end
    else
        pcall(function() raknet.remove_send_hook(rakhook) end)
        removeGhost()
    end
end

local function cachedFind(name)
    if not name or name == "none" then return nil end
    return playerCache[name] or Players:FindFirstChild(name)
end

local function cachedList()
    local l = {}
    for name in pairs(playerCache) do table.insert(l, name) end
    if #l == 0 then table.insert(l, "none") end
    table.sort(l)
    return l
end

-- keep cache in sync with join/leave
Players.PlayerAdded:Connect(function(p) if p ~= lp then playerCache[p.Name] = p end end)
Players.PlayerRemoving:Connect(function(p) playerCache[p.Name] = nil end)

-- ============================================================
-- debounce helper
-- ============================================================
local function debounce(cd)
    local last = 0
    return function()
        local now = tick()
        if now - last < cd then return false end
        last = now
        return true
    end
end

-- ============================================================
-- character refs (auto-update)
-- ============================================================
local myChar, myRoot, myHum

local function refreshChar(c)
    myChar = c
    myRoot = c:WaitForChild("HumanoidRootPart")
    myHum = c:WaitForChild("Humanoid")
end
if lp.Character then pcall(refreshChar, lp.Character) end
lp.CharacterAdded:Connect(function(c) refreshChar(c) end)

-- safe accessors
local function root() return myChar and myChar:FindFirstChild("HumanoidRootPart") end
local function hum() return myChar and myChar:FindFirstChildOfClass("Humanoid") end

local function tgtRoot(name)
    local p = cachedFind(name)
    if not p or not p.Character then return nil end
    return p.Character:FindFirstChild("HumanoidRootPart")
end

local function tgtHum(name)
    local p = cachedFind(name)
    if not p or not p.Character then return nil end
    return p.Character:FindFirstChildOfClass("Humanoid")
end

local function tgtPart(name, part)
    local p = cachedFind(name)
    if not p or not p.Character then return nil end
    return p.Character:FindFirstChild(part)
end

-- ============================================================
-- constants
-- ============================================================
local BENCH_LOCATIONS = {
    Vector3.new(504.199463, 2389.413818, 485.759338),
    Vector3.new(571.336060, 2389.174316, 250.059448),
    Vector3.new(678.740723, 2389.128662, 251.148087),
    Vector3.new(768.364746, 2389.228516, 390.359741),
    Vector3.new(817.045166, 2389.123047, 322.078522),
    Vector3.new(502.039246, 2391.030273, 263.039459),
    Vector3.new(500.525452, 2391.030273, 248.947220)
}
local SAFE_POS   = BENCH_LOCATIONS[4] -- default fallback
local BENCH_NAME = "G"
local V3ZERO     = Vector3.zero

local function getClosestBenchPos(currentPos)
    local closestPos = SAFE_POS
    local closestDist = math.huge
    for _, pos in ipairs(BENCH_LOCATIONS) do
        local dist = (currentPos - pos).Magnitude
        if dist < closestDist then
            closestDist = dist
            closestPos = pos
        end
    end
    return closestPos
end

-- ============================================================
-- config
-- ============================================================
local cfg = {
    -- void
    voidSpam = false, voidDepth = -600, voidSpeed = 1,
    voidPhases = 2, voidRand = false,
    voidDodge = false, dodgeThresh = -50, dodgeBoost = 2000, safeY = 50,
    voidHead = false, voidHeadTgt = nil, voidHeadAggro = 1,

    -- anti death
    godmode = false, antiVoid = false, antiVoidY = -100,

    -- player
    selected = nil,

    -- orbit
    orbit = false, oRad = 10, oSpd = 2, oAng = 0,
    oH = 0, oBob = false, oBobAmt = 3, oRev = false, oFace = true,

    -- bring
    bring = false, bDist = 5, bSide = 0, bH = 0, bDelay = 0, bFront = true,

    -- goto
    goTo = false, gDist = 3, gDelay = 0,

    -- spin
    spin = false, spinSpd = 15, spinAng = 0,

    -- aim
    silent = false, silentFov = 300, silentPart = "Head", showFov = false,
    wallbang = false,

    -- stomp
    stomp = false, stompTgts = {},

    -- anti debuffs
    noEndlag = false, noStun = false, noStompCd = false,
    noHurt = false, noRagdoll = false, autoSprint = false,

    -- anti rager
    desync = false, velSpoof = false, antiBring = false, antiAttach = false,

    -- survival
    autoHeal = false, healTh = 60, healCd = 3,
    emergTp = false, emergTh = 25, emergCd = 5,
    grabBench = false, isHealing = false,

    -- gun
    noGunAnims = false, noMuzzle = false, noShootFx = false,

    -- esp
    hl = false, hlColor = Color3.fromRGB(255, 80, 80),
    box = false, boxColor = Color3.fromRGB(255, 255, 255),
    hpBar = false, hpLow = Color3.fromRGB(255, 0, 0), hpHigh = Color3.fromRGB(0, 255, 0),
    names = false, nameColor = Color3.fromRGB(255, 255, 255), nameSize = 13,
    skel = false, skelColor = Color3.fromRGB(255, 255, 255),
    tracer = false, tracerColor = Color3.fromRGB(0, 200, 255), tracerOrigin = "Bottom",

    -- visuals
    hitmark = false, dmgVig = false, healFl = false,
    killFeed = false, dmgNums = false,
    statusHud = true, tgtCursor = false,

    -- internal
    action = "idle",
}

local healDb = debounce(3)
local emergDb = debounce(5)
local prevHp = 100

-- ============================================================
-- vfx elements (created once, updated in render)
-- ============================================================

-- vignette
local fxGui = Instance.new("ScreenGui")
fxGui.Name = "vm" ; fxGui.ResetOnSpawn = false
fxGui.ZIndexBehavior = Enum.ZIndexBehavior.Global ; fxGui.DisplayOrder = 999
pcall(function() fxGui.Parent = game:GetService("CoreGui") end)

local dmgFr = Instance.new("Frame")
dmgFr.Size = UDim2.new(1,0,1,0) ; dmgFr.BackgroundColor3 = Color3.fromRGB(255,0,0)
dmgFr.BackgroundTransparency = 1 ; dmgFr.BorderSizePixel = 0 ; dmgFr.ZIndex = 100
dmgFr.Parent = fxGui

local hlFr = Instance.new("Frame")
hlFr.Size = UDim2.new(1,0,1,0) ; hlFr.BackgroundColor3 = Color3.fromRGB(0,255,80)
hlFr.BackgroundTransparency = 1 ; hlFr.BorderSizePixel = 0 ; hlFr.ZIndex = 100
hlFr.Parent = fxGui

local function flashDmg(amt)
    if not cfg.dmgVig then return end
    dmgFr.BackgroundTransparency = 1 - math.clamp(amt/40, 0.15, 0.6)
    TweenService:Create(dmgFr, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency=1}):Play()
end

local function flashHl()
    if not cfg.healFl then return end
    hlFr.BackgroundTransparency = 0.7
    TweenService:Create(hlFr, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency=1}):Play()
end

-- hitmarker lines
local hmLines = {}
for i=1,4 do local l = Drawing.new("Line") ; l.Thickness=2 ; l.Color=Color3.fromRGB(255,50,50) ; l.Visible=false ; hmLines[i]=l end

local function showHitmark()
    if not cfg.hitmark then return end
    local cx,cy = Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2
    hmLines[1].From=Vector2.new(cx-5,cy-5) ; hmLines[1].To=Vector2.new(cx-17,cy-17)
    hmLines[2].From=Vector2.new(cx+5,cy-5) ; hmLines[2].To=Vector2.new(cx+17,cy-17)
    hmLines[3].From=Vector2.new(cx-5,cy+5) ; hmLines[3].To=Vector2.new(cx-17,cy+17)
    hmLines[4].From=Vector2.new(cx+5,cy+5) ; hmLines[4].To=Vector2.new(cx+17,cy+17)
    for _,l in pairs(hmLines) do l.Visible=true end
    task.delay(0.25, function() for _,l in pairs(hmLines) do l.Visible=false end end)
end

local function dmgNum(pos, amt, heal)
    if not heal and not cfg.dmgNums then return end
    if heal and not cfg.healFl then return end
    local sp, vis = Camera:WorldToViewportPoint(pos)
    if not vis then return end
    local t = Drawing.new("Text")
    t.Text = heal and ("+"..math.floor(amt)) or ("-"..math.floor(amt))
    t.Color = heal and Color3.fromRGB(0,255,80) or Color3.fromRGB(255,50,50)
    t.Size=22 ; t.Center=true ; t.Outline=true ; t.Font=2
    t.Position = Vector2.new(sp.X + math.random(-20,20), sp.Y)
    t.Visible = true
    task.spawn(function()
        local sy = t.Position.Y
        for i=1,30 do task.wait(0.016) ; t.Position=Vector2.new(t.Position.X, sy-i*1.5) ; t.Size=math.max(22-i*0.3,12) end
        t:Remove()
    end)
end

-- hud text (created once, updated throttled)
local hudT = Drawing.new("Text")
hudT.Size=16;hudT.Font=2;hudT.Outline=true;hudT.Center=false;hudT.Color=Color3.fromRGB(200,200,200);hudT.Position=Vector2.new(12,250);hudT.Visible=false

local hudA = Drawing.new("Text")
hudA.Size=20;hudA.Font=2;hudA.Outline=true;hudA.Center=false;hudA.Position=Vector2.new(12,270);hudA.Visible=false

local hudTgt = Drawing.new("Text")
hudTgt.Size=14;hudTgt.Font=2;hudTgt.Outline=true;hudTgt.Center=false;hudTgt.Color=Color3.fromRGB(255,200,50);hudTgt.Position=Vector2.new(12,294);hudTgt.Visible=false

local hudHp = Drawing.new("Text")
hudHp.Size=14;hudHp.Font=2;hudHp.Outline=true;hudHp.Center=false;hudHp.Position=Vector2.new(12,312);hudHp.Visible=false

-- target cursor
local tC = Drawing.new("Circle")
tC.Thickness=2;tC.NumSides=40;tC.Filled=false;tC.Transparency=1;tC.Color=Color3.fromRGB(255,50,50);tC.Radius=25;tC.Visible=false

local tX = {}
for i=1,4 do local l=Drawing.new("Line");l.Thickness=1;l.Color=Color3.fromRGB(255,50,50);l.Visible=false;tX[i]=l end

local tName = Drawing.new("Text")
tName.Size=14;tName.Font=2;tName.Outline=true;tName.Center=true;tName.Color=Color3.fromRGB(255,80,80);tName.Visible=false

local tAct = Drawing.new("Text")
tAct.Size=12;tAct.Font=2;tAct.Outline=true;tAct.Center=true;tAct.Visible=false

-- silent aim fov
local fovC = Drawing.new("Circle")
fovC.Visible=false;fovC.Thickness=2;fovC.NumSides=100;fovC.Filled=false;fovC.Transparency=1;fovC.Color=Color3.fromRGB(0,255,0);fovC.Radius=300

-- pre-built strings (avoid alloc in render)
local HUD_TITLE = "void master v5"

local function aColor(a)
    if a:find("void") then return Color3.fromRGB(180,0,255)
    elseif a:find("attack") then return Color3.fromRGB(255,50,50)
    elseif a:find("orbit") then return Color3.fromRGB(0,180,255)
    elseif a:find("bring") then return Color3.fromRGB(255,150,0)
    elseif a:find("goto") then return Color3.fromRGB(255,255,0)
    elseif a:find("heal") then return Color3.fromRGB(0,255,80)
    elseif a:find("shield") then return Color3.fromRGB(100,200,255)
    elseif a:find("spin") then return Color3.fromRGB(255,100,200)
    elseif a:find("god") then return Color3.fromRGB(255,215,0)
    else return Color3.fromRGB(150,150,150) end
end

-- ============================================================
-- esp storage (created once per player)
-- ============================================================
local ESP = {
    hl = {}, box = {}, hp = {}, nm = {}, sk = {}, tr = {}
}

local function mkHL(p)
    if p==lp or not cfg.hl then return end
    if ESP.hl[p] then ESP.hl[p]:Destroy() end
    local c = p.Character ; if not c then return end
    local h = Instance.new("Highlight")
    h.FillColor=cfg.hlColor;h.OutlineColor=cfg.hlColor;h.FillTransparency=0.5;h.OutlineTransparency=0
    h.Adornee=c;h.Parent=c;ESP.hl[p]=h
end
local function rmHL(p) if ESP.hl[p] then ESP.hl[p]:Destroy() ESP.hl[p]=nil end end

local function seedPlayer(p)
    if p == lp then return end
    if not ESP.box[p] then local d=Drawing.new("Square");d.Thickness=1;d.Filled=false;d.Visible=false;d.Color=cfg.boxColor;ESP.box[p]=d end
    if not ESP.hp[p] then local d=Drawing.new("Line");d.Thickness=3;d.Visible=false;ESP.hp[p]=d end
    if not ESP.nm[p] then local d=Drawing.new("Text");d.Size=cfg.nameSize;d.Center=true;d.Outline=true;d.Font=2;d.Visible=false;d.Color=cfg.nameColor;ESP.nm[p]=d end
    if not ESP.tr[p] then local d=Drawing.new("Line");d.Thickness=1;d.Visible=false;d.Color=cfg.tracerColor;ESP.tr[p]=d end
    if not ESP.sk[p] then
        local l = {}
        for i=1,6 do local d=Drawing.new("Line");d.Thickness=1;d.Visible=false;d.Color=cfg.skelColor;l[i]=d end
        ESP.sk[p]=l
    end
    p.CharacterAdded:Connect(function() task.wait(0.2) mkHL(p) end)
end

local function cleanPlayer(p)
    rmHL(p)
    if ESP.box[p] then ESP.box[p]:Remove() ESP.box[p]=nil end
    if ESP.hp[p] then ESP.hp[p]:Remove() ESP.hp[p]=nil end
    if ESP.nm[p] then ESP.nm[p]:Remove() ESP.nm[p]=nil end
    if ESP.tr[p] then ESP.tr[p]:Remove() ESP.tr[p]=nil end
    if ESP.sk[p] then for _,l in pairs(ESP.sk[p]) do l:Remove() end ESP.sk[p]=nil end
end

for _, p in pairs(Players:GetPlayers()) do seedPlayer(p) end
Players.PlayerAdded:Connect(function(p) seedPlayer(p) ; mkHL(p) end)
Players.PlayerRemoving:Connect(cleanPlayer)

-- ============================================================
-- game hooks (silent aim, wallbang)
-- ============================================================
local function bestTarget()
    local best, dist = nil, cfg.silentFov
    local mp = UserInputService:GetMouseLocation()
    for name, p in pairs(playerCache) do
        if p.Character then
            local h = p.Character:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then
                local part = p.Character:FindFirstChild(cfg.silentPart)
                if part then
                    local sp, vis = Camera:WorldToViewportPoint(part.Position)
                    if vis then
                        local d = (Vector2.new(sp.X, sp.Y) - mp).Magnitude
                        if d < dist then dist=d ; best=part end
                    end
                end
            end
        end
    end
    return best
end

pcall(function()
    local Mods = ReplicatedStorage:WaitForChild("Modules", 5)
    if not Mods then return end
    local ok1, BH = pcall(function() return require(Mods:WaitForChild("BulletHandler")) end)
    if ok1 and BH and BH.bullet then
        local old = BH.bullet
        BH.bullet = function(self, data)
            if cfg.silent and data then
                local t = bestTarget()
                if t then
                    data.position=t.Position;data.hit=t
                    if data.origin then local d=(t.Position-data.origin).Unit;data.velocity=d*5000;data.direction=d end
                    data.normal=Vector3.new(0,1,0)
                    showHitmark()
                    task.defer(function() dmgNum(t.Position, math.random(15,35), false) end)
                end
            end
            return old(self, data)
        end
    end
    local ok2, AC = pcall(function() return require(Mods:WaitForChild("FastCastRedux"):WaitForChild("ActiveCast")) end)
    if ok2 and AC and AC.new then
        local old = AC.new
        AC.new = function(caster, origin, direction, velocity, behavior)
            behavior = behavior or {}
            behavior.CanPierceFunction = function(_, result)
                if not cfg.wallbang or not result or not result.Instance then return false end
                local m = result.Instance:FindFirstAncestorOfClass("Model")
                if m and m:FindFirstChild("Humanoid") then return false end
                if m == lp.Character then return false end
                return true
            end
            if not behavior.RaycastParams then behavior.RaycastParams = RaycastParams.new() end
            behavior.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            behavior.RaycastParams.FilterDescendantsInstances = {lp.Character}
            behavior.RaycastParams.IgnoreWater = true
            behavior.HighFidelityBehavior=1;behavior.HighFidelitySegmentSize=5
            return old(caster, origin, direction, velocity, behavior)
        end
    end
end)

-- stomp remote
local stompRem
pcall(function() local r = ReplicatedStorage:FindFirstChild("Remotes") ; if r then stompRem = r:FindFirstChild("Swing") end end)

-- ============================================================
-- survival actions (debounced)
-- ============================================================
local function doHeal()
    local r = root() ; if not r then return end
    if not healDb() then return end
    cfg.isHealing = true
    pcall(function()
        local hb ; pcall(function() hb = workspace.Map.Tower.Traps.buttons.Heal100Brick end)
        if hb then r.CFrame=hb.CFrame+Vector3.new(0,2,0) ; flashHl() ; dmgNum(r.Position,100,true)
        else r.CFrame=CFrame.new(0,50,0) end
    end)
    task.delay(1, function() cfg.isHealing=false end)
end

local function doEmergency()
    local r = root() ; if not r then return end
    if not emergDb() then return end
    local closestBenchPos = getClosestBenchPos(r.Position)
    r.CFrame = CFrame.new(closestBenchPos)+Vector3.new(0,3,0)
    flashDmg(100)
    if cfg.grabBench then
        task.delay(0.3, function()
            local r2 = root() ; if not r2 then return end
            -- Dynamically find bench to get its exact front
            local benchPart = nil
            local minDist = math.huge
            for _,obj in pairs(workspace:GetDescendants()) do
                if obj.Name==BENCH_NAME and obj:IsA("BasePart") then
                    local dist = (obj.Position - closestBenchPos).Magnitude
                    if dist < minDist and dist < 20 then
                        minDist = dist
                        benchPart = obj
                    end
                end
            end
            if benchPart then
                -- Move exactly in front of the bench facing it
                r2.CFrame = benchPart.CFrame * CFrame.new(0, 0, -3) * CFrame.Angles(0, math.pi, 0)
            else
                r2.CFrame = CFrame.new(closestBenchPos + Vector3.new(0,3,-2))
            end
            
            task.wait(0.3)
            -- Press G exactly ONCE (G is a toggle: press=grab, press again=drop)
            pcall(function() local vim=game:GetService("VirtualInputManager");vim:SendKeyEvent(true,Enum.KeyCode.G,false,game);task.wait(0.05);vim:SendKeyEvent(false,Enum.KeyCode.G,false,game) end)
            pcall(function() keypress(0x47);task.wait(0.05);keyrelease(0x47) end)
            -- Single touch interest fire as backup
            task.wait(0.1)
            pcall(function()
                local r3 = root() ; if not r3 then return end
                if benchPart and (benchPart.Position-r3.Position).Magnitude<20 then
                    firetouchinterest(r3,benchPart,0);task.wait(0.05);firetouchinterest(r3,benchPart,1)
                end
            end)
        end)
    end
end

-- ============================================================
-- health monitor
-- ============================================================
local function setupHpMon(character)
    local h = character:WaitForChild("Humanoid")
    prevHp = h.Health
    reg("hpmon", h:GetPropertyChangedSignal("Health"):Connect(function()
        local curr = h.Health ; local diff = curr - prevHp
        local pct = (curr / h.MaxHealth) * 100
        if diff < 0 then
            flashDmg(math.abs(diff))
            local r = root() ; if r then dmgNum(r.Position, math.abs(diff), false) end
            if cfg.autoHeal and pct <= cfg.healTh and not cfg.isHealing then task.spawn(doHeal) end
            if cfg.emergTp and pct <= cfg.emergTh and not cfg.isHealing then task.spawn(doEmergency) end
        elseif diff > 0 then
            flashHl() ; local r = root() ; if r then dmgNum(r.Position, diff, true) end
        end
        prevHp = curr
    end))
    h.Died:Connect(function() unreg("hpmon") end)
end
if lp.Character then pcall(function() setupHpMon(lp.Character) end) end
lp.CharacterAdded:Connect(function(c) task.wait(0.5) pcall(setupHpMon, c) end)

-- enemy hp tracking
local eHp = {}
local function trackE(p)
    if p == lp then return end
    local function oc(c)
        task.wait(0.2)
        local h = c:FindFirstChildOfClass("Humanoid") ; if not h then return end
        eHp[p.UserId] = h.Health
        local cn ; cn = h:GetPropertyChangedSignal("Health"):Connect(function()
            local prev = eHp[p.UserId] or h.MaxHealth ; local curr = h.Health
            if prev-curr > 0 then showHitmark() ; local hd=c:FindFirstChild("Head") ; if hd then dmgNum(hd.Position, prev-curr, false) end end
            if curr <= 0 and prev > 0 and cfg.killFeed then Library:Notify({Title='kill', Content=p.Name..' eliminated', Duration=3}) end
            eHp[p.UserId] = curr
        end)
        h.Died:Connect(function() if cn then cn:Disconnect() end end)
    end
    if p.Character then oc(p.Character) end
    p.CharacterAdded:Connect(oc)
end
for _,p in pairs(Players:GetPlayers()) do trackE(p) end
Players.PlayerAdded:Connect(trackE)

-- ============================================================
-- gun mod setup (per character)
-- ============================================================
local function setupGuns(character)
    local function strip(tool)
        if not tool:IsA("Tool") and not tool:IsA("Model") then return end
        for _, d in pairs(tool:GetDescendants()) do
            if cfg.noMuzzle or cfg.noShootFx then
                if d:IsA("ParticleEmitter") or d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") or d:IsA("Beam") or d:IsA("Trail") then pcall(function() d.Enabled=false end) end
            end
            if cfg.noShootFx and d:IsA("Sound") then
                local n = (d.Name or ""):lower()
                if n:find("fire") or n:find("shoot") or n:find("shot") then pcall(function() d.Volume=0 end) end
            end
        end
    end
    character.ChildAdded:Connect(function(c) task.wait(0.1) strip(c) end)
    for _,c in pairs(character:GetChildren()) do strip(c) end

    reg("gunmod", RunService.Heartbeat:Connect(function()
        if not cfg.noGunAnims and not cfg.noMuzzle and not cfg.noShootFx then return end
        if cfg.noGunAnims then
            local h = character:FindFirstChildOfClass("Humanoid") ; if not h then return end
            local a = h:FindFirstChildOfClass("Animator") ; if not a then return end
            for _, track in pairs(a:GetPlayingAnimationTracks()) do
                local n = (track.Name or ""):lower()
                if n:find("aim") or n:find("fire") or n:find("shoot") or n:find("reload") or n:find("equip") or n:find("recoil") or n:find("hold") then
                    pcall(function() track:Stop(0) end)
                end
            end
        end
        if cfg.noMuzzle or cfg.noShootFx then
            for _,c in pairs(character:GetChildren()) do strip(c) end
        end
    end))
end
if lp.Character then pcall(function() setupGuns(lp.Character) end) end
lp.CharacterAdded:Connect(function(c) task.wait(0.5) pcall(setupGuns, c) end)

-- ============================================================
-- ONE CENTRAL HEARTBEAT
-- all game logic runs here, no scattered connections
-- ============================================================
local frame = 0
local bringWait, gotoWait = 0, 0
local stompWait = 0
local lastValidPos = nil
local realCF = nil

reg("heartbeat", RunService.Heartbeat:Connect(function(dt)
    frame = frame + 1
    local r = root()

    -- refresh player cache periodically
    if frame % CACHE_INTERVAL == 0 then refreshCache() end

    if not r then return end
    
    -- === anti attach ===
    if cfg.antiAttach and myChar then
        for _, obj in pairs(myChar:GetDescendants()) do
            if obj:IsA("Weld") or obj:IsA("WeldConstraint") then
                if not obj:IsDescendantOf(myChar) or (obj.Part1 and not obj.Part1:IsDescendantOf(myChar)) then
                    pcall(function() obj:Destroy() end)
                end
            end
        end
    end
    
    -- === anti loop bring ===
    if cfg.antiBring then
        local isTeleporting = cfg.voidSpam or cfg.voidDodge or cfg.voidHead or cfg.emergTp or cfg.grabBench
        if lastValidPos and not isTeleporting and (r.Position - lastValidPos).Magnitude > 50 then
            r.CFrame = CFrame.new(lastValidPos)
            r.Anchored = true
            task.delay(0.2, function() if root() then root().Anchored = false end end)
        else
            lastValidPos = r.Position
        end
    else
        lastValidPos = nil
    end
    
    -- === velocity spoof (anti-silent aim) ===
    if cfg.velSpoof then
        pcall(function()
            r.AssemblyLinearVelocity = Vector3.new(math.huge, math.huge, math.huge)
            r.Velocity = Vector3.new(math.huge, math.huge, math.huge)
        end)
    end
    
    -- (Desync is now handled via RakNet hook)

    -- === void spammer ===
    if cfg.voidSpam then
        local depth = cfg.voidDepth
        if cfg.voidRand then depth = depth + math.random(-200, 200) end
        local run = (cfg.voidSpeed == 3) or (cfg.voidSpeed == 2 and frame % 2 == 0) or (cfg.voidSpeed == 1 and frame % 3 == 0)
        if run then
            if cfg.voidPhases == 2 then
                if frame % 2 == 0 then
                    r.CFrame = CFrame.new(r.Position.X + (cfg.voidRand and math.random(-3,3) or 0), depth, r.Position.Z + (cfg.voidRand and math.random(-3,3) or 0))
                else
                    r.CFrame = CFrame.new(r.Position.X, math.max(r.Position.Y, 5), r.Position.Z)
                end
            else
                local ph = frame % 3
                if ph == 0 then r.CFrame = CFrame.new(r.Position.X, depth, r.Position.Z)
                elseif ph == 1 then r.CFrame = CFrame.new(r.Position.X + (cfg.voidRand and math.random(-8,8) or 0), depth*1.5, r.Position.Z + (cfg.voidRand and math.random(-8,8) or 0))
                else r.CFrame = CFrame.new(r.Position.X, math.max(r.Position.Y, 5), r.Position.Z) end
            end
            pcall(function() r.Velocity=V3ZERO; r.AssemblyLinearVelocity=V3ZERO end)
        end
    end

    -- === void dodge ===
    if cfg.voidDodge and r.Position.Y < cfg.dodgeThresh then
        local ang = math.random() * math.pi * 2
        r.CFrame = CFrame.new(r.Position.X + math.cos(ang)*cfg.dodgeBoost, cfg.safeY, r.Position.Z + math.sin(ang)*cfg.dodgeBoost)
        pcall(function() r.Velocity=V3ZERO;r.AssemblyLinearVelocity=V3ZERO end)
    end

    -- === void head attack ===
    if cfg.voidHead and cfg.voidHeadTgt then
        local tp = cachedFind(cfg.voidHeadTgt)
        if tp and tp.Character then
            local th = tp.Character:FindFirstChild("Head")
            local tR = tp.Character:FindFirstChild("HumanoidRootPart")
            local tH = tp.Character:FindFirstChildOfClass("Humanoid")
            if th and tR and tH and tH.Health > 0 then
                local vel = V3ZERO
                pcall(function() vel = tR.AssemblyLinearVelocity or tR.Velocity or V3ZERO end)
                local pred = th.Position + vel * 0.05
                local depth = cfg.voidDepth
                local ag = cfg.voidHeadAggro

                if ag == 1 then
                    local ph = frame % 3
                    if ph==0 then r.CFrame=CFrame.new(pred+Vector3.new(math.random(-1,1)*0.3,0.5,math.random(-1,1)*0.3))
                    elseif ph==1 then r.CFrame=CFrame.new(pred.X+math.random(-5,5),pred.Y+depth,pred.Z+math.random(-5,5))
                    else r.CFrame=CFrame.new(pred+Vector3.new(0,0.5,0)) end
                elseif ag == 2 then
                    if frame%2==0 then r.CFrame=CFrame.new(pred+Vector3.new(0,0.3,0))
                    else r.CFrame=CFrame.new(pred.X,pred.Y+depth,pred.Z) end
                else
                    if frame%2==0 then r.CFrame=CFrame.new(pred)
                    else r.CFrame=CFrame.new(pred.X,pred.Y+depth*2,pred.Z) end
                end
                pcall(function() r.Velocity=V3ZERO; r.AssemblyLinearVelocity=V3ZERO end)
            end
        end
    end

    -- === godmode ===
    if cfg.godmode then
        local h = hum()
        if h then pcall(function() if h.Health < h.MaxHealth then h.Health = h.MaxHealth end end) end
        if myChar then
            pcall(function()
                myChar:SetAttribute("Hurt",false)
                myChar:SetAttribute("Stunned",false)
                myChar:SetAttribute("Ragdoll",false)
                myChar:SetAttribute("Endlag",false)
            end)
            -- actively destroy hitboxes if they try to touch
            for _, desc in pairs(myChar:GetDescendants()) do
                if desc:IsA("BasePart") then
                    desc.LocalTransparencyModifier = 0
                end
            end
            
            -- add invisible forcefield to bypass most kill scripts
            if not myChar:FindFirstChildOfClass("ForceField") then
                local ff = Instance.new("ForceField")
                ff.Visible = false
                ff.Parent = myChar
            end
        end
        pcall(function() r.Velocity=Vector3.new(r.Velocity.X, math.max(r.Velocity.Y,-50), r.Velocity.Z) end)
    else
        if myChar then
            local ff = myChar:FindFirstChildOfClass("ForceField")
            if ff then ff:Destroy() end
        end
    end

    -- === anti void ===
    if cfg.antiVoid and r.Position.Y < cfg.antiVoidY then
        r.CFrame = CFrame.new(r.Position.X, cfg.safeY, r.Position.Z)
        pcall(function() r.Velocity=V3ZERO;r.AssemblyLinearVelocity=V3ZERO end)
    end

    -- === orbit ===
    if cfg.orbit and cfg.selected then
        local tp = cachedFind(cfg.selected)
        if tp and tp.Character then
            local tHRP = tp.Character:FindFirstChild("HumanoidRootPart")
            if tHRP then
                local dir = cfg.oRev and -1 or 1
                cfg.oAng = cfg.oAng + (cfg.oSpd * dt * dir)
                local bobY = cfg.oBob and math.sin(cfg.oAng*1.5)*cfg.oBobAmt or 0
                local tPos = tHRP.Position
                local np = Vector3.new(tPos.X+math.cos(cfg.oAng)*cfg.oRad, tPos.Y+cfg.oH+bobY, tPos.Z+math.sin(cfg.oAng)*cfg.oRad)
                
                -- Use AlignPosition and AlignOrientation for butter-smooth orbit
                local ap = r:FindFirstChild("OrbitAlignPosition")
                local ao = r:FindFirstChild("OrbitAlignOrientation")
                local att1 = r:FindFirstChild("OrbitAttachment")
                if not att1 then
                    att1 = Instance.new("Attachment", r)
                    att1.Name = "OrbitAttachment"
                end
                
                if not ap then
                    ap = Instance.new("AlignPosition", r)
                    ap.Name = "OrbitAlignPosition"
                    ap.Mode = Enum.PositionAlignmentMode.OneAttachment
                    ap.Attachment0 = att1
                    ap.Responsiveness = 200
                    ap.MaxForce = math.huge
                end
                if not ao then
                    ao = Instance.new("AlignOrientation", r)
                    ao.Name = "OrbitAlignOrientation"
                    ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
                    ao.Attachment0 = att1
                    ao.Responsiveness = 200
                    ao.MaxTorque = math.huge
                end
                
                ap.Position = np
                if cfg.oFace then
                    ao.CFrame = CFrame.lookAt(np, tPos)
                else
                    local tan=Vector3.new(-math.sin(cfg.oAng),0,math.cos(cfg.oAng))*dir
                    ao.CFrame = CFrame.lookAt(np,np+tan)
                end
            end
        end
    else
        -- Clean up align constraints if orbit is off
        if r then
            local ap = r:FindFirstChild("OrbitAlignPosition")
            local ao = r:FindFirstChild("OrbitAlignOrientation")
            local att1 = r:FindFirstChild("OrbitAttachment")
            if ap then ap:Destroy() end
            if ao then ao:Destroy() end
            if att1 then att1:Destroy() end
        end
    end

    -- === loop bring ===
    if cfg.bring and cfg.selected then
        bringWait = bringWait + dt
        if bringWait >= cfg.bDelay then
            bringWait = 0
            local tp = cachedFind(cfg.selected)
            if tp and tp.Character then
                local tHRP = tp.Character:FindFirstChild("HumanoidRootPart")
                if tHRP then
                    local myCF = r.CFrame
                    local fb = cfg.bFront and cfg.bDist or -cfg.bDist
                    local off = myCF.LookVector*fb + myCF.RightVector*cfg.bSide + Vector3.new(0,cfg.bH,0)
                    tHRP.CFrame = CFrame.new(r.Position + off)
                    pcall(function() tHRP.Velocity=V3ZERO;tHRP.AssemblyLinearVelocity=V3ZERO end)
                end
            end
        end
    end

    -- === loop goto ===
    if cfg.goTo and cfg.selected then
        gotoWait = gotoWait + dt
        if gotoWait >= cfg.gDelay then
            gotoWait = 0
            local tp = cachedFind(cfg.selected)
            if tp and tp.Character then
                local tHRP = tp.Character:FindFirstChild("HumanoidRootPart")
                if tHRP then
                    local off = tHRP.CFrame.LookVector * -cfg.gDist
                    r.CFrame = CFrame.new(tHRP.Position + off)
                end
            end
        end
    end

    -- === spin ===
    if cfg.spin then
        cfg.spinAng = cfg.spinAng + (math.rad(cfg.spinSpd) * (dt * 60))
        r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, cfg.spinAng, 0)
    end

    -- === anti debuffs (only when not in godmode, godmode handles these already) ===
    if not cfg.godmode and myChar then
        if cfg.noEndlag then myChar:SetAttribute("Endlag", false) end
        if cfg.noStun then myChar:SetAttribute("Stunned", false) end
        if cfg.noStompCd then myChar:SetAttribute("StompCooldown", false) end
        if cfg.noHurt then myChar:SetAttribute("Hurt", false) end
        if cfg.noRagdoll then myChar:SetAttribute("Ragdoll", false) end
        if cfg.autoSprint then myChar:SetAttribute("Sprinting", true) end
    end

    -- === stomp (throttled to every 2 frames) ===
    if cfg.stomp and stompRem and frame % 2 == 0 then
        for _, p in pairs(Players:GetPlayers()) do
            if cfg.stompTgts[p.UserId] and p.Character then
                local head = p.Character:FindFirstChild("Head")
                local h = p.Character:FindFirstChildOfClass("Humanoid")
                if head and h and h.Health>0 and head:IsDescendantOf(workspace) then
                    pcall(function()
                        stompRem:FireServer("Stomp Air","Stomp Air Start")
                        stompRem:FireServer("Stomp Air","Stomp Air Hit",head)
                        stompRem:FireServer("Stomp Air","Stomp Air End")
                    end)
                end
            end
        end
    end

    -- === silent aim fov circle ===
    if cfg.showFov then
        fovC.Position = UserInputService:GetMouseLocation()
        fovC.Radius = cfg.silentFov
        fovC.Visible = true
    else
        fovC.Visible = false
    end
end))

-- ============================================================
-- ONE CENTRAL RENDER LOOP
-- all drawing/esp updates here
-- ============================================================
local hudFrame = 0

reg("render", RunService.RenderStepped:Connect(function()
    hudFrame = hudFrame + 1
    local r = root()
    
    -- (Desync is now handled via RakNet hook)

    -- === determine action (cheap, no alloc) ===
    if cfg.isHealing then cfg.action = "healing..."
    elseif cfg.voidHead and cfg.voidHeadTgt then cfg.action = "void head attack"
    elseif cfg.voidSpam then cfg.action = "void spamming..."
    elseif cfg.voidDodge then cfg.action = "void dodging..."
    elseif cfg.bring and cfg.selected then cfg.action = "bringing target..."
    elseif cfg.orbit and cfg.selected then cfg.action = "orbiting target"
    elseif cfg.goTo and cfg.selected then cfg.action = "going to target"
    elseif cfg.spin then cfg.action = "spinning"
    elseif cfg.grabBench then cfg.action = "shield active"
    elseif cfg.godmode then cfg.action = "godmode"
    else cfg.action = "idle" end

    -- === hud (throttled: text updates every 8 frames) ===
    if cfg.statusHud then
        if hudFrame % 8 == 0 then
            hudT.Text = HUD_TITLE
            hudA.Text = cfg.action ; hudA.Color = aColor(cfg.action)
            hudTgt.Text = "target: " .. (cfg.selected or "none")
            local h = hum()
            if h then
                local pct = math.floor((h.Health/h.MaxHealth)*100)
                hudHp.Text = "hp: "..math.floor(h.Health).."/"..math.floor(h.MaxHealth).." ("..pct.."%)"
                hudHp.Color = pct>60 and Color3.fromRGB(0,255,80) or pct>30 and Color3.fromRGB(255,200,0) or Color3.fromRGB(255,50,50)
                hudHp.Visible = true
            else hudHp.Visible = false end
        end
        hudT.Visible=true ; hudA.Visible=true ; hudTgt.Visible=true
    else
        hudT.Visible=false;hudA.Visible=false;hudTgt.Visible=false;hudHp.Visible=false
    end

    -- === target cursor ===
    if cfg.tgtCursor and cfg.selected then
        local tp = cachedFind(cfg.selected)
        if tp and tp.Character then
            local tR = tp.Character:FindFirstChild("HumanoidRootPart")
            if tR then
                local sp,vis = Camera:WorldToViewportPoint(tR.Position)
                if vis then
                    local sx,sy = sp.X, sp.Y
                    tC.Position=Vector2.new(sx,sy);tC.Visible=true
                    local cs=18
                    tX[1].From=Vector2.new(sx,sy-cs);tX[1].To=Vector2.new(sx,sy-cs/3)
                    tX[2].From=Vector2.new(sx,sy+cs/3);tX[2].To=Vector2.new(sx,sy+cs)
                    tX[3].From=Vector2.new(sx-cs,sy);tX[3].To=Vector2.new(sx-cs/3,sy)
                    tX[4].From=Vector2.new(sx+cs/3,sy);tX[4].To=Vector2.new(sx+cs,sy)
                    for _,l in pairs(tX) do l.Visible=true end
                    tName.Position=Vector2.new(sx,sy-35);tName.Text=cfg.selected;tName.Visible=true
                    tAct.Position=Vector2.new(sx,sy+32);tAct.Text=cfg.action;tAct.Color=aColor(cfg.action);tAct.Visible=true
                else tC.Visible=false;for _,l in pairs(tX) do l.Visible=false end;tName.Visible=false;tAct.Visible=false end
            else tC.Visible=false;for _,l in pairs(tX) do l.Visible=false end;tName.Visible=false;tAct.Visible=false end
        else tC.Visible=false;for _,l in pairs(tX) do l.Visible=false end;tName.Visible=false;tAct.Visible=false end
    else tC.Visible=false;for _,l in pairs(tX) do l.Visible=false end;tName.Visible=false;tAct.Visible=false end

    -- === esp: boxes ===
    for p,b in pairs(ESP.box) do
        if not cfg.box then b.Visible=false ; continue end
        local c = p.Character ; if not c then b.Visible=false ; continue end
        local hd=c:FindFirstChild("Head");local rt=c:FindFirstChild("HumanoidRootPart")
        if not hd or not rt then b.Visible=false ; continue end
        local hp,v1=Camera:WorldToViewportPoint(hd.Position+Vector3.new(0,.4,0))
        local rp,v2=Camera:WorldToViewportPoint(rt.Position-Vector3.new(0,3,0))
        if v1 and v2 then local h=math.abs(hp.Y-rp.Y);local w=h/1.5;b.Size=Vector2.new(w,h);b.Position=Vector2.new(rp.X-w/2,hp.Y);b.Color=cfg.boxColor;b.Visible=true
        else b.Visible=false end
    end

    -- === esp: health bars ===
    for p,bar in pairs(ESP.hp) do
        if not cfg.hpBar then bar.Visible=false ; continue end
        local c = p.Character ; if not c then bar.Visible=false ; continue end
        local hd=c:FindFirstChild("Head");local rt=c:FindFirstChild("HumanoidRootPart");local hm=c:FindFirstChildOfClass("Humanoid")
        if not hd or not rt or not hm then bar.Visible=false ; continue end
        local hp,v1=Camera:WorldToViewportPoint(hd.Position+Vector3.new(0,.4,0))
        local rp,v2=Camera:WorldToViewportPoint(rt.Position-Vector3.new(0,3,0))
        if v1 and v2 then
            local h=math.abs(hp.Y-rp.Y);local x=rp.X-(h/1.5)/2-6;local pct=math.clamp(hm.Health/hm.MaxHealth,0,1)
            bar.From=Vector2.new(x,rp.Y);bar.To=Vector2.new(x,rp.Y-h*pct);bar.Color=cfg.hpLow:Lerp(cfg.hpHigh,pct);bar.Visible=true
        else bar.Visible=false end
    end

    -- === esp: names ===
    for p,t in pairs(ESP.nm) do
        if not cfg.names then t.Visible=false ; continue end
        local c = p.Character ; if not c then t.Visible=false ; continue end
        local hd=c:FindFirstChild("Head");if not hd then t.Visible=false;continue end
        local pos,vis=Camera:WorldToViewportPoint(hd.Position+Vector3.new(0,1.5,0))
        if vis then t.Position=Vector2.new(pos.X,pos.Y);t.Text=p.Name;t.Color=cfg.nameColor;t.Size=cfg.nameSize;t.Visible=true
        else t.Visible=false end
    end

    -- === esp: skeletons ===
    for p,lines in pairs(ESP.sk) do
        local function hide() for _,l in pairs(lines) do l.Visible=false end end
        if not cfg.skel then hide();continue end
        local c = p.Character ; if not c then hide();continue end
        local hd=c:FindFirstChild("Head");local rt=c:FindFirstChild("HumanoidRootPart")
        local to=c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
        if not hd or not rt or not to then hide();continue end
        local la=c:FindFirstChild("LeftUpperArm") or c:FindFirstChild("Left Arm")
        local ra=c:FindFirstChild("RightUpperArm") or c:FindFirstChild("Right Arm")
        local ll=c:FindFirstChild("LeftUpperLeg") or c:FindFirstChild("Left Leg")
        local rl=c:FindFirstChild("RightUpperLeg") or c:FindFirstChild("Right Leg")
        local h,v1=Camera:WorldToViewportPoint(hd.Position);local t2,v2=Camera:WorldToViewportPoint(to.Position);local rv,v3=Camera:WorldToViewportPoint(rt.Position)
        local hs,ts2,rs = Vector2.new(h.X,h.Y),Vector2.new(t2.X,t2.Y),Vector2.new(rv.X,rv.Y)
        if v1 and v2 and v3 then
            lines[1].From=hs;lines[1].To=ts2;lines[1].Visible=true;lines[2].From=ts2;lines[2].To=rs;lines[2].Visible=true
            local ld={{la,ts2},{ra,ts2},{ll,rs},{rl,rs}}
            for i,d in ipairs(ld) do
                if d[1] then local pp,vis=Camera:WorldToViewportPoint(d[1].Position);lines[i+2].From=d[2];lines[i+2].To=Vector2.new(pp.X,pp.Y);lines[i+2].Visible=vis
                else lines[i+2].Visible=false end
            end
            for _,l in pairs(lines) do l.Color=cfg.skelColor end
        else hide() end
    end

    -- === esp: tracers ===
    for p,line in pairs(ESP.tr) do
        if not cfg.tracer then line.Visible=false;continue end
        local c = p.Character;if not c then line.Visible=false;continue end
        local rt=c:FindFirstChild("HumanoidRootPart");if not rt then line.Visible=false;continue end
        local hm=c:FindFirstChildOfClass("Humanoid");if not hm or hm.Health<=0 then line.Visible=false;continue end
        local pos,vis=Camera:WorldToViewportPoint(rt.Position)
        if vis then
            local vp=Camera.ViewportSize
            if cfg.tracerOrigin=="Bottom" then line.From=Vector2.new(vp.X/2,vp.Y)
            elseif cfg.tracerOrigin=="Center" then line.From=Vector2.new(vp.X/2,vp.Y/2)
            else line.From=UserInputService:GetMouseLocation() end
            line.To=Vector2.new(pos.X,pos.Y);line.Color=cfg.tracerColor;line.Visible=true
        else line.Visible=false end
    end
end))

-- ============================================================
-- gui
-- ============================================================
local W = Library:CreateWindow({
    Title = 'void master v5 | the anti-rager update',
    Center = true, AutoShow = true, TabPadding = 8, MenuFadeTime = 0.2,
})

local T = {
    void     = W:AddTab('void'),
    combat   = W:AddTab('combat'),
    player   = W:AddTab('player'),
    esp      = W:AddTab('esp'),
    visuals  = W:AddTab('visuals'),
    survival = W:AddTab('survival'),
    misc     = W:AddTab('misc'),
    anti_rager = W:AddTab('anti-rager'),
    settings = W:AddTab('settings'),
}

-- void tab
local vL=T.void:AddLeftGroupbox('void spammer')
local vR=T.void:AddRightGroupbox('void dodge')
local vB=T.void:AddLeftGroupbox('void head attack')
local vB2=T.void:AddRightGroupbox('manual')

vL:AddToggle('t_vs',{Text='void spammer',Default=false,Callback=function(v) cfg.voidSpam=v end})
vL:AddSlider('s_vd',{Text='depth',Default=600,Min=100,Max=5000,Rounding=0,Callback=function(v) cfg.voidDepth=-v end})
vL:AddDropdown('d_vsp',{Text='speed',Values={'normal','fast','ultra'},Default='normal',Callback=function(v) cfg.voidSpeed=v=='ultra' and 3 or v=='fast' and 2 or 1 end})
vL:AddDropdown('d_vph',{Text='phases',Values={'2 phase','3 phase'},Default='2 phase',Callback=function(v) cfg.voidPhases=v=='3 phase' and 3 or 2 end})
vL:AddToggle('t_vr',{Text='randomize',Default=false,Callback=function(v) cfg.voidRand=v end})

vR:AddToggle('t_vdg',{Text='void dodge',Default=false,Callback=function(v) cfg.voidDodge=v end})
vR:AddSlider('s_dy',{Text='trigger y',Default=50,Min=10,Max=500,Rounding=0,Callback=function(v) cfg.dodgeThresh=-v end})
vR:AddSlider('s_dd',{Text='dodge distance',Default=2000,Min=500,Max=10000,Rounding=0,Callback=function(v) cfg.dodgeBoost=v end})
vR:AddSlider('s_sy',{Text='safe height',Default=50,Min=5,Max=200,Rounding=0,Callback=function(v) cfg.safeY=v end})

vB:AddLabel('locks onto target head')
local vhDrop=vB:AddDropdown('d_vht',{Text='target',Values=cachedList(),AllowNull=true,Callback=function(v) cfg.voidHeadTgt=(v and v~="none") and v or nil end})
vB:AddToggle('t_vh',{Text='void head attack',Default=false,Callback=function(v) cfg.voidHead=v end})
vB:AddDropdown('d_vha',{Text='aggression',Values={'normal','aggressive','ultra'},Default='normal',Callback=function(v) cfg.voidHeadAggro=v=='ultra' and 3 or v=='aggressive' and 2 or 1 end})
vB:AddButton({Text='refresh',Func=function() vhDrop:SetValues(cachedList()) end})

vB2:AddButton({Text='plunge (ultra)',Func=function() local r=root();if r then r.CFrame=CFrame.new(r.Position.X,-99999,r.Position.Z) end end})
vB2:AddButton({Text='escape void',Func=function() local r=root();if r then r.CFrame=CFrame.new(r.Position.X,50,r.Position.Z) end end})
vB2:AddButton({Text='mega burst (5s)',Func=function()
    task.spawn(function() local t0=tick();while(tick()-t0)<5 do local r=root();if r then r.CFrame=CFrame.new(r.Position.X,-math.random(10000,50000),r.Position.Z);task.wait(0.01);r.CFrame=CFrame.new(r.Position.X,50,r.Position.Z);task.wait(0.01) end end end) end})

-- combat tab
local cL=T.combat:AddLeftGroupbox('silent aim')
local cR=T.combat:AddRightGroupbox('wallbang / stomp')
local cB=T.combat:AddLeftGroupbox('gun mods')

cL:AddToggle('t_si',{Text='silent aim',Default=false,Callback=function(v) cfg.silent=v end})
cL:AddToggle('t_sifov',{Text='show fov',Default=false,Callback=function(v) cfg.showFov=v end})
cL:AddSlider('s_fov',{Text='fov radius',Default=300,Min=50,Max=750,Rounding=0,Callback=function(v) cfg.silentFov=v end})
cL:AddDropdown('d_hp',{Text='hit part',Values={'Head','HumanoidRootPart','UpperTorso'},Default='Head',Callback=function(v) cfg.silentPart=v end})

cR:AddToggle('t_wb',{Text='wallbang',Default=false,Callback=function(v) cfg.wallbang=v end})
cR:AddDivider()
cR:AddToggle('t_st',{Text='stomp loop',Default=false,Callback=function(v) cfg.stomp=v end})
local stDrop=cR:AddDropdown('d_stt',{Text='stomp target',Values=cachedList(),AllowNull=true,
    Callback=function(v) cfg.stompTgts={};if v and v~="none" then local ns=type(v)=="table" and v or{v};for _,n in pairs(ns) do local p=Players:FindFirstChild(n);if p then cfg.stompTgts[p.UserId]=true end end end end})
cR:AddButton({Text='refresh',Func=function() stDrop:SetValues(cachedList()) end})

cB:AddToggle('t_na',{Text='no gun animations',Default=false,Callback=function(v) cfg.noGunAnims=v end})
cB:AddToggle('t_nm',{Text='no muzzle flash',Default=false,Callback=function(v) cfg.noMuzzle=v end})
cB:AddToggle('t_nf',{Text='no shoot effects',Default=false,Callback=function(v) cfg.noShootFx=v end})
cB:AddLabel('deagle, ak47, spas 12, p250, remington')

-- player tab
local pL=T.player:AddLeftGroupbox('target')
local pR=T.player:AddRightGroupbox('orbit')
local pBL=T.player:AddLeftGroupbox('loop bring')
local pBR=T.player:AddRightGroupbox('loop goto / actions')
local pS=T.player:AddLeftGroupbox('movement')

local plDrop=pL:AddDropdown('d_pl',{Text='select player',Values=cachedList(),AllowNull=true,
    Callback=function(v) cfg.selected=(v and v~='none') and v or nil end})
pL:AddButton({Text='refresh all lists',Func=function() local l=cachedList();plDrop:SetValues(l);vhDrop:SetValues(l);stDrop:SetValues(l) end})
pL:AddLabel('auto-refreshes every 5s')
task.spawn(function() while task.wait(5) do pcall(function() local l=cachedList();plDrop:SetValues(l);vhDrop:SetValues(l);stDrop:SetValues(l) end) end end)

pR:AddToggle('t_orb',{Text='orbit',Default=false,Callback=function(v) cfg.orbit=v;cfg.oAng=0 end})
pR:AddSlider('s_or',{Text='radius',Default=10,Min=2,Max=100,Rounding=1,Callback=function(v) cfg.oRad=v end})
pR:AddSlider('s_os',{Text='speed',Default=2,Min=1,Max=20,Rounding=1,Callback=function(v) cfg.oSpd=v end})
pR:AddSlider('s_oh',{Text='height',Default=0,Min=-20,Max=50,Rounding=1,Callback=function(v) cfg.oH=v end})
pR:AddToggle('t_ob',{Text='height bob',Default=false,Callback=function(v) cfg.oBob=v end})
pR:AddSlider('s_oba',{Text='bob amount',Default=3,Min=1,Max=15,Rounding=1,Callback=function(v) cfg.oBobAmt=v end})
pR:AddToggle('t_ore',{Text='reverse',Default=false,Callback=function(v) cfg.oRev=v end})
pR:AddToggle('t_of',{Text='face target',Default=true,Callback=function(v) cfg.oFace=v end})

pBL:AddToggle('t_br',{Text='loop bring',Default=false,Callback=function(v) cfg.bring=v;bringWait=0 end})
pBL:AddSlider('s_bd',{Text='distance',Default=5,Min=1,Max=30,Rounding=1,Callback=function(v) cfg.bDist=v end})
pBL:AddSlider('s_bs',{Text='side offset',Default=0,Min=-15,Max=15,Rounding=1,Callback=function(v) cfg.bSide=v end})
pBL:AddSlider('s_bh',{Text='height offset',Default=0,Min=-10,Max=20,Rounding=1,Callback=function(v) cfg.bH=v end})
pBL:AddSlider('s_bdl',{Text='delay (sec)',Default=0,Min=0,Max=1,Rounding=2,Callback=function(v) cfg.bDelay=v end})
pBL:AddToggle('t_bf',{Text='in front',Default=true,Callback=function(v) cfg.bFront=v end})

pBR:AddToggle('t_gt',{Text='loop goto',Default=false,Callback=function(v) cfg.goTo=v;gotoWait=0 end})
pBR:AddSlider('s_gd',{Text='distance',Default=3,Min=1,Max=20,Rounding=1,Callback=function(v) cfg.gDist=v end})
pBR:AddSlider('s_gdl',{Text='delay (sec)',Default=0,Min=0,Max=1,Rounding=2,Callback=function(v) cfg.gDelay=v end})
pBR:AddDivider()
pBR:AddButton({Text='tp to target',Func=function() local r=root();local t=tgtRoot(cfg.selected);if r and t then r.CFrame=t.CFrame+Vector3.new(3,0,0) end end})
pBR:AddButton({Text='bring target',Func=function() local r=root();local t=tgtRoot(cfg.selected);if r and t then t.CFrame=r.CFrame+Vector3.new(3,0,0) end end})

pS:AddToggle('t_sp',{Text='spin',Default=false,Callback=function(v) cfg.spin=v end})
pS:AddSlider('s_ss',{Text='speed',Default=15,Min=1,Max=200,Rounding=0,Callback=function(v) cfg.spinSpd=v end})

-- esp tab
local eL=T.esp:AddLeftGroupbox('highlight / names')
local eR=T.esp:AddRightGroupbox('boxes / bars')
local eB=T.esp:AddLeftGroupbox('skeleton / tracers')

local hlT=eL:AddToggle('t_hl',{Text='highlight',Default=false,Callback=function(v) cfg.hl=v;for _,p in pairs(Players:GetPlayers()) do if v then mkHL(p) else rmHL(p) end end end})
hlT:AddColorPicker('cp_hl',{Title='color',Default=cfg.hlColor,Callback=function(c) cfg.hlColor=c;for _,h in pairs(ESP.hl) do h.FillColor=c;h.OutlineColor=c end end})
eL:AddDivider()
local nmT=eL:AddToggle('t_nm2',{Text='names',Default=false,Callback=function(v) cfg.names=v end})
nmT:AddColorPicker('cp_nm',{Title='color',Default=cfg.nameColor,Callback=function(c) cfg.nameColor=c end})
eL:AddSlider('s_ns',{Text='size',Default=13,Min=10,Max=30,Rounding=0,Callback=function(v) cfg.nameSize=v end})

local bxT=eR:AddToggle('t_bx',{Text='boxes',Default=false,Callback=function(v) cfg.box=v end})
bxT:AddColorPicker('cp_bx',{Title='color',Default=cfg.boxColor,Callback=function(c) cfg.boxColor=c end})
eR:AddDivider()
local hbT=eR:AddToggle('t_hb',{Text='health bars',Default=false,Callback=function(v) cfg.hpBar=v end})
hbT:AddColorPicker('cp_hh',{Title='high',Default=cfg.hpHigh,Callback=function(c) cfg.hpHigh=c end})
hbT:AddColorPicker('cp_hl2',{Title='low',Default=cfg.hpLow,Callback=function(c) cfg.hpLow=c end})

local skT=eB:AddToggle('t_sk',{Text='skeleton',Default=false,Callback=function(v) cfg.skel=v end})
skT:AddColorPicker('cp_sk',{Title='color',Default=cfg.skelColor,Callback=function(c) cfg.skelColor=c end})
eB:AddDivider()
local trT=eB:AddToggle('t_tr',{Text='tracers',Default=false,Callback=function(v) cfg.tracer=v end})
trT:AddColorPicker('cp_tr',{Title='color',Default=cfg.tracerColor,Callback=function(c) cfg.tracerColor=c end})
eB:AddDropdown('d_to',{Text='origin',Values={'Bottom','Center','Mouse'},Default='Bottom',Callback=function(v) cfg.tracerOrigin=v end})

-- visuals tab
local vfL=T.visuals:AddLeftGroupbox('combat')
local vfR=T.visuals:AddRightGroupbox('screen')
local vfB=T.visuals:AddLeftGroupbox('hud')

vfL:AddToggle('t_hm',{Text='hitmarkers',Default=false,Callback=function(v) cfg.hitmark=v end})
vfL:AddDivider()
vfL:AddToggle('t_dn',{Text='damage numbers',Default=false,Callback=function(v) cfg.dmgNums=v end})
vfL:AddDivider()
vfL:AddToggle('t_kf',{Text='kill feed',Default=false,Callback=function(v) cfg.killFeed=v end})

vfR:AddToggle('t_dv',{Text='damage vignette',Default=false,Callback=function(v) cfg.dmgVig=v end})
vfR:AddDivider()
vfR:AddToggle('t_hfl',{Text='heal flash',Default=false,Callback=function(v) cfg.healFl=v end})
vfR:AddDivider()
vfR:AddButton({Text='test damage',Func=function() flashDmg(50);local r=root();if r then dmgNum(r.Position,25,false) end end})
vfR:AddButton({Text='test heal',Func=function() flashHl();local r=root();if r then dmgNum(r.Position,50,true) end end})
vfR:AddButton({Text='test hitmarker',Func=function() showHitmark() end})

vfB:AddToggle('t_hud',{Text='status hud',Default=true,Callback=function(v) cfg.statusHud=v end})
vfB:AddDivider()
vfB:AddToggle('t_tc',{Text='target cursor',Default=false,Callback=function(v) cfg.tgtCursor=v end})

-- survival tab
local sL=T.survival:AddLeftGroupbox('auto heal')
local sR=T.survival:AddRightGroupbox('emergency / shield')
local sB=T.survival:AddLeftGroupbox('anti death')

sL:AddToggle('t_ah',{Text='auto heal tp',Default=false,Callback=function(v) cfg.autoHeal=v end})
sL:AddSlider('s_ht',{Text='heal below %',Default=60,Min=10,Max=90,Rounding=0,Callback=function(v) cfg.healTh=v end})
sL:AddSlider('s_hc',{Text='cooldown',Default=3,Min=1,Max=15,Rounding=1,Callback=function(v) cfg.healCd=v;healDb=debounce(v) end})
sL:AddDivider()
sL:AddButton({Text='heal now',Func=doHeal})

sR:AddToggle('t_et',{Text='emergency tp',Default=false,Callback=function(v) cfg.emergTp=v end})
sR:AddSlider('s_et',{Text='below %',Default=25,Min=5,Max=50,Rounding=0,Callback=function(v) cfg.emergTh=v end})
sR:AddSlider('s_ec',{Text='cooldown',Default=5,Min=2,Max=30,Rounding=1,Callback=function(v) cfg.emergCd=v;emergDb=debounce(v) end})
sR:AddDivider()
sR:AddToggle('t_gb',{Text='auto grab bench',Default=false,Callback=function(v) cfg.grabBench=v end})
sR:AddLabel('tps to bench and presses g')
sR:AddDivider()
sR:AddButton({Text='emergency tp now',Func=doEmergency})
sR:AddButton({Text='grab bench now',Func=function()
    local r=root();if not r then return end
    local closestBenchPos = getClosestBenchPos(r.Position)
    local benchPart = nil
    local minDist = math.huge
    for _,obj in pairs(workspace:GetDescendants()) do
        if obj.Name==BENCH_NAME and obj:IsA("BasePart") then
            local dist = (obj.Position - closestBenchPos).Magnitude
            if dist < minDist and dist < 20 then
                minDist = dist
                benchPart = obj
            end
        end
    end
    if benchPart then
        r.CFrame = benchPart.CFrame * CFrame.new(0, 0, -3) * CFrame.Angles(0, math.pi, 0)
    else
        r.CFrame=CFrame.new(closestBenchPos+Vector3.new(0,3,-2))
    end
    task.wait(0.3)
    -- Press G exactly ONCE
    pcall(function() local vim=game:GetService("VirtualInputManager");vim:SendKeyEvent(true,Enum.KeyCode.G,false,game);task.wait(0.05);vim:SendKeyEvent(false,Enum.KeyCode.G,false,game) end)
    pcall(function() keypress(0x47);task.wait(0.05);keyrelease(0x47) end)
    task.wait(0.1)
    pcall(function()
        local r3 = root() ; if not r3 then return end
        if benchPart and (benchPart.Position-r3.Position).Magnitude<20 then
            firetouchinterest(r3,benchPart,0);task.wait(0.05);firetouchinterest(r3,benchPart,1)
        end
    end)
end})

sB:AddToggle('t_god',{Text='godmode',Default=false,Callback=function(v) cfg.godmode=v end})
sB:AddLabel('forces max hp every frame')
sB:AddDivider()
sB:AddToggle('t_av',{Text='anti void',Default=false,Callback=function(v) cfg.antiVoid=v end})
sB:AddSlider('s_avy',{Text='void threshold',Default=100,Min=20,Max=500,Rounding=0,Callback=function(v) cfg.antiVoidY=-v end})
sB:AddLabel('snaps back if you fall too low')

-- misc tab
local mL=T.misc:AddLeftGroupbox('anti debuffs')
local mR=T.misc:AddRightGroupbox('teleports')

mL:AddToggle('t_ne',{Text='no endlag',Default=false,Callback=function(v) cfg.noEndlag=v end})
mL:AddToggle('t_ns',{Text='no stun',Default=false,Callback=function(v) cfg.noStun=v end})
mL:AddToggle('t_nsc',{Text='no stomp cd',Default=false,Callback=function(v) cfg.noStompCd=v end})
mL:AddToggle('t_nh',{Text='no hurt',Default=false,Callback=function(v) cfg.noHurt=v end})
mL:AddToggle('t_nrg',{Text='no ragdoll',Default=false,Callback=function(v) cfg.noRagdoll=v end})
mL:AddToggle('t_as',{Text='auto sprint',Default=false,Callback=function(v) cfg.autoSprint=v end})
mL:AddLabel('drop kick breaks with auto sprint')

mR:AddButton({Text='tp to secret',Func=function() local r=root();if r then r.CFrame=CFrame.new(645,2366,328) end end})
mR:AddButton({Text='tp to heal',Func=function() pcall(function() local r=root();if r then r.CFrame=workspace.Map.Tower.Traps.buttons.Heal100Brick.CFrame end end) end})
mR:AddButton({Text='tp to spawn',Func=function() local r=root();if r then r.CFrame=CFrame.new(0,5,0) end end})
mR:AddButton({Text='tp to safe zone',Func=function() local r=root();if r then r.CFrame=CFrame.new(SAFE_POS) end end})

-- anti-rager tab
local arL = T.anti_rager:AddLeftGroupbox('defense')
local arR = T.anti_rager:AddRightGroupbox('info')
arL:AddToggle('t_desync',{Text='network desync (raknet)',Default=false,Callback=function(v) 
    cfg.desync=v 
    toggleRakNetDesync(v)
    if v then
        Library:Notify({Title='desync', Content='raknet hook active - ghost spawned', Duration=3})
    else
        Library:Notify({Title='desync', Content='raknet hook removed', Duration=2})
    end
end})
arL:AddLabel('freezes your server hitbox, enemies miss')
arL:AddDivider()
arL:AddToggle('t_velspoof',{Text='velocity spoof (anti-silent aim)',Default=false,Callback=function(v) cfg.velSpoof=v end})
arL:AddLabel('breaks enemy aimbot prediction')
arL:AddDivider()
arL:AddToggle('t_antibring',{Text='anti loop-bring',Default=false,Callback=function(v) cfg.antiBring=v end})
arL:AddLabel('rubberbands you back if dragged')
arL:AddDivider()
arL:AddToggle('t_antiattach',{Text='anti attach / fling',Default=false,Callback=function(v) cfg.antiAttach=v end})
arL:AddLabel('destroys foreign welds on your char')

arR:AddLabel('desync: intercepts packet 0x1B')
arR:AddLabel('vel spoof: sets velocity to inf')
arR:AddLabel('anti-bring: 50 stud threshold')
arR:AddLabel('anti-attach: checks every frame')

-- settings
local stL=T.settings:AddLeftGroupbox('theme')
local stR=T.settings:AddRightGroupbox('config')
ThemeManager:SetLibrary(Library);SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({'d_pl','d_stt','d_vht'})
ThemeManager:SetFolder('VoidMaster');SaveManager:SetFolder('VoidMaster/BloodyPlayground')
ThemeManager:ApplyToTab(stL);SaveManager:ApplyToTab(stR)

-- ============================================================
-- keybinds: rightshift=toggle, F4=panic (kills everything)
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then Library:ToggleGui() end
    if input.KeyCode == Enum.KeyCode.F4 then
        -- panic: disable everything
        cfg.voidSpam=false;cfg.voidDodge=false;cfg.voidHead=false
        cfg.orbit=false;cfg.bring=false;cfg.goTo=false;cfg.spin=false
        cfg.silent=false;cfg.stomp=false;cfg.godmode=false;cfg.antiVoid=false
        cfg.autoHeal=false;cfg.emergTp=false
        -- anti-rager cleanup
        if cfg.desync then cfg.desync=false;pcall(toggleRakNetDesync,false) end
        cfg.velSpoof=false;cfg.antiBring=false;cfg.antiAttach=false
        fovC.Visible=false
        Library:Notify({Title='panic', Content='all features disabled', Duration=2})
    end
end)

Library:SetWatermark('void master v5')
Library:SetWatermarkVisibility(true)
Library:Notify({Title='loaded', Content='v5 loaded! rightshift=toggle | f4=panic', Duration=4})
