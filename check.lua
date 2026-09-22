--[[ =============================================================
     ANTI-FALL DIAGNOSTIC v1
     Без хуков метатаблиц (по умолчанию). Только безопасные подключения.

     ЧТО СОБИРАЕТ:
       1. ВСЁ, что сервер отправляет клиенту через ScooterRemotes
          (OnClientEvent) — именно здесь видно решение сервера об аварии.
       2. Каждую смену состояния Humanoid и изменения PlatformStand / Sit /
          HipHeight / WalkSpeed / JumpPower / AutoRotate / Health.
       3. Какие скрипты Scooter включаются и выключаются.
       4. Когда персонаж упал/встал — полный "разбор полёта": состояние,
          положение, расстояние до самоката, кто выключен.
       5. Кнопка "ПЕРЕХВАТ" — ловит исходящие FireServer из игры
          (ВКЛЮЧАЙ ОТДЕЛЬНО: у тебя были краши из-за хуков).
       6. Кнопка "КОПИРОВАТЬ" — кладёт весь лог в буфер обмена.

     КАК ПОЛЬЗОВАТЬСЯ:
       - запустить, нажать "СБРОС" (очистить лог),
       - поехать и сделать стант, во время которого роняет,
       - после падения остановиться и нажать "КОПИРОВАТЬ",
       - прислать сюда лог (или строки из F9 с префиксом [DIAG]).
     ============================================================= ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local START = os.clock()

-- среда исполнения (у разных исполнителей разная)
local env = _G
pcall(function()
	if getfenv then
		env = getfenv(0)
	end
end)
local function gget(name)
	local v = rawget(env, name)
	if v == nil then
		v = rawget(_G, name)
	end
	return v
end

--=============================================================
-- ЛОГ
--=============================================================
local lines = {}
local MAX_LINES = 400
local logBox, scroller

local function write(tag, text)
	local line = string.format("%8.2f | %-14s | %s", os.clock() - START, tag, text)
	table.insert(lines, line)
	if #lines > MAX_LINES then
		table.remove(lines, 1)
	end
	print("[DIAG] " .. line)
	if logBox then
		logBox.Text = table.concat(lines, "\n")
		task.defer(function()
			if scroller then
				local low = scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y
				scroller.CanvasPosition = Vector2.new(0, math.max(0, low))
			end
		end)
	end
end

--=============================================================
-- КРАСИВЫЙ ВЫВОД ЗНАЧЕНИЙ
--=============================================================
local val
val = function(v)
	local t = typeof(v)
	if t == "Instance" then
		return v.ClassName .. " '" .. v.Name .. "'"
	elseif t == "string" then
		return "'" .. string.sub(v, 1, 40) .. "'"
	elseif t == "table" then
		local ok, res = pcall(function()
			local parts = {}
			for i, x in ipairs(v) do
				if i > 4 then
					parts[#parts + 1] = "..."
					break
				end
				parts[#parts + 1] = val(x)
			end
			return table.concat(parts, ", ")
		end)
		return "{" .. (ok and res or "?") .. "}"
	end
	return tostring(v)
end

local function argsStr(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, math.min(n, 6) do
		parts[#parts + 1] = val((select(i, ...)))
	end
	if n > 6 then
		parts[#parts + 1] = "..."
	end
	return "(" .. table.concat(parts, ", ") .. ")"
end

--=============================================================
-- ПОИСК САМОКАТА И РАЗБОР СИТУАЦИИ
--=============================================================
local function scooterOf()
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj ~= player.Character then
			local n = obj.Name:lower()
			if n:find("scooter", 1, true) or obj.Name:find(player.Name, 1, true) then
				return obj
			end
		end
	end
	return nil
end

local function dumpSituation(reason)
	write("!!!", "=========== РАЗБОР: " .. reason .. " ===========")
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")

	if hum then
		write("!!!", string.format(
			"Humanoid: state=%s PlatformStand=%s Sit=%s HipHeight=%.2f WS=%.1f JP=%.1f AutoRotate=%s Eval=%s",
			tostring(hum:GetState()), tostring(hum.PlatformStand), tostring(hum.Sit),
			hum.HipHeight, hum.WalkSpeed, hum.JumpPower,
			tostring(hum.AutoRotate), tostring(hum.EvaluateStateMachine)))
	end

	local sc = scooterOf()
	if sc then
		write("!!!", string.format("самокат: %s (%s, детей %d)", sc:GetFullName(), sc.ClassName, #sc:GetChildren()))
		local seat = sc:FindFirstChildWhichIsA("Seat", true)
		if seat then
			local occ = seat.Occupant
			write("!!!", "  сиденье: " .. seat:GetFullName() .. " Occupant=" .. (occ and occ.Parent.Name or "nil"))
		else
			write("!!!", "  сиденья (Seat) внутри самоката нет")
		end
		if hrp then
			write("!!!", string.format("  дистанция до самоката: %.1f студов",
				(hrp.Position - sc:GetPivot().Position).Magnitude))
		end
	else
		write("!!!", "самокат в workspace НЕ найден (возможно, он внутри папки или уже пропал)")
	end

	if hrp then
		local v = hrp.AssemblyLinearVelocity
		write("!!!", string.format("HRP: pos=(%.0f, %.0f, %.0f)  vel=%.1f (Y=%.1f)  parent=%s",
			hrp.Position.X, hrp.Position.Y, hrp.Position.Z, v.Magnitude, v.Y, tostring(char.Parent)))
	end

	local off, on = {}, {}
	local root = player:FindFirstChild("PlayerScripts")
	if root then
		for _, s in ipairs(root:GetDescendants()) do
			if s:IsA("BaseScript") then
				if s.Disabled then
					off[#off + 1] = s.Name
				elseif s.Name:lower():find("crash", 1, true) or s.Name:lower():find("scooter", 1, true) then
					on[#on + 1] = s.Name
				end
			end
		end
	end
	write("!!!", "ВЫКЛЮЧЕНЫ: " .. (#off > 0 and table.concat(off, ", ") or "нет"))
	write("!!!", "работают (crash/scooter): " .. (#on > 0 and table.concat(on, ", ") or "нет"))
	write("!!!", "=========== /РАЗБОР ===========")
end

--=============================================================
-- ГУМАНОИД: СОСТОЯНИЯ И СВОЙСТВА
--=============================================================
local WATCH = {
	PlatformStand = true, Sit = true, SeatPart = true, HipHeight = true, WalkSpeed = true,
	JumpPower = true, AutoRotate = true, EvaluateStateMachine = true, Health = true,
}

local watchedHum
local function watchCharacter(char)
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum or hum == watchedHum then
		return
	end
	watchedHum = hum
	write("ПЕРСОНАЖ", "подключился к Humanoid (" .. char.Name .. ")")

	hum.StateChanged:Connect(function(old, new)
		write("СОСТОЯНИЕ", string.format("%s -> %s   [PlatformStand=%s HipHeight=%.2f]",
			tostring(old), tostring(new), tostring(hum.PlatformStand), hum.HipHeight))
		if new == Enum.HumanoidStateType.Ragdoll
			or new == Enum.HumanoidStateType.FallingDown
			or new == Enum.HumanoidStateType.PlatformStanding then
			dumpSituation("переход в " .. tostring(new))
		end
	end)

	local lastProp = {}
	hum.Changed:Connect(function(prop)
		if WATCH[prop] then
			local now = val(hum[prop])
			if lastProp[prop] == now then
				return
			end
			lastProp[prop] = now
			write("СВОЙСТВО", prop .. " = " .. now)
			if prop == "PlatformStand" and hum.PlatformStand then
				dumpSituation("кто-то поставил PlatformStand = true")
			end
		end
	end)
end

if player.Character then
	watchCharacter(player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

--=============================================================
-- ЧТО СЕРВЕР ПРИСЫЛАЕТ КЛИЕНТУ (главное!)
--=============================================================
local spied = {}
local function spyRemote(r)
	if spied[r] then
		return
	end
	spied[r] = true
	if r:IsA("RemoteEvent") or r.ClassName == "UnreliableRemoteEvent" then
		r.OnClientEvent:Connect(function(...)
			write("СЕРВЕР>КЛИЕНТ", r.Name .. argsStr(...))
		end)
	elseif r:IsA("RemoteFunction") then
		local old = r.OnClientInvoke
		r.OnClientInvoke = function(...)
			write("СЕРВЕР>КЛИЕНТ", r.Name .. ":Invoke" .. argsStr(...))
			if old then
				return old(...)
			end
		end
	end
end

local function spyAllIn(container)
	if not container then
		return
	end
	for _, r in ipairs(container:GetChildren()) do
		if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") then
			spyRemote(r)
		end
	end
	container.DescendantAdded:Connect(function(r)
		if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") then
			spyRemote(r)
		end
	end)
end

local scooterRemotes = ReplicatedStorage:FindFirstChild("ScooterRemotes")
spyAllIn(scooterRemotes)
spyAllIn(ReplicatedStorage:FindFirstChild("GiftRemotes"))
spyAllIn(ReplicatedStorage:FindFirstChild("HouseRemotes"))
spyAllIn(ReplicatedStorage:FindFirstChild("LiveEvents"))
write("РЕМОУТ", "слушаю " .. (scooterRemotes and ("ScooterRemotes, детей " .. #scooterRemotes:GetChildren()) or "ScooterRemotes НЕ НАЙДЕН"))

--=============================================================
-- СКРИПТЫ: КТО ВКЛЮЧАЕТСЯ / ВЫКЛЮЧАЕТСЯ
--=============================================================
local function watchScript(s)
	if s:IsA("BaseScript") then
		s.Changed:Connect(function(p)
			if p == "Disabled" then
				write("СКРИПТ", s:GetFullName() .. " -> Disabled = " .. tostring(s.Disabled))
			end
		end)
	end
end

local scriptsRoot = player:FindFirstChild("PlayerScripts")
if scriptsRoot then
	for _, s in ipairs(scriptsRoot:GetDescendants()) do
		watchScript(s)
	end
	scriptsRoot.DescendantAdded:Connect(watchScript)
end

--=============================================================
-- АТРИБУТЫ (игры часто пишут туда фазу аварии)
--=============================================================
local function watchAttrs(inst, label)
	inst.AttributeChanged:Connect(function(name)
		write("АТРИБУТ", label .. "." .. tostring(name) .. " = " .. val(inst:GetAttribute(name)))
	end)
end
watchAttrs(player, "player")
if player.Character then
	watchAttrs(player.Character, "Character")
end
player.CharacterAdded:Connect(function(c)
	watchAttrs(c, "Character")
	c:GetPropertyChangedSignal("Parent"):Connect(function()
		write("ПЕРСОНАЖ", "Character.Parent = " .. tostring(c.Parent))
	end)
end)

--=============================================================
-- WORKSPACE: самокат пропал / пересоздался / появилось новое
--=============================================================
local srvScripts = nil
workspace.ChildAdded:Connect(function(c)
	write("WORKSPACE+", c.ClassName .. " '" .. c.Name .. "'")
	if c:IsA("Seat") then
		c:GetPropertyChangedSignal("Occupant"):Connect(function()
			write("СИДЕНЬЕ", c:GetFullName() .. ".Occupant = " .. (c.Occupant and c.Occupant.Parent and c.Occupant.Parent.Name or "nil"))
		end)
	end
end)
workspace.ChildRemoved:Connect(function(c)
	write("WORKSPACE-", c.ClassName .. " '" .. c.Name .. "'")
end)

-- следим за всеми Seat, которые есть сейчас, и за Occupant
local function watchSeat(seat)
	if not seat:IsA("Seat") then
		return
	end
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		write("СИДЕНЬЕ", seat:GetFullName() .. ".Occupant = " .. (seat.Occupant and seat.Occupant.Parent and seat.Occupant.Parent.Name or "nil"))
	end)
end
for _, d in ipairs(workspace:GetDescendants()) do
	watchSeat(d)
end
workspace.DescendantAdded:Connect(watchSeat)

--=============================================================
-- GUI
--=============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AntiFallDiag"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 460, 0, 320)
frame.Position = UDim2.new(0, 20, 0, 80)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -150, 0, 26)
title.BackgroundTransparency = 1
title.Text = "  ★ ANTI-FALL DIAGNOSTIC ★"
title.TextColor3 = Color3.fromRGB(255, 220, 120)
title.TextSize = 13
title.Font = Enum.Font.SourceSansBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local function makeButton(text, x, width)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, width, 0, 22)
	b.Position = UDim2.new(0, x, 0, 3)
	b.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextSize = 12
	b.Font = Enum.Font.SourceSans
	b.Text = text
	b.Parent = frame
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
	return b
end

local btnCopy = makeButton("КОПИР. F8", 232, 96)
local btnIntercept = makeButton("ПЕРЕХВАТ", 332, 76)
local btnClear = makeButton("СБРОС F7", 412, 44)

scroller = Instance.new("ScrollingFrame")
scroller.Size = UDim2.new(1, -12, 1, -34)
scroller.Position = UDim2.new(0, 6, 0, 30)
scroller.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
scroller.BorderSizePixel = 0
scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroller.CanvasSize = UDim2.new(0, 0, 0, 0)

logBox = Instance.new("TextLabel")
logBox.Size = UDim2.new(1, -10, 0, 0)
logBox.Position = UDim2.new(0, 5, 0, 4)
logBox.BackgroundTransparency = 1
logBox.AutomaticSize = Enum.AutomaticSize.Y
logBox.TextWrapped = true
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextColor3 = Color3.fromRGB(210, 230, 210)
logBox.TextSize = 12
logBox.Font = Enum.Font.Code
logBox.Text = ""
logBox.Parent = scroller

local function clearLog()
	lines = {}
	logBox.Text = ""
	print("[DIAG] --- лог очищен ---")
end

local function doCopy()
	local text = table.concat(lines, "\n")
	local fn = gget("setclipboard") or gget("toClipboard") or gget("set_clipboard")
	if type(fn) ~= "function" then
		fn = nil
	end
	if fn then
		local ok = pcall(fn, text)
		write("КОПИЯ", ok and "лог скопирован в буфер (" .. #lines .. " строк)" or "не удалось скопировать")
	else
		write("КОПИЯ", "нет setclipboard — смотри консоль (F9)")
	end
end

btnClear.MouseButton1Click:Connect(clearLog)
btnCopy.MouseButton1Click:Connect(doCopy)

-- горячие клавиши: F8 — копировать, F7 — сброс (мышью во время станта не удобно)
game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F8 then
		doCopy()
	elseif input.KeyCode == Enum.KeyCode.F7 then
		clearLog()
	end
end)

--=============================================================
-- ПЕРЕХВАТ ИСХОДЯЩИХ (по кнопке, может крашить)
--=============================================================
local interceptOn = false
local function enableIntercept()
	if interceptOn then
		return
	end
	local hookmm = gget("hookmetamethod")
	local getMethod = gget("getnamecallmethod")
	if type(hookmm) ~= "function" or type(getMethod) ~= "function" then
		write("ПЕРЕХВАТ", "нет hookmetamethod / getnamecallmethod — не поддерживается")
		return
	end
	local ok, err = pcall(function()
		local old
		old = hookmm(game, "__namecall", function(self, ...)
			local ok3, method = pcall(getMethod)
			if not ok3 then
				method = nil
			end
			if (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" then
				local ok2, isRemote = pcall(function()
					return self:IsDescendantOf(ReplicatedStorage)
				end)
				if ok2 and isRemote then
					write("КЛИЕНТ>СЕРВЕР", self.Name .. ":" .. method .. argsStr(...))
				end
			end
			return old(self, ...)
		end)
	end)
	interceptOn = ok
	if ok then
		write("ПЕРЕХВАТ", "включён: пишу все FireServer/InvokeServer в ReplicatedStorage")
		btnIntercept.BackgroundColor3 = Color3.fromRGB(60, 150, 70)
	else
		write("ПЕРЕХВАТ", "ошибка: " .. tostring(err))
	end
end

btnIntercept.MouseButton1Click:Connect(enableIntercept)

-- перетаскивание
local dragging, dragStart, startPos, dragInput
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
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
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)
game:GetService("UserInputService").InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

--=============================================================
-- СТАРТ
--=============================================================
write("СТАРТ", "диагностика запущена")
write("СТАРТ", "Remotes: " .. (scooterRemotes and tostring(#scooterRemotes:GetChildren()) or "нет") .. " | PlayerScripts: " .. (scriptsRoot and tostring(#scriptsRoot:GetDescendants()) or "нет"))
dumpSituation("стартовое состояние")
