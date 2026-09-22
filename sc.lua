--[[
    ★ Anti-Looped Out v5 ★   (без хуков метатаблиц — крашить нечем)

    ЧТО ПОКАЗАЛ ЛОГ ДИАГНОСТИКИ (это важно, всё сделано по нему):
      * Самокат — Модель (например "Kukirin G2 Ultra"). Сиденья (Seat) в нём НЕТ,
        посадка держится состоянием PlatformStand + скрытой частью
        "_LocalRiderLeftFootTarget". Поэтому Sit всегда false — по нему ловить нечего.
      * Посадка видна по атрибуту  player.ScooterMountedForControls (true/false).
      * Клиент сам считает аварию и пишет в лог:
            [Scooter] crash: LOOPED OUT loop=true(82/86 ... fender=true ...)
      * Дальше игра делает так:
            PlatformStand = false          <- персонаж перестаёт удерживаться на деке
            WheeleGrade(0), WheelieReward(())
            ScooterMount(false, Model 'Kukirin G2 Ultra', ...)   <- снятие с самоката
            ScooterLocalThrottle = 0, ScooterLocalWheelie = 0
            ScooterMountedForControls = false
            ScooterPredictedSpeed/Wheelie = nil
        и через 0.14 сек  Running -> FallingDown. То есть тебя не отбрасывает
        физикой — тебя ПЕРЕСТАЮТ держать на деке, и ты падаешь рядом.

    ЧТО ДЕЛАЕТ v5 — четыре слоя, каждый можно включить/выключить кнопкой:

      [1] СКРИПТЫ АВАРИИ (crash/fall/wipeout/bail/ragdoll/looped)
          выключаются мгновенно и держатся выключенными, даже если игра
          попытается включить их обратно.
      [2] РЕМОУТЫ АВАРИИ (CrashRootCommit и подобные) уничтожаются ЛОКАЛЬНО —
          игра не может отправить сигнал аварии со стороны клиента.
      [3] НЕ ПАДАТЬ: Ragdoll/FallingDown запрещены, при срыве мгновенный подъём
          в Running, гашение вертикального импульса.
      [4] ДЕРЖАТЬ ДЕКУ (главное новое): при срыве на скорости запоминается поза
          "стоя на деке" и персонаж возвращается в неё на 2.5 сек, пока игра
          снова не даст ехать. Плюс локально возвращается флаг
          ScooterMountedForControls, чтобы клиентские скрипты самоката снова
          начали удерживать райдера. Если не нужно — кнопка "Держать деку: ВЫКЛ".

    ПОРЯДОК: включи ВСЁ, потом садись на самокат и ломай.
    В F9 будут строки [ANTI-FALL] — пришли их, если что-то не сработает.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- ================= НАСТРОЙКИ =================
local cfg = {
	enabled       = true,   -- главный тумблер
	blockScripts  = true,   -- [1]
	blockRemotes  = true,   -- [2]
	noFall        = true,   -- [3]
	restoreMount  = true,   -- [4a] возвращать ScooterMountedForControls
	holdDeck      = true,   -- [4b] физически держать на деке
	holdSeconds   = 2.5,    -- сколько секунд держать после срыва
	crashSpeed    = 12,     -- скорость, выше которой снятие считаем срывом
	respeedEvery  = 0.5,    -- как часто перепроверять отключённые скрипты
	debug         = true,
}

-- слова, по которым узнаём всё, что связано с аварией
local KEYWORDS = { "crash", "fall", "wipeout", "bail", "ragdoll", "looped" }

local function log(...)
	if cfg.debug then
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

-- ================= СОСТОЯНИЕ =================
local humanoid, root, character
local scooterRemotes = ReplicatedStorage:FindFirstChild("ScooterRemotes")

local mountedFlag  = false       -- игра считает, что мы на самокате
local scooterModel = nil         -- модель самоката (приходит в ScooterMount)
local deckRel      = nil         -- поза персонажа относительно самоката (стоя на деке)
local holdUntil    = 0           -- до какого времени держим деку
local holdActive   = false
local crashCount   = 0

local function getSpeed()
	if root and root.Parent then
		local v = root.AssemblyLinearVelocity
		return Vector3.new(v.X, 0, v.Z).Magnitude
	end
	return 0
end

-- =========================================================
-- [1] СКРИПТЫ АВАРИИ: выключить и держать выключенными
-- =========================================================
local blockedScripts = {}

local function blockCrashScripts(silent)
	local ps = player:FindFirstChild("PlayerScripts")
	if not ps then return 0 end
	local count = 0
	for _, d in ipairs(ps:GetDescendants()) do
		if d:IsA("LocalScript") and not d.Disabled and nameHasKeyword(d.Name) then
			blockedScripts[d] = true
			local full = d:GetFullName()
			local ok = pcall(function() d.Disabled = true end)
			if ok then
				count += 1
				if not silent then
					log("отключён скрипт аварии:", full)
				end
			else
				log("НЕ удалось отключить:", full)
			end
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
end

-- =========================================================
-- [2] РЕМОУТЫ АВАРИИ: уничтожить ЛОКАЛЬНО
-- =========================================================
local function blockCrashRemotes()
	local count = 0
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if (d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent"))
			and nameHasKeyword(d.Name) then
			local full = d:GetFullName()
			if pcall(function() d:Destroy() end) then
				count += 1
				log("уничтожен ремоут аварии:", full)
			end
		end
	end
	return count
end

local function watchRemotes()
	if not scooterRemotes then return end
	scooterRemotes.DescendantAdded:Connect(function(d)
		if cfg.enabled and cfg.blockRemotes and nameHasKeyword(d.Name) then
			task.defer(function()
				log("появился ремоут аварии -> уничтожаю:", d:GetFullName())
				pcall(function() d:Destroy() end)
			end)
		end
	end)
end

-- =========================================================
-- [4] СРЫВ: держим деку и возвращаем флаг посадки
-- =========================================================
local function releaseHold(reason)
	if not holdActive then return end
	holdActive = false
	holdUntil = 0
	if humanoid and humanoid.Parent then
		pcall(function() humanoid.PlatformStand = false end)
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
	end
	log("отпустил деку (" .. tostring(reason) .. ")")
end

local function onCrashDismount(speed)
	crashCount += 1
	holdActive = true
	holdUntil = os.clock() + cfg.holdSeconds
	log(string.format("СРЫВ #%d на скорости %.0f -> держу деку %.1f сек", crashCount, speed, cfg.holdSeconds))

	if humanoid and humanoid.Parent then
		pcall(function() humanoid.PlatformStand = true end)
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
	end
	if cfg.restoreMount then
		pcall(function() player:SetAttribute("ScooterMountedForControls", true) end)
	end
end

-- слушаем серверную команду посадки (только чтение — безопасно)
local function watchMountRemote()
	if not scooterRemotes then
		log("ScooterRemotes не найден — держать деку не смогу, но остальное работает")
		return
	end
	local sm = scooterRemotes:FindFirstChild("ScooterMount")
	if not (sm and sm:IsA("RemoteEvent")) then
		log("ScooterMount не найден среди ремоутов")
		return
	end
	sm.OnClientEvent:Connect(function(isMounted, model, ...)
		local was = mountedFlag
		mountedFlag = (isMounted == true)

		if typeof(model) == "Instance" then
			scooterModel = model
		end

		local name = (typeof(model) == "Instance" and model.Name) or tostring(model)
		log(string.format("ScooterMount(%s, %s)", tostring(isMounted), name))

		if was and not mountedFlag then
			local spd = getSpeed()
			if spd > cfg.crashSpeed and cfg.enabled and cfg.holdDeck then
				onCrashDismount(spd)
			else
				log(string.format("обычное слезание (скорость %.0f) — не вмешиваюсь", spd))
			end
		end
	end)
	log("слушаю ScooterMount")
end

-- =========================================================
-- [3] НЕ ПАДАТЬ
-- =========================================================
local recoverUntil = 0

local function clampVelocity()
	if root and root.Parent then
		local v = root.AssemblyLinearVelocity
		if v.Y > 0 then
			pcall(function()
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end)
		end
	end
end

local function recover(reason)
	if not (humanoid and humanoid.Parent) then return end
	recoverUntil = os.clock() + 0.6
	pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
	clampVelocity()
	log("авария поймана -> встаю:", reason)
end

local function onStateChanged(_, newState)
	if not (cfg.enabled and cfg.noFall) then return end
	-- PlatformStanding НЕ трогаем: игра держит на нём посадку на самокат
	if newState == Enum.HumanoidStateType.Ragdoll
		or newState == Enum.HumanoidStateType.FallingDown then
		-- если мы в режиме "держим деку", встаём прямо на деку, а не на землю
		if holdActive then
			if humanoid and humanoid.Parent then
				pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
			end
		else
			recover(newState.Name)
		end
	end
end

local function setupCharacter(char)
	character = char
	holdActive = false
	holdUntil = 0

	humanoid = char:WaitForChild("Humanoid", 20)
	root = char:WaitForChild("HumanoidRootPart", 20)
	if not humanoid then return end

	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	end)

	humanoid.StateChanged:Connect(onStateChanged)
	log("персонаж под защитой:", char.Name)
end

if player.Character then
	task.spawn(setupCharacter, player.Character)
end
player.CharacterAdded:Connect(function(char)
	task.spawn(setupCharacter, char)
end)

-- видно, когда игра ставит/снимает флаг посадки
player:GetAttributeChangedSignal("ScooterMountedForControls"):Connect(function()
	log("ScooterMountedForControls =", tostring(player:GetAttribute("ScooterMountedForControls")))
end)

-- =========================================================
-- ГЛАВНЫЙ ЦИКЛ
-- =========================================================
local lastRespeed = 0

RunService.Stepped:Connect(function()
	if not cfg.enabled then return end
	local now = os.clock()

	-- [1] держим скрипты аварии выключенными
	if cfg.blockScripts and now - lastRespeed > cfg.respeedEvery then
		lastRespeed = now
		blockCrashScripts(true)
	end

	-- [3] не падать
	if cfg.noFall and humanoid and humanoid.Parent then
		local st = humanoid:GetState()
		if st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown then
			if holdActive then
				pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
			else
				recover(st.Name)
			end
		elseif now < recoverUntil then
			clampVelocity()
		end
	end

	-- [4b] запоминаем позу "стоя на деке", пока едем
	if mountedFlag and scooterModel and scooterModel.Parent and root and root.Parent then
		if getSpeed() > 4 then
			local ok, rel = pcall(function()
				return scooterModel:GetPivot():ToObjectSpace(root.CFrame)
			end)
			if ok and rel then
				deckRel = rel
			end
		end
	end

	-- [4] держим деку после срыва
	if holdActive then
		if now >= holdUntil then
			releaseHold("время вышло")
			return
		end

		if humanoid and humanoid.Parent then
			pcall(function()
				if not humanoid.PlatformStand then
					humanoid.PlatformStand = true
				end
			end)
			if humanoid:GetState() ~= Enum.HumanoidStateType.PlatformStanding then
				pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
			end
		end

		if cfg.restoreMount then
			pcall(function()
				if player:GetAttribute("ScooterMountedForControls") ~= true then
					player:SetAttribute("ScooterMountedForControls", true)
				end
			end)
		end

		if scooterModel and scooterModel.Parent and deckRel and character and character.Parent then
			pcall(function()
				character:PivotTo(scooterModel:GetPivot() * deckRel)
			end)
			if root and root.Parent then
				pcall(function()
					root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				end)
			end
		end
	end
end)

-- =========================================================
-- ВКЛЮЧЕНИЕ
-- =========================================================
task.defer(function()
	if cfg.blockScripts then
		local n = blockCrashScripts(false)
		log("скриптов аварии отключено:", n)
	else
		restoreCrashScripts()
	end
	if cfg.blockRemotes then
		log("ремоутов аварии уничтожено:", blockCrashRemotes())
	end
	watchRemotes()
	watchMountRemote()
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
frame.Size = UDim2.new(0, 220, 0, 236)
frame.Position = UDim2.new(0.5, -110, 0.2, 0)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 26)
title.BackgroundTransparency = 1
title.Text = "★ Anti-Looped Out v5 ★"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 13
title.Font = Enum.Font.SourceSansBold
title.Parent = frame

local function makeButton(text, y, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.9, 0, 0, 26)
	btn.Position = UDim2.new(0.05, 0, 0, y)
	btn.BackgroundColor3 = color
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 12
	btn.Font = Enum.Font.SourceSans
	btn.Parent = frame
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	return btn
end

local green = Color3.fromRGB(50, 200, 80)
local red   = Color3.fromRGB(200, 50, 50)

local masterBtn  = makeButton("Защита: ВКЛ", 28, green)
local scriptBtn  = makeButton("[1] Скрипты аварии: ВКЛ", 56, green)
local remoteBtn  = makeButton("[2] Ремоуты аварии: ВКЛ", 84, green)
local noFallBtn  = makeButton("[3] Не падать: ВКЛ", 112, green)
local holdBtn    = makeButton("[4] Держать деку: ВКЛ", 140, green)
local resBtn     = makeButton("[5] Перепроверка: ВКЛ", 168, green)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 34)
status.Position = UDim2.new(0, 0, 1, -38)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(220, 220, 220)
status.TextSize = 11
status.Font = Enum.Font.SourceSans
status.Text = "срывов: 0"
status.Parent = frame

local function paint(btn, on, baseText)
	btn.Text = baseText .. (on and ": ВКЛ" or ": ВЫКЛ")
	btn.BackgroundColor3 = on and green or red
end

local function refreshStatus()
	status.Text = string.format("срывов: %d | на самокате: %s | держу: %s",
		crashCount, tostring(mountedFlag), tostring(holdActive))
end

masterBtn.MouseButton1Click:Connect(function()
	cfg.enabled = not cfg.enabled
	paint(masterBtn, cfg.enabled, "Защита")
	if cfg.enabled then
		if cfg.blockScripts then
			log("скриптов аварии отключено:", blockCrashScripts(false))
		end
		if cfg.blockRemotes then
			log("ремоутов аварии уничтожено:", blockCrashRemotes())
		end
	else
		releaseHold("защита выключена")
		restoreCrashScripts()
		log("защита выключена")
	end
end)

scriptBtn.MouseButton1Click:Connect(function()
	cfg.blockScripts = not cfg.blockScripts
	paint(scriptBtn, cfg.blockScripts, "[1] Скрипты аварии")
	if cfg.blockScripts then
		log("скриптов аварии отключено:", blockCrashScripts(false))
	else
		restoreCrashScripts()
	end
end)

remoteBtn.MouseButton1Click:Connect(function()
	cfg.blockRemotes = not cfg.blockRemotes
	paint(remoteBtn, cfg.blockRemotes, "[2] Ремоуты аварии")
	if cfg.blockRemotes then
		log("ремоутов аварии уничтожено:", blockCrashRemotes())
	end
end)

noFallBtn.MouseButton1Click:Connect(function()
	cfg.noFall = not cfg.noFall
	paint(noFallBtn, cfg.noFall, "[3] Не падать")
end)

holdBtn.MouseButton1Click:Connect(function()
	cfg.holdDeck = not cfg.holdDeck
	paint(holdBtn, cfg.holdDeck, "[4] Держать деку")
	if not cfg.holdDeck then
		releaseHold("кнопка выключена")
	end
end)

resBtn.MouseButton1Click:Connect(function()
	cfg.respeedEvery = (cfg.respeedEvery == 0.5) and 0.05 or 0.5
	paint(resBtn, cfg.respeedEvery == 0.05, "[5] Перепроверка")
	log("интервал перепроверки:", cfg.respeedEvery)
end)

paint(scriptBtn, cfg.blockScripts, "[1] Скрипты аварии")
paint(remoteBtn, cfg.blockRemotes, "[2] Ремоуты аварии")
paint(noFallBtn, cfg.noFall, "[3] Не падать")
paint(holdBtn, cfg.holdDeck, "[4] Держать деку")
paint(resBtn, false, "[5] Перепроверка")

task.spawn(function()
	while true do
		refreshStatus()
		task.wait(0.2)
	end
end)

-- перетаскивание GUI
local dragging, dragStart, startPos, dragInput
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
game:GetService("UserInputService").InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

-- принудительно отключаем скрипты аварии прямо сейчас
if cfg.blockScripts and cfg.enabled then
	task.spawn(function()
		for _ = 1, 20 do
			blockCrashScripts(true)
			task.wait(0.1)
		end
	end)
end

log("v5 запущен. Включи всё и сядь на самокат.")
