--[[
    ★ Anti-Looped Out v7 + АВТО-ФАРМ ВИЛИ ★   (без хуков метатаблиц)

    АВТО-ФАРМ (кнопка справа снизу):
      Игра платит за вили (в логе WheelieReward + CashGain), поэтому фарм =
      бесконечный вили. Ассист [5] включается сам и держит питч ниже порога
      LOOPED OUT (~82°), иначе вили превращался бы в срыв.
      Клавиша вили не нужна заранее: кнопка "Найти клавишу вили" перебирает
      клавиши и находит ту, что поднимает нос (по атрибуту ScooterPredictedWheelie
      и углу самоката). Найдёт — будет жать её; не найдёт — будет править
      атрибуты ScooterLocalThrottle/ScooterLocalWheelie напрямую.
      В HUD видно: фарм ВКЛ/ВЫКЛ, найденная клавиша, режим и заработанные $.

    ЧТО ПОПРАВЛЕНО В v6.1:
      * "боком" — был баг ассиста: поворот шёл вокруг ЛОКАЛЬНОЙ оси, из-за чего
        самокат постепенно заваливало на бок. Теперь питч и крен считаются в
        мировых осях и правятся раздельно (питч до 74°, крен до 14°).
      * Вылет ПОСЛЕ держания — выход теперь мягкий: после отпускания 1.2 сек
        держу вертикальную скорость в нуле и только потом отдаю персонажа игре.

    ЧТО ИСПРАВЛЕНО ПО СРАВНЕНИЮ С v5 (по твоему логу):
      * v5 определял "я на самокате" ТОЛЬКО по событию ScooterMount(true, ...).
        В логе такого события НЕ БЫЛО (было только ScooterMount(false, ...)),
        поэтому поза "стоя на деке" не сохранялась и держать было нечего.
        В v6 посадка определяется по ТРЁМ признакам сразу:
          атрибут ScooterMountedForControls, PlatformStand = true, событие ScooterMount.
      * v5 держал ровно 2.5 сек и отпускал -> ты падал. В v6 отпускаю умно:
        как только игра снова посадила (ScooterMount(true)), либо самокат встал
        ровно и остановился, либо ты сам нажал C. Максимум — holdSeconds.
      * HUD на экране показывает ПРИЧИНУ последнего срыва и что делает защита —
        логи больше не обязательны.

    ЧТО ЗНАЕМ ТОЧНО (из лога диагностики):
      * Сиденья (Seat) нет. Посадка = PlatformStand + скрытая часть
        "_LocalRiderLeftFootTarget".
      * Клиент сам считает аварию:  [Scooter] crash: LOOPED OUT
        loop=true(82/86 world=86 fender=true ...)  -> порог примерно 82 градуса.
      * Дальше: PlatformStand=false, сервер WheelieGrade(0) + ScooterMount(false,...),
        ScooterLocalThrottle=0, ScooterMountedForControls=false, и через 0.14 с
        Running -> FallingDown. То есть тебя ПЕРЕСТАЮТ держать на деке.

    СЛОИ (каждый кнопкой):
      [1] Скрипты аварии  — выключить и держать выключенными.
      [2] Ремоуты аварии  — уничтожить локально (CrashRootCommit и подобные).
      [3] Не падать       — запрет Ragdoll/FallingDown, мгновенный подъём.
      [4] Держать деку    — возвращать в позу "стоя на деке" после срыва,
                            пока игра снова не посадит. Клавиша C — отпустить.
      [5] Ассист (не перекрут) — не даёт перекрутить самокат выше порога
                            LOOPED OUT (лимит ASSIST_LIMIT), чтобы игра
                            вообще не засчитала аварию.
      [6] Перепроверка    — как часто перепроверять отключение скриптов.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- ================= НАСТРОЙКИ =================
local cfg = {
	enabled      = true,   -- главный тумблер
	blockScripts = true,   -- [1]
	blockRemotes = true,   -- [2]
	noFall       = true,   -- [3]
	holdDeck     = true,   -- [4]
	assist       = true,   -- [5]

	holdSeconds  = 8.0,    -- максимум сколько держим деку после срыва
	crashSpeed   = 12,     -- скорость, выше которой снятие считаем срывом
	hitSpeed     = 6,      -- скорость, на которой считаем позу "едем"
	assistLimit  = 74,     -- максимальный питч (нос вверх), в логе порог LOOPED OUT ~82
	rollLimit    = 14,     -- максимальный крен на бок в градусах
	respeedEvery = 0.5,    -- [6]
	debug        = true,
}

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

local mountByEvent = false      -- игра сказала ScooterMount(true)
local mountByAttr  = false      -- атрибут ScooterMountedForControls
local mountByPose  = false      -- гуманоид стоит в PlatformStand
local scooterModel = nil        -- модель самоката
local deckRel      = nil        -- поза "стоя на деке" относительно самоката
local deckWorld    = nil        -- та же поза, но в мировых координатах (если модель исчезнет)
local holdUntil    = 0
local holdActive   = false
local holdReason   = "-"
local crashCount   = 0
local lastCrash    = "-"
local assistClamps = 0
local lastAssist   = 0
local lastAngle    = "-"
local releaseGraceUntil = 0

local function getSpeed()
	if root and root.Parent then
		local v = root.AssemblyLinearVelocity
		return Vector3.new(v.X, 0, v.Z).Magnitude
	end
	return 0
end

local function isMounted()
	return mountByEvent or mountByAttr or mountByPose
end

-- =========================================================
-- ПОИСК МОДЕЛИ САМОКАТА
-- (в логе она называлась 'Kukirin G2 Ultra'; ScooterDecor* — это НЕ самокат)
-- =========================================================
local function findScooterModel()
	if scooterModel and scooterModel.Parent then
		return scooterModel
	end
	local function looksLikeScooter(o)
		if not o:IsA("Model") then return false end
		local n = string.lower(o.Name)
		if string.find(n, "decor", 1, true) then return false end
		return string.find(n, "kukirin", 1, true) ~= nil
			or string.find(n, "scooter", 1, true) ~= nil
			or string.find(n, "scoot", 1, true) ~= nil
	end

	-- 1) прямо среди детей workspace
	for _, o in ipairs(workspace:GetChildren()) do
		if looksLikeScooter(o) then
			scooterModel = o
			return o
		end
	end

	-- 2) на уровень глубже (самокат может лежать в папке)
	for _, o in ipairs(workspace:GetChildren()) do
		if o:IsA("Model") or o:IsA("Folder") then
			for _, c in ipairs(o:GetChildren()) do
				if looksLikeScooter(c) then
					scooterModel = c
					return c
				end
			end
		end
	end
	return nil
end

-- =========================================================
-- [1] СКРИПТЫ АВАРИИ
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
			if pcall(function() d.Disabled = true end) then
				count += 1
				if not silent then
					log("отключён скрипт аварии:", full)
				end
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
-- [2] РЕМОУТЫ АВАРИИ
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
-- [4] ДЕРЖАТЬ ДЕКУ
-- =========================================================
local function releaseHold(reason)
	if not holdActive then return end
	holdActive = false
	holdUntil = 0

	-- мягкий выход: не бросаем сразу (иначе можно слететь снова)
	releaseGraceUntil = os.clock() + 1.0
	if root and root.Parent then
		local v = root.AssemblyLinearVelocity
		pcall(function()
			root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
		end)
	end

	-- 1.2 сек стоим ровно, потом отдаём персонажа игре
	task.delay(1.2, function()
		if holdActive then return end
		if humanoid and humanoid.Parent then
			pcall(function() humanoid.PlatformStand = false end)
			pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
		end
	end)

	holdReason = "отпустил: " .. tostring(reason)
	log("отпустил деку (" .. tostring(reason) .. ")")
end

local function startHold(speed, reason)
	-- если держание уже идёт (PlatformStand упал и следом ScooterMount(false)) —
	-- не считаем срыв дважды, просто продлеваем
	if holdActive then
		holdUntil = math.max(holdUntil, os.clock() + cfg.holdSeconds)
		log("срыв повторился тем же кадром -> продлеваю: " .. tostring(reason))
		return
	end
	if not deckRel then
		lastCrash = string.format("срыв на %.0f, но поза деки не сохранена", speed)
		log("СРЫВ, но deckRel = nil — держать нечего. Поезди подольше, чтобы поза записалась.")
		return
	end
	crashCount += 1
	holdActive = true
	holdUntil = os.clock() + cfg.holdSeconds
	lastCrash = string.format("срыв #%d: %.0f студ/с (%s)", crashCount, speed, tostring(reason))
	log(string.format("СРЫВ #%d на %.0f -> держу деку до %.1f сек", crashCount, speed, cfg.holdSeconds))

	if humanoid and humanoid.Parent then
		pcall(function() humanoid.PlatformStand = true end)
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
	end
	if cfg.restoreMount then
		pcall(function() player:SetAttribute("ScooterMountedForControls", true) end)
	end
end

-- слушаем посадку (только чтение)
local function watchMountRemote()
	if not scooterRemotes then
		log("ScooterRemotes не найден")
		return
	end
	local sm = scooterRemotes:FindFirstChild("ScooterMount")
	if not (sm and sm:IsA("RemoteEvent")) then
		log("ScooterMount не найден")
		return
	end
	sm.OnClientEvent:Connect(function(isMounted, model, ...)
		local was = isMounted == true
		mountByEvent = was
		if typeof(model) == "Instance" then
			scooterModel = model
		end
		local name = (typeof(model) == "Instance" and model.Name) or tostring(model)
		log(string.format("ScooterMount(%s, %s)", tostring(isMounted), name))

		if not was then
			-- снятие: срыв или обычное слезание?
			local spd = getSpeed()
			if cfg.enabled and cfg.holdDeck and spd > cfg.crashSpeed then
				startHold(spd, "ScooterMount(false)")
			else
				lastCrash = string.format("обычное слезание (%.0f студ/с)", spd)
				log(string.format("обычное слезание (%.0f) — не вмешиваюсь", spd))
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
	if newState == Enum.HumanoidStateType.Ragdoll
		or newState == Enum.HumanoidStateType.FallingDown then
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
	deckRel = nil
	mountByPose = false

	humanoid = char:WaitForChild("Humanoid", 20)
	root = char:WaitForChild("HumanoidRootPart", 20)
	if not humanoid then return end

	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	end)

	humanoid.StateChanged:Connect(onStateChanged)
	humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
		local stand = humanoid.PlatformStand
		if stand then
			mountByPose = true
		else
			-- платформенная стойка кончилась
			if mountByPose and cfg.enabled and cfg.holdDeck and not holdActive then
				local spd = getSpeed()
				if spd > cfg.crashSpeed and deckRel then
					mountByPose = false
					startHold(spd, "PlatformStand true->false")
					return
				end
			end
			mountByPose = false
		end
	end)
	log("персонаж под защитой:", char.Name)
end

if player.Character then
	task.spawn(setupCharacter, player.Character)
end
player.CharacterAdded:Connect(function(char)
	task.spawn(setupCharacter, char)
end)

player:GetAttributeChangedSignal("ScooterMountedForControls"):Connect(function()
	mountByAttr = player:GetAttribute("ScooterMountedForControls") == true
	log("ScooterMountedForControls =", tostring(mountByAttr))
end)

-- =========================================================
-- [5] АССИСТ: не перекрутить выше порога LOOPED OUT
-- =========================================================
local function assistStep()
	if not (cfg.enabled and cfg.assist) then return end
	-- работаем только когда едем/сидим, чтобы не крутить стоящий самокат
	if not (isMounted() or getSpeed() > 3) then return end
	local model = findScooterModel()
	if not model then return end

	local ok, cf = pcall(function() return model:GetPivot() end)
	if not ok or not cf then return end

	-- разбираем ориентацию на питч (нос вперёд/назад) и крен (на бок).
	-- Важно: всё считаем в МИРОВЫХ осях, поэтому самокат не заваливается боком
	-- (в прошлой версии поворот шёл вокруг локальной оси — оттуда и был "боком").
	local pos  = cf.Position
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.001 then
		flat = Vector3.new(0, 0, -1)
	end
	flat = flat.Unit
	local baseUp = Vector3.new(0, 1, 0)
	local right0 = flat:Cross(baseUp).Unit

	local up = cf.UpVector
	local pitch = -math.asin(math.clamp(up:Dot(flat), -1, 1))     -- >0: задрал нос
	local roll  =  math.asin(math.clamp(up:Dot(right0), -1, 1))   -- >0: завалился на бок

	local limPitch = math.rad(cfg.assistLimit)
	local limRoll  = math.rad(cfg.rollLimit)
	local fixPitch = math.clamp(pitch, -limPitch, limPitch)
	local fixRoll  = math.clamp(roll, -limRoll, limRoll)

	lastAngle = string.format("питч %.0f°, крен %.0f°", math.deg(pitch), math.deg(roll))

	-- всё в пределах — не трогаем самокат
	if math.abs(fixPitch - pitch) < 0.0001 and math.abs(fixRoll - roll) < 0.0001 then
		return
	end

	local newUp = (baseUp * math.cos(fixPitch) - flat * math.sin(fixPitch) + right0 * math.sin(fixRoll)).Unit
	local back  = -flat
	local right = newUp:Cross(back).Unit
	local fixed = CFrame.fromMatrix(pos, right, newUp, back)

	pcall(function() model:PivotTo(fixed) end)

	assistClamps += 1
	local now = os.clock()
	if now - lastAssist > 0.5 then
		lastAssist = now
		log(string.format("ассист: питч %.0f->%.0f | крен %.0f->%.0f (всего %d)",
			math.deg(pitch), math.deg(fixPitch), math.deg(roll), math.deg(fixRoll), assistClamps))
	end
end

-- =========================================================
-- ГЛАВНЫЙ ЦИКЛ
-- =========================================================
local lastRespeed = 0
local restSince = nil

RunService.Stepped:Connect(function()
	if not cfg.enabled then return end
	local now = os.clock()

	if cfg.blockScripts and now - lastRespeed > cfg.respeedEvery then
		lastRespeed = now
		blockCrashScripts(true)
	end

	if cfg.noFall and humanoid and humanoid.Parent then
		local st = humanoid:GetState()
		if st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown then
			if holdActive then
				pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
			else
				recover(st.Name)
			end
		elseif now < recoverUntil or now < releaseGraceUntil then
			clampVelocity()
		end
	end

	-- запоминаем позу "стоя на деке": и по событию, и по позе
	local mounted = isMounted()
	if humanoid and humanoid.Parent then
		mountByPose = humanoid.PlatformStand == true
	end

	if (mounted or mountByPose) and root and root.Parent then
		if getSpeed() > cfg.hitSpeed or mountByEvent then
			local model = findScooterModel()
			if model then
				local ok, rel = pcall(function()
					return model:GetPivot():ToObjectSpace(root.CFrame)
				end)
				if ok and rel then
					deckRel = rel
					local ok2, world = pcall(function()
						return model:GetPivot() * rel
					end)
					if ok2 and world then
						deckWorld = world
					end
				end
			end
		end
	end

	-- держим деку
	if holdActive then
		if not cfg.holdDeck then
			releaseHold("слой выключен")
		elseif now >= holdUntil then
			releaseHold("время вышло")
		elseif mountByEvent then
			releaseHold("игра снова посадила")
		else
			-- отпускаем, если самокат встал ровно и остановился
			local model = findScooterModel()
			local tilt = 0
			if model then
				local ok, cf = pcall(function() return model:GetPivot() end)
				if ok and cf then
					tilt = math.deg(math.acos(math.clamp(cf.UpVector.Y, -1, 1)))
				end
			end
			if getSpeed() < 2 and tilt < 12 then
				restSince = restSince or now
				if now - restSince > 1.0 then
					releaseHold("самокат встал ровно")
				end
			else
				restSince = nil
			end
		end

		if holdActive then
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
			local model = findScooterModel()
			local target
			if model and deckRel then
				local ok, cf = pcall(function()
					return model:GetPivot() * deckRel
				end)
				if ok then
					target = cf
				end
			elseif deckWorld then
				target = deckWorld
			end

			if target and character and character.Parent then
				pcall(function()
					character:PivotTo(target)
				end)
				if root and root.Parent then
					pcall(function()
						root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
					end)
				end
			end
		end
	else
		restSince = nil
	end
end)

-- ассист считаем после физики/логики игры
RunService.RenderStepped:Connect(assistStep)

-- C — отпустить деку вручную
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.C and holdActive then
		releaseHold("клавиша C")
	end
end)

-- =========================================================
-- ЗАПУСК
-- =========================================================
task.defer(function()
	if cfg.blockScripts then
		log("скриптов аварии отключено:", blockCrashScripts(false))
	end
	if cfg.blockRemotes then
		log("ремоутов аварии уничтожено:", blockCrashRemotes())
	end
	watchRemotes()
	watchMountRemote()
	findScooterModel()
	log("модель самоката:", scooterModel and scooterModel.Name or "не найдена (найду при посадке)")
end)

-- =========================================================
-- [7] АВТО-ФАРМ ВИЛИ
--     Игра платит за вили: в логе WheelieReward(()) + CashGain(2, 1).
--     Значит надо крутить вили БЕСКОНЕЧНО — а ассист [5] не даёт перекрутить
--     за порог LOOPED OUT (~82°), чтобы не слетать.
--
--     Как подаём управление (скрипт выберет сам, что доступно):
--       "vim"  — VirtualInputManager (работает в Studio/командной строке),
--       "key"  — executor-функции keypress/keyhold/keyrelease,
--       "attr" — прямая запись атрибутов ScooterLocalThrottle/ScooterLocalWheelie.
--     Клавиша вили подбирается калибровкой — вручную знать не нужно.
-- =========================================================
local farm = {
	on = false,
	method = nil,          -- "vim" | "key" | "attr"
	throttleKey = Enum.KeyCode.W,
	wheelieKey = nil,
	wheelieName = "?",
	earned = 0,
	startCash = nil,
}

local KEYCODES = {
	W = Enum.KeyCode.W, S = Enum.KeyCode.S, A = Enum.KeyCode.A, D = Enum.KeyCode.D,
	Space = Enum.KeyCode.Space, Q = Enum.KeyCode.Q, E = Enum.KeyCode.E, Z = Enum.KeyCode.Z,
	X = Enum.KeyCode.X, R = Enum.KeyCode.R, F = Enum.KeyCode.F, B = Enum.KeyCode.B,
	Up = Enum.KeyCode.Up, Down = Enum.KeyCode.Down, Left = Enum.KeyCode.Left,
	Right = Enum.KeyCode.Right, LeftShift = Enum.KeyCode.LeftShift,
}

local function gget(name)
	local v = rawget(_G, name)
	if v == nil then
		local ok, e = pcall(function() return getfenv(0)[name] end)
		if ok then v = e end
	end
	return v
end

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)
if not VIM then
	log("VirtualInputManager недоступен — буду пробовать keypress или атрибуты")
end

local heldKeys = {}
local function pressKey(kc)
	if not kc or heldKeys[kc] then return end
	heldKeys[kc] = true
	if VIM then
		pcall(function() VIM:SendKeyEvent(true, kc, false, game) end)
		return
	end
	local kp = gget("keypress")
	if type(kp) == "function" then
		pcall(function() kp(kc.Name:lower()) end)
		return
	end
	local kh = gget("keyhold")
	if type(kh) == "function" then
		pcall(function() kh(kc.Name:lower()) end)
	end
end

local function releaseKey(kc)
	if not kc or not heldKeys[kc] then return end
	heldKeys[kc] = nil
	if VIM then
		pcall(function() VIM:SendKeyEvent(false, kc, false, game) end)
		return
	end
	local kr = gget("keyrelease")
	if type(kr) == "function" then
		pcall(function() kr(kc.Name:lower()) end)
	end
end

local function releaseAllKeys()
	for kc in pairs(heldKeys) do
		releaseKey(kc)
	end
end

-- деньги (в логе есть CashUpdate/CashGain — обычно это leaderstats)
local function getCash()
	local ls = player:FindFirstChild("leaderstats")
	if not ls then return nil end
	for _, n in ipairs({ "Cash", "Money", "Coins", "Деньги" }) do
		local c = ls:FindFirstChild(n)
		if c and c:IsA("ValueBase") and type(c.Value) == "number" then
			return c.Value
		end
	end
	return nil
end

-- текущий питч самоката и "сигнал вили" из атрибутов
local function scooterPitch()
	local model = findScooterModel()
	if not model then return 0 end
	local ok, cf = pcall(function() return model:GetPivot() end)
	if not ok or not cf then return 0 end
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.001 then return 0 end
	flat = flat.Unit
	return math.deg(-math.asin(math.clamp(cf.UpVector:Dot(flat), -1, 1)))
end

local function wheelieSignal()
	local v = 0
	for _, n in ipairs({ "ScooterPredictedWheelie", "ScooterLocalWheelie" }) do
		local a = player:GetAttribute(n)
		if type(a) == "number" then
			v = math.max(v, math.abs(a))
		end
	end
	return v
end

-- калибровка: перебираем клавиши и смотрим, какая поднимает нос/сигнал вили
local calibrating = false
local function calibrate()
	if calibrating then return end
	if not isMounted() then
		log("калибровка невозможна: сначала сядь на самокат и поезжай")
		return
	end
	calibrating = true
	log("калибровка: ищу клавишу вили, сам ничего не нажимай ...")

	local bestKey, bestName, bestScore = nil, "?", 0
	for name, kc in pairs(KEYCODES) do
		if not farm.on then break end
		local p0, w0 = scooterPitch(), wheelieSignal()
		pressKey(kc)
		task.wait(0.7)
		local p1, w1 = scooterPitch(), wheelieSignal()
		releaseKey(kc)
		task.wait(0.3)

		local score = math.abs(p1 - p0) + math.abs(w1 - w0) * 10
		log(string.format("  %s: питч %.0f->%.0f | сигнал %.2f->%.2f | очков %.1f",
			name, p0, p1, w0, w1, score))
		if score > bestScore then
			bestScore, bestKey, bestName = score, kc, name
		end
	end

	if bestKey and bestScore > 3 then
		farm.wheelieKey = bestKey
		farm.wheelieName = bestName
		farm.method = VIM and "vim" or "key"
		log(string.format("калибровка: вили делает клавиша %s (очков %.1f) -> режим %s",
			bestName, bestScore, farm.method))
	else
		farm.method = "attr"
		log("калибровка: клавиша не найдена -> буду подкручивать атрибуты")
	end
	calibrating = false
end

local function farmOff(reason)
	if not farm.on then return end
	farm.on = false
	releaseAllKeys()
	log("авто-фарм выключен (" .. tostring(reason) .. ") заработано: " .. tostring(farm.earned))
end

local function farmOn()
	if farm.on then return end
	farm.on = true
	farm.startCash = getCash()
	farm.earned = 0

	-- без ассиста вили превратится в LOOPED OUT и срыв
	if not cfg.assist then
		cfg.assist = true
		log("авто-фарм: ассист [5] включён автоматически (иначе вили = авария)")
	end

	if not farm.method then
		task.spawn(calibrate)
	end
	log("авто-фарм включён. Кручу вили бесконечно, ассист держит угол.")
end

local function farmStep()
	if not farm.on then return end

	-- если калибровка не прошла (были не на самокате) — попробуем снова на ходу
	if not farm.method and not calibrating and isMounted() then
		task.spawn(calibrate)
	end

	if farm.method == "attr" then
		pcall(function()
			player:SetAttribute("ScooterLocalThrottle", 1)
			player:SetAttribute("ScooterLocalWheelie", 1)
		end)
	elseif not calibrating then
		pressKey(farm.throttleKey)
		if farm.wheelieKey then
			pressKey(farm.wheelieKey)
		end
	end

	-- если слетел — подержимся на прежнем месте деки и подождём, пока игра посадит
	if not isMounted() and deckWorld and character and character.Parent then
		pcall(function() character:PivotTo(deckWorld) end)
	end

	local c = getCash()
	if c then
		if farm.startCash == nil then farm.startCash = c end
		farm.earned = c - farm.startCash
	end
end

RunService.Heartbeat:Connect(farmStep)

-- =========================================================
-- GUI
-- =========================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AntiFallGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 270, 0, 356)
frame.Position = UDim2.new(0, 20, 0, 90)
frame.BackgroundColor3 = Color3.fromRGB(26, 26, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.Text = "★ Anti-Looped Out v7 + ФАРМ ★"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 13
title.Font = Enum.Font.SourceSansBold
title.Parent = frame

local function makeButton(text, y, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.94, 0, 0, 24)
	btn.Position = UDim2.new(0.03, 0, 0, y)
	btn.BackgroundColor3 = color
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 12
	btn.Font = Enum.Font.SourceSans
	btn.Parent = frame
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	return btn
end

local green = Color3.fromRGB(50, 190, 80)
local red   = Color3.fromRGB(195, 55, 55)

local masterBtn = makeButton("Защита: ВКЛ", 26, green)
local scriptBtn = makeButton("[1] Скрипты аварии", 52, green)
local remoteBtn = makeButton("[2] Ремоуты аварии", 78, green)
local noFallBtn = makeButton("[3] Не падать", 104, green)
local holdBtn   = makeButton("[4] Держать деку", 130, green)
local assistBtn = makeButton("[5] Ассист (не перекрут)", 156, green)
local resBtn    = makeButton("[6] Перепроверка", 182, red)
local resetBtn  = makeButton("Сбросить счётчики", 208, Color3.fromRGB(80, 80, 95))
local farmBtn   = makeButton("АВТО-ФАРМ ВИЛИ: ВЫКЛ", 234, red)
local calibBtn  = makeButton("Найти клавишу вили", 260, Color3.fromRGB(60, 90, 150))

local info = Instance.new("TextLabel")
info.Size = UDim2.new(1, -8, 0, 78)
info.Position = UDim2.new(0, 4, 1, -82)
info.BackgroundTransparency = 1
info.TextColor3 = Color3.fromRGB(220, 225, 220)
info.TextSize = 11
info.Font = Enum.Font.Code
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top
info.TextWrapped = true
info.Text = ""
info.Parent = frame

local function paint(btn, on, baseText)
	btn.Text = baseText .. (on and ": ВКЛ" or ": ВЫКЛ")
	btn.BackgroundColor3 = on and green or red
end

local function refreshInfo()
	local speed = getSpeed()
	local angle = 0
	local model = findScooterModel()
	if model then
		local ok, cf = pcall(function() return model:GetPivot() end)
		if ok and cf then
			angle = math.deg(math.acos(math.clamp(cf.UpVector.Y, -1, 1)))
		end
	end
	info.Text = string.format(
		"на деке: %s | угол: %.0f° | %.0f студ/с\nдержу: %s | срывов: %d | ассист: %d\nфарм: %s | вили: %s (%s) | +%s$\nдека: %s | %s\n%s",
		tostring(isMounted()), angle, speed,
		tostring(holdActive), crashCount, assistClamps,
		tostring(farm.on), farm.wheelieName, tostring(farm.method), tostring(farm.earned),
		deckRel and "записана" or "НЕТ", lastAngle,
		lastCrash)
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
		log("защита включена")
	else
		releaseHold("защита выключена")
		farmOff("защита выключена")
		paint(farmBtn, false, "АВТО-ФАРМ ВИЛИ")
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

assistBtn.MouseButton1Click:Connect(function()
	cfg.assist = not cfg.assist
	paint(assistBtn, cfg.assist, "[5] Ассист (не перекрут)")
	log("ассист:", cfg.assist and ("включён, лимит " .. cfg.assistLimit .. "°") or "выключен")
end)

resBtn.MouseButton1Click:Connect(function()
	cfg.respeedEvery = (cfg.respeedEvery == 0.5) and 0.05 or 0.5
	paint(resBtn, cfg.respeedEvery == 0.05, "[6] Перепроверка")
	log("интервал перепроверки:", cfg.respeedEvery)
end)

farmBtn.MouseButton1Click:Connect(function()
	if farm.on then
		farmOff("кнопка")
	else
		farmOn()
	end
	paint(farmBtn, farm.on, "АВТО-ФАРМ ВИЛИ")
	paint(assistBtn, cfg.assist, "[5] Ассист (не перекрут)")
end)

calibBtn.MouseButton1Click:Connect(function()
	if not farm.on then
		farmOn()
		paint(farmBtn, true, "АВТО-ФАРМ ВИЛИ")
	end
	task.spawn(calibrate)
end)

resetBtn.MouseButton1Click:Connect(function()
	crashCount = 0
	assistClamps = 0
	lastCrash = "-"
	log("счётчики сброшены")
end)

paint(scriptBtn, cfg.blockScripts, "[1] Скрипты аварии")
paint(remoteBtn, cfg.blockRemotes, "[2] Ремоуты аварии")
paint(noFallBtn, cfg.noFall, "[3] Не падать")
paint(holdBtn, cfg.holdDeck, "[4] Держать деку")
paint(assistBtn, cfg.assist, "[5] Ассист (не перекрут)")

task.spawn(function()
	while true do
		refreshInfo()
		task.wait(0.15)
	end
end)

-- перетаскивание
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
UserInputService.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

if cfg.blockScripts and cfg.enabled then
	task.spawn(function()
		for _ = 1, 20 do
			blockCrashScripts(true)
			task.wait(0.1)
		end
	end)
end

log("v6 запущен. C — отпустить деку вручную.")
