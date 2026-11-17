--[[
	TownInfo  (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > TownInfo

	Two things in one script:
	  1. The "Town Info" window (press I to open/close) with two tabs:
	       - Laws: every law that's been declared. The Mayor sees a delete button next to each.
	       - Jobs: every job and the players who currently have it.
	  2. The "Declare a Law" prompt that pops up when the Mayor uses the Megaphone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local JobsConfig = require(ReplicatedStorage:WaitForChild("JobsConfig"))
local lawRemotes = ReplicatedStorage:WaitForChild("LawRemotes")
local openLawPrompt = lawRemotes:WaitForChild("OpenLawPrompt")
local submitLaw = lawRemotes:WaitForChild("SubmitLaw")
local deleteLaw = lawRemotes:WaitForChild("DeleteLaw")
local lawsFolder = ReplicatedStorage:WaitForChild("Laws")

local MAYOR_JOB_ID = "Mayor" -- must match the Id in JobsConfig
local MAX_LAW_LENGTH = lawsFolder:GetAttribute("MaxLength") or 140

local COLOR_PANEL = Color3.fromRGB(28, 28, 33)
local COLOR_ROW = Color3.fromRGB(45, 45, 52)
local COLOR_TAB = Color3.fromRGB(38, 38, 44)
local COLOR_TAB_SELECTED = Color3.fromRGB(70, 70, 86)
local COLOR_TEXT_DIM = Color3.fromRGB(150, 150, 160)

---------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
end

local function padding(parent, amount)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, amount)
	p.PaddingBottom = UDim.new(0, amount)
	p.PaddingLeft = UDim.new(0, amount)
	p.PaddingRight = UDim.new(0, amount)
	p.Parent = parent
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

local function button(props)
	local b = Instance.new("TextButton")
	b.Font = Enum.Font.GothamBold
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 14
	b.AutoButtonColor = true
	for k, v in pairs(props) do
		b[k] = v
	end
	corner(b, 8)
	return b
end

local function makePage(parent)
	local page = Instance.new("ScrollingFrame")
	page.Size = UDim2.new(1, -24, 1, -102)
	page.Position = UDim2.new(0, 12, 0, 90)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 4
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new()
	page.Visible = false
	page.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = page
	return page
end

---------------------------------------------------------------------
-- Town Info window
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "TownInfoGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 420, 0, 460)
frame.Position = UDim2.new(0.5, -210, 0.5, -230)
frame.BackgroundColor3 = COLOR_PANEL
frame.Visible = false
frame.Parent = gui
corner(frame, 12)

label({
	Size = UDim2.new(1, -24, 0, 30),
	Position = UDim2.new(0, 12, 0, 8),
	Text = "Town Info",
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	Parent = frame,
})
label({
	Size = UDim2.new(0, 140, 0, 30),
	Position = UDim2.new(1, -152, 0, 8),
	Text = "Press I to close",
	TextSize = 12,
	TextColor3 = COLOR_TEXT_DIM,
	TextXAlignment = Enum.TextXAlignment.Right,
	Parent = frame,
})

-- Tabs
local lawsTab = button({
	Size = UDim2.new(0.5, -18, 0, 32),
	Position = UDim2.new(0, 12, 0, 46),
	Text = "Laws",
	Parent = frame,
})
local jobsTab = button({
	Size = UDim2.new(0.5, -18, 0, 32),
	Position = UDim2.new(0.5, 6, 0, 46),
	Text = "Jobs",
	Parent = frame,
})

local lawsPage = makePage(frame)
local jobsPage = makePage(frame)

local function selectTab(name)
	local showLaws = name == "Laws"
	lawsPage.Visible = showLaws
	jobsPage.Visible = not showLaws
	lawsTab.BackgroundColor3 = showLaws and COLOR_TAB_SELECTED or COLOR_TAB
	jobsTab.BackgroundColor3 = showLaws and COLOR_TAB or COLOR_TAB_SELECTED
end

lawsTab.Activated:Connect(function()
	selectTab("Laws")
end)
jobsTab.Activated:Connect(function()
	selectTab("Jobs")
end)

---------------------------------------------------------------------
-- Laws tab
---------------------------------------------------------------------
local function refreshLaws()
	for _, child in ipairs(lawsPage:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local laws = {}
	for _, child in ipairs(lawsFolder:GetChildren()) do
		if child:IsA("StringValue") then
			table.insert(laws, child)
		end
	end
	table.sort(laws, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)

	if #laws == 0 then
		label({
			Size = UDim2.new(1, -6, 0, 30),
			Text = "No laws have been declared.",
			TextColor3 = COLOR_TEXT_DIM,
			Parent = lawsPage,
		})
		return
	end

	local canDelete = player:GetAttribute("JobId") == MAYOR_JOB_ID

	for index, law in ipairs(laws) do
		local lawId = law.Name

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, 40)
		row.AutomaticSize = Enum.AutomaticSize.Y -- grows with the law's text
		row.BackgroundColor3 = COLOR_ROW
		row.LayoutOrder = index
		row.Parent = lawsPage
		corner(row)
		padding(row, 10)

		label({
			Size = UDim2.new(1, canDelete and -40 or 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = law.Value,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = row,
		})

		if canDelete then
			local delete = button({
				Size = UDim2.new(0, 28, 0, 28),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 0),
				BackgroundColor3 = Color3.fromRGB(150, 50, 50),
				Text = "✕",
				Parent = row,
			})
			delete.Activated:Connect(function()
				deleteLaw:FireServer(lawId)
			end)
		end
	end
end

local lawsRefreshQueued = false
local function queueLawsRefresh()
	if lawsRefreshQueued then
		return
	end
	lawsRefreshQueued = true
	task.defer(function()
		lawsRefreshQueued = false
		refreshLaws()
	end)
end

lawsFolder.ChildAdded:Connect(queueLawsRefresh)
lawsFolder.ChildRemoved:Connect(queueLawsRefresh)
-- Delete buttons appear/disappear when the local player becomes/stops being Mayor
player:GetAttributeChangedSignal("JobId"):Connect(queueLawsRefresh)

---------------------------------------------------------------------
-- Jobs tab
---------------------------------------------------------------------
local jobPlayerLabels = {} -- [jobId] = TextLabel listing the players

do
	-- Selectable jobs first, then the rest (Unemployed)
	local ordered = {}
	for _, job in ipairs(JobsConfig.Jobs) do
		if job.Selectable then
			table.insert(ordered, job)
		end
	end
	for _, job in ipairs(JobsConfig.Jobs) do
		if not job.Selectable then
			table.insert(ordered, job)
		end
	end

	for index, job in ipairs(ordered) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundColor3 = COLOR_ROW
		row.LayoutOrder = index
		row.Parent = jobsPage
		corner(row)
		padding(row, 10)

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 2)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = row

		label({
			Size = UDim2.new(1, 0, 0, 20),
			Text = job.Name,
			Font = Enum.Font.GothamBold,
			TextSize = 15,
			LayoutOrder = 1,
			Parent = row,
		})
		jobPlayerLabels[job.Id] = label({
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextSize = 13,
			LayoutOrder = 2,
			Parent = row,
		})
	end
end

local leaving = {} -- players who are on their way out
local function refreshJobs()
	local namesByJob = {}
	for _, other in ipairs(Players:GetPlayers()) do
		local jobId = other:GetAttribute("JobId")
		if jobId and not leaving[other] then
			namesByJob[jobId] = namesByJob[jobId] or {}
			table.insert(namesByJob[jobId], other.Name)
		end
	end

	for jobId, jobLabel in pairs(jobPlayerLabels) do
		local names = namesByJob[jobId]
		if names then
			table.sort(names)
			jobLabel.Text = table.concat(names, ", ")
			jobLabel.TextColor3 = Color3.fromRGB(210, 210, 220)
		else
			jobLabel.Text = "No one"
			jobLabel.TextColor3 = COLOR_TEXT_DIM
		end
	end
end

local jobsRefreshQueued = false
local function queueJobsRefresh()
	if jobsRefreshQueued then
		return
	end
	jobsRefreshQueued = true
	task.defer(function()
		jobsRefreshQueued = false
		refreshJobs()
	end)
end

local function watchPlayer(other)
	other:GetAttributeChangedSignal("JobId"):Connect(queueJobsRefresh)
end
for _, other in ipairs(Players:GetPlayers()) do
	watchPlayer(other)
end
Players.PlayerAdded:Connect(function(other)
	watchPlayer(other)
	queueJobsRefresh()
end)
Players.PlayerRemoving:Connect(function(other)
	leaving[other] = true
	queueJobsRefresh()
end)

---------------------------------------------------------------------
-- Open / close with I
---------------------------------------------------------------------
local function setOpen(open)
	frame.Visible = open
	if open then
		refreshLaws()
		refreshJobs()
	end
end

-- On-screen button (same style as the Jobs button, placed just below it)
local toggleButton = Instance.new("TextButton")
toggleButton.Size = UDim2.new(0, 110, 0, 36)
toggleButton.Position = UDim2.new(0, 12, 0.5, 26)
toggleButton.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
toggleButton.Font = Enum.Font.GothamBold
toggleButton.Text = "Town Info (I)"
toggleButton.TextColor3 = Color3.new(1, 1, 1)
toggleButton.TextSize = 13
toggleButton.Parent = gui
corner(toggleButton)

toggleButton.Activated:Connect(function()
	setOpen(not frame.Visible)
end)

---------------------------------------------------------------------
-- "Declare a Law" prompt (opens when the Mayor uses the Megaphone)
---------------------------------------------------------------------
local promptGui = Instance.new("ScreenGui")
promptGui.Name = "LawPromptGui"
promptGui.ResetOnSpawn = false
promptGui.DisplayOrder = 10 -- above the other menus
promptGui.Parent = player.PlayerGui

local promptFrame = Instance.new("Frame")
promptFrame.Size = UDim2.new(0, 420, 0, 210)
promptFrame.Position = UDim2.new(0.5, -210, 0.5, -105)
promptFrame.BackgroundColor3 = COLOR_PANEL
promptFrame.Visible = false
promptFrame.Parent = promptGui
corner(promptFrame, 12)

label({
	Size = UDim2.new(1, -24, 0, 30),
	Position = UDim2.new(0, 12, 0, 8),
	Text = "Declare a Law",
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	Parent = promptFrame,
})

local lawBox = Instance.new("TextBox")
lawBox.Size = UDim2.new(1, -24, 0, 90)
lawBox.Position = UDim2.new(0, 12, 0, 46)
lawBox.BackgroundColor3 = COLOR_ROW
lawBox.Font = Enum.Font.GothamMedium
lawBox.TextSize = 14
lawBox.TextColor3 = Color3.new(1, 1, 1)
lawBox.PlaceholderText = "Type your law here..."
lawBox.PlaceholderColor3 = COLOR_TEXT_DIM
lawBox.TextXAlignment = Enum.TextXAlignment.Left
lawBox.TextYAlignment = Enum.TextYAlignment.Top
lawBox.TextWrapped = true
lawBox.MultiLine = true
lawBox.ClearTextOnFocus = false
lawBox.Text = ""
lawBox.Parent = promptFrame
corner(lawBox)
padding(lawBox, 8)

local counterLabel = label({
	Size = UDim2.new(0, 120, 0, 18),
	Position = UDim2.new(1, -132, 0, 140),
	TextSize = 12,
	TextColor3 = COLOR_TEXT_DIM,
	TextXAlignment = Enum.TextXAlignment.Right,
	Parent = promptFrame,
})

local declareButton = button({
	Size = UDim2.new(0.5, -18, 0, 34),
	Position = UDim2.new(0, 12, 1, -46),
	BackgroundColor3 = Color3.fromRGB(40, 110, 65),
	Text = "Declare",
	Parent = promptFrame,
})
local cancelButton = button({
	Size = UDim2.new(0.5, -18, 0, 34),
	Position = UDim2.new(0.5, 6, 1, -46),
	BackgroundColor3 = Color3.fromRGB(70, 70, 80),
	Text = "Cancel",
	Parent = promptFrame,
})

local function closePrompt()
	promptFrame.Visible = false
	lawBox:ReleaseFocus()
end

local function submitPrompt()
	local text = string.gsub(lawBox.Text, "%s+", " ")
	text = string.match(text, "^%s*(.-)%s*$")
	if text ~= "" then
		submitLaw:FireServer(text)
	end
	closePrompt()
end

-- Keep the text within the limit and update the counter
lawBox:GetPropertyChangedSignal("Text"):Connect(function()
	local length = utf8.len(lawBox.Text)
	if length and length > MAX_LAW_LENGTH then
		local cut = utf8.offset(lawBox.Text, MAX_LAW_LENGTH + 1)
		lawBox.Text = string.sub(lawBox.Text, 1, cut - 1)
		return
	end
	counterLabel.Text = ("%d / %d"):format(length or 0, MAX_LAW_LENGTH)
end)
counterLabel.Text = ("0 / %d"):format(MAX_LAW_LENGTH)

declareButton.Activated:Connect(submitPrompt)
cancelButton.Activated:Connect(closePrompt)

openLawPrompt.OnClientEvent:Connect(function()
	lawBox.Text = ""
	promptFrame.Visible = true
	task.defer(function()
		lawBox:CaptureFocus()
	end)
end)

---------------------------------------------------------------------
-- Keyboard
---------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Enter submits the law while typing in the prompt
	if input.KeyCode == Enum.KeyCode.Return and promptFrame.Visible and lawBox:IsFocused() then
		task.defer(submitPrompt)
		return
	end

	-- I toggles Town Info (ignored while typing in a text box)
	if not gameProcessed and input.KeyCode == Enum.KeyCode.I then
		setOpen(not frame.Visible)
	end
end)

-- Start on the Laws tab
selectTab("Laws")
refreshLaws()
refreshJobs()