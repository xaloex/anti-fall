--[[
    ★ Anti-Looped Out v4 ★  (без хуков метатаблиц!)

    Почему прошлые версии не помогали:
      * Скрипт аварии — это скрипт ИГРЫ, и он не только роняет персонажа,
        но и отправляет сигнал аварии на сервер через ремоут CrashRootCommit.
        Просто отключить его LocalScript недостаточно, если вызов успевает уйти.
      * Блокировка PlatformStanding ломала езду — игра использует это состояние
        для самоката. В v4 оно НЕ трогается.

    Что делает v4:
      1. Отключает клиентские скрипты аварии (crash/fall/wipeout/bail/ragdoll).
      2. Уничтожает ЛОКАЛЬНО ремоуты аварии (CrashRootCommit и подобные) —
         после этого игровой скрипт физически не может ни отправить сигнал,
         ни получить команду на падение. Meter hook не нужен.
      3. Держит гуманоида: блокирует Ragdoll/FallingDown, мгновенно поднимает
         и на 0.6 сек гасит импульс, чтобы тебя не выкинуло со самоката.
      4. Пишет в консоль всё, что делает (можно проверить, что работает).
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local enabled     = false  -- главный тумблер
local blockRemote = true   -- уничтожать ремоуты аварии
local showLog     = true   -- писать в консоль

-- слова, по которым узнаём всё, что связано с аварией
local KEYWORDS = { "crash", "fall", "wipeout", "bail", "ragdoll", "looped" }

local function log(...)
	if showLog then
		print("[ANTI-FALL]", ...)
	end
end

local function nameHasKeyword(name)
	local n = string.lower(tostring(name))
	for _, kw in ipairs(KEYWORDS) do
		if string.find(n, kw, 1, true) then
			return true
		end
	end
	return false
end

-- =========================================================
-- 1. ОТКЛЮЧЕНИЕ КЛИЕНТСКИХ СКРИПТОВ АВАРИИ
-- =========================================================
local blockedScripts = {}
local scriptsBlocked = 0

local function blockCrashScripts()
	local ps = player:FindFirstChild("PlayerScripts")
	if not ps then return 0 end

	local count = 0
	for _, d in ipairs(ps:GetDescendants()) do
		if d:IsA("LocalScript") and not d.Disabled and nameHasKeyword(d.Name) then
			blockedScripts[d] = true
			local full = d:GetFullName()
			pcall(function() d.Disabled = true end)
			count += 1
			scriptsBlocked += 1
			log("отключён скрипт аварии:", full)
		end
	end
	return count
end

local function restoreCrashScripts()
	for s in pairs(blockedScripts) do
		pcall(function()
			if s and s.Parent then s.Disabled = false end
		end)
	end
	blockedScripts = {}
	scriptsBlocked = 0
end

-- =========================================================
-- 2. ЛОКАЛЬНОЕ УНИЧТОЖЕНИЕ РЕМОУТОВ АВАРИИ
--    (Destroy на клиенте рвёт все связи ремоута и делает его
--     непригодным для вызова — игровой скрипт получит ошибку)
-- =========================================================
local remotesKilled = 0

local function blockCrashRemotes()
	local count = 0
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if (d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent"))
			and nameHasKeyword(d.Name) then
			local full = d:GetFullName()
			local ok = pcall(function() d:Destroy() end)
			if ok then
				count += 1
				log("уничтожен ремоут аварии:", full)
			end
		end
	end
	remotesKilled = count
	return count
end

-- =========================================================
-- 3. ЗАЩИТА ГУМАНОИДА
-- =========================================================
local humanoid
local root
local stateConn
local recoverUntil = 0

-- гасит вертикальный импульс, чтобы персонажа не подбрасывало со скутера
local function clampVelocity()
	if root and root.Parent then
		local v = root.AssemblyLinearVelocity
		if v.Y > 0 then
			root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
		end
	end
end

local function recover(reason)
	if not humanoid or not humanoid.Parent then return end
	recoverUntil = os.clock() + 0.6
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	end)
	clampVelocity()
	log("авария поймана -> встаю:", reason)
end

local function onStateChanged(_, newState)
	if not enabled then return end
	-- PlatformStanding НЕ трогаем: игра использует его для езды
	if newState == Enum.HumanoidStateType.Ragdoll
		or newState == Enum.HumanoidStateType.FallingDown then
		recover(newState.Name)
	end
end

local function setupCharacter(char)
	if stateConn then
		stateConn:Disconnect()
		stateConn = nil
	end

	humanoid = char:WaitForChild("Humanoid", 20)
	root = char:WaitForChild("HumanoidRootPart", 20)
	if not humanoid then return end

	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	end)

	stateConn = humanoid.StateChanged:Connect(onStateChanged)
	log("персонаж под защитой")
end

if player.Character then
	task.spawn(setupCharacter, player.Character)
end
player.CharacterAdded:Connect(function(char)
	task.spawn(setupCharacter, char)
end)

-- сторож: если игра всё же уронила — поднимаем и не даём улететь
RunService.Stepped:Connect(function()
	if not enabled then return end
	if not humanoid or not humanoid.Parent then return end

	local st = humanoid:GetState()
	if st == Enum.HumanoidStateType.Ragdoll
		or st == Enum.HumanoidStateType.FallingDown then
		recover(st.Name)
	elseif os.clock() < recoverUntil then
		clampVelocity()
	end
end)

-- =========================================================
-- GUI
-- =========================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AntiFallGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 200, 0, 150)
frame.Position = UDim2.new(0.5, -100, 0.25, 0)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Text = "★ Anti-Looped Out v4 ★"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 13
title.Font = Enum.Font.SourceSansBold
title.Parent = frame

local function makeButton(text, y, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.85, 0, 0, 28)
	btn.Position = UDim2.new(0.075, 0, 0, y)
	btn.BackgroundColor3 = color
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 12
	btn.Font = Enum.Font.SourceSans
	btn.Parent = frame

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = btn
	return btn
end

local toggleBtn = makeButton("Анти-падение: ВЫКЛ", 34, Color3.fromRGB(200, 50, 50))
local remoteBtn = makeButton("Блок ремоутов: ВКЛ", 66, Color3.fromRGB(50, 200, 80))
local logBtn    = makeButton("Лог в консоль: ВКЛ", 98, Color3.fromRGB(50, 200, 80))

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 18)
status.Position = UDim2.new(0, 0, 1, -20)
status.BackgroundTransparency = 1
status.Text = "скриптов: 0 | ремоутов: 0"
status.TextColor3 = Color3.fromRGB(180, 180, 180)
status.TextSize = 11
status.Font = Enum.Font.Code
status.Parent = frame

-- =========================================================
-- ПЕРЕТАСКИВАНИЕ GUI
-- =========================================================
local dragging, dragInput, dragStart, startPos = false, nil, nil, nil

frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

frame.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

-- =========================================================
-- КНОПКИ
-- =========================================================
local function updateStatus()
	status.Text = string.format("скриптов: %d | ремоутов: %d", scriptsBlocked, remotesKilled)
end

toggleBtn.MouseButton1Click:Connect(function()
	enabled = not enabled
	if enabled then
		blockCrashScripts()
		if blockRemote then
			blockCrashRemotes()
		end
		toggleBtn.Text = "Анти-падение: ВКЛ"
		toggleBtn.BackgroundColor3 = Color3.fromRGB(50, 200, 80)
		log("ВКЛ — езжай")
	else
		restoreCrashScripts()
		toggleBtn.Text = "Анти-падение: ВЫКЛ"
		toggleBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		log("ВЫКЛ")
	end
	updateStatus()
end)

remoteBtn.MouseButton1Click:Connect(function()
	blockRemote = not blockRemote
	remoteBtn.Text = "Блок ремоутов: " .. (blockRemote and "ВКЛ" or "ВЫКЛ")
	remoteBtn.BackgroundColor3 = blockRemote and Color3.fromRGB(50, 200, 80) or Color3.fromRGB(90, 90, 90)
	if enabled and blockRemote then
		blockCrashRemotes()
		updateStatus()
	end
end)

logBtn.MouseButton1Click:Connect(function()
	showLog = not showLog
	logBtn.Text = "Лог в консоль: " .. (showLog and "ВКЛ" or "ВЫКЛ")
	logBtn.BackgroundColor3 = showLog and Color3.fromRGB(50, 200, 80) or Color3.fromRGB(90, 90, 90)
end)

-- ловим скрипты и ремоуты аварии, если они появятся позже
local function watchTree()
	local ps = player:FindFirstChild("PlayerScripts")
	if ps then
		ps.DescendantAdded:Connect(function(d)
			if enabled and d:IsA("LocalScript") and nameHasKeyword(d.Name) then
				blockedScripts[d] = true
				pcall(function() d.Disabled = true end)
				scriptsBlocked += 1
				log("отключён новый скрипт аварии:", d:GetFullName())
				updateStatus()
			end
		end)
	end

	ReplicatedStorage.DescendantAdded:Connect(function(d)
		if enabled and blockRemote
			and (d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent"))
			and nameHasKeyword(d.Name) then
			local full = d:GetFullName()
			pcall(function() d:Destroy() end)
			remotesKilled += 1
			log("уничтожен новый ремоут аварии:", full)
			updateStatus()
		end
	end)
end

pcall(watchTree)
updateStatus()
log("загружен. Нажми «Анти-падение: ВКЛ» ДО того, как сядешь на самокат.")
