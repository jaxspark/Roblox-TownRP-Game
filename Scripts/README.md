# Roblox Jobs Template

## Setup (about 2 minutes)

1. In Roblox Studio, **Game Settings > Security > Enable Studio Access to API Services** (needed for saving in Studio testing).
2. Create the three scripts and paste in the code:

| File | Instance type | Where to put it |
|---|---|---|
| `JobsConfig.lua` | **ModuleScript**, named `JobsConfig` | `ReplicatedStorage` |
| `JobService.server.lua` | **Script**, named `JobService` | `ServerScriptService` |
| `JobMenu.client.lua` | **LocalScript**, named `JobMenu` | `StarterPlayer > StarterPlayerScripts` |

3. Press Play. Walk around, press **M** (or click **Jobs**) to open the menu.

## How it works

- **Salary:** paid every 10 minutes of in-game time (`SALARY_INTERVAL`). The progress toward the next paycheck is saved, so leaving and rejoining doesn't reset it.
- **Cooldown:** 30 minutes between job changes (`JOB_CHANGE_COOLDOWN`), enforced on the server. The timestamp is saved, so rejoining doesn't bypass it. A new player's first job pick is free.
- **Saving:** Money, Job, last change time and salary progress are saved on leave, every 60 seconds, and on server shutdown. If loading fails, the player is kicked rather than risk overwriting their data.
- **Default job:** new players start as "Unemployed" (salary 0, hidden from the menu).

## Abilities

Each job in `JobsConfig.lua` can set `WalkSpeed`, `JumpPower`, `MaxHealth` and a list of `Tools`.

- Tools are looked up by name in `ServerStorage > JobTools` (create a Folder with that name and add your own Tool objects).
- If a tool isn't found, a grey placeholder block tool is created so everything works out of the box.
- The **Medkit** has built-in behavior: click to heal the nearest hurt player within 12 studs (+40 HP, 5s cooldown).

## Customizing

- Add/remove jobs or change salaries in `JobsConfig.lua`, so the menu updates automatically.
- Change `DATASTORE_NAME` in `JobService` to start fresh data (for example `PlayerData_v2`).
- Not included yet (easy next steps): job-restricted doors, limiting Mayor to one player, arrest/handcuff mechanics, gun shop.

## Purchasable doors

1. Put `DoorClient.client.lua` in `StarterPlayer > StarterPlayerScripts` as a **LocalScript** (one for the whole game).
2. Insert a Part for your door, then put a **Script** named `Door` inside it with the contents of `Door/Door.server.lua`. Copy/paste that Part for more doors.
3. Give every door a **unique name** (or a `DoorId` attribute). That name is what's saved to the player's data.
4. Optional: set a `Price` attribute on the door Part (default is 500).

Behavior:
- Walk up and hold the **Buy Door** prompt. If you have enough money it's deducted and you can walk through, including after rejoining.
- A **Criminal** holding the Lockpick near the door has a 10% chance per attempt to pass through for 3 seconds. The Lockpick has a 3 second cooldown.
- Settings (`DEFAULT_PRICE`, `LOCKPICK_SUCCESS_CHANCE`, `LOCKPICK_PASS_DURATION`) are at the top of `Door.server.lua`; the cooldown and range are at the top of the lockpick section in `JobService`.
- JobService was updated for this (door purchases are saved with the rest of the player's data), so replace your old copy with the new one.
