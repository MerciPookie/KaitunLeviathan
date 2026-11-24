----- open source------pls join my discord server  
repeat task.wait() until game:IsLoaded() and game:GetService("Players").LocalPlayer
if _G.RJR_HUB_autobounty_Loaded then
	return
end

_G.RJR_HUB_autobounty_Loaded = true
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local CommF = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommF_")
local CommE = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommE")

local LocalPlayer = Players.LocalPlayer
local Net = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net")

-- Tap hotkeys 1, 2, 3, and 4 once shortly after joining a server.
task.spawn(function()
    task.wait(math.random(6, 7))
    for _, keyCode in ipairs({Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four}) do
        pcall(function() VirtualInputManager:SendKeyEvent(true, keyCode, false, game) end)
        task.wait(0.08)
        pcall(function() VirtualInputManager:SendKeyEvent(false, keyCode, false, game) end)
        task.wait(0.12)
    end
end)


-- [CHANGED] Gravity F / flee state is grouped to keep the chunk below Luau's local-register limit.
local GetCombatStatus -- assigned below; shared with Gravity TP recovery
local AutoBountyArmed -- forward-declared for Gravity TP recovery callbacks
local GravityState = {
    TP_DISTANCE = 2000,
    TP_RECOVERY_DISTANCE = 1000, -- reset recovery only if still farther than 1000 studs
    TP_ABOVE_STUDS = 700,
    FLEE_TWEEN_UP = 150,
    FLEE_ENEMY_ABOVE_MIN = 500,
    FLEE_ENEMY_ABOVE_MAX = 1000,
    FLEE_SKY_Y = 67000,
    REPEAT_F_ON_SAME_TARGET = true,
    GravityFEnabled = true,
    GravityFTeamReadyAt = math.huge,
    LastFSequenceTarget = nil,
    FSequenceRunning = false,
    LastInstantTPAt = 0,
    TeleportAttemptBusy = false,
    TeleportRecoveryInProgress = false,
    FailedTargetRoot = nil,
    FailedTeleportCount = 0,
    NextTeleportAttemptAt = 0,
    GTP = {}
}

-- [CHANGED] Read SetCooldown and invoke the Gravity RemoteFunction.
do
    local GTP = GravityState.GTP
    local function cooldownBar()
        local ok, bar = pcall(function()
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local main = pg and pg:FindFirstChild("Main")
            local skills = main and main:FindFirstChild("Skills")
            local gravity = skills and skills:FindFirstChild("Gravity-Gravity")
            local f = gravity and gravity:FindFirstChild("F")
            local cooldown = f and f:FindFirstChild("Cooldown")
            if cooldown and cooldown:IsA("GuiObject") then return cooldown end
            return nil
        end)
        return ok and bar or nil
    end

    -- getcooldown() reads the live Gravity F cooldown indicator. A visible,
    -- non-empty bar means the skill is still cooling down.
    local function getcooldown()
        local bar = cooldownBar()
        if not bar then return nil end
        if not bar.Visible then return false end
        return bar.AbsoluteSize.X > 1 and bar.Size.X.Scale > 0.001
    end

    function GTP.fReady()
        local ok, ready = pcall(function()
            local cooling = getcooldown()
            if cooling ~= nil then return cooling == false end
            -- On a fresh join the F cooldown widget may not exist until Gravity is equipped.
            -- Treat it as ready only when the equipped tool and its Humanoid RemoteFunction exist.
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not char or not hum or not char:FindFirstChild("Gravity-Gravity") then return false end
            for _, child in ipairs(hum:GetChildren()) do
                if child:IsA("RemoteFunction") then return true end
            end
            return false
        end)
        return ok and ready == true
    end

    -- Match the supplied Gravity Click TP exactly: prefer the unnamed
    -- Humanoid RemoteFunction, then fall back to the first RemoteFunction.
    local function findRemote(hum)
        if not hum then return nil end
        local direct
        pcall(function() direct = hum:FindFirstChild("") end)
        if direct and direct:IsA("RemoteFunction") then return direct end
        local ok, remote = pcall(function()
            for _, child in ipairs(hum:GetChildren()) do
                if child:IsA("RemoteFunction") then return child end
            end
            return nil
        end)
        return ok and remote or nil
    end

    local function findGravityTool(char)
        local tool = char and char:FindFirstChild("Gravity-Gravity")
        if tool and tool:IsA("Tool") then return tool end
        local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
        tool = backpack and backpack:FindFirstChild("Gravity-Gravity")
        if tool and tool:IsA("Tool") then return tool end
        return nil
    end

    local function equipGravity(char, hum)
        local ok, equipped = pcall(function()
            local tool = findGravityTool(char)
            if not tool then return false end
            if tool.Parent ~= char then hum:EquipTool(tool) end
            return tool.Parent == char or char:FindFirstChild("Gravity-Gravity") ~= nil
        end)
        return ok and equipped == true
    end

    function GTP.prepare()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not char or not hum or hum.Health <= 0 then return false end
        return equipGravity(char, hum)
    end

    -- Gravity F teleport. Keep the fruit equipped for one full second before
    -- resolving the Humanoid remote and firing the same request as Click TP.
    function GTP.teleportTo(targetRoot)
        if GravityState.TeleportAttemptBusy or GravityState.TeleportRecoveryInProgress
            or tick() < GravityState.NextTeleportAttemptAt then return false end
        if not targetRoot or not targetRoot.Parent or not GravityState.GravityFEnabled then return false end

        GravityState.TeleportAttemptBusy = true
        task.spawn(function()
            local invoked, opponentNear = false, false
            local ok, err = pcall(function()
                local deadline = tick() + 20
                local char, hum, tool

                -- Wait for the character and Gravity fruit to finish loading after join.
                while tick() < deadline and targetRoot and targetRoot.Parent do
                    char = LocalPlayer.Character
                    hum = char and char:FindFirstChildOfClass("Humanoid")
                    if char and hum and hum.Health > 0 then
                        tool = findGravityTool(char)
                        if tool then break end
                    end
                    task.wait(0.15)
                end
                if not tool or not char or not hum then return end

                -- Equip and deliberately keep Gravity selected for one second.
                if tool.Parent ~= char then hum:EquipTool(tool) end
                local equipDeadline = tick() + 2
                while tick() < equipDeadline and tool.Parent ~= char do
                    task.wait(0.05)
                end
                if tool.Parent ~= char then return end
                task.wait(1)

                -- Wait for Gravity F's cooldown to become ready, then add the
                -- requested 0.5-second buffer before sending the teleport request.
                local cooldownDeadline = tick() + 20
                local cooldownReady = false
                while tick() < cooldownDeadline and targetRoot and targetRoot.Parent do
                    if GTP.fReady() then
                        task.wait(0.5)
                        if GTP.fReady() then
                            cooldownReady = true
                            break
                        end
                    end
                    task.wait(0.05)
                end
                if not cooldownReady then return end

                -- Reacquire the live character, tool, and remote after the cooldown wait.
                char = LocalPlayer.Character
                hum = char and char:FindFirstChildOfClass("Humanoid")
                if not char or not hum or hum.Health <= 0 or not targetRoot or not targetRoot.Parent then return end
                tool = char:FindFirstChild("Gravity-Gravity")
                if not tool or tool.Parent ~= char then return end
                local remote = findRemote(hum)
                if not remote or not remote.Parent or not GTP.fReady() then return end

                local destination = targetRoot.CFrame
                -- Mark the attempt before invoking: InvokeServer can error even
                -- when the request was sent, and that still needs distance checking.
                invoked = true
                remote:InvokeServer("F", true, destination, Vector3.zero, true)

                -- Success is determined ONLY by distance to the opponent.
                -- Character movement from its previous position is not checked.
                task.wait(1.25)
                local liveChar = LocalPlayer.Character
                local liveRoot = liveChar and liveChar:FindFirstChild("HumanoidRootPart")
                if liveRoot and targetRoot and targetRoot.Parent then
                    opponentNear = (targetRoot.Position - liveRoot.Position).Magnitude
                        <= GravityState.TP_RECOVERY_DISTANCE
                end
            end)

            if ok and invoked and opponentNear then
                GravityState.LastInstantTPAt = tick()
                GravityState.FailedTargetRoot = nil
                GravityState.FailedTeleportCount = 0
                GravityState.NextTeleportAttemptAt = tick() + 1.5
            else
                -- Count a failed attempt only when the server request was actually sent
                -- and the opponent is still more than 1000 studs away.
                if invoked and targetRoot and targetRoot.Parent and GravityState.GravityFEnabled then
                    task.wait(0.25)

                    local liveChar = LocalPlayer.Character
                    local liveRoot = liveChar and liveChar:FindFirstChild("HumanoidRootPart")
                    local opponentStillFar = liveRoot
                        and (targetRoot.Position - liveRoot.Position).Magnitude > GravityState.TP_RECOVERY_DISTANCE

                    if opponentStillFar then
                        if GravityState.FailedTargetRoot ~= targetRoot then
                            GravityState.FailedTargetRoot = targetRoot
                            GravityState.FailedTeleportCount = 0
                        end
                        GravityState.FailedTeleportCount += 1
                        GravityState.NextTeleportAttemptAt = tick() + 0.75

                        -- Restore the two-failed-attempt threshold before recovery.
                        if GravityState.FailedTeleportCount >= 2
                            and not GravityState.TeleportRecoveryInProgress then
                            GravityState.TeleportRecoveryInProgress = true
                            task.spawn(function()
                                local safeChecks = 0
                                while GravityState.GravityFEnabled and AutoBountyArmed
                                    and GravityState.FailedTargetRoot == targetRoot
                                    and targetRoot and targetRoot.Parent do
                                    local currentChar = LocalPlayer.Character
                                    local currentRoot = currentChar and currentChar:FindFirstChild("HumanoidRootPart")
                                    if not currentRoot then
                                        safeChecks = 0
                                        task.wait(0.5)
                                        continue
                                    end

                                    -- Keep checking opponent distance, never local movement.
                                    local distance = (targetRoot.Position - currentRoot.Position).Magnitude
                                    if distance <= GravityState.TP_RECOVERY_DISTANCE then
                                        -- The opponent is close enough; do not reset.
                                        break
                                    end

                                    -- Require the exact NotInCombat state. InCombatNoRisk
                                    -- is still combat and must never trigger a reset.
                                    local status = GetCombatStatus and GetCombatStatus() or "BountyAtRisk"
                                    if status == "NotInCombat" then
                                        safeChecks += 1
                                        if safeChecks >= 2 then
                                            local liveHum = currentChar:FindFirstChildOfClass("Humanoid")
                                            local finalRoot = currentChar:FindFirstChild("HumanoidRootPart")
                                            if liveHum and liveHum.Health > 0 and finalRoot
                                                and GravityState.FailedTargetRoot == targetRoot
                                                and targetRoot and targetRoot.Parent
                                                and (targetRoot.Position - finalRoot.Position).Magnitude > GravityState.TP_RECOVERY_DISTANCE
                                                and GetCombatStatus and GetCombatStatus() == "NotInCombat" then
                                                GravityState.FailedTeleportCount = 0
                                                GravityState.FailedTargetRoot = nil
                                                -- Reset only after both safety checks pass.
                                                liveHum.Health = 0
                                            end
                                            break
                                        end
                                    else
                                        safeChecks = 0
                                    end
                                    task.wait(0.5)
                                end
                                GravityState.TeleportRecoveryInProgress = false
                            end)
                        end
                    else
                        -- The opponent is within 1000 studs; treat this as success.
                        GravityState.LastInstantTPAt = tick()
                        GravityState.FailedTargetRoot = nil
                        GravityState.FailedTeleportCount = 0
                        GravityState.NextTeleportAttemptAt = tick() + 1.5
                    end
                else
                    -- No request was sent (for example, cooldown/tool setup failed):
                    -- retry normally, but do not count it as a failed teleport attempt.
                    GravityState.NextTeleportAttemptAt = tick() + 0.75
                end
                if not ok then warn("[Merciful Gravity TP] " .. tostring(err)) end
            end
            GravityState.TeleportAttemptBusy = false
        end)
        return true
    end

    function GTP.pressF(aimPos)
        local request = { Started = false, Finished = false, Succeeded = false }
        task.spawn(function()
            local ok = pcall(function()
                if not GravityState.GravityFEnabled or tick() < GravityState.GravityFTeamReadyAt or not GTP.fReady() then return end
                local char = LocalPlayer.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if not char or not hum or hum.Health <= 0 then return end
                if not equipGravity(char, hum) then return end
                local remote = findRemote(hum)
                if not remote or not GTP.fReady() then return end
                request.Started = true
                remote:InvokeServer("F", true, CFrame.new(aimPos), Vector3.new(0, 0, 0), true)
            end)
            request.Succeeded = ok and request.Started
            request.Finished = true
        end)
        return request
    end
    function GTP.runFSequence(aimProvider, shouldAbort, onFirstCooldown)
        if not GravityState.GravityFEnabled then return end
        local function aborted()
            local ok, result = pcall(shouldAbort)
            return not ok or result == true or not GravityState.GravityFEnabled
        end
        local function waitUntilReady()
            while true do
                if aborted() then return false end
                pcall(GTP.prepare)
                if GTP.fReady() and tick() >= GravityState.GravityFTeamReadyAt then return true end
                RunService.Heartbeat:Wait()
            end
        end
        if not waitUntilReady() or aborted() then return false end
        local ok, aimPos = pcall(aimProvider)
        if not ok or not aimPos or aborted() then return false end

        -- Keep Fruit F as the exclusive first action after an instant teleport.
        -- Retry until the actual cooldown UI changes; a successful InvokeServer
        -- return alone is not treated as proof that the move was accepted.
        local function fireAndConfirm(position)
            while not aborted() do
                if not GTP.fReady() and not waitUntilReady() then return false end
                local request = GTP.pressF(position)
                while request and not request.Finished and GTP.fReady() do
                    if aborted() then return false end
                    RunService.Heartbeat:Wait()
                end
                if not GTP.fReady() then return true end
                if aborted() then return false end

                -- The call completed but no cooldown began: refresh the aim and retry.
                task.wait(0.15)
                local success, refreshed = pcall(aimProvider)
                if not success or not refreshed then return false end
                position = refreshed
            end
            return false
        end

        if not fireAndConfirm(aimPos) or aborted() then return false end
        if onFirstCooldown then pcall(onFirstCooldown) end
        return true
    end
end

local LangEnglish = (function()
    local env = getgenv and getgenv()
    if type(env) ~= "table" then return false end
    local lang = env.Language
    if type(lang) ~= "string" then lang = env.language end
    if type(lang) ~= "string" then return false end
    lang = string.lower(lang)
    return lang == "english" or lang == "en" or lang == "eng"
end)()

local LangMap = {
    ["Water Walk / Water Protection"] = "Water Walk / Water Protection",
    ["Thickens the water plane and protects chase/Soru destinations"] = "Thickens the water plane and protects chase/Soru destinations",
    ["V4 Only"] = "V4 Only",
    ["Only cast this category's selected skills while transformed into V4"] = "Only cast this category's selected skills while transformed into V4",
    ["FPS Boost"] = "FPS Boost",
    ["Simplifies map and effects with frame-batched processing"] = "Simplifies map and effects with frame-batched processing",
    ["Restoring visuals; the original flag is unavailable, rejoin to reset it"] = "Restoring visuals; the original flag is unavailable, rejoin to reset it",
    ["Script is already running, do not execute again!"] = "Script is already running, do not execute again!",
    ["Basic"] = "Basic",
    ["Auto Bounty"] = "Auto Bounty",
    ["Skill Config"] = "Skill Config",
    ["Combat Settings"] = "Combat Settings",
    ["Server"] = "Server",
    ["Settings"] = "Settings",
    ["Self"] = "Self",
    ["Left the server"] = "Left the server",
    ["Character not loaded"] = "Character not loaded",
    ["Missing Humanoid/HRP"] = "Missing Humanoid/HRP",
    ["Dead"] = "Dead",
    ["In raid"] = "In raid",
    ["Safe zone, not in combat"] = "Safe zone, not in combat",
    ["PvP disabled"] = "PvP disabled",
    ["1v1 arena"] = "1v1 arena",
    ["Same team (Marines)"] = "Same team (Marines)",
    ["Level unreadable"] = "Level unreadable",
    ["Level gap > 700"] = "Level gap > 700",
    ["Local character not ready"] = "Local character not ready",
    ["Distance > 30000"] = "Distance > 30000",
    ["Lock time reached"] = "Lock time reached",
    ["Info panel update error"] = "Info panel update error",
    ["Unknown"] = "Unknown",
    ["Bounty"] = "Bounty",
    ["Runtime"] = "Runtime",
    ["Random"] = "Random",
    ["Server Hop"] = "Server Hop",
    ["No server matched the region filter, retrying later"] = "No server matched the region filter, retrying later",
    ["Bounty at risk before teleport, aborted: keep ascending"] = "Bounty at risk before teleport, aborted: keep ascending",
    ["No server matched player/bounty filters, relaxed\nHop to: %s | %d players | bounty %s"] = "No server matched player/bounty filters, relaxed\nHop to: %s | %d players | bounty %s",
    ["Server matched\nRegion: %s | Players: %d | Bounty: %s"] = "Server matched\nRegion: %s | Players: %d | Bounty: %s",
    ["Target appeared before teleport, cancelled"] = "Target appeared before teleport, cancelled",
    ["Bounty at risk: hop blocked, ascending until it clears"] = "Bounty at risk: hop blocked, ascending until it clears",
    ["No target in this server, hopping..."] = "No target in this server, hopping...",
    ["Bounty became at risk during hop, aborted: keep ascending"] = "Bounty became at risk during hop, aborted: keep ascending",
    ["Risk cleared, continuing hop"] = "Risk cleared, continuing hop",
    ["Target %s no longer valid (%s), switching"] = "Target %s no longer valid (%s), switching",
    ["Locked %s for %.0f s (limit %d s), switching (that player is skipped for %d s)"] = "Locked %s for %.0f s (limit %d s), switching (that player is skipped for %d s)",
    ["Target appeared during hop, aborted and engaging"] = "Target appeared during hop, aborted and engaging",
    ["Main loop error (auto recovered)"] = "Main loop error (auto recovered)",
    ["Entered a new server, searching for a target"] = "Entered a new server, searching for a target",
    [" Skills"] = " Skills",
    [" Charge"] = " Charge",
    ["Melee"] = "Melee",
    ["Sword"] = "Sword",
    ["Fruit"] = "Fruit",
    ["Gun"] = "Gun",
    ["Fast Attack"] = "Fast Attack",
    ["Fruit M1"] = "Fruit M1",
    ["Dragonstorm"] = "Dragonstorm",
    ["Void Fruit M1"] = "Void Fruit M1",
    ["Combat Assist"] = "Combat Assist",
    ["Auto Enable PvP"] = "Auto Enable PvP",
    ["Auto Buso"] = "Auto Buso",
    ["Auto Ken"] = "Auto Ken",
    ["Auto V3"] = "Auto V3",
    ["Auto use race V3 ability"] = "Auto use race V3 ability",
    ["Max Stay Per Server (s)"] = "Max Stay Per Server (s)",
    ["Server stay reached %d min, hopping as soon as the bounty risk clears"] = "Server stay reached %d min, hopping as soon as the bounty risk clears",
    ["Auto Soru"] = "Auto Soru",
    ["Auto Flee"] = "Auto Flee",
    ["Flee HP threshold (%)"] = "Flee HP threshold (%)",
    ["Hold Weapon"] = "Hold Weapon",
    ["Select Team"] = "Select Team",
    ["Enable ESP"] = "Enable ESP",
    ["Show Name"] = "Show Name",
    ["Show Level"] = "Show Level",
    ["Show Health"] = "Show Health",
    ["Show Distance"] = "Show Distance",
    ["Show PvP State"] = "Show PvP State",
    ["Font Size"] = "Font Size",
    ["Server Region"] = "Server Region",
    ["Hop Player Range"] = "Hop Player Range",
    ["Only hop to servers within this player range"] = "Only hop to servers within this player range",
    ["Hop Bounty Range"] = "Hop Bounty Range",
    ["Only hop to servers above this bounty"] = "Only hop to servers above this bounty",
    ["> 3M"] = "> 3M",
    ["> 5M"] = "> 5M",
    ["> 10M"] = "> 10M",
    ["> 15M"] = "> 15M",
    ["> 25M"] = "> 25M",
    ["> 35M"] = "> 35M",
    ["> 50M"] = "> 50M",
    ["Manual Hop"] = "Manual Hop",
    ["Current Server ID"] = "Current Server ID",
    ["Lock Time"] = "Lock Time",
    ["Executor does not support writefile"] = "Executor does not support writefile",
    ["This executor does not support writefile"] = "This executor does not support writefile",
    ["This executor does not support readfile"] = "This executor does not support readfile",
    ["Save Config"] = "Save Config",
    ["Save Config Failed"] = "Save Config Failed",
    ["Serialize failed: "] = "Serialize failed: ",
    [" / fallback failed too: "] = " / fallback failed too: ",
    ["\n(settings will not be saved, check executor permissions)"] = "\n(settings will not be saved, check executor permissions)",
    ["Failed to hook auto save on some tabs, changes there may not be written:\n"] = "Failed to hook auto save on some tabs, changes there may not be written:\n",
    ["[ PVP ON ]"] = "[ PVP ON ]",
    ["；"] = "; ",
    ["[ PVP OFF ]"] = "[ PVP OFF ]",
    ["Saved to "] = "Saved to ",
    ["Save failed: "] = "Save failed: ",
    ["Load Config"] = "Load Config",
    ["Config file not found"] = "Config file not found",
    ["Read failed"] = "Read failed",
    ["Invalid config format"] = "Invalid config format",
    ["Old config detected, skill charge unified to "] = "Old config detected, skill charge unified to ",
    [" s"] = " s",
    ["Config loaded and applied"] = "Config loaded and applied",
    ["Config Save"] = "Config Save",
    ["Auto Save On Change"] = "Auto Save On Change",
    ["Auto Load On Start"] = "Auto Load On Start",
    ["Delete Config"] = "Delete Config",
    ["Export Config to Clipboard"] = "Export Config to Clipboard",
    ["Copies getgenv().Config = {...}; paste it before the loader line to import"] = "Copies getgenv().Config = {...}; paste it before the loader line to import",
    ["Config file deleted"] = "Config file deleted",
    ["No config to delete"] = "No config to delete",
    ["Script loaded"] = "Script loaded",
    ["WindUI failed to load: put windui.lua in the executor root, or check your network"] = "WindUI failed to load: put windui.lua in the executor root, or check your network",
    ["Auto Save"] = "Auto Save",
    ["Missing UI widgets: "] = "Missing UI widgets: ",
    ["Widget callback error: "] = "Widget callback error: ",
    ["DC Server"] = "DC Server",
    ["Click to Copy DC Link"] = "Click to Copy DC Link",
    ["Copied"] = "Copied",
    ["DC link copied"] = "DC link copied",
}

local function T(text)
    if not LangEnglish then return text end
    return LangMap[text] or text
end

if getgenv and getgenv().AutoBountyMainLoaded and getgenv().AutoBountyMainReady then
    return
end
if getgenv then
    getgenv().AutoBountyMainLoaded = true
end

local LastCaughtError = nil

local function SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        LastCaughtError = tostring(err)
    end
    return ok, err
end

local SaveConfig
local ConfigLoading = true

local InjectedConfig = (function()
    local env = getgenv and getgenv()
    local cfg = env and env.Config
    if type(cfg) ~= "table" then return nil end
    return cfg
end)()
AutoBountyArmed = false -- restored from saved preferences after configuration loads

local Settings = {
    AutoBounty = false,
    LockAtReward = false,
    RewardLockTarget = 30000000,
    CustomTweenSpeed = 200,
    BypassTweenSpeed = false,
    SkillOrder = {},
    UseSkillCombo = false,
    ComboPick = "None",
    MeleeSkills = { "Z", "X", "C" },
    SwordSkills = { "Z", "X" },
    FruitSkills = { "X" },
    GunSkills = { "Z", "X" },
    V4Only = { Melee = false, Sword = false, ["Blox Fruit"] = false, Gun = false },
    FPSBoost = false,
    WaterWalk = true,
    Hold = {
        Melee = { Z = 0.1, X = 0.1, C = 0.1, V = 0.1, F = 0.1 },
        Sword = { Z = 0.1, X = 0.1, C = 0.1, V = 0.1, F = 0.1 },
        ["Blox Fruit"] = { Z = 0.1, X = 0.1, C = 0.1, V = 0.1, F = 0.1 },
        Gun = { Z = 0.1, X = 0.1, C = 0.1, V = 0.1, F = 0.1 }
    },
    FastAttack = false,
    FruitM1 = false,
    Dragonstorm = false,
    VoidFruitM1 = false,
    GravityF = true,
    AutoHaki = true,
    AutoKen = true,
    AutoV3 = true,
    AutoV4 = false,
    AutoSoru = false,
    AutoEnablePVP = true,
    AutoFlee = false,
    AutoFleeHP = 30,
    ESP = false,
    ESP_ShowName = true,
    ESP_ShowLevel = true,
    ESP_ShowHealth = true,
    ESP_ShowDistance = true,
    ESP_ShowPVP = true,
    ESP_FontSize = 14,
    LockTime = 90,
    HoldWeapon = "Melee",
    ServerRegion = "Singapore",
    HopPlayerRange = "1-12",
    HopBountyRange = T("> 3M"),
    AutoLoadConfig = true,
    AutoSaveConfig = true,
    -- Auto-execute only runs URLs that return raw Lua source. Use a source you trust.
    AutoExecute = false,
    AutoExecuteURL = "",
    WebhookEnabled = false,
    WebhookUrl = "",
    HideWebhookUsername = false,
    SelectTeam = "Pirates",
    MaxStaySeconds = 360,
    ConfigVersion = 2
}

local INTERNAL_CONFIG_KEYS = {
    BountyBase = true,
    AutoBountyBountyBase = true,
    AutoBountyEarned = true,
    AutoBountyRunTime = true
}

local OBSOLETE_CONFIG_KEYS = {
    LockCounts = true,
    Blacklist = true,
    FastAttackMode = true,
    FastAttackMobs = true,
    FastAttackPlayers = true
}

local function IsSkippedConfigKey(key)
    return INTERNAL_CONFIG_KEYS[key] or OBSOLETE_CONFIG_KEYS[key]
end

local function ApplyConfigTable(data)
    if type(data) ~= "table" then return false end
    for key, value in pairs(data) do
        if key ~= "AutoSaveConfig" and key ~= "AutoLoadConfig" and key ~= "Hold" and key ~= "V4Only" and not IsSkippedConfigKey(key) then
            Settings[key] = value
        end
    end
    if type(data.V4Only) == "table" then
        for tip in pairs(Settings.V4Only) do
            if type(data.V4Only[tip]) == "boolean" then Settings.V4Only[tip] = data.V4Only[tip] end
        end
    end
    if type(data.Hold) == "table" then
        for weaponTip, holds in pairs(data.Hold) do
            if type(holds) == "table" and Settings.Hold[weaponTip] then
                for key, value in pairs(holds) do
                    if Settings.Hold[weaponTip][key] ~= nil and tonumber(value) then
                        Settings.Hold[weaponTip][key] = math.clamp(math.floor(tonumber(value) * 10 + 0.5) / 10, 0.1, 1)
                    end
                end
            end
        end
    end
    return true
end

ApplyConfigTable(InjectedConfig)
GravityState.GravityFEnabled = Settings.GravityF ~= false
if GravityState.GravityFEnabled then Settings.HoldWeapon = "Blox Fruit" end

GravityState.RefreshTeamDelay = function()
    local ok, teamName = pcall(function() return LocalPlayer.Team and LocalPlayer.Team.Name end)
    if ok and teamName then
        -- Apply the short delay only after an actual team change, not at startup.
        GravityState.GravityFTeamReadyAt = tick() + math.random(300, 500) / 100
    else
        GravityState.GravityFTeamReadyAt = 0
    end
end
GravityState.GravityFTeamReadyAt = 0
pcall(function()
    LocalPlayer:GetPropertyChangedSignal("Team"):Connect(GravityState.RefreshTeamDelay)
end)

local TeamConfigReady = false

local function ApplyTeam(team)
    if not TeamConfigReady or not team or team == "" then return end
    local cur = LocalPlayer.Team
    if cur and cur.Name == team then return end
    pcall(function() CommF:InvokeServer("SetTeam", team) end)
    pcall(function() CommF:InvokeServer("SetTeam2", team) end)
end

do
    task.spawn(function()
        local configWait = tick() + 30
        while not TeamConfigReady and tick() < configWait do
            task.wait(0.05)
        end
        TeamConfigReady = true

        local deadline = tick() + 20
        local nextTry = 0
        while tick() < deadline do
            local team = LocalPlayer.Team
            if team and team.Name == Settings.SelectTeam then break end
            if tick() >= nextTry then
                SafeCall(ApplyTeam, Settings.SelectTeam)
                nextTry = tick() + 1.5
            end
            task.wait(0.2)
        end
    end)
end

local CurrentTarget = nil
local CurrentTargetRoot = nil
local TargetDeathConnection = nil
local ChaseActive = false
local ChaseConnection = nil
local ActiveTween = nil
local ChaseSample = nil
local Random = Random.new()

local TargetLockStart = 0
local TargetInvalidSince = nil
local TempSkipUntil = {}
local OffsetAngle = Random:NextNumber(0, math.pi * 2)
local NextOffsetRefresh = 0
local FleeActive = false
local SoruLastTime = 0

local NextTargetSwitch = 0
local TargetLostTime = 0
local LastScanTime = 0

local Stay = {
    Combat = {},
    Enter = tick(),
    Armed = false,
    Limit = function(self)
        local v = tonumber(Settings.MaxStaySeconds) or 360
        if v < 60 then v = 60 end
        return v
    end,
    Elapsed = function(self)
        return tick() - self.Enter
    end,
    Reached = function(self)
        if not AutoBountyArmed then return false end
        return self:Elapsed() >= self:Limit()
    end
}

-- Visual changes are queued and reversible; no collision, hitboxes or remotes are removed.
do
    local Boost = {
        Enabled = false, Saved = setmetatable({}, { __mode = "k" }),
        Queue = {}, Head = 1, Tail = 0, Seen = setmetatable({}, { __mode = "k" }),
        Lighting = game:GetService("Lighting"), FlagName = "RemoteEventSingleInvocationSizeLimit"
    }
    Stay.Performance = Boost
    function Boost:Write(obj, property, value)
        pcall(function()
            local old = obj[property]
            if old == value then return end
            local saved = self.Saved[obj]
            if not saved then saved = {}; self.Saved[obj] = saved end
            if not saved[property] then saved[property] = { Original = old } end
            saved[property].Applied = value
            obj[property] = value
        end)
    end
    function Boost:Protected(obj)
        local characters = Workspace:FindFirstChild("Characters")
        local cursor = obj
        while cursor and cursor ~= Workspace and cursor ~= self.Lighting do
            if cursor == Workspace.CurrentCamera or cursor == characters
                or cursor:IsA("Tool") or cursor:IsA("GuiBase2d")
                or (cursor:IsA("Model") and cursor:FindFirstChildOfClass("Humanoid")) then return true end
            cursor = cursor.Parent
        end
        return false
    end
    function Boost:Apply(obj)
        if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")
            or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") then
            if not obj.Parent or obj.Parent.Name ~= "ElectricFire" then self:Write(obj, "Enabled", false) end
        elseif obj:IsA("PostEffect") then
            self:Write(obj, "Enabled", false)
        elseif obj:IsA("BasePart") then
            self:Write(obj, "CastShadow", false)
            local map = Workspace:FindFirstChild("Map")
            if map and obj:IsDescendantOf(map) then
                self:Write(obj, "Material", Enum.Material.SmoothPlastic)
                self:Write(obj, "Reflectance", 0)
            end
        elseif obj:IsA("Decal") or obj:IsA("Texture") then
            local map = Workspace:FindFirstChild("Map")
            if map and obj:IsDescendantOf(map) then self:Write(obj, "Transparency", 1) end
        end
    end
    function Boost:Push(obj, walk)
        self.Tail = self.Tail + 1
        self.Queue[self.Tail] = { Object = obj, Walk = walk }
    end
    function Boost:Drain()
        local began, count = os.clock(), 0
        while self.Head <= self.Tail and count < 100 and os.clock() - began < 0.003 do
            local item = self.Queue[self.Head]
            self.Queue[self.Head] = nil
            self.Head = self.Head + 1
            count = count + 1
            local obj = item.Object
            if self.Enabled then
                if obj.Parent and not self.Seen[obj] and not self:Protected(obj) then
                    self.Seen[obj] = true
                    pcall(self.Apply, self, obj)
                    if item.Walk then
                        for _, child in ipairs(obj:GetChildren()) do self:Push(child, true) end
                    end
                end
            else
                local saved = self.Saved[obj]
                if saved then
                    for property, record in pairs(saved) do
                        pcall(function()
                            if obj[property] == record.Applied then obj[property] = record.Original end
                        end)
                    end
                    self.Saved[obj] = nil
                end
            end
        end
        if self.Head > self.Tail then
            self.Queue, self.Head, self.Tail = {}, 1, 0
            if not self.Enabled and self.Worker then self.Worker:Disconnect(); self.Worker = nil end
        end
    end
    function Boost:SetEnabled(value)
        value = value == true
        if self.Enabled == value then return end
        self.Enabled = value
        if self.WorldAdded then self.WorldAdded:Disconnect(); self.WorldAdded = nil end
        if self.LightAdded then self.LightAdded:Disconnect(); self.LightAdded = nil end
        self.Queue, self.Head, self.Tail = {}, 1, 0
        self.Seen = setmetatable({}, { __mode = "k" })
        if value then
            if not self.FlagApplied and type(setfflag) == "function" then
                if type(getfflag) == "function" then
                    local ok, old = pcall(getfflag, self.FlagName)
                    if ok and old ~= nil then self.FlagOriginal = tostring(old) end
                end
                self.FlagApplied = pcall(setfflag, self.FlagName, "1500")
            end
            self:Write(self.Lighting, "GlobalShadows", false)
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            if terrain then
                self:Write(terrain, "WaterWaveSize", 0)
                self:Write(terrain, "WaterWaveSpeed", 0)
                self:Write(terrain, "WaterReflectance", 0)
            end
            pcall(function() self:Write(settings().Rendering, "QualityLevel", Enum.QualityLevel.Level01) end)
            self:Push(Workspace, true)
            self:Push(self.Lighting, true)
            self.WorldAdded = Workspace.DescendantAdded:Connect(function(obj) self:Push(obj, false) end)
            self.LightAdded = self.Lighting.DescendantAdded:Connect(function(obj) self:Push(obj, false) end)
        else
            for obj in pairs(self.Saved) do self:Push(obj, false) end
            if self.FlagApplied then
                if self.FlagOriginal and type(setfflag) == "function" then
                    if pcall(setfflag, self.FlagName, self.FlagOriginal) then self.FlagApplied = false end
                else
                    warn("[FPS Boost] " .. T("Restoring visuals; the original flag is unavailable, rejoin to reset it"))
                end
            end
        end
        if not self.Worker then
            self.Worker = RunService.Heartbeat:Connect(function() SafeCall(self.Drain, self) end)
        end
    end
end

local WeaponLockUntil = 0
-- Hold Weapon waits 3 seconds after a team is assigned; use a short
-- server-entry fallback only while the player has not joined a team yet.
local HoldWeaponReadyAt = tick() + (LocalPlayer.Team and 3 or 5)
pcall(function()
    LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
        HoldWeaponReadyAt = tick() + 3
    end)
end)
local SkillLoopThread = nil

local Aim = {
    Pos = nil,
    Part = nil,
    Position = nil,
    MouseHookInstalled = false,
    GameHookReady = false,
    MouseMod = nil,
    MouseStore = nil,
    MouseMT = nil,
    MouseGame = nil
}

pcall(function()
    for _, conn in pairs(getconnections(LocalPlayer.Idled)) do
        conn:Disable()
    end
end)
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

local function GetHRP(plr)
    plr = plr or LocalPlayer
    local char = plr and plr.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function GetHumanoid(plr)
    plr = plr or LocalPlayer
    local char = plr and plr.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

-- Keep only the current engagement when crossing a safe-zone boundary.
function Stay:UpdateEngagement(plr)
    local char = plr and plr.Character
    local ownChar = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local ownHum = ownChar and ownChar:FindFirstChildOfClass("Humanoid")
    local root, ownRoot = GetHRP(plr), GetHRP(LocalPlayer)
    local fight = self.Combat
    if fight.Player ~= plr or fight.Character ~= char or fight.OwnCharacter ~= ownChar then
        fight = { Player = plr, Character = char, OwnCharacter = ownChar }
        self.Combat = fight
    end
    if not hum or not ownHum or hum.Health <= 0 or ownHum.Health <= 0 then
        fight.Engaged = false
        return
    end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("Main")
    local hud = main and main:FindFirstChild("BottomHUDList")
    local combatUI = hud and hud:FindFirstChild("InCombat")
    local inCombat = ownChar:GetAttribute("InCombat") == true or (combatUI and combatUI.Visible == true)
    if not inCombat then
        fight.Engaged = false
    elseif root and ownRoot and (root.Position - ownRoot.Position).Magnitude <= 150 then
        -- HUD alone may describe fighting somebody else: require target combat or observed damage.
        if char:GetAttribute("InCombat") == true
            or (fight.Health and hum.Health < fight.Health)
            or (fight.OwnHealth and ownHum.Health < fight.OwnHealth) then
            fight.Engaged = true
        end
    end
    fight.Health, fight.OwnHealth = hum.Health, ownHum.Health
end

local function EquipTool(tool)
    local hum = GetHumanoid(LocalPlayer)
    if not hum or hum.Sit or not tool then return false end
    local character = LocalPlayer.Character
    if not character then return false end
    if tool.Parent ~= character then
        pcall(function() hum:EquipTool(tool) end)
        local deadline = tick() + 0.4
        repeat
            task.wait(0.03)
            character = LocalPlayer.Character
            if not character then return false end
        until tool.Parent == character or tick() >= deadline
    end
    return tool.Parent == LocalPlayer.Character
        and LocalPlayer.Character:FindFirstChildOfClass("Tool") == tool
end

local function FindWeaponTool(weaponTip)
    local function scan(container)
        if not container then return nil end
        for _, item in ipairs(container:GetChildren()) do
            if item:IsA("Tool") and item.ToolTip == weaponTip then
                return item
            end
        end
        return nil
    end
    return scan(LocalPlayer.Character) or scan(LocalPlayer:FindFirstChild("Backpack"))
end

local function LockWeapon(owner, duration)
    local now = tick()
    WeaponLockUntil = math.max(WeaponLockUntil, now + duration)
end

local function IsWeaponLocked()
    return tick() < WeaponLockUntil
end

local SafeZonePositions = {
    World1 = {
        { pos = Vector3.new(-3000, 250, 2057), radius = 700 },
        { pos = Vector3.new(1101, 16, 1446), radius = 400 }
    },
    World2 = {
        { pos = Vector3.new(-12, 29, 2840), radius = 200 },
        { pos = Vector3.new(-376, 149, 307), radius = 150 },
        { pos = Vector3.new(-6437, 306, -4730), radius = 150 }
    },
    World3 = {
        { pos = Vector3.new(-338, 21, 5539), radius = 200 },
        { pos = Vector3.new(-12550, 337, -7506), radius = 400 },
        { pos = Vector3.new(-5046, 315, -2993), radius = 300 },
        { pos = Vector3.new(-16228, 9, 443), radius = 300 },
        { pos = Vector3.new(28695, 14959, -81), radius = 10000 },
        { pos = Vector3.new(9637, -1989, 9618), radius = 10000 }
    }
}

local function GetSafeZones()
    if game.PlaceId == 2753915549 or game.PlaceId == 85211729168715 then
        return SafeZonePositions.World1
    elseif game.PlaceId == 4442272183 or game.PlaceId == 79091703265657 then
        return SafeZonePositions.World2
    elseif game.PlaceId == 7449423635 or game.PlaceId == 100117331123089 then
        return SafeZonePositions.World3
    end
    return nil
end

local function IsInSafeZone(plr)
    if not plr or not plr.Character then return false end
    local char = plr.Character
    if char:FindFirstChild("TempSafeZone") then return true end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local origin = Workspace:FindFirstChild("_WorldOrigin")
    local liveZones = origin and origin:FindFirstChild("SafeZones")
    if liveZones then
        local pos = hrp.Position
        for _, zone in ipairs(liveZones:GetChildren()) do
            if zone:IsA("BasePart") then
                local mesh = zone:FindFirstChildOfClass("SpecialMesh")
                local radius = mesh and (mesh.Scale.X * 0.5) or (zone.Size.X * 0.5)
                if (zone.Position - pos).Magnitude <= radius then
                    return true
                end
            end
        end
    end
    local zones = GetSafeZones()
    if not zones then return false end
    local pos = hrp.Position
    for _, zone in ipairs(zones) do
        if (pos - zone.pos).Magnitude <= zone.radius then
            return true
        end
    end
    return false
end

local function IsPVPDisabled(plr)
    if not plr then return true end
    if plr:GetAttribute("PvpDisabled") == true then return true end
    return false
end

local function IsInFriendlyPvp(plr)
    if not plr then return false end
    local session = plr:FindFirstChild("PvpSessionComponent", true)
        or (plr.Character and plr.Character:FindFirstChild("PvpSessionComponent", true))
    if not session then return false end
    local pointer = session:FindFirstChild("pvpArenaPointer")
    -- Any bound arena session is excluded, regardless of team/player count or match phase.
    return pointer ~= nil and pointer.Value ~= nil
end

local function IsPVPEnabled(plr)
    if not plr then return false end
    return plr:GetAttribute("PvpDisabled") ~= true
end

local function GetLevel(plr)
    if not plr then return nil end
    local obj = (plr:FindFirstChild("Data") and plr.Data:FindFirstChild("Level"))
        or (plr:FindFirstChild("leaderstats") and plr.leaderstats:FindFirstChild("Level"))
    return obj and tonumber(obj.Value) or nil
end

-- Detect the game's active raid flags on the player or character.
-- Any active raid flag excludes that player from bounty target selection.
local RAID_KEYWORD = "raid"

local function RaidTruthy(value)
    local valueType = typeof(value)
    if valueType == "boolean" then return value end
    if valueType == "number" then return value == 1 end
    if valueType == "string" then
        local s = string.lower(value)
        return s ~= "" and s ~= "false" and s ~= "none" and s ~= "0"
    end
    return false
end

local function ScanRaidFlags(instance)
    if not instance then return nil end

    for name, value in pairs(instance:GetAttributes()) do
        if string.find(string.lower(tostring(name)), RAID_KEYWORD, 1, true)
            and RaidTruthy(value) then
            return tostring(name)
        end
    end

    for _, child in ipairs(instance:GetChildren()) do
        if child:IsA("ValueBase")
            and string.find(string.lower(child.Name), RAID_KEYWORD, 1, true)
            and RaidTruthy(child.Value) then
            return child.Name
        end
    end

    return nil
end

local function GetRaidState(plr)
    if not plr then return nil end
    local char = plr.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    return ScanRaidFlags(plr)
        or ScanRaidFlags(char)
        or ScanRaidFlags(humanoid)
        or ScanRaidFlags(root)
end

local function IsPlayerInRaid(plr)
    return GetRaidState(plr) ~= nil
end

local function EvaluateTarget(plr)
    if not plr or plr == LocalPlayer then return false, "self" end
    local char = plr.Character
    if not char then return false, "no_character" end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return false, "missing_parts" end
    if hum.Health <= 0 then return false, "dead" end
    if hrp.Position.Y < -100 then return false, "too_low" end
    if IsPlayerInRaid(plr) then return false, "in_raid" end
    if IsInFriendlyPvp(plr) then return false, "friendly_pvp" end
    if IsInSafeZone(plr) and not (plr == CurrentTarget and Stay.Combat.Engaged
        and Stay.Combat.Player == plr and Stay.Combat.Character == char
        and Stay.Combat.OwnCharacter == LocalPlayer.Character) then return false, "safe_zone" end
    if IsPVPDisabled(plr) then return false, "pvp_disabled" end
    local myTeam = LocalPlayer.Team
    local tgTeam = plr.Team
    if myTeam and tgTeam and myTeam.Name == "Marines" and tgTeam.Name == "Marines" then
        return false, "same_team"
    end
    local myLv = GetLevel(LocalPlayer)
    local tgLv = GetLevel(plr)
    if myLv and tgLv and math.abs(myLv - tgLv) > 700 then return false, "level_gap" end
    local myHRP = GetHRP(LocalPlayer)
    if not myHRP then return false, "no_local_hrp" end
    -- Instant Teleport mode removes the target-distance cap entirely.
    -- Keep the normal 30,000-stud limit only when Instant Teleport is disabled.
    if not GravityState.GravityFEnabled
        and (hrp.Position - myHRP.Position).Magnitude > 30000 then
        return false, "too_far"
    end
    return true, nil
end

local TARGET_SKIP_TIME = 30

local LockGuard = {
    Counts = {},
    Blacklist = {}
}

do
    local MAX_LOCKS_PER_PLAYER = 3

    local function PlayerKey(plr)
        local id = plr and plr.UserId
        if id and id ~= 0 then return tostring(id) end
        return plr and plr.Name or "?"
    end

    function LockGuard.GetCount(plr)
        return tonumber(LockGuard.Counts[PlayerKey(plr)]) or 0
    end

    function LockGuard.IsBlacklisted(plr)
        return LockGuard.Blacklist[PlayerKey(plr)] ~= nil
    end

    function LockGuard.RegisterLock(plr)
        if not plr then return end
        local key = PlayerKey(plr)
        local n = LockGuard.GetCount(plr) + 1
        LockGuard.Counts[key] = n
        if n >= MAX_LOCKS_PER_PLAYER then
            LockGuard.Blacklist[key] = plr.Name
        end
    end

    function LockGuard.IsLockedOut(plr)
        if LockGuard.IsBlacklisted(plr) then return true end
        return LockGuard.GetCount(plr) >= MAX_LOCKS_PER_PLAYER
    end
end

local function GetNearestTarget()
    local myHRP = GetHRP(LocalPlayer)
    if not myHRP then return nil, math.huge end
    local best, bestDist = nil, math.huge
    local now = tick()
    for _, plr in ipairs(Players:GetPlayers()) do
        if TempSkipUntil[plr] and now >= TempSkipUntil[plr] then
            TempSkipUntil[plr] = nil
        end
        if not TempSkipUntil[plr] and not LockGuard.IsLockedOut(plr) then
            local ok = select(1, EvaluateTarget(plr))
            if ok then
                local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
                local dist = (hrp.Position - myHRP.Position).Magnitude
                if dist < bestDist then
                    best = plr
                    bestDist = dist
                end
            end
        end
    end
    return best, bestDist
end

local function UpdateAimTarget()
    local root = CurrentTargetRoot
    if root and root.Parent then
        Aim.Part = root
        Aim.Pos = root.CFrame
        Aim.Position = root.Position
    else
        Aim.Part = nil
        Aim.Pos = nil
        Aim.Position = nil
    end
end

local function InstallMouseModuleHook()
    if Aim.MouseHookInstalled then return true end
    if type(getrawmetatable) ~= "function" or type(setreadonly) ~= "function" then return false end
    local mod = ReplicatedStorage:FindFirstChild("Mouse")
    if not mod then return false end
    local okRequire, mouseMod = pcall(require, mod)
    if not okRequire or type(mouseMod) ~= "table" then return false end
    local ok = pcall(function()
        local store = { Hit = rawget(mouseMod, "Hit"), Target = rawget(mouseMod, "Target") }
        local mt = getrawmetatable(mouseMod) or {}
        setreadonly(mt, false)
        rawset(mouseMod, "Hit", nil)
        rawset(mouseMod, "Target", nil)
        mt.__index = function(self, key)
            if Aim.Position then
                if key == "Hit" then return Aim.Pos or CFrame.new(Aim.Position) end
                if key == "Target" and Aim.Part then return Aim.Part end
            end
            local value = rawget(self, key)
            if value ~= nil then return value end
            return store[key]
        end
        mt.__newindex = function(self, key, value)
            if key == "Hit" or key == "Target" then
                store[key] = value
            else
                rawset(self, key, value)
            end
        end
        setreadonly(mt, true)
        Aim.MouseMod = mouseMod
        Aim.MouseStore = store
        Aim.MouseMT = mt
        Aim.MouseHookInstalled = true
    end)
    return ok
end

local function InstallGameMouseHook()
    if Aim.GameHookReady then return true end
    if type(getrawmetatable) ~= "function" or type(newcclosure) ~= "function" then return false end
    local mouse = LocalPlayer:GetMouse()
    if not mouse then return false end
    local gmt = getrawmetatable(game)
    if not gmt then return false end
    local ok = pcall(function()
        setreadonly(gmt, false)
        local oldIndex = gmt.__index
        gmt.__index = newcclosure(function(self, key)
            local targetPos = Aim.Position
            if targetPos and self == mouse and not checkcaller() then
                local cam = Workspace.CurrentCamera
                local camPos = cam and cam.CFrame.Position or nil
                if key == "Hit" then return Aim.Pos or CFrame.new(targetPos) end
                if key == "Target" then return Aim.Part end
                if camPos then
                    local dir = targetPos - camPos
                    if key == "UnitRay" then return Ray.new(camPos, dir.Unit) end
                    if key == "Origin" then return CFrame.new(camPos) end
                    if key == "Direction" then return dir.Unit end
                end
            end
            if type(oldIndex) == "function" then return oldIndex(self, key) end
            if type(oldIndex) == "table" then return oldIndex[key] end
            return nil
        end)
        setreadonly(gmt, true)
        Aim.MouseGame = mouse
        Aim.GameHookReady = true
    end)
    return ok
end

local function InstallAimHooks()
    SafeCall(InstallGameMouseHook)
    if SafeCall(InstallMouseModuleHook) then return end
    task.spawn(function()
        local deadline = tick() + 10
        while tick() < deadline do
            if InstallMouseModuleHook() then return end
            task.wait(0.5)
        end
    end)
end

RunService.RenderStepped:Connect(UpdateAimTarget)


local RJR = {
    SnapDist = 85,
    PredictLead = 0.162,
    SampleInterval = 0.08,
    MaxSampleJump = 300,
    TweenSpeed = Settings.CustomTweenSpeed or 200,
    OffsetRadius = 10,
    OffsetRefresh = 0.7,
    TweenRefreshDist = 4,
    Tween = game:GetService("TweenService")
}

local function StopTween()
    if ActiveTween then
        ActiveTween:Cancel()
        ActiveTween = nil
    end
end

local Noclip = {
    Conn = nil,
    DescConn = nil,
    Char = nil,
    Parts = nil,
    Saved = nil
}

local function NoclipStrip(part, saved)
    if part:IsA("BasePart") and part.CanCollide then
        saved[part] = true
        part.CanCollide = false
    end
end

local function NoclipRestore(saved)
    if not saved then return end
    for part in pairs(saved) do
        pcall(function()
            if part.Parent then
                part.CanCollide = true
            end
        end)
    end
end

local function NoclipBind(char)
    NoclipRestore(Noclip.Saved)
    Noclip.Saved = {}
    Noclip.Char = char
    Noclip.Parts = {}
    if Noclip.DescConn then
        Noclip.DescConn:Disconnect()
        Noclip.DescConn = nil
    end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            Noclip.Parts[#Noclip.Parts + 1] = d
            NoclipStrip(d, Noclip.Saved)
        end
    end
    Noclip.DescConn = char.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then
            Noclip.Parts[#Noclip.Parts + 1] = d
            NoclipStrip(d, Noclip.Saved)
        end
    end)
end

local function NoclipStart()
    if Noclip.Conn then return end
    Noclip.Saved = {}
    local char = LocalPlayer.Character
    if char then NoclipBind(char) end
    Noclip.Conn = RunService.Stepped:Connect(function()
        local current = LocalPlayer.Character
        if not current then return end
        if current ~= Noclip.Char then
            NoclipBind(current)
            return
        end
        local parts = Noclip.Parts
        if not parts then return end
        for i = #parts, 1, -1 do
            local part = parts[i]
            if not part.Parent then
                table.remove(parts, i)
            elseif part.CanCollide then
                part.CanCollide = false
            end
        end
    end)
end

local function NoclipStop()
    if Noclip.Conn then
        Noclip.Conn:Disconnect()
        Noclip.Conn = nil
    end
    if Noclip.DescConn then
        Noclip.DescConn:Disconnect()
        Noclip.DescConn = nil
    end
    NoclipRestore(Noclip.Saved)
    Noclip.Char = nil
    Noclip.Parts = nil
    Noclip.Saved = nil
end

local function SetCollide()
    local char = LocalPlayer.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            if part.Name == "HumanoidRootPart"
                or part.Name:find("LowerTorso")
                or part.Name:find("UpperTorso") then
                part.CanCollide = true
            end
        end
    end
end

local TweenTargetPos = nil

function RJR:IsV4()
    local char = LocalPlayer.Character
    local transformed = char and char:FindFirstChild("RaceTransformed")
    return transformed ~= nil and transformed.Value == true
end
function RJR:Speed()
    if Settings.BypassTweenSpeed then return 360 end
    return math.clamp(tonumber(Settings.CustomTweenSpeed) or self.TweenSpeed, 50, 220)
end
function RJR:SnapRange()
    return self:IsV4() and 100 or self.SnapDist
end
function RJR:ApplyWaterWalk(on)
    local map = Workspace:FindFirstChild("Map")
    local plane = map and map:FindFirstChild("WaterBase-Plane")
    if not plane or not plane:IsA("BasePart") then plane = nil end
    if self.WalkPlane and (self.WalkPlane ~= plane or not on) then
        pcall(function()
            if self.WalkPlane.Size == self.WalkApplied then self.WalkPlane.Size = self.WalkOriginal end
        end)
        self.WalkPlane, self.WalkOriginal, self.WalkApplied = nil, nil, nil
        self.WaterCheckedAt, self.WaterSample = nil, nil
    end
    if on and plane then
        if self.WalkPlane ~= plane then
            self.WalkPlane, self.WalkOriginal = plane, plane.Size
            self.WalkApplied = Vector3.new(plane.Size.X, plane.Size.Y + 32, plane.Size.Z)
            self.WaterCheckedAt, self.WaterSample = nil, nil
        end
        if plane.Size ~= self.WalkApplied then plane.Size = self.WalkApplied end
    end
end

task.spawn(function()
    while true do
        SafeCall(RJR.ApplyWaterWalk, RJR, Settings.WaterWalk)
        task.wait(0.2)
    end
end)

-- Use the map's actual water plane; keep underground/interior locations on their own level.
function RJR:WaterSurface()
    if self.WaterCheckedAt and tick() - self.WaterCheckedAt < 1 then return self.WaterY, self.WaterPlane end
    self.WaterCheckedAt = tick()
    local map = Workspace:FindFirstChild("Map")
    local plane = map and map:FindFirstChild("WaterBase-Plane")
    self.WaterPlane = plane and plane:IsA("BasePart") and plane or nil
    self.WaterY = self.WaterPlane and self.WaterPlane.Position.Y + self.WaterPlane.Size.Y * 0.5 or nil
    return self.WaterY, self.WaterPlane
end
function RJR:WaterFloor(pos)
    local surface, plane = self:WaterSurface()
    if surface and pos.Y < surface - 80 then return nil end
    if self.WaterSample and tick() - self.WaterSample.At < 0.15
        and (Vector3.new(pos.X, 0, pos.Z) - self.WaterSample.Pos).Magnitude < 12 then
        return self.WaterSample.Floor
    end
    if not self.WaterParams then
        self.WaterParams = RaycastParams.new()
        self.WaterParams.FilterType = Enum.RaycastFilterType.Exclude
        self.WaterParams.IgnoreWater = false
    end
    local excluded = {}
    for _, obj in pairs({ LocalPlayer.Character, Workspace:FindFirstChild("Characters"),
        Workspace.CurrentCamera, Workspace:FindFirstChild("_WorldOrigin") }) do
        excluded[#excluded + 1] = obj
    end
    self.WaterParams.FilterDescendantsInstances = excluded
    local top = math.max(pos.Y, surface or pos.Y) + 32
    local hit = Workspace:Raycast(Vector3.new(pos.X, top, pos.Z), Vector3.new(0, -160, 0), self.WaterParams)
    local floor
    if hit and (hit.Material == Enum.Material.Water or hit.Instance == plane) then floor = hit.Position.Y + 12 end
    self.WaterSample = { At = tick(), Pos = Vector3.new(pos.X, 0, pos.Z), Floor = floor }
    return floor
end
function RJR:SafeGoal(cf, cruise)
    if not Settings.WaterWalk then return cf end
    local surface = self:WaterSurface()
    local floor
    if cruise and surface and cf.Position.Y >= surface - 80 then floor = surface + 12
    elseif not surface or cf.Position.Y < surface + 12 then floor = self:WaterFloor(cf.Position) end
    if floor and cf.Position.Y < floor then return cf + Vector3.new(0, floor - cf.Position.Y, 0) end
    return cf
end

local function MoveTo(cf, speed)
    local hrp = GetHRP(LocalPlayer)
    local hum = GetHumanoid(LocalPlayer)
    if not hrp or not hum then return end
    speed = math.max(tonumber(speed) or RJR:Speed(), 1)
    cf = RJR:SafeGoal(cf, (cf.Position - hrp.Position).Magnitude > RJR:SnapRange())
    if ActiveTween and ActiveTween.PlaybackState == Enum.PlaybackState.Playing
        and RJR.ActiveTweenSpeed == speed
        and TweenTargetPos and (cf.Position - TweenTargetPos).Magnitude <= RJR.TweenRefreshDist then
        return
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
    local distance = (cf.Position - hrp.Position).Magnitude
    StopTween()
    local tween = RJR.Tween:Create(hrp, TweenInfo.new(distance / speed, Enum.EasingStyle.Linear), { CFrame = cf })
    ActiveTween = tween
    TweenTargetPos = cf.Position
    RJR.ActiveTweenSpeed = speed
    NoclipStart()
    tween:Play()
end

local function RandomOffset()
    local now = tick()
    if now >= NextOffsetRefresh then
        OffsetAngle = Random:NextNumber(0, math.pi * 2)
        NextOffsetRefresh = now + RJR.OffsetRefresh
    end
    return Vector3.new(math.cos(OffsetAngle) * RJR.OffsetRadius, 0, math.sin(OffsetAngle) * RJR.OffsetRadius)
end

local HopActive
local ClearFlightComponents

-- [CHANGED]
local function ChaseStep()
    local myHRP = GetHRP(LocalPlayer)
    local myHum = GetHumanoid(LocalPlayer)
    if not myHRP or not myHum or myHum.Health <= 0 then
        StopTween()
        NoclipStop()
        return
    end
    local targetRoot = CurrentTarget and CurrentTarget.Character
        and CurrentTarget.Character:FindFirstChild("HumanoidRootPart")
    if not targetRoot then targetRoot = CurrentTargetRoot end
    if not targetRoot or not targetRoot.Parent then
        StopTween()
        NoclipStop()
        ChaseSample = nil
        return
    end
    CurrentTargetRoot = targetRoot
    Aim.Part = targetRoot
    Aim.Pos = targetRoot.CFrame
    if FleeActive or HopActive() then
        StopTween()
        NoclipStop()
        return
    end

    if GravityState.LastInstantTPAt > 0 and tick() - GravityState.LastInstantTPAt < 0.5 then
        pcall(function()
            myHRP.AssemblyLinearVelocity = Vector3.zero
            myHRP.AssemblyAngularVelocity = Vector3.zero
        end)
        ChaseSample = nil
        return
    end

    local dist = (myHRP.Position - targetRoot.Position).Magnitude
    if dist > GravityState.TP_DISTANCE and GravityState.GravityFEnabled then
        -- Start preparing/teleporting immediately after target acquisition. This
        -- worker waits for the fresh-join tool/remote/cooldown without freezing chase.
        pcall(GravityState.GTP.teleportTo, targetRoot)
    end

    local targetPos = targetRoot.Position
    local vel = Vector3.zero
    local now = tick()
    if ChaseSample then
        local dt = now - ChaseSample.t
        if dt > 0 and dt < 1 and (targetPos - ChaseSample.pos).Magnitude <= RJR.MaxSampleJump then
            vel = (targetPos - ChaseSample.pos) / dt
        end
    end
    if not ChaseSample or now - ChaseSample.t >= RJR.SampleInterval then
        ChaseSample = { pos = targetPos, t = now }
    end
    MoveTo(targetRoot.CFrame + vel * RJR.PredictLead + RandomOffset(), RJR:Speed())
end

local function StartChase()
    if ChaseActive then return end
    ChaseActive = true
    ChaseConnection = RunService.Stepped:Connect(function()
        if not AutoBountyArmed or not ChaseActive or ManualHopRequested then return end
        SafeCall(ChaseStep)
    end)
end

local function StopChase()
    ChaseActive = false
    if ChaseConnection then
        ChaseConnection:Disconnect()
        ChaseConnection = nil
    end
    StopTween()
    NoclipStop()
    SetCollide()
    ChaseSample = nil
end

local function ResetTarget()
    if TargetDeathConnection then
        TargetDeathConnection:Disconnect()
        TargetDeathConnection = nil
    end
    Stay.Combat = {}
    CurrentTarget = nil
    CurrentTargetRoot = nil
    UpdateAimTarget()
    ChaseSample = nil
    StopTween()
    TargetLostTime = tick()
end
local function SetTarget(plr)
    if not plr or LockGuard.IsBlacklisted(plr) then return false end
    LockGuard.RegisterLock(plr)
    if plr ~= CurrentTarget then
        GravityState.LastFSequenceTarget = nil
        GravityState.FailedTargetRoot = nil
        GravityState.FailedTeleportCount = 0
    end
    CurrentTarget = plr
    Stay.Combat = {}
    Stay:UpdateEngagement(plr)
    CurrentTargetRoot = plr and plr.Character
        and plr.Character:FindFirstChild("HumanoidRootPart") or nil
    if TargetDeathConnection then
        TargetDeathConnection:Disconnect()
        TargetDeathConnection = nil
    end
    local targetHumanoid = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
    if targetHumanoid then
        TargetDeathConnection = targetHumanoid.Died:Connect(function()
            -- Give the kill/death state half a second to settle, then acquire
            -- the next eligible player and use Gravity F immediately.
            task.delay(0.5, function()
                if not AutoBountyArmed or not GravityState.GravityFEnabled
                    or (CurrentTarget ~= nil and CurrentTarget ~= plr) then return end
                ResetTarget()
                local nextPlayer = GetNearestTarget()
                if nextPlayer and SetTarget(nextPlayer) then
                    local nextRoot = nextPlayer.Character and nextPlayer.Character:FindFirstChild("HumanoidRootPart")
                    if nextRoot then
                        GravityState.NextTeleportAttemptAt = 0
                        pcall(GravityState.GTP.teleportTo, nextRoot)
                    end
                end
            end)
        end)
    end
    ChaseSample = nil
    TargetInvalidSince = nil
    TargetLockStart = tick()
    StopTween()
    return true
end

local Flight = {
    Speed = 350,
    Attachment = nil,
    Velocity = nil,
    Force = nil,
    DescentTime = 0,
    DescentLastY = nil,
    DescentLastClock = nil,
    DescentHRP = nil
}
local DESCENT_ACCEL_TIME = 1.2

local function SetCharNoclip(char, enabled)
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = not enabled
        end
    end
end

function ClearFlightComponents()
    for _, key in ipairs({ "Velocity", "Force", "Attachment" }) do
        local obj = Flight[key]
        if obj then
            pcall(function() obj:Destroy() end)
            Flight[key] = nil
        end
    end
    Flight.DescentTime = 0
    Flight.DescentLastY = nil
    Flight.DescentLastClock = nil
    Flight.DescentHRP = nil
end

local function SetupFlightComponents(hrp)
    if Flight.Velocity and Flight.Velocity.Parent == hrp
        and Flight.Attachment and Flight.Attachment.Parent == hrp then
        return
    end

    ClearFlightComponents()

    local att = Instance.new("Attachment")
    att.Name = "AutoBounty_FlightAttachment"
    att.Parent = hrp
    Flight.Attachment = att

    local lv = Instance.new("LinearVelocity")
    lv.Name = "AutoBounty_FlightVelocity"
    lv.MaxForce = math.huge
    lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
    lv.VectorVelocity = Vector3.zero
    lv.Attachment0 = att
    lv.Parent = hrp
    Flight.Velocity = lv

    local totalMass = 0
    local char = hrp.Parent
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and not part.Massless then
                totalMass = totalMass + part:GetMass()
            end
        end
    end

    local vf = Instance.new("VectorForce")
    vf.Name = "AutoBounty_AntiGravity"
    vf.ApplyAtCenterOfMass = true
    vf.Attachment0 = att
    vf.Force = Vector3.new(0, totalMass * Workspace.Gravity, 0)
    vf.Parent = hrp
    Flight.Force = vf
end

local function ResetDescentState()
    Flight.DescentTime = 0
    Flight.DescentLastY = nil
    Flight.DescentLastClock = nil
end

local function UpdateDescentState(hrp, descending)
    local now = os.clock()

    if not hrp then
        ResetDescentState()
        return 1
    end

    if Flight.DescentHRP ~= hrp then
        Flight.DescentHRP = hrp
        ResetDescentState()
        return 1
    end

    local lastY = Flight.DescentLastY
    local lastClock = Flight.DescentLastClock
    Flight.DescentLastY = hrp.Position.Y
    Flight.DescentLastClock = now

    if not lastY or not lastClock then return 1 end

    local dt = now - lastClock
    if dt <= 0 then return 1 end

    local dropRate = (lastY - hrp.Position.Y) / dt
    if descending and dropRate >= 5 then
        Flight.DescentTime = math.min(Flight.DescentTime + dt, DESCENT_ACCEL_TIME)
    else
        Flight.DescentTime = 0
    end

    local progress = Flight.DescentTime / DESCENT_ACCEL_TIME
    return 1 + (2.0 - 1) * (progress * progress)
end

local function FlyMoveTo(pos)
    if not pos then return end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    SetupFlightComponents(hrp)

    local dir = pos - hrp.Position
    if dir.Magnitude > 0.1 then
        local mult = UpdateDescentState(hrp, dir.Y < 0)
        if Flight.Velocity then
            Flight.Velocity.VectorVelocity = dir.Unit * Flight.Speed * mult
        end
    else
        if Flight.Velocity then
            Flight.Velocity.VectorVelocity = Vector3.zero
        end
        ResetDescentState()
    end
end

local function FlyStop()
    ResetDescentState()
    if Flight.Velocity then
        Flight.Velocity.VectorVelocity = Vector3.zero
    end
end

local function FleeUpLogic()
    pcall(function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or hum.Health <= 0 then return end

        SetCharNoclip(char, true)
        FlyMoveTo(hrp.Position + Vector3.new(0, 100, 0))
    end)
end

local function IsMarineTeam()
    local ok, teamName = pcall(function()
        return LocalPlayer.Team and LocalPlayer.Team.Name
    end)
    if ok and teamName == "Marines" then return true end

    local okData, dataTeam = pcall(function()
        local data = LocalPlayer:FindFirstChild("Data")
        local teamVal = data and data:FindFirstChild("Team")
        return teamVal and teamVal.Value
    end)
    return okData and dataTeam == "Marines"
end

local function IsMarineBountyRiskUI()
    local mainUI = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Main")
    local bottomHUD = mainUI and mainUI:FindFirstChild("BottomHUDList")
    if not bottomHUD then return false end

    local function IsActive(obj)
        if not obj then return false end
        return (not obj:IsA("GuiObject")) or obj.Visible
    end

    if IsActive(bottomHUD:FindFirstChild("CampBounty")) then return true end
    if IsActive(bottomHUD:FindFirstChild("initHonor")) then return true end

    local inCombatUI = bottomHUD:FindFirstChild("InCombat")
    local nestedHonor = inCombatUI and inCombatUI:FindFirstChild("initHonor")
    if IsActive(nestedHonor) then return true end

    return false
end

GetCombatStatus = function()
    local mainUI = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Main")
    local bottomHUD = mainUI and mainUI:FindFirstChild("BottomHUDList")
    local inCombatUI = bottomHUD and bottomHUD:FindFirstChild("InCombat")

    if inCombatUI and inCombatUI.Visible then
        local rawText = ""
        if inCombatUI:IsA("TextLabel") then
            rawText = inCombatUI.Text
        else
            local childText = inCombatUI:FindFirstChildWhichIsA("TextLabel", true)
            if childText then rawText = childText.Text end
        end

        local lowerText = string.lower(rawText)
        local isBountyRisk = string.find(lowerText, "bounty at risk")
            or string.find(lowerText, "bounty")
            or string.find(lowerText, "Bounty")
        local isHonorRisk = string.find(lowerText, "honor at risk")
            or string.find(lowerText, "honor")
            or string.find(lowerText, "Honor")
            or string.find(lowerText, "Rank")
            or string.find(lowerText, "Rank")

        if IsMarineTeam() and (isHonorRisk or IsMarineBountyRiskUI()) then
            return "BountyAtRisk"
        end
        if isBountyRisk or isHonorRisk then
            return "BountyAtRisk"
        end
        return "InCombatNoRisk"
    end

    if IsMarineTeam() and IsMarineBountyRiskUI() then
        return "BountyAtRisk"
    end

    -- Also check the character attribute in case the HUD has not appeared yet
    -- or its InCombat element is temporarily hidden.
    local ownCharacter = LocalPlayer.Character
    if ownCharacter and ownCharacter:GetAttribute("InCombat") == true then
        return "InCombatNoRisk"
    end
    return "NotInCombat"
end

local CombatCache, CombatCacheTime = "NotInCombat", 0
local function IsBountyAtRisk()
    local now = os.clock()
    if now - CombatCacheTime >= 0.5 then
        CombatCacheTime = now
        CombatCache = GetCombatStatus()
    end
    return CombatCache == "BountyAtRisk"
end

local HopMinPlayers, HopMaxPlayers = 1, 12
local function ApplyPlayerRange(label)
    local a, b = tostring(label):match("(%d+)%-(%d+)")
    HopMinPlayers = tonumber(a) or 1
    HopMaxPlayers = tonumber(b) or 12
end
ApplyPlayerRange(Settings.HopPlayerRange)

local HopMinBounty, HopMaxBounty = 0, 999999999
local function ApplyBountyRange(label)
    local numText = tostring(label):match("([%d%.]+%s*[Mm]?)")
    if numText then
        local num, unit = numText:match("([%d%.]+)%s*([Mm]?)")
        local value = tonumber(num) or 0
        if unit and unit:lower() == "m" then value = value * 1000000 end
        HopMinBounty = value + 1
        HopMaxBounty = 999999999
    else
        HopMinBounty = 0
        HopMaxBounty = 999999999
    end
end
ApplyBountyRange(Settings.HopBountyRange)

local HUD = {}

local function SetupHUD()
local RE_EXECUTE_URL = ""
local SCRIPT_START_TICK = tick()
local env = getgenv and getgenv()
local TOTAL_FOLDER = "workspace/AutoBountyMain"
local TOTAL_EARNED_FILE = TOTAL_FOLDER .. "/earned_total_" .. tostring(LocalPlayer.UserId) .. ".txt"
local TOTAL_RUNTIME_FILE = TOTAL_FOLDER .. "/earned_runtime_" .. tostring(LocalPlayer.UserId) .. ".txt"
local TOTAL_RUNTIME_BASE_FILE = TOTAL_FOLDER .. "/earned_runtime_base_" .. tostring(LocalPlayer.UserId) .. ".txt"
local function EnsureTotalFolder()
    local function ensure(path)
        local exists = false
        if type(isfolder) == "function" then
            local ok, result = pcall(isfolder, path)
            exists = ok and result == true
        end
        if not exists and type(makefolder) == "function" then pcall(makefolder, path) end
    end
    ensure("workspace")
    ensure(TOTAL_FOLDER)
end
local function ReadSavedNumber(path)
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
    local ok, value = pcall(function() if isfile(path) then return readfile(path) end end)
    return ok and tonumber(value) or nil
end
local function MaxNumber(...)
    local best = 0
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        best = math.max(best, tonumber(value) or 0)
    end
    return best
end
EnsureTotalFolder()
local TotalEarned = MaxNumber(env and env.AutoBountyTotalEarned, ReadSavedNumber(TOTAL_EARNED_FILE))
local RunTimeCarry = MaxNumber(env and env.AutoBountyRunTime, env and env.AutoBountyTotalRuntime, ReadSavedNumber(TOTAL_RUNTIME_FILE))
local TotalRuntimeBase = math.clamp(MaxNumber(env and env.AutoBountyTotalRuntimeBase, ReadSavedNumber(TOTAL_RUNTIME_BASE_FILE)), 0, RunTimeCarry)
local TotalKills = MaxNumber(env and env.AutoBountyTotalKills, ReadSavedNumber(TOTAL_KILL_COUNT_FILE))
local RecentKills = {}
local function ReadRecentKills()
    local source = type(env) == "table" and env.AutoBountyRecentKills
    if type(source) == "table" then
        for _, item in ipairs(source) do
            if type(item) == "table" and type(item.Name) == "string" then
                RecentKills[#RecentKills + 1] = {Name = item.Name, Reward = tonumber(item.Reward) or 0, Kind = item.Kind == "Honor" and "Honor" or "Bounty"}
                if #RecentKills >= 5 then break end
            end
        end
    elseif type(isfile) == "function" and type(readfile) == "function" then
        pcall(function()
            if not isfile(TOTAL_KILL_HISTORY_FILE) then return end
            for line in readfile(TOTAL_KILL_HISTORY_FILE):gmatch("[^\r\n]+") do
                local name, reward, kind = line:match("^([^\t]+)\t(%d+)\t([%a]+)$")
                if name then
                    RecentKills[#RecentKills + 1] = {Name = name, Reward = tonumber(reward) or 0, Kind = kind == "Honor" and "Honor" or "Bounty"}
                    if #RecentKills >= 5 then break end
                end
            end
        end)
    end
end
ReadRecentKills()
-- Server-earned value resets on each execution; all-server totals are persistent.
local LastEarned = 0

local function GetRewardValues()
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    if not stats then return nil, nil end
    local combined = stats:FindFirstChild("Bounty/Honor")
    if combined then return tonumber(combined.Value), nil end
    local bounty = stats:FindFirstChild("Bounty")
    local honor = stats:FindFirstChild("Honor")
    return bounty and tonumber(bounty.Value) or nil, honor and tonumber(honor.Value) or nil
end

local function GetMyBounty()
    local bounty, honor = GetRewardValues()
    if bounty ~= nil then return bounty end
    return honor
end


-- Stop the session once the configured bounty/honor target is reached.
local RewardLockTriggered = false
local function FormatRewardInteger(value)
    local digits = tostring(math.floor(tonumber(value) or 0))
    local negative = digits:sub(1, 1) == "-"
    if negative then digits = digits:sub(2) end
    local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (negative and "-" or "") .. grouped
end

task.spawn(function()
    while true do
        task.wait(0.5)
        if not RewardLockTriggered and AutoBountyArmed and Settings.LockAtReward == true then
            local currentReward = GetMyBounty()
            local targetReward = math.max(0, tonumber(Settings.RewardLockTarget) or 0)
            if currentReward and targetReward > 0 and currentReward >= targetReward then
                RewardLockTriggered = true
                AutoBountyArmed = false
                Settings.AutoBounty = false
                local env = getgenv and getgenv()
                if type(env) == "table" then env.AutoBountyResume = nil end
                pcall(StopChase)
                pcall(ResetTarget)
                pcall(FlyStop)
                local reached = FormatRewardInteger(currentReward)
                local rewardLabel = "Bounty/Honor"
                local kickMessage = "Merciful Auto Bounty\n" .. reached .. " " .. rewardLabel .. " reached"

                -- Stop all bounty activity immediately, but do not kick while the
                -- character is still in combat (including ordinary InCombat state).
                pcall(function()
                    StopChase()
                    ResetTarget()
                    FlyStop()
                end)
                CurrentTarget = nil
                CurrentTargetRoot = nil
                FleeActive = false
                ManualHopRequested = false
                DeathHopRequested = false

                -- Require the HUD/attributes to report fully out of combat for
                -- a short stable window so a transient UI flicker cannot trigger a kick.
                local safeSince = nil
                while true do
                    task.wait(0.2)
                    local status = GetCombatStatus()
                    if status == "NotInCombat" then
                        safeSince = safeSince or os.clock()
                        if os.clock() - safeSince >= 1.0 then
                            break
                        end
                    else
                        safeSince = nil
                    end
                end

                -- Once combat has been safely cleared, ascend briefly before kicking
                -- instead of leaving the character frozen at the current position.
                pcall(function()
                    local character = LocalPlayer.Character
                    local root = character and character:FindFirstChild("HumanoidRootPart")
                    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                    if root and humanoid and humanoid.Health > 0 then
                        -- Remove any leftover movement controller from the bounty flight.
                        for _, child in ipairs(root:GetChildren()) do
                            if child.Name == "MercifulRewardLockAscend" then
                                child:Destroy()
                            end
                        end

                        local upward = Instance.new("BodyVelocity")
                        upward.Name = "MercifulRewardLockAscend"
                        upward.P = 15000
                        upward.MaxForce = Vector3.new(0, 1e9, 0)
                        upward.Velocity = Vector3.new(0, 115, 0)
                        upward.Parent = root
                        task.wait(1.8)
                        if upward and upward.Parent then
                            upward:Destroy()
                        end
                    end
                end)

                pcall(function()
                    LocalPlayer:Kick(kickMessage)
                end)
                break
            end
        end
    end
end)

local function GetRunTime()
    return RunTimeCarry + (tick() - SCRIPT_START_TICK)
end

local function SaveTotals()
    local currentRuntime = GetRunTime()
    local persistentEnv = getgenv and getgenv()
    if type(persistentEnv) == "table" then
        persistentEnv.AutoBountyTotalEarned = TotalEarned
        persistentEnv.AutoBountyRunTime = currentRuntime
        persistentEnv.AutoBountyTotalRuntime = currentRuntime
        persistentEnv.AutoBountyTotalRuntimeBase = TotalRuntimeBase
        persistentEnv.AutoBountyTotalKills = TotalKills
        persistentEnv.AutoBountyRecentKills = RecentKills
    end
    pcall(function()
        EnsureTotalFolder()
        if type(writefile) == "function" then
            writefile(TOTAL_EARNED_FILE, string.format("%.0f", TotalEarned))
            writefile(TOTAL_RUNTIME_FILE, string.format("%.0f", currentRuntime))
            writefile(TOTAL_RUNTIME_BASE_FILE, string.format("%.0f", TotalRuntimeBase))
            writefile(TOTAL_KILL_COUNT_FILE, string.format("%.0f", TotalKills))
            local lines = {}
            for _, kill in ipairs(RecentKills) do
                local name = tostring(kill.Name):gsub("[\t\r\n]", " ")
                lines[#lines + 1] = name .. "\t" .. string.format("%.0f", tonumber(kill.Reward) or 0) .. "\t" .. (kill.Kind == "Honor" and "Honor" or "Bounty")
            end
            writefile(TOTAL_KILL_HISTORY_FILE, table.concat(lines, "\n"))
        end
    end)
end

local function ResetAllServerTotals()
    TotalEarned = 0
    RunTimeCarry = 0
    SCRIPT_START_TICK = tick()
    TotalRuntimeBase = 0
    SaveTotals()
    local persistentEnv = getgenv and getgenv()
    local ui = persistentEnv and persistentEnv.MercifulUI
    if ui and type(ui.SetStats) == "function" then pcall(ui.SetStats, {TotalEarned = 0, TotalRuntimeBase = TotalRuntimeBase, Runtime = GetRunTime()}) end
    if ui and type(ui.Notify) == "function" then pcall(ui.Notify, "All-server earned total reset", 2) end
end

local function ParseEarnedReward(message)
    local clean = string.lower(tostring(message)):gsub("<[^>]+>", "")
    if not string.find(clean, "earned", 1, true) then return nil end
    local amount, suffix = clean:match("earned%s+%+?([%d,%.]+)%s*([kmb]?)%s+bounty")
    if not amount then amount, suffix = clean:match("earned%s+%+?([%d,%.]+)%s*([kmb]?)%s+honor") end
    if not amount then return nil end
    amount = tonumber((amount:gsub(",", "")))
    if not amount then return nil end
    local multiplier = ({k = 1e3, m = 1e6, b = 1e9})[suffix] or 1
    amount = math.floor(amount * multiplier + 0.5)
    local kind = clean:find("honor", 1, true) and "Honor" or "Bounty"
    return amount > 0 and amount or nil, kind
end

local function ParseKilledPlayer(message)
    local clean = tostring(message):gsub("<[^>]+>", "")
    local lower = string.lower(clean)
    local startAt = lower:find("from killing", 1, true)
    if not startAt then return nil end
    local name = clean:sub(startAt + #"from killing"):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[!%.,;:]+$", "")
    name = name:gsub("[%c]", "")
    if name == "" then return nil end
    return string.sub(name, 1, 40)
end

local function GetEarnedBounty()
    return LastEarned
end

if CommE and CommE:IsA("RemoteEvent") then
    CommE.OnClientEvent:Connect(function(action, ...)
        if action ~= "Notify" then return end
        local values = {...}
        for index = 1, select("#", ...) do
            local value = values[index]
            if type(value) == "string" then
                local amount, rewardKind = ParseEarnedReward(value)
                if amount then
                    LastEarned += amount
                    TotalEarned += amount
                    local killedName = ParseKilledPlayer(value)
                    if killedName then
                        TotalKills += 1
                        table.insert(RecentKills, 1, {Name = killedName, Reward = amount, Kind = rewardKind or "Bounty"})
                        while #RecentKills > 5 do table.remove(RecentKills) end
                    end
                    SaveTotals()
                    local eventEnv = getgenv and getgenv()
                    if type(eventEnv) == "table" then eventEnv.AutoBountyEarned = LastEarned end
                    local ui = eventEnv and eventEnv.MercifulUI
                    if ui and type(ui.SetStats) == "function" then
                        pcall(ui.SetStats, {Earned = LastEarned, TotalEarned = TotalEarned, Runtime = GetRunTime(), TotalRuntimeBase = TotalRuntimeBase, Bounty = GetMyBounty(), KillCount = TotalKills, RecentKills = RecentKills})
                    end
                    break
                end
            end
        end
    end)
end

pcall(function()
    local parent
    if type(gethui) == "function" then local ok, result = pcall(gethui); if ok then parent = result end end
    if not parent then pcall(function() parent = game:GetService("CoreGui") end) end
    if not parent then parent = LocalPlayer:FindFirstChild("PlayerGui") end
    local oldPanel = parent and parent:FindFirstChild("AutoBountyInfoPanel")
    if oldPanel then oldPanel:Destroy() end
end)

local function BuildReExecuteScript()
    GetEarnedBounty()
    -- Persist the user's URL/toggles before leaving this server.
    if type(SaveConfig) == "function" then pcall(SaveConfig) end
    local env = getgenv and getgenv()
    local lang = type(env) == "table" and (env.Language or env.language) or nil
    local parts = {
        "getgenv().AutoBountyMainLoaded = nil",
        "getgenv().AutoBountyMainReady = nil",
        "_G.RJR_HUB_autobounty_Loaded = nil"
    }
    if type(lang) == "string" and lang ~= "" then
        parts[#parts + 1] = string.format("getgenv().Language = %q", lang)
    end
    SaveTotals()
    parts[#parts + 1] = string.format("getgenv().AutoBountyRunTime = %.0f", GetRunTime())
    parts[#parts + 1] = string.format("getgenv().AutoBountyTotalEarned = %.0f", TotalEarned)
    parts[#parts + 1] = string.format("getgenv().AutoBountyTotalRuntime = %.0f", GetRunTime())
    parts[#parts + 1] = string.format("getgenv().AutoBountyTotalRuntimeBase = %.0f", TotalRuntimeBase)
    if AutoBountyArmed then
        parts[#parts + 1] = "getgenv().AutoBountyResume = true"
        parts[#parts + 1] = "getgenv().AutoBountyMinimizeOnResume = true"
    end

    local autoUrl = tostring(Settings.AutoExecuteURL or ""):match("^%s*(.-)%s*$")
    if Settings.AutoExecute == true and autoUrl:match("^https?://") then
        parts[#parts + 1] = string.format([[
task.spawn(function()
    repeat task.wait(0.15) until game:IsLoaded()
    local Players = game:GetService("Players")
    repeat task.wait(0.1) until Players.LocalPlayer
    task.wait(1.5)

    local url = %q
    local source, downloadError
    local ok = pcall(function()
        source = game:HttpGet(url)
    end)
    if not ok or type(source) ~= "string" or source == "" then
        local req = (syn and syn.request) or (http and http.request) or http_request or request
        if type(req) == "function" then
            local reqOK, response = pcall(req, {Url = url, Method = "GET"})
            if reqOK and type(response) == "table" then
                local status = tonumber(response.StatusCode or response.Status or 200)
                if status >= 200 and status < 300 then
                    source = response.Body or response.body
                else
                    downloadError = "HTTP " .. tostring(status)
                end
            else
                downloadError = tostring(response)
            end
        end
    end

    if type(source) ~= "string" or source == "" then
        warn("[Merciful Auto Execute] Download failed: " .. tostring(downloadError or "empty response"))
        return
    end

    local compiler = loadstring or load
    if type(compiler) ~= "function" then
        warn("[Merciful Auto Execute] This executor does not expose loadstring/load")
        return
    end
    local compileOK, chunk, compileError = pcall(compiler, source)
    if not compileOK or type(chunk) ~= "function" then
        warn("[Merciful Auto Execute] Compile failed: " .. tostring(compileError or chunk))
        return
    end
    local runOK, runError = pcall(chunk)
    if not runOK then warn("[Merciful Auto Execute] Script error: " .. tostring(runError)) end
end)
]], autoUrl)
    elseif Settings.AutoExecute == true then
        warn("[Merciful Auto Execute] Enabled, but Script URL is empty or not HTTP(S)")
    end

    return table.concat(parts, "\n") .. "\n"
end

local function FormatWebhookNumber(value)
    local n = math.floor(tonumber(value) or 0)
    local raw = tostring(n)
    local sign = ""
    if raw:sub(1, 1) == "-" then sign, raw = "-", raw:sub(2) end
    local grouped = raw:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. grouped
end

local function CompactWebhookNumber(value)
    local n = tonumber(value) or 0
    if math.abs(n) >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if math.abs(n) >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if math.abs(n) >= 1e3 then return string.format("%.1fK", n / 1e3) end
    return tostring(math.floor(n))
end

local function SendWebhookSummary(reason)
    if Settings.WebhookEnabled ~= true then return false end
    local webhookUrl = tostring(Settings.WebhookUrl or "")
    if not webhookUrl:match("^https://discord%.com/api/webhooks/") and
       not webhookUrl:match("^https://discordapp%.com/api/webhooks/") then
        return false
    end

    local http = game:GetService("HttpService")
    local requestFn = (syn and syn.request) or request or http_request
    if type(requestFn) ~= "function" then
        warn("[Merciful Webhook] Executor HTTP request function is unavailable")
        return false
    end

    -- Custom Discord emoji IDs copied from the webhook design the user supplied.
    local E = {
        arrowName = "<a:arrowhite:1507438139801735189>",
        pinkArrow = "<a:pinkarrow:1514359136471482388>",
        wing1 = "<a:p_wing03:1540688176253771846>",
        wing2 = "<a:p_wing04:1540688262421680130>",
        happy = "<a:Happy:1333814546946588712>",
        pepo = "<a:PepoDanceLS:1544455843855208518>",
        warning = "<:warning_1:1525414587514617946>",
        heartViwa = "<a:Heart_viwa:1467895872791646300>",
        hearts = "<a:Heartsss:1474708031307780096>",
        beli = "<a:money:1481836978571055174>",
        fragments = "<:Fragments:1523292585127448576>",
        mythical = "<:MythicScroll:1168527646867607625>",
        legendary = "<:LegendScroll:1168527616312094811>",
        foolsgold = "<a:9040goldnitro:1413550873354834051>",
        terror = "<:blurryeyes:1372835227256492042>",
        levheart = "<a:DropletHeart:1515188697388154941>",
        levscale = "<:frozen_ice:1528361431563501658>",
        time = "<a:Time:1525744702866067486>",
        bribe = "<a:money_logo:1512768917351694337>",
        players = "<a:white_arroww:1537868864975675523>",
    }

    local team = (LocalPlayer.Team and LocalPlayer.Team.Name) or tostring(Settings.SelectTeam or "Unknown")
    local teamColor = team == "Marines" and 0x1E90FF or 0xFF1A1A
    local elapsed = math.max(GetRunTime() - (RunTimeCarry or 0), 1)
    local perHour = (tonumber(LastEarned) or 0) / elapsed * 3600
    local bounty = GetMyBounty()
    local killLines = {}
    for index, item in ipairs(RecentKills) do
        if index > 5 then break end
        local name = tostring(item.Name or "Unknown"):gsub("[`*|]", "")
        killLines[#killLines + 1] = string.format("%s **%d.** %s • +%s",
            E.pinkArrow, index, name, CompactWebhookNumber(item.Reward))
    end
    if #killLines == 0 then killLines[1] = E.warning .. " No bounty kills recorded this server" end

    local accountText = Settings.HideWebhookUsername == true and "||Hidden||" or ("||" .. LocalPlayer.Name .. "||")
    local avatarUrl = "https://www.roblox.com/headshot-thumbnail/image?userId=" ..
        tostring(LocalPlayer.UserId) .. "&width=420&height=420&format=png"
    local gifUrl = "https://i.imgur.com/QhA0Mot.gif"
    local blank = "\226\128\139"
    local embed = {
        title = E.wing1 .. "  Merciful Auto Bounty  " .. E.wing2,
        description = E.pinkArrow .. " **Server Summary**\n" .. E.players .. " Left server • `" ..
            tostring(#Players:GetPlayers()) .. "/12` players • **" .. team .. "**",
        color = teamColor,
        thumbnail = {url = avatarUrl},
        fields = {
            {name = E.beli .. " Earned This Server", value = "**+" .. CompactWebhookNumber(LastEarned) .. "**", inline = true},
            {name = E.time .. " Time In Server", value = "**" .. string.format("%02d:%02d:%02d",
                math.floor(elapsed / 3600), math.floor(elapsed / 60) % 60, math.floor(elapsed) % 60) .. "**", inline = true},
            {name = blank, value = blank, inline = true},
            {name = E.pepo .. " Kills", value = tostring(TotalKills), inline = true},
            {name = E.beli .. " Per Hour", value = "**" .. CompactWebhookNumber(perHour) .. "/h**", inline = true},
            {name = blank, value = blank, inline = true},
            {name = E.hearts .. " Current Bounty", value = "**" .. (bounty and FormatWebhookNumber(bounty) or "Unknown") .. "**", inline = true},
            {name = E.warning .. " Hop Reason", value = "**" .. tostring(reason or "Server hop"):sub(1, 100) .. "**", inline = true},
            {name = blank, value = blank, inline = true},
            {name = E.pinkArrow .. " Recent Kills", value = table.concat(killLines, "\n"), inline = false},
            {name = E.players .. " All Servers",
                value = E.beli .. " Total earned **" .. CompactWebhookNumber(TotalEarned) ..
                    "**\n" .. E.pepo .. " Total kills **" .. tostring(TotalKills) ..
                    "**\n" .. E.time .. " Runtime **" .. string.format("%02d:%02d:%02d",
                        math.floor(GetRunTime() / 3600), math.floor(GetRunTime() / 60) % 60,
                        math.floor(GetRunTime()) % 60) .. "**",
                inline = false},
            {name = E.arrowName .. " Account", value = E.arrowName .. " " .. accountText, inline = false},
        },
        image = {url = gifUrl},
        footer = {text = E.hearts .. " Previous server summary • Merciful " .. E.happy},
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    local ok, response = pcall(requestFn, {
        Url = webhookUrl,
        Method = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body = http:JSONEncode({username = "Merciful Auto Bounty", embeds = {embed}}),
    })
    if not ok then
        warn("[Merciful Webhook] Request failed: " .. tostring(response))
        return false
    end
    local status = response and (response.StatusCode or response.Status or response.statusCode or response.status)
    if status and tonumber(status) and tonumber(status) >= 400 then
        warn("[Merciful Webhook] Discord returned HTTP " .. tostring(status))
        return false
    end
    return true
end

local function QueueAutoReExecute()
    local source = BuildReExecuteScript()
    local queueFunctions = {}

    if type(queue_on_teleport) == "function" then
        queueFunctions[#queueFunctions + 1] = queue_on_teleport
    end
    if type(queueonteleport) == "function" then
        queueFunctions[#queueFunctions + 1] = queueonteleport
    end
    if type(syn) == "table" and type(syn.queue_on_teleport) == "function" then
        queueFunctions[#queueFunctions + 1] = syn.queue_on_teleport
    end
    if type(fluxus) == "table" and type(fluxus.queue_on_teleport) == "function" then
        queueFunctions[#queueFunctions + 1] = fluxus.queue_on_teleport
    end
    if type(krnl) == "table" and type(krnl.queue_on_teleport) == "function" then
        queueFunctions[#queueFunctions + 1] = krnl.queue_on_teleport
    end

    for _, queueFn in ipairs(queueFunctions) do
        local ok, result = pcall(queueFn, source)
        if ok and result ~= false then
            return true
        end
    end

    if Settings.AutoExecute == true then
        warn("[Merciful Auto Execute] No supported queue_on_teleport function was found, or the executor rejected the queue.")
    end
    return false
end

task.spawn(function()
    while task.wait(30) do pcall(SaveTotals) end
end)

HUD.GetRunTime = GetRunTime
HUD.GetEarnedBounty = GetEarnedBounty
HUD.GetStats = function()
    return {
        Bounty = GetMyBounty(),
        Earned = GetEarnedBounty(),
        TotalEarned = TotalEarned,
        Runtime = GetRunTime(),
        TotalRuntimeBase = TotalRuntimeBase,
        KillCount = TotalKills,
        RecentKills = RecentKills,
        Stay = Stay:Elapsed(),
        StayLimit = Stay:Limit(),
        Players = #Players:GetPlayers()
    }
end
HUD.ResetAllServerTotals = ResetAllServerTotals
HUD.QueueAutoReExecute = QueueAutoReExecute
HUD.SendWebhookSummary = SendWebhookSummary
end

SetupHUD()

local ServerHopCache = { List = nil, Fetching = false }

local function FetchServerList(timeout)
    local browser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
    if not browser then return nil end
    local servers, pending = {}, 0
    for page = 1, 100 do
        pending = pending + 1
        task.delay(page * 0.02, function()
            local ok, result = pcall(function() return browser:InvokeServer(page) end)
            if not ok then
                local tries = 0
                repeat
                    task.wait(0.5)
                    tries = tries + 1
                    ok, result = pcall(function() return browser:InvokeServer(page) end)
                until ok or tries >= 2
            end
            if ok and type(result) == "table" then
                for job, info in pairs(result) do
                    if type(info) == "table" then
                        servers[job] = {
                            Region = tostring(info.Region or "Unknown"),
                            Count = tonumber(info.Count) or 0,
                            Bounty = tonumber(info.Bounty) or 0
                        }
                    end
                end
            end
            pending = pending - 1
        end)
    end
    local deadline = tick() + (timeout or 20)
    while pending > 0 and tick() < deadline do task.wait(0.1) end
    return servers
end

local function GetServerList()
    if ServerHopCache.List then return ServerHopCache.List end
    if ServerHopCache.Fetching then
        local deadline = tick() + 25
        while ServerHopCache.Fetching and tick() < deadline do task.wait(0.1) end
        return ServerHopCache.List
    end
    ServerHopCache.Fetching = true
    local ok, servers = pcall(FetchServerList, 20)
    ServerHopCache.Fetching = false
    if ok and type(servers) == "table" and next(servers) then
        ServerHopCache.List = servers
    end
    return ServerHopCache.List
end

local function MatchRegion(info)
    if not info then return false end
    local want = tostring(Settings.ServerRegion or "")
    if want == "" or want == T("Random") or want == "Random" then return true end
    return tostring(info.Region or ""):lower():find(want:lower(), 1, true) ~= nil
end

local function MatchServer(info)
    if not info then return false end
    if not MatchRegion(info) then return false end
    local count = tonumber(info.Count) or 0
    if count < HopMinPlayers or count > HopMaxPlayers then return false end
    local bounty = tonumber(info.Bounty) or 0
    return bounty >= HopMinBounty and bounty <= HopMaxBounty
end

local function MatchServerRelaxed(info)
    return MatchRegion(info)
end

local function CollectMatches(servers, predicate)
    local matches = {}
    if type(servers) ~= "table" then return matches end
    for job, info in pairs(servers) do
        if job ~= game.JobId and predicate(info) then
            table.insert(matches, { Job = job, Region = info.Region, Count = info.Count, Bounty = info.Bounty })
        end
    end
    return matches
end

local function PickServer(servers)
    local matches = CollectMatches(servers, MatchServer)
    if #matches > 0 then
        return matches[math.random(1, #matches)], false
    end
    local relaxed = CollectMatches(servers, MatchServerRelaxed)
    if #relaxed > 0 then
        return relaxed[math.random(1, #relaxed)], true
    end
    return nil, false
end

local HauntedEntrance = Vector3.new(923.2130126953125, 126.97599792480469, 32852.83203125)
local HauntedRecoveryLastAttempt = 0
local HopPhase = "idle"
local HopPrepStartY = nil
local DeathHopRequested = false
-- Manual Dynamic Island hop: pause automation, wait for combat risk to clear, then hop immediately.
local ManualHopRequested = false

function HopActive()
    return HopPhase ~= "idle"
end

local HopAscendThread = nil
local function StartHopAscend()
    if HopAscendThread then return end
    -- Keep a private numeric baseline for this task. The shared HopPrepStartY
    -- may be reset by another hop transition while this thread is still alive.
    local hrp0 = GetHRP(LocalPlayer)
    local startY = (hrp0 and tonumber(hrp0.Position.Y)) or tonumber(HopPrepStartY) or 0
    HopPrepStartY = startY
    HopAscendThread = task.spawn(function()
        while HopActive() do
            local hrp = GetHRP(LocalPlayer)
            if hrp then
                local currentY = tonumber(hrp.Position.Y) or startY
                if currentY - startY < 1500 then
                    SafeCall(FleeUpLogic)
                else
                    FlyStop()
                end
            end
            task.wait(0.1)
        end
        FlyStop()
        ClearFlightComponents()
        local char = LocalPlayer.Character
        if char then SetCharNoclip(char, false) end
        if HopPrepStartY == startY then HopPrepStartY = nil end
        HopAscendThread = nil
    end)
end

local HopInterruptedByDanger = false
local HOP_LANDING_GRACE = 5
local HOP_DELAY = 5
local HopCooldownUntil = 0
local HopWaitUntil = 0

local function BeginHopMatch()
    HopPhase = "matching"
    task.spawn(function()
        local servers = GetServerList()
        local target = PickServer(servers)
        if not target then
            ServerHopCache.List = nil
            servers = GetServerList()
            target = PickServer(servers)
        end

        if not HopActive() then return end

        if not target then
            task.wait(3)
            HopPhase = "idle"
            HopCooldownUntil = tick() + HOP_LANDING_GRACE
            DeathHopRequested = false
            ManualHopRequested = false
            return
        end

        if IsBountyAtRisk() and not DeathHopRequested then
            HopPhase = "preparing"
            HopInterruptedByDanger = true
            return
        end
        local localRoot = GetHRP(LocalPlayer)
        if not DeathHopRequested and not ManualHopRequested and AutoBountyArmed and localRoot
            and (localRoot.Position - HauntedEntrance).Magnitude <= 450
            and (HauntedRecoveryLastAttempt == 0 or tick() - HauntedRecoveryLastAttempt < 20) then
            HopPhase = "idle"
            return
        end

        local browser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
        if browser then
            if not HopActive() or (IsBountyAtRisk() and not DeathHopRequested) or (CurrentTarget and not Stay.Armed and not DeathHopRequested) then
                return
            end
            -- Send the completed server summary before leaving this server.
            pcall(HUD.SendWebhookSummary, "Server hop")
            local queueOK = HUD.QueueAutoReExecute()
            if Settings.AutoExecute == true and not queueOK then
                warn("[Merciful Auto Execute] Could not queue the script for this server hop.")
            end
            local teleportOk = pcall(function() browser:InvokeServer("teleport", target.Job) end)
            if not teleportOk then
                HopPhase = "idle"
                HopCooldownUntil = tick() + 2
                ManualHopRequested = false
                DeathHopRequested = false
                return
            end
            ManualHopRequested = false
            DeathHopRequested = false
        else
            ManualHopRequested = false
            DeathHopRequested = false
        end
        task.wait(5)
        ManualHopRequested = false
        DeathHopRequested = false
        HopPhase = "idle"
    end)
end

local function DoServerHop()
    if HopActive() and not ManualHopRequested then return end
    local localRoot = GetHRP(LocalPlayer)
    local nearHauntedShip = localRoot and (localRoot.Position - HauntedEntrance).Magnitude <= 450
    if not DeathHopRequested and not ManualHopRequested and AutoBountyArmed and nearHauntedShip and (HauntedRecoveryLastAttempt == 0 or tick() - HauntedRecoveryLastAttempt < 20) then
        return
    end
    if AutoBountyArmed then
        local env = getgenv and getgenv()
        if type(env) == "table" then env.AutoBountyMinimizeOnResume = true end
        local ui = env and env.MercifulUI
        if ui and type(ui.SetOpen) == "function" then pcall(ui.SetOpen, false) end
    end

    HopPhase = "preparing"
    HopPrepStartY = nil
    ResetTarget()
    StartHopAscend()

    if IsBountyAtRisk() and not DeathHopRequested then
        HopInterruptedByDanger = true
        return
    end

    if ManualHopRequested then
        -- Manual hop uses the same combat-risk gate as auto-hop, but no extra delay.
        HopPhase = "matching"
        BeginHopMatch()
    else
        HopPhase = "waiting"
        HopWaitUntil = tick() + HOP_DELAY
    end
end
task.spawn(function()
    while true do
        task.wait(0.2)
        if HopPhase == "waiting" then
            local localRoot = GetHRP(LocalPlayer)
            if AutoBountyArmed and localRoot and (localRoot.Position - HauntedEntrance).Magnitude <= 450
                and (HauntedRecoveryLastAttempt == 0 or tick() - HauntedRecoveryLastAttempt < 20) then
                HopPhase = "idle"
            elseif IsBountyAtRisk() and not DeathHopRequested then
                HopPhase = "preparing"
                HopInterruptedByDanger = true
            elseif tick() >= HopWaitUntil then
                BeginHopMatch()
            end
        elseif HopPhase == "matching" and IsBountyAtRisk() and not DeathHopRequested then
            HopPhase = "preparing"
            HopInterruptedByDanger = true
        elseif HopPhase == "preparing" and (not IsBountyAtRisk() or DeathHopRequested) then
            HopInterruptedByDanger = false
            if ManualHopRequested then
                -- As soon as combat risk clears, resume server selection immediately.
                HopPhase = "matching"
                BeginHopMatch()
            elseif CurrentTarget and not Stay.Armed then
                HopPhase = "idle"
            elseif AutoBountyArmed then
                HopPhase = "waiting"
                HopWaitUntil = tick() + HOP_DELAY
            else
                HopPhase = "idle"
            end
        end
    end
end)

do
    local function ArmForcedHop()
        Stay.Armed = true
        if CurrentTarget then ResetTarget() end
    end

    task.spawn(function()
        while true do
            task.wait(0.5)
            if Stay:Reached() then
                if not Stay.Armed then ArmForcedHop() end
                if not HopActive() and tick() >= HopCooldownUntil then
                    DoServerHop()
                end
            elseif Stay.Armed then
                Stay.Armed = false
            end
        end
    end)
end

do
    local DEATH_HOP_LIMIT = 1
    local DeathCount = 0
    local DeathBound = nil

    local function OnDeath()
        if HopActive() then return end
        DeathCount += 1
        if DeathCount < DEATH_HOP_LIMIT then return end
        DeathCount = 0
        DeathHopRequested = true
        SafeCall(DoServerHop)
    end

    local function BindDeathHop()
        local hum = GetHumanoid(LocalPlayer)
        if not hum or hum == DeathBound then return end
        DeathBound = hum
        hum.Died:Connect(OnDeath)
    end

    BindDeathHop()

task.spawn(function()
    local lastPosition, stalledSince = nil, tick()
    while task.wait(1) do
        if not AutoBountyArmed then
            lastPosition, stalledSince = nil, tick()
            continue
        end
        local root = GetHRP(LocalPlayer)
        if not root then lastPosition, stalledSince = nil, tick(); continue end
        local position = root.Position
        local nearHauntedShip = (position - HauntedEntrance).Magnitude <= 450
        local targetFar = not CurrentTargetRoot or not CurrentTargetRoot.Parent
            or (CurrentTargetRoot.Position - position).Magnitude >= 120
        if not nearHauntedShip or not targetFar then
            lastPosition, stalledSince = position, tick()
            continue
        end
        if not lastPosition or (position - lastPosition).Magnitude >= 5 then
            lastPosition, stalledSince = position, tick()
            continue
        end
        if tick() - stalledSince >= 12 and (HauntedRecoveryLastAttempt == 0 or tick() - HauntedRecoveryLastAttempt >= 35) then
            HauntedRecoveryLastAttempt = tick()
            stalledSince = tick()
            local ok = pcall(function() CommF:InvokeServer("requestEntrance", HauntedEntrance) end)
            if ok then
                local env = getgenv and getgenv()
                local ui = env and env.MercifulUI
                if ui and type(ui.SetStatus) == "function" then pcall(ui.SetStatus, "Hunting", "Recovering from Haunted Ship") end
            end
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
        DeathBound = nil
        task.wait(0.2)
        BindDeathHop()
    end)

    task.spawn(function()
        while true do
            task.wait(0.5)
            if GetHumanoid(LocalPlayer) ~= DeathBound then BindDeathHop() end
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(1)
        if Settings.AutoEnablePVP then
            pcall(function() CommF:InvokeServer("EnablePvp") end)
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(2)
        if Settings.AutoHaki then
            local char = LocalPlayer.Character
            if char and not char:FindFirstChild("HasBuso") then
                pcall(function() CommF:InvokeServer("Buso") end)
            end
        end
    end
end)

local function StartAutoKenLoop()
local KEN_PRESS_GAP = 1.2
local KEN_VERIFY = 1.0
local KEN_FAIL_BACKOFF = 20
local KEN_MAX_FAILS = 3
local KEN_DISABLE_LOCK = 5.5

local function KenChar()
    local char = LocalPlayer.Character
    if not char or not char.Parent then
        return nil
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then
        return nil
    end
    return char
end

local function KenOn()
    local active = LocalPlayer:GetAttribute("KenActive")
    if active ~= nil then return active == true end
    local blur = game:GetService("Lighting"):FindFirstChild("Blur")
    return (blur and blur.Enabled) and true or false
end

local function KenPressKey()
    local code = Enum.KeyCode.E
    VirtualInputManager:SendKeyEvent(true, code, false, game)
    task.wait(0.1)
    VirtualInputManager:SendKeyEvent(false, code, false, game)
end

local KenNextAt, KenFailCount, KenPendingAt, KenLockUntil = 0, 0, 0, 0
local KenDisableBound = false
local KenStatus = nil

local function BindKenDisable()
    if KenDisableBound then return end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local disable = remotes and remotes:FindFirstChild("DisableKen")
    if not disable then return end
    KenDisableBound = true
    pcall(function()
        disable.OnClientEvent:Connect(function()
            KenLockUntil = os.clock() + KEN_DISABLE_LOCK
        end)
    end)
end

local function KenStep()
    if not Settings.AutoKen then
        KenNextAt, KenFailCount, KenPendingAt = 0, 0, 0
        KenStatus = "off"
        return KenStatus
    end

    BindKenDisable()
    local char = KenChar()
    local now = os.clock()

    if not char then
        KenNextAt, KenFailCount, KenPendingAt = 0, 0, 0
        KenStatus = "no_char"
    elseif KenOn() then
        KenNextAt, KenFailCount, KenPendingAt = 0, 0, 0
        KenStatus = "on"
    elseif char:FindFirstChild("KenDisabled") then
        KenNextAt, KenFailCount, KenPendingAt = 0, 0, 0
        KenStatus = "blocked"
    elseif now < KenLockUntil then
        KenStatus = "locked"
    elseif now >= KenNextAt then
        if KenPendingAt > 0 and now - KenPendingAt >= KEN_VERIFY then
            KenFailCount = KenFailCount + 1
        end
        KenPendingAt = 0
        if KenFailCount >= KEN_MAX_FAILS then
            KenStatus = "fail"
            KenFailCount = 0
            KenNextAt = now + KEN_FAIL_BACKOFF
        else
            KenStatus = "trying"
            KenPressKey()
            KenPendingAt = os.clock()
            KenNextAt = os.clock() + KEN_PRESS_GAP
        end
    else
        KenStatus = "wait"
    end
    return KenStatus
end

task.spawn(function()
    while true do
        task.wait(0.5)
        pcall(KenStep)
    end
end)
end

StartAutoKenLoop()

task.spawn(function()
    while true do
        task.wait(2)
        local team = LocalPlayer.Team
        if not team or team.Name ~= Settings.SelectTeam then
            ApplyTeam(Settings.SelectTeam)
        end
    end
end)

local function StartV3Loop()
local AUTO_V3_RANGE = 150
local AUTO_V3_COOLDOWN = 1.5

local function ConsiderEnemy(hrp, myPos, best, myHRP)
    if not hrp or hrp == myHRP then return best end
    local dist = (hrp.Position - myPos).Magnitude
    if not best or dist < best then return dist end
    return best
end

local function GetNearestEnemyDistance(limit)
    local myHRP = GetHRP(LocalPlayer)
    if not myHRP then return nil end
    local myPos = myHRP.Position
    local best = nil
    if CurrentTarget and CurrentTarget ~= LocalPlayer then
        best = ConsiderEnemy(GetHRP(CurrentTarget), myPos, best, myHRP)
    end
    if not best or not limit or best > limit then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local hum = GetHumanoid(plr)
                if hum and hum.Health > 0 then
                    best = ConsiderEnemy(GetHRP(plr), myPos, best, myHRP)
                end
            end
        end
    end
    if best and limit and best <= limit then return best end
    local enemies = Workspace:FindFirstChild("Enemies")
    if enemies then
        for _, model in ipairs(enemies:GetChildren()) do
            local hum = model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                best = ConsiderEnemy(model:FindFirstChild("HumanoidRootPart"), myPos, best, myHRP)
                if best and limit and best <= limit then break end
            end
        end
    end
    return best
end

local function V3Ready()
    local char = LocalPlayer.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local transformed = char:FindFirstChild("RaceTransformed")
    if transformed and transformed.Value then return false end
    return true
end

local function V3Wanted()
    local char = LocalPlayer.Character
    local myHRP = GetHRP(LocalPlayer)
    if myHRP and CurrentTarget and CurrentTarget ~= LocalPlayer then
        local targetHRP = GetHRP(CurrentTarget)
        if targetHRP and (targetHRP.Position - myHRP.Position).Magnitude <= AUTO_V3_RANGE then
            return true
        end
    end
    local dist = GetNearestEnemyDistance(AUTO_V3_RANGE)
    return dist ~= nil and dist <= AUTO_V3_RANGE
end

local V3NextAt = 0

local function V3Step()
    if not Settings.AutoV3 then return "off" end
    if not GetHRP(LocalPlayer) then return "no_char" end
    if not V3Ready() then return "busy" end
    if tick() < V3NextAt then return "wait" end
    if not V3Wanted() then return "no_enemy" end
    pcall(function() CommE:FireServer("ActivateAbility") end)
    V3NextAt = tick() + AUTO_V3_COOLDOWN
    return "fired"
end

task.spawn(function()
    while not GetHRP(LocalPlayer) do
        task.wait(0.5)
    end
    while true do
        task.wait(0.5)
        pcall(V3Step)
    end
end)
end

StartV3Loop()

do
    local nextV4Attempt = 0
    task.spawn(function()
        while true do
            task.wait(0.5)
            if not Settings.AutoV4 or not AutoBountyArmed or ManualHopRequested or tick() < nextV4Attempt then continue end
            local char = LocalPlayer.Character
            local transformed = char and char:FindFirstChild("RaceTransformed")
            if transformed and transformed.Value == true then nextV4Attempt = tick() + 2; continue end
            local charNow = LocalPlayer.Character
            local humNow = charNow and charNow:FindFirstChildOfClass("Humanoid")
            if humNow and humNow.Health > 0 then
                pcall(function()
                    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Y, false, game)
                    task.wait(0.05)
                    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Y, false, game)
                end)
                -- Retry frequently until RaceTransformed becomes true; no enemy proximity gate.
                nextV4Attempt = tick() + 0.75
            else
                nextV4Attempt = tick() + 1
            end
        end
    end)
end

local function SoruTo(targetPosition)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChild("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return false end
    local startCFrame = hrp.CFrame
    local finalCFrame = RJR:SafeGoal((startCFrame - startCFrame.Position) + targetPosition + Vector3.new(0, hrp.Size.Y * 1.5, 0), false)
    pcall(function()
        CommE:FireServer("Soru", startCFrame, finalCFrame, workspace:GetServerTimeNow(), math.random(1, 999999999))
    end)
    return true
end

local function SoruToTarget()
    if tick() - SoruLastTime < 10 then return end
    local targetRoot = CurrentTargetRoot
    local myRoot = GetHRP(LocalPlayer)
    if not targetRoot or not targetRoot.Parent or not myRoot then return end
    local distance = (targetRoot.Position - myRoot.Position).Magnitude
    if distance > 900 then return end
    local targetPos = (targetRoot.CFrame * CFrame.new(0, 0, 3)).Position
    if SoruTo(targetPos) then
        SoruLastTime = tick()
    end
end

task.spawn(function()
    while true do
        task.wait(1)
        if Settings.AutoSoru and AutoBountyArmed and not ManualHopRequested then
            SafeCall(SoruToTarget)
        end
    end
end)

-- [CHANGED]
do
    local FleeReturnPos = nil
    local FleeTween = nil
    local FleeSkyLocked = false
    local function ClearFleeState()
        FleeActive = false
        FleeReturnPos = nil
        FleeSkyLocked = false
        if FleeTween then pcall(function() FleeTween:Cancel() end); FleeTween = nil end
    end
    local function StopFleeFly()
        FlyStop()
        ClearFlightComponents()
        local char = LocalPlayer.Character
        if char then pcall(SetCharNoclip, char, false) end
    end
    local function FinishFleeAtSky(skyPos)
        task.spawn(function()
            while FleeActive and not ManualHopRequested and AutoBountyArmed do
                local char = LocalPlayer.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not char or not hum or hum.Health <= 0 or not root then return end

                -- Equip Gravity while still climbing; don't wait for a cooldown UI that
                -- only appears after the tool is equipped.
                pcall(GravityState.GTP.prepare)
                if GravityState.GravityFEnabled
                    and tick() >= GravityState.GravityFTeamReadyAt
                    and GravityState.GTP.fReady() then
                    local fired = false
                    local ok, result = pcall(function()
                        return GravityState.GTP.runFSequence(function()
                            return skyPos
                        end, function()
                            return not FleeActive or ManualHopRequested or not AutoBountyArmed
                        end, function()
                            fired = true
                            FleeSkyLocked = true
                            FlyStop()
                        end)
                    end)
                    if fired or (ok and result == true) then
                        FleeSkyLocked = true
                        FlyStop()
                        return
                    end
                end

                -- Maintain upward velocity between retries so the character never drops.
                root = GetHRP(LocalPlayer)
                if root then FlyMoveTo(root.Position + Vector3.new(0, 150, 0)) end
                task.wait(0.08)
            end
        end)
    end
    local function BeginFleeAscend()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not char or not hum or not hrp or hum.Health <= 0 then return end
        SetCharNoclip(char, true)
        local enemyRoot = CurrentTarget and GetHRP(CurrentTarget)
        local enemyPos = enemyRoot and enemyRoot.Position or hrp.Position
        local skyPos = Vector3.new(enemyPos.X, GravityState.FLEE_SKY_Y, enemyPos.Z)
        FlyMoveTo(hrp.Position + Vector3.new(0, 150, 0))
        FinishFleeAtSky(skyPos)
    end
    task.spawn(function()
        while true do
            task.wait(0.1)
            if ManualHopRequested or not Settings.AutoFlee or not AutoBountyArmed then
                if FleeActive then StopFleeFly() end
                ClearFleeState()
                continue
            end
            local hum = GetHumanoid(LocalPlayer)
            local hrp = GetHRP(LocalPlayer)
            if not hum or hum.Health <= 0 then
                if FleeActive then StopFleeFly() end
                ClearFleeState()
                continue
            end
            if not hrp then continue end
            local hpPercent = (hum.Health / hum.MaxHealth) * 100
            if hpPercent <= Settings.AutoFleeHP then
                if not FleeActive then
                    FleeActive = true
                    FleeReturnPos = hrp.CFrame
                    StopTween()
                    BeginFleeAscend()
                elseif FleeSkyLocked then
                    pcall(function()
                        local liveRoot = GetHRP(LocalPlayer)
                        if not liveRoot then return end
                        liveRoot.AssemblyLinearVelocity = Vector3.zero
                        liveRoot.AssemblyAngularVelocity = Vector3.zero
                        FlyStop()
                    end)
                end
            elseif FleeActive then
                StopFleeFly()
                local returnPos = FleeReturnPos
                ClearFleeState()
                if returnPos then pcall(function() MoveTo(returnPos, RJR:Speed()) end) end
            end
        end
    end)
end

local function GetSkillUI()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("Main")
    return main and main:FindFirstChild("Skills")
end

local function SkillList(weaponTip)
    -- Gravity F is a forced skill only while Gravity F mode is enabled.
    -- Return a copy so the user's saved FruitSkills selection is never mutated.
    if weaponTip == "Blox Fruit" then
        local selected = {}
        for _, key in ipairs(Settings.FruitSkills or {}) do
            selected[#selected + 1] = key
        end
        if GravityState.GravityFEnabled and not table.find(selected, "F") then
            selected[#selected + 1] = "F"
        end
        if Settings.V4Only[weaponTip] then
            local char = LocalPlayer.Character
            local v4 = char and char:FindFirstChild("RaceTransformed")
            if (not v4 or v4.Value ~= true) and not GravityState.GravityFEnabled then
                return {}
            end
        end
        return selected
    end
    if Settings.V4Only[weaponTip] then
        local char = LocalPlayer.Character
        local v4 = char and char:FindFirstChild("RaceTransformed")
        if not v4 or v4.Value ~= true then return {} end
    end
    if weaponTip == "Melee" then return Settings.MeleeSkills or {} end
    if weaponTip == "Sword" then return Settings.SwordSkills or {} end
    if weaponTip == "Gun" then return Settings.GunSkills or {} end
    return {}
end

local DEFAULT_SKILL_HOLD = 0.1

local function HoldTime(weaponTip, key)
    local holds = Settings.Hold[weaponTip]
    if holds and tonumber(holds[key]) then
        return holds[key]
    end
    return DEFAULT_SKILL_HOLD
end

local function SkillFrameReady(frame)
    local cd = frame:FindFirstChild("Cooldown")
    if not cd or not cd.Visible then return true end
    -- The HUD animates cooldown width; comparing exact UDim2 values misses ready skills.
    return cd.AbsoluteSize.X <= 1 or (cd.Size.X.Scale <= 0 and cd.Size.X.Offset <= 1)
end

local function FindSkillHolder(ui, tool)
    local holder = ui:FindFirstChild(tool.Name, true)
    if holder then return holder end
    local char = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local loose = nil
    for _, child in ipairs(ui:GetChildren()) do
        local name = child.Name
        local item = (char and char:FindFirstChild(name))
            or (backpack and backpack:FindFirstChild(name))
        if item and item:IsA("Tool") and item.ToolTip == tool.ToolTip then
            return child
        end
        if not loose and #name >= 4
            and (string.find(tool.Name, name, 1, true) or string.find(name, tool.Name, 1, true)) then
            loose = child
        end
    end
    return loose
end

local TransformGuard = { Gap = 12, Last = { } }

local function CollectReadySkills(weaponTip, tool)
    if not tool then return nil end
    local ui = GetSkillUI()
    if not ui then return nil end
    local holder = FindSkillHolder(ui, tool)
    if not holder then return "prep" end
    local ready = {}
    local now = tick()
    for _, key in ipairs(SkillList(weaponTip)) do
        local frame = holder:FindFirstChild(key)
        if frame and frame:IsA("GuiObject") then
            local title = frame:FindFirstChild("Title")
            local titleText = title and title.Text
            local isTransform = (type(titleText) == "string" and string.find(titleText, "Transformation"))
                or string.find(frame.Name, "Transformation")
            local gapOk = true
            if isTransform then
                local lastAt = TransformGuard.Last[weaponTip .. key]
                gapOk = lastAt == nil or (now - lastAt) >= TransformGuard.Gap
            end
            if gapOk and SkillFrameReady(frame) then
                if isTransform then TransformGuard.Last[weaponTip .. key] = now end
                table.insert(ready, key)
            end
        end
    end
    return ready
end

local function SendSkillKey(key, hold)
    local code = Enum.KeyCode[string.upper(key)]
    if not code then return false end
    local pressed = pcall(function()
        VirtualInputManager:SendKeyEvent(true, code, false, game)
    end)
    if not pressed then return false end
    task.wait(math.clamp(tonumber(hold) or DEFAULT_SKILL_HOLD, 0.1, 1))
    -- Always release the key even if the character changes during the hold.
    pcall(function() VirtualInputManager:SendKeyEvent(false, code, false, game) end)
    return true
end

local SkillCastToken = 0
local LastSkillCastTime = 0

local function CastSkill(weaponTip, key, tool)
    if not AutoBountyArmed or ManualHopRequested or not table.find(SkillList(weaponTip), key) then return false end
    local root = CurrentTargetRoot
    if not root or not root.Parent then return false end
    local hold = HoldTime(weaponTip, key)
    SkillCastToken += 1
    local token = SkillCastToken
    LastSkillCastTime = tick()
    LockWeapon("skill", hold + 0.12)
    Aim.Part = root
    Aim.Pos = root.CFrame
    InstallAimHooks()
    local ok = SendSkillKey(key, hold)
    task.delay(0.35, function()
        if SkillCastToken == token then
            Aim.Pos = nil
            Aim.Part = nil
        end
    end)
    return ok
end

local SkillRotation = { Index = 0 }

local function NextOrderedSkill()
    local order = Settings.UseSkillCombo and Settings.SkillOrder or {}
    if type(order) ~= "table" then order = {} else order = table.clone(order) end
    if #order == 0 then
        -- No custom order means keep rotating through every skill selected in the skill chips.
        order = {}
        local fallback = {
            {"Melee", Settings.MeleeSkills}, {"Sword", Settings.SwordSkills},
            {"Blox Fruit", Settings.FruitSkills}, {"Gun", Settings.GunSkills}
        }
        for _, group in ipairs(fallback) do
            if type(group[2]) == "table" then
                for _, key in ipairs(group[2]) do order[#order + 1] = group[1] .. ":" .. tostring(key) end
            end
        end
    end
    -- Even with a custom combo enabled, Gravity F mode always adds Fruit F.
    -- This is temporary runtime state; it does not alter or save the user's combo.
    if GravityState.GravityFEnabled then
        local hasGravityF = false
        for _, entry in ipairs(order) do
            if tostring(entry):match("^Blox Fruit:[Ff]$") then
                hasGravityF = true
                break
            end
        end
        if not hasGravityF then
            order[#order + 1] = "Blox Fruit:F"
        end
    end
    if #order == 0 then return nil end
    for offset = 1, #order do
        local index = (SkillRotation.Index + offset - 1) % #order + 1
        local weaponTip, key = tostring(order[index]):match("^(.-):([%a])$")
        key = key and string.upper(key) or nil
        if weaponTip and key and table.find(SkillList(weaponTip), key) then
            local tool = FindWeaponTool(weaponTip)
            if tool then return weaponTip, key, tool, index end
        end
    end
    return nil
end

local function AutoSkillStep()
    -- The Gravity F teleport/cast sequence owns the tool and input until it finishes.
    -- Pause the normal rotation briefly rather than interrupting its F cast.
    if GravityState.GravityFEnabled and GravityState.FSequenceRunning then return end
    local root = CurrentTargetRoot
    local myRoot = GetHRP(LocalPlayer)
    if not root or not root.Parent or not myRoot then return end
    local attackRange = GravityState.GravityFEnabled and 240 or 120
    if (root.Position - myRoot.Position).Magnitude > attackRange then return end

    local targetPlayer = CurrentTarget
    local weaponTip, key, tool, orderIndex = NextOrderedSkill()
    if not weaponTip or not tool then return end

    LockWeapon("skill-prep", 0.4)
    if not EquipTool(tool) then
        if not Settings.UseSkillCombo or #Settings.SkillOrder == 0 then SkillRotation.Index = orderIndex end
        return
    end

    local ready = CollectReadySkills(weaponTip, tool)
    local tries = 0
    while ready == "prep" and tries < 4 do
        task.wait(0.05)
        ready = CollectReadySkills(weaponTip, tool)
        tries += 1
    end
    if ready == "prep" or not ready or not table.find(ready, key) then
        if not Settings.UseSkillCombo or #Settings.SkillOrder == 0 then SkillRotation.Index = orderIndex end
        return
    end
    if not AutoBountyArmed or ManualHopRequested or CurrentTarget ~= targetPlayer
        or not CurrentTargetRoot or not CurrentTargetRoot.Parent then return end
    if CastSkill(weaponTip, key, tool) then SkillRotation.Index = orderIndex end
end

local function StartSkillLoop()
    if SkillLoopThread then return end
    SkillLoopThread = task.spawn(function()
        while true do
            if AutoBountyArmed and not ManualHopRequested then
                SafeCall(AutoSkillStep)
            end
            task.wait(0.1)
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(0.5)
        if GravityState.GravityFEnabled then
            Settings.HoldWeapon = "Blox Fruit"
        end
        if AutoBountyArmed and tick() >= HoldWeaponReadyAt
            and not IsWeaponLocked()
            and (tick() - LastSkillCastTime) > 1.5 then
            local char = LocalPlayer.Character
            if char then
                local equipped = char:FindFirstChildOfClass("Tool")
                if not equipped or equipped.ToolTip ~= Settings.HoldWeapon then
                    local tool = FindWeaponTool(Settings.HoldWeapon)
                    if tool then
                        SafeCall(EquipTool, tool)
                    end
                end
            end
        end
    end
end)

local AttackState = {
    FoundRemote = nil,
    FoundRemoteId = nil
}

task.spawn(function()
    local folders = {
        ReplicatedStorage:FindFirstChild("Util"),
        ReplicatedStorage:FindFirstChild("Common"),
        ReplicatedStorage:FindFirstChild("Remotes"),
        ReplicatedStorage:FindFirstChild("Assets"),
        ReplicatedStorage:FindFirstChild("FX")
    }
    local function checkChild(child)
        if child:IsA("RemoteEvent") and child:GetAttribute("Id") then
            AttackState.FoundRemoteId = child:GetAttribute("Id")
            AttackState.FoundRemote = child
        end
    end
    for _, folder in ipairs(folders) do
        if folder then
            for _, child in ipairs(folder:GetChildren()) do checkChild(child) end
            folder.ChildAdded:Connect(checkChild)
        end
    end
end)

-- Keep submitted hit candidates within normal melee range to avoid invalidating the hit batch.
local M1_RANGE = 65

local function AddAttackTarget(list, seen, model, myPos, ignoreRange)
    if not model or seen[model] then return end
    local root = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return end
    if not ignoreRange and (root.Position - myPos).Magnitude > M1_RANGE then return end
    seen[model] = true
    list[#list + 1] = { Model = model, Root = root, Head = model:FindFirstChild("Head") or root }
end

local function GetAttackTargets()
    local myRoot = GetHRP(LocalPlayer)
    if not myRoot then return {} end
    local myPos = myRoot.Position
    local myChar = LocalPlayer.Character
    local targets, seen = {}, {}
    if CurrentTargetRoot and CurrentTargetRoot.Parent then
        AddAttackTarget(targets, seen, CurrentTarget and CurrentTarget.Character, myPos,
            GravityState.GravityFEnabled)
    end
    if GravityState.GravityFEnabled then
        -- Instant TP mode: include every living player character, not just the
        -- current chase target or players inside the ordinary M1 range.
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then
                AddAttackTarget(targets, seen, plr.Character, myPos, true)
            end
        end
    end
    for _, model in ipairs((Workspace:FindFirstChild("Enemies") or Workspace):GetChildren()) do
        if model ~= myChar then
            AddAttackTarget(targets, seen, model, myPos)
        end
    end
    for _, model in ipairs((Workspace:FindFirstChild("Characters") or Workspace):GetChildren()) do
        if model ~= myChar then
            AddAttackTarget(targets, seen, model, myPos)
        end
    end
    return targets
end

local function PerformFastAttack()
    local char = LocalPlayer.Character
    if not char then return end
    if not (char:FindFirstChildOfClass("Tool") or char:FindFirstChild("EquippedWeapon")) then return end
    local targets = GetAttackTargets()
    if #targets == 0 then return end
    if not AttackState.AttackRemote then
        AttackState.AttackRemote = Net:WaitForChild("RE/RegisterAttack")
        AttackState.HitRemote = Net:WaitForChild("RE/RegisterHit")
        AttackState.Seed = Net:FindFirstChild("seed")
    end
    local mainTarget = targets[1]
    local hitList = {}
    for _, target in ipairs(targets) do
        table.insert(hitList, { target.Model, target.Root })
    end
    pcall(function()
        AttackState.AttackRemote:FireServer(0)
        AttackState.HitRemote:FireServer(mainTarget.Head, hitList)
    end)
    if AttackState.FoundRemote and AttackState.FoundRemoteId then
        pcall(function()
            local seedValue = AttackState.Seed and AttackState.Seed:InvokeServer() or 1
            local encryptedId = bit32.bxor(AttackState.FoundRemoteId + 909090, seedValue * 2)
            local rawName = "RE/RegisterHit"
            local timestamp = math.floor(Workspace:GetServerTimeNow() / 10 % 10) + 1
            local encryptedName = string.gsub(rawName, ".", function(c)
                return string.char(bit32.bxor(string.byte(c), timestamp))
            end)
            AttackState.FoundRemote:FireServer(encryptedName, encryptedId, mainTarget.Head, hitList)
        end)
    end
end

task.spawn(function()
    while true do
        if not Settings.FastAttack then
            task.wait(0.2)
            continue
        end
        local startTime = tick()
        SafeCall(PerformFastAttack)
        local elapsed = tick() - startTime
        task.wait(math.max(0.05 - elapsed, 0.001))
    end
end)

local function GetPlayerFruit()
    local char = LocalPlayer.Character
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") and tool.ToolTip == "Blox Fruit" then
                return tool
            end
        end
    end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") and tool.ToolTip == "Blox Fruit" then
                return tool
            end
        end
    end
    return nil
end

local function GetMaxCombo(tool)
    if not tool then return 5 end
    local n = tool.Name
    if n == "T-Rex-T-Rex" then return 4 end
    if n == "Blade-Blade" then return 2 end
    if n == "Pain-Pain" then return 4 end
    if n == "Control-Control" then return 4 end
    if n == "Gas-Gas" then return 5 end
    if n == "Dragon-Dragon" then
        local char = LocalPlayer.Character
        return (char and char:FindFirstChild("DragonHybrid")) and 5 or 3
    end
    return 5
end

task.spawn(function()
    while true do
        task.wait(0.1)
        if not Settings.FruitM1 then continue end
        local fruit = GetPlayerFruit()
        local remote = fruit and fruit:FindFirstChild("LeftClickRemote")
        if not remote then continue end
        local myRoot = GetHRP(LocalPlayer)
        if not myRoot then continue end
        local myChar = LocalPlayer.Character
        local function hit(model, ignoreRange)
            if not model or model == myChar then return end
            local root = model:FindFirstChild("HumanoidRootPart")
            local hum = model:FindFirstChildOfClass("Humanoid")
            if not root or not hum or hum.Health <= 0 then return end
            if not ignoreRange and (root.Position - myRoot.Position).Magnitude > M1_RANGE then return end
            local offset = root.Position - myRoot.Position
            local dir = offset.Magnitude > 0 and offset.Unit or Vector3.new(0, 0, -1)
            pcall(function()
                remote:FireServer(Vector3.new(dir.X, dir.Y, dir.Z), 1, true)
            end)
        end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then hit(plr.Character, GravityState.GravityFEnabled) end
        end
        local enemies = Workspace:FindFirstChild("Enemies")
        if enemies then
            for _, npc in ipairs(enemies:GetChildren()) do hit(npc) end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(0.1)
        if not Settings.VoidFruitM1 then continue end
        local fruit = GetPlayerFruit()
        local remote = fruit and fruit:FindFirstChild("LeftClickRemote")
        if not remote then continue end
        local maxCombo = GetMaxCombo(fruit)
        pcall(function()
            remote:FireServer(Vector3.new(9e30, 9e30, 9e30), maxCombo, true)
        end)
    end
end)

local Dragon = {
    Ready = false,
    ShootFunc = nil,
    Index = nil,
    Limbs = {
        "Head", "UpperTorso", "LowerTorso",
        "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
        "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg",
        "HumanoidRootPart"
    }
}

local function InitDragon()
    if Dragon.Ready then return end
    if type(debug) ~= "table" or type(debug.getupvalues) ~= "function" then return end
    local ok = pcall(function()
        local controller = require(ReplicatedStorage:WaitForChild("Controllers"):WaitForChild("CombatController"))
        for _, value in ipairs(debug.getupvalues(controller.Attack)) do
            if type(value) == "function" then
                for i, upvalue in ipairs(debug.getupvalues(value)) do
                    if upvalue == 727595 then
                        Dragon.ShootFunc = value
                        Dragon.Index = { u25 = i - 3, u21 = i - 2, u24 = i - 1, u20 = i, u22 = i + 1, u23 = i + 2, u26 = i + 3 }
                        break
                    end
                end
                if Dragon.ShootFunc then break end
            end
        end
    end)
    if ok and Dragon.ShootFunc then
        Dragon.Ready = true
    end
end

local function FireDragonShot(pos, hit)
    if not Dragon.ShootFunc or not Dragon.Index then return end
    local idx = Dragon.Index
    local u20 = debug.getupvalue(Dragon.ShootFunc, idx.u20)
    local u21 = debug.getupvalue(Dragon.ShootFunc, idx.u21)
    local u22 = debug.getupvalue(Dragon.ShootFunc, idx.u22)
    local u23 = debug.getupvalue(Dragon.ShootFunc, idx.u23)
    local u24 = debug.getupvalue(Dragon.ShootFunc, idx.u24)
    local u25 = debug.getupvalue(Dragon.ShootFunc, idx.u25)
    local u26 = debug.getupvalue(Dragon.ShootFunc, idx.u26)
    local u79 = u25 * u21
    local u80 = (u24 * u21 + u25 * u20) % u22
    u80 = (u80 * u22 + u79) % u23
    u24 = math.floor(u80 / u22)
    u25 = u80 - u24 * u22
    u26 += 1
    debug.setupvalue(Dragon.ShootFunc, idx.u24, u24)
    debug.setupvalue(Dragon.ShootFunc, idx.u25, u25)
    debug.setupvalue(Dragon.ShootFunc, idx.u26, u26)
    ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Validator2"):FireServer(math.floor(u80 / u23 * 16777215), u26)
    Net:WaitForChild("RE/ShootGunEvent"):FireServer(pos, { hit })
end

task.spawn(function()
    while not Dragon.Ready do
        InitDragon()
        task.wait(1)
    end
    while true do
        task.wait()
        if ManualHopRequested or not Settings.Dragonstorm or IsWeaponLocked() then continue end
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        if not tool or tool.Name ~= "Dragonstorm" then continue end
        local targetRoot = CurrentTargetRoot
        local myRoot = GetHRP(LocalPlayer)
        if not targetRoot or not targetRoot.Parent or not myRoot then continue end
        if (targetRoot.Position - myRoot.Position).Magnitude > 450 then continue end
        FireDragonShot(targetRoot.Position, targetRoot)
    end
end)

task.spawn(function()
    while true do
        task.wait(0.1)
        local loopOk = pcall(function()
        if ManualHopRequested then
            if ChaseActive then StopChase() end
            if CurrentTarget then ResetTarget() end
            return
        end
        if not AutoBountyArmed then
            GravityState.TeleportRecoveryInProgress = false
            GravityState.FailedTargetRoot = nil
            GravityState.FailedTeleportCount = 0
            if CurrentTarget then ResetTarget() end
            return
        end

        if not ChaseActive then StartChase() end
        if FleeActive then UpdateAimTarget(); return end

        if CurrentTarget then
            Stay:UpdateEngagement(CurrentTarget)
            local valid = EvaluateTarget(CurrentTarget)
            local gone = not CurrentTarget:IsDescendantOf(Players)
            if valid and not gone then
                TargetInvalidSince = nil
                CurrentTargetRoot = CurrentTarget.Character
                    and CurrentTarget.Character:FindFirstChild("HumanoidRootPart")
            else
                ResetTarget()
                TargetInvalidSince = nil
            end
        end

        if CurrentTarget and TargetLockStart > 0
            and tick() - TargetLockStart >= Settings.LockTime then
            TempSkipUntil[CurrentTarget] = tick() + TARGET_SKIP_TIME
            ResetTarget()
            TargetInvalidSince = nil
        end

        if not CurrentTarget and not Stay.Armed then
            if tick() >= NextTargetSwitch then
                NextTargetSwitch = tick() + 0.5
                LastScanTime = tick()
                local nearest = GetNearestTarget()
                if nearest then
                    SetTarget(nearest)
                end
            end
        end

        if CurrentTarget and HopActive() and not Stay.Armed then
            HopPhase = "idle"
            HopInterruptedByDanger = false
        end

        if not CurrentTarget and LastScanTime >= TargetLostTime then
            if IsBountyAtRisk() then
                HopInterruptedByDanger = true
                if not HopActive() then
                    DoServerHop()
                end
            elseif not HopActive() and tick() >= HopCooldownUntil then
                DoServerHop()
            end
        end

        UpdateAimTarget()
        end)
        if not loopOk then
            LastCaughtError = T("Main loop error (auto recovered)")
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    GravityState.LastFSequenceTarget = nil
    GravityState.LastInstantTPAt = 0
    task.wait(0.2)
    ChaseSample = nil
    StopTween()
    NoclipStop()
    SetCollide()
    local hum = GetHumanoid(LocalPlayer)
    if hum then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
    end
    UpdateAimTarget()
    local team = LocalPlayer.Team
    if not team or team.Name ~= Settings.SelectTeam then
        ApplyTeam(Settings.SelectTeam)
    end
    if HopActive() then
        HopPhase = "idle"
        ServerHopCache.List = nil
        TargetLockStart = tick()
        HopCooldownUntil = tick() + HOP_LANDING_GRACE
    end
end)

local function StartAntiSit()
local AntiSitBound = nil

local function UnsitNow()
    local hum = GetHumanoid(LocalPlayer)
    if not hum or not hum.Sit then return false end
    pcall(function() hum.Sit = false end)
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    return true
end

local function BindAntiSit()
    local hum = GetHumanoid(LocalPlayer)
    if not hum or hum == AntiSitBound then return end
    AntiSitBound = hum
    hum:GetPropertyChangedSignal("Sit"):Connect(function()
        if hum.Sit then UnsitNow() end
    end)
    hum.StateChanged:Connect(function(_, newState)
        if newState == Enum.HumanoidStateType.Seated then UnsitNow() end
    end)
end

BindAntiSit()

LocalPlayer.CharacterAdded:Connect(function()
    AntiSitBound = nil
    task.wait(0.2)
    BindAntiSit()
end)

task.spawn(function()
    while true do
        task.wait(0.25)
        if GetHumanoid(LocalPlayer) ~= AntiSitBound then BindAntiSit() end
        UnsitNow()
    end
end)
end

StartAntiSit()

do
    local function CheckAndDestroyLava(v)
        if not v then return end
        local name = v.Name
        if name == "Lava" then
            pcall(function() v:Destroy() end)
        elseif name == "LavaParts" then
            local parent = v.Parent
            if parent then
                local pName = parent.Name
                if pName == "CircleIsland" or pName == "GhostShipInterior" then
                    local grandParent = parent.Parent
                    if grandParent and grandParent.Name == "Map" then
                        pcall(function() v:Destroy() end)
                    end
                end
            end
        end
    end

    local function SweepLava(container)
        if not container then return end
        pcall(function()
            for _, v in ipairs(container:GetDescendants()) do
                CheckAndDestroyLava(v)
            end
        end)
    end

    SweepLava(Workspace)
    SweepLava(ReplicatedStorage)

    pcall(function()
        Workspace.DescendantAdded:Connect(CheckAndDestroyLava)
        ReplicatedStorage.DescendantAdded:Connect(CheckAndDestroyLava)
    end)

    task.spawn(function()
        while true do
            task.wait(Settings.FPSBoost and 60 or 10)
            SweepLava(Workspace)
        end
    end)
end

Players.PlayerRemoving:Connect(function(plr)
    if plr == CurrentTarget then
        ResetTarget()
    end
end)

local ESPObjects = {}

local function RemoveESP(p)
    local objs = ESPObjects[p]
    if objs then
        if objs.Highlight and objs.Highlight.Parent then objs.Highlight:Destroy() end
        if objs.Billboard and objs.Billboard.Parent then objs.Billboard:Destroy() end
        ESPObjects[p] = nil
    end
    if p and p.Character then
        local h = p.Character:FindFirstChild("ESP_Highlight")
        if h then h:Destroy() end
        local head = p.Character:FindFirstChild("Head")
        if head then
            local bill = head:FindFirstChild("ESP_Billboard")
            if bill then bill:Destroy() end
        end
    end
end

local function CreateESP(p)
    if p == LocalPlayer then return end
    local char = p.Character
    if not char then return end
    local head = char:FindFirstChild("Head")
    if not head then return end

    local objs = ESPObjects[p] or {}
    ESPObjects[p] = objs

    if not objs.Highlight or not objs.Highlight.Parent then
        local h = char:FindFirstChild("ESP_Highlight")
        if not h then
            h = Instance.new("Highlight")
            h.Name = "ESP_Highlight"
            h.FillColor = Color3.fromRGB(255, 80, 80)
            h.OutlineColor = Color3.fromRGB(255, 255, 255)
            h.FillTransparency = 0.6
            h.OutlineTransparency = 0.1
            h.Adornee = char
            h.Parent = char
        end
        objs.Highlight = h
    end

    if not objs.Billboard or not objs.Billboard.Parent then
        local bill = head:FindFirstChild("ESP_Billboard")
        if not bill then
            bill = Instance.new("BillboardGui")
            bill.Name = "ESP_Billboard"
            bill.AlwaysOnTop = true
            bill.Size = UDim2.new(0, 200, 0, 110)
            bill.StudsOffset = Vector3.new(0, 4.5, 0)
            bill.Adornee = head
            bill.Parent = head

            local info = Instance.new("TextLabel", bill)
            info.Name = "InfoLabel"
            info.Size = UDim2.new(1, 0, 0, 80)
            info.BackgroundTransparency = 1
            info.TextStrokeTransparency = 0.1
            info.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            info.Font = Enum.Font.GothamBold
            info.TextSize = Settings.ESP_FontSize
            info.TextColor3 = Color3.fromRGB(255, 255, 255)
            info.RichText = true
            info.TextYAlignment = Enum.TextYAlignment.Bottom

            local barBG = Instance.new("Frame", bill)
            barBG.Name = "HealthBarBG"
            barBG.Size = UDim2.new(0, 110, 0, 5)
            barBG.Position = UDim2.new(0.5, -55, 0, 92)
            barBG.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
            barBG.BorderSizePixel = 0
            local c1 = Instance.new("UICorner", barBG)
            c1.CornerRadius = UDim.new(1, 0)

            local barFG = Instance.new("Frame", barBG)
            barFG.Name = "HealthBarFG"
            barFG.Size = UDim2.new(1, 0, 1, 0)
            barFG.BackgroundColor3 = Color3.fromRGB(0, 255, 130)
            barFG.BorderSizePixel = 0
            local c2 = Instance.new("UICorner", barFG)
            c2.CornerRadius = UDim.new(1, 0)
        end
        objs.Billboard = bill
    end
end

local function UpdateESPText(p, bill, hum, hrp, myHRP)
    local info = bill:FindFirstChild("InfoLabel")
    local barBG = bill:FindFirstChild("HealthBarBG")
    local barFG = barBG and barBG:FindFirstChild("HealthBarFG")
    if info then
        local display = ""
        if Settings.ESP_ShowName then
            display = display .. "<b>" .. p.Name .. "</b>\n"
        end
        if Settings.ESP_ShowLevel then
            local lv = GetLevel(p) or "???"
            display = display .. '<font color="#FFFFFF">Lv. ' .. tostring(lv) .. '</font>\n'
        end
        if Settings.ESP_ShowPVP then
            if IsPVPEnabled(p) then
                display = display .. '<font color="#00FF88">' .. T("[ PVP ON ]") .. '</font>\n'
            else
                display = display .. '<font color="#FF4D4D">' .. T("[ PVP OFF ]") .. '</font>\n'
            end
        end
        local line = ""
        if Settings.ESP_ShowHealth then
            line = '<font color="#FFFFFF">HP: ' .. math.floor(hum.Health) .. "/" .. math.floor(hum.MaxHealth) .. '</font> '
        end
        if Settings.ESP_ShowDistance and myHRP then
            line = line .. '<font color="#FFFFFF">[' .. math.floor((myHRP.Position - hrp.Position).Magnitude) .. 'm]</font>'
        end
        if line ~= "" then display = display .. line end
        info.Text = display
        info.TextSize = Settings.ESP_FontSize
    end
    if barBG and barFG then
        barBG.Visible = Settings.ESP_ShowHealth
        if Settings.ESP_ShowHealth then
            local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
            barFG.Size = UDim2.fromScale(pct, 1)
            if pct > 0.5 then
                barFG.BackgroundColor3 = Color3.fromRGB(255 * (1 - pct) * 2, 255, 50)
            else
                barFG.BackgroundColor3 = Color3.fromRGB(255, 255 * pct * 2, 50)
            end
        end
    end
end

task.spawn(function()
    while true do
        task.wait(0.1)
        if Settings.ESP then
            local myHRP = GetHRP(LocalPlayer)
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer then
                    local char = p.Character
                    local head = char and char:FindFirstChild("Head")
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    local hum = char and char:FindFirstChildOfClass("Humanoid")
                    if head and hrp and hum and hum.Health > 0 then
                        CreateESP(p)
                        local objs = ESPObjects[p]
                        if objs and objs.Billboard then
                            UpdateESPText(p, objs.Billboard, hum, hrp, myHRP)
                        end
                    else
                        RemoveESP(p)
                    end
                end
            end
        end
    end
end)

Players.PlayerRemoving:Connect(function(p)
    RemoveESP(p)
end)

local DEFAULT_SKILL_HOLD = 0.1

local HttpService = game:GetService("HttpService")
local CONFIG_FOLDER = "workspace/AutoBountyMain"
local OLD_CONFIG_FOLDER = "AutoBountyMain"
local LEGACY_CONFIG_FILE = OLD_CONFIG_FOLDER .. "/config.json"

local function GetAccountTag()
    local name = "unknown"
    local id = "0"
    if LocalPlayer then
        name = tostring(LocalPlayer.Name or name)
        if LocalPlayer.UserId then id = tostring(LocalPlayer.UserId) end
    end
    name = name:gsub("[^%w_%-]", "_")
    return name .. "_" .. id
end

local ACCOUNT_TAG = GetAccountTag()
local CONFIG_FILE = CONFIG_FOLDER .. "/config_" .. ACCOUNT_TAG .. ".json"
local CONFIG_FALLBACK_FILE = CONFIG_FOLDER .. "/config_backup_" .. ACCOUNT_TAG .. ".json"
local OLD_CONFIG_FILE = OLD_CONFIG_FOLDER .. "/config_" .. ACCOUNT_TAG .. ".json"

local function EnsureConfigFolder()
    if type(makefolder) ~= "function" then return false end
    local function ensure(path)
        local exists = false
        if type(isfolder) == "function" then
            local ok, result = pcall(isfolder, path)
            exists = ok and result == true
        end
        if not exists then pcall(makefolder, path) end
    end
    ensure("workspace")
    ensure(CONFIG_FOLDER)
    return true
end

local function ListToMap(list)
    local map = {}
    if type(list) == "table" then
        for _, key in ipairs(list) do map[key] = true end
    end
    return map
end

local LastSaveError = nil
local LastSaveOk = false
local RefreshMercifulUI

function SaveConfig(silent)
    EnsureConfigFolder()
    for _, key in ipairs({ "BountyBase", "AutoBountyBountyBase", "AutoBountyEarned", "AutoBountyRunTime" }) do
        Settings[key] = nil
    end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(Settings) end)
    if not ok then
        LastSaveError = T("Serialize failed: ") .. tostring(encoded)
        LastSaveOk = false
        return false
    end
    -- Keep a session fallback so settings still survive script re-execution when file APIs are unavailable.
    local env = getgenv and getgenv()
    if type(env) == "table" then
        env.MercifulConfigJSON = encoded
        local decodedOk, decoded = pcall(function() return HttpService:JSONDecode(encoded) end)
        if decodedOk and type(decoded) == "table" then env.Config = decoded end
    end
    if type(writefile) ~= "function" then
        LastSaveError = "File API unavailable; settings are saved for this executor session only."
        LastSaveOk = false
        return false
    end

    local ok2, err = pcall(writefile, CONFIG_FILE, encoded)
    if not ok2 then
        local ok3, err3 = pcall(writefile, CONFIG_FALLBACK_FILE, encoded)
        if ok3 then
            CONFIG_FILE = CONFIG_FALLBACK_FILE
            ok2, err = true, nil
        else
            err = tostring(err) .. T(" / fallback failed too: ") .. tostring(err3)
        end
    end

    if ok2 then
        LastSaveError = nil
        LastSaveOk = true
    else
        LastSaveError = tostring(err)
        LastSaveOk = false
    end

    return ok2 == true
end

local function LoadConfig(silent)
    local source, raw = nil, nil
    local env = getgenv and getgenv()
    -- Prefer the latest in-session snapshot; a stale disk file must not overwrite newer edits.
    if type(env) == "table" and type(env.MercifulConfigJSON) == "string" then
        raw, source = env.MercifulConfigJSON, "session"
    end
    if not raw and type(isfile) == "function" and type(readfile) == "function" then
        if isfile(CONFIG_FILE) then
            source = CONFIG_FILE
        elseif isfile(CONFIG_FALLBACK_FILE) then
            source = CONFIG_FALLBACK_FILE
        elseif isfile(OLD_CONFIG_FILE) then
            source = OLD_CONFIG_FILE
        elseif isfile(LEGACY_CONFIG_FILE) then
            source = LEGACY_CONFIG_FILE
        end
        if source then
            local ok, contents = pcall(readfile, source)
            if ok and type(contents) == "string" and contents ~= "" then raw = contents end
        end
    end
    if not raw then return false end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then
        return false
    end

    ApplyConfigTable(data)

    ApplyPlayerRange(Settings.HopPlayerRange)
    ApplyBountyRange(Settings.HopBountyRange)

    local loadedVersion = tonumber(data.ConfigVersion) or 1
    if loadedVersion < 2 then
        for _, holds in pairs(Settings.Hold) do
            for key in pairs(holds) do
                holds[key] = DEFAULT_SKILL_HOLD
            end
        end
        Settings.ConfigVersion = 2
    end
    Stay.Performance:SetEnabled(Settings.FPSBoost == true)
    RJR.TweenSpeed = math.clamp(tonumber(Settings.CustomTweenSpeed) or 200, 50, 220)
    SafeCall(RJR.ApplyWaterWalk, RJR, Settings.WaterWalk == true)
    ConfigLoading = true
    ConfigLoading = false
    if RefreshMercifulUI then RefreshMercifulUI() end
    if source and source ~= CONFIG_FILE and source ~= "session" then
        SaveConfig(true)
    end
    return true
end

local ConfigExport = {}
function ConfigExport.Text(data)
    local KEYWORDS = {
        ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
        ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
        ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
        ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
        ["until"] = true, ["while"] = true
    }
    local function IsIdentifierKey(key)
        return type(key) == "string" and key:match("^[%a_][%w_]*$") ~= nil and not KEYWORDS[key]
    end
    local function Quote(text)
        local escaped = text:gsub("\\", "\\\\"):gsub("\"", "\\\"")
        escaped = escaped:gsub("%c", function(c)
            if c == "\n" then return "\n" end
            if c == "\r" then return "\r" end
            if c == "\t" then return "\t" end
            return string.format("\\%d", string.byte(c))
        end)
        return "\"" .. escaped .. "\""
    end
    local function KeyToLua(key)
        if IsIdentifierKey(key) then return key end
        if type(key) == "number" and key == math.floor(key) then return "[" .. string.format("%d", key) .. "]" end
        return "[" .. Quote(tostring(key)) .. "]"
    end
    local function ToLua(value, indent)
        local kind = type(value)
        if kind == "number" then
            if value ~= value or value == math.huge or value == -math.huge then return "0" end
            if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%d", value) end
            return string.format("%.14g", value)
        elseif kind == "boolean" then
            return value and "true" or "false"
        elseif kind == "string" then
            return Quote(value)
        elseif kind == "table" then
            local pad, inner, parts = string.rep("    ", indent), string.rep("    ", indent + 1), {}
            local arrayLen = #value
            for i = 1, arrayLen do parts[#parts + 1] = inner .. ToLua(value[i], indent + 1) end
            local keys = {}
            for key in pairs(value) do
                local isArrayIndex = type(key) == "number" and key >= 1 and key <= arrayLen and key == math.floor(key)
                if not isArrayIndex then keys[#keys + 1] = key end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, key in ipairs(keys) do parts[#parts + 1] = inner .. KeyToLua(key) .. " = " .. ToLua(value[key], indent + 1) end
            if #parts == 0 then return "{}" end
            return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
        end
        return "nil"
    end
    local clean = {}
    for key, value in pairs(data or {}) do
        if not IsSkippedConfigKey(key) then clean[key] = value end
    end
    return "getgenv().Config = " .. ToLua(clean, 0)
end

ConfigExport.CopyToClipboard = function(text)
    if type(text) ~= "string" then return false end
    local writers = {
        setclipboard,
        toclipboard,
        writeclipboard,
        type(syn) == "table" and syn.write_clipboard or nil
    }
    for _, writer in ipairs(writers) do
        if type(writer) == "function" then
            if select(1, pcall(writer, text)) then return true end
        end
    end
    return false
end

-- ═══════════════════════════════════════════════════════════════
task.spawn(function()
    while true do
        task.wait(1)
        if not ConfigLoading then
            local ok, snapshot = pcall(function() return HttpService:JSONEncode(Settings) end)
            if ok and snapshot and snapshot ~= getgenv().MercifulLastSavedSnapshot then
                SaveConfig(true)
                getgenv().MercifulLastSavedSnapshot = snapshot
            end
        end
    end
end)

task.spawn(function()
    task.wait(0.5)
    LoadConfig(true)
    if InjectedConfig then
        ConfigLoading = true
        ApplyConfigTable(InjectedConfig)
    end
    GravityState.GravityFEnabled = Settings.GravityF ~= false
    if GravityState.GravityFEnabled then Settings.HoldWeapon = "Blox Fruit" end
    GravityState.RefreshTeamDelay()
    local env = getgenv and getgenv()
    local shouldResume = Settings.AutoBounty == true or (type(env) == "table" and env.AutoBountyResume == true)
    Settings.AutoBounty = shouldResume
    AutoBountyArmed = shouldResume
    if type(env) == "table" then env.AutoBountyResume = nil end
    ConfigLoading = false
    TeamConfigReady = true
    if AutoBountyArmed then
        TargetLockStart = tick()
        StartChase()
        StartSkillLoop()
        InstallAimHooks()
    end
    SaveConfig(true)
    local ok, snapshot = pcall(function() return HttpService:JSONEncode(Settings) end)
    if ok then getgenv().MercifulLastSavedSnapshot = snapshot end
    if RefreshMercifulUI then RefreshMercifulUI() end
    SafeCall(ApplyTeam, Settings.SelectTeam)
end)

if getgenv then getgenv().AutoBountyMainReady = true end


-- Connect the bounty backend to the supplied Merciful UI through its documented bridge.
local MercifulBridge = {}
local function ResolveBridgeFlag(flag)
    if flag == "LockTimeBounty" then return "LockTime" end
    local p, key = flag:match("^(%a+)Hold(%a)$")
    if p then
        local weapon = ({Melee = "Melee", Sword = "Sword", Fruit = "Blox Fruit", Gun = "Gun"})[p]
        return nil, weapon, key
    end
    local prefix = flag:match("^(%a+)V4Only$")
    if prefix then
        return nil, ({Melee = "Melee", Sword = "Sword", Fruit = "Blox Fruit", Gun = "Gun"})[prefix]
    end
    return flag
end
function MercifulBridge.Get(flag)
    if flag == "GravityF" then return GravityState.GravityFEnabled end
    if flag == "HoldWeapon" and GravityState.GravityFEnabled then return "Blox Fruit" end
    local key, weapon, subkey = ResolveBridgeFlag(flag)
    if subkey then return Settings.Hold[weapon] and Settings.Hold[weapon][subkey] end
    if weapon then return Settings.V4Only[weapon] end
    if key == "Theme" then return Settings.Theme or "Abyss" end
    if key == "UI_Island" or key == "UI_IslandAuto" or key == "UI_Anim" or key == "UI_Orb" then
        if Settings[key] == nil then return true end
    end
    return Settings[key]
end
function MercifulBridge.ParseSkillOrder(value)
    local parsed, currentWeapon = {}, nil
    local valid = {
        Melee = {Z=true, X=true, C=true, V=true, F=true},
        Sword = {Z=true, X=true},
        ["Blox Fruit"] = {Z=true, X=true, C=true, V=true, F=true},
        Gun = {Z=true, X=true}
    }
    local function add(key)
        key = string.upper(key)
        if currentWeapon and valid[currentWeapon] and valid[currentWeapon][key] then
            parsed[#parsed + 1] = currentWeapon .. ":" .. key
        end
    end
    if type(value) == "table" then
        for _, entry in ipairs(value) do
            local weapon, key = tostring(entry):match("^(.-):([%a])$")
            if weapon and valid[weapon] then currentWeapon = weapon; add(key) end
        end
    elseif type(value) == "string" then
        for word in string.lower(value):gmatch("[%a]+") do
            if word == "melee" then currentWeapon = "Melee"
            elseif word == "sword" then currentWeapon = "Sword"
            elseif word == "gun" then currentWeapon = "Gun"
            elseif word == "fruit" then currentWeapon = "Blox Fruit"
            elseif #word == 1 and string.find("zxcvf", word, 1, true) then add(word) end
        end
    end
    return parsed
end

local BypassTweenAccessoryIds = {
    "7ef8f80dee2847768dc6b834b79efff3",
    "0b03f25ada1444e7bb15294dcbb90e2b",
    "574f6c0aa0294e988e8a3bad8f2ae464",
    "3745ac298f8c44c79dd51b839c4ed9b4",
    "eaa0e3e2e5864e47bdb548b8c6ebb479",
    "d4988a3d5a87495f91b78f37f268794c",
}

local function EquipAnyBypassAccessory()
    task.spawn(function()
        for _, accessoryId in ipairs(BypassTweenAccessoryIds) do
            local ok, result = pcall(function()
                return CommF:InvokeServer("LoadItem", accessoryId, nil)
            end)
            if ok and result ~= nil and result ~= false then
                return
            end
            task.wait(0.15)
        end
    end)
end

function MercifulBridge.Set(flag, value)
    local key, weapon, subkey = ResolveBridgeFlag(flag)
    if subkey then
        Settings.Hold[weapon][subkey] = math.clamp(tonumber(value) or 0.1, 0.1, 1)
    elseif weapon then
        Settings.V4Only[weapon] = value == true
    elseif flag == "CustomTweenSpeed" then
        if not Settings.BypassTweenSpeed then
            Settings.CustomTweenSpeed = math.clamp(math.floor(tonumber(value) or 200), 50, 220)
            RJR.TweenSpeed = Settings.CustomTweenSpeed
        end
    elseif flag == "BypassTweenSpeed" then
        local enabled = value == true
        Settings.BypassTweenSpeed = enabled
        local env = getgenv and getgenv()
        local ui = type(env) == "table" and env.MercifulUI or nil
        local speedInput = ui and ui.Elements and ui.Elements.CustomTweenSpeed
        if speedInput and speedInput.SetLocked then
            speedInput.SetLocked(enabled)
        end
        if enabled then
            EquipAnyBypassAccessory()
        else
            RJR.TweenSpeed = math.clamp(tonumber(Settings.CustomTweenSpeed) or 200, 50, 220)
        end
    elseif flag == "GravityF" then
        GravityState.GravityFEnabled = value == true
        Settings.GravityF = GravityState.GravityFEnabled
        if GravityState.GravityFEnabled then
            Settings.HoldWeapon = "Blox Fruit"
        end
        local env = getgenv and getgenv()
        local ui = type(env) == "table" and env.MercifulUI or nil
        local holdDropdown = ui and ui.Elements and ui.Elements.HoldWeapon
        if holdDropdown then
            if type(holdDropdown.SetLocked) == "function" then
                pcall(holdDropdown.SetLocked, GravityState.GravityFEnabled)
            end
            if GravityState.GravityFEnabled and type(holdDropdown.Set) == "function" then
                pcall(holdDropdown.Set, "Blox Fruit")
            end
        end
    elseif flag == "HoldWeapon" then
        if GravityState.GravityFEnabled then
            Settings.HoldWeapon = "Blox Fruit"
            local env = getgenv and getgenv()
            local ui = type(env) == "table" and env.MercifulUI or nil
            local holdDropdown = ui and ui.Elements and ui.Elements.HoldWeapon
            if holdDropdown and type(holdDropdown.Set) == "function" then
                pcall(holdDropdown.Set, "Blox Fruit")
            end
        else
            Settings.HoldWeapon = value
        end
    elseif flag == "SkillOrder" then
        Settings.SkillOrder = MercifulBridge.ParseSkillOrder(value)
        if #Settings.SkillOrder == 0 then
            Settings.UseSkillCombo = false
            local env = getgenv and getgenv()
            local ui = env and env.MercifulUI
            local toggle = ui and ui.Elements and ui.Elements.UseSkillCombo
            if toggle and type(toggle.Set) == "function" then pcall(toggle.Set, false) end
        end
        SkillRotation.Index = 0
        local env = getgenv and getgenv()
        local ui = env and env.MercifulUI
        local list = ui and ui.Elements and ui.Elements.SkillComboList
        if list and type(list.Set) == "function" then pcall(list.Set, Settings.SkillOrder) end
    else
        Settings[key] = value
    end
    if flag == "AutoBounty" then
        AutoBountyArmed = value == true
        Settings.AutoBounty = AutoBountyArmed
        local env = getgenv and getgenv()
        if type(env) == "table" then env.AutoBountyResume = AutoBountyArmed and true or nil end
        if AutoBountyArmed then
            TargetLockStart = tick()
            StartChase()
            StartSkillLoop()
            InstallAimHooks()
        else
            StopChase()
            ResetTarget()
        end
    end
    if flag == "SelectTeam" and TeamConfigReady then
        SafeCall(ApplyTeam, value)
    elseif flag == "HopPlayerRange" then
        ApplyPlayerRange(value)
    elseif flag == "HopBountyRange" then
        ApplyBountyRange(value)
    elseif flag == "FPSBoost" then
        Stay.Performance:SetEnabled(value == true)
    elseif flag == "WaterWalk" then
        SafeCall(RJR.ApplyWaterWalk, RJR, value == true)
    end
    if not ConfigLoading and SaveConfig then
        local saved = SaveConfig(true)
        local env = getgenv and getgenv()
        local ui = env and env.MercifulUI
        if not saved and type(env) == "table" and ui and not env.MercifulSaveWarningShown then
            env.MercifulSaveWarningShown = true
            ui.Notify("Disk saving is unavailable; settings are kept for this executor session.", 4)
        end
    end
end
function MercifulBridge.Action(name)
    local ui = getgenv().MercifulUI
    if name == "ManualHop" then
        -- Take over any current hop phase and pause combat automation immediately.
        ManualHopRequested = true
        DeathHopRequested = false -- unlike death-hop, manual hop must respect combat risk
        Stay.Armed = true
        HopInterruptedByDanger = false
        StopChase()
        ResetTarget()
        HopPhase = "idle"
        HopPrepStartY = nil
        ServerHopCache.List = nil
        SafeCall(DoServerHop)
    elseif name == "ResetAllServerTotals" then
        if HUD.ResetAllServerTotals then HUD.ResetAllServerTotals() end
    elseif name == "AddComboSkill" then
        local entry = Settings.ComboPick
        local weapon, key = tostring(entry):match("^(.-):([%a])$")
        local selectedByWeapon = { Melee = Settings.MeleeSkills, Sword = Settings.SwordSkills, ["Blox Fruit"] = Settings.FruitSkills, Gun = Settings.GunSkills }
        if weapon and key and type(selectedByWeapon[weapon]) == "table" and table.find(selectedByWeapon[weapon], string.upper(key)) then
            local order, exists = {}, false
            for _, item in ipairs(Settings.SkillOrder) do order[#order + 1] = item; if item == entry then exists = true end end
            if not exists and #order < 10 then order[#order + 1] = entry; MercifulBridge.Set("SkillOrder", order) end
        elseif ui then
            ui.Notify("Select that skill below first", 2)
        end
    elseif name == "ClearComboSkills" then
        MercifulBridge.Set("SkillOrder", {})
    elseif name == "SaveConfig" then
        local ok = SaveConfig(false)
        if ui then ui.Notify(ok and "Settings saved" or (LastSaveError or "Settings could not be saved to a file"), 3) end
    elseif name == "LoadConfig" then
        local ok = LoadConfig(false)
        if ui then ui.Notify(ok and "Settings loaded" or "No saved settings were found", 3) end
    elseif name == "ExportConfig" then ConfigExport.CopyToClipboard(ConfigExport.Text(Settings))
    elseif name == "DeleteConfig" then
        for _, path in ipairs({CONFIG_FILE, CONFIG_FALLBACK_FILE, OLD_CONFIG_FILE, LEGACY_CONFIG_FILE}) do
            if type(delfile) == "function" and type(isfile) == "function" and isfile(path) then pcall(delfile, path) end
        end
        local env = getgenv and getgenv()
        if type(env) == "table" then env.MercifulConfigJSON = nil end
    end
end
RefreshMercifulUI = function()
    local ui = getgenv().MercifulUI
    if not ui or type(ui.Elements) ~= "table" then return end
    for flag, element in pairs(ui.Elements) do
        if element and type(element.Set) == "function" then
            local value = MercifulBridge.Get(flag)
            if value ~= nil then pcall(element.Set, value) end
        end
    end
    if type(ui.SetTheme) == "function" then pcall(ui.SetTheme, MercifulBridge.Get("Theme")) end
end
getgenv().MercifulBridge = MercifulBridge

task.spawn(function()
    local lastRosterUpdate = 0
    while true do
        task.wait(0.15)
        local ui = getgenv().MercifulUI
        if ui then
            local state, status = "Idle", "Auto Bounty off"
            if LastCaughtError and string.find(string.lower(LastCaughtError), "risk") then
                state, status = "Risk", tostring(LastCaughtError)
            elseif FleeActive then
                state, status = "Fleeing", "Escaping low health"
            elseif HopPhase and HopPhase ~= "idle" then
                state, status = "Hopping", "Hopping to another server"
            elseif AutoBountyArmed and CurrentTarget then
                state, status = "Hunting", "Chasing " .. CurrentTarget.Name
            elseif AutoBountyArmed then
                state, status = "Hunting", "Searching for targets"
            end
            local targetName, hp, distance, angle
            if CurrentTarget and CurrentTargetRoot then
                targetName = CurrentTarget.Name
                local hum = CurrentTarget.Character and CurrentTarget.Character:FindFirstChildOfClass("Humanoid")
                if hum and hum.MaxHealth > 0 then hp = hum.Health / hum.MaxHealth end
                local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if myRoot then
                    local delta = CurrentTargetRoot.Position - myRoot.Position
                    distance = delta.Magnitude
                    angle = math.atan2(delta.Z, delta.X)
                end
            end
            pcall(ui.SetStatus, state, status)
            pcall(ui.SetTarget, targetName, hp, distance, angle)
            if type(HUD.GetStats) == "function" then
                pcall(ui.SetStats, HUD.GetStats())
            end

            if os.clock() - lastRosterUpdate >= 0.5 then
                lastRosterUpdate = os.clock()
                local roster = {}
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer then
                        local inRaid = IsPlayerInRaid(player)
                        local eligible, reason = EvaluateTarget(player)
                        local temporarilySkipped = TempSkipUntil[player] and os.clock() < TempSkipUntil[player]
                        local lockedOut = LockGuard.IsLockedOut(player)
                        if inRaid then
                            eligible, reason = false, "IN RAID"
                        elseif temporarilySkipped then
                            eligible, reason = false, "TEMP SKIP"
                        elseif lockedOut then
                            eligible, reason = false, "LOCKED OUT"
                        end
                        roster[#roster + 1] = {
                            UserId = player.UserId,
                            Name = player.Name,
                            DisplayName = player.DisplayName,
                            InRaid = inRaid,
                            IsTarget = player == CurrentTarget,
                            Eligible = eligible,
                            Reason = eligible and "ELIGIBLE" or tostring(reason or "SKIPPED"),
                        }
                    end
                end
                table.sort(roster, function(a, b)
                    if a.IsTarget ~= b.IsTarget then return a.IsTarget end
                    if a.InRaid ~= b.InRaid then return a.InRaid end
                    return string.lower(a.Name) < string.lower(b.Name)
                end)
                pcall(ui.SetPlayers, roster)
            end
        end
    end
end)

-- The UI source is compiled as its own chunk to avoid sharing the backend's locals.
pcall(function()
    -- Load persisted settings before controls initialize, so UI defaults cannot overwrite them.
    local configDeadline = tick() + 15
    while ConfigLoading and tick() < configDeadline do task.wait(0.05) end
    local uiEnv = getgenv and getgenv()
    if type(uiEnv) == "table" then uiEnv.MercifulUIInitializing = true end
    local uiChunk = loadstring([====[
--[==[
    MERCIFUL AUTO BOUNTY  -  UI only  (Bhalu Hub layout)
    Made by Merciful
    Left Ctrl toggles the menu.

    WIRING (optional - works standalone with demo values):

        getgenv().MercifulBridge = {
            Get     = function(flag) ... end,
            Set     = function(flag, value) ... end,
            Action  = function(name) ... end,   -- "ManualHop" "SaveConfig" "LoadConfig" "ExportConfig" "DeleteConfig"
            Close   = function() ... end,       -- optional
        }
        local UI = loadstring(...)()

        UI.SetStatus("Hunting", "Chasing PlayerName")  -- Idle | Hunting | Fleeing | Hopping | Risk
        UI.SetTarget("PlayerName", 0.62, 143, angleRadians)   -- name, hp 0..1, studs, (optional) radar angle. UI.SetTarget(nil) clears
        UI.SetStats({Bounty=, Earned=, Runtime=, Stay=, StayLimit=, Players=})   -- all optional
        UI.Notify("Server hopping...", 3)
        UI.SetLocked("Dragonstorm", true) / UI.SetTitle(flag, text) / UI.SetOpen(bool)

    HOW THE RJR BACKEND PLUGS IN (Settings table -> flags, almost 1:1):

        local function holdKey(flag)  -- "MeleeHoldZ" -> tip, key
            local p, k = flag:match("^(%a+)Hold(%a)$")
            return ({Melee="Melee", Sword="Sword", Fruit="Blox Fruit", Gun="Gun"})[p], k
        end
        getgenv().MercifulBridge = {
            Get = function(f)
                if f == "LockTimeBounty" then return Settings.LockTime end
                local p = f:match("^(%a+)V4Only$")
                if p then return Settings.V4Only[({Melee="Melee",Sword="Sword",Fruit="Blox Fruit",Gun="Gun"})[p]] end
                local tip, key = holdKey(f); if tip then return Settings.Hold[tip][key] end
                return Settings[f]
            end,
            Set = function(f, v)
                -- mirror of Get: write into Settings, then call ApplyPlayerRange / ApplyBountyRange /
                -- ApplyTeam / Stay.Performance:SetEnabled / RJR:ApplyWaterWalk where the old callbacks did
            end,
            Action = function(n)
                if n == "ManualHop" then DeathHopRequested = true; HopPhase = "idle"; ServerHopCache.List = nil; SafeCall(DoServerHop)
                elseif n == "SaveConfig" then SaveConfig(false)
                elseif n == "LoadConfig" then LoadConfig(false)
                elseif n == "ExportConfig" then ConfigExport.CopyToClipboard(ConfigExport.Text(Settings))
                elseif n == "DeleteConfig" then pcall(delfile, CONFIG_FILE) end
            end,
        }

    Flags: AutoBounty LockAtReward RewardLockTarget SelectTeam HoldWeapon LockTimeBounty
           FastAttack FruitM1 Dragonstorm VoidFruitM1 AutoEnablePVP AutoHaki AutoKen AutoV3 AutoSoru AutoFlee AutoFleeHP
           MeleeSkills SwordSkills FruitSkills GunSkills (arrays of "Z".."F"), <Melee|Sword|Fruit|Gun>V4Only, <Prefix>Hold<Key>
           ServerRegion HopPlayerRange HopBountyRange ("> 3M" ...) MaxStaySeconds
           ESP ESP_ShowName ESP_ShowLevel ESP_ShowHealth ESP_ShowDistance ESP_ShowPVP ESP_FontSize WaterWalk FPSBoost
           AutoSaveConfig AutoLoadConfig Theme UI_Island UI_IslandAuto UI_Anim UI_Orb
]==]

local TweenService     = game:GetService("TweenService")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")
local StatsService     = game:GetService("Stats")
local TextService      = game:GetService("TextService")

local genv = (getgenv and getgenv()) or _G
if genv.MercifulUI then pcall(function() genv.MercifulUI.Destroy() end) end
local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------
-- BRIDGE
----------------------------------------------------------------------
local demo = {}
local bridge = genv.MercifulBridge
local api = {
    Get    = (bridge and bridge.Get) or function(f) return demo[f] end,
    Set    = (bridge and bridge.Set) or function(f, v) demo[f] = v end,
    Action = bridge and bridge.Action,
    Close  = bridge and bridge.Close,
}
local function Get(f) local ok, v = pcall(api.Get, f); if ok then return v end return nil end
local function Set(f, v) pcall(api.Set, f, v) end

----------------------------------------------------------------------
-- THEMES
----------------------------------------------------------------------
local H = Color3.fromHex
local THEMES = {
    {name = "Abyss",      A = H"22d3ee", B = H"3b82f6", bg = H"050d1a", panel = H"0b1a2e", elem = H"11263f", stroke = H"1d4268"},
    {name = "Neon Crypt", A = H"ff3afd", B = H"008eff", bg = H"0b0814", panel = H"150f26", elem = H"1f1638", stroke = H"3a2a66"},
    {name = "Ember",      A = H"ff5a36", B = H"ffb020", bg = H"140803", panel = H"24110a", elem = H"331a0f", stroke = H"5c2f18"},
    {name = "Blood Moon", A = H"ff2b4a", B = H"b0176e", bg = H"13040a", panel = H"220811", elem = H"310c19", stroke = H"561429"},
    {name = "Emerald",    A = H"34d399", B = H"a3e635", bg = H"04120b", panel = H"0a2014", elem = H"102e1d", stroke = H"1b5232"},
    {name = "Sakura",     A = H"ffa6d0", B = H"c084fc", bg = H"150a14", panel = H"26122a", elem = H"361a3c", stroke = H"5d2f66"},
    {name = "Ultraviolet",A = H"b794ff", B = H"ff6fd8", bg = H"160a33", panel = H"24124f", elem = H"331a70", stroke = H"6238b8"},
    {name = "Aurora",     A = H"5eead4", B = H"818cf8", bg = H"071a1f", panel = H"0c2a31", elem = H"123c46", stroke = H"1f6773"},
}

local T = {text = H"f1eefc", sub = H"8f8aae"}
local function loadTheme(name)
    local pick = THEMES[1]
    for _, t in ipairs(THEMES) do if t.name == name then pick = t end end
    for k, v in pairs(pick) do T[k] = v end
    return pick
end
loadTheme(Get("Theme"))

----------------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------------
local reg, grads, repaints, conns = {}, {}, {}, {}
local WHITE = Color3.new(1, 1, 1)
local animOn = true
local Q, BACK, SINE = Enum.EasingStyle.Quint, Enum.EasingStyle.Back, Enum.EasingStyle.Sine
local OUT = Enum.EasingDirection.Out

local function C(sig, fn) local c = sig:Connect(fn); conns[#conns + 1] = c; return c end
local function New(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    o.Parent = parent
    return o
end
local function R(inst, prop, role) inst[prop] = T[role]; reg[#reg + 1] = {inst, prop, role} end
local function Grad(parent, rot)
    local g = New("UIGradient", {Color = ColorSequence.new(T.A, T.B), Rotation = rot or 0}, parent)
    grads[#grads + 1] = g
    return g
end
local function Corner(p, r) return New("UICorner", {CornerRadius = UDim.new(0, r)}, p) end
local function Pad(p, t, r, b, l)
    return New("UIPadding", {PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r or t),
        PaddingBottom = UDim.new(0, b or t), PaddingLeft = UDim.new(0, l or r or t)}, p)
end
local function List(p, gap, dir)
    return New("UIListLayout", {Padding = UDim.new(0, gap or 0), SortOrder = Enum.SortOrder.LayoutOrder,
        FillDirection = dir or Enum.FillDirection.Vertical}, p)
end
local function Stroke(p, role, th, tr)
    local s = New("UIStroke", {Thickness = th or 1, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, p)
    if role then R(s, "Color", role) else s.Color = WHITE end
    return s
end
-- every animation goes through here; "Animations" off => instant (max fps)
local function Tw(o, props, t, style, dir)
    if not animOn or t == 0 then
        for k, v in pairs(props) do o[k] = v end
        return nil
    end
    local tw = TweenService:Create(o, TweenInfo.new(t or 0.18, style or Q, dir or OUT), props)
    tw:Play()
    return tw
end
local function Text(parent, txt, size, role, font, props)
    local l = New("TextLabel", {BackgroundTransparency = 1, Text = txt, TextSize = size or 13, Font = font or Enum.Font.GothamMedium,
        TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = false}, parent)
    R(l, "TextColor3", role or "text")
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end
-- unthemed label (island + state colours)
local function IText(parent, txt, size, col, font, props)
    local l = New("TextLabel", {BackgroundTransparency = 1, Text = txt, TextSize = size, Font = font or Enum.Font.GothamMedium,
        TextColor3 = col, TextXAlignment = Enum.TextXAlignment.Left}, parent)
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end
local function fmtNum(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. out
end
local function fmtCompact(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if a >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if a >= 1e4 then return string.format("%.1fK", n / 1e3) end
    return fmtNum(n)
end
local function fmtTime(s)
    s = math.max(math.floor(tonumber(s) or 0), 0)
    return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end
local orders = setmetatable({}, {__mode = "k"})
local function nextOrder(p) orders[p] = (orders[p] or 0) + 1; return orders[p] end

local STATE_COL = {
    Idle    = Color3.fromRGB(122, 122, 140),
    Hunting = Color3.fromRGB(74, 222, 128),
    Fleeing = Color3.fromRGB(251, 191, 36),
    Hopping = Color3.fromRGB(56, 189, 248),
    Risk    = Color3.fromRGB(244, 63, 94),
}

local UI = {Elements = {}}
local startMinimized = genv.AutoBountyMinimizeOnResume == true
if startMinimized then genv.AutoBountyMinimizeOnResume = nil end
local isOpen, openToken, orbWanted = not startMinimized, 0, true

----------------------------------------------------------------------
-- ROOT + WINDOW
----------------------------------------------------------------------
local Gui = New("ScreenGui", {Name = "MercifulAutoBounty", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999})
do
    local ok = pcall(function() Gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
    if not ok or not Gui.Parent then Gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end
end

local WIDTH, HEIGHT = 760, 520
local Main = New("CanvasGroup", {Name = "Main", Size = UDim2.fromOffset(WIDTH, HEIGHT), AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.56, 0), BorderSizePixel = 0, GroupTransparency = 1, Visible = isOpen}, Gui)
R(Main, "BackgroundColor3", "bg"); Corner(Main, 16)
local MainStrokeGrad = Grad(Stroke(Main, nil, 1.5, 0.05), 0)
local Scale = New("UIScale", {Scale = 0.92}, Main)
local baseScale = 1
local function fit()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    baseScale = math.clamp(math.min(vp.X / (WIDTH + 40), vp.Y / (HEIGHT + 120), 1), 0.4, 1)
end
fit()
if workspace.CurrentCamera then
    C(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), function() fit(); if isOpen then Scale.Scale = baseScale end end)
end

local Glow = New("Frame", {Size = UDim2.new(1, 0, 0, 190), BackgroundColor3 = WHITE, BackgroundTransparency = 0.8, BorderSizePixel = 0}, Main)
Grad(Glow, 90).Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)})

----------------------------------------------------------------------
-- HEADER: crest, title, segmented page switch, window buttons
----------------------------------------------------------------------
local Head = New("Frame", {Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1}, Main)
local Crest = New("Frame", {Size = UDim2.fromOffset(36, 36), Position = UDim2.fromOffset(16, 11), BackgroundColor3 = WHITE, BorderSizePixel = 0}, Head)
Corner(Crest, 11); Grad(Crest, 45)
New("TextLabel", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "M", Font = Enum.Font.GothamBlack, TextSize = 21, TextColor3 = WHITE}, Crest)
local Title = New("TextLabel", {BackgroundTransparency = 1, Text = "MERCIFUL AUTO BOUNTY", Font = Enum.Font.GothamBlack, TextSize = 16, TextColor3 = WHITE,
    TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(62, 10), Size = UDim2.fromOffset(250, 20)}, Head)
Grad(Title, 0)
Text(Head, "Made by Merciful", 11, "sub", Enum.Font.GothamMedium, {Position = UDim2.fromOffset(62, 31), Size = UDim2.fromOffset(250, 14)})

local PAGE_NAMES = {"BOUNTY", "SKILLS", "SERVER", "SYSTEM"}
local Seg = New("Frame", {Size = UDim2.fromOffset(#PAGE_NAMES * 72 + 4, 32), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.6, 0, 0.5, 0), BorderSizePixel = 0}, Head)
R(Seg, "BackgroundColor3", "panel"); Corner(Seg, 16); Stroke(Seg, "stroke", 1, 0.3)
local SegPill = New("Frame", {Size = UDim2.new(1 / #PAGE_NAMES, -3, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = WHITE, BorderSizePixel = 0}, Seg)
Corner(SegPill, 14); Grad(SegPill, 0)
local segBtns = {}

local function HeadBtn(txt, x, hoverCol)
    local b = New("TextButton", {Text = txt, Font = Enum.Font.GothamBold, TextSize = 15, AutoButtonColor = false, BackgroundTransparency = 0,
        Size = UDim2.fromOffset(28, 28), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0)}, Head)
    R(b, "BackgroundColor3", "panel"); R(b, "TextColor3", "sub"); Corner(b, 9)
    C(b.MouseEnter, function() Tw(b, {TextColor3 = hoverCol or WHITE}, 0.15) end)
    C(b.MouseLeave, function() Tw(b, {TextColor3 = T.sub}, 0.2) end)
    return b
end
local CloseBtn, MinBtn = HeadBtn("×", -14, Color3.fromRGB(244, 63, 94)), HeadBtn("–", -48)

do
    local drag, start, orig, moveC
    C(Head.InputBegan, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            drag, start, orig = true, i.Position, Main.Position
            moveC = UserInputService.InputChanged:Connect(function(m)
                if drag and (m.UserInputType == Enum.UserInputType.MouseMovement or m.UserInputType == Enum.UserInputType.Touch) then
                    local d = (m.Position - start) / Scale.Scale
                    Main.Position = UDim2.new(orig.X.Scale, orig.X.Offset + d.X, orig.Y.Scale, orig.Y.Offset + d.Y)
                end
            end)
        end
    end)
    C(UserInputService.InputEnded, function(i)
        if drag and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            drag = false
            if moveC then moveC:Disconnect(); moveC = nil end
        end
    end)
end

----------------------------------------------------------------------
-- PAGES
----------------------------------------------------------------------
local Body = New("Frame", {BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 66), Size = UDim2.new(1, -28, 1, -80), ClipsDescendants = true}, Main)
local pages = {}
for i = 1, #PAGE_NAMES do
    pages[i] = New("CanvasGroup", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, GroupTransparency = 1}, Body)
end
local currentPage = 0
local function paintSeg()
    for k, b in ipairs(segBtns) do b.TextColor3 = (k == currentPage) and WHITE or T.sub end
end
repaints[#repaints + 1] = paintSeg
local function showPage(i, instant)
    if i == currentPage then return end
    local prev = currentPage
    currentPage = i
    Tw(SegPill, {Position = UDim2.new((i - 1) / #PAGE_NAMES, 2, 0, 2)}, instant and 0 or 0.4, BACK)
    for k, b in ipairs(segBtns) do Tw(b, {TextColor3 = (k == i) and WHITE or T.sub}, 0.2) end
    if prev > 0 then pages[prev].Visible = false end
    local pg = pages[i]
    pg.GroupTransparency = 1
    pg.Position = UDim2.fromOffset(0, 12)
    pg.Visible = true
    Tw(pg, {GroupTransparency = 0, Position = UDim2.fromOffset(0, 0)}, instant and 0 or 0.35)
end
for i, n in ipairs(PAGE_NAMES) do
    local b = New("TextButton", {Text = n, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false, BackgroundTransparency = 1,
        Size = UDim2.new(1 / #PAGE_NAMES, 0, 1, 0), Position = UDim2.fromScale((i - 1) / #PAGE_NAMES, 0), TextColor3 = T.sub}, Seg)
    segBtns[i] = b
    C(b.MouseEnter, function() if currentPage ~= i then Tw(b, {TextColor3 = T.text}, 0.15) end end)
    C(b.MouseLeave, function() if currentPage ~= i then Tw(b, {TextColor3 = T.sub}, 0.2) end end)
    C(b.MouseButton1Click, function() showPage(i) end)
end

local function Column(page, side, top)
    top = top or 0
    local c = New("ScrollingFrame", {BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2,
        Size = UDim2.new(0.5, -5, 1, -top), Position = UDim2.new(side, 0, 0, top), AnchorPoint = Vector2.new(side, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new()}, page)
    R(c, "ScrollBarImageColor3", "A")
    Pad(c, 0, 4, 8, 0); List(c, 10)
    return c
end

----------------------------------------------------------------------
-- ELEMENTS
----------------------------------------------------------------------
local function Elements(parent)
    local E = {}

    local function rowHover(r)
        C(r.MouseEnter, function() Tw(r, {BackgroundColor3 = T.stroke}, 0.15) end)
        C(r.MouseLeave, function() Tw(r, {BackgroundColor3 = T.elem}, 0.25) end)
    end

    function E.Toggle(flag, title, desc)
        local locked, value = false, Get(flag) and true or false
        local r = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, desc and 46 or 36),
            BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 9)
        local st = Stroke(r, "A", 1, 1)
        local t = Text(r, title, 13, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, desc and 6 or 0),
            Size = UDim2.new(1, -72, 0, desc and 17 or 36), TextTruncate = Enum.TextTruncate.AtEnd})
        if desc then Text(r, desc, 11, "sub", Enum.Font.Gotham, {Position = UDim2.fromOffset(12, 24), Size = UDim2.new(1, -72, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd}) end
        local sw = New("Frame", {Size = UDim2.fromOffset(38, 20), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), BorderSizePixel = 0}, r)
        R(sw, "BackgroundColor3", "stroke"); Corner(sw, 10)
        local fill = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0}, sw)
        Corner(fill, 10); Grad(fill, 0)
        local knob = New("Frame", {Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = WHITE, BorderSizePixel = 0}, sw)
        Corner(knob, 7)
        local o = {}
        local function paint(anim)
            local on = value and not locked
            Tw(fill, {BackgroundTransparency = on and 0 or 1}, anim and 0.2 or 0)
            Tw(knob, {Position = value and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(14, 14)}, anim and 0.32 or 0, BACK)
            Tw(st, {Transparency = on and 0.5 or 1}, anim and 0.25 or 0)
            t.TextTransparency = locked and 0.55 or 0
            sw.BackgroundTransparency = locked and 0.5 or 0
        end
        function o.Set(v) value = v and true or false; paint(true) end
        function o.SetLocked(b) locked = b; if b and value then value = false; Set(flag, false) end; paint(true) end
        function o.SetTitle(x) t.Text = x end
        rowHover(r)
        C(r.MouseButton1Down, function() if not locked then Tw(knob, {Size = UDim2.fromOffset(18, 14)}, 0.1) end end)
        C(r.MouseLeave, function() Tw(knob, {Size = UDim2.fromOffset(14, 14)}, 0.15) end)
        C(r.MouseButton1Click, function()
            if locked then return end
            value = not value; paint(true); Set(flag, value)
        end)
        paint(false)
        UI.Elements[flag] = o
        return o
    end

    -- big featured toggle
    function E.Hero(flag, title, desc)
        local value = Get(flag) and true or false
        local r = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 64), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 14)
        local st = Stroke(r, "A", 1.5, 1)
        local glow = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0}, r)
        Corner(glow, 14); Grad(glow, 20)
        Text(r, title, 16, "text", Enum.Font.GothamBlack, {Position = UDim2.fromOffset(18, 12), Size = UDim2.new(1, -90, 0, 20)})
        Text(r, desc, 11, "sub", Enum.Font.Gotham, {Position = UDim2.fromOffset(18, 35), Size = UDim2.new(1, -90, 0, 16)})
        local sw = New("Frame", {Size = UDim2.fromOffset(48, 26), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0), BorderSizePixel = 0}, r)
        R(sw, "BackgroundColor3", "stroke"); Corner(sw, 13)
        local fill = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0}, sw)
        Corner(fill, 13); Grad(fill, 0)
        local knob = New("Frame", {Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = WHITE, BorderSizePixel = 0}, sw)
        Corner(knob, 10)
        local o = {}
        local function paint(anim)
            Tw(fill, {BackgroundTransparency = value and 0 or 1}, anim and 0.2 or 0)
            Tw(glow, {BackgroundTransparency = value and 0.84 or 1}, anim and 0.4 or 0)
            Tw(st, {Transparency = value and 0.3 or 1}, anim and 0.4 or 0)
            Tw(knob, {Position = value and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)}, anim and 0.38 or 0, BACK)
        end
        function o.Set(v) value = v and true or false; paint(true) end
        C(r.MouseEnter, function() if not value then Tw(r, {BackgroundColor3 = T.stroke}, 0.15) end end)
        C(r.MouseLeave, function() Tw(r, {BackgroundColor3 = T.elem}, 0.25) end)
        C(r.MouseButton1Click, function() value = not value; paint(true); Set(flag, value) end)
        paint(false)
        UI.Elements[flag] = o
        return o
    end

    function E.Slider(flag, title, min, max, step)
        local locked = false
        local value = tonumber(Get(flag)) or min
        local r = New("Frame", {Size = UDim2.new(1, 0, 0, 48), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 9)
        local t = Text(r, title, 13, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -80, 0, 16)})
        local v = Text(r, "", 12, "A", Enum.Font.GothamBold, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 6),
            Size = UDim2.fromOffset(64, 16), TextXAlignment = Enum.TextXAlignment.Right})
        local track = New("Frame", {Position = UDim2.new(0, 12, 0, 32), Size = UDim2.new(1, -24, 0, 5), BorderSizePixel = 0}, r)
        R(track, "BackgroundColor3", "stroke"); Corner(track, 3)
        local fill = New("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0}, track)
        Corner(fill, 3); Grad(fill, 0)
        local knob = New("Frame", {Size = UDim2.fromOffset(13, 13), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = WHITE, BorderSizePixel = 0}, track)
        Corner(knob, 7)
        local o = {}
        local function render()
            local p = (max > min) and (value - min) / (max - min) or 0
            fill.Size = UDim2.fromScale(p, 1); knob.Position = UDim2.fromScale(p, 0.5)
            v.Text = string.format("%g", math.floor(value * 100 + 0.5) / 100)
        end
        local function setv(x, fire)
            x = math.clamp(x, min, max)
            if step and step > 0 then x = math.floor(x / step + 0.5) * step end
            x = math.clamp(math.floor(x * 1000 + 0.5) / 1000, min, max)
            value = x; render()
            if fire then Set(flag, x) end
        end
        local dragging, hovering, moveC = false, false, nil
        local function knobTo(big) Tw(knob, {Size = big and UDim2.fromOffset(18, 18) or UDim2.fromOffset(13, 13)}, 0.2, BACK) end
        local function fromX(x)
            local w = track.AbsoluteSize.X
            if w > 0 and not locked then setv(min + (max - min) * math.clamp((x - track.AbsolutePosition.X) / w, 0, 1), true) end
        end
        C(r.MouseEnter, function() hovering = true; if not locked then Tw(r, {BackgroundColor3 = T.stroke}, 0.15) end end)
        C(r.MouseLeave, function() hovering = false; if not dragging then Tw(r, {BackgroundColor3 = T.elem}, 0.25) end end)
        C(r.InputBegan, function(i)
            if locked then return end
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging = true; fromX(i.Position.X); knobTo(true)
                moveC = UserInputService.InputChanged:Connect(function(m)
                    if dragging and (m.UserInputType == Enum.UserInputType.MouseMovement or m.UserInputType == Enum.UserInputType.Touch) then fromX(m.Position.X) end
                end)
            end
        end)
        C(UserInputService.InputEnded, function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
                dragging = false; knobTo(false)
                if not hovering then Tw(r, {BackgroundColor3 = T.elem}, 0.25) end
                if moveC then moveC:Disconnect(); moveC = nil end
            end
        end)
        function o.Set(x) setv(tonumber(x) or min, false) end
        function o.SetMin(m) min = m; setv(value, true) end
        function o.SetTitle(x) t.Text = x end
        function o.SetLocked(b) locked = b; t.TextTransparency = b and 0.55 or 0; track.BackgroundTransparency = b and 0.6 or 0 end
        render()
        UI.Elements[flag] = o
        return o
    end

    function E.NumberInput(flag, title, min, max)
        local value = math.clamp(math.floor(tonumber(Get(flag)) or min), min, max)
        local r = New("Frame", {Size = UDim2.new(1, 0, 0, 40), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 9); Stroke(r, "stroke", 1, 0.3)
        Text(r, title, 12, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -100, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd})
        local box = New("TextBox", {Text = tostring(value), ClearTextOnFocus = false, Font = Enum.Font.GothamBold, TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Center, TextEditable = Get("BypassTweenSpeed") ~= true,
            Size = UDim2.fromOffset(72, 26), AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -8, 0.5, 0), BorderSizePixel = 0}, r)
        R(box, "BackgroundColor3", "bg"); R(box, "TextColor3", "A"); Corner(box, 7); Stroke(box, "stroke", 1, 0.25)
        local o = {}
        local function commit()
            if Get("BypassTweenSpeed") == true then box.Text = tostring(value); return end
            local n = tonumber(box.Text)
            if not n then box.Text = tostring(value); return end
            value = math.clamp(math.floor(n + 0.5), min, max)
            box.Text = tostring(value)
            Set(flag, value)
        end
        box.FocusLost:Connect(commit)
        function o.Set(v)
            value = math.clamp(math.floor(tonumber(v) or min), min, max)
            box.Text = tostring(value)
        end
        function o.SetLocked(locked)
            box.TextEditable = not locked
            box.TextTransparency = locked and 0.5 or 0
        end
        UI.Elements[flag] = o
        return o
    end

    function E.TextInput(flag, title, placeholder)
        local function display(v)
            if type(v) ~= "table" then return tostring(v or "") end
            local parts = {}
            for _, entry in ipairs(v) do
                local weapon, key = tostring(entry):match("^(.-):([%a])$")
                parts[#parts + 1] = weapon and (weapon .. " " .. string.upper(key)) or tostring(entry)
            end
            return table.concat(parts, ", ")
        end
        local r = New("Frame", {Size = UDim2.new(1, 0, 0, 76), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 9); Stroke(r, "stroke", 1, 0.3)
        Text(r, title, 12, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -24, 0, 16)})
        local box = New("TextBox", {Text = display(Get(flag)), PlaceholderText = placeholder or "", ClearTextOnFocus = false,
            MultiLine = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Font = Enum.Font.Gotham,
            TextSize = 11, Size = UDim2.new(1, -20, 0, 44), Position = UDim2.fromOffset(10, 26), BorderSizePixel = 0}, r)
        R(box, "BackgroundColor3", "bg"); R(box, "TextColor3", "text"); Corner(box, 7); Stroke(box, "stroke", 1, 0.4)
        box.PlaceholderColor3 = T.sub
        local o = {}
        box.FocusLost:Connect(function()
            Set(flag, box.Text)
            box.Text = display(Get(flag))
        end)
        function o.Set(v) box.Text = display(v) end
        UI.Elements[flag] = o
        return o
    end

    function E.Dropdown(flag, title, values)
        local cur = Get(flag) or values[1]
        local ROW, ITEM = 38, 28
        local wrap = New("Frame", {Size = UDim2.new(1, 0, 0, ROW), BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = nextOrder(parent)}, parent)
        R(wrap, "BackgroundColor3", "elem"); Corner(wrap, 9)
        local head = New("TextButton", {Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW)}, wrap)
        Text(head, title, 13, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.5, -12, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd})
        local val = Text(head, tostring(cur), 12, "A", Enum.Font.GothamBold, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -30, 0, 0),
            Size = UDim2.new(0.5, -36, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd})
        local chev = Text(head, "›", 18, "sub", Enum.Font.GothamBold, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -16, 0.5, -1),
            Size = UDim2.fromOffset(16, 16), TextXAlignment = Enum.TextXAlignment.Center})
        local list = New("Frame", {BackgroundTransparency = 1, Position = UDim2.fromOffset(0, ROW), Size = UDim2.new(1, 0, 0, 0)}, wrap)
        local items, count, open, o = {}, 0, false, {}
        local function paint()
            for name, it in pairs(items) do
                local on = name == cur
                it.l.TextColor3 = on and T.A or T.sub
                it.l.Font = on and Enum.Font.GothamBold or Enum.Font.GothamMedium
            end
        end
        local function resize()
            Tw(wrap, {Size = UDim2.new(1, 0, 0, open and (ROW + count * ITEM + 6) or ROW)}, 0.32)
        end
        local function build(vals)
            for _, it in pairs(items) do it.bg:Destroy() end
            items, count = {}, #vals
            for i, name in ipairs(vals) do
                local bg = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.new(1, -12, 0, ITEM), Position = UDim2.fromOffset(6, (i - 1) * ITEM),
                    BackgroundTransparency = 1, BorderSizePixel = 0}, list)
                R(bg, "BackgroundColor3", "stroke"); Corner(bg, 7)
                local l = Text(bg, tostring(name), 12, "sub", Enum.Font.GothamMedium, {Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -14, 1, 0)})
                items[name] = {bg = bg, l = l}
                bg.MouseEnter:Connect(function() Tw(bg, {BackgroundTransparency = 0.6}, 0.12) end)
                bg.MouseLeave:Connect(function() Tw(bg, {BackgroundTransparency = 1}, 0.2) end)
                bg.MouseButton1Click:Connect(function()
                    cur = name; val.Text = tostring(name); paint(); Set(flag, name)
                    open = false; resize(); Tw(chev, {Rotation = 0}, 0.25); Tw(wrap, {BackgroundColor3 = T.elem}, 0.25)
                end)
            end
            paint(); if open then resize() end
        end
        build(values)
        repaints[#repaints + 1] = paint
        C(head.MouseEnter, function() if not open then Tw(wrap, {BackgroundColor3 = T.stroke}, 0.15) end end)
        C(head.MouseLeave, function() if not open then Tw(wrap, {BackgroundColor3 = T.elem}, 0.25) end end)
        C(head.MouseButton1Click, function()
            open = not open; resize()
            Tw(chev, {Rotation = open and 90 or 0}, 0.28, BACK)
        end)
        function o.Set(x) cur = x; val.Text = tostring(x); paint() end
        function o.SetValues(vals) build(vals) end
        UI.Elements[flag] = o
        return o
    end

    function E.Chips(flag, title, keys)
        local sel = {}
        local function load(v)
            sel = {}
            if type(v) == "table" then
                for k, x in pairs(v) do
                    if type(k) == "number" and type(x) == "string" then sel[x] = true
                    elseif x == true then sel[k] = true end
                end
            end
        end
        load(Get(flag))
        local r = New("Frame", {Size = UDim2.new(1, 0, 0, 38), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 9)
        Text(r, title, 13, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.3, 0, 1, 0)})
        local holder = New("Frame", {BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.new(0.7, 0, 0, 24)}, r)
        New("UIListLayout", {Padding = UDim.new(0, 5), FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
            VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder}, holder)
        local chips = {}
        local function emit()
            local out = {}
            for _, k in ipairs(keys) do if sel[k] then out[#out + 1] = k end end
            Set(flag, out)
        end
        for i, k in ipairs(keys) do
            local b = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(28, 24), LayoutOrder = i, BorderSizePixel = 0}, holder)
            R(b, "BackgroundColor3", "stroke"); Corner(b, 12)
            local fill = New("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0}, b)
            Corner(fill, 12); Grad(fill, 30)
            local lbl = New("TextLabel", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = k, Font = Enum.Font.GothamBold, TextSize = 11, ZIndex = 2}, b)
            R(lbl, "TextColor3", "sub")
            chips[k] = {fill = fill, lbl = lbl}
            C(b.MouseButton1Click, function()
                sel[k] = not sel[k] or nil
                Tw(fill, {BackgroundTransparency = sel[k] and 0 or 1}, 0.2)
                Tw(lbl, {TextColor3 = sel[k] and WHITE or T.sub}, 0.2)
                Tw(b, {Size = UDim2.fromOffset(28, 24)}, 0.25, BACK)
                emit()
            end)
            C(b.MouseButton1Down, function() Tw(b, {Size = UDim2.fromOffset(23, 21)}, 0.08) end)
        end
        local function paint()
            for k, c in pairs(chips) do
                c.fill.BackgroundTransparency = sel[k] and 0 or 1
                c.lbl.TextColor3 = sel[k] and WHITE or T.sub
            end
        end
        repaints[#repaints + 1] = paint
        paint()
        local o = {}
        function o.Set(v) load(v); paint() end
        UI.Elements[flag] = o
        return o
    end

    function E.Button(action, title, primary)
        local r = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        if primary then
            r.BackgroundColor3 = WHITE; Corner(r, 9); Grad(r, 0)
            New("TextLabel", {BackgroundTransparency = 1, Text = title, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = WHITE, Size = UDim2.fromScale(1, 1)}, r)
            C(r.MouseEnter, function() Tw(r, {BackgroundTransparency = 0.12}, 0.15) end)
            C(r.MouseLeave, function() Tw(r, {BackgroundTransparency = 0}, 0.2) end)
        else
            R(r, "BackgroundColor3", "elem"); Corner(r, 9)
            Text(r, title, 13, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -40, 1, 0)})
            Text(r, "›", 18, "sub", Enum.Font.GothamBold, {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, -1), Size = UDim2.fromOffset(16, 16), TextXAlignment = Enum.TextXAlignment.Center})
            rowHover(r)
        end
        C(r.MouseButton1Down, function() Tw(r, {Size = UDim2.new(1, -8, 0, 33)}, 0.08) end)
        C(r.MouseLeave, function() Tw(r, {Size = UDim2.new(1, 0, 0, 36)}, 0.2) end)
        C(r.MouseButton1Click, function()
            Tw(r, {Size = UDim2.new(1, 0, 0, 36)}, 0.3, BACK)
            if api.Action then pcall(api.Action, action) else Set(action, true) end
            if UI.Notify then UI.Notify(title, 1.8) end
        end)
    end

    function E.Copy(title, value, shown)
        shown = shown or tostring(value)
        local r = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), BorderSizePixel = 0, LayoutOrder = nextOrder(parent)}, parent)
        R(r, "BackgroundColor3", "elem"); Corner(r, 9); rowHover(r)
        Text(r, title, 13, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.45, 0, 1, 0)})
        local v = Text(r, shown, 11, "sub", Enum.Font.Gotham, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0),
            Size = UDim2.new(0.55, -12, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd})
        local busy = false
        C(r.MouseButton1Click, function()
            pcall(function() (setclipboard or toclipboard)(tostring(value)) end)
            if busy then return end
            busy = true; v.Text = "Copied ✓"; Tw(v, {TextColor3 = T.A}, 0.15)
            task.delay(1.2, function() v.Text = shown; Tw(v, {TextColor3 = T.sub}, 0.3); busy = false end)
        end)
    end

    return E
end

local function Card(col, title)
    local f = New("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, LayoutOrder = nextOrder(col)}, col)
    R(f, "BackgroundColor3", "panel"); Corner(f, 12); Stroke(f, "stroke", 1, 0.25)
    Pad(f, 10, 10, 10, 10); List(f, 6)
    local h = New("Frame", {Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = 0}, f)
    local bar = New("Frame", {Size = UDim2.fromOffset(3, 12), Position = UDim2.fromOffset(0, 3), BorderSizePixel = 0, BackgroundColor3 = WHITE}, h)
    Corner(bar, 2); Grad(bar, 90)
    local l = New("TextLabel", {BackgroundTransparency = 1, Text = string.upper(title), TextSize = 11, Font = Enum.Font.GothamBlack, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -10, 1, 0)}, h)
    Grad(l, 0)
    return Elements(f), f
end

----------------------------------------------------------------------
-- PAGE 1: BOUNTY
----------------------------------------------------------------------
local P1L, P1R = Column(pages[1], 0), Column(pages[1], 1)

local liveE, liveCard = Card(P1L, "Live")
local liveBox = New("Frame", {Size = UDim2.new(1, 0, 0, 90), BackgroundTransparency = 1, LayoutOrder = nextOrder(liveCard)}, liveCard)
local liveState  = IText(liveBox, "IDLE", 11, STATE_COL.Idle, Enum.Font.GothamBlack, {Position = UDim2.fromOffset(2, 0), Size = UDim2.new(1, 0, 0, 14)})
local liveStatus = Text(liveBox, "Idle", 15, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(2, 17), Size = UDim2.new(1, -4, 0, 20), TextTruncate = Enum.TextTruncate.AtEnd})
local liveBounty = Text(liveBox, "Bounty -", 12, "sub", Enum.Font.Gotham, {Position = UDim2.fromOffset(2, 42), Size = UDim2.new(1, -4, 0, 14)})
local liveEarn   = Text(liveBox, "", 12, "A", Enum.Font.GothamBold, {Position = UDim2.fromOffset(2, 57), Size = UDim2.new(1, -4, 0, 14)})
local liveTotal  = Text(liveBox, "", 11, "sub", Enum.Font.Gotham, {Position = UDim2.fromOffset(2, 74), Size = UDim2.new(1, -4, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd})

do
    local e = Card(P1L, "Hunt")
    e.Hero("AutoBounty", "Auto Bounty", "Hunts players and collects bounty")
    e.Toggle("LockAtReward", "Stop at target Bounty/Honor", "Kicks you once the target is reached")
    e.NumberInput("RewardLockTarget", "Target Bounty/Honor", 1, 999999999)
    e.NumberInput("CustomTweenSpeed", "Movement tween speed (max 220)", 50, 220)
    e.Dropdown("SelectTeam", "Team", {"Pirates", "Marines"})
    e.Dropdown("HoldWeapon", "Hold Weapon", {"Melee", "Sword", "Blox Fruit", "Gun"})
    e.Slider("LockTimeBounty", "Lock Player Time (s)", 30, 150, 1)

    local c = Card(P1R, "Attacks")
    c.Toggle("FastAttack", "Fast Attack")
    c.Toggle("FruitM1", "Fruit M1")
    c.Toggle("Dragonstorm", "Dragonstorm", "Needs the Dragonstorm gun")
    c.Toggle("VoidFruitM1", "Instant Kill")
    local g = Card(P1R, "Instant teleport")
    g.Toggle("GravityF", "Instant teleport", "Instant TP on far targets")
    g.Toggle("BypassTweenSpeed", "Bypass Tween Speed")

    local a = Card(P1R, "Assist")
    a.Toggle("AutoEnablePVP", "Auto Enable PvP")
    a.Toggle("AutoHaki", "Auto Buso")
    a.Toggle("AutoKen", "Auto Ken")
    a.Toggle("AutoV3", "Auto V3")
    a.Toggle("AutoV4", "Auto V4")
    a.Toggle("AutoSoru", "Auto Soru")

    local s = Card(P1R, "Survival")
    s.Toggle("AutoFlee", "Auto Flee", "Flies up when health is low")
    s.Slider("AutoFleeHP", "Flee HP Threshold (%)", 1, 100, 1)
end

----------------------------------------------------------------------
-- PAGE 2: SKILLS
----------------------------------------------------------------------
local P2L, P2R = Column(pages[2], 0), Column(pages[2], 1)
do
    local orderCard, orderFrame = Card(P2L, "Optional skill combo")
    orderCard.Toggle("UseSkillCombo", "Use this combo", "Off uses the selected-skill rotation")
    local orderChoices = {"None", "Melee:Z", "Melee:X", "Melee:C", "Melee:V", "Melee:F", "Sword:Z", "Sword:X", "Blox Fruit:Z", "Blox Fruit:X", "Blox Fruit:C", "Blox Fruit:V", "Blox Fruit:F", "Gun:Z", "Gun:X"}
    orderCard.Dropdown("ComboPick", "Choose a skill to add", orderChoices)
    orderCard.Button("AddComboSkill", "Add to combo")
    local comboRows = New("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(orderFrame)}, orderFrame)
    local comboLayout = New("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, comboRows)
    local comboListElement = {}
    function comboListElement.Set(order)
        for _, child in ipairs(comboRows:GetChildren()) do if child ~= comboLayout then child:Destroy() end end
        order = type(order) == "table" and order or {}
        comboRows.Size = UDim2.new(1, 0, 0, #order * 34 + math.max(#order - 1, 0) * 5)
        for index, entry in ipairs(order) do
            local weapon, key = tostring(entry):match("^(.-):([%a])$")
            local row = New("Frame", {Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.elem, BorderSizePixel = 0, LayoutOrder = index}, comboRows)
            Corner(row, 8)
            Text(row, string.format("%d.  %s  %s", index, weapon or "Skill", key and string.upper(key) or ""), 12, "text", Enum.Font.GothamBold, {Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -112, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd})
            local function miniButton(label, x, callback)
                local b = New("TextButton", {Text = label, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = T.text, BackgroundColor3 = T.stroke, BorderSizePixel = 0, Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, x, 0.5, -13), AnchorPoint = Vector2.new(1, 0)}, row)
                Corner(b, 7); C(b.MouseButton1Click, callback)
            end
            miniButton("↑", -74, function()
                if index <= 1 then return end
                local nextOrder = table.clone(order); nextOrder[index], nextOrder[index - 1] = nextOrder[index - 1], nextOrder[index]
                Set("SkillOrder", nextOrder)
            end)
            miniButton("↓", -42, function()
                if index >= #order then return end
                local nextOrder = table.clone(order); nextOrder[index], nextOrder[index + 1] = nextOrder[index + 1], nextOrder[index]
                Set("SkillOrder", nextOrder)
            end)
            miniButton("×", -10, function()
                local nextOrder = table.clone(order); table.remove(nextOrder, index); Set("SkillOrder", nextOrder)
            end)
        end
    end
    UI.Elements.SkillComboList = comboListElement
    comboListElement.Set(Get("SkillOrder"))
    orderCard.Button("ClearComboSkills", "Clear combo")
    local SK = {
        {"Melee", P2L, {"Z", "X", "C"}},
        {"Sword", P2L, {"Z", "X"}},
        {"Fruit", P2R, {"Z", "X", "C", "V", "F"}},
        {"Gun",   P2R, {"Z", "X"}},
    }
    for _, s in ipairs(SK) do
        local e = Card(s[2], s[1])
        e.Chips(s[1] .. "Skills", "Skills", s[3])
        e.Toggle(s[1] .. "V4Only", "Only while V4")
        for _, k in ipairs(s[3]) do e.Slider(s[1] .. "Hold" .. k, k .. " hold (s)", 0.1, 1, 0.1) end
    end
end

----------------------------------------------------------------------
-- PAGE 3: SERVER (+ ESP, performance)
----------------------------------------------------------------------
local P3L, P3R = Column(pages[3], 0), Column(pages[3], 1)
do
    local e = Card(P3L, "Server hop")
    e.Dropdown("ServerRegion", "Region", {"Random", "Oregon", "Florida", "Texas", "California", "Hong Kong", "Germany", "Brazil", "Singapore", "India"})
    e.Dropdown("HopPlayerRange", "Players", {"1-12", "3-12", "5-12", "7-12", "9-12"})
    e.Dropdown("HopBountyRange", "Min bounty", {"> 3M", "> 5M", "> 10M", "> 15M", "> 25M", "> 35M", "> 50M"})
    e.Slider("MaxStaySeconds", "Max stay (s)", 60, 1800, 30)
    e.Copy("Server ID", game.JobId ~= "" and game.JobId or "Studio")
    e.Button("ManualHop", "Hop now", true)

    local p = Card(P3L, "Performance")
    p.Toggle("WaterWalk", "Water walk", "Protects chase and Soru over water")
    p.Toggle("FPSBoost", "FPS boost", "Simplifies map and effects")

    local v = Card(P3R, "ESP")
    v.Toggle("ESP", "Enable ESP")
    v.Toggle("ESP_ShowName", "Name")
    v.Toggle("ESP_ShowLevel", "Level")
    v.Toggle("ESP_ShowHealth", "Health")
    v.Toggle("ESP_ShowDistance", "Distance")
    v.Toggle("ESP_ShowPVP", "PvP state")
    v.Slider("ESP_FontSize", "Font size", 8, 28, 1)
end

----------------------------------------------------------------------
-- PAGE 4: SYSTEM (theme strip, interface, config, credits)
----------------------------------------------------------------------
local ThemeStrip = New("Frame", {Size = UDim2.new(1, 0, 0, 54), BorderSizePixel = 0}, pages[4])
R(ThemeStrip, "BackgroundColor3", "panel"); Corner(ThemeStrip, 12); Stroke(ThemeStrip, "stroke", 1, 0.25)
local themeName = Text(ThemeStrip, "", 12, "A", Enum.Font.GothamBlack, {Position = UDim2.fromOffset(14, 9), Size = UDim2.fromOffset(120, 16)})
Text(ThemeStrip, "THEME", 10, "sub", Enum.Font.GothamBold, {Position = UDim2.fromOffset(14, 27), Size = UDim2.fromOffset(120, 14)})
local themeRow = New("Frame", {BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.new(1, -150, 1, -16)}, ThemeStrip)
List(themeRow, 6, Enum.FillDirection.Horizontal)
local themeCards = {}

local P4L, P4R = Column(pages[4], 0, 62), Column(pages[4], 1, 62)
do
    local e = Card(P4L, "Interface")
    e.Toggle("UI_Island", "Dynamic island")
    e.Toggle("UI_IslandAuto", "Island toasts", "Pop status changes on the island")
    e.Toggle("UI_Anim", "Animations", "Off = instant, max fps")
    e.Toggle("UI_Orb", "Floating button")

    local _, preferencesCard = Card(P4R, "Preferences")
    Text(preferencesCard, "All settings are saved automatically.", 11, "sub", Enum.Font.Gotham,
        {Size = UDim2.new(1, -8, 0, 30), TextWrapped = true})

    local auto = Card(P4L, "Auto execute")
    auto.Toggle("AutoExecute", "Auto execute after server hop",
        "Runs raw Lua source returned by your URL after the next server loads; normal webpages will not work")
    auto.TextInput("AutoExecuteURL", "Script URL",
        "https://raw.githubusercontent.com/your-name/repo/main/script.lua")

    local hook = Card(P4R, "Discord webhook")
    hook.Toggle("WebhookEnabled", "Enable server summaries")
    hook.TextInput("WebhookUrl", "Webhook URL", "Paste your Discord webhook URL")
    hook.Toggle("HideWebhookUsername", "Hide username in webhook",
        "Replaces your Roblox username with Hidden")

    local a = Card(P4L, "Credits")
    a.Copy("Made by Merciful", "mercifuldragon_", "Copy Discord")
    local note = New("Frame", {Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 99}, select(2, Card(P4R, "Tips")))
    Text(note, "Left Ctrl hides / shows the menu.\nClick the island to expand it.", 11, "sub", Enum.Font.Gotham,
        {Size = UDim2.fromScale(1, 1), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top})
end

----------------------------------------------------------------------
-- DYNAMIC ISLAND
----------------------------------------------------------------------
local I_TEXT, I_SUB = Color3.fromRGB(242, 242, 248), Color3.fromRGB(140, 140, 158)
local W0, H0, W1, H1 = 250, 38, 420, 278
local rng = Random.new()

local Island = New("Frame", {BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -80),
    Size = UDim2.fromOffset(W1, H1), ZIndex = 50}, Gui)
local Pill = New("TextButton", {Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0),
    BackgroundColor3 = Color3.fromRGB(6, 6, 10), Size = UDim2.fromOffset(W0, H0), ClipsDescendants = true, ZIndex = 50, BorderSizePixel = 0}, Island)
local PillCorner = Corner(Pill, 19)
local PillStroke = New("UIStroke", {Color = WHITE, Thickness = 1.6, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, Pill)
local PillGrad = Grad(PillStroke, 0)

local Ring = New("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(20, H0 / 2), Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = STATE_COL.Idle, BackgroundTransparency = 0.4, BorderSizePixel = 0}, Pill)
Corner(Ring, 13)
local Dot = New("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(20, H0 / 2), Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = STATE_COL.Idle, BorderSizePixel = 0}, Pill)
Corner(Dot, 4)
local PillText = IText(Pill, "Idle", 12, I_TEXT, Enum.Font.GothamBold, {Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -112, 0, H0), TextTruncate = Enum.TextTruncate.AtEnd})
local PillRight = IText(Pill, "+0", 12, WHITE, Enum.Font.GothamBold, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 0),
    Size = UDim2.fromOffset(70, H0), TextXAlignment = Enum.TextXAlignment.Right})
R(PillRight, "TextColor3", "A")

-- expanded detail panel: key stats, compact meters, and a three-row recent-kill list.
local Detail = New("CanvasGroup", {BackgroundTransparency = 1, Position = UDim2.fromOffset(0, H0), Size = UDim2.new(1, 0, 1, -H0 - 8), Visible = false, GroupTransparency = 1}, Pill)
IText(Detail, "EARNED THIS SERVER", 9, I_SUB, Enum.Font.GothamBold, {Position = UDim2.fromOffset(18, 0), Size = UDim2.fromOffset(140, 12)})
local BigNum = IText(Detail, "0", 28, I_TEXT, Enum.Font.GothamBlack, {Position = UDim2.fromOffset(18, 10), Size = UDim2.new(0.6, 0, 0, 32)})
IText(Detail, "ALL SERVERS", 9, I_SUB, Enum.Font.GothamBold, {Position = UDim2.fromOffset(276, 4), Size = UDim2.fromOffset(62, 12)})
local TotalNum = IText(Detail, "0", 15, I_TEXT, Enum.Font.GothamBlack, {Position = UDim2.fromOffset(276, 18), Size = UDim2.fromOffset(62, 22), TextTruncate = Enum.TextTruncate.AtEnd})
local ResetTotalButton = New("TextButton", {Text = "RESET", Position = UDim2.fromOffset(276, 42), Size = UDim2.fromOffset(62, 17), BackgroundColor3 = Color3.fromRGB(37, 43, 59), TextColor3 = I_SUB, TextSize = 9, Font = Enum.Font.GothamBold, AutoButtonColor = true, BorderSizePixel = 0, ZIndex = 56}, Detail)
Corner(ResetTotalButton, 5)
C(ResetTotalButton.MouseButton1Click, function() if api.Action then pcall(api.Action, "ResetAllServerTotals") end end)
local Delta = IText(Detail, "", 11, WHITE, Enum.Font.GothamBold, {Position = UDim2.fromOffset(18, 43), Size = UDim2.new(0.6, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd})
R(Delta, "TextColor3", "A")
local StayHold = New("Frame", {AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -4), Size = UDim2.new(1, -32, 0, 2), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0}, Pill)
Corner(StayHold, 1)
local StayLine = New("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0}, StayHold)
Corner(StayLine, 1); Grad(StayLine, 0)
local Radar = New("CanvasGroup", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 0), Size = UDim2.fromOffset(62, 62), BackgroundColor3 = Color3.fromRGB(14, 16, 24), BorderSizePixel = 0}, Detail)
Corner(Radar, 31)
local RadarStroke = New("UIStroke", {Thickness = 1.2, Transparency = 0.45, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, Radar)
R(RadarStroke, "Color", "A")
for _, f in ipairs({0.66, 0.33}) do
    local ringF = New("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(f, f), BackgroundTransparency = 1}, Radar)
    Corner(ringF, 40); New("UIStroke", {Color = WHITE, Thickness = 1, Transparency = 0.85}, ringF)
end
local Sweep = New("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1}, Radar)
local SweepLine = New("Frame", {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 2, 0.5, 0), BorderSizePixel = 0}, Sweep)
R(SweepLine, "BackgroundColor3", "A")
local SweepTrail = New("Frame", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 24, 0.5, 0), BorderSizePixel = 0, BackgroundTransparency = 0}, Sweep)
R(SweepTrail, "BackgroundColor3", "A")
New("UIGradient", {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.55)})}, SweepTrail)
local Blip = New("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(7, 7), BackgroundColor3 = STATE_COL.Risk, BorderSizePixel = 0, Visible = false}, Radar)
Corner(Blip, 4); New("UIStroke", {Color = WHITE, Thickness = 1, Transparency = 0.4}, Blip)
local Spark = New("Frame", {Position = UDim2.fromOffset(18, 63), Size = UDim2.new(1, -36, 0, 16), BackgroundTransparency = 1}, Detail)
local SPARK_N, sparkBars = 32, {}
for i = 1, SPARK_N do
    local b = New("Frame", {AnchorPoint = Vector2.new(0, 1), Position = UDim2.new((i - 1) / SPARK_N, 0, 1, 0), Size = UDim2.new(1 / SPARK_N, -2, 0, 2), BorderSizePixel = 0, BackgroundTransparency = 0.85}, Spark)
    Corner(b, 1); R(b, "BackgroundColor3", "A"); sparkBars[i] = b
end
local stats = {}
do
    local labels = {"PER HOUR", "TOTAL KILLS", "RUNTIME", "PLAYERS"}
    local colW = (W1 - 36) / 4
    for i, cap in ipairs(labels) do
        local x = 18 + (i - 1) * colW
        IText(Detail, cap, 8, I_SUB, Enum.Font.GothamBold, {Position = UDim2.fromOffset(x, 82), Size = UDim2.fromOffset(colW, 11)})
        stats[i] = IText(Detail, "-", 11, I_TEXT, Enum.Font.GothamBold, {Position = UDim2.fromOffset(x, 93), Size = UDim2.fromOffset(colW - 4, 15), TextTruncate = Enum.TextTruncate.AtEnd})
    end
end
local TgtName = IText(Detail, "No target", 10, I_SUB, Enum.Font.GothamMedium, {Position = UDim2.fromOffset(18, 112), Size = UDim2.new(0.58, 0, 0, 13), TextTruncate = Enum.TextTruncate.AtEnd})
local TgtInfo = IText(Detail, "", 10, I_SUB, Enum.Font.GothamMedium, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 112), Size = UDim2.new(0.42, 0, 0, 13), TextXAlignment = Enum.TextXAlignment.Right})
local HPBack = New("Frame", {Position = UDim2.fromOffset(18, 130), Size = UDim2.new(1, -36, 0, 3), BackgroundColor3 = WHITE, BackgroundTransparency = 0.92, BorderSizePixel = 0}, Detail)
Corner(HPBack, 2)
local HPFill = New("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0}, HPBack)
Corner(HPFill, 2); Grad(HPFill, 0)
IText(Detail, "LAST 5 KILLS", 8, I_SUB, Enum.Font.GothamBold, {Position = UDim2.fromOffset(18, 140), Size = UDim2.fromOffset(120, 11)})
local killRows = {}
for i = 1, 5 do
    local row, col = math.floor((i - 1) / 2), (i - 1) % 2
    local x, y = 18 + col * 202, 154 + row * 16
    local nameLabel = IText(Detail, "—", 9, I_TEXT, Enum.Font.GothamMedium, {Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(122, 12), TextTruncate = Enum.TextTruncate.AtEnd})
    local rewardLabel = IText(Detail, "", 9, I_SUB, Enum.Font.Gotham, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromOffset(x + 190, y), Size = UDim2.fromOffset(68, 12), TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd})
    killRows[i] = {Name = nameLabel, Reward = rewardLabel}
end
local IslandActions = {}
IslandActions.Toggle = New("TextButton", {Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(18, 204), Size = UDim2.fromOffset(118, 24), BackgroundColor3 = Color3.fromRGB(37, 43, 59), BorderSizePixel = 0, ZIndex = 56}, Detail)
Corner(IslandActions.Toggle, 7)
IslandActions.ToggleLabel = IText(IslandActions.Toggle, "Start Auto", 10, WHITE, Enum.Font.GothamBold, {Size = UDim2.fromScale(1, 1), ZIndex = 57})
IslandActions.Hop = New("TextButton", {Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(144, 204), Size = UDim2.fromOffset(118, 24), BackgroundColor3 = Color3.fromRGB(37, 43, 59), BorderSizePixel = 0, ZIndex = 56}, Detail)
Corner(IslandActions.Hop, 7)
IText(IslandActions.Hop, "Hop server", 10, WHITE, Enum.Font.GothamBold, {Size = UDim2.fromScale(1, 1), ZIndex = 57})
IslandActions.Players = New("TextButton", {Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(270, 204), Size = UDim2.fromOffset(132, 24), BackgroundColor3 = Color3.fromRGB(37, 43, 59), BorderSizePixel = 0, ZIndex = 56}, Detail)
Corner(IslandActions.Players, 7)
IText(IslandActions.Players, "Players List", 10, WHITE, Enum.Font.GothamBold, {Size = UDim2.fromScale(1, 1), ZIndex = 57})
C(IslandActions.Toggle.MouseButton1Click, function()
    Set("AutoBounty", Get("AutoBounty") ~= true)
    UI._refresh()
end)
C(IslandActions.Hop.MouseButton1Click, function()
    if api.Action then pcall(api.Action, "ManualHop") end
end)
C(IslandActions.Toggle.MouseEnter, function() Tw(IslandActions.Toggle, {BackgroundColor3 = T.A}, 0.12) end)
C(IslandActions.Hop.MouseEnter, function() Tw(IslandActions.Hop, {BackgroundColor3 = T.A}, 0.12) end)
C(IslandActions.Toggle.MouseLeave, function() Tw(IslandActions.Toggle, {BackgroundColor3 = Color3.fromRGB(37, 43, 59)}, 0.16) end)
C(IslandActions.Hop.MouseLeave, function() Tw(IslandActions.Hop, {BackgroundColor3 = Color3.fromRGB(37, 43, 59)}, 0.16) end)

-- Separate second page for the live player roster.
local PlayersPage = New("CanvasGroup", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(0, H0),
    Size = UDim2.new(1, 0, 1, -H0 - 8),
    Visible = false,
    GroupTransparency = 1,
    ZIndex = 58,
}, Pill)
IText(PlayersPage, "PLAYERS LIST", 12, I_TEXT, Enum.Font.GothamBlack, {
    Position = UDim2.fromOffset(18, 2), Size = UDim2.fromOffset(180, 18), ZIndex = 59
})
local PlayersCount = IText(PlayersPage, "0 PLAYERS", 9, I_SUB, Enum.Font.GothamBold, {
    Position = UDim2.fromOffset(18, 20), Size = UDim2.fromOffset(150, 12), ZIndex = 59
})
local PlayersBack = New("TextButton", {
    Text = "BACK", Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = WHITE,
    BackgroundColor3 = Color3.fromRGB(37, 43, 59), BorderSizePixel = 0,
    Position = UDim2.new(1, -72, 0, 3), Size = UDim2.fromOffset(54, 23),
    AutoButtonColor = false, ZIndex = 61,
}, PlayersPage)
Corner(PlayersBack, 7)
local PlayersScroll = New("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2,
    ScrollBarImageColor3 = T.A, Position = UDim2.fromOffset(14, 39),
    Size = UDim2.new(1, -28, 1, -44), CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 59,
}, PlayersPage)
local PlayersLayout = List(PlayersScroll, 5)
local PlayerRows = {}
local PlayerData = {}
local expanded

local function renderPlayers()
    if not PlayersPage.Visible then return end
    local present = {}
    for index, info in ipairs(PlayerData) do
        local key = tostring(info.UserId or info.Name or index)
        present[key] = true
        local row = PlayerRows[key]
        if not row then
            local frame = New("Frame", {
                Size = UDim2.new(1, -5, 0, 48), BackgroundColor3 = Color3.fromRGB(19, 20, 30),
                BorderSizePixel = 0, LayoutOrder = index, ZIndex = 60,
            }, PlayersScroll)
            Corner(frame, 10)
            local frameStroke = New("UIStroke", {
                Color = WHITE, Thickness = 1, Transparency = 0.88,
                ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            }, frame)
            local avatar = New("ImageLabel", {
                Size = UDim2.fromOffset(34, 34), Position = UDim2.fromOffset(8, 7),
                BackgroundColor3 = Color3.fromRGB(35, 36, 49), BorderSizePixel = 0,
                Image = "", ZIndex = 62,
            }, frame)
            Corner(avatar, 17)
            local avatarStroke = New("UIStroke", {Color = T.A, Thickness = 1.3, Transparency = 0.55}, avatar)
            local display = IText(frame, "", 11, I_TEXT, Enum.Font.GothamBold, {
                Position = UDim2.fromOffset(50, 7), Size = UDim2.new(1, -142, 0, 16),
                TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 62,
            })
            local username = IText(frame, "", 9, I_SUB, Enum.Font.Gotham, {
                Position = UDim2.fromOffset(50, 24), Size = UDim2.new(1, -142, 0, 13),
                TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 62,
            })
            local status = IText(frame, "", 8, I_SUB, Enum.Font.GothamBold, {
                AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
                Size = UDim2.fromOffset(86, 18), TextXAlignment = Enum.TextXAlignment.Right,
                TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 62,
            })
            row = {Frame = frame, Stroke = frameStroke, Avatar = avatar,
                AvatarStroke = avatarStroke, Display = display, Username = username, Status = status}
            PlayerRows[key] = row

            local uid = tonumber(info.UserId)
            if uid and uid > 0 then
                task.spawn(function()
                    local ok, image = pcall(Players.GetUserThumbnailAsync, Players, uid,
                        Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
                    if ok and image and row.Avatar and row.Avatar.Parent then
                        row.Avatar.Image = image
                    end
                end)
            end
        end

        row.Frame.LayoutOrder = index
        row.Display.Text = tostring(info.DisplayName or info.Name or "Unknown")
        row.Username.Text = "@" .. tostring(info.Name or "unknown")
        if info.IsTarget then
            row.Frame.BackgroundColor3 = Color3.fromRGB(43, 31, 58)
            row.Stroke.Color, row.Stroke.Transparency = T.A, 0.05
            row.AvatarStroke.Color, row.AvatarStroke.Transparency = T.A, 0
            row.Status.Text, row.Status.TextColor3 = "ATTACKING", T.A
        elseif info.InRaid then
            row.Frame.BackgroundColor3 = Color3.fromRGB(43, 35, 22)
            row.Stroke.Color, row.Stroke.Transparency = Color3.fromRGB(255, 185, 75), 0.35
            row.AvatarStroke.Color, row.AvatarStroke.Transparency = Color3.fromRGB(255, 185, 75), 0.35
            row.Status.Text, row.Status.TextColor3 = "IN RAID", Color3.fromRGB(255, 185, 75)
        elseif info.Eligible then
            row.Frame.BackgroundColor3 = Color3.fromRGB(19, 31, 29)
            row.Stroke.Color, row.Stroke.Transparency = Color3.fromRGB(74, 222, 128), 0.72
            row.AvatarStroke.Color, row.AvatarStroke.Transparency = Color3.fromRGB(74, 222, 128), 0.65
            row.Status.Text, row.Status.TextColor3 = "ELIGIBLE", Color3.fromRGB(74, 222, 128)
        else
            row.Frame.BackgroundColor3 = Color3.fromRGB(19, 20, 30)
            row.Stroke.Color, row.Stroke.Transparency = WHITE, 0.9
            row.AvatarStroke.Color, row.AvatarStroke.Transparency = T.A, 0.7
            row.Status.Text = tostring(info.Reason or "SKIPPED"):gsub("_", " "):upper()
            row.Status.TextColor3 = I_SUB
        end
    end

    for key, row in pairs(PlayerRows) do
        if not present[key] then
            if row.Frame then row.Frame:Destroy() end
            PlayerRows[key] = nil
        end
    end
    PlayersCount.Text = tostring(#PlayerData) .. " PLAYERS"
end

C(IslandActions.Players.MouseButton1Click, function()
    Detail.Visible = false
    PlayersPage.Visible = true
    PlayersPage.GroupTransparency = 1
    renderPlayers()
    Tw(PlayersPage, {GroupTransparency = 0}, 0.14)
end)
C(PlayersBack.MouseButton1Click, function()
    Tw(PlayersPage, {GroupTransparency = 1}, 0.1)
    task.delay(0.11, function()
        PlayersPage.Visible = false
        if expanded then Detail.Visible = true end
    end)
end)

----------------------------------------------------------------------
-- LIVE DATA + ISLAND BEHAVIOUR
----------------------------------------------------------------------
local startClock = os.clock()
local runCarry = tonumber(genv.AutoBountyRunTime) or 0
local S = {State = "Idle", Status = "Idle"}
local baseBounty = nil
local frames, fps = 0, 60
expanded = false
local toast, toastTok, pillW = false, 0, W0
local samples = {}
local lastSeen, rolled, boostUntil = nil, nil, 0

local bountyNV = Instance.new("NumberValue")
C(bountyNV.Changed, function(v) BigNum.Text = fmtNum(v) end)

local function readBounty()
    if S.Bounty then return tonumber(S.Bounty) end
    local ls = LocalPlayer and LocalPlayer:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Bounty/Honor")
    return v and tonumber(v.Value) or nil
end
local function readPing()
    local ok, v = pcall(function() return StatsService.Network.ServerStatsItem["Data Ping"]:GetValue() end)
    return ok and v or nil
end

-- typewriter reveal for status changes
local function typeText(label, txt)
    label.Text = txt
    if not animOn then label.MaxVisibleGraphemes = -1; return end
    local n = utf8.len(txt) or #txt
    label.MaxVisibleGraphemes = 0
    local tw = Tw(label, {MaxVisibleGraphemes = n}, math.clamp(n * 0.025, 0.15, 0.8), SINE)
    if tw then tw.Completed:Connect(function() if label.Text == txt then label.MaxVisibleGraphemes = -1 end end) end
end
local function setPillText(txt)
    if PillText.Text == txt then return end
    typeText(PillText, txt)
end

-- pulsing ring: slow when idle, frantic when risk
local PERIOD = {Idle = 2.6, Hunting = 1.1, Fleeing = 0.45, Hopping = 0.8, Risk = 0.35}
local pulse
local function setPulse(state)
    if pulse then pulse:Cancel(); pulse = nil end
    Ring.Size = UDim2.fromOffset(8, 8); Ring.BackgroundTransparency = 0.4
    if animOn then
        pulse = TweenService:Create(Ring, TweenInfo.new(PERIOD[state] or 1.2, SINE, OUT, -1), {Size = UDim2.fromOffset(26, 26), BackgroundTransparency = 1})
        pulse:Play()
    end
end
local function paintState()
    local col = STATE_COL[S.State] or STATE_COL.Idle
    Tw(Dot, {BackgroundColor3 = col}, 0.3); Tw(Ring, {BackgroundColor3 = col}, 0.3)
    if S.State == "Risk" then
        PillGrad.Color = ColorSequence.new(STATE_COL.Risk, Color3.fromRGB(255, 150, 60))
    else
        PillGrad.Color = ColorSequence.new(T.A, T.B)
    end
    liveState.Text = string.upper(S.State)
    Tw(liveState, {TextColor3 = col}, 0.3)
    setPulse(S.State)
end

local function Shake()
    if not animOn then return end
    task.spawn(function()
        for i = 1, 6 do
            local dx = (i % 2 == 0 and 1 or -1) * (7 - i)
            Pill.Position = UDim2.new(0.5, dx, 0, 0)
            task.wait(0.04)
        end
        Pill.Position = UDim2.fromScale(0.5, 0)
    end)
end

-- bounty gain: confetti + floating "+N" + border spin
local function Celebrate(gain)
    boostUntil = os.clock() + 1.4
    if not animOn or not Island.Visible then return end
    local cols = {T.A, T.B, WHITE}
    local cx = W1 / 2
    for _ = 1, 20 do
        local sz = rng:NextInteger(4, 8)
        local p = New("Frame", {Size = UDim2.fromOffset(sz, sz), AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(cx + rng:NextInteger(-50, 50), H0 / 2), BackgroundColor3 = cols[rng:NextInteger(1, 3)],
            BorderSizePixel = 0, ZIndex = 70, Rotation = rng:NextInteger(0, 360)}, Island)
        Corner(p, rng:NextInteger(0, 1) == 0 and sz or 1)
        local dur = 0.7 + rng:NextNumber() * 0.5
        Tw(p, {Position = UDim2.fromOffset(cx + rng:NextInteger(-180, 180), H0 + rng:NextInteger(20, 130)),
            Rotation = p.Rotation + rng:NextInteger(-320, 320), BackgroundTransparency = 1}, dur, Q)
        task.delay(dur + 0.05, function() p:Destroy() end)
    end
    local lbl = New("TextLabel", {BackgroundTransparency = 1, Text = "+" .. fmtCompact(gain), Font = Enum.Font.GothamBlack, TextSize = 18,
        TextColor3 = T.A, TextStrokeTransparency = 0.6, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(cx, H0 + 6),
        Size = UDim2.fromOffset(160, 22), ZIndex = 71}, Island)
    Tw(lbl, {Position = UDim2.fromOffset(cx, H0 + 42), TextTransparency = 1, TextStrokeTransparency = 1}, 1.1, Q)
    task.delay(1.2, function() lbl:Destroy() end)
    if not expanded then
        Tw(Pill, {Size = UDim2.fromOffset(pillW + 20, H0 + 6)}, 0.12, Q)
        task.delay(0.14, function() if not expanded then Tw(Pill, {Size = UDim2.fromOffset(pillW, H0)}, 0.45, BACK) end end)
    end
end

local function setExpanded(x)
    expanded = x
    if x then
        Detail.Visible = true
        PlayersPage.Visible = false
        Detail.GroupTransparency = 0
        bountyNV.Value = 0; BigNum.Text = "0"; rolled = nil
        Tw(Pill, {Size = UDim2.fromOffset(W1, H1)}, 0.28, BACK)
        Tw(PillCorner, {CornerRadius = UDim.new(0, 28)}, 0.4)
        task.delay(animOn and 0.12 or 0, function() if expanded then Tw(Detail, {GroupTransparency = 0}, 0.14) end end)
        UI._refresh()
    else
        Tw(Detail, {GroupTransparency = 1}, 0.12)
        Tw(PlayersPage, {GroupTransparency = 1}, 0.12)
        PlayersPage.Visible = false
        Tw(Pill, {Size = UDim2.fromOffset(pillW, H0)}, 0.25, BACK)
        Tw(PillCorner, {CornerRadius = UDim.new(0, 19)}, 0.4)
        task.delay(animOn and 0.2 or 0, function() if not expanded then Detail.Visible = false end end)
    end
end
C(Pill.MouseButton1Click, function() setExpanded(not expanded) end)
C(Pill.MouseEnter, function() if not expanded then Tw(Pill, {Size = UDim2.fromOffset(pillW + 10, H0)}, 0.2, BACK) end end)
C(Pill.MouseLeave, function() if not expanded then Tw(Pill, {Size = UDim2.fromOffset(pillW, H0)}, 0.25) end end)

function UI._refresh()
    local cur = readBounty()

    local earned = tonumber(S.Earned) or 0
    if cur then
        if lastSeen and cur > lastSeen then Celebrate(cur - lastSeen) end
        lastSeen = cur
    end
    local runtime = S.Runtime or (runCarry + (os.clock() - startClock))
    local totalEarned = tonumber(S.TotalEarned) or 0
    local earnedRuntime = math.max(runtime - (tonumber(S.TotalRuntimeBase) or 0), 0)
    local perHour = earnedRuntime > 30 and (totalEarned / earnedRuntime * 3600) or 0
    local sign = earned >= 0 and "+" or "-"

    if not toast then setPillText(S.Status) end
    PillRight.Text = sign .. fmtCompact(math.abs(earned))
    IslandActions.ToggleLabel.Text = Get("AutoBounty") == true and "Stop Auto Bounty" or "Start Auto Bounty"

    liveStatus.Text = S.Status
    liveBounty.Text = "Bounty  " .. (cur and fmtNum(cur) or "-")
    liveEarn.Text = sign .. fmtNum(math.abs(earned)) .. "  this server"
    liveTotal.Text = "All servers  " .. fmtNum(totalEarned) .. "  ·  " .. fmtCompact(perHour) .. "/h"

    local stay, limit = tonumber(S.Stay) or (os.clock() - startClock), tonumber(S.StayLimit)
    if limit and limit > 0 then
        Tw(StayLine, {Size = UDim2.fromScale(math.clamp(stay / limit, 0, 1), 1)}, 0.5)
        StayHold.Visible = true
    else
        StayHold.Visible = false
    end

    if not expanded then return end
    if earned ~= rolled then
        rolled = earned
        if animOn then Tw(bountyNV, {Value = earned}, 0.28) else bountyNV.Value = earned end
    end
    TotalNum.Text = fmtCompact(totalEarned)
    Delta.Text = "Current bounty  " .. (cur and fmtNum(cur) or "-")
    stats[1].Text = fmtCompact(perHour) .. "/h"
    stats[2].Text = fmtNum(tonumber(S.KillCount) or 0)
    stats[3].Text = fmtTime(runtime)
    stats[4].Text = tostring(S.Players or #Players:GetPlayers()) .. "/12"
    TgtName.Text = S.Target and ("Target  " .. S.Target) or "No target"
    TgtName.TextColor3 = S.Target and I_TEXT or I_SUB
    TgtInfo.Text = S.Target and ((S.TargetHP and (math.floor(S.TargetHP * 100) .. "%") or "") .. (S.TargetDist and ("  ·  " .. math.floor(S.TargetDist) .. " studs") or "")) or ""
    Tw(HPFill, {Size = UDim2.fromScale(math.clamp(S.TargetHP or 0, 0, 1), 1)}, 0.25)
    local recent = type(S.RecentKills) == "table" and S.RecentKills or {}
    for i, row in ipairs(killRows) do
        local kill = recent[i]
        if kill then
            row.Name.Text = tostring(i) .. ". " .. tostring(kill.Name or "Unknown")
            row.Reward.Text = fmtCompact(tonumber(kill.Reward) or 0) .. " " .. string.lower(kill.Kind == "Honor" and "Honor" or "Bounty")
            row.Name.TextColor3, row.Reward.TextColor3 = I_TEXT, I_SUB
        else
            row.Name.Text, row.Reward.Text = "—", ""
            row.Name.TextColor3 = I_SUB
        end
    end
    if S.Target then
        local ang = S.TargetAngle
        if not ang then
            local h = 0
            for c in tostring(S.Target):gmatch(".") do h = (h * 31 + string.byte(c)) % 360 end
            ang = math.rad(h)
        end
        local rad = math.clamp((S.TargetDist or 200) / 600, 0.1, 1) * 0.42
        Blip.Visible = true
        Tw(Blip, {Position = UDim2.fromScale(0.5 + math.sin(ang) * rad, 0.5 - math.cos(ang) * rad)}, 0.4)
    else
        Blip.Visible = false
    end
end
local function pushSample()
    local cur = readBounty()
    if not cur then return end
    samples[#samples + 1] = cur
    if #samples > SPARK_N then table.remove(samples, 1) end
    if not expanded then return end
    local lo, hi = math.huge, -math.huge
    for _, value in ipairs(samples) do lo = math.min(lo, value); hi = math.max(hi, value) end
    local span = math.max(hi - lo, 1)
    local offset = SPARK_N - #samples
    for i = 1, SPARK_N do
        local value = samples[i - offset]
        Tw(sparkBars[i], {Size = UDim2.new(1 / SPARK_N, -2, 0, value and (2 + ((value - lo) / span) * 14) or 2), BackgroundTransparency = value and 0.05 or 0.85}, 0.35)
    end
end

----------------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------------
function UI.Notify(txt, dur)
    txt = tostring(txt)
    toastTok += 1
    local tok = toastTok
    toast = true
    setPillText(txt)
    if not expanded and Get("UI_IslandAuto") ~= false then
        local w = TextService:GetTextSize(txt, 12, Enum.Font.GothamBold, Vector2.new(400, H0)).X + 38 + 90
        pillW = math.clamp(w, W0, 380)
        Tw(Pill, {Size = UDim2.fromOffset(pillW, H0)}, 0.55, BACK)
    end
    task.delay(dur or 2.6, function()
        if toastTok ~= tok then return end
        toast = false
        pillW = W0
        setPillText(S.Status)
        if not expanded then Tw(Pill, {Size = UDim2.fromOffset(W0, H0)}, 0.5, BACK) end
    end)
end
function UI.SetStatus(state, status)
    if STATE_COL[state] == nil then status = status or tostring(state); state = S.State end
    local stateChanged = state ~= S.State
    local changed = stateChanged or (status and tostring(status) ~= S.Status)
    S.State, S.Status = state, tostring(status or state)
    paintState()
    if stateChanged and (state == "Fleeing" or state == "Risk") then Shake() end
    if changed and Get("UI_IslandAuto") ~= false then UI.Notify(S.Status, 2.4) end
    UI._refresh()
end
function UI.SetStats(t) if type(t) == "table" then for k, v in pairs(t) do S[k] = v end; UI._refresh() end end
function UI.SetTarget(name, hp, dist, angle) S.Target, S.TargetHP, S.TargetDist, S.TargetAngle = name, hp, dist, angle end
function UI.SetLocked(flag, b) local e = UI.Elements[flag]; if e and e.SetLocked then e.SetLocked(b) end end
function UI.SetTitle(flag, s) local e = UI.Elements[flag]; if e and e.SetTitle then e.SetTitle(s) end end
function UI.SetMin(flag, n) local e = UI.Elements[flag]; if e and e.SetMin then e.SetMin(n) end end
function UI.SetPlayers(data)
    PlayerData = type(data) == "table" and data or {}
    renderPlayers()
end
function UI.RefreshPlayers() renderPlayers() end

----------------------------------------------------------------------
-- ORB + OPEN / CLOSE
----------------------------------------------------------------------
local Orb = New("TextButton", {Text = "M", Font = Enum.Font.GothamBlack, TextSize = 18, TextColor3 = WHITE, AutoButtonColor = false, Visible = not isOpen,
    Size = UDim2.fromOffset(46, 46), Position = UDim2.new(0, 14, 0.5, -23), ZIndex = 40, BorderSizePixel = 0}, Gui)
R(Orb, "BackgroundColor3", "bg"); Corner(Orb, 23)
local OrbGrad = Grad(Stroke(Orb, nil, 2, 0), 0)
local OrbScale = New("UIScale", {Scale = 1}, Orb)
C(Orb.MouseEnter, function() Tw(OrbScale, {Scale = 1.14}, 0.25, BACK) end)
C(Orb.MouseLeave, function() Tw(OrbScale, {Scale = 1}, 0.25) end)

local function setOpen(x)
    if x == isOpen then return end
    isOpen = x
    Orb.Visible = orbWanted or not x
    openToken += 1
    local tok = openToken
    if x then
        Main.Visible = true
        Scale.Scale = baseScale * 0.92
        Tw(Main, {GroupTransparency = 0}, 0.25)
        Tw(Scale, {Scale = baseScale}, 0.5, BACK)
    else
        Tw(Main, {GroupTransparency = 1}, 0.2)
        Tw(Scale, {Scale = baseScale * 0.94}, 0.2)
        task.delay(animOn and 0.22 or 0, function() if openToken == tok and not isOpen then Main.Visible = false end end)
    end
end
UI.SetOpen = setOpen
C(MinBtn.MouseButton1Click, function() setOpen(false) end)
C(CloseBtn.MouseButton1Click, function() setOpen(false); if api.Close then pcall(api.Close) end end)
C(UserInputService.InputBegan, function(i)
    if i.KeyCode == Enum.KeyCode.LeftControl and not UserInputService:GetFocusedTextBox() then setOpen(not isOpen) end
end)
do
    local down, start, orig, moved
    local function isPtr(i) return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch end
    C(Orb.InputBegan, function(i) if isPtr(i) then down, start, orig, moved = true, i.Position, Orb.Position, 0 end end)
    C(UserInputService.InputChanged, function(i)
        if down and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local dx, dy = i.Position.X - start.X, i.Position.Y - start.Y
            moved = math.max(moved, math.sqrt(dx * dx + dy * dy))
            if moved >= 6 then Orb.Position = UDim2.new(orig.X.Scale, orig.X.Offset + dx, orig.Y.Scale, orig.Y.Offset + dy) end
        end
    end)
    C(UserInputService.InputEnded, function(i)
        if down and isPtr(i) then down = false; if moved < 6 then setOpen(not isOpen) end end
    end)
end

----------------------------------------------------------------------
-- THEME PICKER + SWITCHING (colours cross-fade)
----------------------------------------------------------------------
local function applyTheme(name, instant)
    local pick = loadTheme(name)
    local t = (instant or not animOn) and 0 or 0.45
    for i = #reg, 1, -1 do
        local r = reg[i]
        if r[1] and r[1].Parent then
            if t == 0 then r[1][r[2]] = T[r[3]]
            else TweenService:Create(r[1], TweenInfo.new(t, Enum.EasingStyle.Quad, OUT), {[r[2]] = T[r[3]]}):Play() end
        else
            table.remove(reg, i)
        end
    end
    for _, g in ipairs(grads) do if g.Parent then g.Color = ColorSequence.new(T.A, T.B) end end
    for _, fn in ipairs(repaints) do pcall(fn) end
    paintState()
    for n, c in pairs(themeCards) do
        local on = n == pick.name
        Tw(c.stroke, {Transparency = on and 0 or 0.8}, 0.25)
        Tw(c.scale, {Scale = on and 1.08 or 1}, 0.3, BACK)
    end
    themeName.Text = string.upper(pick.name)
    Set("Theme", pick.name)
end
UI.SetTheme = function(name) applyTheme(name, true) end
for i, th in ipairs(THEMES) do
    local card = New("TextButton", {Text = "", AutoButtonColor = false, Size = UDim2.new(1 / #THEMES, -6, 1, 0), BorderSizePixel = 0, LayoutOrder = i,
        BackgroundColor3 = th.bg}, themeRow)
    Corner(card, 9)
    local st = New("UIStroke", {Color = th.A, Thickness = 2, Transparency = 0.8, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, card)
    local sc = New("UIScale", {Scale = 1}, card)
    local top = New("Frame", {Size = UDim2.new(1, -8, 0.5, -3), Position = UDim2.fromOffset(4, 4), BackgroundColor3 = WHITE, BorderSizePixel = 0}, card)
    Corner(top, 5)
    New("UIGradient", {Color = ColorSequence.new(th.A, th.B), Rotation = 20}, top)
    local lo = New("Frame", {Size = UDim2.new(1, -8, 0.5, -7), Position = UDim2.new(0, 4, 0.5, 3), BackgroundColor3 = th.elem, BorderSizePixel = 0}, card)
    Corner(lo, 4)
    themeCards[th.name] = {stroke = st, scale = sc}
    C(card.MouseEnter, function() themeName.Text = string.upper(th.name) end)
    C(card.MouseLeave, function() themeName.Text = string.upper(T.name or "") end)
    C(card.MouseButton1Click, function() applyTheme(th.name) end)
end

----------------------------------------------------------------------
-- INTERFACE FLAGS (live)
----------------------------------------------------------------------
local rawSet = api.Set
api.Set = function(flag, v)
    if flag == "UI_Island" then Island.Visible = v and true or false
    elseif flag == "UI_Anim" then animOn = v and true or false; setPulse(S.State)
    elseif flag == "UI_Orb" then orbWanted = v and true or false; Orb.Visible = orbWanted or not isOpen end
    pcall(rawSet, flag, v)
end
for _, flag in ipairs({"UI_Island", "UI_IslandAuto", "UI_Anim", "UI_Orb"}) do
    local v = Get(flag); if v == nil then v = true; demo[flag] = true end
    if UI.Elements[flag] then UI.Elements[flag].Set(v) end
    api.Set(flag, v)
end

----------------------------------------------------------------------
-- LOOPS (one render connection + one 4 Hz updater)
----------------------------------------------------------------------
local mainAng, pillAng, orbAng = 0, 0, 0
C(RunService.RenderStepped, function(dt)
    frames += 1
    if not animOn then return end
    local now = os.clock()
    if Main.Visible then mainAng = (mainAng + dt * 30) % 360; MainStrokeGrad.Rotation = mainAng end
    if Island.Visible then
        local sp = 70 + (S.State ~= "Idle" and 70 or 0) + (now < boostUntil and 420 or 0)
        pillAng = (pillAng + dt * sp) % 360
        PillGrad.Rotation = pillAng
            if expanded then Sweep.Rotation = (now * 150) % 360 end
    end
    if Orb.Visible then orbAng = (orbAng + dt * 100) % 360; OrbGrad.Rotation = orbAng end
end)
local alive = true
task.spawn(function()
    local lastFrames, lastT, sampleClock = 0, os.clock(), 0
    while alive do
        task.wait(0.1)
        local now = os.clock()
        local dt = now - lastT
        if dt > 0 then fps = math.floor((frames - lastFrames) / dt + 0.5) end
        lastFrames, lastT = frames, now
        sampleClock += dt
        if sampleClock >= 5 then sampleClock = 0; pcall(pushSample) end
        pcall(UI._refresh)
    end
end)

----------------------------------------------------------------------
-- CLEANUP + START (intro animation)
----------------------------------------------------------------------
function UI.Destroy()
    alive = false
    if pulse then pcall(function() pulse:Cancel() end) end
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    pcall(function() Gui:Destroy() end)
    genv.MercifulUI = nil
end
genv.MercifulUI = UI

applyTheme(T.name, true)
showPage(1, true)
paintState()
UI._refresh()
setExpanded(true)
task.defer(function() pcall(pushSample) end)

Scale.Scale = baseScale * 0.92
if isOpen then
    Tw(Main, {GroupTransparency = 0}, 0.4)
    Tw(Scale, {Scale = baseScale}, 0.7, BACK)
end
Tw(Island, {Position = UDim2.new(0.5, 0, 0, 10)}, 0.8, BACK)

return UI
    ]====])
    if uiChunk then
        local uiOk, uiError = pcall(uiChunk)
        if uiOk and RefreshMercifulUI then RefreshMercifulUI() end
        if not uiOk then warn("Merciful UI failed to initialize: " .. tostring(uiError)) end
    end
    if type(uiEnv) == "table" then uiEnv.MercifulUIInitializing = nil end
    if SaveConfig then SaveConfig(true) end
end)
