--[[
	JobService  (Script)
	Location: ServerScriptService > JobService

	Handles:
	  - Loading / saving Money, Job, last job change time, salary timer (DataStore)
	  - Paying salary every 10 minutes of in-game time
	  - Job change requests (30 minute cooldown, enforced on the server)
	  - Applying job abilities (stats + tools) on spawn
	  - One-per-server jobs (Mayor, Sheriff) via MaxPerServer in JobsConfig
	  - Door purchases: unowned again and refunded 50% when the player leaves
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local JobsConfig = require(ReplicatedStorage:WaitForChild("JobsConfig"))

local DATASTORE_NAME = "PlayerData_v1"
local AUTOSAVE_INTERVAL = 60
local DOOR_REFUND_RATE = 0.5 -- share of a door's price refunded when the player leaves
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
		DoorPurchases = {}, -- [doorId] = price paid. Refunded 50% when the player leaves
		Hunger = JobsConfig.MAX_HUNGER,
		HungerProgress = 0, -- seconds toward the next hunger tick
		-- Health is added the first time the player spawns (it starts at their job's max health)
	}
end

-- sessions[player] = { Data = {...}, Loaded = bool, Leaving = bool }
local sessions = {}

-- How many players currently hold a job. Players who are leaving don't count,
-- so their slot is free the moment they disconnect.
local function countPlayersWithJob(jobId, exceptPlayer)
	local count = 0
	for other, session in pairs(sessions) do
		if other ~= exceptPlayer and session.Loaded and not session.Leaving and session.Data.Job == jobId then
			count += 1
		end
	end
	return count
end

local function jobIsFull(job, exceptPlayer)
	return job.MaxPerServer ~= nil and countPlayersWithJob(job.Id, exceptPlayer) >= job.MaxPerServer
end

-- Gives back DOOR_REFUND_RATE of the price of every door the player bought and
-- clears them (doors become unowned). Safe to call more than once. Returns the refund.
local function refundDoors(data)
	local refund = 0
	for _, price in pairs(data.DoorPurchases) do
		refund += math.floor(price * DOOR_REFUND_RATE)
	end
	data.DoorPurchases = {}
	data.Money += refund
	return refund
end

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
			data.OwnedDoors = nil -- old format from an earlier version, no longer used
			if type(data.DoorPurchases) ~= "table" then
				data.DoorPurchases = {}
			end
			if type(data.Hunger) ~= "number" then
				data.Hunger = JobsConfig.MAX_HUNGER
			end
			data.Hunger = math.clamp(data.Hunger, 0, JobsConfig.MAX_HUNGER)
			if type(data.HungerProgress) ~= "number" then
				data.HungerProgress = 0
			end
			if type(data.Health) ~= "number" or data.Health <= 0 then
				data.Health = nil -- full health on next spawn
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
	player:SetAttribute("Hunger", data.Hunger)
	player:SetAttribute("MaxHunger", JobsConfig.MAX_HUNGER)
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
---------------------------------------------------------------------
-- Medic tools: Medkit (drops a medkit pickup), Use Medkit, First Aid
---------------------------------------------------------------------
local MEDKIT_COOLDOWN = 20 -- seconds between the medic dropping medkits
local MEDKIT_LIFETIME = 120 -- seconds before an unclaimed medkit disappears (0 = never)
local MEDKIT_SPAWN_DISTANCE = 4 -- studs in front of the medic
local USE_MEDKIT_HEAL = 50 -- health restored by the "Use Medkit" tool
local FIRST_AID_HEAL = 20 -- health restored by "First Aid"
local FIRST_AID_RANGE = 10 -- studs
local FIRST_AID_COOLDOWN = 3 -- seconds

local createTool -- defined further down (the medkit pickup hands out a tool)

local medkitLastUse = setmetatable({}, { __mode = "k" }) -- [player] = os.clock()
local firstAidLastUse = setmetatable({}, { __mode = "k" })

-- The First Aid tool's click target comes from the client (see MedicClient)
local firstAidEvent = Instance.new("RemoteEvent")
firstAidEvent.Name = "FirstAid"
firstAidEvent.Parent = remotes

-- Heals a humanoid, never above its max. Returns how much was actually healed.
local function healHumanoid(humanoid, amount)
	if humanoid.Health <= 0 then
		return 0
	end
	local before = humanoid.Health
	humanoid.Health = math.min(humanoid.MaxHealth, before + amount)
	return humanoid.Health - before
end

-- Clones the Part named "medkit" from ReplicatedStorage and drops it into the world.
-- (If there isn't one, a plain white box is used so everything still works.)
local function spawnMedkitPart(cframe)
	local template = ReplicatedStorage:FindFirstChild("medkit")
	local part
	if template and template:IsA("BasePart") then
		part = template:Clone()
	else
		warn("[JobService] ReplicatedStorage needs a Part named 'medkit'. Using a placeholder box for now.")
		part = Instance.new("Part")
		part.Name = "medkit"
		part.Size = Vector3.new(2, 1, 1.5)
		part.Color = Color3.fromRGB(240, 240, 240)
		part.Material = Enum.Material.SmoothPlastic
	end

	part.Anchored = false -- so it follows physics and drops to the ground
	part.CanCollide = true
	part.CanTouch = true
	part.CFrame = cframe
	part.Parent = workspace
	pcall(function()
		part:SetNetworkOwner(nil) -- keep the physics on the server
	end)
	return part
end

local function giveUseMedkit(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		createTool("Use Medkit", false).Parent = backpack
	end
end

-- "Medkit" (the medic's tool): drops a medkit in front of the medic, 20 second cooldown
local function setupMedkit(tool)
	tool.Activated:Connect(function()
		local character = tool.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not player or not root or not humanoid or humanoid.Health <= 0 then
			return
		end

		local now = os.clock()
		local remaining = MEDKIT_COOLDOWN - (now - (medkitLastUse[player] or -math.huge))
		if remaining > 0 then
			notifyEvent:FireClient(player, ("Medkit ready in %d seconds."):format(math.ceil(remaining)))
			return
		end
		medkitLastUse[player] = now

		local part = spawnMedkitPart(CFrame.new(root.Position + root.CFrame.LookVector * MEDKIT_SPAWN_DISTANCE))

		-- Whoever touches it first picks it up
		local claimed = false
		local connection
		connection = part.Touched:Connect(function(hit)
			if claimed then
				return
			end
			local hitCharacter = hit:FindFirstAncestorOfClass("Model")
			local toucher = hitCharacter and Players:GetPlayerFromCharacter(hitCharacter)
			local touchHumanoid = hitCharacter and hitCharacter:FindFirstChildOfClass("Humanoid")
			if not toucher or not touchHumanoid or touchHumanoid.Health <= 0 then
				return
			end
			if not toucher:FindFirstChildOfClass("Backpack") then
				return
			end

			claimed = true
			connection:Disconnect()
			part:Destroy()
			giveUseMedkit(toucher)
			notifyEvent:FireClient(toucher, ("You picked up a medkit! Use it to heal %d health."):format(USE_MEDKIT_HEAL))
		end)

		if MEDKIT_LIFETIME > 0 then
			Debris:AddItem(part, MEDKIT_LIFETIME)
		end
	end)
end

-- "Use Medkit" (given when you pick up a medkit): heals the user 50 health, then is used up
local function setupUseMedkit(tool)
	local used = false
	tool.Activated:Connect(function()
		if used then
			return
		end
		local character = tool.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not player or not humanoid or humanoid.Health <= 0 then
			return
		end
		if humanoid.Health >= humanoid.MaxHealth then
			notifyEvent:FireClient(player, "You are already at full health.")
			return
		end

		used = true
		local healed = healHumanoid(humanoid, USE_MEDKIT_HEAL)
		notifyEvent:FireClient(player, ("You used a medkit and healed %d health."):format(math.floor(healed + 0.5)))
		tool:Destroy()
	end)
end

-- "First Aid": equip it and click a player within range to heal them. The server re-checks everything.
firstAidEvent.OnServerEvent:Connect(function(player, target)
	if typeof(target) ~= "Instance" or not target:IsA("Player") or target == player then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local tool = character and character:FindFirstChild("First Aid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	-- Must be holding the First Aid tool the job gave them
	if not tool or not tool:IsA("Tool") or not tool:GetAttribute("JobTool") then
		return
	end

	local now = os.clock()
	if now - (firstAidLastUse[player] or -math.huge) < FIRST_AID_COOLDOWN then
		return
	end

	local targetCharacter = target.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
	if not targetRoot or not targetHumanoid or targetHumanoid.Health <= 0 then
		return
	end

	if (targetRoot.Position - root.Position).Magnitude > FIRST_AID_RANGE then
		notifyEvent:FireClient(player, ("%s is too far away."):format(target.Name))
		return
	end
	if targetHumanoid.Health >= targetHumanoid.MaxHealth then
		notifyEvent:FireClient(player, ("%s is already at full health."):format(target.Name))
		return
	end

	firstAidLastUse[player] = now -- cooldown only starts after a successful heal
	local healed = healHumanoid(targetHumanoid, FIRST_AID_HEAL)
	notifyEvent:FireClient(player, ("Healed %s for %d health."):format(target.Name, math.floor(healed + 0.5)))
end)

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

-- Megaphone: tells LawService the Mayor used it. LawService opens the "Declare a Law" prompt.
local megaphoneUsed = Instance.new("BindableEvent")
megaphoneUsed.Name = "MegaphoneUsed"
megaphoneUsed.Parent = ServerStorage

local function setupMegaphone(tool)
	tool.Activated:Connect(function()
		local player = Players:GetPlayerFromCharacter(tool.Parent)
		if player then
			megaphoneUsed:Fire(player)
		end
	end)
end

-- Chemistry Set: tells ChemService the Chemist used it. ChemService opens the chem menu.
local chemistrySetUsed = Instance.new("BindableEvent")
chemistrySetUsed.Name = "ChemistrySetUsed"
chemistrySetUsed.Parent = ServerStorage

local function setupChemistrySet(tool)
	tool.Activated:Connect(function()
		local player = Players:GetPlayerFromCharacter(tool.Parent)
		if player then
			chemistrySetUsed:Fire(player)
		end
	end)
end

function createTool(toolName, isJobTool)
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

	if isJobTool ~= false then
		tool:SetAttribute("JobTool", true) -- job tools are removed when the player changes job
	end
	if toolName == "Medkit" then
		setupMedkit(tool)
	elseif toolName == "Lockpick" then
		setupLockpick(tool)
	elseif toolName == "Megaphone" then
		setupMegaphone(tool)
	elseif toolName == "Use Medkit" then
		setupUseMedkit(tool)
	elseif toolName == "Chemistry Set" then
		setupChemistrySet(tool)
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

-- Applies the job's stats (speed, jump, max health) plus any active chem buffs.
-- isSpawn: restore the saved health. Otherwise (job change or buff change) health follows the max-health rules.
local function applyStats(player, isSpawn)
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
	-- Chem buffs are additive: base * (1 + total bonus)
	local speedMultiplier = 1 + (player:GetAttribute("BuffSpeed") or 0)
	local jumpHeightMultiplier = 1 + (player:GetAttribute("BuffJump") or 0)
	humanoid.WalkSpeed = (abilities.WalkSpeed or 16) * speedMultiplier
	humanoid.UseJumpPower = true
	-- Jump height grows with the SQUARE of jump power, so +200% height = power x sqrt(3)
	humanoid.JumpPower = (abilities.JumpPower or 50) * math.sqrt(jumpHeightMultiplier)
	-- Health. On spawn we restore the saved health (or full health on first join / after dying).
	-- On a job change: if max health went UP, current health goes up by the same amount.
	-- It never goes down, unless it is above the new max (then it becomes the new max).
	local data = session.Data
	local newMax = math.round((abilities.MaxHealth or 100) * (1 + (player:GetAttribute("BuffMaxHealth") or 0)))
	if isSpawn then
		if session.RespawnFull or data.Health == nil then
			data.Health = newMax
			session.RespawnFull = false
		end
		humanoid.MaxHealth = newMax
		humanoid.Health = math.min(data.Health, newMax)
	elseif humanoid.Health > 0 then
		local health = humanoid.Health
		if newMax > humanoid.MaxHealth then
			health += newMax - humanoid.MaxHealth
		end
		humanoid.MaxHealth = newMax
		humanoid.Health = math.min(health, newMax)
	else
		humanoid.MaxHealth = newMax -- dead: the respawn will set their health
	end
end

local function applyJob(player, isSpawn)
	local session = sessions[player]
	if not session or not player.Character then
		return
	end
	applyStats(player, isSpawn)

	-- Tools
	local abilities = JobsConfig.ById[session.Data.Job].Abilities or {}
	clearJobTools(player)
	local backpack = player:WaitForChild("Backpack")
	for _, toolName in ipairs(abilities.Tools or {}) do
		createTool(toolName).Parent = backpack
	end
end

-- ChemService fires this when a player's chem buffs change, so speed / jump / max health update
local buffsChanged = Instance.new("BindableEvent")
buffsChanged.Name = "BuffsChanged"
buffsChanged.Parent = ServerStorage
buffsChanged.Event:Connect(function(player)
	applyStats(player, false)
end)

-- Hunger tick: hunger drops, and once it is empty health drops instead
local function applyHungerTick(player, data)
	if data.Hunger > 0 then
		data.Hunger = math.max(0, data.Hunger - JobsConfig.HUNGER_DROP)
	else
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			-- Damage reduction (like the Invincibility Chem) also applies to starvation
			local multiplier = math.max(0, 1 - (player:GetAttribute("BuffDamageReduction") or 0))
			humanoid.Health = math.max(0, humanoid.Health - JobsConfig.STARVATION_DAMAGE * multiplier)
		end
	end
end

-- Roblox's built-in script slowly heals players. Remove it so health only changes through our systems.
local function disableDefaultRegen(character)
	local existing = character:FindFirstChild("Health")
	if existing and existing:IsA("BaseScript") then
		existing:Destroy()
		return
	end
	task.spawn(function()
		local late = character:WaitForChild("Health", 3)
		if late and late:IsA("BaseScript") then
			late:Destroy()
		end
	end)
end

-- Runs every time the player's character spawns
local function setupCharacter(player, character)
	local session = sessions[player]
	if not session or not session.Loaded then
		return
	end
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	disableDefaultRegen(character)
	applyJob(player, true)
	session.Data.Health = humanoid.Health

	-- Keep the saved health in step with the Humanoid (damage, healing, starvation...)
	humanoid.HealthChanged:Connect(function(health)
		if health > 0 and sessions[player] == session then
			session.Data.Health = health
		end
	end)

	-- Dying: lose most of your money, then respawn with full health and hunger
	humanoid.Died:Connect(function()
		if sessions[player] ~= session then
			return
		end
		local data = session.Data
		local lost = data.Money * JobsConfig.DEATH_MONEY_LOSS_PERCENT // 100 -- rounded down
		data.Money -= lost
		data.Hunger = JobsConfig.MAX_HUNGER

		local job = JobsConfig.ById[data.Job]
		data.Health = (job.Abilities and job.Abilities.MaxHealth) or 100
		session.RespawnFull = true -- also re-checked on spawn, in case they change job while dead

		syncPlayer(player)
		if lost > 0 then
			notifyEvent:FireClient(player, ("You died and lost $%d."):format(lost))
		else
			notifyEvent:FireClient(player, "You died.")
		end
	end)
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
	for doorId in pairs(session.Data.DoorPurchases) do
		player:SetAttribute("Door_" .. doorId, true)
	end
end

-- Removes the "Door_<id>" ownership attributes (doors become unowned for everyone else's prompts)
local function clearDoorAttributes(player)
	for name in pairs(player:GetAttributes()) do
		if string.sub(name, 1, 5) == "Door_" then
			player:SetAttribute(name, nil)
		end
	end
end

purchaseDoorFunction.OnInvoke = function(player, doorId, price, maxOwners)
	local session = sessions[player]
	if not session or not session.Loaded then
		return false, "Your data is still loading."
	end
	if type(doorId) ~= "string" or type(price) ~= "number" or price < 0 then
		return false, "Invalid purchase."
	end

	local data = session.Data
	if data.DoorPurchases[doorId] then
		return false, "You already own this door."
	end

	-- Owner limit for this door (the door's NumAllowedOwners attribute)
	maxOwners = type(maxOwners) == "number" and math.max(1, math.floor(maxOwners)) or 1
	local ownerCount = 0
	for _, otherSession in pairs(sessions) do
		if otherSession.Loaded and not otherSession.Leaving and otherSession.Data.DoorPurchases[doorId] then
			ownerCount += 1
		end
	end
	if ownerCount >= maxOwners then
		return false, "This door already has the maximum number of owners."
	end
	if data.Money < price then
		return false, ("You need $%d to buy this door."):format(price)
	end

	data.Money -= price
	data.DoorPurchases[doorId] = price
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
	if jobIsFull(job, player) then
		return false, ("%s is already taken by another player."):format(job.Name)
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
				-- Hunger: every HUNGER_INTERVAL seconds of in-game time (only runs while the player is online)
				data.HungerProgress += dt
				if data.HungerProgress >= JobsConfig.HUNGER_INTERVAL then
					data.HungerProgress -= JobsConfig.HUNGER_INTERVAL
					applyHungerTick(player, data)
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

	-- Crash recovery: doors left over from a session that never ended cleanly get refunded now
	local leftoverRefund = refundDoors(data)

	-- One-per-server jobs: if another player already holds this job, demote to Unemployed.
	-- (No yielding between this check and Loaded = true, so two joiners can't both win.)
	local demotedFrom = nil
	local savedJob = JobsConfig.ById[data.Job]
	if jobIsFull(savedJob, player) then
		demotedFrom = savedJob.Name
		data.Job = JobsConfig.DEFAULT_JOB
		data.LastJobChange = 0 -- demotion wasn't their choice, so no cooldown
	end

	sessions[player].Loaded = true
	createLeaderstats(player)
	syncPlayer(player)
	setDoorAttributes(player)

	player.CharacterAdded:Connect(function(character)
		setupCharacter(player, character)
	end)
	if player.Character then
		task.spawn(setupCharacter, player, player.Character)
	end

	task.delay(3, function() -- give the client a moment to build its UI
		if not player.Parent then
			return
		end
		if demotedFrom then
			notifyEvent:FireClient(player, ("Another player already has the %s job, so you are now Unemployed."):format(demotedFrom))
		end
		if leftoverRefund > 0 then
			notifyEvent:FireClient(player, ("Your doors from your last session were refunded: $%d"):format(leftoverRefund))
		end
	end)
end

local function onPlayerRemoving(player)
	local session = sessions[player]
	if session and session.Loaded then
		session.Leaving = true -- frees up their job slot immediately
		refundDoors(session.Data) -- doors become unowned, player gets 50% back
		clearDoorAttributes(player) -- door prompts update right away
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			session.Data.Health = humanoid.Health -- saved so it is the same when they come back
		end
	end
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
		local session = sessions[player]
		if session and session.Loaded then
			refundDoors(session.Data)
		end
		task.spawn(saveData, player)
	end
	task.wait(3)
end)