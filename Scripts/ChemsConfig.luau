--[[
	ChemsConfig  (ModuleScript)
	Location: ReplicatedStorage > ChemsConfig

	The chems the Chemist can create. Both the server and the chem menu read from this.

	Id is also the NAME of the Part in ReplicatedStorage that is spawned when the chem is
	created (e.g. a Part named "SpeedChem"). It is never shown in the menu.
	If that Part is missing, a small coloured placeholder is used so everything still works.

	Effect types:
	  Invisible       - invisible for Duration seconds
	  Speed           - walk speed +Amount (0.5 = +50%)
	  MaxHealth       - max health +Amount (0.3 = +30%)
	  Jump            - jump HEIGHT +Amount (2 = +200%)
	  DamageReduction - damage taken -Amount (1 = 100% less, i.e. invincible)

	Bonuses of the same type are ADDITIVE: two Speed Chems give +100%, not +125%.
]]

local ChemsConfig = {}

-- Seconds it takes to create any chem
ChemsConfig.CRAFT_TIME = 5

ChemsConfig.Chems = {
	{
		Id = "InvisChem",
		Name = "Invis Chem",
		Description = "Go invisible for 5 seconds.",
		Cooldown = 30,
		Effect = { Type = "Invisible", Duration = 5 },
		Color = Color3.fromRGB(190, 200, 255), -- placeholder colour only
	},
	{
		Id = "SpeedChem",
		Name = "Speed Chem",
		Description = "Speed increased by 50% for 1 minute.",
		Cooldown = 20,
		Effect = { Type = "Speed", Amount = 0.5, Duration = 60 },
		Color = Color3.fromRGB(255, 220, 60),
	},
	{
		Id = "MaxHealthChem",
		Name = "Max Health Chem",
		Description = "Max health increased by 30% for 2 minutes.",
		Cooldown = 30,
		Effect = { Type = "MaxHealth", Amount = 0.3, Duration = 120 },
		Color = Color3.fromRGB(240, 80, 80),
	},
	{
		Id = "JumpChem",
		Name = "Jump Chem",
		Description = "Jump height increased by 200% for 1 minute.",
		Cooldown = 20,
		Effect = { Type = "Jump", Amount = 2, Duration = 60 },
		Color = Color3.fromRGB(110, 220, 130),
	},
	{
		Id = "InvincibilityChem",
		Name = "Invincibility Chem",
		Description = "Damage reduced by 100% for 8 seconds.",
		Cooldown = 30,
		Effect = { Type = "DamageReduction", Amount = 1, Duration = 8 },
		Color = Color3.fromRGB(255, 235, 150),
	},
}

-- Lookup by Id (built automatically)
ChemsConfig.ById = {}
for _, chem in ipairs(ChemsConfig.Chems) do
	ChemsConfig.ById[chem.Id] = chem
end

return ChemsConfig
