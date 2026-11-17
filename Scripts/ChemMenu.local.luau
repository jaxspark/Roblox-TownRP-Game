--[[
	ChemMenu  (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > ChemMenu

	The Chemist's menu. It opens when the Chemistry Set is used (using it again closes it).
	  - A progress bar at the top fills while a chem is being created
	  - Five buttons, one per chem, with a short description
	  - While a chem is being created, or the menu is on cooldown, the buttons are greyed out
	The server decides everything; this script only displays the state it publishes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local ChemsConfig = require(ReplicatedStorage:WaitForChild("ChemsConfig"))
local chemRemotes = ReplicatedStorage:WaitForChild("ChemRemotes")
local openMenuEvent = chemRemotes:WaitForChild("OpenChemMenu")
local startChemEvent = chemRemotes:WaitForChild("StartChem")

local CHEMIST_JOB_ID = "Chemist" -- must match the Id in JobsConfig

local COLOR_PANEL = Color3.fromRGB(28, 28, 33)
local COLOR_ROW = Color3.fromRGB(45, 45, 52)
local COLOR_ROW_BUSY = Color3.fromRGB(34, 34, 38)
local COLOR_ROW_ACTIVE = Color3.fromRGB(40, 90, 55)
local COLOR_DIM = Color3.fromRGB(150, 150, 160)

---------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
end

local function label(props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamMedium
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextSize = 14
	for k, v in pairs(props) do
		l[k] = v
	end
	return l
end

---------------------------------------------------------------------
-- Build UI
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ChemMenuGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 420, 0, 442)
frame.Position = UDim2.new(0.5, -210, 0.5, -221)
frame.BackgroundColor3 = COLOR_PANEL
frame.Visible = false
frame.Parent = gui
corner(frame, 12)

-- Progress bar (top of the menu)
local barBack = Instance.new("Frame")
barBack.Size = UDim2.new(1, -24, 0, 28)
barBack.Position = UDim2.new(0, 12, 0, 12)
barBack.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
barBack.BorderSizePixel = 0
barBack.ClipsDescendants = true
barBack.Parent = frame
corner(barBack, 6)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = Color3.fromRGB(80, 200, 110)
barFill.BorderSizePixel = 0
barFill.Parent = barBack

local barText = label({
	Size = UDim2.new(1, 0, 1, 0),
	TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	ZIndex = 2,
	Parent = barBack,
})

-- Title + close button
label({
	Size = UDim2.new(1, -70, 0, 26),
	Position = UDim2.new(0, 12, 0, 48),
	Text = "Chemistry Set",
	Font = Enum.Font.GothamBold,
	TextSize = 18,
	Parent = frame,
})

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.new(0, 32, 0, 26)
closeButton.Position = UDim2.new(1, -44, 0, 48)
closeButton.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
closeButton.Font = Enum.Font.GothamBold
closeButton.Text = "✕"
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.TextSize = 14
closeButton.Parent = frame
corner(closeButton, 6)

-- Chem buttons
local list = Instance.new("Frame")
list.Size = UDim2.new(1, -24, 0, 344)
list.Position = UDim2.new(0, 12, 0, 84)
list.BackgroundTransparency = 1
list.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local busy = false -- true while a chem is being created or the menu is on cooldown
local rows = {} -- [chemId] = button

for index, chem in ipairs(ChemsConfig.Chems) do
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 64)
	button.BackgroundColor3 = COLOR_ROW
	button.AutoButtonColor = true
	button.Text = ""
	button.LayoutOrder = index
	button.Parent = list
	corner(button)

	label({
		Size = UDim2.new(1, -130, 0, 22),
		Position = UDim2.new(0, 10, 0, 6),
		Text = chem.Name,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Parent = button,
	})
	label({
		Size = UDim2.new(0, 110, 0, 22),
		Position = UDim2.new(1, -120, 0, 8),
		Text = ("Cooldown %ds"):format(chem.Cooldown),
		TextSize = 12,
		TextColor3 = COLOR_DIM,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = button,
	})
	label({
		Size = UDim2.new(1, -20, 0, 28),
		Position = UDim2.new(0, 10, 0, 30),
		Text = chem.Description,
		TextSize = 12,
		TextColor3 = COLOR_DIM,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = button,
	})

	button.Activated:Connect(function()
		if not busy then
			startChemEvent:FireServer(chem.Id)
		end
	end)

	rows[chem.Id] = button
end

---------------------------------------------------------------------
-- Show the server's crafting / cooldown state
---------------------------------------------------------------------
local function update()
	local now = workspace:GetServerTimeNow()
	local craftEnd = player:GetAttribute("ChemCraftEnd")
	local cooldownEnd = player:GetAttribute("ChemCooldownEnd") or 0
	local craftingId = nil

	if craftEnd and craftEnd > now then
		local start = player:GetAttribute("ChemCraftStart") or (craftEnd - ChemsConfig.CRAFT_TIME)
		local fraction = math.clamp((now - start) / (craftEnd - start), 0, 1)
		craftingId = player:GetAttribute("ChemCraftId")
		local chem = ChemsConfig.ById[craftingId]

		busy = true
		barFill.Size = UDim2.new(fraction, 0, 1, 0)
		barText.Text = ("Creating %s...  %d%%"):format(chem and chem.Name or "chem", math.floor(fraction * 100))
	elseif cooldownEnd > now then
		busy = true
		barFill.Size = UDim2.new(0, 0, 1, 0)
		barText.Text = ("On cooldown: %d seconds"):format(math.ceil(cooldownEnd - now))
	else
		busy = false
		barFill.Size = UDim2.new(0, 0, 1, 0)
		barText.Text = "Choose a chem to create"
	end

	for chemId, button in pairs(rows) do
		if chemId == craftingId then
			button.BackgroundColor3 = COLOR_ROW_ACTIVE
		elseif busy then
			button.BackgroundColor3 = COLOR_ROW_BUSY
		else
			button.BackgroundColor3 = COLOR_ROW
		end
	end
end

RunService.Heartbeat:Connect(function()
	if frame.Visible then
		update()
	end
end)

---------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------
local function setOpen(open)
	frame.Visible = open
	if open then
		update()
	end
end

closeButton.Activated:Connect(function()
	setOpen(false)
end)

-- Using the Chemistry Set opens the menu (and closes it if it's already open)
openMenuEvent.OnClientEvent:Connect(function()
	setOpen(not frame.Visible)
end)

-- The menu closes if you stop being a Chemist
player:GetAttributeChangedSignal("JobId"):Connect(function()
	if player:GetAttribute("JobId") ~= CHEMIST_JOB_ID then
		setOpen(false)
	end
end)
