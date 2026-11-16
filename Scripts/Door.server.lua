--[[
	Door  (Script)
	Location: put this Script INSIDE the door Part.

	- Any player with enough money can buy the door (ProximityPrompt) and then walk through it.
	  Purchases are saved, so owners keep access when they rejoin.
	- A player whose job is "Criminal" can use the Lockpick tool near the door:
	  10% chance to be able to walk through for 3 seconds.

	Optional attributes you can set on the door Part (Properties > Attributes):
	  DoorId (string)  - unique id for this door, letters/numbers/underscores only.
	                     Defaults to the Part's name, so give each door a UNIQUE name or DoorId.
	  Price  (number)  - price of the door. Defaults to DEFAULT_PRICE below.
	  
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
local ownedAttribute = "Door_" .. doorId
local passAttribute = "DoorPass_" .. doorId

door:SetAttribute("DoorId", doorId)
door:SetAttribute("Price", price)
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
prompt.ActionText = "Buy Door"
prompt.ObjectText = "$" .. price

-- Lets JobService's Lockpick tool talk to this door
local lockpickAttempt = Instance.new("BindableEvent")
lockpickAttempt.Name = "LockpickAttempt"
lockpickAttempt.Parent = door

---------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------
prompt.Triggered:Connect(function(player)
	if player:GetAttribute(ownedAttribute) then
		notify:FireClient(player, "You already own this door.")
		return
	end
	local _, message = purchaseDoor:Invoke(player, doorId, price)
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
