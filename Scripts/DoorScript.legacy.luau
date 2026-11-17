--[[
	Door  (Script)
	Location: put this Script INSIDE the door Part.

	- Players with enough money can buy the door (ProximityPrompt) and then walk through it.
	  A door can only have a limited number of owners at once (default 1).
	- When a door is full, its prompt shows who owns it instead ("Owned by Bob").
	- Owners lose access (and get a 50% refund) when they leave the server.
	- A player whose job is "Criminal" can use the Lockpick tool near the door:
	  10% chance to be able to walk through for 3 seconds.

	Optional attributes you can set on the door Part (Properties > Attributes):
	  DoorId (string)           - unique id for this door, letters/numbers/underscores only.
	                              Defaults to the Part's name, so give each door a UNIQUE name or DoorId.
	  Price  (number)           - price of the door. Defaults to DEFAULT_PRICE below.
	  NumAllowedOwners (number) - how many players can own the door at once in a server.
	                              Defaults to DEFAULT_ALLOWED_OWNERS below (1).

	Requires JobService, DoorClient and the Notify remote from the base template.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
local DEFAULT_PRICE = 500
local DEFAULT_ALLOWED_OWNERS = 1
local LOCKPICK_SUCCESS_CHANCE = 0.10 -- 10%
local LOCKPICK_PASS_DURATION = 3 -- seconds the door is passable after a success
local CRIMINAL_JOB_ID = "Criminal" -- must match the Id in JobsConfig

---------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------
local door = script.Parent
if not door:IsA("BasePart") then
	error("The Door script must be placed inside a Part (or MeshPart).")
end

-- Attribute names can only contain letters, numbers and underscores
local doorId = tostring(door:GetAttribute("DoorId") or door.Name):gsub("[^%w_]", "_")
local price = door:GetAttribute("Price") or DEFAULT_PRICE
local maxOwners = door:GetAttribute("NumAllowedOwners") or DEFAULT_ALLOWED_OWNERS
if type(maxOwners) ~= "number" then
	maxOwners = DEFAULT_ALLOWED_OWNERS
end
maxOwners = math.max(1, math.floor(maxOwners))
local ownedAttribute = "Door_" .. doorId
local passAttribute = "DoorPass_" .. doorId

door:SetAttribute("DoorId", doorId)
door:SetAttribute("Price", price)
door:SetAttribute("NumAllowedOwners", maxOwners)
door.CanCollide = true -- stays solid on the server; owners get a client-side pass
CollectionService:AddTag(door, "PurchasableDoor")

local notify = ReplicatedStorage:WaitForChild("JobRemotes"):WaitForChild("Notify")
local purchaseDoor = ServerStorage:WaitForChild("PurchaseDoor")

-- Purchase prompt
local prompt = door:FindFirstChildOfClass("ProximityPrompt")
if not prompt then
	prompt = Instance.new("ProximityPrompt")
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = door
end
local buyHoldDuration = prompt.HoldDuration

-- Lets JobService's Lockpick tool talk to this door
local lockpickAttempt = Instance.new("BindableEvent")
lockpickAttempt.Name = "LockpickAttempt"
lockpickAttempt.Parent = door

---------------------------------------------------------------------
-- Owners + prompt text
---------------------------------------------------------------------
-- Names of the players who currently own this door (ownership is a player attribute set by JobService)
local function getOwners()
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

local function refreshPrompt()
	local owners = getOwners()
	if #owners >= maxOwners then
		-- Door is full: show who owns it instead of the purchase prompt
		prompt.ActionText = "Owned by " .. joinNames(owners)
		prompt.ObjectText = ""
		prompt.HoldDuration = 0
	else
		prompt.ActionText = "Buy Door"
		prompt.HoldDuration = buyHoldDuration
		if #owners > 0 then
			prompt.ObjectText = "$" .. price .. ", owned by " .. joinNames(owners)
		else
			prompt.ObjectText = "$" .. price
		end
	end
end

local function watchPlayer(p)
	p:GetAttributeChangedSignal(ownedAttribute):Connect(refreshPrompt)
end
for _, p in ipairs(Players:GetPlayers()) do
	watchPlayer(p)
end
Players.PlayerAdded:Connect(watchPlayer)
Players.PlayerRemoving:Connect(function()
	task.defer(refreshPrompt)
end)
refreshPrompt()

---------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------
prompt.Triggered:Connect(function(player)
	if player:GetAttribute(ownedAttribute) then
		notify:FireClient(player, "You already own this door.")
		return
	end

	local owners = getOwners()
	if #owners >= maxOwners then
		notify:FireClient(player, "Owned by " .. joinNames(owners))
		return
	end

	-- JobService does the final check and takes the money
	local _, message = purchaseDoor:Invoke(player, doorId, price, maxOwners)
	notify:FireClient(player, message)
end)

---------------------------------------------------------------------
-- Lockpicking
---------------------------------------------------------------------
lockpickAttempt.Event:Connect(function(player)
	if player:GetAttribute("JobId") ~= CRIMINAL_JOB_ID then
		notify:FireClient(player, "Only criminals can lockpick doors.")
		return
	end
	if player:GetAttribute(ownedAttribute) then
		notify:FireClient(player, "You already own this door.")
		return
	end

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
end)
