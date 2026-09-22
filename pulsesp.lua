--[[
    ══ Pulse Hub - Murder Mystery 2 & General ESP ══
    Извлеченный и доработанный скрипт ESP в стиле Pulse Hub
    Поддерживает: Delta, Solara, Wave, Hydrogen, Macsploit и др.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- Настройки ESP
local Settings = {
    Enabled = true,
    PlayerESP = true,
    Chams = true,
    Nametags = true,
    GunESP = true,
    Tracers = false,
    ShowDistance = true,
    ShowHealth = true,
    ShowRole = true,
}

-- Цветовая палитра Pulse Hub
local Colors = {
    Murderer = Color3.fromRGB(255, 50, 75),   -- Красный
    Sheriff  = Color3.fromRGB(50, 150, 255),  -- Синий
    Hero     = Color3.fromRGB(255, 215, 0),   -- Золотой
    Innocent = Color3.fromRGB(50, 230, 120),  -- Зеленый
    GunDrop  = Color3.fromRGB(255, 215, 0)    -- Желтый/Золотой
}

-- Хранилище созданных GUI-элементов
local Cache = {
    Players = {},
    Gun = nil,
    Tracers = {}
}

--------------------------------------------------------------------------------
-- 1. Определение Ролей (MM2 Role Detector)
--------------------------------------------------------------------------------
local function GetPlayerRole(player)
    if not player or not player.Character then return "Innocent" end

    local character = player.Character
    local backpack = player:FindFirstChildOfClass("Backpack")

    local function checkItem(item)
        if not item or not item:IsA("Tool") then return nil end
        local name = item.Name:lower()
        if name:find("knife") or name:find("slash") or name:find("blade") or name:find("scythe") or name:find("dagger") then
            return "Murderer"
        elseif name:find("gun") or name:find("revolver") or name:find("pistol") or name:find("blaster") or name:find("luger") then
            return "Sheriff"
        end
        return nil
    end

    -- 1. Проверяем экипированное оружие
    for _, item in ipairs(character:GetChildren()) do
        local role = checkItem(item)
        if role then return role end
    end

    -- 2. Проверяем рюкзак (Backpack)
    if backpack then
        for _, item in ipairs(backpack:GetChildren()) do
            local role = checkItem(item)
            if role then return role end
        end
    end

    return "Innocent"
end

local function GetRoleColor(role)
    return Colors[role] or Colors.Innocent
end

--------------------------------------------------------------------------------
-- 2. Логика ESP для Игроков (Chams + Nametags + Tracers)
--------------------------------------------------------------------------------
local function ClearPlayerESP(player)
    if Cache.Players[player] then
        local data = Cache.Players[player]
        if data.Highlight then data.Highlight:Destroy() end
        if data.Billboard then data.Billboard:Destroy() end
        if data.Tracer then data.Tracer:Remove() end
        Cache.Players[player] = nil
    end
end

local function CreatePlayerESP(player)
    if player == LocalPlayer then return end

    local function ApplyESP()
        ClearPlayerESP(player)

        local character = player.Character
        if not character then return end

        local rootPart = character:FindFirstChild("HumanoidRootPart")
        local head = character:FindFirstChild("Head")
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not rootPart or not head or not humanoid then return end

        local role = GetPlayerRole(player)
        local roleColor = GetRoleColor(role)

        -- 1. Highlight (Chams)
        local highlight = Instance.new("Highlight")
        highlight.Name = "Pulse_Chams"
        highlight.Adornee = character
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.FillColor = roleColor
        highlight.OutlineColor = roleColor
        highlight.FillTransparency = 0.45
        highlight.OutlineTransparency = 0
        highlight.Enabled = Settings.Enabled and Settings.PlayerESP and Settings.Chams
        highlight.Parent = CoreGui

        -- 2. BillboardGui (Nametag + Info)
        local bb = Instance.new("BillboardGui")
        bb.Name = "Pulse_Nametag"
        bb.Adornee = head
        bb.Size = UDim2.fromOffset(150, 45)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
        bb.AlwaysOnTop = true
        bb.Enabled = Settings.Enabled and Settings.PlayerESP and Settings.Nametags
        bb.Parent = CoreGui

        local titleLabel = Instance.new("TextLabel")
        titleLabel.Size = UDim2.new(1, 0, 0.5, 0)
        titleLabel.BackgroundTransparency = 1
        titleLabel.Font = Enum.Font.GothamBold
        titleLabel.TextSize = 13
        titleLabel.TextColor3 = roleColor
        titleLabel.TextStrokeTransparency = 0.3
        titleLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        titleLabel.Text = player.DisplayName or player.Name
        titleLabel.Parent = bb

        local infoLabel = Instance.new("TextLabel")
        infoLabel.Position = UDim2.new(0, 0, 0.5, 0)
        infoLabel.Size = UDim2.new(1, 0, 0.5, 0)
        infoLabel.BackgroundTransparency = 1
        infoLabel.Font = Enum.Font.Gotham
        infoLabel.TextSize = 11
        infoLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
        infoLabel.TextStrokeTransparency = 0.4
        infoLabel.Text = string.format("[%s]", role:upper())
        infoLabel.Parent = bb

        -- 3. Tracer (2D Line)
        local tracerLine = nil
        if Drawing then
            tracerLine = Drawing.new("Line")
            tracerLine.Thickness = 1.5
            tracerLine.Color = roleColor
            tracerLine.Transparency = 0.8
            tracerLine.Visible = false
        end

        Cache.Players[player] = {
            Highlight = highlight,
            Billboard = bb,
            TitleLabel = titleLabel,
            InfoLabel = infoLabel,
            Tracer = tracerLine,
            Role = role
        }
    end

    if player.Character then
        ApplyESP()
    end

    player.CharacterAdded:Connect(function()
        task.wait(0.5)
        ApplyESP()
    end)
end

--------------------------------------------------------------------------------
-- 3. Логика Gun ESP (Выпавший пистолет шерифа)
--------------------------------------------------------------------------------
local function ClearGunESP()
    if Cache.Gun then
        if Cache.Gun.Highlight then Cache.Gun.Highlight:Destroy() end
        if Cache.Gun.Billboard then Cache.Gun.Billboard:Destroy() end
        Cache.Gun = nil
    end
end

local function UpdateGunESP()
    if not Settings.Enabled or not Settings.GunESP then
        ClearGunESP()
        return
    end

    local gunDrop = Workspace:FindFirstChild("GunDrop") or Workspace:FindFirstChild("Gun")
    if not gunDrop then
        for _, child in ipairs(Workspace:GetChildren()) do
            if child:IsA("Tool") and child.Name:lower():find("gun") then
                gunDrop = child
                break
            end
        end
    end

    if gunDrop then
        local targetPart = gunDrop:IsA("Model") or gunDrop:IsA("Tool") and (gunDrop:FindFirstChild("Handle") or gunDrop.PrimaryPart) or gunDrop

        if targetPart and (not Cache.Gun or Cache.Gun.Target ~= gunDrop) then
            ClearGunESP()

            local highlight = Instance.new("Highlight")
            highlight.Name = "Pulse_Gun_Highlight"
            highlight.Adornee = gunDrop
            highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            highlight.FillColor = Colors.GunDrop
            highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            highlight.FillTransparency = 0.3
            highlight.OutlineTransparency = 0
            highlight.Parent = CoreGui

            local bb = Instance.new("BillboardGui")
            bb.Name = "Pulse_Gun_Tag"
            bb.Adornee = targetPart
            bb.Size = UDim2.fromOffset(120, 30)
            bb.StudsOffsetWorldSpace = Vector3.new(0, 1.5, 0)
            bb.AlwaysOnTop = true
            bb.Parent = CoreGui

            local label = Instance.new("TextLabel")
            label.Size = UDim2.new(1, 0, 1, 0)
            label.BackgroundTransparency = 1
            label.Font = Enum.Font.GothamBold
            label.TextSize = 13
            label.TextColor3 = Colors.GunDrop
            label.TextStrokeTransparency = 0.2
            label.Text = "🔫 GUN DROP"
            label.Parent = bb

            Cache.Gun = {
                Target = gunDrop,
                Highlight = highlight,
                Billboard = bb,
                Label = label
            }
        elseif Cache.Gun and targetPart then
            -- Обновляем дистанцию до пистолета
            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                local dist = math.floor((LocalPlayer.Character.HumanoidRootPart.Position - targetPart.Position).Magnitude)
                Cache.Gun.Label.Text = string.format("🔫 GUN DROP [%dm]", dist)
            end
        end
    else
        ClearGunESP()
    end
end

--------------------------------------------------------------------------------
-- 4. Главный Цикл Обновления
--------------------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
    if not Settings.Enabled then return end

    local localChar = LocalPlayer.Character
    local localRoot = localChar and localChar:FindFirstChild("HumanoidRootPart")

    -- Обновляем игроков
    for player, data in pairs(Cache.Players) do
        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")

        if char and root and hum and hum.Health > 0 then
            -- Динамическое обновление роли (если игрок достал нож/пистолет)
            local currentRole = GetPlayerRole(player)
            if currentRole ~= data.Role then
                data.Role = currentRole
                local newColor = GetRoleColor(currentRole)
                data.Highlight.FillColor = newColor
                data.Highlight.OutlineColor = newColor
                data.TitleLabel.TextColor3 = newColor
            end

            -- Видимость и дистанция
            data.Highlight.Enabled = Settings.PlayerESP and Settings.Chams
            data.Billboard.Enabled = Settings.PlayerESP and Settings.Nametags

            local dist = localRoot and math.floor((localRoot.Position - root.Position).Magnitude) or 0
            local healthPercent = math.floor((hum.Health / hum.MaxHealth) * 100)

            local infoText = ""
            if Settings.ShowRole then infoText = infoText .. string.format("[%s]", data.Role:upper()) end
            if Settings.ShowDistance then infoText = infoText .. string.format(" [%dm]", dist) end
            if Settings.ShowHealth then infoText = infoText .. string.format(" [%d%%]", healthPercent) end

            data.InfoLabel.Text = infoText

            -- Трейсеры
            if data.Tracer then
                if Settings.PlayerESP and Settings.Tracers then
                    local screenPos, onScreen = Camera:WorldToViewportPoint(root.Position)
                    if onScreen then
                        data.Tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                        data.Tracer.To = Vector2.new(screenPos.X, screenPos.Y)
                        data.Tracer.Color = GetRoleColor(data.Role)
                        data.Tracer.Visible = true
                    else
                        data.Tracer.Visible = false
                    end
                else
                    data.Tracer.Visible = false
                end
            end
        else
            if data.Highlight then data.Highlight.Enabled = false end
            if data.Billboard then data.Billboard.Enabled = false end
            if data.Tracer then data.Tracer.Visible = false end
        end
    end

    -- Обновляем выпавший пистолет
    UpdateGunESP()
end)

-- Подписываемся на новых игроков
for _, player in ipairs(Players:GetPlayers()) do
    CreatePlayerESP(player)
end
Players.PlayerAdded:Connect(CreatePlayerESP)
Players.PlayerRemoving:Connect(ClearPlayerESP)

--------------------------------------------------------------------------------
-- 5. Построение UI Интерфейса (Pulse Hub Style / Slate UI)
--------------------------------------------------------------------------------
local function BuildUI()
    local success, Slate = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/PulseZax/Slate/refs/heads/main/.lua"), "@Slate")()
    end)

    if success and Slate then
        pcall(function() Slate.Cleanup() end)
        pcall(function() Slate:PreloadIcons({"lucide"}) end)

        local Window = Slate:CreateWindow({
            Name = "Pulse Hub",
            Subtitle = "MM2 ESP Module",
            Icon = "eye",
            Logo = true,
            Size = UDim2.fromOffset(500, 360),
            ToggleKey = Enum.KeyCode.RightControl
        })

        pcall(function() Slate.Theme.Preset("Ash") end)
        pcall(function() Slate:SetFontFamily("JosefinSans") end)
        pcall(function() Window:SetBackdrop("aurora") end)

        local Tab = Window:CreateTab({ Name = "ESP Settings", Icon = "shield" })
        local mainSec = Tab:CreateSection({ Name = "Visual Controls" })

        mainSec:Toggle({
            Name = "Enable ESP Master",
            Default = Settings.Enabled,
            Callback = function(v) Settings.Enabled = v end
        })

        mainSec:Toggle({
            Name = "Player Highlights (Chams)",
            Default = Settings.Chams,
            Callback = function(v) Settings.Chams = v end
        })

        mainSec:Toggle({
            Name = "Player Nametags",
            Default = Settings.Nametags,
            Callback = function(v) Settings.Nametags = v end
        })

        mainSec:Toggle({
            Name = "Sheriff Gun Drop ESP",
            Default = Settings.GunESP,
            Callback = function(v) Settings.GunESP = v end
        })

        mainSec:Toggle({
            Name = "Tracers (Lines)",
            Default = Settings.Tracers,
            Callback = function(v) Settings.Tracers = v end
        })

        mainSec:Toggle({
            Name = "Show Distance",
            Default = Settings.ShowDistance,
            Callback = function(v) Settings.ShowDistance = v end
        })

        Slate:Notify({
            Title = "Pulse Hub MM2 ESP",
            Description = "ESP успешно загружен! Нажмите RightCtrl для закрытия меню.",
            Icon = "check-circle",
            Duration = 5
        })
        return
    end

    -- Встроенный Fallback UI (если библиотека Slate недоступна)
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "PulseHub_FallbackUI"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = CoreGui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(320, 320)
    frame.Position = UDim2.new(0.5, -160, 0.5, -160)
    frame.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 40)
    title.BackgroundColor3 = Color3.fromRGB(32, 35, 45)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(255, 215, 0)
    title.Text = "⚡ PULSE HUB - MM2 ESP (RightCtrl)"
    title.Parent = frame

    local titleCorner = Instance.new("UICorner")
    titleCorner.CornerRadius = UDim.new(0, 8)
    titleCorner.Parent = title

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 48)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = frame

    local toggles = {
        {"Enable Master ESP", "Enabled"},
        {"Player Chams (Highlights)", "Chams"},
        {"Player Nametags", "Nametags"},
        {"Sheriff Gun Drop ESP", "GunESP"},
        {"Tracers (Lines)", "Tracers"},
        {"Show Distance", "ShowDistance"}
    }

    for idx, item in ipairs(toggles) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 34)
        btn.BackgroundColor3 = Settings[item[2]] and Color3.fromRGB(45, 140, 85) or Color3.fromRGB(45, 48, 58)
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 12
        btn.TextColor3 = Color3.fromRGB(240, 240, 240)
        btn.Text = item[1] .. ": " .. (Settings[item[2]] and "ON" or "OFF")
        btn.LayoutOrder = idx
        btn.Parent = frame

        local bCorner = Instance.new("UICorner")
        bCorner.CornerRadius = UDim.new(0, 6)
        bCorner.Parent = btn

        btn.MouseButton1Click:Connect(function()
            Settings[item[2]] = not Settings[item[2]]
            btn.BackgroundColor3 = Settings[item[2]] and Color3.fromRGB(45, 140, 85) or Color3.fromRGB(45, 48, 58)
            btn.Text = item[1] .. ": " .. (Settings[item[2]] and "ON" or "OFF")
        end)
    end

    UserInputService.InputBegan:Connect(function(input, gpe)
        if not gpe and input.KeyCode == Enum.KeyCode.RightControl then
            screenGui.Enabled = not screenGui.Enabled
        end
    end)
end

BuildUI()
print("[Pulse Hub] ESP Script Loaded Successfully!")
