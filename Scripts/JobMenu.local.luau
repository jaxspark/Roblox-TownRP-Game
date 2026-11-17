--[[
	JobMenu  (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > JobMenu

	Builds the whole UI from code (no manual GUI setup needed).
	Open/close with the "Jobs" button or the M key.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local JobsConfig = require(ReplicatedStorage:WaitForChild("JobsConfig"))
local remotes = ReplicatedStorage:WaitForChild("JobRemotes")
local requestJobChange = remotes:WaitForChild("RequestJobChange")
local notifyEvent = remotes:WaitForChild("Notify")

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
gui.Name = "JobMenuGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

-- Toggle button
local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(0, 110, 0, 36)
toggle.Position = UDim2.new(0, 12, 0.5, -18)
toggle.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
toggle.Font = Enum.Font.GothamBold
toggle.Text = "Jobs (M)"
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.TextSize = 14
toggle.Parent = gui
corner(toggle)

-- Main frame
local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 380, 0, 440)
frame.Position = UDim2.new(0.5, -190, 0.5, -220)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 33)
frame.Visible = false
frame.Parent = gui
corner(frame, 12)

label({
	Size = UDim2.new(1, -24, 0, 30),
	Position = UDim2.new(0, 12, 0, 8),
	Text = "Choose a Job",
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	Parent = frame,
})

local cooldownLabel = label({
	Size = UDim2.new(1, -24, 0, 20),
	Position = UDim2.new(0, 12, 0, 38),
	TextSize = 13,
	TextColor3 = Color3.fromRGB(180, 180, 190),
	Parent = frame,
})

local statusLabel = label({
	Size = UDim2.new(1, -24, 0, 20),
	Position = UDim2.new(0, 12, 1, -28),
	TextSize = 13,
	TextColor3 = Color3.fromRGB(255, 200, 90),
	Parent = frame,
})

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -24, 1, -110)
list.Position = UDim2.new(0, 12, 0, 66)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = list

-- Job rows
local rows = {} -- [jobId] = { Button = , Tag = }

for _, job in ipairs(JobsConfig.Jobs) do
	if job.Selectable then
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, -6, 0, 56)
		button.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
		button.AutoButtonColor = true
		button.Text = ""
		button.Parent = list
		corner(button)

		label({
			Size = UDim2.new(1, -110, 0, 22),
			Position = UDim2.new(0, 10, 0, 6),
			Text = job.Name,
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			Parent = button,
		})
		label({
			Size = UDim2.new(1, -20, 0, 20),
			Position = UDim2.new(0, 10, 0, 30),
			Text = job.Description,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(170, 170, 180),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = button,
		})
		label({
			Size = UDim2.new(0, 90, 0, 22),
			Position = UDim2.new(1, -100, 0, 6),
			Text = "$" .. job.Salary .. " / 10m",
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = Color3.fromRGB(110, 220, 130),
			Parent = button,
		})

		button.Activated:Connect(function()
			statusLabel.Text = "..."
			local ok, message = requestJobChange:InvokeServer(job.Id)
			statusLabel.Text = message or ""
			statusLabel.TextColor3 = ok and Color3.fromRGB(110, 220, 130) or Color3.fromRGB(255, 120, 110)
		end)

		rows[job.Id] = button
	end
end

---------------------------------------------------------------------
-- Money HUD + toast notifications
---------------------------------------------------------------------
local moneyLabel = label({
	Size = UDim2.new(0, 160, 0, 32),
	Position = UDim2.new(1, -172, 0, 12),
	TextXAlignment = Enum.TextXAlignment.Right,
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	TextColor3 = Color3.fromRGB(110, 220, 130),
	Parent = gui,
})

local jobHudLabel = label({
	Size = UDim2.new(0, 220, 0, 20),
	Position = UDim2.new(1, -232, 0, 42),
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 14,
	Parent = gui,
})

local toast = label({
	Size = UDim2.new(0, 360, 0, 60),
	TextWrapped = true,
	Position = UDim2.new(0.5, -180, 0, -80),
	TextXAlignment = Enum.TextXAlignment.Center,
	BackgroundTransparency = 0.1,
	BackgroundColor3 = Color3.fromRGB(28, 28, 33),
	Parent = gui,
})
corner(toast)

local toastToken = 0
notifyEvent.OnClientEvent:Connect(function(message)
	toast.Text = message
	toastToken += 1
	local token = toastToken
	toast:TweenPosition(UDim2.new(0.5, -180, 0, 12), "Out", "Quad", 0.25, true)
	task.delay(4, function()
		if token == toastToken then
			toast:TweenPosition(UDim2.new(0.5, -180, 0, -80), "In", "Quad", 0.25, true)
		end
	end)
end)

---------------------------------------------------------------------
-- Refresh loop
---------------------------------------------------------------------
-- True when a limited job (e.g. Mayor, Sheriff) is already held by someone in this server
local function jobIsTaken(job)
	if not job.MaxPerServer then
		return false
	end
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other:GetAttribute("JobId") == job.Id then
			count += 1
		end
	end
	return count >= job.MaxPerServer
end

local function refresh()
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats and leaderstats:FindFirstChild("Money") then
		moneyLabel.Text = "$" .. leaderstats.Money.Value
		jobHudLabel.Text = leaderstats.Job.Value
	end

	local currentJob = player:GetAttribute("JobId")
	local remaining = (player:GetAttribute("NextJobChange") or 0) - math.floor(workspace:GetServerTimeNow())

	if remaining > 0 then
		cooldownLabel.Text = ("Next job change in %d:%02d"):format(remaining // 60, remaining % 60)
	else
		cooldownLabel.Text = "You can change jobs now."
	end

	for jobId, button in pairs(rows) do
		if jobId == currentJob then
			button.BackgroundColor3 = Color3.fromRGB(40, 90, 55)
		elseif jobIsTaken(JobsConfig.ById[jobId]) then
			button.BackgroundColor3 = Color3.fromRGB(75, 38, 38) -- red tint: another player has this job
		elseif remaining > 0 then
			button.BackgroundColor3 = Color3.fromRGB(38, 38, 42)
		else
			button.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
		end
	end
end

local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator >= 0.5 then
		accumulator = 0
		refresh()
	end
end)

---------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------
local function setOpen(open)
	frame.Visible = open
	if open then
		statusLabel.Text = ""
		refresh()
	end
end

toggle.Activated:Connect(function()
	setOpen(not frame.Visible)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not gameProcessed and input.KeyCode == Enum.KeyCode.M then
		setOpen(not frame.Visible)
	end
end)
