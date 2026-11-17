--[[
	JobsConfig  (ModuleScript)
	Location: ReplicatedStorage > JobsConfig

	Edit this file to add/remove jobs, change salaries or change abilities.
	Both the server and the client read from it.

	Abilities (all optional):
		WalkSpeed  - number
		JumpPower  - number
		MaxHealth  - number
		Tools      - list of tool names. The server looks for a Tool with that
		             name in ServerStorage > JobTools. If none exists, a simple
		             placeholder tool is created so the template works out of the box.

	Other job options:
		MaxPerServer - optional number. Limits how many players can hold this job at once per server.
]]

local JobsConfig = {}

-- Seconds of in-game time between paychecks
JobsConfig.SALARY_INTERVAL = 10 * 1

-- Seconds a player must wait between job changes
JobsConfig.JOB_CHANGE_COOLDOWN = 30 * 1

-- Job a brand-new player starts with (salary 0). Their first pick is free of cooldown.
JobsConfig.DEFAULT_JOB = "Unemployed"

JobsConfig.Jobs = {
	{
		Id = "Unemployed",
		Name = "Unemployed",
		Salary = 0,
		Description = "No job selected yet.",
		Selectable = false, -- hidden from the menu
		Abilities = {MaxHealth = 100, WalkSpeed = 15 },
	},
	{
		Id = "GunSalesman",
		Name = "Gun Salesman",
		Salary = 100,
		Description = "Sells weapons to other players.",
		Selectable = true,
		Abilities = { Tools = { "Catalog" }, MaxHealth = 120, WalkSpeed = 15 },
	},
	{
		Id = "Medic",
		Name = "Medic",
		Salary = 250,
		Description = "Heals nearby players with the Medkit.",
		Selectable = true,
		Abilities = { Tools = { "Medkit" }, MaxHealth = 140, WalkSpeed = 18 },
	},
	{
		Id = "Cook",
		Name = "Cook",
		Salary = 150,
		Description = "Prepares food for other players.",
		Selectable = true,
		Abilities = { Tools = { "Frying Pan" }, MaxHealth = 150, WalkSpeed = 15 },
	},
	{
		Id = "Carpenter",
		Name = "Carpenter",
		Salary = 150,
		Description = "Builds and repairs structures.",
		Selectable = true,
		Abilities = { Tools = { "Hammer" }, MaxHealth = 160, WalkSpeed = 15 },
	},
	{
		Id = "Mayor",
		Name = "Mayor",
		Salary = 300,
		Description = "Runs the city. Allows you to set laws.",
		Selectable = true,
		MaxPerServer = 1, -- only one mayor per server
		Abilities = { Tools = { "Megaphone" }, MaxHealth = 120, WalkSpeed = 14 },
	},
	{
		Id = "Sherriff",
		Name = "Sherriff",
		Salary = 250,
		Description = "Runs the police. Allows you to create arrest warrants.",
		Selectable = true,
		MaxPerServer = 1, -- only one sheriff per server
		Abilities = { Tools = { "Baton", "Handcuffs", "Arrest Warrant" }, MaxHealth = 150, WalkSpeed = 17 },
	},
	{
		Id = "PoliceOfficer",
		Name = "Police Officer",
		Salary = 200,
		Description = "Keeps the peace and arrests criminals.",
		Selectable = true,
		Abilities = { Tools = { "Baton", "Handcuffs" }, MaxHealth = 150, WalkSpeed = 18 },
	},
	{
		Id = "Criminal",
		Name = "Criminal",
		Salary = 50,
		Description = "Lives outside the law. Faster, but fragile.",
		Selectable = true,
		Abilities = { Tools = { "Lockpick" }, WalkSpeed = 21, MaxHealth = 90 },
	},
	{
		Id = "Chemist",
		Name = "Chemist",
		Salary = 200,
		Description = "Creates chems that give buffs when used.",
		Selectable = true,
		Abilities = { Tools = { "Chemistry Set" }, WalkSpeed = 15, MaxHealth = 130 },
	},
	{
		Id = "Hitman",
		Name = "Hitman",
		Salary = 150,
		Description = "Takes contracts to kill other citizens.",
		Selectable = true,
		Abilities = { Tools = { "Contract" }, WalkSpeed = 15, MaxHealth = 130 },
	},
	{
		Id = "Hobo",
		Name = "Hobo",
		Salary = 150,
		Description = "Asks for spare change with a donation bowl",
		Selectable = true,
		Abilities = { Tools = { "Donation Bowl" }, WalkSpeed = 17, MaxHealth = 110 },
	},
}

-- Lookup by Id (built automatically)
JobsConfig.ById = {}
for _, job in ipairs(JobsConfig.Jobs) do
	JobsConfig.ById[job.Id] = job
end

return JobsConfig
