--[[
    ★ Anti-Looped Out ★ — МИНИМАЛЬНАЯ ВЕРСИЯ (без хуков)

    Причина прошлых крашей — hookmetamethod. В этой версии его НЕТ вовсе.
    Осталось только:
      1. Отключение клиентских скриптов аварии (CrashFallClient и т.п.)
      2. Блокировка состояний Ragdoll / FallingDown у гуманоида
      3. Мгновенный подъём через StateChanged
    PlatformStanding не трогаем — игра использует его для езды на самокате.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local enabled = false

-- =========================================================
-- ОТКЛЮЧЕНИЕ СКРИПТОВ АВАРИИ
-- =========================================================
local SCRIPT_KEYWORDS = { "crash", "fall", "ragdoll", "wipeout" }

local function isCrashScript(inst)
	if not (inst:IsA("LocalScript") or inst:IsA("Script")) then return false end
	local n = inst.Name:lower()
	for _, kw in ipairs(SCRIPT_KEYWORDS) do
		if n:find(kw, 1, true) then
			return true
		end
	end
	return false
end

local function applyScriptBlocking()
	local ps = player:FindFirstChild("PlayerScripts")
	if not ps then return end
	for _, d in ipairs(ps:GetDescendants()) do
		if isCrashScript(d) then
			pcall(function()
				d.Disabled = enabled
			end)
		end
	end
end

-- =========================================================
-- БЛОКИРОВКА СОСТОЯНИЙ ПАДЕНИЯ
-- =========================================================
local humanoidConnection = nil

local function cleanupHumanoid()
	if humanoidConnection then
		humanoidConnection:Disconnect()
		humanoidConnection = nil
	end
end

local function setupHumanoid(character)
	cleanupHumanoid()
	local humanoid = character:WaitForChild("Humanoid", 15)
	if not humanoid then return end

	-- задаём один раз при спавне, не в цикле
	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	end)

	humanoidConnection = humanoid.StateChanged:Connect(function(_, new)
		if not enabled then return end
		if new == Enum.HumanoidStateType.Ragdoll
			or new == Enum.HumanoidStateType.FallingDown then
			task.defer(function()
				if humanoid.Parent then
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
			end)
		end
	end)
end

if player.Character then
	setupHumanoid(player.Character)
end
player.CharacterAdded:Connect(setupHumanoid)

-- =========================================================
-- GUI
-- =========================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AntiFallGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 190, 0, 85)
frame.Position = UDim2.new(0.5, -95, 0.3, 0)
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
title.Text = "★ Anti-Looped Out ★"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 13
title.Font = Enum.Font.SourceSansBold
title.Parent = frame

local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0.85, 0, 0, 35)
toggleBtn.Position = UDim2.new(0.075, 0, 0.45, 0)
toggleBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
toggleBtn.Text = "Анти-падение: ВЫКЛ"
toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleBtn.TextSize = 13
toggleBtn.Font = Enum.Font.SourceSans
toggleBtn.Parent = frame

local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(0, 6)
btnCorner.Parent = toggleBtn

-- =========================================================
-- ПЕРЕТАСКИВАНИЕ GUI
-- =========================================================
local dragging = false
local dragInput = nil
local dragStart = nil
local startPos = nil

local function update(input)
	local delta = input.Position - dragStart
	frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
		startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end

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

local uis = game:GetService("UserInputService")
uis.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		update(input)
	end
end)

-- =========================================================
-- ВКЛЮЧЕНИЕ / ВЫКЛЮЧЕНИЕ
-- =========================================================
toggleBtn.MouseButton1Click:Connect(function()
	enabled = not enabled
	if enabled then
		applyScriptBlocking()
		toggleBtn.Text = "Анти-падение: ВКЛ"
		toggleBtn.BackgroundColor3 = Color3.fromRGB(50, 200, 80)
	else
		applyScriptBlocking()
		toggleBtn.Text = "Анти-падение: ВЫКЛ"
		toggleBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	end
end)
