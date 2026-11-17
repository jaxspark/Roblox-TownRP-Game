--[[
	StatusBars  (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > StatusBars

	Health bar (top) and hunger bar (bottom) in the bottom-left corner of the screen.
	  - Health: max = your job's MaxHealth. Green when full, fading to red, fully red at 20% or below.
	            The bar gets wider with max health (150 max health = 50% wider than 100).
	  - Hunger: max = JobsConfig.MAX_HUNGER (100) for everyone. Yellow when full, fading to grey,
	            fully grey at 20% or below.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local JobsConfig = require(ReplicatedStorage:WaitForChild("JobsConfig"))

-- Hide Roblox's built-in health bar, since we have our own
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
local BASE_WIDTH = 200 -- pixel width of a bar whose max is 100
local BAR_HEIGHT = 24
local GAP = 8
local MARGIN = 16
local FULL_COLOR_AT = 1 -- fraction at/above which the bar shows its "full" color
local EMPTY_COLOR_AT = 0.2 -- fraction at/below which the bar shows its "empty" color

local HUNGER_FULL = Color3.fromRGB(245, 205, 45) -- yellow
local HUNGER_EMPTY = Color3.fromRGB(130, 130, 135) -- grey

---------------------------------------------------------------------
-- Build UI
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "StatusBarsGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local container = Instance.new("Frame")
container.AnchorPoint = Vector2.new(0, 1)
container.Position = UDim2.new(0, MARGIN, 1, -MARGIN)
container.Size = UDim2.new(0, 600, 0, BAR_HEIGHT * 2 + GAP)
container.BackgroundTransparency = 1
container.Visible = false -- shown once the player's data has loaded
container.Parent = gui

local function makeBar(yOffset)
	local back = Instance.new("Frame")
	back.Size = UDim2.new(0, BASE_WIDTH, 0, BAR_HEIGHT)
	back.Position = UDim2.new(0, 0, 0, yOffset)
	back.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
	back.BorderSizePixel = 0
	back.ClipsDescendants = true
	back.Parent = container

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 6)
	backCorner.Parent = back

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.5
	stroke.Thickness = 1.5
	stroke.Parent = back

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.Parent = back

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 13
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.5
	text.ZIndex = 2
	text.Parent = back

	return back, fill, text
end

local healthBack, healthFill, healthText = makeBar(0) -- top
local hungerBack, hungerFill, hungerText = makeBar(BAR_HEIGHT + GAP) -- below it

---------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------
-- 0 at/below EMPTY_COLOR_AT, 1 at/above FULL_COLOR_AT, smooth in between
local function colorAmount(fraction)
	return math.clamp((fraction - EMPTY_COLOR_AT) / (FULL_COLOR_AT - EMPTY_COLOR_AT), 0, 1)
end

local function healthColor(fraction)
	-- Hue 0 = red ... 0.3 = green, so it passes through orange and yellow on the way
	return Color3.fromHSV(0.3 * colorAmount(fraction), 0.75, 0.85)
end

local function hungerColor(fraction)
	return HUNGER_EMPTY:Lerp(HUNGER_FULL, colorAmount(fraction))
end

---------------------------------------------------------------------
-- Update every frame
---------------------------------------------------------------------
local lastMaxHealth = 100

RunService.Heartbeat:Connect(function()
	local hunger = player:GetAttribute("Hunger")
	container.Visible = hunger ~= nil
	if hunger == nil then
		return
	end

	-- Health comes straight from the character's Humanoid
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local health = humanoid and humanoid.Health or 0
	local maxHealth = humanoid and humanoid.MaxHealth or lastMaxHealth
	lastMaxHealth = maxHealth

	local healthFraction = math.clamp(health / maxHealth, 0, 1)
	healthBack.Size = UDim2.new(0, BASE_WIDTH * maxHealth / 100, 0, BAR_HEIGHT)
	healthFill.Size = UDim2.new(healthFraction, 0, 1, 0)
	healthFill.BackgroundColor3 = healthColor(healthFraction)
	healthText.Text = ("Health  %d / %d"):format(math.ceil(health), math.floor(maxHealth))

	-- Hunger is a player attribute set by the server
	local maxHunger = JobsConfig.MAX_HUNGER
	local hungerFraction = math.clamp(hunger / maxHunger, 0, 1)
	hungerBack.Size = UDim2.new(0, BASE_WIDTH, 0, BAR_HEIGHT)
	hungerFill.Size = UDim2.new(hungerFraction, 0, 1, 0)
	hungerFill.BackgroundColor3 = hungerColor(hungerFraction)
	hungerText.Text = ("Hunger  %d / %d"):format(math.floor(hunger), maxHunger)
end)
