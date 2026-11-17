--[[
	DoorClient  (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > DoorClient

	One script for ALL doors. For every door tagged "PurchasableDoor" it makes the door
	passable for this player when they own it or have a temporary lockpick pass.
	(Player movement is simulated on the player's own client, so a local CanCollide
	change is what lets only that player walk through.)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local DOOR_TAG = "PurchasableDoor"

RunService.Heartbeat:Connect(function()
	local now = workspace:GetServerTimeNow()

	for _, door in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
		local doorId = door:GetAttribute("DoorId")
		if doorId and door:IsA("BasePart") then
			local owned = player:GetAttribute("Door_" .. doorId) == true
			local passUntil = player:GetAttribute("DoorPass_" .. doorId)
			local passable = owned or (passUntil ~= nil and passUntil > now)

			door.CanCollide = not passable
			door.LocalTransparencyModifier = passable and 0.6 or 0

			-- Owners don't need the buy prompt
			local prompt = door:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = not owned
			end
		end
	end
end)
