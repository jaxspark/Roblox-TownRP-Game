--[[
	JobService  (Script)
	Location: ServerScriptService > JobService

	Handles:
	  - Loading / saving Money, Job, last job change time, salary timer (DataStore)
	  - Paying salary every 10 minutes of in-game time
	  - Job change requests (30 minute cooldown, enforced on the server)
	  - Applying job abilities (stats + tools) on spawn
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local JobsConfig = require(ReplicatedStorage:WaitForChild("JobsConfig"))

local DATASTORE_NAME = "PlayerData_v1"
local AUTOSAVE_INTERVAL = 60
local store = DataStoreService:GetDataStore(DATASTORE_NAME)

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------
local remotes = Instance.new("Folder")
remotes.Name = "JobRemotes"
remotes.Parent = ReplicatedStorage

local requestJobChange = Instance.new("RemoteFunction")
requestJobChange.Name = "RequestJobChange"
requestJobChange.Parent = remotes

local notifyEvent = Instance.new("RemoteEvent")
notifyEvent.Name = "Notify"
notifyEvent.Parent = remotes

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function serverNow()
	return math.floor(workspace:GetServerTimeNow())
end

local function defaultData()
	return {
		Money = 0,
		Job = JobsConfig.DEFAULT_JOB,
		LastJobChange = 0, -- unix time of last change (0 = never, so first pick is free)
		SalaryProgress = 0, -- seconds toward the next paycheck
		OwnedDoors = {}, -- ids of doors this player has purchased
	}
end

-- sessions[player] = { Data = {...}, Loaded = bool }
local sessions = {}

---------------------------------------------------------------------
-- Data loading / saving
---------------------------------------------------------------------
local function loadData(player)
	local key = "Player_" .. player.UserId
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			local data = defaultData()
			if type(result) == "table" then
				for k, v in pairs(result) do
					data[k] = v
				end
			end
			-- Make sure a removed/renamed job doesn't break the player
			if not JobsConfig.ById[data.Job] then
				data.Job = JobsConfig.DEFAULT_JOB
			end
			if type(data.OwnedDoors) ~= "table" then
				data.OwnedDoors = {}
			end
			return data
		end
		warn(("Load failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(result)))
		task.wait(2)
	end
	return nil
end

local function saveData(player)
	local session = sessions[player]
	if not session or not session.Loaded then
		return
	end
	local key = "Player_" .. player.UserId
	local snapshot = table.clone(session.Data)

	for attempt = 1, 3 do
		local ok, err = pcall(function()
			store:UpdateAsync(key, function()
				return snapshot
			end)
		end)
		if ok then
			return true
		end
		warn(("Save failed for %s (attempt %d): %s"):format(player.Name, attempt, tostring(err)))
		task.wait(2)
	end
	return false
end

---------------------------------------------------------------------
-- Leaderstats / replication to the client
---------------------------------------------------------------------
local function syncPlayer(player)
	local session = sessions[player]
	if not session then
		return
	end
	local data = session.Data
	local job = JobsConfig.ById[data.Job]

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Money.Value = data.Money
		leaderstats.Job.Value = job.Name
	end

	player:SetAttribute("JobId", job.Id)
	player:SetAttribute("NextJobChange", data.LastJobChange + JobsConfig.JOB_CHANGE_COOLDOWN)
	player:SetAttribute("SalaryProgress", data.SalaryProgress)
end

local function createLeaderstats(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local money = Instance.new("IntValue")
	money.Name = "Money"
	money.Parent = leaderstats

	local jobValue = Instance.new("StringValue")
	jobValue.Name = "Job"
	jobValue.Parent = leaderstats

	leaderstats.Parent = player
end

---------------------------------------------------------------------
-- Tools & abilities
---------------------------------------------------------------------
local function setupMedkit(tool)
	local onCooldown = false
	tool.Activated:Connect(function()
		if onCooldown then
			return
		end
		local character = tool.Parent
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end

		local target, bestDist = nil, 12
		for _, other in ipairs(Players:GetPlayers()) do
			local c = other.Character
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			local otherRoot = c and c:FindFirstChild("HumanoidRootPart")
			if hum and otherRoot and hum.Health > 0 and hum.Health < hum.MaxHealth then
				local dist = (otherRoot.Position - root.Position).Magnitude
				if dist < bestDist then
					target, bestDist = hum, dist
				end
			end
		end

		if target then
			onCooldown = true
			target.Health = math.min(target.MaxHealth, target.Health + 40)
			task.delay(5, function()
				onCooldown = false
			end)
		end
	end)
end

-- Lockpick: finds the nearest purchasable door and tells it a lockpick attempt happened.
-- The door script decides whether the attempt succeeds.
local LOCKPICK_COOLDOWN = 3 -- seconds
local LOCKPICK_RANGE = 10 -- studs
local lockpickLastUse = setmetatable({}, { __mode = "k" }) -- [player] = os.clock()

local function distanceToPart(part, position)
	-- Distance from a point to the surface of a (possibly large) part
	local localPos = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	local clamped = Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	)
	return (localPos - clamped).Magnitude
end

local function setupLockpick(tool)
	tool.Activated:Connect(function()
		local character = tool.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not player or not root then
			return
		end

		local now = os.clock()
		if now - (lockpickLastUse[player] or -math.huge) < LOCKPICK_COOLDOWN then
			return
		end

		local nearest, bestDist = nil, LOCKPICK_RANGE
		for _, door in ipairs(CollectionService:GetTagged("PurchasableDoor")) do
			if door:IsA("BasePart") then
				local dist = distanceToPart(door, root.Position)
				if dist < bestDist then
					nearest, bestDist = door, dist
				end
			end
		end

		if not nearest then
			notifyEvent:FireClient(player, "There is no door in range.")
			return
		end

		lockpickLastUse[player] = now -- cooldown only starts when a door was targeted
		local attempt = nearest:FindFirstChild("LockpickAttempt")
		if attempt then
			attempt:Fire(player)
		end
	end)
end

local function createTool(toolName)
	local jobTools = ServerStorage:FindFirstChild("JobTools")
	local template = jobTools and jobTools:FindFirstChild(toolName)

	local tool
	if template and template:IsA("Tool") then
		tool = template:Clone()
	else
		-- Placeholder tool so the template works without any assets
		tool = Instance.new("Tool")
		tool.Name = toolName
		tool.RequiresHandle = true
		tool.CanBeDropped = false

		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 1)
		handle.Color = Color3.fromRGB(120, 120, 120)
		handle.Parent = tool
	end

	tool:SetAttribute("JobTool", true)
	if toolName == "Medkit" then
		setupMedkit(tool)
	elseif toolName == "Lockpick" then
		setupLockpick(tool)
	end
	return tool
end

local function clearJobTools(player)
	local function clear(container)
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and child:GetAttribute("JobTool") then
					child:Destroy()
				end
			end
		end
	end
	clear(player:FindFirstChildOfClass("Backpack"))
	clear(player.Character)
end

local function applyJob(player)
	local session = sessions[player]
	local character = player.Character
	if not session or not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	local job = JobsConfig.ById[session.Data.Job]
	local abilities = job.Abilities or {}

	-- Stats (fall back to Roblox defaults)
	humanoid.WalkSpeed = abilities.WalkSpeed or 16
	humanoid.UseJumpPower = true
	humanoid.JumpPower = abilities.JumpPower or 50
	local maxHealth = abilities.MaxHealth or 100
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth

	-- Tools
	clearJobTools(player)
	local backpack = player:WaitForChild("Backpack")
	for _, toolName in ipairs(abilities.Tools or {}) do
		createTool(toolName).Parent = backpack
	end
end

---------------------------------------------------------------------
-- Job change requests
---------------------------------------------------------------------
---------------------------------------------------------------------
-- Door purchases (called by Door scripts through a BindableFunction)
---------------------------------------------------------------------
local purchaseDoorFunction = Instance.new("BindableFunction")
purchaseDoorFunction.Name = "PurchaseDoor"
purchaseDoorFunction.Parent = ServerStorage

local function setDoorAttributes(player)
	local session = sessions[player]
	if not session or not session.Loaded then
		return
	end
	for _, doorId in ipairs(session.Data.OwnedDoors) do
		player:SetAttribute("Door_" .. doorId, true)
	end
end

purchaseDoorFunction.OnInvoke = function(player, doorId, price)
	local session = sessions[player]
	if not session or not session.Loaded then
		return false, "Your data is still loading."
	end
	if type(doorId) ~= "string" or type(price) ~= "number" or price < 0 then
		return false, "Invalid purchase."
	end

	local data = session.Data
	if table.find(data.OwnedDoors, doorId) then
		return false, "You already own this door."
	end
	if data.Money < price then
		return false, ("You need $%d to buy this door."):format(price)
	end

	data.Money -= price
	table.insert(data.OwnedDoors, doorId)
	setDoorAttributes(player)
	syncPlayer(player)
	task.spawn(saveData, player) -- save right away so a purchase is never lost
	return true, ("You bought the door for $%d."):format(price)
end

requestJobChange.OnServerInvoke = function(player, jobId)
	local session = sessions[player]
	if not session or not session.Loaded then
		return false, "Your data is still loading."
	end
	if type(jobId) ~= "string" then
		return false, "Invalid job."
	end

	local job = JobsConfig.ById[jobId]
	if not job or not job.Selectable then
		return false, "That job does not exist."
	end
	if session.Data.Job == jobId then
		return false, "You already have that job."
	end

	local now = serverNow()
	local nextChange = session.Data.LastJobChange + JobsConfig.JOB_CHANGE_COOLDOWN
	if now < nextChange then
		local remaining = nextChange - now
		return false, ("You can change jobs again in %d min %d sec."):format(remaining // 60, remaining % 60)
	end

	session.Data.Job = jobId
	session.Data.LastJobChange = now
	syncPlayer(player)
	applyJob(player)
	notifyEvent:FireClient(player, "You are now a " .. job.Name .. " (salary $" .. job.Salary .. ").")
	return true, "Job changed."
end

---------------------------------------------------------------------
-- Salary: every SALARY_INTERVAL seconds of in-game time
---------------------------------------------------------------------
task.spawn(function()
	while true do
		local dt = task.wait(1)
		for player, session in pairs(sessions) do
			if session.Loaded then
				local data = session.Data
				data.SalaryProgress += dt
				if data.SalaryProgress >= JobsConfig.SALARY_INTERVAL then
					data.SalaryProgress -= JobsConfig.SALARY_INTERVAL
					local job = JobsConfig.ById[data.Job]
					if job.Salary > 0 then
						data.Money += job.Salary
						notifyEvent:FireClient(player, ("Paycheck received: $%d"):format(job.Salary))
					end
				end
				syncPlayer(player)
			end
		end
	end
end)

---------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------
local function onPlayerAdded(player)
	sessions[player] = { Data = nil, Loaded = false }

	local data = loadData(player)
	if not player.Parent then
		sessions[player] = nil
		return -- left while loading
	end
	if not data then
		-- Kick instead of letting them play and overwrite good data with a blank save
		player:Kick("Could not load your data. Please rejoin.")
		sessions[player] = nil
		return
	end

	sessions[player].Data = data
	sessions[player].Loaded = true
	createLeaderstats(player)
	syncPlayer(player)
	setDoorAttributes(player)

	player.CharacterAdded:Connect(function()
		applyJob(player)
	end)
	if player.Character then
		applyJob(player)
	end
end

local function onPlayerRemoving(player)
	saveData(player)
	sessions[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Autosave
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(saveData, player)
		end
	end
end)

-- Save everyone when the server shuts down
game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(saveData, player)
	end
	task.wait(3)
end)
