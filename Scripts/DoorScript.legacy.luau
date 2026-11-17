--[[
	Door  (Script)
	Location: ServerScriptService > Door

	One script for EVERY door. Tag a Part with "PurchasableDoor" (Studio: View > Tag Editor,
	or CollectionService:AddTag) and this script sets it up, including doors added later.

	- Players with enough money can buy the door (ProximityPrompt) and then walk through it.
	  A door can only have a limited number of owners at once (default 1).
	- When a door is full, its prompt shows who owns it instead ("Owned by Bob").
	- Owners lose access (and get a 50% refund) when they leave the server.
	- A player whose job is "Criminal" can use the Lockpick tool near the door:
	  10% chance to be able to walk through for 3 seconds.

	Optional attributes you can set on each door Part (Properties > Attributes):
	  DoorId (string)           - letters/numbers/underscores only. Defaults to the Part's name.
	                              Give each door a unique name or DoorId, OR give two parts the
	                              SAME DoorId on purpose (e.g. double doors) so one purchase opens both.
	  Price  (number)           - price of the door. Defaults to DEFAULT_PRICE below.
	  NumAllowedOwners (number) - how many players can own the door at once in a server.
	                              Defaults to DEFAULT_ALLOWED_OWNERS below (1).

	Requires JobService and DoorClient from the base template.
	Do NOT also keep an older per-door Door script inside your door parts.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
local DOOR_TAG = "PurchasableDoor"
local DEFAULT_PRICE = 500
local DEFAULT_ALLOWED_OWNERS = 1
local LOCKPICK_SUCCESS_CHANCE = 0.10 -- 10%
local LOCKPICK_PASS_DURATION = 3 -- seconds the door is passable after a success
local CRIMINAL_JOB_ID = "Criminal" -- must match the Id in JobsConfig

local notify = ReplicatedStorage:WaitForChild("JobRemotes"):WaitForChild("Notify")
local purchaseDoor = ServerStorage:WaitForChild("PurchaseDoor")

-- doorStates[doorPart] = state table for that door
local doorStates = {}
-- doorsById[doorId] = list of states (several parts can share one DoorId)
local doorsById = {}

---------------------------------------------------------------------
-- Owners + prompt text
---------------------------------------------------------------------
-- Names of the players who currently own a door (ownership is a player attribute set by JobService)
local function getOwners(ownedAttribute)
	local names = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p:GetAttribute(ownedAttribute) then
			table.insert(names, p.Name)
		end
	end
	table.sort(names)
	return names
end

-- "Bob" / "Bob and Sue" / "Bob, Sue, and Tim"
local function joinNames(names)
	local n = #names
	if n == 1 then
		return names[1]
	elseif n == 2 then
		return names[1] .. " and " .. names[2]
	end
	return table.concat(names, ", ", 1, n - 1) .. ", and " .. names[n]
end

local function refreshPrompt(state)
	local prompt = state.prompt
	local owners = getOwners(state.ownedAttribute)
	if #owners >= state.maxOwners then
		-- Door is full: show who owns it instead of the purchase prompt
		prompt.ActionText = "Owned by " .. joinNames(owners)
		prompt.ObjectText = ""
		prompt.HoldDuration = 0
	else
		prompt.ActionText = "Buy Door"
		prompt.HoldDuration = state.buyHoldDuration
		if #owners > 0 then
			prompt.ObjectText = "$" .. state.price .. ", owned by " .. joinNames(owners)
		else
			prompt.ObjectText = "$" .. state.price
		end
	end
end

local function refreshAllPrompts()
	for _, state in pairs(doorStates) do
		refreshPrompt(state)
	end
end

---------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------
local function handleTriggered(state, player)
	if player:GetAttribute(state.ownedAttribute) then
		notify:FireClient(player, "You already own this door.")
		return
	end

	local owners = getOwners(state.ownedAttribute)
	if #owners >= state.maxOwners then
		notify:FireClient(player, "Owned by " .. joinNames(owners))
		return
	end

	-- JobService does the final check and takes the money
	local _, message = purchaseDoor:Invoke(player, state.doorId, state.price, state.maxOwners)
	notify:FireClient(player, message)
end

---------------------------------------------------------------------
-- Lockpicking
---------------------------------------------------------------------
local function handleLockpick(state, player)
	if player:GetAttribute("JobId") ~= CRIMINAL_JOB_ID then
		notify:FireClient(player, "Only criminals can lockpick doors.")
		return
	end
	if player:GetAttribute(state.ownedAttribute) then
		notify:FireClient(player, "You already own this door.")
		return
	end

	local passAttribute = state.passAttribute
	local now = workspace:GetServerTimeNow()
	local currentPass = player:GetAttribute(passAttribute)
	if currentPass and currentPass > now then
		notify:FireClient(player, "The door is already unlocked.")
		return
	end

	if math.random() < LOCKPICK_SUCCESS_CHANCE then
		local expiresAt = now + LOCKPICK_PASS_DURATION
		player:SetAttribute(passAttribute, expiresAt)
		notify:FireClient(player, ("Lock picked! You have %d seconds to get through."):format(LOCKPICK_PASS_DURATION))

		task.delay(LOCKPICK_PASS_DURATION + 0.5, function()
			-- Clean up, unless a newer pass replaced this one
			if player.Parent and player:GetAttribute(passAttribute) == expiresAt then
				player:SetAttribute(passAttribute, nil)
			end
		end)
	else
		notify:FireClient(player, "The lockpick slipped. Try again.")
	end
end

---------------------------------------------------------------------
-- Setting doors up / tearing them down
---------------------------------------------------------------------
local function setupDoor(door)
	if doorStates[door] then
		return
	end
	if not door:IsA("BasePart") then
		warn(("[Door] %s has the %s tag but is not a Part, so it was ignored."):format(door:GetFullName(), DOOR_TAG))
		return
	end

	-- Attribute names can only contain letters, numbers and underscores
	local doorId = tostring(door:GetAttribute("DoorId") or door.Name):gsub("[^%w_]", "_")

	local price = door:GetAttribute("Price")
	if type(price) ~= "number" then
		price = DEFAULT_PRICE
	end
	local maxOwners = door:GetAttribute("NumAllowedOwners")
	if type(maxOwners) ~= "number" then
		maxOwners = DEFAULT_ALLOWED_OWNERS
	end
	maxOwners = math.max(1, math.floor(maxOwners))

	door:SetAttribute("DoorId", doorId)
	door:SetAttribute("Price", price)
	door:SetAttribute("NumAllowedOwners", maxOwners)
	door.CanCollide = true -- stays solid on the server; owners get a client-side pass

	-- Use the door's own ProximityPrompt if it has one, otherwise make one
	local prompt = door:FindFirstChildOfClass("ProximityPrompt")
	local createdPrompt = false
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.HoldDuration = 0.5
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = door
		createdPrompt = true
	end

	-- Lets JobService's Lockpick tool talk to this door
	local lockpickEvent = Instance.new("BindableEvent")
	lockpickEvent.Name = "LockpickAttempt"
	lockpickEvent.Parent = door

	local state = {
		door = door,
		doorId = doorId,
		price = price,
		maxOwners = maxOwners,
		ownedAttribute = "Door_" .. doorId,
		passAttribute = "DoorPass_" .. doorId,
		prompt = prompt,
		createdPrompt = createdPrompt,
		buyHoldDuration = prompt.HoldDuration,
		lockpickEvent = lockpickEvent,
		connections = {},
	}

	table.insert(state.connections, prompt.Triggered:Connect(function(player)
		handleTriggered(state, player)
	end))
	table.insert(state.connections, lockpickEvent.Event:Connect(function(player)
		handleLockpick(state, player)
	end))

	doorStates[door] = state
	doorsById[doorId] = doorsById[doorId] or {}
	table.insert(doorsById[doorId], state)

	refreshPrompt(state)
end

local function cleanupDoor(door)
	local state = doorStates[door]
	if not state then
		return
	end
	doorStates[door] = nil

	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end

	local list = doorsById[state.doorId]
	if list then
		local index = table.find(list, state)
		if index then
			table.remove(list, index)
		end
		if #list == 0 then
			doorsById[state.doorId] = nil
		end
	end

	state.lockpickEvent:Destroy()
	if state.createdPrompt then
		state.prompt:Destroy()
	end
end

---------------------------------------------------------------------
-- Keep prompts up to date when ownership changes
---------------------------------------------------------------------
local function watchPlayer(player)
	player.AttributeChanged:Connect(function(name)
		-- "Door_<id>" is ownership ("DoorPass_<id>" lockpick passes don't match this pattern)
		local doorId = string.match(name, "^Door_(.+)$")
		local list = doorId and doorsById[doorId]
		if list then
			for _, state in ipairs(list) do
				refreshPrompt(state)
			end
		end
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)
Players.PlayerRemoving:Connect(function()
	task.defer(refreshAllPrompts)
end)

---------------------------------------------------------------------
-- Start
---------------------------------------------------------------------
CollectionService:GetInstanceAddedSignal(DOOR_TAG):Connect(setupDoor)
CollectionService:GetInstanceRemovedSignal(DOOR_TAG):Connect(cleanupDoor)
for _, door in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
	setupDoor(door)
end
