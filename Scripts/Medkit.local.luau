--[[
	MedicClient  (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > MedicClient

	While the medic holds the "First Aid" tool, clicking (or tapping) on another player tells the
	server who was clicked. The server checks the range (10 studs), cooldown (3 seconds) and does the healing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local firstAidEvent = ReplicatedStorage:WaitForChild("JobRemotes"):WaitForChild("FirstAid")

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return -- clicked on a button or other UI
	end
	local inputType = input.UserInputType
	if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
		return
	end

	local character = player.Character
	local tool = character and character:FindFirstChild("First Aid")
	if not tool or not tool:IsA("Tool") then
		return -- First Aid isn't equipped
	end

	-- Find what was clicked
	local camera = workspace.CurrentCamera
	local ray = camera:ScreenPointToRay(input.Position.X, input.Position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result then
		return
	end

	local model = result.Instance:FindFirstAncestorOfClass("Model")
	local target = model and Players:GetPlayerFromCharacter(model)
	if target then
		firstAidEvent:FireServer(target)
	end
end)
