--[[
    ★ Anti-Looped Out v9: анти-падение + фарм + свои самокаты + серверный спавн ★

    СЕРВЕРНЫЙ СПАВН (чтобы видели ВСЕ игроки):
      Локальный клон видят только ты — это ограничение Roblox, обойти нельзя.
      Чтобы самокат создал сервер, есть две кнопки в окне САМИКИ:
        1. "Лог ремоутов 20 сек" — __namecall-хук на 20 секунд: пишет все
           FireServer/InvokeServer. Сделай в это время обычное действие
           с самокатом — увидим точные аргументы спавна.
           Если твой исполнитель крашится от хуков — не жми, пользуйся второй.
        2. "Проба SpawnScooter" — совсем без хуков: дёргает игровой ремоут
           спавна с разными аргументами и смотрит, появился ли самокат.
           Покупки (purchase/buy) не трогаются никогда.

    ОКНО "САМИКИ" (справа):
      * список моделей из ReplicatedStorage.Scooters — что нашлось, то в списке;
      * "Спавнить рядом со мной" — клон выбранной модели перед тобой, на землю;
      * "Сесть на мой" — ставит тебя на деку своего самоката (держит слой [4]);
        газ — W, назад — S, руль — A/D, слезть — C;
      * "Удалить мой" — убирает все твои клоны;
      * "Скорость: x1/x2/x3/x5/x8" — крутилка. На игровом самокате держит
        скорость до xN от базовых ~50 студ/с (потолок 320), на своём — задаёт
        скорость движения.
      Честно: клон клиента видит только ты. Сервер про него не знает, поэтому
      игра сама на него не посадит — сажаемся кнопкой, и держит наш слой [4].

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
      [1] Скрипты аварии  — выключить и держать выключенными
                            (по умолчанию только CrashFallClient — точно).
      [2] Ремоуты аварии  — уничтожить локально. ПО УМОЛЧАНИЮ ВЫКЛЮЧЕНО:
                            Destroy() на ремоуте ломает игровой код, который
                            ждёт его через WaitForChild — тот получает nil и
                            падает с "attempt to call a nil value".
                            Включать только если без него не работает.
      [11] Ошибки игры     — пишутся в лог с пометкой "ИГРА ОШИБКА",
                            "(давняя)" = было ещё до нашего запуска (игра),
                            без пометки = появилось при нас (наш скрипт).
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
	-- [2] ВНИМАНИЕ: Destroy() на ремоуте ломает игровой код, который ждёт его
	-- через WaitForChild: ожидание вернёт nil и игра упадёт с
	-- "attempt to call a nil value". Поэтому по умолчанию ВЫКЛЮЧЕНО.
	-- Включай, только если без этого не работает, и помни про эту ошибку.
	blockRemotes = false,  -- [2]
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

-- ВАЖНО: по умолчанию трогаем ТОЛЬКО точные цели.
-- Широкий режим по словам опасен: под "fall"/"bail"/"crash" может попасть
-- UI-скрипт или ремоут интерфейса, и игра потом падает с
-- "attempt to call a nil value". Нужен широкий — поставь "keywords".
cfg.scriptMode   = "exact"
cfg.remoteMode   = "exact"
cfg.crashScripts = { "CrashFallClient" }
cfg.crashRemotes = { "CrashRootCommit" }

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

local function listHasExact(list, name)
	local low = string.lower(tostring(name))
	for _, n in ipairs(list) do
		if string.lower(tostring(n)) == low then
			return true
		end
	end
	return false
end

local function scriptIsCrash(name)
	if cfg.scriptMode == "keywords" then
		return nameHasKeyword(name)
	end
	return listHasExact(cfg.crashScripts, name)
end

local function remoteIsCrash(name)
	if cfg.remoteMode == "keywords" then
		return nameHasKeyword(name)
	end
	return listHasExact(cfg.crashRemotes, name)
end

-- =========================================================
-- [11] ПЕРЕХВАТ ОШИБОК ИГРЫ
--   Видно сразу, наша это ошибка или игра сама так падает:
--   * "(давняя)" — ошибка была ДО запуска нашего скрипта, значит игра;
--   * без пометки — появилась уже при нас, значит что-то задел наш скрипт.
-- =========================================================
local gameErrors = { count = 0, last = "-", history = {} }

local function noteGameError(text, wasBefore)
	gameErrors.count += 1
	local line = (wasBefore and "(давняя) " or "") .. tostring(text)
	gameErrors.last = string.sub(line, 1, 120)
	table.insert(gameErrors.history, line)
	if #gameErrors.history > 60 then
		table.remove(gameErrors.history, 1)
	end
	log("ИГРА ОШИБКА", line)
end

pcall(function()
	local LogService = game:GetService("LogService")
	for _, e in ipairs(LogService:GetLogHistory()) do
		if e.messageType == Enum.MessageType.MessageError then
			noteGameError(e.message, true)
		end
	end
	LogService.MessageOut:Connect(function(message, msgType)
		if msgType == Enum.MessageType.MessageError then
			noteGameError(message, false)
		end
	end)
end)

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
local holdForever  = false      -- держим райдера бесконечно (езда на своём самокате)

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
		if d:IsA("LocalScript") and not d.Disabled and scriptIsCrash(d.Name) then
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
			and remoteIsCrash(d.Name) then
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
		if cfg.enabled and cfg.blockRemotes and remoteIsCrash(d.Name) then
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
	holdForever = false
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
	holdForever = false
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
		elseif holdForever then
			-- едем на своём самокате: держим, пока сами не отпустим (C)
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
frame.Size = UDim2.new(0, 270, 0, 400)
frame.Position = UDim2.new(0, 20, 0, 90)
frame.BackgroundColor3 = Color3.fromRGB(26, 26, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.Text = "★ Anti-Looped Out v9 ★"
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
info.Size = UDim2.new(1, -8, 0, 104)
info.Position = UDim2.new(0, 4, 1, -110)
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
		"на деке: %s | угол: %.0f° | %.0f студ/с\nдержу: %s | срывов: %d | ассист: %d\nфарм: %s | вили: %s (%s) | +%s$\nдека: %s | %s\n%s\nошибок игры: %d | %s",
		tostring(isMounted()), angle, speed,
		tostring(holdActive), crashCount, assistClamps,
		tostring(farm.on), farm.wheelieName, tostring(farm.method), tostring(farm.earned),
		deckRel and "записана" or "НЕТ", lastAngle,
		lastCrash,
		gameErrors.count, gameErrors.last)
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

log("v8 запущен. C — отпустить деку вручную.")

-- =========================================================
-- [8] САМИКИ: скорость + спавн из ReplicatedStorage.Scooters
--
--     ВАЖНО, честно: всё, что создаёт клиент, видит только он сам.
--     Для сервера твоего самоката не существует, поэтому игра сама на него
--     не посадит. Зато он полностью клиентский — клиент владеет его физикой,
--     и кнопка "Сесть на мой" ставит тебя на деку, а слой [4] удерживает.
--     Газ (W), назад (S) и руль (A/D) для своего самоката сделаны ниже.
-- =========================================================
local SCOOTERS_FOLDER = "Scooters"
local SPEED_STEPS = { 1, 2, 3, 5, 8 }
local MAX_SPEED = 100000

-- Ручное управление скоростью: любое число, применяется сразу несколькими способами,
-- чтобы игра не "съедала" скорость (она перезаписывает физику каждый кадр).
local speedCtrl = {
	target = 50,        -- студ/с: ставится вручную в окне СКОРОСТЬ или кнопками xN
	useLinear = true,   -- LinearVelocity: тяга постоянно тянет сборку к нужной скорости
	hardMode = true,    -- каждый кадр двигать саму модель (скорость не может упасть)
	autoDrive = false,  -- ехать без газа
	maxForce = 1e5,
}

local my = {
	templates = {},
	selected = nil,
	clones = {},
	speedIdx = 1,
	riding = nil,
	baseSpeed = 50,     -- в логе игра писала ScooterPredictedSpeed ≈ 49
}

-- самое крупное основание модели = её "двигатель" для физики
local function primaryOf(model)
	if not model then return nil end
	local p = model.PrimaryPart
	if p and p:IsA("BasePart") then return p end
	local best, bestVol = nil, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then
				bestVol, best = v, d
			end
		end
	end
	return best
end

local function refreshTemplates()
	my.templates = {}
	local folder = ReplicatedStorage:FindFirstChild(SCOOTERS_FOLDER)
	if not folder then
		log("ReplicatedStorage." .. SCOOTERS_FOLDER .. " не найдена")
		return
	end
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("Model") then
			table.insert(my.templates, d)
		end
	end
	if #my.templates == 0 then
		for _, d in ipairs(folder:GetChildren()) do
			if d:IsA("Model") or d:IsA("Tool") then
				table.insert(my.templates, d)
			end
		end
	end
	log("моделей самокатов в ReplicatedStorage." .. SCOOTERS_FOLDER .. ": " .. #my.templates)
end

local function prepareClone(clone)
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			pcall(function()
				d.Anchored = false
				d.CanCollide = true
				d.CanQuery = true
				d.CanTouch = true
				d.Massless = false
			end)
		elseif d:IsA("BaseScript") then
			pcall(function() d.Disabled = true end)
		end
	end
end

local function placeNearMe(model)
	if not (character and root and root.Parent) then return end
	local front = root.CFrame * CFrame.new(0, 0, -9)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { character, model }
	local hit = workspace:Raycast(front.Position + Vector3.new(0, 20, 0), Vector3.new(0, -80, 0), rp)
	local y = hit and hit.Position.Y or front.Position.Y
	local rot = front - front.Position
	model:PivotTo(CFrame.new(Vector3.new(front.Position.X, y, front.Position.Z)) * rot)
	local ok, size = pcall(function()
		local _, s = model:GetBoundingBox()
		return s
	end)
	if ok and size then
		local cf = model:GetPivot()
		model:PivotTo(cf + Vector3.new(0, size.Y / 2, 0))
	end
end

local function spawnNear()
	if not my.selected then
		log("спавн: сначала выбери модель в списке (окно САМИКИ)")
		return
	end
	local ok, clone = pcall(function() return my.selected:Clone() end)
	if not ok or not clone then
		log("спавн: не удалось склонировать " .. my.selected.Name)
		return
	end
	clone.Name = "MY_" .. my.selected.Name
	prepareClone(clone)
	if not clone.PrimaryPart then
		clone.PrimaryPart = primaryOf(clone)
	end
	clone.Parent = workspace
	my.clones[clone] = true
	placeNearMe(clone)
	log("заспавнил рядом: " .. clone.Name)
end

local function deleteMine()
	for m in pairs(my.clones) do
		pcall(function()
			if m and m.Parent then m:Destroy() end
		end)
	end
	my.clones = {}
	if my.riding then
		my.riding = nil
		if holdActive then releaseHold("свой самокат удалён") end
	end
	log("мои самокаты удалены")
end

local function rideMine()
	local clone
	for m in pairs(my.clones) do
		if m and m.Parent then
			clone = m
			break
		end
	end
	if not clone then
		log("сесть: сначала нажми Спавнить рядом")
		return
	end
	if not (character and root and root.Parent) then return end

	local pivot = clone:GetPivot()
	local size
	pcall(function()
		local _, s = clone:GetBoundingBox()
		size = s
	end)
	local h = (size and size.Y / 2) or 2
	local rot = pivot - pivot.Position
	local deck = CFrame.new(pivot.Position + Vector3.new(0, h + 2.5, 0)) * rot

	pcall(function() character:PivotTo(deck) end)
	if humanoid and humanoid.Parent then
		pcall(function() humanoid.PlatformStand = true end)
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
	end

	my.riding = clone
	scooterModel = clone
	deckRel = pivot:ToObjectSpace(deck)
	local ok, w = pcall(function() return clone:GetPivot() * deckRel end)
	if ok then deckWorld = w end
	holdActive = true
	holdForever = true
	holdUntil = math.huge
	log("сел на свой самокат: " .. clone.Name .. " (газ W, назад S, руль A/D, C — слезть)")
end

local function ownerOf(model)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local ok, owner = pcall(function() return p:GetNetworkOwner() end)
			if ok then
				return owner and owner.Name or "сервер"
			end
		end
	end
	return "?"
end

-- у модели может быть несколько отдельных сборок (корпус, колёса) — берём корни всех
local function assemblyRootsOf(model)
	local seen, res = {}, {}
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and not p.Anchored then
			local ok, root = pcall(function() return p.AssemblyRootPart end)
			if ok and root and not seen[root] then
				seen[root] = true
				res[#res + 1] = root
			end
		end
	end
	return res
end

local function ensureDrive(part)
	local att = part:FindFirstChild("AF_Drive")
	if not att then
		att = Instance.new("Attachment")
		att.Name = "AF_Drive"
		att.Parent = part
	end
	local lv = att:FindFirstChild("AF_DriveLV")
	if not lv then
		lv = Instance.new("LinearVelocity")
		lv.Name = "AF_DriveLV"
		lv.Attachment0 = att
		lv.Parent = att
		pcall(function()
			lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
			lv.RelativeTo = Enum.ActuatorRelativeTo.World
			lv.ForceLimitsEnabled = true
		end)
	end
	return lv
end

local function removeDrive(model)
	for _, p in ipairs(model:GetDescendants()) do
		local att = p.FindFirstChild and p:FindFirstChild("AF_Drive")
		if att then
			local lv = att:FindFirstChild("AF_DriveLV")
			if lv then pcall(function() lv:Destroy() end) end
			pcall(function() att:Destroy() end)
		end
	end
end

-- руль своего самоката (скорость разгоняет общий механизм ниже)
local function mySteerStep()
	local clone = my.riding
	if not (clone and clone.Parent) then
		my.riding = nil
		return
	end
	-- слезли (C или слой отпустил) — больше не ведём самокат
	if not holdActive then
		my.riding = nil
		scooterModel = nil
		return
	end
	local steer = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then steer += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then steer -= 1 end

	if steer ~= 0 then
		pcall(function()
			clone:PivotTo(clone:GetPivot() * CFrame.Angles(0, math.rad(steer * 2.2), 0))
		end)
	end
end

local speedInfo = { asked = 0, real = 0, mode = "-" }

-- ГЛАВНОЕ: применяем скорость сразу тремя способами, чтобы игра её не съедала
local function speedApplyStep(dt)
	local target = tonumber(speedCtrl.target) or 50
	speedInfo.asked = target

	local model = (my.riding and my.riding.Parent) and my.riding
		or ((scooterModel and scooterModel.Parent) and scooterModel)
		or findScooterModel()
	if not model then
		speedInfo.real = 0
		return
	end
	if not (isMounted() or my.riding) then return end

	local pivot = model:GetPivot()
	local look = pivot.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.001 then return end
	flatLook = flatLook.Unit

	local roots = assemblyRootsOf(model)
	if #roots == 0 then return end

	local fwd = UserInputService:IsKeyDown(Enum.KeyCode.W)
	local back = UserInputService:IsKeyDown(Enum.KeyCode.S)

	local v0 = roots[1].AssemblyLinearVelocity
	local flatV = Vector3.new(v0.X, 0, v0.Z)
	speedInfo.real = flatV.Magnitude

	local dir
	if flatV.Magnitude > 2 then
		dir = flatV.Unit
	elseif fwd or back then
		dir = fwd and flatLook or -flatLook
	elseif speedCtrl.autoDrive then
		dir = flatLook
	end

	if not dir then
		for _, part in ipairs(roots) do
			local lv = ensureDrive(part)
			if lv then lv.Enabled = false end
		end
		speedInfo.mode = "стоим"
		return
	end

	local want = target
	if back and not fwd then want = -target end

	-- способ 1: линейная тяга (тянет каждый физический шаг — скорость не спадает)
	if speedCtrl.useLinear then
		for _, part in ipairs(roots) do
			local lv = ensureDrive(part)
			if lv then
				lv.Enabled = true
				lv.MaxForce = speedCtrl.maxForce
				lv.VectorVelocity = dir * want
			end
		end
	end

	-- способ 2: напрямую задать скорость всем сборкам
	for _, part in ipairs(roots) do
		pcall(function()
			part.AssemblyLinearVelocity = Vector3.new(dir.X * want, part.AssemblyLinearVelocity.Y, dir.Z * want)
		end)
	end

	-- способ 3: жёстко двигать модель (работает там, где физику игры не переспорить)
	if speedCtrl.hardMode and dt then
		local owner = ownerOf(model)
		local allowed = (my.riding ~= nil) or owner == player.Name
		if allowed then
			pcall(function()
				model:PivotTo(CFrame.new(pivot.Position + dir * want * dt) * (pivot - pivot.Position))
			end)
		end
	end

	speedInfo.mode = (speedCtrl.useLinear and "тяга" or "") .. (speedCtrl.hardMode and "+жёстко" or "")
end

RunService.RenderStepped:Connect(function(dt)
	mySteerStep()
	speedApplyStep(dt)
end)

-- ===================== ОКНО "САМИКИ" =====================
local gui2 = Instance.new("ScreenGui")
gui2.Name = "MyScooterGui"
gui2.ResetOnSpawn = false
gui2.Parent = player:WaitForChild("PlayerGui")

local f2 = Instance.new("Frame")
f2.Size = UDim2.new(0, 260, 0, 330)
f2.Position = UDim2.new(1, -285, 0, 90)
f2.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
f2.BorderSizePixel = 0
f2.Active = true
f2.Parent = gui2
Instance.new("UICorner", f2).CornerRadius = UDim.new(0, 8)

local t2 = Instance.new("TextLabel")
t2.Size = UDim2.new(1, 0, 0, 24)
t2.BackgroundTransparency = 1
t2.Text = "★ САМИКИ (ReplicatedStorage.Scooters) ★"
t2.TextColor3 = Color3.fromRGB(255, 230, 150)
t2.TextSize = 12
t2.Font = Enum.Font.SourceSansBold
t2.Parent = f2

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(0.95, 0, 0, 150)
list.Position = UDim2.new(0.025, 0, 0, 26)
list.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
list.BorderSizePixel = 0
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.ScrollBarThickness = 4
list.Parent = f2
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 3)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local pickLabel = Instance.new("TextLabel")
pickLabel.Size = UDim2.new(0.95, 0, 0, 18)
pickLabel.Position = UDim2.new(0.025, 0, 0, 180)
pickLabel.BackgroundTransparency = 1
pickLabel.Text = "выбрано: -"
pickLabel.TextColor3 = Color3.fromRGB(200, 210, 220)
pickLabel.TextSize = 11
pickLabel.Font = Enum.Font.Code
pickLabel.TextXAlignment = Enum.TextXAlignment.Left
pickLabel.Parent = f2

local function makeBtn2(text, y, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.95, 0, 0, 24)
	b.Position = UDim2.new(0.025, 0, 0, y)
	b.BackgroundColor3 = color
	b.Text = text
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextSize = 12
	b.Font = Enum.Font.SourceSans
	b.Parent = f2
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local itemButtons = {}
local function paintList()
	for m, b in pairs(itemButtons) do
		if m == my.selected then
			b.BackgroundColor3 = Color3.fromRGB(60, 140, 90)
		else
			b.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
		end
	end
	pickLabel.Text = "выбрано: " .. (my.selected and my.selected.Name or "-")
end

local function buildList()
	for _, b in pairs(itemButtons) do
		b:Destroy()
	end
	itemButtons = {}
	for i, m in ipairs(my.templates) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, -6, 0, 22)
		b.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
		b.Text = m.Name
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.TextSize = 11
		b.Font = Enum.Font.SourceSans
		b.LayoutOrder = i
		b.Parent = list
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
		b.MouseButton1Click:Connect(function()
			my.selected = m
			paintList()
			log("выбран самокат: " .. m.Name)
		end)
		itemButtons[m] = b
	end
	paintList()
end

local btnSpawn = makeBtn2("Спавнить рядом со мной", 202, Color3.fromRGB(60, 120, 190))
local btnRide  = makeBtn2("Сесть на мой", 228, Color3.fromRGB(60, 170, 90))
local btnDel   = makeBtn2("Удалить мой", 254, Color3.fromRGB(160, 70, 70))
local btnSpeed = makeBtn2("Скорость: x1", 280, Color3.fromRGB(140, 110, 50))

btnSpawn.MouseButton1Click:Connect(spawnNear)
btnRide.MouseButton1Click:Connect(rideMine)
btnDel.MouseButton1Click:Connect(deleteMine)
btnSpeed.MouseButton1Click:Connect(function()
	my.speedIdx = (my.speedIdx % #SPEED_STEPS) + 1
	speedCtrl.target = my.baseSpeed * SPEED_STEPS[my.speedIdx]
	btnSpeed.Text = "Скорость: x" .. SPEED_STEPS[my.speedIdx] .. " (" .. math.floor(speedCtrl.target) .. ")"
	log("скорость x" .. SPEED_STEPS[my.speedIdx] .. " = " .. math.floor(speedCtrl.target)
		.. " студ/с" .. (my.riding and " (мой)" or " (игровой)"))
end)

-- перетаскивание второго окна
local function makeDraggable(gf)
	local dragging, dragStart, startPos, dragInput
	gf.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = gf.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	gf.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			local delta = input.Position - dragStart
			gf.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
end
makeDraggable(f2)

refreshTemplates()
buildList()
log("окно САМИКИ готово. Выбери модель -> Спавнить рядом -> Сесть на мой, газ W.")

-- =========================================================
-- [9] СЕРВЕРНЫЙ СПАВН — чтобы самокат видели ВСЕ
--
--     Другие игроки видят только то, что создал СЕРВЕР. Локальный клон
--     (кнопка "Спавнить рядом") не увидит никто, кроме тебя — это факт,
--     его обойти нельзя. Значит надо вызвать игровой ремоут спавна
--     (SpawnScooter) — тогда сервер создаст настоящий самокат.
--
--     Две кнопки:
--       * "Лог ремоутов 20с" — ставит __namecall-хук на 20 секунд и пишет
--         все FireServer/InvokeServer. Сделай за это время в игре обычное
--         действие с самокатом (выбери/получи/сядь) — мы увидим ТОЧНЫЕ
--         аргументы, и я прикручу честный вызов. Хук безопасный: срабатывает
--         только на заранее собранном списке ремоутов и сам замолкает через
--         20 сек. Если исполнитель крашится от хуков — не жми эту кнопку.
--       * "Проба SpawnScooter" — без хуков вообще: дёргает ремоут спавна
--         с несколькими наборами аргументов и смотрит, появился ли самокат.
--         Ремоуты с purchase/buy в имени не трогаются никогда.
-- =========================================================
f2.Size = UDim2.new(0, 260, 0, 505)

local srvStatus = Instance.new("TextLabel")
srvStatus.Size = UDim2.new(0.95, 0, 0, 58)
srvStatus.Position = UDim2.new(0.025, 0, 0, 440)
srvStatus.BackgroundTransparency = 1
srvStatus.TextColor3 = Color3.fromRGB(200, 215, 225)
srvStatus.TextSize = 11
srvStatus.Font = Enum.Font.Code
srvStatus.TextXAlignment = Enum.TextXAlignment.Left
srvStatus.TextYAlignment = Enum.TextYAlignment.Top
srvStatus.TextWrapped = true
srvStatus.Text = "серверный спавн: жду"
srvStatus.Parent = f2

local btnSummon = makeBtn2("Призвать самокат ко мне", 306, Color3.fromRGB(60, 150, 140))
local btnReplay = makeBtn2("Повторить вызов серверу", 332, Color3.fromRGB(110, 130, 60))
local btnCap    = makeBtn2("Лог ремоутов 20 сек", 358, Color3.fromRGB(120, 80, 170))
local btnProbe  = makeBtn2("Проба SpawnScooter", 384, Color3.fromRGB(150, 110, 60))
local btnStopP  = makeBtn2("Стоп пробы", 410, Color3.fromRGB(140, 60, 60))

local function argsToStr(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, math.min(n, 4) do
		local v = select(i, ...)
		if typeof(v) == "Instance" then
			parts[#parts + 1] = v.ClassName .. ":" .. v.Name
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	if n > 4 then
		parts[#parts + 1] = "..."
	end
	return "(" .. table.concat(parts, ", ") .. ")"
end

-- набор ремоутов для супер-быстрой проверки в хуке
local remoteSet = setmetatable({}, { __mode = "k" })
local function addRemotes(container)
	if not container then return end
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			remoteSet[d] = true
		end
	end
end
addRemotes(ReplicatedStorage)
ReplicatedStorage.DescendantAdded:Connect(function(d)
	if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
		remoteSet[d] = true
	end
end)

local capture = { active = false, logging = false, calls = 0 }
local lastCall = nil   -- последний вызов ремоута самоката: {remote = ..., args = table.pack(...)}

local function isScooterRemote(name)
	local n = string.lower(tostring(name))
	return string.find(n, "scooter", 1, true) ~= nil
		or string.find(n, "spawn", 1, true) ~= nil
		or string.find(n, "mount", 1, true) ~= nil
		or string.find(n, "equip", 1, true) ~= nil
		or string.find(n, "wheelie", 1, true) ~= nil
end

local function startCapture(seconds)
	if capture.active then
		log("лог ремоутов уже идёт")
		return
	end
	local hf = gget("hookfunction")
	if type(hf) ~= "function" then
		log("нет hookfunction — в этом исполнителе лог ремоутов недоступен, жми Пробу")
		srvStatus.Text = "серверный спавн: хуки недоступны"
		return
	end

	local gnm = gget("getnamecallmethod")
	local orig

	local function hookFn(self, ...)
		if capture.logging and remoteSet[self] then
			local method = "?"
			pcall(function()
				if type(gnm) == "function" then
					method = gnm()
				end
			end)
			local full = "?"
			pcall(function() full = self:GetFullName() end)
			capture.calls += 1
			log("КЛИЕНТ>СЕРВЕР", full .. ":" .. tostring(method) .. argsToStr(...))
			-- запоминаем вызов на будущее: его можно будет повторить
			if isScooterRemote(self.Name) then
				local okPack, packed = pcall(function() return table.pack(...) end)
				if okPack and packed then
					lastCall = { remote = self, args = packed }
				end
			end
		end
		return orig(self, ...)
	end

	local getrmt = gget("getrawmetatable")
	local mt
	if type(getrmt) == "function" then
		local ok, m = pcall(getrmt, game)
		if ok then mt = m end
	end

	if mt and type(mt.__namecall) == "function" then
		local ok, res = pcall(hf, mt.__namecall, hookFn)
		if not ok then
			log("hookfunction не сработал: " .. tostring(res))
			srvStatus.Text = "серверный спавн: хук не встал"
			return
		end
		orig = res
	else
		local hmm = gget("hookmetamethod")
		if type(hmm) ~= "function" then
			log("нет hookmetamethod — лог ремоутов недоступен")
			srvStatus.Text = "серверный спавн: хуки недоступны"
			return
		end
		local ok, res = pcall(hmm, game, "__namecall", hookFn)
		if not ok then
			log("hookmetamethod не сработал: " .. tostring(res))
			srvStatus.Text = "серверный спавн: хук не встал"
			return
		end
		orig = res
	end

	capture.active = true
	capture.logging = true
	capture.calls = 0
	srvStatus.Text = "серверный спавн: пишу 20 сек, делай действие в игре"
	log("лог ремоутов ВКЛ на " .. seconds .. " сек")
	log("сделай в игре обычное действие: выбери самокат / получи его / сядь — а я увижу точный вызов")

	task.delay(seconds, function()
		capture.logging = false
		capture.active = false
		srvStatus.Text = "серверный спавн: записано " .. capture.calls .. " вызовов"
		log("лог ремоутов выключен (записано вызовов: " .. capture.calls .. ")")
		-- пробуем вернуть хук как было; если не выйдет — он прозрачный, ничего не делает
		if orig then
			local ok, err = pcall(hf, hookFn, orig)
			log(ok and "хук снят, вернул как было" or ("хук оставлен (прозрачный): " .. tostring(err)))
		end
	end)
end

local probe = { running = false, stopFlag = false }

local function remotesLike(pattern)
	local res = {}
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if (d:IsA("RemoteEvent") or d:IsA("RemoteFunction"))
			and string.find(string.lower(d.Name), pattern, 1, true) then
			res[#res + 1] = d
		end
	end
	return res
end

local function workspaceModelCount()
	local n = 0
	for _, o in ipairs(workspace:GetChildren()) do
		if o:IsA("Model") then n += 1 end
	end
	return n
end

local function probeSpawn()
	if probe.running then
		log("проба уже идёт")
		return
	end
	local targets = remotesLike("spawnscooter")
	if #targets == 0 then targets = remotesLike("spawn") end
	if #targets == 0 then
		log("проба: ремоут спавна не найден")
		srvStatus.Text = "серверный спавн: ремоут не найден"
		return
	end

	probe.running = true
	probe.stopFlag = false
	log("проба: ремоутов-целей " .. #targets .. ", покупки не трогаю")

	task.spawn(function()
		for _, r in ipairs(targets) do
			if probe.stopFlag then break end
			local low = string.lower(r.Name)
			if string.find(low, "purchase", 1, true) or string.find(low, "buy", 1, true) then
				log("проба: пропускаю " .. r.Name .. " (покупка — не рискуем деньгами)")
			else
				local trials = {
					{ "()", nil },
					{ "(true)", true },
					{ "(имя выбранной модели)", my.selected and my.selected.Name or "Scooter" },
					{ "(инстанс модели)", my.selected },
					{ "(игрок)", player },
					{ "(игрок, имя)", player, my.selected and my.selected.Name or "Scooter" },
				}
				local isFunc = false
				pcall(function() isFunc = r:IsA("RemoteFunction") end)
				for _, t in ipairs(trials) do
					if probe.stopFlag then break end
					local before = workspaceModelCount()
					local a1, a2 = t[2], t[3]
					local ok, err = pcall(function()
						if isFunc then
							if a2 ~= nil then
								r:InvokeServer(a1, a2)
							elseif a1 ~= nil then
								r:InvokeServer(a1)
							else
								r:InvokeServer()
							end
						else
							if a2 ~= nil then
								r:FireServer(a1, a2)
							elseif a1 ~= nil then
								r:FireServer(a1)
							else
								r:FireServer()
							end
						end
					end)
					task.wait(1.5)
					local after = workspaceModelCount()
					log(string.format("проба %s %s -> %s | моделей в workspace %d -> %d | на самокате: %s",
						r.Name, t[1], ok and "отправлено" or ("ошибка: " .. tostring(err)),
						before, after, tostring(isMounted())))
				end
			end
		end
		probe.running = false
		srvStatus.Text = "серверный спавн: проба завершена"
		log("проба завершена")
	end)
end

-- =========================================================
-- ПРИЗЫВ: телепортировать самокат к себе
-- Если сетевой владелец модели — ты, перемещение уходит на сервер
-- через физику, и его видят ВСЕ. Это самый рабочий путь без хуков.
-- =========================================================
local function isScooterName(name)
	local n = string.lower(tostring(name))
	if string.find(n, "decor", 1, true) then return false end
	if string.find(n, "kukirin", 1, true) then return true end
	if string.find(n, "scoot", 1, true) then return true end
	for _, t in ipairs(my.templates) do
		if string.lower(t.Name) == n then return true end
	end
	return false
end

local function collectWorldScooters()
	local res = {}
	local function scan(container, depth)
		for _, o in ipairs(container:GetChildren()) do
			if o:IsA("Model") and isScooterName(o.Name) then
				res[#res + 1] = o
			elseif depth < 1 and (o:IsA("Model") or o:IsA("Folder")) then
				scan(o, depth + 1)
			end
		end
	end
	scan(workspace, 0)
	return res
end

local function networkOwnerName(model)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local ok, owner = pcall(function() return p:GetNetworkOwner() end)
			if ok then
				if owner then return owner.Name end
				return "сервер"
			end
		end
	end
	return "?"
end

local function summonScooter()
	if not (root and root.Parent) then return end
	local all = collectWorldScooters()
	local list = {}
	for _, m in ipairs(all) do
		if not my.clones[m] then
			list[#list + 1] = m
		end
	end
	if #list == 0 then
		log("призыв: в workspace не нашёл ни одной модели самоката")
		srvStatus.Text = "призыв: рядом нет моделей самокатов"
		return
	end

	local best, bestD
	for _, m in ipairs(list) do
		local ok, cf = pcall(function() return m:GetPivot() end)
		if ok and cf then
			local d = (cf.Position - root.Position).Magnitude
			if not bestD or d < bestD then
				bestD, best = d, m
			end
		end
	end
	if not best then return end

	local owner = networkOwnerName(best)
	local mineBy = string.find(string.lower(best.Name), string.lower(player.Name), 1, true) ~= nil
	log(string.format("призыв: %s (%s, %.0f студов) | сетевой владелец: %s",
		best.Name, mineBy and "по имени твой" or "чужой", bestD or -1, owner))
	if owner == player.Name then
		log("призыв: владелец ты — перемещение уйдёт на сервер, его увидят ВСЕ")
	else
		log("призыв: владелец не ты — сервер может откатить, тогда увидишь только ты")
	end

	local deck = root.CFrame * CFrame.new(0, 3, 0)
	local ok, err = pcall(function()
		best:PivotTo(deck)
		for _, p in ipairs(best:GetDescendants()) do
			if p:IsA("BasePart") then
				p.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				p.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
			end
		end
	end)
	log(ok and "призыв: самокат перемещён под тебя" or ("призыв: не вышло — " .. tostring(err)))
	srvStatus.Text = string.format("призыв: %s | владелец: %s", best.Name, owner)
end

-- =========================================================
-- ПОВТОР ВЫЗОВА НА СЕРВЕР
--     Это буквально "отправить на сервер то же, что отправил сам
--     скутер-клиент": мы записали вызов хуком и шлём его снова.
--     Покупки (purchase/buy) повторять нельзя — это тратит деньги.
-- =========================================================
local function replayLastCall()
	if not lastCall then
		log("повтор: ничего не записано — сначала нажми Лог ремоутов 20 сек и сделай действие")
		srvStatus.Text = "повтор: нечего повторять"
		return
	end
	local r = lastCall.remote
	if not (r and r.Parent) then
		log("повтор: ремоут уже не существует")
		return
	end
	local low = string.lower(r.Name)
	if string.find(low, "purchase", 1, true) or string.find(low, "buy", 1, true) or string.find(low, "redeem", 1, true) then
		log("повтор: " .. r.Name .. " — это покупка, повторять не буду (списывает деньги)")
		return
	end

	local n = lastCall.args.n or #lastCall.args
	local ok, err = pcall(function()
		if r:IsA("RemoteFunction") then
			r:InvokeServer(table.unpack(lastCall.args, 1, n))
		else
			r:FireServer(table.unpack(lastCall.args, 1, n))
		end
	end)
	log(string.format("повтор %s%s -> %s", r.Name, argsToStr(table.unpack(lastCall.args, 1, n)),
		ok and "отправлено" or ("ошибка: " .. tostring(err))))
	srvStatus.Text = "повтор: " .. r.Name .. (ok and " отправлен" or " ошибка")
end

btnSummon.MouseButton1Click:Connect(summonScooter)
btnReplay.MouseButton1Click:Connect(replayLastCall)
btnCap.MouseButton1Click:Connect(function()
	startCapture(20)
end)
btnProbe.MouseButton1Click:Connect(probeSpawn)
btnStopP.MouseButton1Click:Connect(function()
	probe.stopFlag = true
	capture.logging = false
	log("остановлено вручную")
end)

-- =========================================================
-- [10] ОКНО "СКОРОСТЬ": любое число, применяется тремя способами
--   игра перезаписывает физику каждый кадр, поэтому делаем разом:
--     1) LinearVelocity (тяга) — держит скорость на каждом физшаге;
--     2) AssemblyLinearVelocity — прямое задание скорости всем сборкам;
--     3) жёсткий режим — каждый кадр двигаем саму модель.
-- =========================================================
local gui3 = Instance.new("ScreenGui")
gui3.Name = "SpeedGui"
gui3.ResetOnSpawn = false
gui3.Parent = player:WaitForChild("PlayerGui")

local f3 = Instance.new("Frame")
f3.Size = UDim2.new(0, 235, 0, 205)
f3.Position = UDim2.new(0, 20, 0, 440)
f3.BackgroundColor3 = Color3.fromRGB(28, 24, 32)
f3.BorderSizePixel = 0
f3.Active = true
f3.Parent = gui3
Instance.new("UICorner", f3).CornerRadius = UDim.new(0, 8)

local t3 = Instance.new("TextLabel")
t3.Size = UDim2.new(1, 0, 0, 22)
t3.BackgroundTransparency = 1
t3.Text = "★ СКОРОСТЬ (любое число) ★"
t3.TextColor3 = Color3.fromRGB(255, 220, 160)
t3.TextSize = 12
t3.Font = Enum.Font.SourceSansBold
t3.Parent = f3

local box = Instance.new("TextBox")
box.Size = UDim2.new(0.54, 0, 0, 24)
box.Position = UDim2.new(0.04, 0, 0, 24)
box.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
box.TextColor3 = Color3.fromRGB(255, 255, 255)
box.TextSize = 12
box.Font = Enum.Font.Code
box.Text = "300"
box.ClearTextOnFocus = false
box.Parent = f3
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

local applyB = Instance.new("TextButton")
applyB.Size = UDim2.new(0.36, 0, 0, 24)
applyB.Position = UDim2.new(0.6, 0, 0, 24)
applyB.BackgroundColor3 = Color3.fromRGB(60, 120, 190)
applyB.Text = "Применить"
applyB.TextColor3 = Color3.fromRGB(255, 255, 255)
applyB.TextSize = 12
applyB.Parent = f3
Instance.new("UICorner", applyB).CornerRadius = UDim.new(0, 6)

local function applyBox()
	local v = tonumber(box.Text)
	if not v then
		box.Text = tostring(speedCtrl.target)
		log("скорость: это не число")
		return
	end
	if v < 0 then v = 0 end
	if v > MAX_SPEED then v = MAX_SPEED end
	speedCtrl.target = v
	box.Text = tostring(v)
	log("скорость поставлена: " .. tostring(v) .. " студ/с")
end
applyB.MouseButton1Click:Connect(applyBox)
box.FocusLost:Connect(applyBox)

local function mkb(text, x, y, w, color, onClick)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(w, 0, 0, 22)
	b.Position = UDim2.new(x, 0, 0, y)
	b.BackgroundColor3 = color
	b.Text = text
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextSize = 11
	b.Font = Enum.Font.SourceSans
	b.Parent = f3
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
	if onClick then b.MouseButton1Click:Connect(onClick) end
	return b
end

local green3 = Color3.fromRGB(50, 180, 80)
local red3 = Color3.fromRGB(180, 60, 60)

local bLin = mkb("Тяга: ВКЛ", 0.04, 54, 0.44, green3, function()
	speedCtrl.useLinear = not speedCtrl.useLinear
	bLin.Text = "Тяга: " .. (speedCtrl.useLinear and "ВКЛ" or "ВЫКЛ")
	bLin.BackgroundColor3 = speedCtrl.useLinear and green3 or red3
end)

local bHard = mkb("Жёстко: ВКЛ", 0.52, 54, 0.44, green3, function()
	speedCtrl.hardMode = not speedCtrl.hardMode
	bHard.Text = "Жёстко: " .. (speedCtrl.hardMode and "ВКЛ" or "ВЫКЛ")
	bHard.BackgroundColor3 = speedCtrl.hardMode and green3 or red3
end)

local bAuto = mkb("Авто-газ: ВЫКЛ", 0.04, 80, 0.44, red3, function()
	speedCtrl.autoDrive = not speedCtrl.autoDrive
	bAuto.Text = "Авто-газ: " .. (speedCtrl.autoDrive and "ВКЛ" or "ВЫКЛ")
	bAuto.BackgroundColor3 = speedCtrl.autoDrive and green3 or red3
end)

local bClr = mkb("Снять тягу", 0.52, 80, 0.44, Color3.fromRGB(120, 90, 60), function()
	local model = (my.riding and my.riding.Parent) and my.riding or findScooterModel()
	if model then
		removeDrive(model)
		log("тяга снята с " .. model.Name)
	end
end)

local mults = { 1, 2, 5, 10 }
for i, mult in ipairs(mults) do
	mkb("x" .. mult, 0.04 + (i - 1) * 0.24, 106, 0.2, Color3.fromRGB(70, 70, 90), function()
		speedCtrl.target = my.baseSpeed * mult
		box.Text = tostring(speedCtrl.target)
		log("скорость x" .. mult .. " = " .. tostring(speedCtrl.target))
	end)
end

local st3 = Instance.new("TextLabel")
st3.Size = UDim2.new(0.92, 0, 0, 40)
st3.Position = UDim2.new(0.04, 0, 0, 134)
st3.BackgroundTransparency = 1
st3.TextColor3 = Color3.fromRGB(215, 220, 225)
st3.TextSize = 11
st3.Font = Enum.Font.Code
st3.TextXAlignment = Enum.TextXAlignment.Left
st3.TextYAlignment = Enum.TextYAlignment.Top
st3.TextWrapped = true
st3.Text = ""
st3.Parent = f3

task.spawn(function()
	while true do
		local model = (my.riding and my.riding.Parent) and my.riding
			or ((scooterModel and scooterModel.Parent) and scooterModel)
			or findScooterModel()
		st3.Text = string.format("цель: %d | сейчас: %d\nметод: %s\nвладелец: %s",
			speedInfo.asked, speedInfo.real, tostring(speedInfo.mode),
			model and ownerOf(model) or "-")
		task.wait(0.25)
	end
end)

makeDraggable(f3)
log("окно СКОРОСТЬ готово: впиши любое число (например 300 или 1500) и жми Применить")
log("если скорость всё равно падает — включи Авто-газ и проверь владельца в окне")

log("готово: Призвать самокат | Повторить вызов | Лог ремоутов 20с | Проба SpawnScooter")
log("подсказка: сетевой владелец виден в логе призыва — если владелец ты, движение самоката уходит на сервер и его видят все")
