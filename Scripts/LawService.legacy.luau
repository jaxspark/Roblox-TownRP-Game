--[[
	LawService  (Script)
	Location: ServerScriptService > LawService

	Handles the Mayor's laws:
	  - JobService tells us when a Mayor uses the Megaphone -> we open the "Declare a Law" prompt on their screen
	  - The Mayor submits text -> we validate and filter it, store it, and notify everyone once
	  - Laws are stored as StringValues in ReplicatedStorage > Laws, so every client (including players who
	    join later) can read them for the Town Info UI
	  - The Mayor can delete laws from the Town Info UI

	Laws live as long as the server does (they are not saved between servers).
	Requires JobService (for the Megaphone and the Notify remote).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
local MAYOR_JOB_ID = "Mayor" -- must match the Id in JobsConfig
local MAX_LAWS = 15 -- most laws that can exist at once
local MIN_LENGTH = 3 -- characters
local MAX_LENGTH = 140 -- characters
local SUBMIT_COOLDOWN = 5 -- seconds between laws, so the Mayor can't spam notifications

---------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------
local notify = ReplicatedStorage:WaitForChild("JobRemotes"):WaitForChild("Notify")
local megaphoneUsed = ServerStorage:WaitForChild("MegaphoneUsed")

local remotes = Instance.new("Folder")
remotes.Name = "LawRemotes"
remotes.Parent = ReplicatedStorage

local openPrompt = Instance.new("RemoteEvent")
openPrompt.Name = "OpenLawPrompt"
openPrompt.Parent = remotes

local submitLaw = Instance.new("RemoteEvent")
submitLaw.Name = "SubmitLaw"
submitLaw.Parent = remotes

local deleteLaw = Instance.new("RemoteEvent")
deleteLaw.Name = "DeleteLaw"
deleteLaw.Parent = remotes

local lawsFolder = Instance.new("Folder")
lawsFolder.Name = "Laws"
lawsFolder:SetAttribute("MaxLength", MAX_LENGTH) -- the client prompt reads this
lawsFolder.Parent = ReplicatedStorage

local nextLawId = 0
local pendingPrompt = setmetatable({}, { __mode = "k" }) -- [player] = true after using the Megaphone
local lastSubmit = setmetatable({}, { __mode = "k" }) -- [player] = os.clock()

local function isMayor(player)
	return player:GetAttribute("JobId") == MAYOR_JOB_ID
end

---------------------------------------------------------------------
-- Megaphone -> open the prompt
---------------------------------------------------------------------
megaphoneUsed.Event:Connect(function(player)
	if not isMayor(player) then
		return
	end
	pendingPrompt[player] = true
	openPrompt:FireClient(player)
end)

---------------------------------------------------------------------
-- Declaring a law
---------------------------------------------------------------------
submitLaw.OnServerEvent:Connect(function(player, rawText)
	-- Only accept a law right after the Mayor used the Megaphone
	if not pendingPrompt[player] or not isMayor(player) then
		return
	end
	pendingPrompt[player] = nil

	if type(rawText) ~= "string" or #rawText > MAX_LENGTH * 4 then
		return
	end

	-- Collapse whitespace/newlines and trim
	local text = string.gsub(rawText, "%s+", " ")
	text = string.match(text, "^%s*(.-)%s*$")

	local length = utf8.len(text)
	if not length then
		return
	end
	if length < MIN_LENGTH then
		notify:FireClient(player, "Your law is too short.")
		return
	end
	if length > MAX_LENGTH then
		notify:FireClient(player, ("Your law is too long (max %d characters)."):format(MAX_LENGTH))
		return
	end
	if #lawsFolder:GetChildren() >= MAX_LAWS then
		notify:FireClient(player, ("There are already %d laws. Delete one first."):format(MAX_LAWS))
		return
	end

	local now = os.clock()
	if now - (lastSubmit[player] or -math.huge) < SUBMIT_COOLDOWN then
		notify:FireClient(player, "Please wait a few seconds before declaring another law.")
		return
	end
	lastSubmit[player] = now

	-- Roblox requires text from players to be filtered before other players see it
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok or type(filtered) ~= "string" or filtered == "" then
		warn("[LawService] Filtering failed: " .. tostring(filtered))
		notify:FireClient(player, "Your law could not be posted. Please try again.")
		return
	end

	-- We yielded while filtering, so check again
	if not player.Parent or not isMayor(player) then
		return
	end
	if #lawsFolder:GetChildren() >= MAX_LAWS then
		notify:FireClient(player, ("There are already %d laws. Delete one first."):format(MAX_LAWS))
		return
	end

	nextLawId += 1
	local law = Instance.new("StringValue")
	law.Name = tostring(nextLawId)
	law.Value = filtered
	law.Parent = lawsFolder

	-- Everyone currently in the server is notified, once
	notify:FireAllClients("New law: " .. filtered)
end)

---------------------------------------------------------------------
-- Deleting a law
---------------------------------------------------------------------
deleteLaw.OnServerEvent:Connect(function(player, lawId)
	if not isMayor(player) or type(lawId) ~= "string" then
		return
	end
	local law = lawsFolder:FindFirstChild(lawId)
	if law and law:IsA("StringValue") then
		law:Destroy()
	end
end)
