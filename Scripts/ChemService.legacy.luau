--[[
	ChemService  (Script)
	Location: ServerScriptService > ChemService

	The Chemist's chems:
	  1. The Chemist uses the Chemistry Set -> JobService tells us -> we open the chem menu on their screen
	  2. They click a chem -> it takes ChemsConfig.CRAFT_TIME seconds to create (only one at a time).
	     Taking damage stops it (no cooldown). Finishing it starts the menu cooldown.
	  3. The finished chem drops in front of the Chemist as a physics Part. The first player to touch it
	     picks it up as a tool.
	  4. Using the tool applies the buff for its duration and uses the tool up.

	Buffs are additive and are published as player attributes that JobService reads when it works out
	speed / jump / max health:
	  BuffSpeed, BuffJump, BuffMaxHealth, BuffDamageReduction (0-1), BuffInvisible
	Any damage system you add later should multiply damage by (1 - BuffDamageReduction).

	Requires JobService, ChemsConfig and ChemMenu.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local ChemsConfig = require(ReplicatedStorage:WaitForChild("ChemsConfig"))

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
local CHEMIST_JOB_ID = "Chemist" -- must match the Id in JobsConfig
local CHEM_SPAWN_DISTANCE = 4 -- studs in front of the Chemist
local CHEM_LIFETIME = 120 -- seconds before an unclaimed chem disappears (0 = never)

---------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------
local notify = ReplicatedStorage:WaitForChild("JobRemotes"):WaitForChild("Notify")
local chemistrySetUsed = ServerStorage:WaitForChild("ChemistrySetUsed")
local buffsChanged = ServerStorage:WaitForChild("BuffsChanged")

local remotes = Instance.new("Folder")
remotes.Name = "ChemRemotes"
remotes.Parent = ReplicatedStorage

local openMenuEvent = Instance.new("RemoteEvent")
openMenuEvent.Name = "OpenChemMenu"
openMenuEvent.Parent = remotes

local startChemEvent = Instance.new("RemoteEvent")
startChemEvent.Name = "StartChem"
startChemEvent.Parent = remotes

local weak = { __mode = "k" }
local crafting = setmetatable({}, weak) -- [player] = { Chem = chem } while creating a chem
local activeBuffs = setmetatable({}, weak) -- [player] = list of { Type, Amount }
local invisibleStates = setmetatable({}, weak) -- [character] = saved transparencies
local warnedMissing = {}

---------------------------------------------------------------------
-- Crafting state (replicated to the client as player attributes)
---------------------------------------------------------------------
local function clearCraftAttributes(player)
	player:SetAttribute("ChemCraftId", nil)
	player:SetAttribute("ChemCraftStart", nil)
	player:SetAttribute("ChemCraftEnd", nil)
end

-- Stops the chem being created (no cooldown). Safe to call when nothing is being created.
local function cancelCraft(player, message)
	if not crafting[player] then
		return
	end
	crafting[player] = nil
	clearCraftAttributes(player)
	if message and player.Parent then
		notify:FireClient(player, message)
	end
end

local function hasChemistrySet(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	return (backpack and backpack:FindFirstChild("Chemistry Set") ~= nil)
		or (player.Character and player.Character:FindFirstChild("Chemistry Set") ~= nil)
end

---------------------------------------------------------------------
-- Chem parts and tools
---------------------------------------------------------------------
-- The Part named after the chem in ReplicatedStorage, or a small placeholder
local function makeChemPart(chem)
	local template = ReplicatedStorage:FindFirstChild(chem.Id)
	if template and template:IsA("BasePart") then
		return template:Clone()
	end

	if not warnedMissing[chem.Id] then
		warnedMissing[chem.Id] = true
		warn(("[ChemService] ReplicatedStorage needs a Part named '%s'. Using a placeholder for now."):format(chem.Id))
	end
	local part = Instance.new("Part")
	part.Name = chem.Id
	part.Size = Vector3.new(0.8, 1.2, 0.8)
	part.Color = chem.Color or Color3.fromRGB(180, 180, 180)
	part.Material = Enum.Material.Neon
	return part
end

-- Forward declaration: tools and buffs refer to each other
local addBuff

local function createChemTool(chem)
	local tool = Instance.new("Tool")
	tool.Name = chem.Name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute("ChemId", chem.Id)

	-- The chem part itself is the handle, so it looks the same in the player's hand
	local handle = makeChemPart(chem)
	handle.Name = "Handle"
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanTouch = false
	handle.Parent = tool

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
		used = true
		addBuff(player, chem)
		tool:Destroy()
	end)

	return tool
end

-- Drops a finished chem into the world. The first player to touch it picks it up.
local function spawnChem(chem, cframe)
	local part = makeChemPart(chem)
	part.Name = chem.Id
	part.Anchored = false -- follows physics and falls to the ground
	part.CanCollide = true
	part.CanTouch = true
	part.CFrame = cframe
	part.Parent = workspace
	pcall(function()
		part:SetNetworkOwner(nil) -- keep the physics on the server
	end)

	local claimed = false
	local connection
	connection = part.Touched:Connect(function(hit)
		if claimed then
			return
		end
		local hitCharacter = hit:FindFirstAncestorOfClass("Model")
		local toucher = hitCharacter and Players:GetPlayerFromCharacter(hitCharacter)
		local humanoid = hitCharacter and hitCharacter:FindFirstChildOfClass("Humanoid")
		if not toucher or not humanoid or humanoid.Health <= 0 then
			return
		end
		local backpack = toucher:FindFirstChildOfClass("Backpack")
		if not backpack then
			return
		end

		claimed = true
		connection:Disconnect()
		part:Destroy()
		createChemTool(chem).Parent = backpack
		notify:FireClient(toucher, ("You picked up a %s."):format(chem.Name))
	end)

	if CHEM_LIFETIME > 0 then
		Debris:AddItem(part, CHEM_LIFETIME)
	end
end

---------------------------------------------------------------------
-- Buff effects that aren't just numbers (invisibility, invincibility shield)
---------------------------------------------------------------------
local function hideInstance(state, inst)
	if state.originals[inst] ~= nil then
		return
	end
	if inst:IsA("BasePart") then
		if inst.Name ~= "HumanoidRootPart" then
			state.originals[inst] = inst.Transparency
			inst.Transparency = 1
		end
	elseif inst:IsA("Decal") then
		state.originals[inst] = inst.Transparency
		inst.Transparency = 1
	end
end

local function applyInvisibility(character, on)
	if not character then
		return
	end
	local state = invisibleStates[character]
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if on and not state then
		state = { originals = {} }
		invisibleStates[character] = state
		for _, inst in ipairs(character:GetDescendants()) do
			hideInstance(state, inst)
		end
		-- Hide anything added while invisible too (for example a tool being equipped)
		state.connection = character.DescendantAdded:Connect(function(inst)
			hideInstance(state, inst)
		end)
		if humanoid then
			state.displayType = humanoid.DisplayDistanceType
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- hides the name tag
		end
	elseif not on and state then
		invisibleStates[character] = nil
		state.connection:Disconnect()
		for inst, original in pairs(state.originals) do
			if inst.Parent then
				inst.Transparency = original
			end
		end
		if humanoid and state.displayType then
			humanoid.DisplayDistanceType = state.displayType
		end
	end
end

-- A ForceField (set invisible so it doesn't give away an invisible player) blocks Humanoid:TakeDamage
local function applyShield(character, on)
	if not character then
		return
	end
	local existing = character:FindFirstChild("ChemShield")
	if on and not existing then
		local shield = Instance.new("ForceField")
		shield.Name = "ChemShield"
		shield.Visible = false
		shield.Parent = character
	elseif not on and existing then
		existing:Destroy()
	end
end

---------------------------------------------------------------------
-- Buffs
---------------------------------------------------------------------
-- Adds up every active buff (additive), publishes the totals and tells JobService to re-apply stats
local function recomputeBuffs(player)
	local totals = { Speed = 0, Jump = 0, MaxHealth = 0, DamageReduction = 0 }
	local invisible = false

	for _, buff in ipairs(activeBuffs[player] or {}) do
		if buff.Type == "Invisible" then
			invisible = true
		elseif totals[buff.Type] then
			totals[buff.Type] += buff.Amount
		end
	end
	totals.DamageReduction = math.min(totals.DamageReduction, 1) -- can't go past 100%

	player:SetAttribute("BuffSpeed", totals.Speed)
	player:SetAttribute("BuffJump", totals.Jump)
	player:SetAttribute("BuffMaxHealth", totals.MaxHealth)
	player:SetAttribute("BuffDamageReduction", totals.DamageReduction)
	player:SetAttribute("BuffInvisible", invisible)

	applyInvisibility(player.Character, invisible)
	applyShield(player.Character, totals.DamageReduction >= 1)
	buffsChanged:Fire(player)
end

function addBuff(player, chem)
	local effect = chem.Effect
	local list = activeBuffs[player]
	if not list then
		list = {}
		activeBuffs[player] = list
	end

	local buff = { Type = effect.Type, Amount = effect.Amount or 0 }
	table.insert(list, buff)
	recomputeBuffs(player)
	notify:FireClient(player, ("%s activated!"):format(chem.Name))

	task.delay(effect.Duration, function()
		local current = activeBuffs[player]
		local index = current and table.find(current, buff)
		if not index then
			return -- already cleared (for example the player died)
		end
		table.remove(current, index)
		if player.Parent then
			recomputeBuffs(player)
			notify:FireClient(player, ("%s wore off."):format(chem.Name))
		end
	end)
end

local function clearBuffs(player)
	if activeBuffs[player] then
		activeBuffs[player] = nil
		recomputeBuffs(player)
	end
end

---------------------------------------------------------------------
-- Creating a chem
---------------------------------------------------------------------
local function finishCraft(player, job)
	crafting[player] = nil
	clearCraftAttributes(player)

	local chem = job.Chem
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not player.Parent or not root or not humanoid or humanoid.Health <= 0 then
		return
	end

	-- The menu goes on cooldown for this chem's cooldown time
	player:SetAttribute("ChemCooldownEnd", workspace:GetServerTimeNow() + chem.Cooldown)

	spawnChem(chem, CFrame.new(root.Position + root.CFrame.LookVector * CHEM_SPAWN_DISTANCE))
	notify:FireClient(player, ("Your %s is ready! Pick it up."):format(chem.Name))
end

startChemEvent.OnServerEvent:Connect(function(player, chemId)
	if type(chemId) ~= "string" then
		return
	end
	local chem = ChemsConfig.ById[chemId]
	if not chem or player:GetAttribute("JobId") ~= CHEMIST_JOB_ID or not hasChemistrySet(player) then
		return
	end

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	if crafting[player] then
		return -- only one chem at a time
	end
	local now = workspace:GetServerTimeNow()
	if now < (player:GetAttribute("ChemCooldownEnd") or 0) then
		return -- menu is on cooldown
	end

	local job = { Chem = chem }
	crafting[player] = job
	player:SetAttribute("ChemCraftId", chem.Id)
	player:SetAttribute("ChemCraftStart", now)
	player:SetAttribute("ChemCraftEnd", now + ChemsConfig.CRAFT_TIME)

	task.delay(ChemsConfig.CRAFT_TIME, function()
		if crafting[player] == job then -- not cancelled in the meantime
			finishCraft(player, job)
		end
	end)
end)

chemistrySetUsed.Event:Connect(function(player)
	if player:GetAttribute("JobId") == CHEMIST_JOB_ID then
		openMenuEvent:FireClient(player)
	end
end)

---------------------------------------------------------------------
-- Players: damage cancels crafting, death clears buffs
---------------------------------------------------------------------
local function hookCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	local lastHealth = humanoid.Health
	local lastMax = humanoid.MaxHealth
	humanoid.HealthChanged:Connect(function(health)
		local max = humanoid.MaxHealth
		-- A drop in health is damage, unless it was only max health shrinking (a buff wearing off)
		if health < lastHealth and max == lastMax then
			cancelCraft(player, "Taking damage interrupted your chem. Choose it again to restart.")
		end
		lastHealth = health
		lastMax = max
	end)

	humanoid.Died:Connect(function()
		cancelCraft(player)
		clearBuffs(player) -- buffs are lost on death
	end)
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		hookCharacter(player, character)
	end)
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end

	-- Switching away from Chemist stops anything being created
	player:GetAttributeChangedSignal("JobId"):Connect(function()
		if player:GetAttribute("JobId") ~= CHEMIST_JOB_ID then
			cancelCraft(player, "You are no longer a Chemist.")
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
