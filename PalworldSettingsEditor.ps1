<#
  VPal Server Command Center
  The control panel for a Palworld dedicated server: every PalWorldSettings.ini setting (change values, click
  Save, and the file is rewritten for you with a backup first), start and stop, messages, the Pal Planner,
  players, backups, the watchdog and the Discord bot. Unofficial fan tool. Not affiliated with Pocketpair.

  It lives in the server folder (the one with PalServer.exe) and works on that server. The Pal Planner tab runs the
  family pal website from the PalPlanner folder next to it.
#>

$ErrorActionPreference = 'Stop'

# ---------------- Paths ----------------
# The server folder is the one this file is in (VPal-Setup puts the panel, CommandCenter and
# PalPlanner there). Only a copy of the panel sitting on its own falls back to C:\palworld-server.
$PanelFile = $PSCommandPath                    # this file, to reopen it after a VPal update
$ServerDir = $PSScriptRoot
if (-not $ServerDir -or -not ((Test-Path -LiteralPath (Join-Path $ServerDir 'Pal')) -or (Test-Path -LiteralPath (Join-Path $ServerDir 'CommandCenter')))) {
    if (Test-Path -LiteralPath 'C:\palworld-server\Pal') { $ServerDir = 'C:\palworld-server' }
    elseif (-not $ServerDir) { $ServerDir = 'C:\palworld-server' }
}
$IniPath     = Join-Path $ServerDir 'Pal\Saved\Config\WindowsServer\PalWorldSettings.ini'
$BackupDir   = Join-Path $ServerDir 'settings-backups'
$ChangeLog   = Join-Path $ServerDir 'settings-changes-log.txt'
$StartScript = Join-Path $ServerDir 'StartServer.bat'
$WelcomeFile   = Join-Path $ServerDir 'welcome-message.txt'
$WelcomeScript = Join-Path $ServerDir 'WelcomeMessage.ps1'
$DefaultWelcome = 'Welcome {name}! Have fun out there.'
$KeepBackups = 30

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------- The Command Center look ----------------
# CommandCenter\service\ui holds the night scene, the icons and VPalUi.cs (the custom-drawn controls). VPalUi.cs is
# compiled once with the C# compiler that comes with Windows, and the result is kept in CommandCenter\data\ui.
$UiDir = Join-Path $ServerDir 'CommandCenter\service\ui'
function Import-VPalUi {
    if ('VPalUi.Theme' -as [type]) { return }
    $code = [System.IO.File]::ReadAllText((Join-Path $UiDir 'VPalUi.cs'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($code + '|' + [string][Environment]::Version))
    $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
    $cacheDir = Join-Path $ServerDir 'CommandCenter\data\ui'
    $dll = Join-Path $cacheDir ('VPalUi-' + $hash + '.dll')
    $refs = @('System.Windows.Forms', 'System.Drawing')
    if (Test-Path -LiteralPath $dll) {
        try { Add-Type -Path $dll; return } catch { }
    }
    try {
        [void](New-Item -ItemType Directory -Force -Path $cacheDir)
        Add-Type -TypeDefinition $code -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library
        if (-not ('VPalUi.Theme' -as [type])) { Add-Type -Path $dll }
        Get-ChildItem -LiteralPath $cacheDir -Filter 'VPalUi-*.dll' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $dll } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        # the cache folder can't be written: build it in memory instead
        if (-not ('VPalUi.Theme' -as [type])) { Add-Type -TypeDefinition $code -ReferencedAssemblies $refs }
    }
}
try {
    Import-VPalUi
    [VPalUi.Theme]::LoadAssets($UiDir)
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show(("VPal couldn't load its look from CommandCenter\service\ui.`r`n`r`n" + $_.Exception.Message +
        "`r`n`r`nDownload VPal-Setup.exe from VPal's GitHub page and run it again to repair it. Your server and settings stay as they are."),
        'VPal Server Command Center', 'OK', 'Error')
    exit 1
}

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:IniEncoding = New-Object System.Text.UTF8Encoding($false)
$script:Rows  = New-Object System.Collections.Generic.List[object]
$script:Model = $null
$script:Defaults = @{}
$script:ServerTitle = 'Palworld'
$script:PlayersOnline = $null
$script:PlayerTick = 0
$script:Busy  = $false
$script:StartRequestedAt = $null
$script:LastSeenRunning  = $null

# ---------------- Settings catalog ----------------
# Type: Float, Int, Bool, Enum, Text, Raw.  -Locked = shown but not editable.
$Catalog = New-Object System.Collections.Generic.List[object]
function Add-Setting {
    param(
        [string]$Key, [string]$Tab, [string]$Type, [string]$Label, [string]$Desc,
        [double]$Min = 0, [double]$Max = 100,
        [string[]]$Options = @(),
        [switch]$Locked, [switch]$Mask
    )
    $Catalog.Add([pscustomobject]@{
        Key = $Key; Tab = $Tab; Type = $Type; Label = $Label; Desc = $Desc
        Min = $Min; Max = $Max; Options = $Options; Locked = [bool]$Locked; Mask = [bool]$Mask
    })
}

$TabNames = @('Progression', 'Resources', 'Base', 'Survival', 'Combat', 'World',
              'Offline and Guilds', 'Players and Travel', 'PvP', 'Performance', 'Server')

# Progression
Add-Setting 'ExpRate' 'Progression' 'Float' 'XP rate' 'XP multiplier for players and Pals. 1 is normal. The level cap stays at 80.' 0.1 100
Add-Setting 'PalCaptureRate' 'Progression' 'Float' 'Capture rate' 'Chance a Pal Sphere catches its target. Higher means fewer wasted spheres.' 0.1 10
Add-Setting 'PalEggDefaultHatchingTime' 'Progression' 'Float' 'Egg hatch time (hours)' 'Hours for a Huge Egg to hatch; smaller eggs scale down from it. 0 is near instant, default is 72.' 0 240
Add-Setting 'bAllowEnhanceStat_Health' 'Progression' 'Bool' 'Stat points: HP' 'Lets players spend stat points on HP.'
Add-Setting 'bAllowEnhanceStat_Attack' 'Progression' 'Bool' 'Stat points: Attack' 'Lets players spend stat points on Attack.'
Add-Setting 'bAllowEnhanceStat_Stamina' 'Progression' 'Bool' 'Stat points: Stamina' 'Lets players spend stat points on Stamina.'
Add-Setting 'bAllowEnhanceStat_Weight' 'Progression' 'Bool' 'Stat points: Carry weight' 'Lets players spend stat points on Carry Weight.'
Add-Setting 'bAllowEnhanceStat_WorkSpeed' 'Progression' 'Bool' 'Stat points: Work speed' 'Lets players spend stat points on Work Speed, which speeds up your own building and crafting.'

# Resources
Add-Setting 'CollectionDropRate' 'Resources' 'Float' 'Gathering amount' 'Size of each batch from trees, rocks and ore nodes. Does not change base pits.' 0.1 100
Add-Setting 'CollectionObjectHpRate' 'Resources' 'Float' 'Tree and rock HP' 'Lower breaks them in fewer hits but gives less in total. Keep at 1.' 0.1 10
Add-Setting 'CollectionObjectRespawnSpeedRate' 'Resources' 'Float' 'Tree and rock respawn' 'How quickly harvested trees and rocks come back. Guides disagree on which way is faster, so leave at 1.' 0.1 10
Add-Setting 'EnemyDropItemRate' 'Resources' 'Float' 'Enemy loot' 'Loot from defeated Pals and enemies. Higher gives more.' 0.1 100

# Base
Add-Setting 'WorkSpeedRate' 'Base' 'Float' 'Base work speed' 'Speed of pits, crafting, building and cooking. Each cycle finishes faster; the amount per cycle stays the same.' 0.1 100
Add-Setting 'MonsterFarmActionSpeedRate' 'Base' 'Float' 'Ranch speed' 'How fast Ranch Pals produce eggs, wool and milk.' 0.1 100
Add-Setting 'BaseCampWorkerMaxNum' 'Base' 'Int' 'Pals per base' 'Most Pals that can work at one base. Max 50. More Pals means more lag.' 1 50
Add-Setting 'BaseCampMaxNumInGuild' 'Base' 'Int' 'Bases per guild' 'How many bases each guild can have. Max 10. More bases means more load.' 1 10
Add-Setting 'BaseCampMaxNum' 'Base' 'Int' 'Bases on the whole server' 'Total bases allowed across the server. Leave as is.' 1 1000
Add-Setting 'MaxBuildingLimitNum' 'Base' 'Int' 'Structure cap' 'How many structures each player can build. 0 means unlimited.' 0 100000
Add-Setting 'MaxBuildingLimitNumPerPlayer' 'Base' 'Int' 'Structure cap (second)' 'A second per-player structure cap. 0 means unlimited.' 0 100000
Add-Setting 'BuildObjectHpRate' 'Base' 'Float' 'Building HP' 'Higher makes buildings sturdier.' 0.1 10
Add-Setting 'BuildObjectDamageRate' 'Base' 'Float' 'Building damage taken' 'Lower means buildings take less damage.' 0 10
Add-Setting 'BuildObjectDeteriorationDamageRate' 'Base' 'Float' 'Building decay' 'How fast buildings decay. 0 turns decay off.' 0 10
Add-Setting 'bBuildAreaLimit' 'Base' 'Bool' 'Restrict building areas' 'On blocks building near fast-travel points and other key spots.'
Add-Setting 'bAllowEnemyCampSpawnNearBaseCamp' 'Base' 'Bool' 'Enemy camps near bases' 'Lets enemy camps spawn near your bases. Keep off.'
Add-Setting 'bEnableBuildingPlayerUIdDisplay' 'Base' 'Bool' 'Show builder ID' 'Shows the builder player ID on structures. Cosmetic only.'

# Survival
Add-Setting 'PlayerStomachDecreaceRate' 'Survival' 'Float' 'Player hunger' 'How fast you get hungry. Lower means slower. 1 is normal.' 0 5
Add-Setting 'PalStomachDecreaceRate' 'Survival' 'Float' 'Pal hunger' 'How fast Pals get hungry. Lower means slower, and fed Pals keep their sanity up.' 0 5
Add-Setting 'PlayerStaminaDecreaceRate' 'Survival' 'Float' 'Player stamina drain' 'Sprinting, climbing and swimming. Lower makes stamina last longer.' 0 5
Add-Setting 'PalStaminaDecreaceRate' 'Survival' 'Float' 'Mount stamina drain' 'Flying and riding. Lower means longer flights and rides.' 0 5
Add-Setting 'PlayerAutoHPRegeneRate' 'Survival' 'Float' 'Player healing' 'Your natural healing. Higher heals faster.' 0 10
Add-Setting 'PlayerAutoHpRegeneRateInSleep' 'Survival' 'Float' 'Player healing while asleep' 'Your healing while sleeping. Higher heals faster.' 0 10
Add-Setting 'PalAutoHPRegeneRate' 'Survival' 'Float' 'Pal healing' 'Pals natural healing. Higher heals faster.' 0 10
Add-Setting 'PalAutoHpRegeneRateInSleep' 'Survival' 'Float' 'Pal healing in Palbox' 'Pals healing while resting in the Palbox. Higher heals faster.' 0 10
Add-Setting 'ItemWeightRate' 'Survival' 'Float' 'Item weight' 'Lower lets you carry more. 0 is weightless.' 0 5
Add-Setting 'EquipmentDurabilityDamageRate' 'Survival' 'Float' 'Gear wear' 'How fast gear wears out. Lower makes it last longer.' 0 5
Add-Setting 'ItemCorruptionMultiplier' 'Survival' 'Float' 'Food spoiling' 'How fast food spoils. Lower means slower.' 0 5
Add-Setting 'FishingDifficultyRate' 'Survival' 'Float' 'Fishing difficulty' 'From 0.1 to 1.0. Lower makes fishing easier.' 0.1 1
Add-Setting 'DayTimeSpeedRate' 'Survival' 'Float' 'Day speed' 'How fast daytime passes. Higher means shorter days.' 0.1 10
Add-Setting 'NightTimeSpeedRate' 'Survival' 'Float' 'Night speed' 'How fast nighttime passes. Higher means shorter nights.' 0.1 10

# Combat
Add-Setting 'PlayerDamageRateAttack' 'Combat' 'Float' 'Player damage dealt' 'Higher means players hit harder.' 0.1 10
Add-Setting 'PlayerDamageRateDefense' 'Combat' 'Float' 'Player damage taken' 'Lower means players take less damage.' 0.1 10
Add-Setting 'PalDamageRateAttack' 'Combat' 'Float' 'Pal damage dealt' 'Higher means Pals hit harder.' 0.1 10
Add-Setting 'PalDamageRateDefense' 'Combat' 'Float' 'Pal damage taken' 'Lower makes Pals tougher.' 0.1 10
Add-Setting 'DeathPenalty' 'Combat' 'Enum' 'Death penalty' 'None drops nothing. Item drops items but not gear. ItemAndEquipment drops everything. All also drops your team Pals.' -Options 'None', 'Item', 'ItemAndEquipment', 'All'
Add-Setting 'bPalLost' 'Combat' 'Bool' 'Lose Pals on death' 'Permanently lose Pals when you die. Keep off.'
Add-Setting 'BlockRespawnTime' 'Combat' 'Float' 'Respawn wait (seconds)' 'Seconds before you can respawn after dying.' 0 600
Add-Setting 'RespawnPenaltyTimeScale' 'Combat' 'Float' 'Repeat-death penalty' 'Multiplies the respawn wait after repeated deaths.' 1 10
Add-Setting 'RespawnPenaltyDurationThreshold' 'Combat' 'Float' 'Penalty time window (seconds)' 'Survival time that decides when the repeat-death penalty applies. Leave at 0.' 0 100000
Add-Setting 'bHardcore' 'Combat' 'Bool' 'Hardcore' 'No respawning at all after death.'
Add-Setting 'bCharacterRecreateInHardcore' 'Combat' 'Bool' 'Hardcore: new character' 'In Hardcore, lets a dead player make a new character.'
Add-Setting 'bEnableFriendlyFire' 'Combat' 'Bool' 'Friendly fire' 'Lets teammates damage each other. Keep off.'

# World
Add-Setting 'PalSpawnNumRate' 'World' 'Float' 'Wild Pal spawns' 'How many wild Pals spawn, bosses included. 2 gives the boss pairs. Higher means more hitching while flying.' 0.1 3
Add-Setting 'EnablePredatorBossPal' 'World' 'Bool' 'Predator bosses' 'Rampaging red-eyed bosses can replace normal spawns anywhere.'
Add-Setting 'bEnableInvaderEnemy' 'World' 'Bool' 'Base raids' 'Enemies attack your bases now and then.'
Add-Setting 'SupplyDropSpan' 'World' 'Int' 'Supply drop interval (minutes)' 'Minutes between meteorite and supply drops. Lower means more often.' 1 1440
Add-Setting 'RandomizerType' 'World' 'Enum' 'Pal randomizer' 'Shuffles which Pals spawn where. None keeps the normal world.' -Options 'None', 'Region', 'All'
Add-Setting 'RandomizerSeed' 'World' 'Text' 'Randomizer seed' 'Seed used by the randomizer. Only matters if the randomizer is on.'
Add-Setting 'bIsRandomizerPalLevelRandom' 'World' 'Bool' 'Random Pal levels' 'Fully random wild Pal levels when the randomizer is on.'
Add-Setting 'Difficulty' 'World' 'Raw' 'Difficulty preset' 'Old preset. Leave at None; your individual settings decide difficulty.' -Locked

# Offline and Guilds
Add-Setting 'bExistPlayerAfterLogout' 'Offline and Guilds' 'Bool' 'Stay in world after logout' 'Your character sleeps in place, which keeps that base area active. Log off at your base.'
Add-Setting 'bEnableNonLoginPenalty' 'Offline and Guilds' 'Bool' 'Offline penalty' 'Penalties for offline players. May do nothing in version 1.0.'
Add-Setting 'bAutoResetGuildNoOnlinePlayers' 'Offline and Guilds' 'Bool' 'Auto-delete inactive guilds' 'DELETES a guild bases and base Pals if no member logs in for a while. Keep off!'
Add-Setting 'AutoResetGuildTimeNoOnlinePlayers' 'Offline and Guilds' 'Float' 'Hours before auto-delete' 'Only matters if auto-delete is on.' 1 10000
Add-Setting 'GuildPlayerMaxNum' 'Offline and Guilds' 'Int' 'Players per guild' 'Most players in one guild.' 1 100
Add-Setting 'GuildRejoinCooldownMinutes' 'Offline and Guilds' 'Int' 'Guild rejoin wait (minutes)' 'Wait before rejoining a guild after leaving. 0 means no wait.' 0 100000
Add-Setting 'AutoTransferMasterThresholdDays' 'Offline and Guilds' 'Int' 'Inactive leader days' 'Appears to be the days a guild leader can be inactive before leadership passes on.' 1 365
Add-Setting 'AutoTransferMasterCheckIntervalSeconds' 'Offline and Guilds' 'Float' 'Leader check interval (seconds)' 'How often the server checks for an inactive guild leader. Leave as is.' 60 100000
Add-Setting 'MaxGuildsPerFrame' 'Offline and Guilds' 'Int' 'Guilds processed at once' 'Technical. Leave as is.' 1 100

# Players and Travel
Add-Setting 'ServerPlayerMaxNum' 'Players and Travel' 'Int' 'Max players online' 'Most players on the server at once. Max 32.' 1 32
Add-Setting 'bEnableFastTravel' 'Players and Travel' 'Bool' 'Fast travel' 'Turns fast travel on or off.'
Add-Setting 'bEnableFastTravelOnlyBaseCamp' 'Players and Travel' 'Bool' 'Fast travel: bases only' 'Limits fast travel to trips between bases.'
Add-Setting 'bIsStartLocationSelectByMap' 'Players and Travel' 'Bool' 'Pick start location' 'Lets new players choose where they start.'
Add-Setting 'bShowPlayerList' 'Players and Travel' 'Bool' 'Player list in menu' 'Shows who is online in the pause menu.'
Add-Setting 'bIsShowJoinLeftMessage' 'Players and Travel' 'Bool' 'Join and leave messages' 'Shows a message when players join or leave.'
Add-Setting 'ChatPostLimitPerMinute' 'Players and Travel' 'Int' 'Chat limit per minute' 'Chat messages each player can send per minute.' 1 1000
Add-Setting 'bEnableVoiceChat' 'Players and Travel' 'Bool' 'In-game voice chat' 'PlayStation party chat is separate and not affected.'
Add-Setting 'VoiceChatMaxVolumeDistance' 'Players and Travel' 'Float' 'Voice full-volume distance' 'Only matters if in-game voice chat is on.' 0 100000
Add-Setting 'VoiceChatZeroVolumeDistance' 'Players and Travel' 'Float' 'Voice fade-out distance' 'Only matters if in-game voice chat is on.' 0 100000
Add-Setting 'bEnableAimAssistPad' 'Players and Travel' 'Bool' 'Controller aim assist' 'Aim assist for controllers.'
Add-Setting 'bEnableAimAssistKeyboard' 'Players and Travel' 'Bool' 'Keyboard aim assist' 'Aim assist for keyboard and mouse. Does not matter on consoles.'
Add-Setting 'bAllowGlobalPalboxExport' 'Players and Travel' 'Bool' 'Global Palbox: save' 'Lets players save Pals to the Global Palbox.'
Add-Setting 'bAllowGlobalPalboxImport' 'Players and Travel' 'Bool' 'Global Palbox: load' 'Lets players bring Pals in from other worlds. Off keeps everyone starting fresh.'
Add-Setting 'bAllowClientMod' 'Players and Travel' 'Bool' 'Allow modded PC players' 'Does not matter on consoles.'

# PvP
Add-Setting 'bIsPvP' 'PvP' 'Bool' 'PvP' 'Turns PvP on. The next two must be on as well. Trial feature: turns off missions, and rival guilds can open your chests.'
Add-Setting 'bEnablePlayerToPlayerDamage' 'PvP' 'Bool' 'Player vs player damage' 'Players can damage each other.'
Add-Setting 'bEnableDefenseOtherGuildPlayer' 'PvP' 'Bool' 'Base Pals defend' 'Base Pals attack players from other guilds.'
Add-Setting 'bCanPickupOtherGuildDeathPenaltyDrop' 'PvP' 'Bool' 'Loot rival drops' 'Rivals can grab what you drop on death.'
Add-Setting 'bInvisibleOtherGuildBaseCampAreaFX' 'PvP' 'Bool' 'Rival base borders' 'Controls whether other guilds base borders are shown.'
Add-Setting 'bAdditionalDropItemWhenPlayerKillingInPvPMode' 'PvP' 'Bool' 'Champion emblem drops' 'Killing a player drops a Champion Emblem, for scorekeeping.'
Add-Setting 'AdditionalDropItemWhenPlayerKillingInPvPMode' 'PvP' 'Raw' 'Emblem item' 'Which item drops for that.' -Locked
Add-Setting 'AdditionalDropItemNumWhenPlayerKillingInPvPMode' 'PvP' 'Int' 'Emblems per kill' 'How many emblems drop.' 1 100
Add-Setting 'bDisplayPvPItemNumOnWorldMap_BaseCamp' 'PvP' 'Bool' 'Map: base emblem counts' 'Shows each base emblem count on the map.'
Add-Setting 'bDisplayPvPItemNumOnWorldMap_Player' 'PvP' 'Bool' 'Map: player locations' 'Shows player locations and emblem counts on the map.'

# Performance
Add-Setting 'DropItemMaxNum' 'Performance' 'Int' 'Max loose items' 'Most items allowed on the ground; the oldest are cleaned up first.' 100 10000
Add-Setting 'PhysicsActiveDropItemMaxNum' 'Performance' 'Int' 'Items with physics' 'Loose items that bounce and roll. -1 means unlimited. Lower is lighter.' -1 10000
Add-Setting 'DropItemAliveMaxHours' 'Performance' 'Float' 'Ground item lifetime (hours)' 'Hours before an item left on the ground disappears. 0.25 is 15 minutes.' 0.05 24
Add-Setting 'ServerReplicatePawnCullDistance' 'Performance' 'Float' 'Pal tracking distance' 'How far around each player Pals are sent to consoles (5000 to 15000). Lower means less to draw.' 5000 15000
Add-Setting 'AutoSaveSpan' 'Performance' 'Float' 'Autosave interval (seconds)' 'Seconds between autosaves. Leave as is.' 10 600
Add-Setting 'bIsUseBackupSaveData' 'Performance' 'Bool' 'World backups' 'Rolling world backups. Keep on.'
Add-Setting 'ItemContainerForceMarkDirtyInterval' 'Performance' 'Float' 'Chest refresh (seconds)' 'Seconds between chest refreshes while one is open. Leave as is.' 0.1 10
Add-Setting 'PlayerDataPalStorageUpdateCheckTickInterval' 'Performance' 'Float' 'Palbox data check' 'Technical. Leave as is.' 0.1 10
Add-Setting 'BuildingNameDisplayCacheTTLSeconds' 'Performance' 'Int' 'Building name cache' 'Technical. Leave as is.' 1 3600
Add-Setting 'bActiveUNKO' 'Performance' 'Bool' 'Pal droppings' 'Pal droppings feature. Leave off.'
Add-Setting 'DropItemMaxNum_UNKO' 'Performance' 'Int' 'Max Pal droppings' 'Only matters if Pal droppings are on.' 0 1000

# Server
Add-Setting 'ServerName' 'Server' 'Text' 'Server name' 'Name your friends search for in Community Servers.'
Add-Setting 'ServerDescription' 'Server' 'Text' 'Server description' 'Shown when players select your server. No double quote marks.'
Add-Setting 'ServerPassword' 'Server' 'Text' 'Join password' 'Password friends enter to join. Everyone needs the new one if you change it.'
Add-Setting 'AdminPassword' 'Server' 'Raw' 'Admin password' 'Locked: StopServer, the restarts and the welcome message all use it.' -Locked -Mask
Add-Setting 'CrossplayPlatforms' 'Server' 'Raw' 'Crossplay platforms' 'Locked: PS5 and Xbox must stay in it.' -Locked
Add-Setting 'PublicPort' 'Server' 'Raw' 'Public port' 'Locked: must match the port forwarding on your router.' -Locked
Add-Setting 'PublicIP' 'Server' 'Raw' 'Public IP' 'Locked: blank means detect automatically.' -Locked
Add-Setting 'RESTAPIEnabled' 'Server' 'Raw' 'REST API' 'Locked: StopServer, the restarts, the welcome message and this editor need it.' -Locked
Add-Setting 'RESTAPIPort' 'Server' 'Raw' 'REST API port' 'Locked: never port-forward this one.' -Locked
Add-Setting 'RCONEnabled' 'Server' 'Raw' 'RCON' 'Locked: older remote admin tool, not used.' -Locked
Add-Setting 'RCONPort' 'Server' 'Raw' 'RCON port' 'Locked: not used.' -Locked
Add-Setting 'bUseAuth' 'Server' 'Raw' 'Server authentication' 'Locked.' -Locked
Add-Setting 'BanListURL' 'Server' 'Raw' 'Ban list' 'Locked: Pocketpair ban list.' -Locked
Add-Setting 'Region' 'Server' 'Raw' 'Region' 'Locked.' -Locked
Add-Setting 'LogFormatType' 'Server' 'Raw' 'Log format' 'Locked.' -Locked
Add-Setting 'bIsMultiplay' 'Server' 'Raw' 'Co-op switch' 'Locked: not used by a dedicated server.' -Locked
Add-Setting 'CoopPlayerMaxNum' 'Server' 'Raw' 'Co-op party size' 'Locked: not used by a dedicated server.' -Locked
Add-Setting 'DenyTechnologyList' 'Server' 'Raw' 'Blocked technologies' 'Locked: list of tech that cannot be unlocked.' -Locked

# ---------------- File reading and writing ----------------
function Split-Options([string]$inner) {
    # Splits the OptionSettings list on commas, ignoring commas inside quotes or parentheses.
    $items = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQuote = $false
    $depth = 0
    foreach ($ch in $inner.ToCharArray()) {
        if ($ch -eq [char]'"') { $inQuote = -not $inQuote }
        elseif (-not $inQuote -and $ch -eq [char]'(') { $depth++ }
        elseif (-not $inQuote -and $ch -eq [char]')') { $depth-- }

        if ($ch -eq [char]',' -and -not $inQuote -and $depth -eq 0) {
            $items.Add($sb.ToString())
            [void]$sb.Clear()
        }
        else {
            [void]$sb.Append($ch)
        }
    }
    $items.Add($sb.ToString())
    return ,$items
}

function ConvertFrom-IniText([string]$text) {
    $m = [regex]::Match($text, '(?m)^OptionSettings=\((.*)\)[ \t\r]*$')
    if (-not $m.Success) { return $null }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($part in (Split-Options $m.Groups[1].Value)) {
        $eq = $part.IndexOf('=')
        if ($eq -lt 0) {
            $items.Add([pscustomobject]@{ Key = $part; Value = $null })
        }
        else {
            $items.Add([pscustomobject]@{ Key = $part.Substring(0, $eq); Value = $part.Substring($eq + 1) })
        }
    }
    return [pscustomobject]@{ Text = $text; Match = $m; Items = $items }
}

function ConvertTo-IniText($model, [hashtable]$changes) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($it in $model.Items) {
        if ($null -eq $it.Value) { $parts.Add($it.Key) }
        elseif ($changes.ContainsKey($it.Key)) { $parts.Add($it.Key + '=' + $changes[$it.Key]) }
        else { $parts.Add($it.Key + '=' + $it.Value) }
    }
    $g = $model.Match.Groups[1]
    return $model.Text.Substring(0, $g.Index) + ($parts -join ',') + $model.Text.Substring($g.Index + $g.Length)
}

function Read-IniModel {
    if (-not (Test-Path -LiteralPath $IniPath)) { throw "Settings file not found:`n$IniPath" }
    $bytes = [System.IO.File]::ReadAllBytes($IniPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $script:IniEncoding = New-Object System.Text.UTF8Encoding($true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $script:IniEncoding = New-Object System.Text.UnicodeEncoding($false, $true)
    }
    else {
        $script:IniEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    $text = [System.IO.File]::ReadAllText($IniPath)
    $model = ConvertFrom-IniText $text
    if ($null -eq $model) { throw "Could not find the OptionSettings line in:`n$IniPath" }
    $rebuilt = ConvertTo-IniText $model @{}
    if ($rebuilt -cne $text) { throw 'The settings file has a layout this editor cannot safely rewrite, so it will not touch it.' }
    return $model
}

function Get-ValueTable($model) {
    $values = @{}
    foreach ($it in $model.Items) {
        if ($null -ne $it.Value -and -not $values.ContainsKey($it.Key)) { $values[$it.Key] = $it.Value }
    }
    return $values
}

function Get-Decimal([string]$s) {
    $d = [decimal]0
    if ([decimal]::TryParse($s.Trim(), [System.Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
    return $null
}

function Get-Places([string]$s) {
    $i = $s.IndexOf('.')
    if ($i -lt 0) { return 0 }
    return $s.Substring($i + 1).Trim().TrimEnd('0').Length
}

function Test-ServerRunning {
    return [bool](Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue)
}

function Test-ServerStarting {
    # True right after Start is clicked, or while StartServer is updating the game through SteamCMD.
    if ($null -ne $script:StartRequestedAt -and ((Get-Date) - $script:StartRequestedAt).TotalMinutes -lt 3) { return $true }
    return [bool](Get-Process -Name 'steamcmd' -ErrorAction SilentlyContinue)
}

function Test-AutoRestartRunning {
    # True while a scheduled restart script (RestartServer.ps1) is in the middle of its work.
    try {
        $p = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
             Where-Object { $_.CommandLine -like '*RestartServer.ps1*' }
        return [bool]$p
    }
    catch { return $false }
}

# ---------------- Small UI helpers ----------------
function Show-Message([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'VPal Server Command Center', 'OK', $Icon)
}

function Confirm-Action([string]$Text) {
    $r = [System.Windows.Forms.MessageBox]::Show($Text, 'VPal Server Command Center', 'YesNo', 'Question')
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Wait-UI([int]$Milliseconds) {
    $end = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

$FontMain     = New-Object System.Drawing.Font('Segoe UI', 9)
$FontBold     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$FontSmall    = New-Object System.Drawing.Font('Segoe UI', 8.25)
$FontName     = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$FontDesc     = New-Object System.Drawing.Font('Segoe UI', 9.5)
$ColorChanged = [VPalUi.Theme]::Orange
$ColorNormal  = [VPalUi.Theme]::Text
$ColorDesc    = [VPalUi.Theme]::Muted
$ColorLocked  = [VPalUi.Theme]::Faint
$ColorOn       = [VPalUi.Theme]::Green
$ColorStarting = [VPalUi.Theme]::Gold
$ColorOff      = [VPalUi.Theme]::Red
$ColorClear    = [System.Drawing.Color]::Transparent

# ---------------- Row logic ----------------
function Get-RowNewRaw($row) {
    switch ($row.Kind) {
        'Float' { return ([decimal]$row.Control.Value).ToString('0.000000', $Inv) }
        'Int'   { return ([decimal]$row.Control.Value).ToString('0', $Inv) }
        'Bool'  {
            if ($row.Control.Checked) { return 'True' }
            else { return 'False' }
        }
        'Enum'  { return [string]$row.Control.SelectedItem }
        'Text'  {
            if ($row.Quoted) { return '"' + $row.Control.Text + '"' }
            else { return $row.Control.Text }
        }
    }
    return $row.OrigRaw
}

function Test-RowChanged($row) {
    switch ($row.Kind) {
        'Float' { return ([decimal]$row.Control.Value -ne [decimal]$row.OrigValue) }
        'Int'   { return ([decimal]$row.Control.Value -ne [decimal]$row.OrigValue) }
        'Bool'  { return ((Get-RowNewRaw $row) -ine $row.OrigRaw) }
        'Enum'  { return ((Get-RowNewRaw $row) -ine $row.OrigRaw) }
        'Text'  { return ((Get-RowNewRaw $row) -cne $row.OrigRaw) }
    }
    return $false
}

function Get-ChangeCount {
    $n = 0
    foreach ($r in $script:Rows) { if (Test-RowChanged $r) { $n++ } }
    return $n
}

function Update-ChangeCount {
    $n = Get-ChangeCount
    if ($n -eq 0) {
        $lblChanges.Text = 'No unsaved changes'
        $lblChanges.ForeColor = $ColorDesc
    }
    elseif ($n -eq 1) {
        $lblChanges.Text = '1 unsaved change'
        $lblChanges.ForeColor = $ColorChanged
    }
    else {
        $lblChanges.Text = "$n unsaved changes"
        $lblChanges.ForeColor = $ColorChanged
    }
    if ($null -ne $chgDot) {
        if ($n -eq 0) { $chgDot.DotColor = [VPalUi.Theme]::Faint } else { $chgDot.DotColor = $ColorChanged }
    }
}

function Update-RowLook($row) {
    $changed = Test-RowChanged $row
    if ($changed) { $row.NameLabel.ForeColor = $ColorChanged }
    elseif ($row.Kind -eq 'Raw') { $row.NameLabel.ForeColor = $ColorLocked }
    else { $row.NameLabel.ForeColor = $ColorNormal }
    if ($null -ne $row.Badge) { $row.Badge.Visible = $changed }
    if ($null -ne $row.Stepper) { $row.Stepper.Changed = $changed }
    Update-ChangeCount
}

# ---------------- Pages ----------------
# Sidebar group, icon, sidebar name and the line under the title, for every page.
$PageInfo = @{
    'Progression'        = @{ Icon = 'progression'; Sub = 'Level up, catch and hatch at your pace.' }
    'Resources'          = @{ Icon = 'resources';   Sub = 'How much you gather and loot.' }
    'Base'               = @{ Icon = 'base';        Sub = 'Bases, building limits and how fast your Pals work.' }
    'Survival'           = @{ Icon = 'survival';    Sub = 'Hunger, stamina, healing, weight and the day and night.' }
    'Combat'             = @{ Icon = 'combat';      Sub = 'Damage, death penalties and respawning.' }
    'World'              = @{ Icon = 'world';       Sub = 'Wild Pals, bosses, raids and supply drops.' }
    'Offline and Guilds' = @{ Icon = 'guilds';      Sub = 'What happens while people are away, and guild rules.'; Nav = 'Offline & Guilds' }
    'Players and Travel' = @{ Icon = 'travel';      Sub = 'Player limits, fast travel, chat and voice.'; Nav = 'Players & Travel' }
    'PvP'                = @{ Icon = 'pvp';         Sub = 'Player-versus-player rules.' }
    'Performance'        = @{ Icon = 'performance'; Sub = 'Keeps the server smooth: loose items, autosaves and cleanup.' }
    'Server'             = @{ Icon = 'server';      Sub = 'Name, passwords and connection settings.' }
    'Other'              = @{ Icon = 'other';       Sub = 'Settings in your file that this editor does not explain yet.' }
    'Watchdog'           = @{ Icon = 'watchdog';    Sub = 'Keeps your world running, backed up and up to date.'; Order = 0 }
    'Players'            = @{ Icon = 'players';     Sub = 'Who is online, who has played, kicks, bans and the whitelist.'; Order = 1 }
    'Backups'            = @{ Icon = 'backups';     Sub = 'World backups, and restoring one safely.'; Order = 2 }
    'Messages'           = @{ Icon = 'messages';    Sub = 'The welcome message, and announcements to everyone online.'; Order = 3 }
    'Discord'            = @{ Icon = 'discord';     Sub = 'Alerts and slash commands in your Discord server.'; Order = 4 }
    'Pal Planner'        = @{ Icon = 'planner';     Sub = 'Your players'' own private Pal website.'; Order = 5 }
}

# Camp notes: a few true, useful things about each settings page (icon: info, peak or warn).
$CampNotes = @{
    'Progression'        = @(@('info', 'XP rate changes how fast both players and Pals level up.'),
                             @('peak', 'The level cap stays at 80, whatever the XP rate.'))
    'Resources'          = @(@('info', 'Gathering amount changes trees, rocks and ore nodes, not base pits.'),
                             @('peak', 'Tree and rock HP and respawn are best left at 1.'))
    'Base'               = @(@('info', 'Base work speed makes each cycle finish sooner; the amount per cycle stays the same.'),
                             @('peak', 'More Pals per base means more lag. The most is 50.'))
    'Survival'           = @(@('info', 'Day speed and night speed: higher means shorter days or nights.'),
                             @('info', 'Item weight at 0 makes everything weightless.'))
    'Combat'             = @(@('info', 'Death penalty None drops nothing. All also drops the Pals in your team.'),
                             @('warn', 'Lose Pals on death and Friendly fire are best kept off for family servers.'))
    'World'              = @(@('info', 'Wild Pal spawns at 2 doubles up the bosses, with more hitching while flying.'),
                             @('peak', 'Leave the difficulty preset at None. Your own settings decide.'))
    'Offline and Guilds' = @(@('warn', 'Auto-delete inactive guilds deletes bases and base Pals. Keep it off.'),
                             @('info', 'Log off at your base: your character sleeps where it is.'))
    'Players and Travel' = @(@('info', 'Up to 32 players can be online at once.'),
                             @('info', 'PlayStation party chat is separate from the in-game voice chat setting.'))
    'PvP'                = @(@('warn', 'PvP turns off missions, and rival guilds can open your chests.'),
                             @('info', 'PvP needs Player vs player damage and Base Pals defend on as well.'))
    'Performance'        = @(@('info', 'A lower Pal tracking distance gives consoles less to draw.'),
                             @('peak', 'Keep World backups on.'))
    'Server'             = @(@('warn', 'Never forward port 8212 (the REST API) on your router.'),
                             @('info', 'Locked settings are ones VPal''s restarts and messages depend on.'))
}

# Colorful icon for each setting (art in CommandCenter\service\ui\icons), and one per page for the rest.
$SettingIcons = @{
    ExpRate = 'star'; PalCaptureRate = 'target'; PalEggDefaultHatchingTime = 'egg'
    bAllowEnhanceStat_Health = 'heart'; bAllowEnhanceStat_Attack = 'sword'; bAllowEnhanceStat_Stamina = 'bolt'
    bAllowEnhanceStat_Weight = 'backpack'; bAllowEnhanceStat_WorkSpeed = 'hammer'
    CollectionDropRate = 'tree'; CollectionObjectHpRate = 'rock'; CollectionObjectRespawnSpeedRate = 'leaf'; EnemyDropItemRate = 'bag'
    WorkSpeedRate = 'gear'; MonsterFarmActionSpeedRate = 'barn'; BaseCampWorkerMaxNum = 'paw'; BaseCampMaxNumInGuild = 'house'
    BaseCampMaxNum = 'house'; MaxBuildingLimitNum = 'box'; MaxBuildingLimitNumPerPlayer = 'box'; BuildObjectHpRate = 'castle'
    BuildObjectDamageRate = 'shield'; BuildObjectDeteriorationDamageRate = 'hourglass'; bBuildAreaLimit = 'map'
    bAllowEnemyCampSpawnNearBaseCamp = 'tent'; bEnableBuildingPlayerUIdDisplay = 'eye'
    PlayerStomachDecreaceRate = 'drumstick'; PalStomachDecreaceRate = 'drumstick'; PlayerStaminaDecreaceRate = 'bolt'
    PalStaminaDecreaceRate = 'bolt'; PlayerAutoHPRegeneRate = 'heal'; PlayerAutoHpRegeneRateInSleep = 'zzz'
    PalAutoHPRegeneRate = 'heal'; PalAutoHpRegeneRateInSleep = 'zzz'; ItemWeightRate = 'backpack'
    EquipmentDurabilityDamageRate = 'wrench'; ItemCorruptionMultiplier = 'hourglass'; FishingDifficultyRate = 'fish'
    DayTimeSpeedRate = 'sun'; NightTimeSpeedRate = 'moon'
    PlayerDamageRateAttack = 'sword'; PlayerDamageRateDefense = 'shield'; PalDamageRateAttack = 'swords'; PalDamageRateDefense = 'shield'
    DeathPenalty = 'skull'; bPalLost = 'skull'; BlockRespawnTime = 'clock'; RespawnPenaltyTimeScale = 'hourglass'
    RespawnPenaltyDurationThreshold = 'clock'; bHardcore = 'skull'; bCharacterRecreateInHardcore = 'people'; bEnableFriendlyFire = 'swords'
    PalSpawnNumRate = 'paw'; EnablePredatorBossPal = 'flame'; bEnableInvaderEnemy = 'castle'; SupplyDropSpan = 'box'
    RandomizerType = 'dice'; RandomizerSeed = 'dice'; bIsRandomizerPalLevelRandom = 'dice'; Difficulty = 'gauge'
    bExistPlayerAfterLogout = 'zzz'; bEnableNonLoginPenalty = 'hourglass'; bAutoResetGuildNoOnlinePlayers = 'ban'
    AutoResetGuildTimeNoOnlinePlayers = 'clock'; GuildPlayerMaxNum = 'people'; GuildRejoinCooldownMinutes = 'clock'
    AutoTransferMasterThresholdDays = 'crown'; AutoTransferMasterCheckIntervalSeconds = 'crown'; MaxGuildsPerFrame = 'gauge'
    ServerPlayerMaxNum = 'people'; bEnableFastTravel = 'map'; bEnableFastTravelOnlyBaseCamp = 'house'; bIsStartLocationSelectByMap = 'compass'
    bShowPlayerList = 'people'; bIsShowJoinLeftMessage = 'chat'; ChatPostLimitPerMinute = 'chat'; bEnableVoiceChat = 'mic'
    VoiceChatMaxVolumeDistance = 'mic'; VoiceChatZeroVolumeDistance = 'mic'; bEnableAimAssistPad = 'target'; bEnableAimAssistKeyboard = 'target'
    bAllowGlobalPalboxExport = 'save'; bAllowGlobalPalboxImport = 'save'; bAllowClientMod = 'code'
    bIsPvP = 'swords'; bEnablePlayerToPlayerDamage = 'sword'; bEnableDefenseOtherGuildPlayer = 'shield'
    bCanPickupOtherGuildDeathPenaltyDrop = 'bag'; bInvisibleOtherGuildBaseCampAreaFX = 'eye'
    bAdditionalDropItemWhenPlayerKillingInPvPMode = 'emblem'; AdditionalDropItemWhenPlayerKillingInPvPMode = 'emblem'
    AdditionalDropItemNumWhenPlayerKillingInPvPMode = 'emblem'; bDisplayPvPItemNumOnWorldMap_BaseCamp = 'map'; bDisplayPvPItemNumOnWorldMap_Player = 'map'
    DropItemMaxNum = 'box'; PhysicsActiveDropItemMaxNum = 'box'; DropItemAliveMaxHours = 'hourglass'; ServerReplicatePawnCullDistance = 'eye'
    AutoSaveSpan = 'save'; bIsUseBackupSaveData = 'save'; ItemContainerForceMarkDirtyInterval = 'chest'
    PlayerDataPalStorageUpdateCheckTickInterval = 'gauge'; BuildingNameDisplayCacheTTLSeconds = 'gauge'; bActiveUNKO = 'poop'; DropItemMaxNum_UNKO = 'poop'
    ServerName = 'server'; ServerDescription = 'chat'; ServerPassword = 'key'; AdminPassword = 'key'; CrossplayPlatforms = 'globe'
    PublicPort = 'plug'; PublicIP = 'plug'; RESTAPIEnabled = 'code'; RESTAPIPort = 'plug'; RCONEnabled = 'code'; RCONPort = 'plug'
    bUseAuth = 'lock'; BanListURL = 'ban'; Region = 'globe'; LogFormatType = 'code'; bIsMultiplay = 'people'; CoopPlayerMaxNum = 'people'
    DenyTechnologyList = 'ban'
}
$TabIcons = @{
    'Progression' = 'star'; 'Resources' = 'gem'; 'Base' = 'house'; 'Survival' = 'drumstick'; 'Combat' = 'sword'; 'World' = 'globe'
    'Offline and Guilds' = 'flag'; 'Players and Travel' = 'compass'; 'PvP' = 'swords'; 'Performance' = 'gauge'; 'Server' = 'server'
}

function New-VPage([string]$Title, [string]$Group) {
    $page = New-Object VPalUi.Page
    $page.Text = $Title
    $page.Group = $Group
    $i = $PageInfo[$Title]
    if ($null -ne $i) {
        $page.IconKey = $i.Icon
        $page.Subtitle = $i.Sub
        if ($i.Nav) { $page.NavText = $i.Nav }
        if ($null -ne $i.Order) { $page.Order = [int]$i.Order }
    }
    else { $page.IconKey = 'other' }
    return $page
}

function New-TintedIcon([string]$Name, $Color, [int]$Size) {
    # an icon recolored for the dark look, in a PictureBox
    $bm = New-Object System.Drawing.Bitmap(($Size * 2), ($Size * 2))
    $g = [System.Drawing.Graphics]::FromImage($bm)
    try { [VPalUi.Theme]::DrawTinted($g, [VPalUi.Theme]::Icon($Name), (New-Object System.Drawing.Rectangle(0, 0, ($Size * 2), ($Size * 2))), $Color) }
    finally { $g.Dispose() }
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Size = New-Object System.Drawing.Size($Size, $Size)
    $pb.SizeMode = 'Zoom'
    $pb.Image = $bm
    $pb.BackColor = $ColorClear
    return $pb
}

function New-CampNotes([string]$Title) {
    $notes = New-Object VPalUi.Card
    $notes.Glass = $true
    $notes.Dock = 'Right'
    $notes.Width = 300
    $notes.Text = 'Camp notes'
    $notes.TitleIcon = [VPalUi.Theme]::Icon('set_star')
    $notes.TitleFont = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $notes.TitleHeight = 40
    $notes.BackColor = $ColorClear
    $notes.Padding = New-Object System.Windows.Forms.Padding(14, 50, 14, 14)

    $art = New-Object System.Windows.Forms.PictureBox
    $art.Image = [VPalUi.Theme]::Icon('campnotes')
    $art.SizeMode = 'Zoom'
    $art.Dock = 'Top'
    $art.Height = 136
    $art.BackColor = $ColorClear

    $tips = New-Object System.Windows.Forms.FlowLayoutPanel
    $tips.FlowDirection = 'TopDown'
    $tips.WrapContents = $false
    $tips.Dock = 'Fill'
    $tips.BackColor = $ColorClear
    $tips.Padding = New-Object System.Windows.Forms.Padding(0, 16, 0, 0)
    $list = New-Object System.Collections.Generic.List[object]
    if ($CampNotes.ContainsKey($Title)) { foreach ($t in $CampNotes[$Title]) { $list.Add($t) } }
    $list.Add(@('rocket', 'Changes apply when the server restarts. Save & restart does it now.'))
    foreach ($t in $list) {
        $line = New-Object System.Windows.Forms.FlowLayoutPanel
        $line.AutoSize = $true
        $line.WrapContents = $false
        $line.BackColor = $ColorClear
        $line.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
        $color = [VPalUi.Theme]::TealSoft
        $icon = 'ui_' + $t[0]
        if ($t[0] -eq 'peak') { $color = [VPalUi.Theme]::Gold }
        if ($t[0] -eq 'warn') { $color = [VPalUi.Theme]::Orange; $icon = 'ui_info' }
        $ic = New-TintedIcon $icon $color 20
        $ic.Margin = New-Object System.Windows.Forms.Padding(0, 1, 10, 0)
        $tl = New-Object System.Windows.Forms.Label
        $tl.AutoSize = $true
        $tl.UseMnemonic = $false
        $tl.MaximumSize = New-Object System.Drawing.Size(226, 0)
        $tl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $tl.ForeColor = [VPalUi.Theme]::Text
        $tl.BackColor = $ColorClear
        $tl.Text = $t[1]
        $line.Controls.Add($ic)
        $line.Controls.Add($tl)
        $tips.Controls.Add($line)
    }
    $notes.Controls.Add($art)
    $notes.Controls.Add($tips)
    $tips.BringToFront()
    return $notes
}

# Setting rows: icon | name, Changed badge and description | stepper, switch, list or box | unit and default
$ColIcon = 56
$ColCtl = 176
$ColExtra = 128

function New-TabTable([string]$title) {
    $page = New-VPage $title 'World settings'
    [void]$page.MakeHeader('World settings')

    $body = New-Object VPalUi.BackdropPanel
    $body.Tint = $page.Tint
    $body.Dock = 'Fill'
    $body.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)

    $card = New-Object VPalUi.Card
    $card.Dock = 'Fill'
    $card.Padding = New-Object System.Windows.Forms.Padding(2, 4, 2, 4)
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'
    $scroll.AutoScroll = $true
    $scroll.BackColor = [VPalUi.Theme]::Card
    [VPalUi.Theme]::DarkScrollbars($scroll)
    $card.Controls.Add($scroll)

    $table = New-Object VPalUi.RowTable          # draws the line under each row itself
    $table.ColumnCount = 4
    $table.RowCount = 0
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $ColIcon)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $ColCtl)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $ColExtra)))
    $table.AutoSize = $true
    $table.AutoSizeMode = 'GrowAndShrink'
    $table.Dock = 'Top'
    $table.BackColor = [VPalUi.Theme]::Card
    $scroll.Controls.Add($table)
    $scroll.Tag = $table
    $scroll.add_Resize({ param($s, $e) Update-RowWidths $s })

    $notes = New-CampNotes $title
    $gap = New-Object System.Windows.Forms.Panel
    $gap.Dock = 'Right'
    $gap.Width = 16
    $gap.BackColor = $ColorClear
    $body.Controls.Add($card)
    $body.Controls.Add($gap)
    $body.Controls.Add($notes)
    $card.BringToFront()
    $body.Tag = @{ Notes = $notes; Gap = $gap }
    $body.add_Resize({
        param($s, $e)
        # Camp notes only when there is room for them
        $wide = $s.ClientSize.Width -ge 900
        if ($s.Tag.Notes.Visible -ne $wide) { $s.Tag.Notes.Visible = $wide; $s.Tag.Gap.Visible = $wide }
    })
    $page.Controls.Add($body)
    $body.BringToFront()
    $page.Tag = $table
    $tabs.TabPages.Add($page)
    return $table
}

function Update-RowWidths($scroll) {
    # the descriptions wrap to the width the window leaves them
    $table = $scroll.Tag
    if ($null -eq $table) { return }
    $w = [Math]::Max(200, $scroll.ClientSize.Width - $ColIcon - $ColCtl - $ColExtra - 36)
    if ($table.Tag -eq $w) { return }
    $table.Tag = $w
    $table.SuspendLayout()
    foreach ($row in $script:Rows) {
        if ($row.Table -eq $table) {
            $row.DescLabel.MaximumSize = New-Object System.Drawing.Size($w, 0)
        }
    }
    $table.ResumeLayout()
}

function Get-SettingIcon($meta) {
    $n = $SettingIcons[$meta.Key]
    if (-not $n) { $n = $TabIcons[$meta.Tab] }
    if (-not $n) { $n = 'gear' }
    return [VPalUi.Theme]::Icon('set_' + $n)
}

function Format-Default([string]$Kind, [string]$Raw) {
    switch ($Kind) {
        'Float' { $d = Get-Decimal $Raw; if ($null -ne $d) { return $d.ToString('0.0##', $Inv) } }
        'Int'   { $d = Get-Decimal $Raw; if ($null -ne $d) { return $d.ToString('0', $Inv) } }
        'Bool'  { if ($Raw.Trim() -ieq 'True') { return 'On' } else { return 'Off' } }
        'Enum'  { return $Raw.Trim() }
    }
    return ''
}

function Set-RowDefault($row) {
    # "Default: ..." was clicked: put that setting back to Palworld's default (not saved until Save)
    $d = [string]$row.Default
    switch ($row.Kind) {
        'Float' { $v = Get-Decimal $d; if ($null -ne $v) { $row.Control.Value = [Math]::Max($row.Control.Minimum, [Math]::Min($row.Control.Maximum, $v)) } }
        'Int'   { $v = Get-Decimal $d; if ($null -ne $v) { $row.Control.Value = [Math]::Max($row.Control.Minimum, [Math]::Min($row.Control.Maximum, $v)) } }
        'Bool'  { $row.Control.Checked = ($d.Trim() -ieq 'True') }
        'Enum'  { foreach ($o in @($row.Control.Items)) { if ([string]$o -ieq $d.Trim()) { $row.Control.SelectedItem = $o } } }
    }
}

function New-Row($table, $meta, [string]$raw) {
    $kind = $meta.Type
    if ($meta.Locked) { $kind = 'Raw' }
    $origValue = $null
    $quoted = $false
    $shown = $raw

    if ($kind -eq 'Float' -or $kind -eq 'Int') {
        $origValue = Get-Decimal $raw
        if ($null -eq $origValue) { $kind = 'Raw' }
        elseif ($kind -eq 'Int' -and $raw.Contains('.')) { $kind = 'Float' }
    }
    if ($kind -eq 'Text' -or $kind -eq 'Raw') {
        if ($raw.Length -ge 2 -and $raw.StartsWith('"') -and $raw.EndsWith('"')) {
            $quoted = $true
            $shown = $raw.Substring(1, $raw.Length - 2)
        }
        if ($kind -eq 'Text' -and $shown.Contains('"')) { $kind = 'Raw' }
    }

    $inputFont = New-Object System.Drawing.Font('Segoe UI', 10)
    $stepper = $null
    switch ($kind) {
        'Float' {
            $c = New-Object System.Windows.Forms.NumericUpDown
            $c.DecimalPlaces = [Math]::Min(6, [Math]::Max(2, (Get-Places $raw)))
            $min = [decimal]$meta.Min
            $max = [decimal]$meta.Max
            if ($origValue -lt $min) { $min = $origValue }
            if ($origValue -gt $max) { $max = $origValue }
            $c.Maximum = $max
            $c.Minimum = $min
            if ($meta.Max -le 10) { $c.Increment = [decimal]0.05 }
            elseif ($meta.Max -le 100) { $c.Increment = [decimal]0.5 }
            elseif ($meta.Max -le 1000) { $c.Increment = [decimal]1 }
            else { $c.Increment = [decimal]100 }
            $c.Value = $origValue
            $stepper = New-Object VPalUi.Stepper -ArgumentList @($c, 158)
        }
        'Int' {
            $c = New-Object System.Windows.Forms.NumericUpDown
            $c.DecimalPlaces = 0
            $min = [decimal]$meta.Min
            $max = [decimal]$meta.Max
            if ($origValue -lt $min) { $min = $origValue }
            if ($origValue -gt $max) { $max = $origValue }
            $c.Maximum = $max
            $c.Minimum = $min
            if ($meta.Max -gt 2000) { $c.Increment = [decimal]100 } else { $c.Increment = [decimal]1 }
            $c.Value = $origValue
            $stepper = New-Object VPalUi.Stepper -ArgumentList @($c, 158)
        }
        'Bool' {
            $c = New-Object VPalUi.Toggle
            $c.Checked = ($raw.Trim() -ieq 'True')
            if ($c.Checked) { $c.Text = 'On' } else { $c.Text = 'Off' }
        }
        'Enum' {
            $c = New-Object System.Windows.Forms.ComboBox
            $c.DropDownStyle = 'DropDownList'
            $c.FlatStyle = 'Flat'
            $c.BackColor = [VPalUi.Theme]::Card2
            $c.ForeColor = [VPalUi.Theme]::Text
            $c.Font = $inputFont
            $c.Width = 158
            $selected = $null
            foreach ($o in $meta.Options) {
                [void]$c.Items.Add($o)
                if ($o -ieq $raw) { $selected = $o }
            }
            if ($null -eq $selected) {
                [void]$c.Items.Add($raw)
                $selected = $raw
            }
            $c.SelectedItem = $selected
        }
        'Text' {
            $c = New-Object System.Windows.Forms.TextBox
            $c.Width = 290
            $c.Font = $inputFont
            $c.BorderStyle = 'FixedSingle'
            $c.BackColor = [VPalUi.Theme]::Card2
            $c.ForeColor = [VPalUi.Theme]::Text
            $c.Text = $shown
        }
        default {
            $kind = 'Raw'
            $c = New-Object System.Windows.Forms.TextBox
            $c.Width = 290
            $c.Font = $inputFont
            $c.BorderStyle = 'FixedSingle'
            $c.ReadOnly = $true
            $c.BackColor = [VPalUi.Theme]::Card3
            $c.ForeColor = [VPalUi.Theme]::Muted
            $c.Text = $shown
            if ($meta.Mask) { $c.UseSystemPasswordChar = $true }
        }
    }
    $holder = $c
    if ($null -ne $stepper) { $holder = $stepper }
    $holder.Anchor = 'Left'
    $holder.Margin = New-Object System.Windows.Forms.Padding(6, 12, 6, 12)

    $icon = New-Object System.Windows.Forms.PictureBox
    $icon.Image = Get-SettingIcon $meta
    $icon.SizeMode = 'Zoom'
    $icon.Size = New-Object System.Drawing.Size(34, 34)
    $icon.BackColor = [VPalUi.Theme]::Card
    $icon.Anchor = 'Left'
    $icon.Margin = New-Object System.Windows.Forms.Padding(14, 10, 4, 10)

    $label = [string]$meta.Label
    $unit = ''
    if ($label -match '^(.*?)\s*\((hours|minutes|seconds)\)$') { $label = $Matches[1]; $unit = $Matches[2] }

    $info = New-Object System.Windows.Forms.FlowLayoutPanel
    $info.FlowDirection = 'TopDown'
    $info.WrapContents = $false
    $info.AutoSize = $true
    $info.BackColor = [VPalUi.Theme]::Card
    $info.Anchor = 'Left'
    $info.Margin = New-Object System.Windows.Forms.Padding(6, 10, 6, 10)

    $nameLine = New-Object System.Windows.Forms.FlowLayoutPanel
    $nameLine.AutoSize = $true
    $nameLine.WrapContents = $false
    $nameLine.BackColor = [VPalUi.Theme]::Card
    $nameLine.Margin = New-Object System.Windows.Forms.Padding(0)

    $name = New-Object System.Windows.Forms.Label
    $name.AutoSize = $true
    $name.UseMnemonic = $false
    $name.Font = $FontName
    $name.ForeColor = $ColorNormal
    $name.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
    $name.Text = $label
    $nameLine.Controls.Add($name)

    $badge = New-Object VPalUi.Badge
    $badge.Text = 'Changed'
    $badge.Visible = $false
    $nameLine.Controls.Add($badge)
    if ($kind -eq 'Raw') {
        $name.ForeColor = $ColorLocked
        $lock = New-Object VPalUi.Badge
        $lock.Text = 'Locked'
        $lock.Fill = [VPalUi.Theme]::Card3
        $lock.BorderColor = [VPalUi.Theme]::Border
        $lock.TextColor = [VPalUi.Theme]::Muted
        $nameLine.Controls.Add($lock)
    }

    $desc = New-Object System.Windows.Forms.Label
    $desc.AutoSize = $true
    $desc.UseMnemonic = $false
    $desc.MaximumSize = New-Object System.Drawing.Size(360, 0)
    $desc.Font = $FontDesc
    $desc.ForeColor = $ColorDesc
    $desc.Text = $meta.Desc
    $info.Controls.Add($nameLine)
    $info.Controls.Add($desc)
    $ToolTip.SetToolTip($name, 'In the settings file: ' + $meta.Key)
    $ToolTip.SetToolTip($desc, 'In the settings file: ' + $meta.Key)

    $defRaw = $null
    if ($script:Defaults.ContainsKey($meta.Key) -and ($kind -eq 'Float' -or $kind -eq 'Int' -or $kind -eq 'Bool' -or $kind -eq 'Enum')) {
        $defRaw = [string]$script:Defaults[$meta.Key]
        if ($kind -eq 'Enum' -or $kind -eq 'Bool') { $defRaw = $defRaw.Trim().Trim('"') }
    }
    $extra = New-Object System.Windows.Forms.FlowLayoutPanel
    $extra.FlowDirection = 'TopDown'
    $extra.WrapContents = $false
    $extra.AutoSize = $true
    $extra.BackColor = [VPalUi.Theme]::Card
    $extra.Anchor = 'Left'
    $extra.Margin = New-Object System.Windows.Forms.Padding(14, 10, 4, 10)
    if ($unit) {
        $ub = New-Object VPalUi.Badge
        $ub.Text = $unit
        $ub.Fill = [VPalUi.Theme]::Card3
        $ub.BorderColor = [VPalUi.Theme]::Border
        $ub.TextColor = [VPalUi.Theme]::Text
        $ub.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
        $extra.Controls.Add($ub)
    }
    $defLabel = $null
    $defText = ''
    if ($null -ne $defRaw) { $defText = Format-Default $kind $defRaw }
    if ($defText) {
        $defLabel = New-Object System.Windows.Forms.Label
        $defLabel.AutoSize = $true
        $defLabel.UseMnemonic = $false
        $defLabel.Font = $FontDesc
        $defLabel.ForeColor = $ColorDesc
        $defLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
        $defLabel.Margin = New-Object System.Windows.Forms.Padding(0)
        $defLabel.Text = 'Default: ' + $defText
        $ToolTip.SetToolTip($defLabel, "Palworld's default. Click to use it (saved when you click Save).")
        $extra.Controls.Add($defLabel)
    }

    $r = $table.RowCount
    $table.RowCount = $r + 1
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $table.Controls.Add($icon, 0, $r)
    $table.Controls.Add($info, 1, $r)
    $table.Controls.Add($holder, 2, $r)
    if ($kind -eq 'Text' -or $kind -eq 'Raw') { $table.SetColumnSpan($holder, 2) }
    else { $table.Controls.Add($extra, 3, $r) }
    $ToolTip.SetToolTip($c, $meta.Desc)

    $row = [pscustomobject]@{
        Key = $meta.Key; Meta = $meta; Kind = $kind; Control = $c; NameLabel = $name; DescLabel = $desc
        Badge = $badge; Stepper = $stepper; Table = $table; Default = $defRaw
        OrigRaw = $raw; OrigValue = $origValue; Quoted = $quoted
    }
    $c.Tag = $row
    if ($null -ne $defLabel) {
        $defLabel.Tag = $row
        $defLabel.add_Click({ param($s, $e) try { Set-RowDefault $s.Tag } catch { } })
    }
    switch ($kind) {
        'Float' { $c.add_ValueChanged({ param($s, $e) Update-RowLook $s.Tag }) }
        'Int'   { $c.add_ValueChanged({ param($s, $e) Update-RowLook $s.Tag }) }
        'Bool'  {
            $c.add_CheckedChanged({
                param($s, $e)
                if ($s.Checked) { $s.Text = 'On' } else { $s.Text = 'Off' }
                Update-RowLook $s.Tag
            })
        }
        'Enum'  { $c.add_SelectedIndexChanged({ param($s, $e) Update-RowLook $s.Tag }) }
        'Text'  { $c.add_TextChanged({ param($s, $e) Update-RowLook $s.Tag }) }
    }
    $script:Rows.Add($row)
}

function Build-Editor {
    $selected = $tabs.SelectedIndex
    $script:Model = Read-IniModel
    $values = Get-ValueTable $script:Model
    $script:ServerTitle = 'Palworld'
    if ($values.ContainsKey('ServerName')) { $script:ServerTitle = $values['ServerName'].Trim('"') }
    $script:Defaults = @{}
    try {
        # Palworld's own defaults, shown next to each setting
        $dp = Join-Path $ServerDir 'DefaultPalWorldSettings.ini'
        if (Test-Path -LiteralPath $dp) {
            $dm = ConvertFrom-IniText ([System.IO.File]::ReadAllText($dp))
            if ($null -ne $dm) { $script:Defaults = Get-ValueTable $dm }
        }
    }
    catch { }

    $tabs.SuspendLayout()
    $script:Rows.Clear()
    foreach ($p in @($tabs.TabPages)) { $tabs.TabPages.Remove($p); $p.Dispose() }

    $tables = @{}
    foreach ($tn in $TabNames) { $tables[$tn] = New-TabTable $tn }
    $known = @{}
    foreach ($meta in $Catalog) {
        $known[$meta.Key] = $true
        if ($values.ContainsKey($meta.Key)) { New-Row $tables[$meta.Tab] $meta $values[$meta.Key] }
    }

    $others = @($script:Model.Items | Where-Object { $null -ne $_.Value -and $_.Key -ne '' -and -not $known.ContainsKey($_.Key) })
    if ($others.Count -gt 0) {
        $t = New-TabTable 'Other'
        foreach ($it in $others) {
            $meta = [pscustomobject]@{
                Key = $it.Key; Tab = 'Other'; Type = 'Raw'; Label = $it.Key
                Desc = 'Not in this editor list, so it is shown for reference only.'
                Min = 0; Max = 0; Options = @(); Locked = $true; Mask = $false
            }
            New-Row $t $meta $it.Value
        }
    }

    foreach ($p in @($tabs.TabPages)) {
        if ($p.Tag -is [System.Windows.Forms.TableLayoutPanel]) {
            $n = $p.Tag.RowCount
            if ($n -eq 0) { $tabs.TabPages.Remove($p); $p.Dispose() }
            elseif ($n -eq 1) { $p.Header.Chip = '1 setting' }
            else { $p.Header.Chip = "$n settings" }
        }
    }
    New-MessagesTab
    New-PlannerTab
    New-PlayersTab
    New-BackupsTab
    New-WatchdogTab
    New-DiscordTab
    $tabs.ResumeLayout()
    if ($selected -ge 0 -and $selected -lt $tabs.TabPages.Count) { $tabs.SelectedIndex = $selected }
    $tabs.WarmUp()            # prepares the other pages in the background, so switching to them is instant

    $serverName = 'Palworld'
    if ($values.ContainsKey('ServerName')) { $serverName = $values['ServerName'].Trim('"') }
    $form.Text = 'VPal Server Command Center - ' + $serverName
    Update-ChangeCount
    try { Update-SelectedTab } catch { }
}

# ---------------- Save and restart ----------------
function Set-Status([string]$Text) {
    if ($null -eq $lblStatus) { return }          # the setup wizard runs before the main window exists
    $lblStatus.Text = $Text
    if ($null -ne $ToolTip) { $ToolTip.SetToolTip($lblStatus, $Text) }
    $lblStatus.Refresh()
}

function Set-Busy([bool]$On) {
    $script:Busy = $On
    foreach ($b in @($btnSave, $btnRestart, $btnUndo, $btnClose, $btnBackups, $btnStart, $btnStop, $btnHealth)) { if ($null -ne $b) { $b.Enabled = -not $On } }
    $tabs.Enabled = -not $On
    if ($null -ne $nav) { $nav.Enabled = -not $On }
    if ($On) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Update-ServerStatus
    }
}

function Update-ServerStatus {
    $running = Test-ServerRunning
    if ($running) {
        $script:LastSeenRunning = Get-Date
        $script:StartRequestedAt = $null
    }
    $starting = (-not $running) -and (Test-ServerStarting)

    if ($null -eq $status) { return }
    $status.ServerName = [string]$script:ServerTitle
    if ($running) {
        $status.State = 'Running'
        $status.StateColor = $ColorOn
    }
    elseif ($starting) {
        $status.State = 'Starting...'
        $status.StateColor = $ColorStarting
    }
    else {
        $status.State = 'Off'
        $status.StateColor = $ColorOff
    }

    # Players online, from the watchdog every 15 seconds while the server runs
    $script:PlayerTick = $script:PlayerTick + 1
    if (-not $running) { $script:PlayersOnline = $null }
    elseif (($script:PlayerTick % 3) -eq 1) {
        try {
            if (Test-CommandCenter) {
                $st = Invoke-CC 'status' $null 3
                if ($null -ne $st.players) { $script:PlayersOnline = [int]$st.players }
            }
        }
        catch { }
    }
    if ($null -eq $script:PlayersOnline) { $status.Players = '' }
    elseif ($script:PlayersOnline -eq 1) { $status.Players = '1 player online' }
    else { $status.Players = [string]$script:PlayersOnline + ' players online' }

    # Start only when fully off; Stop only when running. Only one of them shows.
    $btnStart.Visible = -not $running
    $btnStop.Visible = $running
    if (-not $script:Busy) {
        $btnStart.Enabled = (-not $running) -and (-not $starting)
        $btnStop.Enabled = $running
    }
}

function Save-Settings([switch]$Quiet) {
    $changes = @{}
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($row in $script:Rows) {
        if (-not (Test-RowChanged $row)) { continue }
        if ($row.Kind -eq 'Text') {
            $t = $row.Control.Text
            if ($t.Contains('"')) { $problems.Add($row.Meta.Label + ': remove the double quote (") marks.') }
            if ($row.Key -eq 'ServerName' -and [string]::IsNullOrWhiteSpace($t)) { $problems.Add('Server name cannot be blank.') }
        }
        $changes[$row.Key] = Get-RowNewRaw $row
    }
    if ($problems.Count -gt 0) {
        Show-Message ("Nothing was saved. Please fix:`n`n- " + ($problems -join "`n- ")) 'Warning'
        return $false
    }
    if ($changes.Count -eq 0) {
        if (-not $Quiet) { Show-Message 'There are no changes to save.' }
        return $true
    }

    # Re-read the file right before writing, so only the changed settings are touched.
    $fresh = Read-IniModel
    $old = Get-ValueTable $fresh
    foreach ($k in @($changes.Keys)) {
        if (-not $old.ContainsKey($k)) {
            Show-Message "$k is no longer in the settings file, so nothing was saved. Click Undo changes to reload." 'Warning'
            return $false
        }
    }
    $newText = ConvertTo-IniText $fresh $changes

    # Safety check: the new file must parse the same way, with every change in place.
    $check = ConvertFrom-IniText $newText
    if ($null -eq $check -or $check.Items.Count -ne $fresh.Items.Count) {
        Show-Message 'Safety check failed, so nothing was saved.' 'Error'
        return $false
    }
    foreach ($it in $check.Items) {
        if ($changes.ContainsKey($it.Key) -and $it.Value -cne $changes[$it.Key]) {
            Show-Message "Safety check failed on $($it.Key), so nothing was saved." 'Error'
            return $false
        }
    }

    # Backup, then write.
    [void](New-Item -ItemType Directory -Force -Path $BackupDir)
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    Copy-Item -LiteralPath $IniPath -Destination (Join-Path $BackupDir ('PalWorldSettings_' + $stamp + '.ini')) -Force
    Get-ChildItem -LiteralPath $BackupDir -Filter 'PalWorldSettings_*.ini' |
        Sort-Object Name -Descending | Select-Object -Skip $KeepBackups | Remove-Item -Force
    [System.IO.File]::WriteAllText($IniPath, $newText, $script:IniEncoding)

    $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = foreach ($k in ($changes.Keys | Sort-Object)) {
        if ($k -like '*Password*') { "$when  $k changed" }
        else { "$when  $k : $($old[$k]) -> $($changes[$k])" }
    }
    Add-Content -LiteralPath $ChangeLog -Value $lines -Encoding UTF8

    $count = $changes.Count
    $null = Build-Editor
    Set-Status ("Saved $count change(s) at " + (Get-Date -Format 'h:mm tt') + '. A backup of the old file is in settings-backups.')
    if (-not $Quiet) {
        Show-Message ("Saved $count change(s).`n`nThe server uses the new values after its next restart. " +
                      'To apply them now, click Save and restart server.')
    }
    return $true
}

function Get-ApiInfo {
    # Builds the local REST address and login from the settings file. $null if the REST API is off.
    $values = Get-ValueTable $script:Model
    if (([string]$values['RESTAPIEnabled']).Trim() -ine 'True') { return $null }
    $pw = ([string]$values['AdminPassword']).Trim().Trim('"')
    $port = ([string]$values['RESTAPIPort']).Trim()
    if ([string]::IsNullOrEmpty($port)) { $port = '8212' }
    $auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('admin:' + $pw)) }
    return @{ Url = "http://127.0.0.1:$port/v1/api"; Auth = $auth }
}

function Stop-PalServer([string]$Message) {
    # Saves the world, shuts down with a 30-second warning, and waits until the server is fully closed.
    if (-not (Test-ServerRunning)) { return $true }
    $api = Get-ApiInfo
    if ($null -eq $api) {
        Show-Message 'RESTAPIEnabled is off, so the editor cannot stop the server safely. Use StopServer instead.' 'Warning'
        return $false
    }

    Set-CCHold 'stopped from the control panel'
    Set-Status 'Saving the world...'
    try { Invoke-RestMethod -Uri ($api.Url + '/save') -Method Post -Headers $api.Auth -ContentType 'application/json' -Body '{}' -TimeoutSec 30 | Out-Null } catch { }
    Wait-UI 3000

    Set-Status 'Shutting down the server (players get a 30-second warning)...'
    $body = @{ waittime = 30; message = $Message } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri ($api.Url + '/shutdown') -Method Post -Headers $api.Auth -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
    }
    catch {
        Clear-CCHold
        Show-Message ("Could not reach the server to shut it down, so nothing was changed.`n`n" +
                      $_.Exception.Message + "`n`nUse StopServer instead.") 'Warning'
        return $false
    }

    $deadline = (Get-Date).AddMinutes(3)
    while (Test-ServerRunning) {
        $script:LastSeenRunning = Get-Date
        if ((Get-Date) -ge $deadline) {
            Show-Message ('The server did not close within 3 minutes. Check the server window; ' +
                          'if it is stuck, close that window yourself.') 'Warning'
            return $false
        }
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
        Set-Status "Waiting for the server to close... ($left s left)"
        Wait-UI 1000
    }
    Set-Status ('The server is off (stopped at ' + (Get-Date -Format 'h:mm tt') + ').')
    return $true
}

function Start-PalServer {
    # Starts the server through StartServer.bat (which updates first). Refuses if any copy is running or starting.
    if (Test-ServerRunning) { Show-Message 'The server is already running.'; return $false }
    if (Test-ServerStarting) { Show-Message 'The server is already starting. Give it a minute or two.'; return $false }
    if (Test-AutoRestartRunning) {
        Show-Message 'The scheduled restart is in progress and will start the server by itself.'
        return $false
    }
    # StartServer.bat (it updates the game first) when there is one, otherwise the server program itself
    $launch = $StartScript
    if (-not (Test-Path -LiteralPath $launch)) { $launch = Join-Path $ServerDir 'PalServer.exe' }
    if (-not (Test-Path -LiteralPath $launch)) { Show-Message ('Could not find StartServer.bat or PalServer.exe in ' + $ServerDir) 'Error'; return $false }

    # Give a just-closed server 30 seconds to free its ports (avoids the port 27015 errors).
    if ($null -ne $script:LastSeenRunning) {
        $wait = 30 - ((Get-Date) - $script:LastSeenRunning).TotalSeconds
        if ($wait -gt 0) {
            Set-Status 'Giving the old server a few seconds to free its ports...'
            Wait-UI ([int]($wait * 1000))
        }
    }
    if ((Test-ServerRunning) -or (Test-ServerStarting)) {
        Show-Message 'Something else already started the server, so the editor did not start another copy.'
        return $false
    }

    $script:StartRequestedAt = Get-Date
    Clear-CCHold
    Start-Process -FilePath $launch -WorkingDirectory $ServerDir
    Set-Status 'Starting the server. It checks for game updates first, then shows in Community Servers within a few minutes.'
    return $true
}

function Restart-PalServer {
    if (-not (Test-ServerRunning)) {
        if (Test-ServerStarting) {
            Show-Message 'Settings are saved. The server is already starting and will load them.'
            return
        }
        if (Confirm-Action "Settings are saved. The server is off.`n`nStart it now with the new settings?") {
            [void](Start-PalServer)
        }
        else { Set-Status 'Saved. The new settings load the next time the server starts.' }
        return
    }
    if (Test-AutoRestartRunning) {
        Show-Message 'Settings are saved. The automatic restart is in progress right now and will load them.'
        return
    }
    $ask = "Restart the server now so the new settings take effect?`n`n" +
           'Anyone online gets a 30-second warning and is disconnected for about 3 minutes.'
    if (-not (Confirm-Action $ask)) {
        Set-Status 'Saved. The new settings load at the next restart.'
        return
    }
    if (Stop-PalServer 'Server restarting to apply new settings. Back in about 3 minutes!') {
        [void](Start-PalServer)
    }
}

# ---------------- Health check ----------------
$script:DiagBox    = $null
$script:DiagIssues = $null
$script:DiagWatch  = $null
$script:DiagBusy   = $false
$ColorGood   = [VPalUi.Theme]::Green
$ColorFair   = [VPalUi.Theme]::Gold
$ColorBad    = [VPalUi.Theme]::Red
$ColorInfo   = [VPalUi.Theme]::Muted
$FontDiag    = New-Object System.Drawing.Font('Consolas', 10)
$FontDiagHd  = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)

function Add-DiagText([string]$Text, $Color, $Font) {
    $box = $script:DiagBox
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $Color
    $box.SelectionFont = $Font
    $box.AppendText($Text + "`n")
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-DiagLine([string]$Text) { Add-DiagText $Text $ColorInfo $FontDiag }

function Add-DiagHeading([string]$Text) {
    Add-DiagText '' $ColorInfo $FontDiag
    Add-DiagText $Text.ToUpper() ([VPalUi.Theme]::Text) $FontDiagHd
}

function Add-DiagResult([string]$Level, [string]$Text) {
    # Level: OK (green), FAIR (amber), BAD (red), INFO (grey)
    switch ($Level) {
        'OK'   { Add-DiagText ('  [GOOD] ' + $Text) $ColorGood $FontDiag }
        'FAIR' { Add-DiagText ('  [FAIR] ' + $Text) $ColorFair $FontDiag; $script:DiagWatch.Add($Text) }
        'BAD'  { Add-DiagText ('  [BAD ] ' + $Text) $ColorBad $FontDiag; $script:DiagIssues.Add($Text) }
        default { Add-DiagText ('  [INFO] ' + $Text) $ColorInfo $FontDiag }
    }
}

function Format-Span([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    return ('{0}m' -f [int][Math]::Floor($t.TotalMinutes))
}

function Format-When($d) {
    if ($null -eq $d) { return 'never' }
    $dt = [datetime]$d
    if ($dt.Year -lt 2000) { return 'never' }
    return $dt.ToString('ddd h:mm tt')
}

function Test-PingSeries([string]$Target, [int]$Count) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.Generic.List[double]
    $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, 1000)
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $times.Add([double]$r.RoundtripTime) }
            else { $lost++ }
        }
        catch { $lost++ }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }
    $ping.Dispose()
    $avg = 0.0
    $max = 0.0
    if ($times.Count -gt 0) {
        $avg = ($times | Measure-Object -Average).Average
        $max = ($times | Measure-Object -Maximum).Maximum
    }
    return [pscustomobject]@{
        Lost = $lost; LossPct = [int][Math]::Round(100.0 * $lost / $Count)
        Avg = [Math]::Round($avg, 1); Max = [Math]::Round($max, 0)
    }
}

function Invoke-HealthCheck {
    $script:DiagIssues = New-Object System.Collections.Generic.List[string]
    $script:DiagWatch  = New-Object System.Collections.Generic.List[string]
    $script:DiagBox.Clear()
    $now = Get-Date
    Add-DiagText ('Palworld server health check  -  ' + $now.ToString('dddd, MMM d, yyyy  h:mm tt')) ([VPalUi.Theme]::Text) $FontDiagHd
    Add-DiagLine 'Green = healthy, amber = worth watching, red = needs attention.'

    # ---- Server program ----
    Add-DiagHeading 'Server program'
    $procs = @(Get-Process -Name 'PalServer-Win64-Shipping*' -ErrorAction SilentlyContinue)
    $running = $procs.Count -gt 0
    if ($procs.Count -eq 0) {
        if (Test-ServerStarting) { Add-DiagResult 'FAIR' 'The server is starting (it updates first). Run the check again in a few minutes.' }
        else { Add-DiagResult 'BAD' 'The server is off. Click Start server.' }
    }
    elseif ($procs.Count -eq 1) {
        $p = $procs[0]
        $ram = [Math]::Round($p.WorkingSet64 / 1GB, 2)
        $upText = ''
        $upHours = 0
        try {
            $up = $now - $p.StartTime
            $upHours = $up.TotalHours
            $upText = 'up ' + (Format-Span $up) + ', '
        } catch { }
        Add-DiagResult 'OK' ("One copy running, as it should be. Server is $upText" + "using $ram GB of memory.")
        if ($ram -gt 8) { Add-DiagResult 'BAD' 'Memory use is very high. A restart will clear it.' }
        elseif ($ram -gt 4) { Add-DiagResult 'FAIR' 'Memory use is climbing. The next scheduled restart will clear it.' }
        if ($upHours -gt 13) { Add-DiagResult 'BAD' ('Running ' + [int]$upHours + ' hours without a restart, so a scheduled restart was missed. See Automatic tasks.') }
    }
    else {
        Add-DiagResult 'BAD' ("$($procs.Count) copies of the server are running at once. Close the extra server window so only one runs.")
    }

    # ---- Performance, players, loaded settings (need the REST API) ----
    $playerCount = $null
    $api = Get-ApiInfo
    if ($running -and $null -eq $api) {
        Add-DiagHeading 'Server performance'
        Add-DiagResult 'BAD' 'RESTAPIEnabled is off, so performance and player checks are not available.'
    }
    elseif ($running) {
        Add-DiagHeading 'Server performance'
        try {
            $m = Invoke-RestMethod -Uri ($api.Url + '/metrics') -Headers $api.Auth -TimeoutSec 5
            $fps = [Math]::Round([double]$m.serverfps)
            if ($fps -ge 50) { Add-DiagResult 'OK' "Running smoothly at $fps FPS (full speed is about 60)." }
            elseif ($fps -ge 30) { Add-DiagResult 'FAIR' "Running at $fps FPS, a little strained." }
            else { Add-DiagResult 'BAD' "Only $fps FPS, the server is struggling. Lower Pal spawns or Pals per base." }
            $playerCount = [int]$m.currentplayernum
            Add-DiagResult 'INFO' "Players online: $($m.currentplayernum) of $($m.maxplayernum)    In-game day: $($m.days)    Bases: $($m.basecampnum)"
        }
        catch { Add-DiagResult 'FAIR' 'Could not reach the server for performance numbers. If it just started, wait a minute and run again.' }

        Add-DiagHeading 'Players online'
        try {
            $raw = (Invoke-RestMethod -Uri ($api.Url + '/players') -Headers $api.Auth -TimeoutSec 5).players
            $pl = @($raw | Where-Object { $null -ne $_ })
            if ($pl.Count -eq 0) { Add-DiagResult 'INFO' 'Nobody is online right now.' }
            foreach ($x in $pl) {
                $ms = [int][Math]::Round([double]$x.ping)
                $line = "$($x.name)  (level $($x.level))  ping $ms ms"
                if ($ms -le 100) { Add-DiagResult 'OK' "$line - good connection" }
                elseif ($ms -le 250) { Add-DiagResult 'FAIR' "$line - a bit laggy" }
                else { Add-DiagResult 'BAD' "$line - very laggy (on their end or yours; see Connection below)" }
            }
        }
        catch { Add-DiagResult 'FAIR' 'Could not get the player list.' }

        Add-DiagHeading 'Settings loaded by the server'
        try {
            $live = Invoke-RestMethod -Uri ($api.Url + '/settings') -Headers $api.Auth -TimeoutSec 5
            $fileVals = Get-ValueTable (Read-IniModel)
            $pending = New-Object System.Collections.Generic.List[string]
            $compared = 0
            foreach ($meta in $Catalog) {
                if ($meta.Locked -or ($meta.Type -notin @('Float', 'Int', 'Bool'))) { continue }
                if (-not $fileVals.ContainsKey($meta.Key)) { continue }
                $prop = $live.PSObject.Properties[$meta.Key]
                if ($null -eq $prop) { continue }
                try {
                    $fv = ([string]$fileVals[$meta.Key]).Trim()
                    $lv = $prop.Value
                    if ($meta.Type -eq 'Bool') { $same = ([string]$lv -ieq $fv) }
                    else {
                        $fd = Get-Decimal $fv
                        if ($null -eq $fd) { continue }
                        $f = [double]$fd
                        $same = [Math]::Abs([double]$lv - $f) -le (0.0005 * [Math]::Max(1.0, [Math]::Abs($f)))
                    }
                    $compared++
                    if (-not $same) { $pending.Add("$($meta.Label): saved as $fv, server still using $lv") }
                }
                catch { continue }
            }
            if ($pending.Count -eq 0) { Add-DiagResult 'OK' "The server is using the settings in your file ($compared checked)." }
            else {
                Add-DiagResult 'FAIR' "$($pending.Count) saved change(s) are not loaded yet. They take effect at the next restart:"
                foreach ($x in $pending) { Add-DiagText ('           - ' + $x) $ColorFair $FontDiag }
            }
        }
        catch { Add-DiagResult 'FAIR' 'Could not read the settings the server is using.' }
    }

    # ---- Automatic tasks ----
    Add-DiagHeading 'Automatic tasks'
    $me = $env:USERNAME
    $hasRestartScript = Test-Path -LiteralPath (Join-Path $ServerDir 'RestartServer.ps1')
    $wcfg = $null
    try {
        $cfgPath = Join-Path $CCDir 'data\config.json'
        if (Test-Path -LiteralPath $cfgPath) { $wcfg = [System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json }
    }
    catch { }
    $taskName = 'Palworld 12-Hour Restart'
    if ($wcfg -and $null -ne $wcfg.external_restart_task) { $taskName = [string]$wcfg.external_restart_task }
    if ($hasRestartScript -and -not $taskName) { $hasRestartScript = $false }     # switched to VPal's own schedule
    if (-not $hasRestartScript) {
        if ($wcfg -and $wcfg.schedule -and $wcfg.schedule.enabled -and @($wcfg.schedule.times).Count) {
            Add-DiagResult 'OK' ('VPal restarts the server every day at ' + (Format-ScheduleTimes @($wcfg.schedule.times)) + '.')
        }
        else { Add-DiagResult 'INFO' 'No daily restarts are set. A daily restart keeps memory low (Watchdog tab, Daily restarts).' }
    }
    if ($hasRestartScript) {
        $restartTask = $null
        try { $restartTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { }
        if ($null -eq $restartTask) {
            Add-DiagResult 'INFO' ('Windows only lets an administrator view the restart task (' + $taskName + '), so this check uses the restart log below instead.')
        }
        else {
            $owner = [string]$restartTask.Principal.UserId
            $ownerShort = ($owner -split '\\')[-1]
            if ($ownerShort -and ($ownerShort -ine $me)) {
                Add-DiagResult 'BAD' "The scheduled restart runs as '$owner' but you are signed in as '$me', so it will not run."
            }
            elseif ([string]$restartTask.State -eq 'Disabled') {
                Add-DiagResult 'BAD' 'The scheduled restart task is turned off.'
            }
            else {
                $next = $null
                try { $next = ($restartTask | Get-ScheduledTaskInfo -ErrorAction Stop).NextRunTime } catch { }
                Add-DiagResult 'OK' ('The scheduled restart task is set up. Next run: ' + (Format-When $next) + '.')
            }
        }
    }

    # Welcome messages come from the watchdog, or from the older welcome helper (WelcomeMessage.ps1) where there is one.
    $wdOn = Test-CommandCenter
    if ((Get-CCWelcomeMode) -eq 'cc' -or -not (Test-Path -LiteralPath $WelcomeScript)) {
        if ($wdOn) { Add-DiagResult 'OK' 'Welcome messages are sent by the watchdog.' }
        else { Add-DiagResult 'BAD' 'Welcome messages are sent by the watchdog, which is not running. Open the Watchdog tab and click Start the watchdog.' }
    }
    else {
        # The welcome helper is checked by looking for its running program, which needs no administrator rights.
        switch (Get-WelcomeHelperState) {
            'on'       { Add-DiagResult 'OK' 'The welcome message helper is running.' }
            'old'      { Add-DiagResult 'FAIR' 'The welcome helper is running an older copy. Click Restart welcome helper on the Messages tab.' }
            'multiple' { Add-DiagResult 'BAD' 'More than one welcome helper is running, so players may get the message twice. Click Restart welcome helper on the Messages tab.' }
            default {
                if ($wdOn) { Add-DiagResult 'OK' 'Welcome messages are sent by the watchdog (the older welcome helper is not running).' }
                else { Add-DiagResult 'BAD' 'Nothing is sending welcome messages. Open the Watchdog tab and click Start the watchdog.' }
            }
        }
    }

    # ---- Restart log (only where a restart script writes one) ----
    $logPath = Join-Path $ServerDir 'restart-log.txt'
    if ($hasRestartScript) { Add-DiagHeading 'Recent automatic restarts' }
    if (-not $hasRestartScript) { }
    elseif (Test-Path -LiteralPath $logPath) {
        $tail = @(Get-Content -LiteralPath $logPath -Tail 4)
        foreach ($l in $tail) { Add-DiagLine ('         ' + $l) }
        $lastLine = $tail | Where-Object { $_.Length -ge 19 } | Select-Object -Last 1
        if ($lastLine) {
            $d = [datetime]::MinValue
            if ([datetime]::TryParseExact($lastLine.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $Inv, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
                $hours = ($now - $d).TotalHours
                if ($hours -le 13) { Add-DiagResult 'OK' ('Last automatic restart activity: ' + $d.ToString('ddd h:mm tt') + '.') }
                else { Add-DiagResult 'BAD' ('No automatic restart activity for ' + [int]$hours + ' hours.') }
            }
        }
    }
    else { Add-DiagResult 'FAIR' 'No restart log found yet.' }

    # ---- Connection ----
    Add-DiagHeading 'Connection'
    $route = $null
    try { $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1 } catch { }
    if ($null -ne $route) {
        if ([string]$route.InterfaceAlias -like '*Wi-Fi*' -or [string]$route.InterfaceAlias -like '*Wireless*') {
            Add-DiagResult 'BAD' ('The PC is using Wi-Fi (' + $route.InterfaceAlias + '). The server should use the Ethernet cable.')
        }
        else { Add-DiagResult 'OK' ('The PC is connected by cable (' + $route.InterfaceAlias + ').') }

        $gw = [string]$route.NextHop
        Add-DiagLine "         Testing your router ($gw) with 10 pings..."
        $r = Test-PingSeries $gw 10
        $txt = "PC to router: average $($r.Avg) ms, worst $($r.Max) ms, $($r.LossPct)% lost."
        if ($r.Lost -eq 0 -and $r.Avg -le 10 -and $r.Max -le 50) { Add-DiagResult 'OK' "$txt Solid." }
        elseif ($r.LossPct -le 10 -and $r.Avg -le 30) { Add-DiagResult 'FAIR' "$txt A little shaky; expect under 10 ms with no loss." }
        else { Add-DiagResult 'BAD' "$txt Unstable. Check the network cable and your router." }
    }
    else { Add-DiagResult 'BAD' 'Could not find your router. The PC may be offline.' }

    Add-DiagLine '         Testing the internet (8.8.8.8) with 10 pings...'
    $r = Test-PingSeries '8.8.8.8' 10
    $txt = "PC to internet: average $($r.Avg) ms, worst $($r.Max) ms, $($r.LossPct)% lost."
    if ($r.Lost -eq 0 -and $r.Avg -le 60 -and $r.Max -le 150) { Add-DiagResult 'OK' "$txt Good." }
    elseif ($r.LossPct -le 10 -and $r.Avg -le 120) { Add-DiagResult 'FAIR' "$txt Some spikes. Big downloads or streaming in the house can cause this." }
    else { Add-DiagResult 'BAD' "$txt Unstable. If the router test above is fine, the problem is outside the house or something is hogging bandwidth." }

    # ---- Backups and disk ----
    Add-DiagHeading 'World backups and disk space'
    $bk = Get-ChildItem -Path (Join-Path $ServerDir 'Pal\Saved\SaveGames\0\*\backup\world') -Directory -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $bk) {
        $age = $now - $bk.LastWriteTime
        $msg = 'Newest world backup: ' + (Format-Span $age) + ' ago (' + $bk.LastWriteTime.ToString('ddd h:mm tt') + ').'
        if (-not $running -or $age.TotalMinutes -le 15) { Add-DiagResult 'OK' $msg }
        elseif ($null -ne $playerCount -and $playerCount -eq 0) {
            Add-DiagResult 'INFO' ($msg + ' Normal while nobody is online; the server appears to save only while someone is playing.')
        }
        else { Add-DiagResult 'BAD' ($msg + ' Backups should be minutes old while people are playing.') }
    }
    else { Add-DiagResult 'BAD' 'No world backups found. Turn on World backups (Performance tab).' }

    try {
        $c = Get-PSDrive -Name C -ErrorAction Stop
        $free = [Math]::Round($c.Free / 1GB, 0)
        if ($free -ge 30) { Add-DiagResult 'OK' "Drive C has $free GB free." }
        elseif ($free -ge 10) { Add-DiagResult 'FAIR' "Drive C has only $free GB free." }
        else { Add-DiagResult 'BAD' "Drive C is nearly full ($free GB free). The server can corrupt saves when the disk fills up." }
    } catch { }

    # ---- Watchdog ----
    if (Test-Path -LiteralPath $CCService) {
        Add-DiagHeading 'Watchdog (runs in the background)'
        $ccs = Get-CCState
        if ($ccs -eq 'off') { Add-DiagResult 'BAD' 'Not running, so crashes and freezes are not being caught. Open the Watchdog tab and click Start the watchdog.' }
        else {
            if ($ccs -eq 'old') { Add-DiagResult 'FAIR' 'Running an older copy. It updates itself within a minute or two.' }
            try {
                $cst = Invoke-RestMethod -Uri ($CCUrl + 'api/status') -TimeoutSec 5
                if ($cst.hold) { Add-DiagResult 'FAIR' ('Running, but the watchdog is paused: ' + [string]$cst.hold.reason + '.') }
                else { Add-DiagResult 'OK' ('Running and watching the server (version ' + [string]$cst.version + ').') }
                if ($null -ne $cst.mem) {
                    $line = 'Server memory ' + [string]$cst.mem + ' GB; it restarts the server at ' + [string]$cst.memLimit + ' GB.'
                    if ($cst.forecast -and $cst.forecast.hours) { $line += ' At the current rate that is about ' + [string]$cst.forecast.hours + ' hours away.' }
                    Add-DiagResult 'INFO' $line
                }
            }
            catch { Add-DiagResult 'FAIR' 'Running, but it did not answer.' }
            # the Discord bot's checks come from the watchdog
            try {
                $hc = Invoke-CC 'health' $null 30
                foreach ($sec in @($hc.sections | Where-Object { $_ -and $_.title -eq 'Discord' })) {
                    Add-DiagHeading 'Discord bot'
                    foreach ($it in @($sec.items | Where-Object { $_ })) { Add-DiagResult ([string]$it.level).ToUpper() ([string]$it.text) }
                }
            }
            catch { }
        }
    }

    # ---- Summary ----
    Add-DiagLine ''
    if ($script:DiagIssues.Count -eq 0 -and $script:DiagWatch.Count -eq 0) {
        Add-DiagText 'SUMMARY: Everything looks healthy.' $ColorGood $FontDiagHd
    }
    elseif ($script:DiagIssues.Count -eq 0) {
        Add-DiagText ("SUMMARY: No problems. $($script:DiagWatch.Count) thing(s) worth watching (amber above).") $ColorFair $FontDiagHd
    }
    else {
        Add-DiagText ("SUMMARY: $($script:DiagIssues.Count) problem(s) need attention:") $ColorBad $FontDiagHd
        foreach ($i in $script:DiagIssues) { Add-DiagText ('  - ' + $i) $ColorBad $FontDiag }
    }
    Add-DiagLine ''
    Add-DiagLine 'Click Copy report to paste this into your chat with Claude.'
}

function Invoke-DiagRun {
    if ($script:DiagBusy) { return }
    $script:DiagBusy = $true
    $script:DiagAgainBtn.Enabled = $false
    $script:DiagCopyBtn.Enabled = $false
    $script:DiagDialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { Invoke-HealthCheck }
    catch { Add-DiagText ('The health check hit an error: ' + $_.Exception.Message) $ColorBad $FontDiag }
    finally {
        $script:DiagBusy = $false
        $script:DiagAgainBtn.Enabled = $true
        $script:DiagCopyBtn.Enabled = $true
        $script:DiagDialog.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Show-HealthCheck {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Server health check'
    $dlg.Size = New-Object System.Drawing.Size(900, 680)
    $dlg.MinimumSize = New-Object System.Drawing.Size(700, 400)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $FontMain
    $script:DiagDialog = $dlg

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.ReadOnly = $true
    $box.Dock = 'Fill'
    $box.BackColor = [VPalUi.Theme]::Card2
    $box.ForeColor = [VPalUi.Theme]::Text
    $box.Font = $FontDiag
    $box.BorderStyle = 'None'
    $box.DetectUrls = $false
    $script:DiagBox = $box

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'
    $bar.Height = 52
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Right'
    $flow.FlowDirection = 'RightToLeft'
    $flow.AutoSize = $true
    $flow.WrapContents = $false
    $flow.Padding = New-Object System.Windows.Forms.Padding(0, 10, 8, 0)
    $bClose = New-Button 'Close'
    $bCopy  = New-Button 'Copy report'
    $bAgain = New-Button 'Run again'
    $script:DiagCopyBtn = $bCopy
    $script:DiagAgainBtn = $bAgain
    foreach ($b in @($bClose, $bCopy, $bAgain)) { $flow.Controls.Add($b) }
    $bar.Controls.Add($flow)

    $bClose.add_Click({ $script:DiagDialog.Close() })
    $bAgain.add_Click({ Invoke-DiagRun })
    $bCopy.add_Click({
        try {
            if ($script:DiagBox.TextLength -gt 0) {
                [System.Windows.Forms.Clipboard]::SetText($script:DiagBox.Text)
                Show-Message 'The report is copied. Paste it into your chat with Claude.'
            }
        }
        catch { Show-Message ('Could not copy: ' + $_.Exception.Message) 'Warning' }
    })
    $dlg.add_Shown({ Invoke-DiagRun })
    $dlg.add_FormClosing({
        param($s, $e)
        if ($script:DiagBusy) { $e.Cancel = $true }
    })

    $dlg.Controls.Add($box)
    $dlg.Controls.Add($bar)
    $box.BringToFront()
    [VPalUi.Dark]::Apply($dlg)
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ---------------- Messages (welcome message and send-now) ----------------
$script:WelcomeBox       = $null
$script:BroadcastBox     = $null
$script:lblWelcomeState  = $null
$script:lblBroadcastState = $null

function Get-WelcomeText {
    try {
        if (Test-Path -LiteralPath $WelcomeFile) {
            $t = ([System.IO.File]::ReadAllText($WelcomeFile)).Trim()
            if ($t) { return $t }
        }
    }
    catch { }
    return $DefaultWelcome
}

function Get-WelcomeHelpers {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
                 Where-Object { $_.CommandLine -like '*WelcomeMessage.ps1*' })
    }
    catch { return @() }
}

function Get-WelcomeHelperState {
    # on / old (started before WelcomeMessage.ps1 was last updated) / multiple / off
    $h = @(Get-WelcomeHelpers)
    if ($h.Count -eq 0) { return 'off' }
    if ($h.Count -gt 1) { return 'multiple' }
    if (Test-Path -LiteralPath $WelcomeScript) {
        $updated = (Get-Item -LiteralPath $WelcomeScript).LastWriteTime
        if ($null -ne $h[0].CreationDate -and $h[0].CreationDate -lt $updated) { return 'old' }
    }
    return 'on'
}

function Get-CCWelcomeMode {
    # 'cc' when the watchdog sends welcome messages itself, else ''
    try {
        $p = Join-Path $CCDir 'data\config.json'
        if (Test-Path -LiteralPath $p) { return [string](([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).welcome.mode) }
    }
    catch { }
    return ''
}

function Update-WelcomeState {
    if ($null -eq $script:lblWelcomeState -or $script:lblWelcomeState.IsDisposed) { return }
    if ($script:btnRestartWelcome -and -not $script:btnRestartWelcome.IsDisposed) { $script:btnRestartWelcome.Visible = (Test-Path -LiteralPath $WelcomeScript) }
    if ((Get-CCWelcomeMode) -eq 'cc' -or -not (Test-Path -LiteralPath $WelcomeScript)) {
        $script:lblWelcomeState.Text = 'Welcome messages: sent by the watchdog (no helper needed)'
        $script:lblWelcomeState.ForeColor = $ColorOn
        return
    }
    switch (Get-WelcomeHelperState) {
        'on' {
            $script:lblWelcomeState.Text = 'Welcome helper: running'
            $script:lblWelcomeState.ForeColor = $ColorOn
        }
        'old' {
            $script:lblWelcomeState.Text = 'Welcome helper: running an older copy. Click Restart welcome helper.'
            $script:lblWelcomeState.ForeColor = $ColorStarting
        }
        'multiple' {
            $script:lblWelcomeState.Text = 'Welcome helper: more than one copy is running. Click Restart welcome helper.'
            $script:lblWelcomeState.ForeColor = $ColorStarting
        }
        default {
            $script:lblWelcomeState.Text = 'Welcome helper: not running. Click Restart welcome helper.'
            $script:lblWelcomeState.ForeColor = $ColorOff
        }
    }
}

function Restart-WelcomeHelper([switch]$ShowResult) {
    if (-not (Test-Path -LiteralPath $WelcomeScript)) {
        Show-Message ('Could not find ' + $WelcomeScript) 'Error'
        return $false
    }
    foreach ($h in @(Get-WelcomeHelpers)) {
        try { Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop } catch { }
    }
    Wait-UI 1500
    if (@(Get-WelcomeHelpers).Count -gt 0) {
        Show-Message 'The old welcome helper could not be stopped. Restarting the PC will clear it.' 'Warning'
        Update-WelcomeState
        return $false
    }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $WelcomeScript + '"'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden
    Wait-UI 2500
    Update-WelcomeState
    $ok = (@(Get-WelcomeHelpers).Count -ge 1)
    if ($ShowResult) {
        if ($ok) { Show-Message 'The welcome helper restarted and is using your latest message.' }
        else { Show-Message 'The welcome helper did not start. Run the Health check for details.' 'Warning' }
    }
    return $ok
}

function Save-WelcomeMessage {
    $t = ($script:WelcomeBox.Text -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($t)) {
        Show-Message 'The welcome message cannot be blank.' 'Warning'
        return
    }
    [System.IO.File]::WriteAllText($WelcomeFile, $t, (New-Object System.Text.UTF8Encoding($false)))
    if ((Get-CCWelcomeMode) -ne 'cc' -and (Test-Path -LiteralPath $WelcomeScript) -and (Get-WelcomeHelperState) -ne 'on') { [void](Restart-WelcomeHelper) }
    Update-WelcomeState
    Show-Message ("Welcome message saved. The next player who joins will see:`n`n" + $t.Replace('{name}', '(player name)'))
}

function Send-Broadcast {
    $t = ($script:BroadcastBox.Text -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return }
    if (-not (Test-ServerRunning)) {
        Show-Message 'The server is off, so there is nobody to send it to.'
        return
    }
    $api = Get-ApiInfo
    if ($null -eq $api) {
        Show-Message 'RESTAPIEnabled is off, so the editor cannot send messages.' 'Warning'
        return
    }
    $body = @{ message = $t } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri ($api.Url + '/announce') -Method Post -Headers $api.Auth `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
    $script:lblBroadcastState.Text = 'Sent at ' + (Get-Date -Format 'h:mm tt') + ':  ' + $t
    $script:lblBroadcastState.ForeColor = $ColorOn
    $script:BroadcastBox.Clear()
}

function New-SmallLabel([string]$Text, [int]$X, [int]$Y, [int]$Width) {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.UseMnemonic = $false
    $l.MaximumSize = New-Object System.Drawing.Size($Width, 0)
    $l.Font = $FontMain
    $l.ForeColor = $ColorDesc
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Text = $Text
    return $l
}

function New-MessagesTab {
    $page = New-ToolPage 'Messages'

    # --- Welcome message ---
    $g1 = New-Object VPalUi.CardGroup
    $g1.Text = 'Welcome message'
    $g1.Font = $FontBold
    $g1.Location = New-Object System.Drawing.Point(10, 10)
    $g1.Size = New-Object System.Drawing.Size(860, 172)
    $g1.Controls.Add((New-SmallLabel 'Pops up for everyone about 20 seconds after a player joins. Type {name} where the player name should go. Saving applies it to the next player who joins.' 14 24 830))

    $wb = New-Object System.Windows.Forms.TextBox
    $wb.Font = $FontMain
    $wb.Location = New-Object System.Drawing.Point(14, 66)
    $wb.Width = 830
    $wb.MaxLength = 200
    $wb.Text = Get-WelcomeText
    $script:WelcomeBox = $wb
    $g1.Controls.Add($wb)

    $f1 = New-Object System.Windows.Forms.FlowLayoutPanel
    $f1.AutoSize = $true
    $f1.WrapContents = $false
    $f1.Location = New-Object System.Drawing.Point(10, 98)
    $bSaveW = New-Button 'Save welcome message'
    $bRestartW = New-Button 'Restart welcome helper'
    $script:btnRestartWelcome = $bRestartW
    $bSaveW.Font = $FontBold
    $bRestartW.Font = $FontMain
    $f1.Controls.Add($bSaveW)
    $f1.Controls.Add($bRestartW)
    $g1.Controls.Add($f1)

    $lw = New-Object System.Windows.Forms.Label
    $lw.AutoSize = $true
    $lw.UseMnemonic = $false
    $lw.Font = $FontBold
    $lw.Location = New-Object System.Drawing.Point(14, 142)
    $script:lblWelcomeState = $lw
    $g1.Controls.Add($lw)

    # --- Send a message now ---
    $g2 = New-Object VPalUi.CardGroup
    $g2.Text = 'Send a message to everyone now'
    $g2.Font = $FontBold
    $g2.Location = New-Object System.Drawing.Point(10, 196)
    $g2.Size = New-Object System.Drawing.Size(860, 132)
    $g2.Controls.Add((New-SmallLabel 'Pops up on every player screen right away, for example a heads-up before you restart. Press Enter or click Send now.' 14 24 830))

    $bb = New-Object System.Windows.Forms.TextBox
    $bb.Font = $FontMain
    $bb.Location = New-Object System.Drawing.Point(14, 60)
    $bb.Width = 700
    $bb.MaxLength = 200
    $script:BroadcastBox = $bb
    $g2.Controls.Add($bb)

    $bSend = New-Button 'Send now'
    $bSend.Font = $FontBold
    $bSend.Location = New-Object System.Drawing.Point(726, 56)
    $g2.Controls.Add($bSend)

    $lb = New-Object System.Windows.Forms.Label
    $lb.AutoSize = $true
    $lb.UseMnemonic = $false
    $lb.MaximumSize = New-Object System.Drawing.Size(830, 0)
    $lb.Font = $FontMain
    $lb.ForeColor = $ColorDesc
    $lb.Location = New-Object System.Drawing.Point(14, 98)
    $lb.Text = 'Nothing sent yet.'
    $script:lblBroadcastState = $lb
    $g2.Controls.Add($lb)

    $bSaveW.add_Click({
        try { Save-WelcomeMessage }
        catch { Show-Message ("Could not save the welcome message:`n`n" + $_.Exception.Message) 'Error' }
    })
    $bRestartW.add_Click({
        try { [void](Restart-WelcomeHelper -ShowResult) }
        catch { Show-Message ("Could not restart the welcome helper:`n`n" + $_.Exception.Message) 'Error' }
    })
    $bSend.add_Click({
        try { Send-Broadcast }
        catch { Show-Message ("Could not send the message:`n`n" + $_.Exception.Message) 'Error' }
    })
    $bb.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            try { Send-Broadcast }
            catch { Show-Message ("Could not send the message:`n`n" + $_.Exception.Message) 'Error' }
        }
    })

    $page.Controls.Add($g1)
    $page.Controls.Add($g2)
    $tabs.TabPages.Add($page)
    Update-WelcomeState
}

# ---------------- Watchdog (the background part of this control panel) ----------------
# A small background program (CommandCenter\service\ccservice.py, run by pythonw, no window) watches the server every
# 15 seconds, even with this window closed: it starts it again after a crash or a freeze, restarts it with a warning
# when memory runs high or a game update is out, backs up the world and runs the Discord bot. It has no screen of its
# own and only answers this control panel, on 127.0.0.1:18770 (this PC only).
$CCDir     = Join-Path $ServerDir 'CommandCenter'
$CCService = Join-Path $CCDir 'service\ccservice.py'
$CCHold    = Join-Path $CCDir 'data\hold.json'
$CCTask    = 'VPal Server Watchdog'
$CCOldTask = 'Palworld Command Center'
$CCPort    = 18770
$CCUrl     = 'http://127.0.0.1:18770/'

function Test-CommandCenter {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $CCPort, $null, $null)
        return ([bool]($iar.AsyncWaitHandle.WaitOne(400) -and $c.Connected))
    }
    catch { return $false }
    finally { $c.Close() }
}

function Get-CCProcesses {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" -ErrorAction Stop |
                 Where-Object { $_.CommandLine -like '*ccservice.py*' })
    }
    catch { return @() }
}

function Get-CCFileVersion {
    try {
        $file = [System.IO.File]::ReadAllText((Join-Path (Split-Path $CCService) 'cc\util.py'))
        $m = [regex]::Match($file, "(?m)^VERSION = '([^']*)'")
        if ($m.Success) { return $m.Groups[1].Value }
    }
    catch { }
    return ''
}

function Get-CCState {
    # on / old (the running copy is an older version than the files on disk; it updates itself within a minute) / off
    if (-not (Test-CommandCenter)) { return 'off' }
    try {
        $want = Get-CCFileVersion
        $run = (Invoke-RestMethod -Uri ($CCUrl + 'api/status') -TimeoutSec 5).version
        if ($want -and [string]$run -ne $want) { return 'old' }
    }
    catch { }
    return 'on'
}

function Set-CCHold([string]$Reason) {
    # Tells the watchdog you stopped the server on purpose, so it leaves it off until you start it again.
    if (-not (Test-Path -LiteralPath $CCDir)) { return }
    try {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $CCHold))
        $json = @{ reason = $Reason; since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); until = $null } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($CCHold, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Clear-CCHold {
    try { if (Test-Path -LiteralPath $CCHold) { Remove-Item -LiteralPath $CCHold -Force } } catch { }
}

function Register-CCTask([string]$Py) {
    # Starts the watchdog when you sign in to Windows, and every 5 minutes makes sure it is still running
    # (a second copy just exits). No time limit, because it runs all the time.
    $action = New-ScheduledTaskAction -Execute $Py -Argument ('"' + $CCService + '"') -WorkingDirectory (Split-Path $CCService)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User ([Environment]::UserDomainName + '\' + [Environment]::UserName)
    $keep = New-ScheduledTaskTrigger -Daily -At '12:00 AM'
    $rep = New-ScheduledTaskTrigger -Once -At '12:00 AM' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Hours 24)
    $keep.Repetition = $rep.Repetition
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    $desc = 'VPal Server Command Center watchdog: crash and freeze recovery, backups and the Discord bot. Runs in the background; managed by the control panel.'
    try {
        Register-ScheduledTask -TaskName $CCTask -Action $action -Trigger @($logon, $keep) -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
    }
    catch {
        # some Windows setups only allow sign-in triggers for administrators; the 5-minute check starts it after sign-in anyway
        Register-ScheduledTask -TaskName $CCTask -Action $action -Trigger $keep -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
    }
    # the task had a different name before (the running copy keeps running; the new task takes over)
    try {
        if (Get-ScheduledTask -TaskName $CCOldTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $CCOldTask -Confirm:$false -ErrorAction Stop }
    }
    catch { }
}

function Start-Watchdog([switch]$Quiet) {
    # Installs the background task if needed and starts it. Returns $true once it answers.
    if (Test-CommandCenter) { return $true }
    if (-not (Test-Path -LiteralPath $CCService)) {
        if (-not $Quiet) { Show-Message ('Could not find ' + $CCService + '. Extract the update zip into ' + $ServerDir + ' first.') 'Error' }
        return $false
    }
    $py = Find-Python
    if (-not $py) {
        if ($Quiet) { return $false }
        if (-not (Confirm-Action "The watchdog needs Python (free). Install it now? It takes a minute or two.")) { return $false }
        if (-not (Install-Python)) { return $false }
        $py = Find-Python
        if (-not $py) { return $false }
    }
    Set-Status 'Starting the watchdog...'
    try { Register-CCTask $py } catch { }
    try { Start-ScheduledTask -TaskName $CCTask -ErrorAction Stop } catch {
        Start-Process -FilePath $py -ArgumentList ('"' + $CCService + '"') -WorkingDirectory (Split-Path $CCService) -WindowStyle Hidden | Out-Null
    }
    for ($i = 0; $i -lt 60; $i++) {
        Wait-UI 250
        if (Test-CommandCenter) { Set-Status 'The watchdog is running.'; return $true }
    }
    if (-not $Quiet) { Show-Message 'The watchdog did not start. Run the Health check for details.' 'Warning' }
    return $false
}

function Restart-Watchdog {
    foreach ($p in @(Get-CCProcesses)) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { } }
    for ($i = 0; $i -lt 20 -and (Test-CommandCenter); $i++) { Wait-UI 250 }
    return (Start-Watchdog)
}

function Initialize-Watchdog {
    # When this window opens: sets up and starts the watchdog without asking. A running older copy updates itself
    # within a minute, so it is left alone. If Python is missing, the Watchdog tab offers to set it up.
    if (-not (Test-Path -LiteralPath $CCService)) { return }
    $state = Get-CCState
    $hasNew = $false
    $hasOld = $false
    try { $hasNew = [bool](Get-ScheduledTask -TaskName $CCTask -ErrorAction SilentlyContinue) } catch { }
    try { $hasOld = [bool](Get-ScheduledTask -TaskName $CCOldTask -ErrorAction SilentlyContinue) } catch { }
    if ($state -ne 'off' -and $hasNew -and -not $hasOld) { return }
    $py = Find-Python
    if (-not $py) { return }
    if ((-not $hasNew) -or $hasOld) {
        try { Register-CCTask $py } catch { }
        Wait-UI 1500
    }
    if (-not (Test-CommandCenter)) { [void](Start-Watchdog -Quiet) }
}

function Invoke-CC([string]$Path, $Body = $null, [int]$Timeout = 30) {
    # Asks the watchdog (GET when there is no body, POST with a JSON body). Throws a plain-English message on errors.
    $u = $CCUrl + 'api/' + $Path
    try {
        if ($null -eq $Body) { return (Invoke-RestMethod -Uri $u -TimeoutSec $Timeout) }
        $json = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
        return (Invoke-RestMethod -Uri $u -Method Post -Headers @{ 'X-CC' = '1' } -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $Timeout)
    }
    catch {
        $msg = ''
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = [string](($_.ErrorDetails.Message | ConvertFrom-Json).error) } } catch { }
        if (-not $msg) {
            if (-not (Test-CommandCenter)) { $msg = 'The watchdog is not running. Open the Watchdog tab and click Start the watchdog.' }
            else { $msg = $_.Exception.Message }
        }
        throw $msg
    }
}

# ---------------- Pal Planner (family website) ----------------
# The planner page lives in PalPlanner\web. A tiny web server (engine\webserver.py) shows that folder to
# this PC only, and Tailscale Funnel passes the family's https link to it, so nothing is opened on the
# router and no administrator rights are needed. pythonw runs engine\palplanner.py to read the save and
# lock each person's pals with their own code.
$PlannerDir     = Join-Path $ServerDir 'PalPlanner'
$PlannerWeb     = Join-Path $PlannerDir 'web'
$PlannerEngine  = Join-Path $PlannerDir 'engine\palplanner.py'
$PlannerPlayers = Join-Path $PlannerDir 'players.json'
$PlannerStatus  = Join-Path $PlannerDir 'status.json'
$PlannerSetupLog = Join-Path $PlannerDir 'sharing-setup-log.txt'
$PlannerShareMark = Join-Path $PlannerDir 'sharing-on.txt'
$PlannerTask    = 'Pal Planner refresh'
try { if (Get-ScheduledTask -TaskName 'Vega Pal Planner refresh' -ErrorAction SilentlyContinue) { $PlannerTask = 'Vega Pal Planner refresh' } } catch { }
$PlannerServer  = Join-Path $PlannerDir 'engine\webserver.py'
$PlannerPort    = 18765          # this PC only; never the REST API port
$PlannerStartup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Pal Planner website.lnk'
$oldStartup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Vega Pal Planner website.lnk'
if (Test-Path -LiteralPath $oldStartup) { $PlannerStartup = $oldStartup }
$PlannerSite    = Join-Path $PlannerDir 'site-settings.json'
$TailscaleExe   = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$CodeWords = @('amber','otter','cedar','comet','maple','falcon','harbor','ember','willow','lunar','canyon','pepper',
               'river','summit','tiger','violet','meadow','copper','orbit','sparrow','thunder','jade','glacier','cobalt',
               'saffron','juniper','raven','coral','birch','nova','acorn','badger','breeze','cactus','cliff','clover',
               'crystal','dune','echo','fern','forest','frost','galaxy','garnet','hazel','island','ivy','lagoon',
               'lantern','lotus','marble','mesa','mint','moss','oak','ocean','opal','panda','pebble','pine',
               'prairie','quartz','reef','ridge','robin','sage','shadow','silver','spruce','storm','sunset','tundra',
               'valley','wave','wren','zephyr')

$script:PlannerLink    = $null
$script:PlannerShareOn = $false
$script:PlannerUI      = @{}
$script:PlannerList    = New-Object System.Collections.Generic.List[object]

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    # Runs a console program and returns its exit code and text (stderr included) without throwing.
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        return @{ Code = $LASTEXITCODE; Text = (@($lines) -join "`n") }
    }
    catch { return @{ Code = -1; Text = $_.Exception.Message } }
}

function Read-SharedText([string]$Path) {
    # Reads a file another program is still writing to.
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $t = $sr.ReadToEnd()
        $sr.Close()
        return $t
    }
    catch { return '' }
}

function Wait-ChildProcess($Proc, [int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while (-not $Proc.HasExited) {
        if ((Get-Date) -gt $end) { try { $Proc.Kill() } catch { }; return $false }
        Wait-UI 250
    }
    return $true
}

# ---- Python ----
function Test-PythonExe([string]$Exe) {
    # Needs 64-bit Python 3.9 or newer. Returns the matching pythonw.exe, or $null.
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $null }
    if ($Exe -like '*\WindowsApps\*') { return $null }        # the Microsoft Store shortcut, not real Python
    $console = Join-Path (Split-Path $Exe) 'python.exe'
    $windowless = Join-Path (Split-Path $Exe) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $console) -or -not (Test-Path -LiteralPath $windowless)) { return $null }
    $r = Invoke-Native $console @('-c', "import sys,struct;print(sys.version_info[0]*100+sys.version_info[1],struct.calcsize('P')*8)")
    $parts = ($r.Text.Trim() -split '\s+')
    if ($r.Code -ne 0 -or $parts.Count -lt 2) { return $null }
    if ([int]$parts[0] -lt 309 -or $parts[1] -ne '64') { return $null }
    return $windowless
}

function Find-Python {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
            Sort-Object { [int]('0' + ($_.Name -replace '\D', '')) } -Descending |
            ForEach-Object { $cands.Add((Join-Path $_.FullName 'python.exe')) }
    }
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py) {
        $r = Invoke-Native $py.Source @('-3', '-c', 'import sys;print(sys.executable)')
        if ($r.Code -eq 0) { $cands.Add($r.Text.Trim()) }
    }
    $pc = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($pc) { $cands.Add($pc.Source) }
    foreach ($c in $cands) {
        $ok = Test-PythonExe $c
        if ($ok) { return $ok }
    }
    return $null
}

function Install-Python {
    $wg = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $wg) {
        Start-Process 'https://www.python.org/downloads/windows/'
        Show-Message ("Windows could not install Python by itself on this PC.`n`nThe Python download page just opened. " +
                      "Download the Windows installer (64-bit), run it, tick ""Add python.exe to PATH"", then click Set up sharing again.") 'Warning'
        return $false
    }
    Set-Status 'Installing Python. This takes a minute or two...'
    $p = Start-Process -FilePath $wg.Source -ArgumentList 'install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements' -WindowStyle Hidden -PassThru
    $null = $p.Handle
    [void](Wait-ChildProcess $p 900)
    return [bool](Find-Python)
}

# ---- Engine (reads the save, locks each planner) ----
function Invoke-PlannerEngine([string]$Command) {
    # Returns the status object written by the engine, or $null if Python is missing.
    $py = Find-Python
    if (-not $py) { return $null }
    if (-not (Test-Path -LiteralPath $PlannerEngine)) { throw ('Could not find ' + $PlannerEngine) }
    $p = Start-Process -FilePath $py -ArgumentList ('"' + $PlannerEngine + '" ' + $Command) -WorkingDirectory (Split-Path $PlannerEngine) -WindowStyle Hidden -PassThru
    $null = $p.Handle
    if (-not (Wait-ChildProcess $p 600)) { throw 'The pal update took longer than 10 minutes and was stopped.' }
    return Read-PlannerStatus
}

function Read-PlannerStatus {
    try {
        if (Test-Path -LiteralPath $PlannerStatus) { return ([System.IO.File]::ReadAllText($PlannerStatus) | ConvertFrom-Json) }
    }
    catch { }
    return $null
}

# ---- Automatic updates (a Windows scheduled task, so it also runs while this window is closed) ----
function Get-PlannerAutoMinutes {
    try {
        $t = Get-ScheduledTask -TaskName $PlannerTask -ErrorAction Stop
        if ($t.State -eq 'Disabled') { return 0 }
        $iv = [string]$t.Triggers[0].Repetition.Interval
        if ($iv -match 'PT(\d+)H') { return [int]$Matches[1] * 60 }
        if ($iv -match 'PT(\d+)M') { return [int]$Matches[1] }
        return 30
    }
    catch { return 0 }
}

function Set-PlannerAuto([int]$Minutes) {
    try { Unregister-ScheduledTask -TaskName $PlannerTask -Confirm:$false -ErrorAction Stop } catch { }
    if ($Minutes -le 0) { return $true }
    $py = Find-Python
    if (-not $py) { Show-Message 'Python is not set up yet. Click Set up sharing first.' 'Warning'; return $false }
    $action = New-ScheduledTaskAction -Execute $py -Argument ('"' + $PlannerEngine + '" refresh --if-changed') -WorkingDirectory (Split-Path $PlannerEngine)
    $trigger = New-ScheduledTaskTrigger -Daily -At '12:00 AM'
    $rep = New-ScheduledTaskTrigger -Once -At '12:00 AM' -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration (New-TimeSpan -Hours 24)
    $trigger.Repetition = $rep.Repetition
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $PlannerTask -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Rebuilds the Pal Planner from the Palworld save. Managed by the VPal Server Command Center (Pal Planner tab).' -Force | Out-Null
    return $true
}

# ---- Sharing (Tailscale Funnel) ----
function Get-TailscaleInfo {
    $info = @{ Installed = (Test-Path -LiteralPath $TailscaleExe); State = ''; Dns = ''; Funnel = $false }
    if (-not $info.Installed) { return $info }
    $r = Invoke-Native $TailscaleExe @('status', '--json')
    try {
        $s = $r.Text | ConvertFrom-Json
        $info.State = [string]$s.BackendState
        if ($s.Self -and $s.Self.DNSName) { $info.Dns = ([string]$s.Self.DNSName).TrimEnd('.') }
    }
    catch { $info.State = 'Unknown' }
    if ($info.State -eq 'Running') {
        $f = Invoke-Native $TailscaleExe @('funnel', 'status', '--json')
        $t = $f.Text.Trim()
        if ($t.StartsWith('{')) {
            try {
                $j = $t | ConvertFrom-Json
                if ($j.AllowFunnel) { foreach ($pp in $j.AllowFunnel.PSObject.Properties) { if ($pp.Value -eq $true) { $info.Funnel = $true } } }
            }
            catch { }
        }
        elseif ($f.Code -ne 0) { $info.Funnel = (Test-Path -LiteralPath $PlannerShareMark) }   # could not read it; use what setup recorded
    }
    return $info
}

function Install-Tailscale {
    $wg = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $wg) {
        Start-Process 'https://tailscale.com/download/windows'
        Show-Message "The Tailscale download page just opened. Install it, then click Set up sharing again." 'Warning'
        return $false
    }
    Set-Status 'Installing Tailscale. Windows asks for permission; click Yes...'
    $p = Start-Process -FilePath $wg.Source -ArgumentList 'install -e --id Tailscale.Tailscale --silent --accept-package-agreements --accept-source-agreements' -WindowStyle Hidden -PassThru
    $null = $p.Handle
    [void](Wait-ChildProcess $p 900)
    Wait-UI 4000
    return (Test-Path -LiteralPath $TailscaleExe)
}

function Connect-Tailscale {
    # Opens the Tailscale sign-in page in the browser and waits (up to 5 minutes) until it finishes.
    $out = Join-Path $PlannerDir 'tailscale-login.txt'
    $err = Join-Path $PlannerDir 'tailscale-login-err.txt'
    Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $TailscaleExe -ArgumentList 'login' -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
    $opened = $false
    $end = (Get-Date).AddMinutes(5)
    Set-Status 'Waiting for you to sign in to Tailscale in your browser...'
    while ((Get-Date) -lt $end) {
        Wait-UI 1500
        if (-not $opened) {
            $txt = (Read-SharedText $out) + (Read-SharedText $err)
            $m = [regex]::Match($txt, 'https://login\.tailscale\.com/\S+')
            if ($m.Success) {
                Start-Process $m.Value
                $opened = $true
                Show-Message ("Your browser opened the Tailscale sign-in page.`n`nSign in with Google, Microsoft or Apple (it is free), " +
                              "click Connect, then come back here. This only happens once.")
            }
        }
        if ((Get-TailscaleInfo).State -eq 'Running') { break }
    }
    try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    return ((Get-TailscaleInfo).State -eq 'Running')
}

function Invoke-Tailscale([string]$Arguments, [string]$Waiting) {
    # Runs a Tailscale command as you (the Windows account Tailscale belongs to). If Tailscale asks for
    # approval in the browser, opens that page and waits (up to 8 minutes). Saves what it said to the log.
    $out = Join-Path $PlannerDir 'tailscale-out.txt'
    $err = Join-Path $PlannerDir 'tailscale-err.txt'
    Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $TailscaleExe -ArgumentList $Arguments -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
    $null = $p.Handle
    Set-Status $Waiting
    $opened = @{}
    $end = (Get-Date).AddMinutes(8)
    while (-not $p.HasExited -and (Get-Date) -lt $end) {
        Wait-UI 1000
        $txt = (Read-SharedText $out) + "`n" + (Read-SharedText $err)
        foreach ($m in [regex]::Matches($txt, 'https://login\.tailscale\.com/\S+')) {
            if (-not $opened.ContainsKey($m.Value)) {
                Start-Process $m.Value
                $opened[$m.Value] = $true
                Show-Message ("Tailscale opened a page in your browser asking you to allow sharing (HTTPS / Funnel).`n`n" +
                              'Click Enable on that page, then come back here and click OK. This only happens once.')
            }
        }
    }
    $ok = $false
    if ($p.HasExited) { $ok = ($p.ExitCode -eq 0) } else { try { $p.Kill() } catch { } }
    Wait-UI 300
    $txt = ((Read-SharedText $out) + "`n" + (Read-SharedText $err)).Trim()
    try { Set-Content -LiteralPath $PlannerSetupLog -Value ("tailscale " + $Arguments + "`r`n" + $txt + "`r`nok: " + $ok) -Encoding UTF8 } catch { }
    Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    return @{ Ok = $ok; Text = $txt }
}

# ---- The little web server (this PC only) ----
function Test-PlannerWeb {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $PlannerPort, $null, $null)
        return ([bool]($iar.AsyncWaitHandle.WaitOne(400) -and $c.Connected))
    }
    catch { return $false }
    finally { $c.Close() }
}

function Start-PlannerWeb {
    if (Test-PlannerWeb) { return $true }
    $py = Find-Python
    if (-not $py -or -not (Test-Path -LiteralPath $PlannerServer)) { return $false }
    Start-Process -FilePath $py -ArgumentList ('"' + $PlannerServer + '" ' + $PlannerPort) -WorkingDirectory (Split-Path $PlannerServer) -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 24; $i++) {
        Wait-UI 250
        if (Test-PlannerWeb) { return $true }
    }
    return $false
}

function Set-PlannerWebAutostart {
    # A shortcut in your Startup folder starts the web server whenever you sign in to Windows.
    $py = Find-Python
    if (-not $py) { return }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($PlannerStartup)
    $lnk.TargetPath = $py
    $lnk.Arguments = '"' + $PlannerServer + '" ' + $PlannerPort
    $lnk.WorkingDirectory = Split-Path $PlannerServer
    $lnk.WindowStyle = 7
    $lnk.Description = 'Shows the Pal Planner to Tailscale (this PC only). Managed by the VPal Server Command Center.'
    $lnk.Save()
}

function Update-PlannerSharing {
    $ui = $script:PlannerUI
    if (-not $ui.ShareLabel -or $ui.ShareLabel.IsDisposed) { return }
    $py = Find-Python
    $ts = Get-TailscaleInfo
    $script:PlannerShareOn = ($ts.Funnel -and $ts.Dns)
    if ($script:PlannerShareOn -and -not (Test-PlannerWeb)) { [void](Start-PlannerWeb) }
    if ($ts.Dns) { $script:PlannerLink = 'https://' + $ts.Dns + '/' } else { $script:PlannerLink = $null }
    if ($script:PlannerShareOn) {
        $ui.ShareLabel.Text = 'Family link:  ' + $script:PlannerLink
        $ui.ShareLabel.ForeColor = $ColorOn
    }
    elseif ($ts.Dns -and $ts.State -eq 'Running') {
        $ui.ShareLabel.Text = 'Sharing is off. Click Set up sharing to turn the family link back on.'
        $ui.ShareLabel.ForeColor = $ColorOff
    }
    else {
        $ui.ShareLabel.Text = 'Not shared yet. Click Set up sharing (one time, about 5 minutes).'
        $ui.ShareLabel.ForeColor = $ColorStarting
    }
    $parts = @()
    if ($py) { $parts += 'Python: ready' } else { $parts += 'Python: not installed' }
    if (-not $ts.Installed) { $parts += 'Tailscale: not installed' }
    elseif ($ts.State -eq 'Running') { $parts += 'Tailscale: signed in' }
    else { $parts += 'Tailscale: not signed in' }
    if ($script:PlannerShareOn) { $parts += 'Link: on' } else { $parts += 'Link: off' }
    $ui.PartsLabel.Text = ($parts -join '   |   ')
    $ui.CopyLink.Enabled = $script:PlannerShareOn
    $ui.OpenLink.Enabled = $script:PlannerShareOn
    $ui.ShareOff.Enabled = $script:PlannerShareOn
}

function Start-PlannerSetup {
    # One button does every step it still needs; finished steps are skipped.
    if (-not (Test-Path -LiteralPath $PlannerEngine)) {
        Show-Message ('The PalPlanner folder is missing. It should be at ' + $PlannerDir) 'Error'
        return
    }
    # 1. Python
    if (-not (Find-Python)) {
        if (-not (Confirm-Action "Step 1 of 3: Python`n`nThe pal reader needs Python (free, from python.org). Install it now?")) { return }
        if (-not (Install-Python)) {
            Show-Message 'Python did not finish installing. Click Set up sharing to try again.' 'Warning'
            return
        }
    }
    # 2. First read of the save + automatic updates
    Set-Status 'Reading the world save and building everyone''s planner...'
    $st = Invoke-PlannerEngine 'refresh'
    if ($null -eq $st -or -not $st.ok) {
        $why = 'unknown problem'
        if ($null -ne $st) { $why = [string]$st.message }
        Show-Message ("The pal reader could not read the save:`n`n" + $why + "`n`nDetails are in PalPlanner\refresh-log.txt.") 'Error'
        return
    }
    if ((Get-PlannerAutoMinutes) -eq 0) { [void](Set-PlannerAuto 30) }
    Update-PlannerData
    # 3. Tailscale: install, sign in, share the web folder
    $ts = Get-TailscaleInfo
    if (-not $ts.Installed) {
        $ask = "Step 2 of 3: Tailscale`n`nTailscale (free) gives the planner a fixed https link your family can open from home, " +
               "without opening anything on your router. Install it now?`n`nWindows will ask for permission; click Yes."
        if (-not (Confirm-Action $ask)) { return }
        if (-not (Install-Tailscale)) { Show-Message 'Tailscale did not finish installing. Click Set up sharing to try again.' 'Warning'; return }
        $ts = Get-TailscaleInfo
    }
    if ($ts.State -ne 'Running') {
        if (-not (Connect-Tailscale)) {
            Show-Message 'Tailscale is not signed in yet. Finish signing in, then click Set up sharing again.' 'Warning'
            Update-PlannerSharing
            return
        }
    }
    Set-Status 'Starting the planner''s web server (this PC only)...'
    if (-not (Start-PlannerWeb)) {
        Show-Message ("The planner's web server did not start.`n`nClose this window, open it again and click Set up sharing. " +
                      "If it still fails, send Claude a screenshot of this message.") 'Warning'
        return
    }
    try { Set-PlannerWebAutostart } catch { }
    if (-not (Get-TailscaleInfo).Funnel) {
        Show-Message ("Step 3 of 3: turn on the family link`n`nOnly the planner page is shared. Your server, files and the REST API stay private.")
        $r = Invoke-Tailscale ('funnel --bg --yes ' + $PlannerPort) 'Turning on the family link...'
        if ($r.Ok) { Set-Content -LiteralPath $PlannerShareMark -Value (Get-Date -Format 's') -Encoding UTF8 }
        Wait-UI 1500
        if (-not $r.Ok -and -not (Get-TailscaleInfo).Funnel) {
            $said = $r.Text
            if ($said.Length -gt 600) { $said = $said.Substring(0, 600) + '...' }
            if (-not $said) { $said = '(nothing)' }
            Show-Message ("The family link did not turn on. Tailscale said:`n`n" + $said + "`n`nClick Set up sharing to try again, or send Claude a screenshot of this message.") 'Warning'
            Update-PlannerSharing
            return
        }
    }
    Update-PlannerSharing
    Set-Status 'The Pal Planner is shared.'
    if ($script:PlannerLink) {
        [System.Windows.Forms.Clipboard]::SetText($script:PlannerLink)
        Show-Message ("All set. The family link is:`n`n" + $script:PlannerLink + "`n`nIt is copied. Pick a player below and click Text invite or Email invite to send them the link and their code.")
    }
}

function Stop-PlannerSharing {
    if (-not (Confirm-Action "Turn the family link off?`n`nNobody can open the planner until you click Set up sharing again. The link stays the same when you turn it back on.")) { return }
    $r = Invoke-Tailscale 'funnel reset' 'Turning the family link off...'
    if ($r.Ok) { Remove-Item -LiteralPath $PlannerShareMark -ErrorAction SilentlyContinue }
    else { Show-Message ("Tailscale said:`n`n" + $r.Text) 'Warning' }
    Wait-UI 1500
    Update-PlannerSharing
    Set-Status 'The family link is off.'
}

# ---- Players and codes ----
function New-PlannerCode {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 4
    $pick = {
        param([int]$n)
        $rng.GetBytes($buf)
        return ([BitConverter]::ToUInt32($buf, 0) % [uint32]$n)
    }
    $used = @{}
    foreach ($p in $script:PlannerList) { $used[[string]$p.code] = $true }
    do {
        $code = $CodeWords[(& $pick $CodeWords.Count)] + '-' + $CodeWords[(& $pick $CodeWords.Count)] + '-' + (10 + (& $pick 90))
    } while ($used.ContainsKey($code))
    return $code
}

function Read-PlannerPlayers {
    $script:PlannerList.Clear()
    if (-not (Test-Path -LiteralPath $PlannerPlayers)) { return }
    $j = [System.IO.File]::ReadAllText($PlannerPlayers) | ConvertFrom-Json
    foreach ($p in @($j.players)) {
        if ($null -eq $p) { continue }
        $script:PlannerList.Add([ordered]@{
            real = [string]$p.real; game = [string]$p.game; uid = [string]$p.uid; code = [string]$p.code
            phone = [string]$p.phone; email = [string]$p.email; invited = [string]$p.invited
        })
    }
}

function Save-PlannerPlayers {
    $arr = @($script:PlannerList | ForEach-Object { New-Object -TypeName PSObject -Property $_ })
    $json = ConvertTo-Json -InputObject @{ players = $arr } -Depth 4
    [System.IO.File]::WriteAllText($PlannerPlayers, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-SavePlayers {
    # In-game players found by the last save read: name, uid, level, pals.
    $st = Read-PlannerStatus
    if ($null -eq $st -or $null -eq $st.players) { return @() }
    return @($st.players)
}

function Update-PlannerList {
    $lv = $script:PlannerUI.List
    if (-not $lv -or $lv.IsDisposed) { return }
    $sel = -1
    if ($lv.SelectedIndices.Count -gt 0) { $sel = $lv.SelectedIndices[0] }
    $pals = @{}
    foreach ($sp in (Get-SavePlayers)) { $pals[[string]$sp.uid] = $sp; $pals['name:' + ([string]$sp.name).ToLower()] = $sp }
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($p in $script:PlannerList) {
        $hit = $pals[$p.uid]
        if (-not $hit) { $hit = $pals['name:' + $p.game.ToLower()] }
        $count = 'not in save yet'
        if ($hit) { $count = [string]$hit.pals }
        $contact = @($p.phone, $p.email | Where-Object { $_ }) -join ', '
        $invited = $p.invited
        if (-not $invited) { $invited = 'not yet' }
        $it = New-Object System.Windows.Forms.ListViewItem($p.real)
        foreach ($sub in @($p.game, $p.code, $count, $contact, $invited)) { [void]$it.SubItems.Add([string]$sub) }
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    if ($sel -ge 0 -and $sel -lt $lv.Items.Count) { $lv.Items[$sel].Selected = $true }
}

function Update-PlannerData {
    $ui = $script:PlannerUI
    if (-not $ui.DataLabel -or $ui.DataLabel.IsDisposed) { return }
    $st = Read-PlannerStatus
    if ($null -eq $st) {
        $ui.DataLabel.Text = 'Not read yet. Click Refresh now (or Set up sharing).'
        $ui.DataLabel.ForeColor = $ColorStarting
    }
    elseif (-not $st.ok) {
        $ui.DataLabel.Text = [string]$st.message + '  (' + [string]$st.when + '). Details: PalPlanner\refresh-log.txt'
        $ui.DataLabel.ForeColor = $ColorOff
    }
    else {
        $ui.DataLabel.Text = 'Last updated ' + [string]$st.when + ' from the ' + [string]$st.saved + ' save.'
        $ui.DataLabel.ForeColor = $ColorOn
    }
}

function Get-SelectedPlayer {
    $lv = $script:PlannerUI.List
    if ($lv.SelectedIndices.Count -eq 0) { Show-Message 'Click a player in the list first.'; return $null }
    return $script:PlannerList[$lv.SelectedIndices[0]]
}

function Invoke-PlannerLock([string]$Done) {
    Save-PlannerPlayers
    $st = Invoke-PlannerEngine 'lock'
    Update-PlannerList
    if ($null -eq $st) {
        Set-Status 'Saved. Click Set up sharing so Python is ready, then the planner updates.'
        return
    }
    $missing = @($st.missing | Where-Object { $_ })
    if ($missing.Count -gt 0) {
        Show-Message ($Done + "`n`nNo pals found yet for: " + ($missing -join ', ') +
                      ".`nThey need to join the server once (and the next update has to run). Click Refresh now after they have played.")
    }
    else { Set-Status $Done }
}

function Show-PlayerDialog($Player) {
    # Add (Player = $null) or edit a player. Returns the filled-in player or $null.
    $isNew = ($null -eq $Player)
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $(if ($isNew) { 'Add a player' } else { 'Edit player' })
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'
    $d.Font = $FontMain
    $d.ClientSize = New-Object System.Drawing.Size(460, 300)

    $y = 16
    $fields = @{}
    foreach ($f in @(
        @('real', 'Their name (shown on their planner)'),
        @('game', 'In-game name'),
        @('phone', 'Phone (for texting the invite, optional)'),
        @('email', 'Email (for emailing the invite, optional)'))) {
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point(16, $y)
        $l.Text = $f[1]
        $d.Controls.Add($l)
        if ($f[0] -eq 'game') {
            $c = New-Object System.Windows.Forms.ComboBox
            $c.DropDownStyle = 'DropDown'
            $taken = @{}
            foreach ($p in $script:PlannerList) { if (-not [object]::ReferenceEquals($p, $Player)) { $taken[$p.game.ToLower()] = $true } }
            foreach ($sp in (Get-SavePlayers)) {
                if (-not $taken.ContainsKey(([string]$sp.name).ToLower())) { [void]$c.Items.Add([string]$sp.name) }
            }
        }
        else { $c = New-Object System.Windows.Forms.TextBox }
        $c.Location = New-Object System.Drawing.Point(16, ($y + 20))
        $c.Width = 428
        if (-not $isNew) { $c.Text = [string]$Player[$f[0]] }
        $d.Controls.Add($c)
        $fields[$f[0]] = $c
        $y += 56
    }
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true
    $hint.MaximumSize = New-Object System.Drawing.Size(300, 0)
    $hint.ForeColor = $ColorDesc
    $hint.Location = New-Object System.Drawing.Point(16, ($y + 2))
    $hint.Text = $(if ($isNew) { 'A private code is made for them when you click Save.' } else { 'Their code stays the same.' })
    $d.Controls.Add($hint)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save'
    $ok.Font = $FontBold
    $ok.Size = New-Object System.Drawing.Size(80, 30)
    $ok.Location = New-Object System.Drawing.Point(274, ($y - 2))
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object System.Drawing.Size(80, 30)
    $cancel.Location = New-Object System.Drawing.Point(364, ($y - 2))
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $d.Controls.Add($ok)
    $d.Controls.Add($cancel)
    $d.AcceptButton = $ok
    $d.CancelButton = $cancel
    $ok.add_Click({
        if ([string]::IsNullOrWhiteSpace($fields['real'].Text) -or [string]::IsNullOrWhiteSpace($fields['game'].Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('Fill in their name and their in-game name.', 'Pal Planner', 'OK', 'Information')
            return
        }
        $d.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $d.Close()
    })
    [VPalUi.Dark]::Apply($d)
    if ($d.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { $d.Dispose(); return $null }

    if ($isNew) { $Player = [ordered]@{ real = ''; game = ''; uid = ''; code = (New-PlannerCode); phone = ''; email = ''; invited = '' } }
    $Player.real = $fields['real'].Text.Trim()
    $newGame = $fields['game'].Text.Trim()
    if ($newGame -ne $Player.game) {
        $Player.game = $newGame
        $Player.uid = ''
        foreach ($sp in (Get-SavePlayers)) { if (([string]$sp.name).ToLower() -eq $newGame.ToLower()) { $Player.uid = [string]$sp.uid } }
    }
    $Player.phone = $fields['phone'].Text.Trim()
    $Player.email = $fields['email'].Text.Trim()
    $d.Dispose()
    return $Player
}

function Get-PlannerSite {
    # The planner page's name and who people ask for a code (site-settings.json; the engine copies it into web\site.json).
    $o = @{ name = ''; owner = '' }
    try {
        if (Test-Path -LiteralPath $PlannerSite) {
            $j = [System.IO.File]::ReadAllText($PlannerSite) | ConvertFrom-Json
            $o.name = [string]$j.name
            $o.owner = [string]$j.owner
        }
    }
    catch { }
    if (-not $o.name) { $o.name = [string]$script:ServerTitle }
    return $o
}

function Get-PlannerTitle {
    $n = (Get-PlannerSite).name
    if ($n) { return ($n + ' Pal Planner') }
    return 'Pal Planner'
}

function Save-PlannerSite([string]$Name, [string]$Owner) {
    $json = @{ name = $Name.Trim(); owner = $Owner.Trim() } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($PlannerSite, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-InviteText($P) {
    $every = 'every so often'
    $m = Get-PlannerAutoMinutes
    if ($m -ge 60) { $every = 'every hour' } elseif ($m -gt 0) { $every = "every $m minutes" }
    return ('Hi ' + $P.real + "! Here's your " + (Get-PlannerTitle) + ": all your pals with their true stats, the best crew for every job, " +
            "boss teams, breeding plans and the world map.`r`n`r`n" + $script:PlannerLink + "`r`n`r`nYour code: " + $P.code +
            "`r`n`r`nYour code only opens your own pals. Leave ""Remember me on this device"" ticked so you only type it once. " +
            "It updates by itself $every while the server is running." +
            "`r`n`r`nPut it on your home screen so it opens like an app:" +
            "`r`n- iPhone: open the link in Safari, tap the Share button, then Add to Home Screen." +
            "`r`n- Android: open the link in Chrome, tap the 3-dot menu, then Add to Home screen (or Install app)." +
            "`r`nThen open it from the new icon and enter your code one more time.")
}

function Send-PlannerInvite([string]$How) {
    $p = Get-SelectedPlayer
    if ($null -eq $p) { return }
    if (-not $script:PlannerShareOn -or -not $script:PlannerLink) {
        Show-Message 'The family link is not on yet. Click Set up sharing first, so there is a link to send.'
        return
    }
    $text = Get-InviteText $p
    switch ($How) {
        'text' {
            [System.Windows.Forms.Clipboard]::SetText($text)
            $to = $p.real
            if ($p.phone) { $to = $p.real + ' (' + $p.phone + ')' }
            Show-Message ("The invite for " + $p.real + " is copied.`n`nClick OK to open Phone Link. Go to Messages, start a new message to " + $to +
                          ", click in the message box and press Ctrl+V, then send.`n`n(It also pastes into any other texting app.)")
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App' } catch { }
        }
        'email' {
            # Opens a ready-to-send Gmail message in your web browser (no email app setup needed).
            $subject = 'Your ' + (Get-PlannerTitle) + ' link and code'
            $uri = 'https://mail.google.com/mail/?view=cm&fs=1&to=' + [uri]::EscapeDataString(($p.email -replace '[\s<>"]', '')) +
                   '&su=' + [uri]::EscapeDataString($subject) + '&body=' + [uri]::EscapeDataString($text)
            try { Start-Process $uri }
            catch {
                [System.Windows.Forms.Clipboard]::SetText($text)
                Show-Message 'Your web browser did not open, so the invite was copied instead. Paste it into a new Gmail message.' 'Warning'
            }
        }
        default {
            [System.Windows.Forms.Clipboard]::SetText($text)
            Set-Status ('Invite for ' + $p.real + ' copied. Paste it anywhere.')
        }
    }
    $p.invited = (Get-Date -Format 'MMM d, h:mm tt')
    Save-PlannerPlayers
    Update-PlannerList
}

function Edit-PlannerPlayer {
    try {
        $p = Get-SelectedPlayer
        if ($null -eq $p) { return }
        if ($null -eq (Show-PlayerDialog $p)) { return }
        Set-Busy $true
        Invoke-PlannerLock ('Saved ' + $p.real + '.')
    }
    catch { Show-Message ("Could not save the player:`n`n" + $_.Exception.Message) 'Error' }
    finally { Set-Busy $false }
}

function New-PlannerTab {
    $page = New-ToolPage 'Pal Planner'
    $ui = @{}

    # --- Family link ---
    $g1 = New-Object VPalUi.CardGroup
    $g1.Text = 'Family link'
    $g1.Font = $FontBold
    $g1.Location = New-Object System.Drawing.Point(10, 10)
    $g1.Size = New-Object System.Drawing.Size(860, 156)
    $g1.Controls.Add((New-SmallLabel 'Everyone opens the same link and types their own code, so each person only sees their own pals. The page runs on this PC and is shared through Tailscale, so nothing is opened on your router.' 14 24 830))
    $ls = New-Object System.Windows.Forms.Label
    $ls.AutoSize = $true
    $ls.UseMnemonic = $false
    $ls.Font = $FontBold
    $ls.Location = New-Object System.Drawing.Point(14, 64)
    $ls.Text = 'Checking...'
    $g1.Controls.Add($ls)
    $lp = New-SmallLabel '' 14 86 830
    $g1.Controls.Add($lp)
    $f1 = New-Object System.Windows.Forms.FlowLayoutPanel
    $f1.AutoSize = $true
    $f1.WrapContents = $false
    $f1.Location = New-Object System.Drawing.Point(10, 112)
    $bSetup = New-Button 'Set up sharing'
    $bSetup.Font = $FontBold
    $bCopy = New-Button 'Copy link'
    $bOpen = New-Button 'Open planner'
    $bOff  = New-Button 'Turn link off'
    foreach ($b in @($bCopy, $bOpen, $bOff)) { $b.Font = $FontMain }
    foreach ($b in @($bSetup, $bCopy, $bOpen, $bOff)) { $f1.Controls.Add($b) }
    $g1.Controls.Add($f1)

    # --- Pal data ---
    $g2 = New-Object VPalUi.CardGroup
    $g2.Text = 'Pal data'
    $g2.Font = $FontBold
    $g2.Location = New-Object System.Drawing.Point(10, 176)
    $g2.Size = New-Object System.Drawing.Size(860, 98)
    $ld = New-Object System.Windows.Forms.Label
    $ld.AutoSize = $true
    $ld.UseMnemonic = $false
    $ld.MaximumSize = New-Object System.Drawing.Size(830, 0)
    $ld.Font = $FontMain
    $ld.Location = New-Object System.Drawing.Point(14, 24)
    $g2.Controls.Add($ld)
    $f2 = New-Object System.Windows.Forms.FlowLayoutPanel
    $f2.AutoSize = $true
    $f2.WrapContents = $false
    $f2.Location = New-Object System.Drawing.Point(10, 52)
    $bRefresh = New-Button 'Refresh now'
    $bRefresh.Font = $FontMain
    $f2.Controls.Add($bRefresh)
    $la = New-Object System.Windows.Forms.Label
    $la.AutoSize = $true
    $la.Font = $FontMain
    $la.Margin = New-Object System.Windows.Forms.Padding(16, 8, 4, 0)
    $la.Text = 'Update automatically:'
    $f2.Controls.Add($la)
    $cAuto = New-Object System.Windows.Forms.ComboBox
    $cAuto.DropDownStyle = 'DropDownList'
    $cAuto.Font = $FontMain
    $cAuto.Width = 150
    $cAuto.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
    foreach ($o in @('Off', 'Every 15 minutes', 'Every 30 minutes', 'Every hour')) { [void]$cAuto.Items.Add($o) }
    $f2.Controls.Add($cAuto)
    $g2.Controls.Add($f2)

    # --- Players ---
    $g3 = New-Object VPalUi.CardGroup
    $g3.Text = 'Players and codes'
    $g3.Font = $FontBold
    $g3.Location = New-Object System.Drawing.Point(10, 284)
    $g3.Size = New-Object System.Drawing.Size(860, 262)
    $lv = New-Object VPalUi.DarkList
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.Font = $FontMain
    $lv.Location = New-Object System.Drawing.Point(14, 24)
    $lv.Size = New-Object System.Drawing.Size(830, 178)
    foreach ($col in @(@('Name', 110), @('In-game', 110), @('Code', 150), @('Pals', 110), @('Phone / email', 210), @('Invite sent', 120))) {
        [void]$lv.Columns.Add($col[0], $col[1])
    }
    $g3.Controls.Add($lv)
    $f3 = New-Object System.Windows.Forms.FlowLayoutPanel
    $f3.AutoSize = $true
    $f3.WrapContents = $false
    $f3.Location = New-Object System.Drawing.Point(10, 212)
    $bAdd = New-Button 'Add player'
    $bEdit = New-Button 'Edit'
    $bCode = New-Button 'New code'
    $bDel = New-Button 'Remove'
    $bText = New-Button 'Text invite'
    $bMail = New-Button 'Email invite'
    $bCopyInv = New-Button 'Copy invite'
    $bText.Margin = New-Object System.Windows.Forms.Padding(28, 0, 4, 0)
    foreach ($b in @($bAdd, $bEdit, $bCode, $bDel, $bText, $bMail, $bCopyInv)) { $b.Font = $FontMain; $f3.Controls.Add($b) }
    $bAdd.Font = $FontBold
    $bText.Font = $FontBold
    $g3.Controls.Add($f3)

    $ui.ShareLabel = $ls; $ui.PartsLabel = $lp; $ui.CopyLink = $bCopy; $ui.OpenLink = $bOpen; $ui.ShareOff = $bOff
    $ui.DataLabel = $ld; $ui.Auto = $cAuto; $ui.List = $lv
    $script:PlannerUI = $ui

    # --- Actions ---
    $bSetup.add_Click({
        try { Set-Busy $true; Start-PlannerSetup }
        catch { Show-Message ("Set up stopped:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false; Update-PlannerSharing; Update-PlannerList; Update-PlannerData; Update-PlannerAutoBox }
    })
    $bCopy.add_Click({
        if ($script:PlannerLink) { [System.Windows.Forms.Clipboard]::SetText($script:PlannerLink); Set-Status 'Family link copied.' }
    })
    $bOpen.add_Click({ if ($script:PlannerLink) { Start-Process $script:PlannerLink } })
    $bOff.add_Click({
        try { Set-Busy $true; Stop-PlannerSharing }
        catch { Show-Message ("Could not turn the link off:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false; Update-PlannerSharing }
    })
    $bRefresh.add_Click({
        try {
            Set-Busy $true
            Set-Status 'Reading the world save...'
            $st = Invoke-PlannerEngine 'refresh'
            if ($null -eq $st) { Show-Message 'Python is not set up yet. Click Set up sharing first.'; return }
            Set-Status ([string]$st.message)
        }
        catch { Show-Message ("Refresh failed:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false; Update-PlannerData; Update-PlannerList }
    })
    $cAuto.add_SelectionChangeCommitted({
        try {
            $mins = @(0, 15, 30, 60)[$script:PlannerUI.Auto.SelectedIndex]
            if (Set-PlannerAuto $mins) {
                if ($mins -eq 0) { Set-Status 'Automatic updates are off. Use Refresh now.' }
                else { Set-Status ('The planner now updates every ' + $script:PlannerUI.Auto.Text.Replace('Every ', '') + ', even with this window closed.') }
            }
        }
        catch { Show-Message ("Could not change automatic updates:`n`n" + $_.Exception.Message) 'Error' }
        finally { Update-PlannerAutoBox }
    })
    $bAdd.add_Click({
        try {
            $p = Show-PlayerDialog $null
            if ($null -eq $p) { return }
            $script:PlannerList.Add($p)
            Set-Busy $true
            Invoke-PlannerLock ('Added ' + $p.real + '. Their code is ' + $p.code + '.')
            $script:PlannerUI.List.Items[$script:PlannerUI.List.Items.Count - 1].Selected = $true
        }
        catch { Show-Message ("Could not add the player:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })
    $bEdit.add_Click({ Edit-PlannerPlayer })
    $bCode.add_Click({
        try {
            $p = Get-SelectedPlayer
            if ($null -eq $p) { return }
            if (-not (Confirm-Action ('Make a new code for ' + $p.real + "?`n`nTheir old code stops working right away, so send them the new invite after."))) { return }
            $p.code = New-PlannerCode
            $p.invited = ''
            Set-Busy $true
            Invoke-PlannerLock ($p.real + "'s new code is " + $p.code + '. Send them a new invite.')
        }
        catch { Show-Message ("Could not make a new code:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })
    $bDel.add_Click({
        try {
            $p = Get-SelectedPlayer
            if ($null -eq $p) { return }
            if (-not (Confirm-Action ('Remove ' + $p.real + "?`n`nTheir code stops working right away. Their pals in the game are not touched."))) { return }
            [void]$script:PlannerList.Remove($p)
            Set-Busy $true
            Invoke-PlannerLock ('Removed ' + $p.real + '.')
        }
        catch { Show-Message ("Could not remove the player:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })
    $bText.add_Click({ try { Send-PlannerInvite 'text' } catch { Show-Message ("Could not make the invite:`n`n" + $_.Exception.Message) 'Error' } })
    $bMail.add_Click({ try { Send-PlannerInvite 'email' } catch { Show-Message ("Could not make the invite:`n`n" + $_.Exception.Message) 'Error' } })
    $bCopyInv.add_Click({ try { Send-PlannerInvite 'copy' } catch { Show-Message ("Could not make the invite:`n`n" + $_.Exception.Message) 'Error' } })
    $lv.add_DoubleClick({ Edit-PlannerPlayer })

    # --- Planner page: its name and who to ask for a code ---
    $g4 = New-Object VPalUi.CardGroup
    $g4.Text = 'Planner page'
    $g4.Font = $FontBold
    $g4.Location = New-Object System.Drawing.Point(10, 556)
    $g4.Size = New-Object System.Drawing.Size(860, 100)
    $g4.Controls.Add((New-SmallLabel 'The name at the top of the page and on everyone''s home screen, and who the page tells people to ask for a code.' 14 22 830))
    $site = Get-PlannerSite
    $tName = New-Object System.Windows.Forms.TextBox
    $tOwner = New-Object System.Windows.Forms.TextBox
    foreach ($t in @($tName, $tOwner)) { $t.Font = $FontMain; $t.Width = 150; $t.MaxLength = 30; $t.Margin = New-Object System.Windows.Forms.Padding(2, 2, 6, 0) }
    $tName.Text = $site.name
    $tOwner.Text = $site.owner
    $bSite = New-Button 'Save'
    $bSite.Font = $FontBold
    $g4.Controls.Add((New-Line 14 56 @('Name', $tName, 'Pal Planner      Your name', $tOwner, '(people see "Ask ___ for a code")', $bSite)))
    $ui.SiteName = $tName; $ui.SiteOwner = $tOwner
    $bSite.add_Click({
        try {
            $n = $script:PlannerUI.SiteName.Text.Trim()
            if (-not $n) { Show-Message 'Type a name for the page, for example your server''s name.'; return }
            Save-PlannerSite $n $script:PlannerUI.SiteOwner.Text
            Set-Busy $true
            Invoke-PlannerLock ('Saved. The page is now called ' + (Get-PlannerTitle) + '. Phones show it the next time they open it.')
        }
        catch { Show-Message ("Could not save:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })

    $page.Controls.Add($g1)
    $page.Controls.Add($g2)
    $page.Controls.Add($g3)
    $page.Controls.Add($g4)
    $tabs.TabPages.Add($page)
    try { Read-PlannerPlayers } catch { }
    Update-PlannerList
    Update-PlannerData
}

function Update-PlannerAutoBox {
    $c = $script:PlannerUI.Auto
    if (-not $c -or $c.IsDisposed) { return }
    $m = Get-PlannerAutoMinutes
    $i = 0
    if ($m -ge 60) { $i = 3 } elseif ($m -ge 30) { $i = 2 } elseif ($m -gt 0) { $i = 1 }
    $c.SelectedIndex = $i
}

function Update-PlannerTab {
    # Called when the tab is opened: checks Tailscale and the scheduled task (takes about a second).
    try { Update-PlannerSharing } catch { }
    try { Update-PlannerAutoBox } catch { }
    try { Update-PlannerData; Update-PlannerList } catch { }
}

# ---------------- Watchdog, Players, Backups and Discord tabs (they talk to the watchdog on this PC) ----------------
$script:WD = @{}
$script:PL = @{}
$script:BK = @{}
$script:DC = @{}

function Format-Unix($t) {
    if ($null -eq $t -or "$t" -eq '') { return '' }
    $n = [double]$t
    if ($n -le 0) { return '' }
    $d = [DateTimeOffset]::FromUnixTimeSeconds([long]$n).LocalDateTime
    $today = (Get-Date).Date
    if ($d.Date -eq $today) { return 'Today ' + $d.ToString('h:mm tt') }
    if ($d.Date -eq $today.AddDays(-1)) { return 'Yesterday ' + $d.ToString('h:mm tt') }
    if ($d.Date -eq $today.AddDays(1)) { return 'Tomorrow ' + $d.ToString('h:mm tt') }
    return $d.ToString('ddd MMM d, h:mm tt')
}

function Format-Dur($Seconds) {
    $s = [double]$Seconds
    if ($s -lt 60) { return 'under a minute' }
    $m = [int][Math]::Floor($s / 60)
    if ($m -lt 60) { return "$m min" }
    $h = [int][Math]::Floor($m / 60)
    if ($h -lt 48) {
        if ($m % 60) { return ('{0} h {1} min' -f $h, ($m % 60)) }
        return "$h h"
    }
    return ('{0} days' -f [int][Math]::Floor($h / 24))
}

function Format-Bytes($Bytes) {
    $x = [double]$Bytes
    if ($x -ge 1GB) { return ('{0:0.0} GB' -f ($x / 1GB)) }
    return ('{0:0} MB' -f [Math]::Max(1, ($x / 1MB)))
}

function Get-NowUnix { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function New-Group([string]$Title, [int]$Y, [int]$Height) {
    $g = New-Object VPalUi.CardGroup
    $g.Text = $Title
    $g.Font = $FontBold
    $g.Location = New-Object System.Drawing.Point(10, $Y)
    $g.Size = New-Object System.Drawing.Size(860, $Height)
    return $g
}

function New-Text([string]$Text, [int]$X, [int]$Y, [int]$Width, [switch]$Bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.UseMnemonic = $false
    $l.MaximumSize = New-Object System.Drawing.Size($Width, 0)
    if ($Bold) { $l.Font = $FontBold } else { $l.Font = $FontMain }
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Text = $Text
    return $l
}

function New-Check([string]$Text) {
    $c = New-Object VPalUi.Check
    $c.Text = $Text
    $c.AutoSize = $true
    $c.UseMnemonic = $false
    $c.Font = $FontMain
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 6, 2, 0)
    return $c
}

function New-Num([decimal]$Min, [decimal]$Max, [int]$Places) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $Min
    $n.Maximum = $Max
    $n.DecimalPlaces = $Places
    if ($Places -gt 0) { $n.Increment = 0.5 }
    $n.Width = 64
    $n.Font = $FontMain
    $n.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 0)
    return $n
}

function New-Line([int]$X, [int]$Y, [object[]]$Parts) {
    # One row of controls and words, laid out left to right (checkbox, number box, words, ...).
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.AutoSizeMode = 'GrowAndShrink'
    $f.WrapContents = $false
    $f.Location = New-Object System.Drawing.Point($X, $Y)
    foreach ($p in $Parts) {
        if ($p -is [string]) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $p
            $l.AutoSize = $true
            $l.UseMnemonic = $false
            $l.Font = $FontMain
            $l.Margin = New-Object System.Windows.Forms.Padding(0, 7, 2, 0)
            $f.Controls.Add($l)
        }
        elseif ($p -is [System.Windows.Forms.NumericUpDown]) {
            # number boxes get the - and + buttons (the NumericUpDown itself is still what the code reads)
            $st = New-Object VPalUi.Stepper -ArgumentList @($p, ($p.Width + 64))
            $p.Font = $FontBold
            $st.Height = 30
            $st.Margin = New-Object System.Windows.Forms.Padding(2, 0, 4, 0)
            $f.Controls.Add($st)
        }
        else { $f.Controls.Add($p) }
    }
    return $f
}

function New-TimeBox {
    $t = New-Object System.Windows.Forms.DateTimePicker
    $t.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
    $t.CustomFormat = 'h:mm tt'
    $t.ShowUpDown = $true
    $t.Width = 96
    $t.Font = $FontMain
    $t.Margin = New-Object System.Windows.Forms.Padding(2, 1, 6, 0)
    $t.Value = [datetime]::Today.AddHours(1)
    return $t
}

function Set-TimeBox($Box, [string]$HM) {
    try {
        $p = $HM.Split(':')
        $Box.Value = [datetime]::Today.AddHours([int]$p[0]).AddMinutes([int]$p[1])
    }
    catch { }
}

function New-ButtonRow([int]$X, [int]$Y, [object[]]$Buttons) {
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.AutoSizeMode = 'GrowAndShrink'
    $f.WrapContents = $false
    $f.Location = New-Object System.Drawing.Point($X, $Y)
    foreach ($b in $Buttons) {
        if ($b -is [System.Windows.Forms.Button]) { $b.Font = $FontMain }
        $f.Controls.Add($b)
    }
    return $f
}

function New-List([int]$X, [int]$Y, [int]$W, [int]$H, [object[]]$Cols) {
    $lv = New-Object VPalUi.DarkList
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.ShowItemToolTips = $true
    $lv.Font = $FontMain
    $lv.Location = New-Object System.Drawing.Point($X, $Y)
    $lv.Size = New-Object System.Drawing.Size($W, $H)
    foreach ($c in $Cols) { [void]$lv.Columns.Add([string]$c[0], [int]$c[1]) }
    return $lv
}

function New-ToolPage([string]$Title) {
    # a Server page: its header and scrolling body are added when it joins the window
    $page = New-VPage $Title 'Server'
    $page.WrapContent = $true
    return $page
}

function Show-Error([string]$What, $Err) {
    Show-Message ($What + "`n`n" + [string]$Err.Exception.Message) 'Warning'
}

# ---------- Watchdog tab ----------
function New-WatchdogTab {
    $page = New-ToolPage 'Watchdog'
    $ui = @{}

    $g1 = New-Group 'Status' 10 232
    $g1.Controls.Add((New-SmallLabel 'Runs in the background all the time, even with this window closed. It starts the server again after a crash or a freeze, restarts it with a warning when memory runs high or a game update comes out, backs up the world and runs the Discord bot.' 14 22 830))
    $ui.State = New-Text 'Checking...' 14 70 830 -Bold
    $info = New-Object System.Windows.Forms.Label
    $info.AutoSize = $false
    $info.UseMnemonic = $false
    $info.Font = $FontMain
    $info.Location = New-Object System.Drawing.Point(14, 92)
    $info.Size = New-Object System.Drawing.Size(830, 74)
    $ui.Info = $info
    $ui.Job = New-Text '' 14 168 830 -Bold
    $ui.Job.ForeColor = $ColorStarting
    $ui.Cancel = New-Button 'Cancel it'
    $ui.Resume = New-Button 'Turn the watchdog back on'
    $ui.Start = New-Button 'Start the watchdog'
    $ui.CheckUpd = New-Button 'Check for a game update now'
    $ui.VPalChk = New-Button 'Check for VPal updates'
    $ui.VPalNote = New-Text '' 0 0 330
    $ui.VPalNote.ForeColor = $ColorDesc
    $ui.VPalNote.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    $ui.Start.Visible = $false
    $ui.Cancel.Visible = $false
    $ui.Resume.Visible = $false
    foreach ($c in @($ui.State, $info, $ui.Job, (New-ButtonRow 10 190 @($ui.Cancel, $ui.Resume, $ui.Start, $ui.CheckUpd, $ui.VPalChk, $ui.VPalNote)))) { $g1.Controls.Add($c) }
    $ui.Start.Font = $FontBold

    $g2 = New-Group 'What it does' 252 240
    $ui.On = New-Check 'Watch the server and step in when something goes wrong'
    $ui.On.Font = $FontBold
    $ui.Crash = New-Check 'Start it again after a crash'
    $ui.Freeze = New-Check 'Restart it when it stops answering for'
    $ui.FreezeMin = New-Num 2 30 0
    $ui.Mem = New-Check 'Restart it with a'
    $ui.MemWarn = New-Num 0 15 0
    $ui.MemGb = New-Num 0 512 1
    $ui.MemAuto = New-Object System.Windows.Forms.Label
    $ui.MemAuto.AutoSize = $true
    $ui.MemAuto.Font = $FontMain
    $ui.MemAuto.ForeColor = $ColorDesc
    $ui.MemAuto.Margin = New-Object System.Windows.Forms.Padding(4, 5, 2, 0)
    $ui.Upd = New-Check 'Check Steam for a new game version every hour'
    $ui.UpdRestart = New-Check 'Restart to install it, with a'
    $ui.UpdWarn = New-Num 0 30 0
    $ui.SaveCfg = New-Button 'Save watchdog settings'
    $ui.SaveCfg.Font = $FontBold
    $ui.CfgNote = New-Text '' 0 0 520
    $ui.CfgNote.ForeColor = $ColorDesc
    $ui.CfgNote.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
    $g2.Controls.Add((New-Line 14 24 @($ui.On)))
    $g2.Controls.Add((New-Line 34 54 @($ui.Crash)))
    $g2.Controls.Add((New-Line 34 82 @($ui.Freeze, $ui.FreezeMin, 'minutes')))
    $g2.Controls.Add((New-Line 34 110 @($ui.Mem, $ui.MemWarn, '-minute warning when its memory goes over', $ui.MemGb, 'GB', $ui.MemAuto)))
    $g2.Controls.Add((New-Line 34 138 @($ui.Upd)))
    $g2.Controls.Add((New-Line 54 166 @($ui.UpdRestart, $ui.UpdWarn, '-minute warning')))
    $g2.Controls.Add((New-ButtonRow 10 198 @($ui.SaveCfg, $ui.CfgNote)))
    $ui.SaveCfg.Font = $FontBold

    $g4 = New-Group 'Daily restarts' 502 168
    $g4.Controls.Add((New-SmallLabel 'A fresh start every day keeps memory low and the server smooth. Players get warnings in the game first, the world is backed up, then the server starts again the usual way (StartServer.bat also installs any game update).' 14 22 830))
    $ui.Sched = New-Check 'Restart the server every day at'
    $ui.T1 = New-TimeBox
    $ui.Sched2 = New-Check 'and at'
    $ui.T2 = New-TimeBox
    Set-TimeBox $ui.T2 '13:00'
    $ui.SchedWarn = New-Num 0 15 0
    $g4.Controls.Add((New-Line 14 60 @($ui.Sched, $ui.T1, $ui.Sched2, $ui.T2, ', with a', $ui.SchedWarn, '-minute warning')))
    $ui.OldNote = New-SmallLabel '' 14 90 830
    $ui.OldNote.ForeColor = $ColorStarting
    $g4.Controls.Add($ui.OldNote)
    $ui.SaveSched = New-Button 'Save restart times'
    $ui.SwitchBtn = New-Button 'Switch to VPal''s schedule'
    $ui.SchedNote = New-Text '' 0 0 420
    $ui.SchedNote.ForeColor = $ColorDesc
    $ui.SchedNote.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
    $g4.Controls.Add((New-ButtonRow 10 126 @($ui.SaveSched, $ui.SwitchBtn, $ui.SchedNote)))
    $ui.SaveSched.Font = $FontBold

    $g3 = New-Group 'Recent activity' 680 266
    $ui.List = New-List 14 24 830 196 @(@('When', 150), @('What happened', 656))
    $ui.Refresh = New-Button 'Refresh'
    $ui.Copy = New-Button 'Copy the list'
    $g3.Controls.Add($ui.List)
    $g3.Controls.Add((New-ButtonRow 10 226 @($ui.Refresh, $ui.Copy)))

    $script:WD = $ui

    $ui.Start.add_Click({
        try { Set-Busy $true; [void](Start-Watchdog) }
        catch { Show-Error 'Could not start the watchdog:' $_ }
        finally { Set-Busy $false; Update-WatchdogStatus; Update-WatchdogSettings; Update-Activity -Force }
    })
    $ui.Cancel.add_Click({
        try { [void](Invoke-CC 'job/cancel' @{}); Set-Status 'Cancelled.' }
        catch { Show-Error 'Could not cancel:' $_ }
        finally { Update-WatchdogStatus }
    })
    $ui.Resume.add_Click({
        try { [void](Invoke-CC 'hold/clear' @{}); Set-Status 'The watchdog is watching the server again.' }
        catch { Show-Error 'Could not turn the watchdog back on:' $_ }
        finally { Update-WatchdogStatus }
    })
    $ui.CheckUpd.add_Click({
        try { [void](Invoke-CC 'update/check' @{}); Set-Status 'Checking Steam for a new game version. This takes a minute.' }
        catch { Show-Error 'Could not check for an update:' $_ }
        finally { Update-WatchdogStatus }
    })
    $ui.VPalChk.add_Click({
        try {
            Set-Status 'Checking for a VPal update...'
            $i = Invoke-CC 'vpal-update/check' @{}
            Update-VPalUpdate $i
            if ($i.available) { Start-VPalUpdate }
            elseif ($i.error) { Show-Message ([string]$i.error) 'Warning' }
            elseif (-not $i.feed) { Show-Message (Format-VPalUpdateNote $i) }
            else { Set-Status ('VPal ' + [string]$i.current + ' is the newest version.') }
        }
        catch { Show-Error 'Could not check for a VPal update:' $_ }
    })
    $ui.SaveCfg.add_Click({
        $w = $script:WD
        try {
            $body = @{
                watchdog = @{ enabled = [bool]$w.On.Checked; crash_restart = [bool]$w.Crash.Checked; freeze_restart = [bool]$w.Freeze.Checked
                              freeze_minutes = [int]$w.FreezeMin.Value }
                memory   = @{ enabled = [bool]$w.Mem.Checked; warn_minutes = [int]$w.MemWarn.Value; limit_gb = [double]$w.MemGb.Value }
                updates  = @{ enabled = [bool]$w.Upd.Checked; auto_restart = [bool]$w.UpdRestart.Checked; warn_minutes = [int]$w.UpdWarn.Value }
            }
            [void](Invoke-CC 'config' $body)
            $w.CfgNote.Text = 'Saved at ' + (Get-Date -Format 'h:mm tt') + '.'
        }
        catch { Show-Error 'Could not save the watchdog settings:' $_ }
        finally { Update-WatchdogSettings; Update-WatchdogStatus }
    })
    $ui.On.add_Click({ Update-WatchdogEnabled })
    $ui.Upd.add_Click({ Update-WatchdogEnabled })
    $ui.Refresh.add_Click({ Update-WatchdogStatus; Update-Activity -Force })
    $ui.Copy.add_Click({
        $lines = foreach ($it in $script:WD.List.Items) { $it.Text + '   ' + $it.SubItems[1].Text }
        if ($lines) { [System.Windows.Forms.Clipboard]::SetText((@($lines) -join "`r`n")); Set-Status 'Activity list copied.' }
    })

    $ui.Sched.add_Click({ Update-WatchdogEnabled })
    $ui.Sched2.add_Click({ Update-WatchdogEnabled })
    $ui.SaveSched.add_Click({
        $w = $script:WD
        try {
            $times = @(Get-ScheduleTimes)
            if ($w.Sched.Checked -and (Test-OldRestartTask)) {
                $ask = 'Your own restart task (' + [string]$w.Cfg.external_restart_task + ') still restarts the server too, so it would restart twice.' + "`n`n" +
                       'Click Switch to VPal''s schedule instead: it turns your old task off.' + "`n`n" + 'Save anyway?'
                if (-not (Confirm-Action $ask)) { return }
            }
            [void](Invoke-CC 'config' @{ schedule = @{ enabled = [bool]$w.Sched.Checked; times = @($times); warn_minutes = [int]$w.SchedWarn.Value } })
            if ($w.Sched.Checked) { Set-Status ('The server restarts every day at ' + (Format-ScheduleTimes $times) + '.') }
            else { Set-Status 'Daily restarts are off.' }
        }
        catch { Show-Error 'Could not save the restart times:' $_ }
        finally { Update-WatchdogSettings; Update-WatchdogStatus }
    })
    $ui.SwitchBtn.add_Click({
        try { Set-Busy $true; Switch-ToVPalSchedule }
        catch { Show-Error 'Could not switch the restart schedule:' $_ }
        finally { Set-Busy $false; Update-WatchdogSettings; Update-WatchdogStatus }
    })

    foreach ($g in @($g1, $g2, $g4, $g3)) { $page.Controls.Add($g) }
    $tabs.TabPages.Add($page)
}

function Get-ScheduleTimes {
    $w = $script:WD
    $t = @($w.T1.Value.ToString('HH:mm', $Inv))
    if ($w.Sched2.Checked) { $t += $w.T2.Value.ToString('HH:mm', $Inv) }
    return @($t | Select-Object -Unique)
}

function Format-ScheduleTimes($Times) {
    $out = foreach ($t in @($Times)) {
        try {
            $p = ([string]$t).Split(':')
            [datetime]::Today.AddHours([int]$p[0]).AddMinutes([int]$p[1]).ToString('h:mm tt')
        }
        catch { [string]$t }
    }
    return (@($out) -join ' and ')
}

function Test-OldRestartTask {
    # True while your own restart script still has a Windows task (VPal plans around it until you switch).
    $w = $script:WD
    if (-not $w.Cfg -or -not [string]$w.Cfg.external_restart_task) { return $false }
    return (Test-Path -LiteralPath (Join-Path $ServerDir 'RestartServer.ps1'))
}

function Switch-ToVPalSchedule {
    # Turns off your own restart task (Windows asks for administrator permission once) and turns on VPal's daily restarts.
    $w = $script:WD
    $task = [string]$w.Cfg.external_restart_task
    if (-not $task) { return }
    $times = @(Get-ScheduleTimes)
    $nice = Format-ScheduleTimes $times
    $ask = 'Switch to VPal''s restart schedule?' + "`n`n" +
           'Windows asks for administrator permission once, to turn off your old restart task (' + $task + '). Then VPal restarts the server every day at ' +
           $nice + ', with warnings in the game and a backup first.' + "`n`n" + 'You can change the times on this tab any time. Your old RestartServer.ps1 file is left as it is.'
    if (-not (Confirm-Action $ask)) { return }
    $cmd = "Get-ScheduledTask -TaskName '" + $task.Replace("'", "''") + "' -ErrorAction Stop | Disable-ScheduledTask -ErrorAction Stop | Out-Null"
    $p = $null
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop `
                -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"')
    }
    catch {
        Show-Message 'Nothing was changed: Windows did not get administrator permission, so your old restart task is still on.' 'Warning'
        return
    }
    if ($null -eq $p -or $p.ExitCode -ne 0) {
        Show-Message ('Windows could not turn off the task "' + $task + '". Nothing was changed.' + "`n`n" +
                      'You can turn it off yourself in Task Scheduler, then tick Restart the server every day and click Save restart times.') 'Warning'
        return
    }
    [void](Invoke-CC 'config' @{ external_restart_task = ''; schedule = @{ enabled = $true; times = @($times); warn_minutes = [int]$w.SchedWarn.Value } })
    Set-Status ('Switched: VPal restarts the server every day at ' + $nice + '. Your old restart task is off.')
}

function Update-WatchdogEnabled {
    $w = $script:WD
    foreach ($c in @($w.Crash, $w.Freeze, $w.FreezeMin, $w.Mem, $w.MemWarn, $w.MemGb, $w.Upd)) { $c.Enabled = [bool]$w.On.Checked }
    foreach ($c in @($w.T1, $w.Sched2, $w.SchedWarn)) { $c.Enabled = [bool]$w.Sched.Checked }
    $w.T2.Enabled = [bool]($w.Sched.Checked -and $w.Sched2.Checked)
    $w.UpdRestart.Enabled = [bool]($w.On.Checked -and $w.Upd.Checked)
    $w.UpdWarn.Enabled = $w.UpdRestart.Enabled
}

function Set-NumValue($Box, $Value) {
    $v = [decimal]0
    try { $v = [decimal]$Value } catch { }
    if ($v -lt $Box.Minimum) { $v = $Box.Minimum }
    if ($v -gt $Box.Maximum) { $v = $Box.Maximum }
    $Box.Value = $v
}

function Update-WatchdogSettings {
    $w = $script:WD
    if (-not $w.On -or $w.On.IsDisposed) { return }
    $c = $null
    try { $c = Invoke-CC 'config' $null 5 } catch { }
    $w.SaveCfg.Enabled = ($null -ne $c)
    $w.SaveSched.Enabled = ($null -ne $c)
    if ($null -eq $c) { $w.CfgNote.Text = 'Start the watchdog to change these.'; $w.SwitchBtn.Visible = $false; return }
    $sc = $c.schedule
    $times = @($sc.times | Where-Object { $_ })
    $w.Sched.Checked = [bool]$sc.enabled
    if ($times.Count -ge 1) { Set-TimeBox $w.T1 ([string]$times[0]) }
    $w.Sched2.Checked = ($times.Count -ge 2)
    if ($times.Count -ge 2) { Set-TimeBox $w.T2 ([string]$times[1]) }
    Set-NumValue $w.SchedWarn $sc.warn_minutes
    $w.On.Checked = [bool]$c.watchdog.enabled
    $w.Crash.Checked = [bool]$c.watchdog.crash_restart
    $w.Freeze.Checked = [bool]$c.watchdog.freeze_restart
    Set-NumValue $w.FreezeMin $c.watchdog.freeze_minutes
    $w.Mem.Checked = [bool]$c.memory.enabled
    Set-NumValue $w.MemWarn $c.memory.warn_minutes
    Set-NumValue $w.MemGb $c.memory.limit_gb
    $w.MemAuto.Text = '(0 = automatic, ' + [string]$c._auto.memLimit + ' GB on this PC)'
    $w.Upd.Checked = [bool]$c.updates.enabled
    $w.UpdRestart.Checked = [bool]$c.updates.auto_restart
    Set-NumValue $w.UpdWarn $c.updates.warn_minutes
    if ($w.CfgNote.Text -like 'Start the watchdog*') { $w.CfgNote.Text = '' }
    $w.Cfg = $c
    $old = Test-OldRestartTask
    $w.SwitchBtn.Visible = $old
    if ($old) {
        $w.OldNote.Text = 'Your own restart task (' + [string]$c.external_restart_task + ', which runs RestartServer.ps1) restarts the server right now. ' +
                          'Click Switch to VPal''s schedule to use these times instead, so the server never restarts twice.'
    }
    else { $w.OldNote.Text = '' }
    if ($sc.enabled -and $times.Count) { $w.SchedNote.Text = 'Next: ' + (Format-ScheduleTimes $times) + ' every day.' }
    elseif ($old) { $w.SchedNote.Text = '' }
    else { $w.SchedNote.Text = 'Daily restarts are off.' }
    Update-WatchdogEnabled
}

function Update-WatchdogStatus {
    $w = $script:WD
    if (-not $w.State -or $w.State.IsDisposed) { return }
    $w.Cancel.Visible = $false
    $w.Resume.Visible = $false
    $w.Job.Text = ''
    $st = $null
    $running = Test-CommandCenter
    if ($running) { try { $st = Invoke-CC 'status' $null 5 } catch { } }
    if ($null -eq $st) {
        $w.CheckUpd.Visible = $false
        $w.VPalChk.Visible = $false
        $w.VPalNote.Text = ''
        $w.State.ForeColor = $ColorOff
        if (-not (Test-Path -LiteralPath $CCService)) {
            $w.Start.Visible = $false
            $w.State.Text = 'Watchdog: not installed'
            $w.Info.Text = 'Its files are missing. Extract the latest update zip into ' + $ServerDir + ' (choose Replace).'
        }
        elseif ($running) {
            $w.Start.Visible = $false
            $w.State.Text = 'Watchdog: running, but not answering'
            $w.Info.Text = 'It may be busy for a moment. If this stays for more than a minute, run the Health check.'
        }
        else {
            $w.Start.Visible = $true
            $w.State.Text = 'Watchdog: off'
            $w.Info.Text = 'Crashes and freezes are not being caught, and backups are not being made. Click Start the watchdog.'
        }
        return
    }
    $w.Start.Visible = $false
    $w.CheckUpd.Visible = $true
    $w.VPalChk.Visible = $true

    $want = Get-CCFileVersion
    $enabled = $true
    if ($w.Cfg) { $enabled = [bool]$w.Cfg.watchdog.enabled }
    if ($want -and [string]$st.version -ne $want) {
        $w.State.Text = 'Watchdog: updating itself to version ' + $want + '...'
        $w.State.ForeColor = $ColorStarting
    }
    elseif ($st.hold) {
        $w.State.Text = 'Watchdog: standing aside (' + [string]$st.hold.reason + ')'
        $w.State.ForeColor = $ColorStarting
        $w.Resume.Visible = $true
    }
    elseif ($st.maintenance) {
        $w.State.Text = 'Watchdog: standing aside while the scheduled restart or a game update runs'
        $w.State.ForeColor = $ColorStarting
    }
    elseif (-not $st.restApi) {
        $w.State.Text = 'Watchdog: running, but it cannot see the server'
        $w.State.ForeColor = $ColorOff
    }
    elseif (-not $enabled) {
        $w.State.Text = 'Watchdog: running, but watching is turned off below'
        $w.State.ForeColor = $ColorStarting
    }
    else {
        $w.State.Text = 'Watchdog: running and watching the server'
        $w.State.ForeColor = $ColorOn
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $s = 'Server: ' + [string]$st.state
    if ($st.state -eq 'running' -and $null -ne $st.uptime) { $s += ' for ' + (Format-Dur $st.uptime) }
    if ($st.state -ne 'off') {
        $s += '  |  ' + [string]$st.players + ' online'
        if ($null -ne $st.fps) { $s += '  |  ' + [string]$st.fps + ' FPS' }
        if ($null -ne $st.mem) {
            $s += '  |  memory ' + [string]$st.mem + ' GB (restarts at ' + [string]$st.memLimit + ' GB'
            if ($st.forecast -and $st.forecast.hours) { $s += ', about ' + [string]$st.forecast.hours + ' hours away at this rate' }
            $s += ')'
        }
    }
    $lines.Add($s)
    if (-not $st.restApi) { $lines.Add('Turn on RESTAPIEnabled (Server tab) and restart the server, so the watchdog can talk to it.') }
    $next = @()
    if ($st.nextRestart.task) { $next += (Format-Unix $st.nextRestart.task) + ' (your restart task)' }
    if ($st.nextRestart.scheduled) { $next += (Format-Unix $st.nextRestart.scheduled) + ' (daily restart)' }
    $s = 'Next planned restart: '
    if ($next.Count) { $s += ($next -join ', ') } else { $s += 'none' }
    if ($st.lastBackup) { $s += '  |  Last backup: ' + (Format-Dur ((Get-NowUnix) - [double]$st.lastBackup)) + ' ago' }
    else { $s += '  |  Last backup: none yet' }
    $lines.Add($s)
    $u = $st.update
    if ($u -and $u.error) { $lines.Add('Game updates: could not check (' + [string]$u.error + ')') }
    elseif ($u -and $u.latest) {
        if ([string]$u.latest -ne [string]$u.installed) { $lines.Add('Game updates: a new version is out (build ' + [string]$u.latest + '). Checked ' + (Format-Unix $u.checked) + '.') }
        else { $lines.Add('Game updates: up to date (build ' + [string]$u.installed + '). Checked ' + (Format-Unix $u.checked) + '.') }
    }
    if ($st.hold) { $lines.Add('It leaves the server alone until you start it (or click Turn the watchdog back on).') }
    $w.Info.Text = ($lines -join "`n")

    if ($st.job) {
        $j = 'Doing now: ' + [string]$st.job.text
        if ($st.job.step) { $j += ' - ' + [string]$st.job.step }
        elseif ($null -ne $st.job.left) { $j += ' - warning players, ' + (Format-Dur ([double]$st.job.left)) + ' to go' }
        $w.Job.Text = $j
        $w.Cancel.Visible = (@('restart', 'stop', 'restore', 'memory', 'update', 'schedule') -contains [string]$st.job.kind) -and -not $st.job.step
    }
    else {
        $bg = @()
        if ($st.background) { $bg = @($st.background.PSObject.Properties | ForEach-Object { [string]$_.Value }) }
        if ($bg.Count) { $w.Job.Text = 'Doing now: ' + ($bg -join ', ') }
    }
}

function Update-Activity([switch]$Force) {
    $w = $script:WD
    if (-not $w.List -or $w.List.IsDisposed) { return }
    $r = $null
    try { $r = Invoke-CC 'events?limit=200' $null 5 } catch { return }
    $ev = @($r.list | Where-Object { $_ })
    $key = [string]$ev.Count
    if ($ev.Count) { $key += ':' + [string]$ev[-1].t + [string]$ev[-1].text }
    if (-not $Force -and $key -eq $w.ListKey) { return }
    $w.ListKey = $key
    $lv = $w.List
    $lv.BeginUpdate()
    $lv.Items.Clear()
    for ($i = $ev.Count - 1; $i -ge 0; $i--) {
        $e = $ev[$i]
        $it = New-Object System.Windows.Forms.ListViewItem([string](Format-Unix $e.t))
        [void]$it.SubItems.Add([string]$e.text)
        $it.ToolTipText = [string]$e.text
        switch ([string]$e.level) {
            'bad'  { $it.ForeColor = $ColorBad }
            'warn' { $it.ForeColor = $ColorFair }
            'good' { $it.ForeColor = $ColorGood }
        }
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
}

# ---------- Players tab ----------
function New-PlayersTab {
    $page = New-ToolPage 'Players'
    $ui = @{}
    $g1 = New-Group 'Players' 10 400
    $g1.Controls.Add((New-SmallLabel 'Everyone who has played on this server. Kick removes someone for now (they can join again). Ban keeps them out until you unban them.' 14 22 830))
    $ui.List = New-List 14 56 830 262 @(@('Name', 150), @('Level', 50), @('Status', 220), @('Playtime', 90), @('Visits', 50), @('Whitelist', 70), @('Player ID', 180))
    $ui.Kick = New-Button 'Kick'
    $ui.Ban = New-Button 'Ban'
    $ui.Unban = New-Button 'Unban'
    $ui.WlAdd = New-Button 'Add to whitelist'
    $ui.WlDel = New-Button 'Take off whitelist'
    $ui.Refresh = New-Button 'Refresh'
    $ui.WlAdd.Margin = New-Object System.Windows.Forms.Padding(24, 0, 4, 0)
    $ui.Refresh.Margin = New-Object System.Windows.Forms.Padding(24, 0, 4, 0)
    $ui.Note = New-SmallLabel '' 14 368 830
    $g1.Controls.Add($ui.List)
    $g1.Controls.Add((New-ButtonRow 10 328 @($ui.Kick, $ui.Ban, $ui.Unban, $ui.WlAdd, $ui.WlDel, $ui.Refresh)))
    $g1.Controls.Add($ui.Note)

    $g2 = New-Group 'Whitelist' 420 122
    $g2.Controls.Add((New-SmallLabel 'When this is on, only players on the whitelist can stay. Anyone else is removed as soon as they join and shows up above as "Turned away", so you can add them with one click.' 14 22 830))
    $ui.WlOn = New-Check 'Only let in players on the whitelist'
    $ui.WlCount = New-Object System.Windows.Forms.Label
    $ui.WlCount.AutoSize = $true
    $ui.WlCount.Font = $FontMain
    $ui.WlCount.ForeColor = $ColorDesc
    $ui.WlCount.Margin = New-Object System.Windows.Forms.Padding(16, 5, 0, 0)
    $g2.Controls.Add((New-Line 14 76 @($ui.WlOn, $ui.WlCount)))

    $script:PL = $ui

    $ui.Kick.add_Click({ Invoke-PlayerAction 'kick' })
    $ui.Ban.add_Click({ Invoke-PlayerAction 'ban' })
    $ui.Unban.add_Click({ Invoke-PlayerAction 'unban' })
    $ui.WlAdd.add_Click({ Set-Whitelisted $true })
    $ui.WlDel.add_Click({ Set-Whitelisted $false })
    $ui.Refresh.add_Click({ Update-PlayersTab -Force })
    $ui.List.add_SelectedIndexChanged({ Update-PlayerButtons })
    $ui.WlOn.add_Click({
        $p = $script:PL
        try {
            $ids = @($p.Data.whitelist.ids)
            if ($p.WlOn.Checked) {
                $everyone = @($p.Data.known | Where-Object { $_ -and -not $_.turned_away } | ForEach-Object { [string]$_.id })
                $missing = @($everyone | Where-Object { $ids -notcontains $_ })
                $ask = 'Turn the whitelist on?' + "`n`n" + 'Only players on the list can stay; anyone else is removed as soon as they join.'
                if ($missing.Count) { $ask += "`n`n" + $missing.Count + ' player(s) who already played here are not on the list yet. They will be added now, so nobody you know is locked out.' }
                if (-not (Confirm-Action $ask)) { $p.WlOn.Checked = $false; return }
                $ids = @($ids + $missing | Where-Object { $_ } | Select-Object -Unique)
            }
            [void](Invoke-CC 'whitelist' @{ enabled = [bool]$p.WlOn.Checked; ids = @($ids) })
            if ($p.WlOn.Checked) { Set-Status 'The whitelist is on.' } else { Set-Status 'The whitelist is off. Anyone can join.' }
        }
        catch { Show-Error 'Could not change the whitelist:' $_ }
        finally { Update-PlayersTab -Force }
    })

    foreach ($g in @($g1, $g2)) { $page.Controls.Add($g) }
    $tabs.TabPages.Add($page)
}

function Get-SelectedPlayerRow {
    $lv = $script:PL.List
    if (-not $lv -or $lv.SelectedItems.Count -eq 0) { return $null }
    return $lv.SelectedItems[0].Tag
}

function Update-PlayerButtons {
    $p = $script:PL
    $r = Get-SelectedPlayerRow
    $p.Kick.Enabled = [bool]($r -and $r.Online)
    $p.Ban.Enabled = [bool]($r -and -not $r.Banned)
    $p.Unban.Enabled = [bool]($r -and $r.Banned)
    $p.WlAdd.Enabled = [bool]($r -and -not $r.Listed)
    $p.WlDel.Enabled = [bool]($r -and $r.Listed)
}

function Update-PlayersTab([switch]$Force) {
    $p = $script:PL
    if (-not $p.List -or $p.List.IsDisposed) { return }
    $d = $null
    try { $d = Invoke-CC 'players' $null 5 }
    catch {
        $p.Note.Text = [string]$_.Exception.Message
        foreach ($b in @($p.Kick, $p.Ban, $p.Unban, $p.WlAdd, $p.WlDel, $p.WlOn)) { $b.Enabled = $false }
        return
    }
    $p.WlOn.Enabled = $true
    $p.Data = $d
    $bans = @($d.bans | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() })
    $wl = @($d.whitelist.ids | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() })
    $online = @{}
    foreach ($o in @($d.online | Where-Object { $_ })) { $online[[string]$o.id] = $o }
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($k in @($d.known | Where-Object { $_ })) {
        $id = [string]$k.id
        $seen[$id.ToLower()] = $true
        $names = @($id.ToLower(), ([string]$k.playerId).ToLower(), ([string]$k.name).ToLower())
        $row = [pscustomobject]@{
            Id = $id; Name = [string]$k.name; Level = [string]$k.level; Online = $online.ContainsKey($id)
            Banned = [bool](@($names | Where-Object { $_ -and $bans -contains $_ }).Count)
            Listed = [bool](@($names | Where-Object { $_ -and $wl -contains $_ }).Count)
            Status = ''; Play = (Format-Dur ([double]$k.play)); Visits = [string]$k.sessions
        }
        if ($row.Online) { $row.Status = 'Online now (since ' + (Format-Unix $online[$id].since) + ')' }
        elseif ($row.Banned) { $row.Status = 'Banned' }
        elseif ($k.turned_away -and -not $row.Listed) { $row.Status = 'Turned away ' + (Format-Unix $k.turned_away) }
        elseif ($k.last) { $row.Status = 'Last seen ' + (Format-Unix $k.last) }
        if ([double]$k.play -le 0) { $row.Play = '' }
        $rows.Add($row)
    }
    foreach ($b in $bans) {
        if ($seen.ContainsKey($b)) { continue }
        $rows.Add([pscustomobject]@{ Id = $b; Name = '(not seen here)'; Level = ''; Online = $false; Banned = $true; Listed = ($wl -contains $b)
                                     Status = 'Banned'; Play = ''; Visits = '' })
    }
    $sorted = @($rows | Sort-Object @{ Expression = { -not $_.Online } }, @{ Expression = { $_.Name } })
    $key = (@($sorted | ForEach-Object { $_.Id + $_.Status + $_.Level + $_.Play + $_.Listed + $_.Banned }) -join '|') + [string]$d.whitelist.enabled
    if ($Force -or $key -ne $p.Key) {
        $p.Key = $key
        $selId = $null
        $cur = Get-SelectedPlayerRow
        if ($cur) { $selId = $cur.Id }
        $lv = $p.List
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($r in $sorted) {
            $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
            $wlText = ''
            if ($r.Listed) { $wlText = 'Yes' }
            foreach ($sub in @($r.Level, $r.Status, $r.Play, $r.Visits, $wlText, $r.Id)) { [void]$it.SubItems.Add([string]$sub) }
            $it.Tag = $r
            if ($r.Online) { $it.ForeColor = $ColorGood }
            elseif ($r.Banned -or $r.Status -like 'Turned away*') { $it.ForeColor = $ColorBad }
            [void]$lv.Items.Add($it)
            if ($selId -and $r.Id -eq $selId) { $it.Selected = $true }
        }
        $lv.EndUpdate()
    }
    $p.WlOn.Checked = [bool]$d.whitelist.enabled
    $p.WlCount.Text = [string]$wl.Count + ' on the whitelist.'
    $nOn = @($d.online | Where-Object { $_ }).Count
    $p.Note.Text = [string]$nOn + ' online now. ' + [string]@($d.known | Where-Object { $_ }).Count + ' have played here.'
    Update-PlayerButtons
}

function Invoke-PlayerAction([string]$What) {
    $r = Get-SelectedPlayerRow
    if (-not $r) { return }
    try {
        switch ($What) {
            'kick' {
                if (-not (Confirm-Action ('Kick ' + $r.Name + '? They are removed now and can join again right away.'))) { return }
                [void](Invoke-CC 'players/kick' @{ id = $r.Id; message = 'You were removed by the server owner.' })
                Set-Status ('Kicked ' + $r.Name + '.')
            }
            'ban' {
                if (-not (Confirm-Action ('Ban ' + $r.Name + '? They are removed now and cannot join again until you unban them.'))) { return }
                [void](Invoke-CC 'players/ban' @{ id = $r.Id; message = 'You are banned from this server.' })
                Set-Status ('Banned ' + $r.Name + '.')
            }
            'unban' {
                [void](Invoke-CC 'players/unban' @{ id = $r.Id })
                Set-Status ('Unbanned ' + $r.Name + '. They can join again.')
            }
        }
    }
    catch { Show-Error ('Could not ' + $What + ' ' + $r.Name + ':') $_ }
    finally { Update-PlayersTab -Force }
}

function Set-Whitelisted([bool]$On) {
    $p = $script:PL
    $r = Get-SelectedPlayerRow
    if (-not $r -or -not $p.Data) { return }
    try {
        $ids = @($p.Data.whitelist.ids | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($On) { $ids = @($ids + $r.Id | Select-Object -Unique) }
        else {
            $drop = @($r.Id.ToLower(), $r.Name.ToLower())
            $ids = @($ids | Where-Object { $drop -notcontains $_.ToLower() })
        }
        [void](Invoke-CC 'whitelist' @{ ids = @($ids) })
        if ($On) { Set-Status ($r.Name + ' is on the whitelist.') } else { Set-Status ($r.Name + ' is off the whitelist.') }
    }
    catch { Show-Error 'Could not change the whitelist:' $_ }
    finally { Update-PlayersTab -Force }
}

# ---------- Backups tab ----------
function New-BackupsTab {
    $page = New-ToolPage 'Backups'
    $ui = @{}
    $g1 = New-Group 'World backups' 10 404
    $g1.Controls.Add((New-SmallLabel 'The watchdog''s own backups, plus the game''s own rolling backups. Before any restore, a safety copy of the world as it is right now is saved first, so a restore can always be undone.' 14 22 830))
    $ui.List = New-List 14 56 830 270 @(@('When', 210), @('Kind', 360), @('Size', 100))
    $ui.Make = New-Button 'Back up now'
    $ui.Make.Font = $FontBold
    $ui.Peek = New-Button 'What is in it?'
    $ui.Restore = New-Button 'Restore...'
    $ui.Folder = New-Button 'Open backups folder'
    $ui.Refresh = New-Button 'Refresh'
    $ui.Folder.Margin = New-Object System.Windows.Forms.Padding(24, 0, 4, 0)
    $ui.Note = New-SmallLabel '' 14 374 830
    $g1.Controls.Add($ui.List)
    $g1.Controls.Add((New-ButtonRow 10 336 @($ui.Make, $ui.Peek, $ui.Restore, $ui.Folder, $ui.Refresh)))
    $ui.Make.Font = $FontBold
    $g1.Controls.Add($ui.Note)

    $g2 = New-Group 'Automatic backups' 424 128
    $ui.Auto = New-Check 'Back up every'
    $ui.Hours = New-Num 1 48 0
    $ui.Keep = New-Num 3 200 0
    $ui.Before = New-Check 'Also back up before every restart the watchdog does'
    $ui.SaveCfg = New-Button 'Save backup settings'
    $g2.Controls.Add((New-Line 14 26 @($ui.Auto, $ui.Hours, 'hours, and keep the newest', $ui.Keep, 'backups')))
    $g2.Controls.Add((New-Line 14 56 @($ui.Before)))
    $g2.Controls.Add((New-ButtonRow 10 88 @($ui.SaveCfg)))

    $script:BK = $ui

    $ui.Make.add_Click({
        try { [void](Invoke-CC 'backups/create' @{ note = 'from the control panel' }); Set-Status 'Backing up the world. It shows in the list when it is done.' }
        catch { Show-Error 'Could not start a backup:' $_ }
        finally { Update-BackupsBusy }
    })
    $ui.Peek.add_Click({ Show-BackupPreview })
    $ui.Restore.add_Click({ Invoke-BackupRestore })
    $ui.List.add_DoubleClick({ Show-BackupPreview })
    $ui.List.add_SelectedIndexChanged({
        $has = $script:BK.List.SelectedItems.Count -gt 0
        $script:BK.Peek.Enabled = $has
        $script:BK.Restore.Enabled = $has
    })
    $ui.Folder.add_Click({
        try {
            $f = $script:BK.Dir
            if (-not $f) { $f = Join-Path $CCDir 'data\backups' }
            [void](New-Item -ItemType Directory -Force -Path $f)
            Start-Process -FilePath $f
        }
        catch { Show-Error 'Could not open the folder:' $_ }
    })
    $ui.Refresh.add_Click({ Update-BackupsTab })
    $ui.SaveCfg.add_Click({
        $b = $script:BK
        try {
            [void](Invoke-CC 'config' @{ backups = @{ enabled = [bool]$b.Auto.Checked; every_hours = [int]$b.Hours.Value; keep = [int]$b.Keep.Value
                                                      before_restart = [bool]$b.Before.Checked } })
            Set-Status 'Backup settings saved.'
        }
        catch { Show-Error 'Could not save the backup settings:' $_ }
        finally { Update-BackupsTab }
    })

    foreach ($g in @($g1, $g2)) { $page.Controls.Add($g) }
    $tabs.TabPages.Add($page)
}

function Update-BackupsTab {
    $b = $script:BK
    if (-not $b.List -or $b.List.IsDisposed) { return }
    $d = $null
    try { $d = Invoke-CC 'backups' $null 20 }
    catch {
        $b.Note.Text = [string]$_.Exception.Message
        foreach ($c in @($b.Make, $b.Peek, $b.Restore, $b.SaveCfg)) { $c.Enabled = $false }
        return
    }
    $b.Dir = [string]$d.folder
    $selId = $null
    if ($b.List.SelectedItems.Count) { $selId = $b.List.SelectedItems[0].Tag.id }
    $lv = $b.List
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $list = @($d.list | Where-Object { $_ })
    $script:BK.Entries = $list
    foreach ($e in $list) {
        $it = New-Object System.Windows.Forms.ListViewItem([string](Format-Unix $e.t))
        $kind = [string]$e.label
        if ($e.kind -eq 'cc' -and $e.reason -and @('auto', 'manual', 'before-restart', 'before-restore', 'before-update', 'game') -notcontains [string]$e.reason) { $kind = [string]$e.reason }
        [void]$it.SubItems.Add($kind)
        [void]$it.SubItems.Add((Format-Bytes $e.size))
        $it.Tag = $e
        if ($e.kind -eq 'game') { $it.ForeColor = $ColorDesc }
        [void]$lv.Items.Add($it)
        if ($selId -and $e.id -eq $selId) { $it.Selected = $true }
    }
    $lv.EndUpdate()
    $mine = @($list | Where-Object { $_.kind -eq 'cc' }).Count
    $b.Note.Text = [string]$mine + ' watchdog backups (it keeps the newest ' + [string]$d.keep + ') and ' + [string]($list.Count - $mine) + ' of the game''s own. Folder: ' + [string]$d.folder
    $b.Make.Enabled = $true
    $b.SaveCfg.Enabled = $true
    $b.Peek.Enabled = ($lv.SelectedItems.Count -gt 0)
    $b.Restore.Enabled = $b.Peek.Enabled
    try {
        $c = Invoke-CC 'config' $null 5
        $b.Auto.Checked = [bool]$c.backups.enabled
        Set-NumValue $b.Hours $c.backups.every_hours
        Set-NumValue $b.Keep $c.backups.keep
        $b.Before.Checked = [bool]$c.backups.before_restart
    }
    catch { }
    Update-BackupsBusy
}

function Update-BackupsBusy {
    # Shows backups and restores in progress, and reloads the list once one finishes.
    $b = $script:BK
    if (-not $b.Note -or $b.Note.IsDisposed) { return }
    $st = $null
    try { $st = Invoke-CC 'status' $null 5 } catch { return }
    $busy = @()
    if ($st.background) { $busy += @($st.background.PSObject.Properties | ForEach-Object { [string]$_.Value }) }
    if ($st.job -and $st.job.kind -eq 'restore') {
        $t = [string]$st.job.text
        if ($st.job.step) { $t += ' - ' + [string]$st.job.step }
        $busy += $t
    }
    $was = [bool]$b.WasBusy
    $b.WasBusy = [bool]$busy.Count
    if ($busy.Count) {
        $b.Make.Enabled = -not (@($busy | Where-Object { $_ -like 'Backing up*' }).Count)
        $b.Restore.Enabled = $false
        $b.Note.Text = 'Doing now: ' + ($busy -join ', ') + '...'
    }
    elseif ($was) { Update-BackupsTab }
}

function Get-SelectedBackup {
    $lv = $script:BK.List
    if (-not $lv -or $lv.SelectedItems.Count -eq 0) { return $null }
    return $lv.SelectedItems[0].Tag
}

function Show-BackupPreview {
    $e = Get-SelectedBackup
    if (-not $e) { return }
    try {
        Set-Busy $true
        Set-Status 'Reading the backup...'
        $pv = Invoke-CC ('backups/preview?id=' + [uri]::EscapeDataString([string]$e.id)) $null 120
        $txt = 'Backup from ' + (Format-Unix $e.t) + ' (' + [string]$e.label + ', ' + (Format-Bytes $e.size) + ")`n`n"
        $then = $pv.then
        $now = $pv.now
        if ($then.detail) {
            $nowBy = @{}
            if ($now.detail) { foreach ($q in @($now.detail.players | Where-Object { $_ })) { $nowBy[[string]$q.name] = $q } }
            $txt += "Players in the backup (and now):`n"
            foreach ($q in @($then.detail.players | Where-Object { $_ })) {
                $line = '  ' + [string]$q.name + ': level ' + [string]$q.level + ', ' + [string]$q.pals + ' pals'
                $n = $nowBy[[string]$q.name]
                if ($n) { $line += '   (now level ' + [string]$n.level + ', ' + [string]$n.pals + ' pals)' }
                else { $line += '   (not in the world now)' }
                $txt += $line + "`n"
            }
            if ($now.detail) {
                foreach ($q in @($now.detail.players | Where-Object { $_ })) {
                    if (-not @($then.detail.players | Where-Object { $_ -and [string]$_.name -eq [string]$q.name }).Count) {
                        $txt += '  ' + [string]$q.name + ': not in this backup (joined later)' + "`n"
                    }
                }
            }
        }
        else {
            $txt += [string]$then.players + ' player save file(s). (Player names and levels show when the Pal Planner is installed.)' + "`n"
            if ($then.note) { $txt += [string]$then.note + "`n" }
        }
        Set-Status ''
        Show-Message $txt
    }
    catch { Show-Error 'Could not read the backup:' $_ }
    finally { Set-Busy $false }
}

function Invoke-BackupRestore {
    $e = Get-SelectedBackup
    if (-not $e) { return }
    $ask = 'Restore the backup from ' + (Format-Unix $e.t) + '?' + "`n`n" +
           'The world goes back to how it was then. Anything built, caught or earned since then is lost.' + "`n`n" +
           'A safety copy of the world as it is right now is saved first, so you can undo this by restoring that copy from this list.'
    if (Test-ServerRunning) { $ask += "`n`n" + 'The server restarts for this: anyone online gets a 1-minute warning, then it is down for a few minutes.' }
    if (-not (Confirm-Action $ask)) { return }
    try {
        [void](Invoke-CC 'backups/restore' @{ id = [string]$e.id; confirm = 'RESTORE'; minutes = 1 })
        Set-Status 'Restoring. You can follow it on the Watchdog tab.'
    }
    catch { Show-Error 'Could not start the restore:' $_ }
    finally { Update-BackupsBusy }
}

# ---------- Discord tab ----------
function New-DiscordTab {
    $page = New-ToolPage 'Discord'
    $ui = @{}

    $g1 = New-Group '1. Create your bot (free, about 5 minutes)' 10 274
    $steps = '1. Click Open the Developer Portal and sign in to Discord. Click New Application, give it a name (for example "' + $script:ServerTitle + ' Server") and click Create.' + "`n" +
             '2. On General Information, copy the Application ID and the Public Key into the boxes below.' + "`n" +
             '3. Click Bot on the left, then Reset Token and Yes. Copy the token into the Bot token box. Treat it like a password: anyone with it can post as your bot.' + "`n" +
             '4. Optional, so only you can add the bot to servers: on Installation set Install Link to None and save, then on Bot turn off Public Bot and save.'
    $l = New-Text $steps 14 22 830
    $g1.Controls.Add($l)
    $ui.AppId = New-Object System.Windows.Forms.TextBox
    $ui.Key = New-Object System.Windows.Forms.TextBox
    $ui.Token = New-Object System.Windows.Forms.TextBox
    $ui.Token.UseSystemPasswordChar = $true
    $y = 136
    foreach ($pair in @(@('Application ID', $ui.AppId, 220), @('Public Key', $ui.Key, 560), @('Bot token', $ui.Token, 560))) {
        $g1.Controls.Add((New-Text $pair[0] 14 ($y + 3) 120))
        $pair[1].Font = $FontMain
        $pair[1].Location = New-Object System.Drawing.Point(130, $y)
        $pair[1].Width = $pair[2]
        $g1.Controls.Add($pair[1])
        $y += 30
    }
    $ui.Portal = New-Button 'Open the Developer Portal'
    $ui.CheckApp = New-Button 'Check and save'
    $ui.AppNote = New-Text '' 0 0 480
    $ui.AppNote.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
    $g1.Controls.Add((New-ButtonRow 10 230 @($ui.Portal, $ui.CheckApp, $ui.AppNote)))
    $ui.CheckApp.Font = $FontBold

    $g2 = New-Group '2. Add it to your Discord server' 294 222
    $g2.Controls.Add((New-SmallLabel 'Click Open the invite link, pick your Discord server and click Authorize. Then come back, click Show my servers, and pick the server and the channel for alerts.' 14 22 830))
    $ui.Invite = New-Button 'Open the invite link'
    $ui.Guilds = New-Button 'Show my servers'
    $ui.SrvNote = New-Object System.Windows.Forms.Label
    $ui.SrvNote.AutoSize = $true
    $ui.SrvNote.Font = $FontMain
    $ui.SrvNote.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
    $g2.Controls.Add((New-ButtonRow 10 58 @($ui.Invite, $ui.Guilds, $ui.SrvNote)))
    $ui.GuildBox = New-Object System.Windows.Forms.ComboBox
    $ui.ChanBox = New-Object System.Windows.Forms.ComboBox
    $ui.VoiceBox = New-Object System.Windows.Forms.ComboBox
    foreach ($c in @($ui.GuildBox, $ui.ChanBox, $ui.VoiceBox)) { $c.DropDownStyle = 'DropDownList'; $c.Font = $FontMain; $c.Width = 240; $c.Margin = New-Object System.Windows.Forms.Padding(2, 2, 12, 0) }
    $ui.SaveSrv = New-Button 'Save'
    $ui.SaveSrv.Font = $FontBold
    $g2.Controls.Add((New-Line 14 98 @('Server', $ui.GuildBox, 'Alerts channel', $ui.ChanBox)))
    $g2.Controls.Add((New-Line 14 130 @('Voice channel', $ui.VoiceBox, 'for the Pal Planner''s Voice tab', $ui.SaveSrv)))
    $ui.VoiceNote = New-SmallLabel '' 14 168 830
    $g2.Controls.Add($ui.VoiceNote)

    $g3 = New-Group '3. Alerts' 526 150
    $ui.AlertsOn = New-Check 'Post alerts in the channel'
    $ui.AlertsOn.Font = $FontBold
    $ui.Al = [ordered]@{}
    foreach ($pair in @(@('problems', 'Crashes, freezes and errors'), @('restarts', 'Restarts, starts and stops'), @('updates', 'Game updates'),
                        @('backups', 'Backups'), @('joins', 'Players joining and leaving'), @('levelups', 'Level-ups'))) {
        $c = New-Check $pair[1]
        $c.Margin = New-Object System.Windows.Forms.Padding(0, 4, 18, 0)
        $ui.Al[$pair[0]] = $c
    }
    $ui.Test = New-Button 'Send a test message'
    $ui.AlNote = New-Object System.Windows.Forms.Label
    $ui.AlNote.AutoSize = $true
    $ui.AlNote.Font = $FontMain
    $ui.AlNote.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
    $g3.Controls.Add((New-Line 14 24 @($ui.AlertsOn)))
    $g3.Controls.Add((New-Line 34 50 @($ui.Al['problems'], $ui.Al['restarts'], $ui.Al['updates'])))
    $g3.Controls.Add((New-Line 34 76 @($ui.Al['backups'], $ui.Al['joins'], $ui.Al['levelups'])))
    $g3.Controls.Add((New-ButtonRow 10 108 @($ui.Test, $ui.AlNote)))

    $g4 = New-Group '4. Slash commands' 686 150
    $g4.Controls.Add((New-SmallLabel 'Everyone: /status /players /playtime /planner. People with Manage Server in your Discord: /restart /stop /start /backup /announce /kick /ban /unban. Discord sends commands through your family link, and each one is checked for Discord''s signature. The bot shows as offline in the member list. That is normal; it still answers.' 14 22 830))
    $ui.CmdState = New-Text '' 14 78 830 -Bold
    $ui.CmdOn = New-Button 'Turn slash commands on'
    $ui.CmdOn.Font = $FontBold
    $ui.Forget = New-Button 'Disconnect the bot'
    $ui.Forget.Margin = New-Object System.Windows.Forms.Padding(40, 0, 4, 0)
    $g4.Controls.Add($ui.CmdState)
    $g4.Controls.Add((New-ButtonRow 10 104 @($ui.CmdOn, $ui.Forget)))
    $ui.CmdOn.Font = $FontBold

    $ui.Groups = @($g2, $g3, $g4)
    $script:DC = $ui

    $ui.Portal.add_Click({ Start-Process 'https://discord.com/developers/applications' })
    $ui.CheckApp.add_Click({
        $d = $script:DC
        try {
            Set-Busy $true
            $tok = $d.Token.Text.Trim()
            if (-not $tok -and $d.Data -and $d.Data.hasToken) { $tok = '__keep__' }
            $r = Invoke-CC 'discord/app' @{ app_id = $d.AppId.Text.Trim(); public_key = $d.Key.Text.Trim(); token = $tok } 30
            $d.Token.Clear()
            Set-Status ('Connected to Discord as ' + [string]$r.bot_name + '.')
        }
        catch { Show-Error 'Discord did not accept that:' $_ }
        finally { Set-Busy $false; Update-DiscordTab }
    })
    $ui.Invite.add_Click({ if ($script:DC.Data -and $script:DC.Data.invite) { Start-Process ([string]$script:DC.Data.invite) } })
    $ui.Guilds.add_Click({
        $d = $script:DC
        try {
            Set-Busy $true
            $r = Invoke-CC 'discord?guilds=1' $null 30
            if ($r.guildsError) { throw [string]$r.guildsError }
            $d.GuildList = @($r.guilds | Where-Object { $_ })
            $d.GuildBox.Items.Clear()
            foreach ($g in $d.GuildList) { [void]$d.GuildBox.Items.Add([string]$g.name) }
            if ($d.GuildList.Count -eq 0) { Show-Message 'The bot is not in any Discord server yet. Click Open the invite link first, pick your server and click Authorize.' }
            else {
                $i = 0
                for ($k = 0; $k -lt $d.GuildList.Count; $k++) { if ([string]$d.GuildList[$k].id -eq [string]$d.Data.guild_id) { $i = $k } }
                $d.GuildBox.SelectedIndex = $i
            }
        }
        catch { Show-Error 'Could not get your Discord servers:' $_ }
        finally { Set-Busy $false }
    })
    $ui.GuildBox.add_SelectedIndexChanged({
        $d = $script:DC
        if ($d.GuildBox.SelectedIndex -lt 0 -or -not $d.GuildList) { return }
        $g = $d.GuildList[$d.GuildBox.SelectedIndex]
        try {
            $r = Invoke-CC ('discord?channels=' + [string]$g.id) $null 30
            if ($r.channelsError) { throw [string]$r.channelsError }
            $d.ChanList = @($r.channels | Where-Object { $_ })
            $d.ChanBox.Items.Clear()
            $sel = 0
            for ($k = 0; $k -lt $d.ChanList.Count; $k++) {
                [void]$d.ChanBox.Items.Add('#' + [string]$d.ChanList[$k].name)
                if ([string]$d.ChanList[$k].id -eq [string]$d.Data.channel_id) { $sel = $k }
            }
            if ($d.ChanList.Count) { $d.ChanBox.SelectedIndex = $sel }
            $d.VoiceList = @($r.voiceChannels | Where-Object { $_ })
            $d.VoiceBox.Items.Clear()
            [void]$d.VoiceBox.Items.Add('(none)')
            $sel = 0
            for ($k = 0; $k -lt $d.VoiceList.Count; $k++) {
                [void]$d.VoiceBox.Items.Add([string]$d.VoiceList[$k].name)
                if ([string]$d.VoiceList[$k].id -eq [string]$d.Data.voice_id) { $sel = $k + 1 }
            }
            $d.VoiceBox.SelectedIndex = $sel
        }
        catch { Show-Error 'Could not get the channels:' $_ }
    })
    $ui.SaveSrv.add_Click({
        $d = $script:DC
        if (-not $d.GuildList -or $d.GuildBox.SelectedIndex -lt 0 -or $d.ChanBox.SelectedIndex -lt 0) { Show-Message 'These are your saved choices. To change them, click Show my servers first, then pick a server and a channel.'; return }
        try {
            $vid = ''
            if ($d.VoiceBox.SelectedIndex -gt 0 -and $d.VoiceList) { $vid = [string]$d.VoiceList[$d.VoiceBox.SelectedIndex - 1].id }
            $r = Invoke-CC 'discord/server' @{ guild_id = [string]$d.GuildList[$d.GuildBox.SelectedIndex].id; channel_id = [string]$d.ChanList[$d.ChanBox.SelectedIndex].id; voice_id = $vid }
            $msg = 'Alerts go to #' + [string]$r.channel_name + '.'
            if ($r.voice_name) { $msg += ' The Pal Planner''s Voice tab joins ' + [string]$r.voice_name + '.' }
            Set-Status $msg
        }
        catch { Show-Error 'Could not save the server and channel:' $_ }
        finally { Update-DiscordTab }
    })
    $saveAlerts = {
        $d = $script:DC
        try {
            $al = @{}
            foreach ($k in @($d.Al.Keys)) { $al[$k] = [bool]$d.Al[$k].Checked }
            [void](Invoke-CC 'discord/alerts' @{ enabled = [bool]$d.AlertsOn.Checked; alerts = $al })
            Set-Status 'Discord alert settings saved.'
        }
        catch { Show-Error 'Could not save the alert settings:' $_ }
        finally { Update-DiscordTab }
    }
    $ui.AlertsOn.add_Click($saveAlerts)
    foreach ($c in @($ui.Al.Values)) { $c.add_Click($saveAlerts) }
    $ui.Test.add_Click({
        try { Set-Busy $true; [void](Invoke-CC 'discord/test' @{}); Set-Status 'Test message sent. Check the channel in Discord.' }
        catch { Show-Error 'The test message did not go through:' $_ }
        finally { Set-Busy $false; Update-DiscordTab }
    })
    $ui.CmdOn.add_Click({
        $d = $script:DC
        $on = -not ($d.Data -and $d.Data.commands_on)
        try {
            Set-Busy $true
            if ($on) { Set-Status 'Turning slash commands on. Discord checks your family link first, so this can take up to a minute...' }
            $r = Invoke-CC 'discord/commands' @{ on = $on } 120
            if ($r -and $r.ok -eq $false) {
                if ($r.approve) {
                    Start-Process ([string]$r.approve)
                    Show-Message 'Tailscale asked you to approve this in your browser. Approve it, then click Turn slash commands on again.'
                }
                else { Show-Message ('Tailscale said: ' + [string]$r.text) 'Warning' }
            }
            elseif ($on) { Set-Status 'Slash commands are on. Try /status in your Discord server.' }
            else { Set-Status 'Slash commands are off.' }
        }
        catch { Show-Error 'Could not change slash commands:' $_ }
        finally { Set-Busy $false; Update-DiscordTab }
    })
    $ui.Forget.add_Click({
        if (-not (Confirm-Action "Disconnect the bot?`n`nAlerts and slash commands stop, and the saved token is deleted from this PC. You can connect it again later.")) { return }
        try { Set-Busy $true; [void](Invoke-CC 'discord/forget' @{}); Set-Status 'The Discord bot is disconnected.' }
        catch { Show-Error 'Could not disconnect the bot:' $_ }
        finally { Set-Busy $false; Update-DiscordTab }
    })

    foreach ($g in @($g1, $g2, $g3, $g4)) { $page.Controls.Add($g) }
    $tabs.TabPages.Add($page)
}

function Update-DiscordTab {
    $d = $script:DC
    if (-not $d.AppId -or $d.AppId.IsDisposed) { return }
    $r = $null
    try { $r = Invoke-CC 'discord' $null 10 }
    catch {
        $d.AppNote.Text = [string]$_.Exception.Message
        $d.AppNote.ForeColor = $ColorOff
        $d.CheckApp.Enabled = $false
        foreach ($g in $d.Groups) { $g.Enabled = $false }
        return
    }
    $d.Data = $r
    $d.CheckApp.Enabled = $true
    if (-not $d.AppId.Focused) { $d.AppId.Text = [string]$r.app_id }
    if (-not $d.Key.Focused) { $d.Key.Text = [string]$r.public_key }
    if ($r.hasToken) {
        $d.AppNote.Text = 'Connected as ' + [string]$r.bot_name + '. The token is saved; paste a new one only to change it.'
        $d.AppNote.ForeColor = $ColorOn
    }
    else {
        $d.AppNote.Text = 'Not connected yet.'
        $d.AppNote.ForeColor = $ColorDesc
    }
    $d.Groups[0].Enabled = [bool]$r.hasToken
    $d.Groups[1].Enabled = [bool]($r.hasToken -and $r.channel_id)
    $d.Groups[2].Enabled = [bool]($r.hasToken -and $r.channel_id)
    if ($r.channel_id) {
        $d.SrvNote.Text = 'Posting in #' + [string]$r.channel_name + ' on ' + [string]$r.guild_name + '.'
        $d.SrvNote.ForeColor = $ColorOn
    }
    else {
        $d.SrvNote.Text = ''
    }
    if (-not $d.GuildList -and $r.channel_id) {
        # until Show my servers loads the full lists from Discord, the boxes show what is saved
        $d.GuildBox.Items.Clear(); [void]$d.GuildBox.Items.Add([string]$r.guild_name); $d.GuildBox.SelectedIndex = 0
        $d.ChanBox.Items.Clear(); [void]$d.ChanBox.Items.Add('#' + [string]$r.channel_name); $d.ChanBox.SelectedIndex = 0
        $d.VoiceBox.Items.Clear()
        if ($r.voice_id) { [void]$d.VoiceBox.Items.Add([string]$r.voice_name) } else { [void]$d.VoiceBox.Items.Add('(none)') }
        $d.VoiceBox.SelectedIndex = 0
    }
    $v = $r.voice
    if (-not $r.channel_id) { $d.VoiceNote.Text = '' }
    elseif (-not $v -or -not $v.configured) { $d.VoiceNote.Text = 'Optional: pick a voice channel to add a Join voice button to the Pal Planner. Click Show my servers to see the choices.' }
    else {
        $t = 'The Pal Planner''s Voice tab has a Join voice button for ' + [string]$v.channel
        if ($v.widget -eq 'ok' -and $v.private) { $t += '. The channel is private, so it cannot show who is in it.' }
        elseif ($v.widget -eq 'ok') { $t += ' and shows who is in it.' }
        elseif ($v.widget -eq 'off') { $t += '. In Discord, turn on Server Settings > Widget > Enable Server Widget and pick an Invite Channel there: then it shows who is in voice and invites everyone who is not in your Discord yet.' }
        else { $t += '.' }
        if ($v.widget -eq 'ok' -and -not $v.invite) { $t += ' To invite people who are not in your Discord yet, pick an Invite Channel in Discord''s Server Settings > Widget.' }
        elseif ($v.invite) { $t += ' Everyone gets a one-time invite to your Discord the next time they open the Pal Planner.' }
        $d.VoiceNote.Text = $t
    }
    $d.AlertsOn.Checked = [bool]$r.enabled
    foreach ($k in @($d.Al.Keys)) {
        $d.Al[$k].Checked = [bool]$r.alerts.$k
        $d.Al[$k].Enabled = [bool]$r.enabled
    }
    if ($r.last_error) { $d.AlNote.Text = 'Last problem: ' + [string]$r.last_error; $d.AlNote.ForeColor = $ColorOff }
    elseif ($r.last_ok) { $d.AlNote.Text = 'Last alert sent ' + (Format-Unix $r.last_ok) + '.'; $d.AlNote.ForeColor = $ColorDesc }
    else { $d.AlNote.Text = '' }
    if ($r.commands_on) {
        $d.CmdOn.Text = 'Turn slash commands off'
        if ($r.mounted -eq $false) {
            $d.CmdState.Text = 'On, but the family link is not passing commands through right now. It puts itself back within 5 minutes of the family link being on.'
            $d.CmdState.ForeColor = $ColorStarting
        }
        else {
            $d.CmdState.Text = 'On. Discord sends them to ' + [string]$r.commandsUrl
            $d.CmdState.ForeColor = $ColorOn
        }
        $d.CmdOn.Enabled = $true
    }
    else {
        $d.CmdOn.Text = 'Turn slash commands on'
        if ($r.familyLink) {
            $d.CmdState.Text = 'Off.'
            $d.CmdState.ForeColor = $ColorDesc
            $d.CmdOn.Enabled = $true
        }
        else {
            $d.CmdState.Text = 'Off. Turn the family link on first (Pal Planner tab, Set up sharing).'
            $d.CmdState.ForeColor = $ColorStarting
            $d.CmdOn.Enabled = $false
        }
    }
    $d.Forget.Enabled = [bool]$r.hasToken
}

function Update-SelectedTab([switch]$Timer) {
    # Refreshes whichever watchdog tab is showing (on opening it, and every 5 seconds while it stays open).
    if ($script:Busy -or $null -eq $tabs.SelectedTab) { return }
    switch ($tabs.SelectedTab.Text) {
        'Watchdog' {
            if (-not $Timer -or -not $script:WD.Cfg) { Update-WatchdogSettings }
            Update-WatchdogStatus
            Update-VPalUpdate
            Update-Activity
        }
        'Players' { Update-PlayersTab }
        'Backups' { if ($Timer) { Update-BackupsBusy } else { Update-BackupsTab } }
        'Discord' { if (-not $Timer) { Update-DiscordTab } }
    }
}

# ---------------- VPal's own updates ----------------
# The watchdog checks VPal's GitHub page once a day. When a newer VPal is out, an Update button shows in the top bar.
# The watchdog downloads the update and checks it, then vpal_updater.py puts it in while the watchdog is closed for a
# moment (the game server keeps running and nobody is disconnected). Then this window reopens on the new version.
$script:VU = @{ Ticks = 0 }

function Format-VPalUpdateNote($I) {
    if ($null -eq $I) { return '' }
    $cur = 'VPal ' + [string]$I.current
    if (-not $I.feed) { return $cur + '. This copy does not check for VPal updates.' }
    if ($I.available) { return 'VPal ' + [string]$I.version + ' is ready (you have ' + [string]$I.current + ').' }
    if ($I.error) { return $cur + '. The last update check did not work (the Health check says why).' }
    if ([double]$I.checked -gt 0 -and -not $I.published) { return $cur + '. No release is on VPal''s GitHub page yet (checked ' + (Format-Unix $I.checked) + ').' }
    if ([double]$I.checked -gt 0) { return $cur + ' is the newest (checked ' + (Format-Unix $I.checked) + ').' }
    return $cur + '.'
}

function Set-HeaderFit {
    # Keeps the last message in the bottom bar clear of the buttons on the right.
    if ($null -eq $lblStatus -or $null -eq $buttons -or $buttons.IsDisposed) { return }
    $buttons.PerformLayout()
    $w = $bar.ClientSize.Width - $buttons.Width - $lblStatus.Left - 12
    $lblStatus.Visible = ($w -ge 80)
    if ($w -ge 80) { $lblStatus.Width = $w }
}

function Update-VPalUpdate($I = $null) {
    # Shows or hides the top bar's Update button, and the VPal line on the Watchdog tab.
    if ($null -eq $I) {
        if (-not (Test-CommandCenter)) { return }
        try { $I = Invoke-CC 'vpal-update' $null 3 } catch { return }
    }
    $script:VU.Info = $I
    if ($null -ne $btnVPal -and -not $btnVPal.IsDisposed) {
        $show = [bool]$I.available
        if ($show) { $btnVPal.Text = 'Update VPal to ' + [string]$I.version }
        if ($btnVPal.Visible -ne $show) {
            $btnVPal.Visible = $show
            Set-HeaderFit
        }
    }
    $w = $script:WD
    if ($w.VPalNote -and -not $w.VPalNote.IsDisposed) { $w.VPalNote.Text = Format-VPalUpdateNote $I }
}

function Start-VPalUpdate {
    # The Update button: what's new, then the update itself.
    try { $i = Invoke-CC 'vpal-update' $null 5 } catch { Show-Error 'Could not reach the watchdog:' $_; return }
    Update-VPalUpdate $i
    if (-not $i.available) { Show-Message ('VPal ' + [string]$i.current + ' is the newest version.'); return }
    if ($i.needsSetup) {
        $m = 'VPal ' + [string]$i.version + ' is a bigger update that this window cannot install. Download VPal-Setup.exe and run it. It keeps your server, worlds and settings.'
        if ($i.setup) { if (Confirm-Action ($m + "`n`nOpen the download page now?")) { Start-Process ([string]$i.setup) } }
        else { Show-Message $m }
        return
    }
    $text = 'VPal ' + [string]$i.version + ' is ready. You have ' + [string]$i.current + '.'
    $notes = @($i.notes | Where-Object { $_ } | Select-Object -First 8)
    if ($notes.Count -gt 0) { $text += "`n`nWhat's new:`n" + (($notes | ForEach-Object { '  - ' + $_ }) -join "`n") }
    $text += "`n`nThe game server keeps running and nobody is disconnected. The watchdog and the Pal Planner's website pause for about a minute, then this window reopens on the new version.`n`nUpdate now?"
    if (-not (Confirm-Action $text)) { return }
    $n = Get-ChangeCount
    if ($n -gt 0) {
        $r = [System.Windows.Forms.MessageBox]::Show("You have $n unsaved setting change(s). Save them before VPal updates?`n`nNo throws them away.",
                                                     'VPal Server Command Center', 'YesNoCancel', 'Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            Set-Busy $true
            try { if (-not (Save-Settings -Quiet)) { return } } finally { Set-Busy $false }
        }
    }
    if (Show-VPalUpdateProgress ([string]$i.version)) { Restart-Panel }
    else { Update-VPalUpdate }
}

function Show-VPalUpdateProgress([string]$To) {
    # Follows the update until the watchdog is back on the new version. Returns $true when it is.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Updating VPal'
    $dlg.Font = $FontMain
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ControlBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 146)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $false
    $lbl.UseMnemonic = $false
    $lbl.Location = New-Object System.Drawing.Point(16, 14)
    $lbl.Size = New-Object System.Drawing.Size(448, 54)
    $lbl.Text = 'Starting the update...'
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(16, 72)
    $bar.Size = New-Object System.Drawing.Size(448, 18)
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Close'
    $btn.Size = New-Object System.Drawing.Size(90, 30)
    $btn.Location = New-Object System.Drawing.Point(374, 104)
    $btn.Visible = $false
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 1000
    $script:VU.Run = @{ Form = $dlg; Label = $lbl; Bar = $bar; Btn = $btn; Timer = $tm; To = $To; Gone = $null; BackOld = $null
                        Kicked = $false; Done = $false; Ok = $false; InStep = $false; Since = (Get-NowUnix) }
    $btn.add_Click({ $script:VU.Run.Form.Close() })
    $tm.add_Tick({ try { Step-VPalUpdate } catch { } })
    $dlg.add_Shown({
        try {
            [void](Invoke-CC 'vpal-update/start' @{})
            $script:VU.Run.Timer.Start()
        }
        catch { Stop-VPalUpdate ('The update did not start. ' + [string]$_.Exception.Message) }
    })
    foreach ($c in @($lbl, $bar, $btn)) { $dlg.Controls.Add($c) }
    [VPalUi.Dark]::Apply($dlg)
    try { [void]$dlg.ShowDialog($form) }
    finally {
        $tm.Stop()
        $tm.Dispose()
        $dlg.Dispose()
    }
    return [bool]$script:VU.Run.Ok
}

function Stop-VPalUpdate([string]$Text, [switch]$Ok) {
    $r = $script:VU.Run
    $r.Done = $true
    $r.Timer.Stop()
    $r.Bar.Style = 'Continuous'
    $r.Label.Text = $Text
    if ($Ok) {
        $r.Bar.Value = 100
        $r.Ok = $true
        Wait-UI 1500
        $r.Form.Close()
    }
    else {
        $r.Bar.Value = 0
        $r.Btn.Visible = $true
        $r.Form.ControlBox = $true
    }
}

function Step-VPalUpdate {
    # Once a second while the update runs.
    $r = $script:VU.Run
    if ($r.Done -or $r.InStep) { return }
    $r.InStep = $true
    try {
        $i = $null
        if (Test-CommandCenter) { try { $i = Invoke-CC 'vpal-update' $null 3 } catch { } }
        if ($null -ne $i) {
            if ([string]$i.current -eq $r.To) { Stop-VPalUpdate ('VPal is updated to ' + $r.To + '. This window reopens now.') -Ok; return }
            $res = $i.result
            if ($null -ne $res -and -not $res.ok -and [double]$res.t -ge ($r.Since - 5)) { Stop-VPalUpdate ([string]$res.error); return }
            if ([string]$i.state -eq 'failed') { Stop-VPalUpdate ([string]$i.jobError); return }
            if ($null -ne $r.Gone) {
                # back, but on the old version and without a result yet: give it a moment, then say so
                if ($null -eq $r.BackOld) { $r.BackOld = Get-Date }
                if (((Get-Date) - $r.BackOld).TotalSeconds -gt 20) {
                    Stop-VPalUpdate ('The update did not install, so VPal is still on ' + [string]$i.current + '. The Recent activity list on the Watchdog tab says why. You can try again.')
                }
                return
            }
            switch ([string]$i.state) {
                'downloading' {
                    $tot = [double]$i.total
                    if ($tot -gt 0) {
                        $r.Bar.Style = 'Continuous'
                        $r.Bar.Value = [int][Math]::Min(100, 100 * [double]$i.got / $tot)
                        $r.Label.Text = 'Downloading VPal ' + $r.To + '... ' + (Format-Bytes $i.got) + ' of ' + (Format-Bytes $tot)
                    }
                }
                'checking' { $r.Bar.Style = 'Marquee'; $r.Label.Text = 'Checking the download...' }
                'waiting' { $r.Bar.Style = 'Marquee'; $r.Label.Text = 'Waiting for the watchdog to finish a restart or a backup first...' }
                'installing' { $r.Bar.Style = 'Marquee'; $r.Label.Text = 'Installing VPal ' + $r.To + '...' }
            }
            return
        }
        # the watchdog is closed while vpal_updater.py puts the new files in
        if ($null -eq $r.Gone) { $r.Gone = Get-Date }
        $r.Bar.Style = 'Marquee'
        $r.Label.Text = 'Installing VPal ' + $r.To + '. The watchdog is closed for a moment; the game server keeps running.'
        $secs = ((Get-Date) - $r.Gone).TotalSeconds
        if ($secs -gt 90 -and -not $r.Kicked) {
            $r.Kicked = $true
            [void](Start-Watchdog -Quiet)
        }
        if ($secs -gt 240) {
            Stop-VPalUpdate 'The watchdog has not come back yet. Close this, open the Watchdog tab and click Start the watchdog. If it still shows the old version afterwards, try the update again.'
        }
    }
    finally { $r.InStep = $false }
}

function Restart-Panel {
    # Opens this window again, now from its updated file, and closes this copy.
    $exe = Join-Path (Split-Path -Parent $PanelFile) 'VPal.exe'
    try {
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
        else {
            $ps = Join-Path $PSHOME 'powershell.exe'
            Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PanelFile + '"')
        }
    }
    catch {
        Show-Message 'VPal is updated. Close this window and open VPal again to use the new version.'
        return
    }
    $script:Relaunching = $true
    $form.Close()
}

# ---------------- First-run setup: installs a new server, or finishes setting up one VPal has not seen before ----------------
$SteamCmdDir = Join-Path $ServerDir 'steamcmd'
$SteamCmdExe = Join-Path $SteamCmdDir 'steamcmd.exe'
$SteamCmdUrl = 'https://steamcdn-media.steamcontent.com/client/installer/steamcmd.zip'
$PalAppId    = '2394010'                       # Palworld Dedicated Server on Steam
$script:WZ   = @{}

function New-AdminPassword {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $b = New-Object byte[] 20
    $rng.GetBytes($b)
    return (-join ($b | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function Set-IniValues([string]$Text, [hashtable]$Values) {
    # Sets keys inside OptionSettings=(...) and keeps everything else as it is.
    foreach ($k in @($Values.Keys)) {
        $v = [string]$Values[$k]
        $pat = '(?<=[(,]\s*)' + [regex]::Escape($k) + '=("[^"]*"|[^,)\r\n]*)'
        if ([regex]::IsMatch($Text, $pat)) {
            $Text = [regex]::Replace($Text, $pat, ($k + '=' + $v).Replace('$', '$$'), 'None')
        }
        else {
            $m = [regex]::Match($Text, '(?m)^OptionSettings=\((.*)\)[ \t]*\r?$')
            if (-not $m.Success) { throw 'The settings file has no OptionSettings line.' }
            $inner = $m.Groups[1].Value
            if ($inner.Trim()) { $inner += ',' }
            $line = 'OptionSettings=(' + $inner + $k + '=' + $v + ')'
            if ($m.Value.EndsWith("`r")) { $line += "`r" }
            $Text = $Text.Substring(0, $m.Index) + $line + $Text.Substring($m.Index + $m.Length)
        }
    }
    return $Text
}

function Get-IniRaw([string]$Text, [string]$Key) {
    $m = [regex]::Match($Text, '(?<=[(,]\s*)' + [regex]::Escape($Key) + '=("([^"]*)"|([^,)\r\n]*))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    return $m.Groups[3].Value.Trim()
}

function Test-IniHasOptions {
    try {
        if (-not (Test-Path -LiteralPath $IniPath)) { return $false }
        return ([System.IO.File]::ReadAllText($IniPath) -match '(?m)^OptionSettings=\(')
    }
    catch { return $false }
}

function Get-LocalIPv4 {
    try {
        $c = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        if ($c) { return [string]@($c.IPv4Address)[0].IPAddress }
    }
    catch { }
    return ''
}

function Confirm-RestApi {
    # The watchdog, the Players tab and backups talk to the server through its REST API (this PC only).
    if (-not (Test-IniHasOptions)) { return }
    $text = [System.IO.File]::ReadAllText($IniPath)
    $rest = [string](Get-IniRaw $text 'RESTAPIEnabled')
    $pw = [string](Get-IniRaw $text 'AdminPassword')
    if ($rest -ieq 'True' -and $pw) { return }
    $ask = 'Turn on the server''s REST API?' + "`n`n" +
           'The watchdog, the Players and Backups tabs and the Discord bot talk to your server through it. It only listens on this PC.'
    if (-not $pw) { $ask += ' Your server has no admin password yet, so a strong one is set for you.' }
    $ask += "`n`n" + 'The server picks it up the next time it starts.'
    if (-not (Confirm-Action $ask)) { return }
    [void](New-Item -ItemType Directory -Force -Path $BackupDir)
    Copy-Item -LiteralPath $IniPath -Destination (Join-Path $BackupDir ('PalWorldSettings_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.ini')) -Force
    $vals = @{ RESTAPIEnabled = 'True' }
    if (-not (Get-IniRaw $text 'RESTAPIPort')) { $vals.RESTAPIPort = '8212' }
    if (-not $pw) { $vals.AdminPassword = '"' + (New-AdminPassword) + '"' }
    [System.IO.File]::WriteAllText($IniPath, (Set-IniValues $text $vals), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-FirstRunCheck {
    # $true: open the control panel. $false: setup was cancelled, so close.
    $exe = Join-Path $ServerDir 'PalServer.exe'
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-IniHasOptions)) { return (Show-SetupWizard) }
    try { Confirm-RestApi } catch { Show-Message ("Could not turn on the REST API:`n`n" + $_.Exception.Message) 'Warning' }
    return $true
}

function Add-WizardLog([string]$Text) {
    $b = $script:WZ.Log
    if (-not $b -or $b.IsDisposed) { return }
    $b.AppendText((Get-Date -Format 'h:mm:ss tt') + '  ' + $Text + "`r`n")
}

function Set-WizardStep([int]$I, [string]$State, [string]$Note) {
    # State: wait, now, done, skip, fail
    $l = $script:WZ.Steps[$I]
    $mark = @{ wait = '      '; now = '  >>  '; done = '  OK  '; skip = '  --  '; fail = '  !!  ' }[$State]
    $l.Text = $mark + $script:WZ.StepNames[$I] + $(if ($Note) { '   (' + $Note + ')' } else { '' })
    switch ($State) {
        'now'  { $l.ForeColor = $ColorNormal; $l.Font = $FontBold }
        'done' { $l.ForeColor = $ColorOn; $l.Font = $FontMain }
        'fail' { $l.ForeColor = $ColorOff; $l.Font = $FontMain }
        'skip' { $l.ForeColor = $ColorDesc; $l.Font = $FontMain }
        default { $l.ForeColor = $ColorDesc; $l.Font = $FontMain }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-WizardProgress($Percent, [string]$Text) {
    $p = $script:WZ.Bar
    if ($null -eq $Percent) { $p.Style = 'Marquee' }
    else { $p.Style = 'Continuous'; $p.Value = [int][Math]::Max(0, [Math]::Min(100, $Percent)) }
    $script:WZ.Detail.Text = $Text
}

function Install-SteamCmd {
    if (Test-Path -LiteralPath $SteamCmdExe) { Add-WizardLog 'SteamCMD is already here.'; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP 'vpal-steamcmd.zip'
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Set-WizardProgress $null 'Downloading SteamCMD from Valve...'
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFileAsync([uri]$SteamCmdUrl, $zip)
    while ($wc.IsBusy) { Wait-UI 200 }
    if (-not (Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).Length -lt 100000) { throw 'SteamCMD did not download. Check the internet connection and try again.' }
    [void](New-Item -ItemType Directory -Force -Path $SteamCmdDir)
    Expand-Archive -LiteralPath $zip -DestinationPath $SteamCmdDir -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $SteamCmdExe)) { throw 'SteamCMD did not unpack.' }
    Add-WizardLog ('SteamCMD is in ' + $SteamCmdDir)
}

function Install-PalServerFiles {
    # Runs SteamCMD (anonymous login; the dedicated server is free) and shows its progress. Tries again twice,
    # because SteamCMD often stops after updating itself the first time it runs.
    $log = Join-Path $SteamCmdDir 'vpal-install-log.txt'
    for ($try = 1; $try -le 3; $try++) {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        $inner = '"' + $SteamCmdExe + '" +force_install_dir "' + $ServerDir + '" +login anonymous +app_update ' + $PalAppId + ' validate +quit > "' + $log + '" 2>&1'
        Add-WizardLog ('Running SteamCMD (try ' + $try + ' of 3)...')
        Set-WizardProgress $null 'Starting SteamCMD (it updates itself first)...'
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/s /c "' + $inner + '"') -WindowStyle Hidden -PassThru
        $null = $p.Handle
        $started = Get-Date
        while (-not $p.HasExited) {
            Wait-UI 700
            $txt = ''
            if (Test-Path -LiteralPath $log) { $txt = Read-SharedText $log }
            $ms = [regex]::Matches($txt, 'Update state \(0x[0-9a-fA-F]+\) ([a-z ]+), progress: ([\d.]+) \((\d+) / (\d+)\)')
            $mins = [int]((Get-Date) - $started).TotalMinutes
            if ($ms.Count) {
                $m = $ms[$ms.Count - 1]
                $pct = [double]::Parse($m.Groups[2].Value, $Inv)
                $done = [double]$m.Groups[3].Value / 1GB
                $all = [double]$m.Groups[4].Value / 1GB
                $what = $m.Groups[1].Value.Trim()
                $word = @{ 'downloading' = 'Downloading'; 'verifying install' = 'Checking files'; 'verifying update' = 'Checking files'; 'preallocating' = 'Making room'; 'committing' = 'Finishing' }[$what]
                if (-not $word) { $word = 'Working' }
                Set-WizardProgress $pct ('{0} the Palworld server: {1:0}% ({2:0.0} of {3:0.0} GB). {4} min so far.' -f $word, $pct, $done, $all, $mins)
            }
            elseif ($mins -ge 1) { Set-WizardProgress $null ('SteamCMD is getting ready... ' + $mins + ' min so far.') }
        }
        $txt = ''
        if (Test-Path -LiteralPath $log) { $txt = Read-SharedText $log }
        if ((Test-Path -LiteralPath (Join-Path $ServerDir 'PalServer.exe')) -and $txt -match "Success! App '$PalAppId' fully installed") {
            Set-WizardProgress 100 'The Palworld server is downloaded.'
            Add-WizardLog 'The Palworld server is installed.'
            return
        }
        $err = ([regex]::Matches($txt, '(?m)^ERROR!.*$') | Select-Object -Last 1)
        if ($err) { Add-WizardLog ('SteamCMD said: ' + $err.Value.Trim()) }
        else { Add-WizardLog ('SteamCMD stopped (code ' + $p.ExitCode + ') before the server was fully installed.') }
    }
    throw 'SteamCMD could not install the Palworld server. Check the internet connection and the free space on the drive, then click Try again.'
}

function Write-ServerSettings($A) {
    # PalWorldSettings.ini from the game's own defaults (or the file that is there), with the answers filled in.
    $dir = Split-Path $IniPath
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $text = $null
    if (Test-IniHasOptions) {
        $text = [System.IO.File]::ReadAllText($IniPath)
        [void](New-Item -ItemType Directory -Force -Path $BackupDir)
        Copy-Item -LiteralPath $IniPath -Destination (Join-Path $BackupDir ('PalWorldSettings_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.ini')) -Force
    }
    else {
        $def = Join-Path $ServerDir 'DefaultPalWorldSettings.ini'
        if (Test-Path -LiteralPath $def) { $text = [System.IO.File]::ReadAllText($def) }
        else { $text = "[/Script/Pal.PalGameWorldSettings]`r`nOptionSettings=()`r`n" }
        # the default file starts with comments saying edits there do nothing; this copy is the one the server reads
        $text = [regex]::Replace($text, '(?m)^;.*\r?\n', '')
    }
    $vals = @{
        ServerName = '"' + $A.Name + '"'; ServerPassword = '"' + $A.Password + '"'; AdminPassword = '"' + $A.Admin + '"'
        ServerPlayerMaxNum = [string]$A.Players; PublicPort = [string]$A.Port
        RESTAPIEnabled = 'True'; RESTAPIPort = '8212'; bIsUseBackupSaveData = 'True'
    }
    [System.IO.File]::WriteAllText($IniPath, (Set-IniValues $text $vals), (New-Object System.Text.UTF8Encoding($false)))
    Add-WizardLog ('Settings saved in ' + $IniPath)
    if ((Test-Path -LiteralPath $SteamCmdExe) -and -not (Test-Path -LiteralPath $StartScript)) {
        $launchArgs = '-port=' + $A.Port
        if ($A.Public) { $launchArgs += ' -publiclobby' }
        $bat = "@echo off`r`n" +
               "rem Made by VPal Server Command Center: checks for a Palworld update, then starts the server.`r`n" +
               "cd /d ""%~dp0""`r`n" +
               "title Palworld server`r`n" +
               "echo Checking for a Palworld update...`r`n" +
               """%~dp0steamcmd\steamcmd.exe"" +force_install_dir ""%~dp0."" +login anonymous +app_update $PalAppId +quit`r`n" +
               "start ""Palworld server"" ""%~dp0PalServer.exe"" $launchArgs`r`n"
        [System.IO.File]::WriteAllText($StartScript, $bat, (New-Object System.Text.ASCIIEncoding))
        Add-WizardLog 'StartServer.bat made (it checks for game updates before each start).'
    }
}

function Add-FirewallRules($A) {
    # One administrator prompt. If it is declined, Windows asks the first time the server starts instead.
    $cmd = "Get-NetFirewallRule -DisplayName 'VPal Palworld*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; " +
           "New-NetFirewallRule -DisplayName 'VPal Palworld game (UDP " + $A.Port + ")' -Direction Inbound -Protocol UDP -LocalPort " + $A.Port + " -Action Allow -Profile Any | Out-Null"
    if ($A.Public) { $cmd += "; New-NetFirewallRule -DisplayName 'VPal Palworld server list (UDP 27015)' -Direction Inbound -Protocol UDP -LocalPort 27015 -Action Allow -Profile Any | Out-Null" }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop `
                -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"')
        if ($p.ExitCode -eq 0) { return '' }
        return 'Windows could not add the firewall rules'
    }
    catch { return 'skipped: no administrator permission. Windows asks the first time the server starts' }
}

function Show-SetupWizard {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'VPal Server Command Center: set up your server'
    $f.ClientSize = New-Object System.Drawing.Size(640, 580)
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.Font = $FontMain
    $wz = @{ Form = $f; Done = $false; Busy = $false }
    $script:WZ = $wz
    $existing = Test-Path -LiteralPath (Join-Path $ServerDir 'PalServer.exe')

    # ---- page 1: questions ----
    $p1 = New-Object System.Windows.Forms.Panel
    $p1.Dock = 'Fill'
    $h = New-Text 'Set up your Palworld server' 20 16 600 -Bold
    $h.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $intro = 'Answer a few questions, then VPal downloads the free Palworld dedicated server from Steam (about 6 GB) and sets everything up. ' +
             'You can change all of this later in the control panel.'
    if ($existing) { $intro = 'VPal found a Palworld server in this folder that has no settings yet. Answer a few questions and VPal fills them in.' }
    $p1.Controls.Add($h)
    $p1.Controls.Add((New-SmallLabel $intro 22 54 590))
    $y = 104
    $fields = @{}
    foreach ($row in @(@('Name', 'Server name', 'My Palworld Server', 'What people see in the server list.'),
                       @('Password', 'Password to join', '', 'Optional, but a good idea for a server in the public list.'))) {
        $p1.Controls.Add((New-Text $row[1] 22 ($y + 3) 150))
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Font = $FontMain
        $tb.Location = New-Object System.Drawing.Point(180, $y)
        $tb.Width = 260
        $tb.MaxLength = 60
        $tb.Text = $row[2]
        $p1.Controls.Add($tb)
        $p1.Controls.Add((New-SmallLabel $row[3] 180 ($y + 26) 420))
        $fields[$row[0]] = $tb
        $y += 54
    }
    $p1.Controls.Add((New-Text 'Players at once' 22 ($y + 3) 150))
    $np = New-Num 1 32 0
    $np.Value = 16
    $np.Location = New-Object System.Drawing.Point(180, $y)
    $p1.Controls.Add($np)
    $y += 36
    $p1.Controls.Add((New-Text 'Game port' 22 ($y + 3) 150))
    $nport = New-Num 1024 65535 0
    $nport.Width = 80
    $nport.Value = 8211
    $nport.Location = New-Object System.Drawing.Point(180, $y)
    $p1.Controls.Add($nport)
    $p1.Controls.Add((New-SmallLabel 'Leave it at 8211 unless you know you need another one.' 270 ($y + 4) 340))
    $y += 36
    $pub = New-Check 'List it in Community Servers (Xbox and PlayStation players can only join this way)'
    $pub.Checked = $true
    $pub.Location = New-Object System.Drawing.Point(22, $y)
    $p1.Controls.Add($pub)
    $y += 34
    $p1.Controls.Add((New-Text 'Admin password' 22 ($y + 3) 150))
    $ta = New-Object System.Windows.Forms.TextBox
    $ta.Font = $FontMain
    $ta.ReadOnly = $true
    $ta.Location = New-Object System.Drawing.Point(180, $y)
    $ta.Width = 260
    $ta.Text = New-AdminPassword
    $p1.Controls.Add($ta)
    $p1.Controls.Add((New-SmallLabel 'Made for you. The control panel uses it to talk to the server; it is saved in the server''s settings file.' 180 ($y + 26) 420))
    $y += 62
    $drive = ''
    try { $d = Get-PSDrive -Name ($ServerDir.Substring(0, 1)) -ErrorAction Stop; $drive = ('{0:0} GB free on drive {1}:' -f ($d.Free / 1GB), $d.Name) } catch { }
    $p1.Controls.Add((New-SmallLabel ('Folder: ' + $ServerDir + '   ' + $drive) 22 $y 590))
    $go = New-Button 'Install my server'
    if ($existing) { $go.Text = 'Save and start' }
    $go.Font = $FontBold
    $cancel1 = New-Button 'Cancel'
    $p1.Controls.Add((New-ButtonRow 16 528 @($go, $cancel1)))
    $go.Font = $FontBold
    $wz.Fields = $fields; $wz.Players = $np; $wz.Port = $nport; $wz.Public = $pub; $wz.Admin = $ta

    # ---- page 2: progress ----
    $p2 = New-Object System.Windows.Forms.Panel
    $p2.Dock = 'Fill'
    $p2.Visible = $false
    $h2 = New-Text 'Setting up your server' 20 16 600 -Bold
    $h2.Font = $h.Font
    $p2.Controls.Add($h2)
    $p2.Controls.Add((New-SmallLabel 'This takes 5 to 20 minutes, mostly the download. You can leave it running.' 22 50 590))
    $wz.StepNames = @('Download SteamCMD, Valve''s free server downloader', 'Download the Palworld server', 'Write the server settings',
                      'Open the game ports in Windows Firewall (Windows asks once)', 'Install Python, for the watchdog and the Pal Planner',
                      'Start the watchdog', 'Start the server for the first time')
    $wz.Steps = @()
    for ($i = 0; $i -lt $wz.StepNames.Count; $i++) {
        $l = New-Text '' 22 (80 + 24 * $i) 600
        $l.Font = $FontMain
        $p2.Controls.Add($l)
        $wz.Steps += $l
    }
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(22, 256)
    $bar.Size = New-Object System.Drawing.Size(596, 20)
    $bar.MarqueeAnimationSpeed = 30
    $p2.Controls.Add($bar)
    $wz.Bar = $bar
    $wz.Detail = New-Text '' 22 282 596
    $p2.Controls.Add($wz.Detail)
    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $log.Location = New-Object System.Drawing.Point(22, 310)
    $log.Size = New-Object System.Drawing.Size(596, 206)
    $p2.Controls.Add($log)
    $wz.Log = $log
    $again = New-Button 'Try again'
    $again.Visible = $false
    $cancel2 = New-Button 'Cancel'
    $cancel2.Visible = $false
    $p2.Controls.Add((New-ButtonRow 16 528 @($again, $cancel2)))
    $wz.Again = $again; $wz.Cancel2 = $cancel2

    # ---- page 3: done ----
    $p3 = New-Object System.Windows.Forms.Panel
    $p3.Dock = 'Fill'
    $p3.Visible = $false
    $h3 = New-Text 'Your server is set up' 20 16 600 -Bold
    $h3.Font = $h.Font
    $p3.Controls.Add($h3)
    $sum = New-Object System.Windows.Forms.TextBox
    $sum.Multiline = $true
    $sum.ReadOnly = $true
    $sum.ScrollBars = 'Vertical'
    $sum.BackColor = [VPalUi.Theme]::Card2
    $sum.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $sum.Location = New-Object System.Drawing.Point(22, 56)
    $sum.Size = New-Object System.Drawing.Size(596, 460)
    $p3.Controls.Add($sum)
    $wz.Summary = $sum
    $copy = New-Button 'Copy these steps'
    $open = New-Button 'Open the control panel'
    $p3.Controls.Add((New-ButtonRow 16 528 @($open, $copy)))
    $open.Font = $FontBold

    foreach ($p in @($p1, $p2, $p3)) { $f.Controls.Add($p) }
    $wz.P1 = $p1; $wz.P2 = $p2; $wz.P3 = $p3

    $cancel1.add_Click({ $script:WZ.Form.Close() })
    $cancel2.add_Click({ $script:WZ.Form.Close() })
    $copy.add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:WZ.Summary.Text) } catch { } })
    $open.add_Click({ $script:WZ.Done = $true; $script:WZ.Form.Close() })
    $go.add_Click({
        $w = $script:WZ
        $name = $w.Fields.Name.Text.Trim()
        $pw = $w.Fields.Password.Text
        if (-not $name) { Show-Message 'Type a server name.'; return }
        if (($name + $pw).Contains('"')) { Show-Message 'Leave out double quote marks (") in the name and the password.'; return }
        if ($pw -match '\s') { Show-Message 'Leave spaces out of the password: some consoles cannot type them.'; return }
        if ($w.Public.Checked -and -not $pw) {
            if (-not (Confirm-Action 'Your server will be in the public list with no password, so anyone can join. Continue?')) { return }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $ServerDir 'PalServer.exe'))) {
            try {
                $d = Get-PSDrive -Name ($ServerDir.Substring(0, 1)) -ErrorAction Stop
                if ($d.Free -lt 12GB) {
                    if (-not (Confirm-Action ('Drive ' + $d.Name + ': has only ' + [int]($d.Free / 1GB) + ' GB free. The server needs about 6 GB, plus room for worlds and backups. Continue anyway?'))) { return }
                }
            }
            catch { }
        }
        $w.Answers = @{ Name = $name; Password = $pw; Players = [int]$w.Players.Value; Port = [int]$w.Port.Value; Public = [bool]$w.Public.Checked; Admin = $w.Admin.Text }
        $w.P1.Visible = $false
        $w.P2.Visible = $true
        Invoke-SetupSteps
    })
    $again.add_Click({ $script:WZ.Again.Visible = $false; $script:WZ.Cancel2.Visible = $false; Invoke-SetupSteps })
    $f.add_FormClosing({
        param($s, $e)
        if ($script:WZ.Busy) { $e.Cancel = $true; Show-Message 'Please wait until this step finishes.' }
    })

    [VPalUi.Dark]::Apply($f)
    [void]$f.ShowDialog()
    $f.Dispose()
    return [bool]$script:WZ.Done
}

function Invoke-SetupSteps {
    $w = $script:WZ
    $A = $w.Answers
    $w.Busy = $true
    $w.Form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
    $notes = @{}
    for ($i = 0; $i -lt $w.StepNames.Count; $i++) { if (-not $w.StepDone -or -not $w.StepDone[$i]) { Set-WizardStep $i 'wait' '' } }
    if (-not $w.StepDone) { $w.StepDone = @{} }
    $failed = $false
    try {
        $hasServer = Test-Path -LiteralPath (Join-Path $ServerDir 'PalServer.exe')
        # 1-3 must work
        if (-not $w.StepDone[0]) {
            if ($hasServer -and -not (Test-Path -LiteralPath $SteamCmdExe)) { Set-WizardStep 0 'skip' 'not needed: the server is already here'; $w.StepDone[0] = $true }
            else { Set-WizardStep 0 'now' ''; Install-SteamCmd; Set-WizardStep 0 'done' ''; $w.StepDone[0] = $true }
        }
        if (-not $w.StepDone[1]) {
            if ($hasServer) { Set-WizardStep 1 'skip' 'already here'; $w.StepDone[1] = $true }
            else { Set-WizardStep 1 'now' ''; Install-PalServerFiles; Set-WizardStep 1 'done' ''; $w.StepDone[1] = $true }
        }
        if (-not $w.StepDone[2]) { Set-WizardStep 2 'now' ''; Write-ServerSettings $A; Set-WizardStep 2 'done' ''; $w.StepDone[2] = $true }
    }
    catch {
        $failed = $true
        for ($i = 0; $i -lt 3; $i++) { if (-not $w.StepDone[$i]) { Set-WizardStep $i 'fail' ''; break } }
        Add-WizardLog ('Stopped: ' + $_.Exception.Message)
        Set-WizardProgress 0 $_.Exception.Message
        $w.Detail.ForeColor = $ColorOff
        $w.Again.Visible = $true
        $w.Cancel2.Visible = $true
    }
    if ($failed) { $w.Busy = $false; $w.Form.Cursor = [System.Windows.Forms.Cursors]::Default; return }
    $w.Detail.ForeColor = $ColorNormal

    # 4-7 are worth doing but never stop the setup
    Set-WizardStep 3 'now' ''
    Set-WizardProgress $null 'Waiting for Windows (look for its prompt)...'
    $n = Add-FirewallRules $A
    if ($n) { Set-WizardStep 3 'skip' $n; $notes.Firewall = $n } else { Set-WizardStep 3 'done' ''; Add-WizardLog 'Firewall rules added.' }

    Set-WizardStep 4 'now' ''
    Set-WizardProgress $null 'Checking for Python...'
    try {
        if (Find-Python) { Set-WizardStep 4 'done' 'already installed' }
        elseif (Install-Python) { Set-WizardStep 4 'done' ''; Add-WizardLog 'Python installed.' }
        else { Set-WizardStep 4 'fail' 'install it later from the Watchdog tab'; $notes.Python = $true }
    }
    catch { Set-WizardStep 4 'fail' $_.Exception.Message; $notes.Python = $true }

    Set-WizardStep 5 'now' ''
    Set-WizardProgress $null 'Starting the watchdog...'
    try {
        if (-not $notes.Python -and (Start-Watchdog -Quiet)) { Set-WizardStep 5 'done' ''; Add-WizardLog 'The watchdog is running.' }
        else { Set-WizardStep 5 'fail' 'start it later on the Watchdog tab'; $notes.Watchdog = $true }
    }
    catch { Set-WizardStep 5 'fail' $_.Exception.Message; $notes.Watchdog = $true }

    Set-WizardStep 6 'now' ''
    Set-WizardProgress $null 'Starting the server. The first start makes the world, which takes a minute or two.'
    try {
        if (Test-ServerRunning) { Set-WizardStep 6 'done' 'it is already running' }
        elseif (Start-PalServer) { Set-WizardStep 6 'done' ''; Add-WizardLog 'The server is starting.' }
        else { Set-WizardStep 6 'fail' 'start it from the control panel'; $notes.Start = $true }
    }
    catch { Set-WizardStep 6 'fail' $_.Exception.Message; $notes.Start = $true }
    Set-WizardProgress 100 'Done.'

    # ---- what is left for the person to do ----
    $ip = Get-LocalIPv4
    $pc = 'this PC'
    if ($ip) { $pc = 'this PC (' + $ip + ')' }
    $nl = "`r`n"
    $t = 'Your Palworld server "' + $A.Name + '" is set up and starting. Two things are left, and then people can join.' + $nl + $nl
    $t += '1. Open the ports on your router' + $nl
    $t += '   In your router''s settings (often under Port Forwarding or Virtual Servers), forward these to ' + $pc + ':' + $nl
    $t += '   - UDP ' + $A.Port + ' (the game)' + $nl
    if ($A.Public) { $t += '   - UDP 27015 (the server list, needed for Xbox and PlayStation)' + $nl }
    $t += '   Never forward 8212. That port is only for this control panel.' + $nl
    if ($notes.Firewall) { $t += '   Windows Firewall: ' + $notes.Firewall + '. When Windows asks about PalServer, click Allow.' + $nl }
    $t += $nl + '2. Tell people how to join' + $nl
    if ($A.Public) { $t += '   - Xbox and PlayStation: Join Multiplayer Game > Community Servers, then search for "' + $A.Name + '".' + $nl }
    $t += '   - PC: Join Multiplayer Game, then type your public IP address and :' + $A.Port + ' (search "what is my IP" to find it)'
    if ($A.Public) { $t += ', or use Community Servers' }
    $t += '.' + $nl
    if ($A.Password) { $t += '   - Password: ' + $A.Password + $nl }
    $t += $nl + 'Next, in the control panel' + $nl
    $t += '   - Pal Planner tab: Set up sharing, so everyone gets their own pal planner on their phone.' + $nl
    $t += '   - Discord tab: alerts and slash commands in your Discord server.' + $nl
    $t += '   - Watchdog tab: daily restarts, crash and freeze recovery, backups.' + $nl
    if ($notes.Python -or $notes.Watchdog) { $t += $nl + 'The watchdog is not running yet. Open the Watchdog tab and click Start the watchdog (it installs Python if needed).' + $nl }
    if ($notes.Start) { $t += $nl + 'The server did not start by itself. Click Start server at the top of the control panel.' + $nl }
    $t += $nl + 'VPal is an unofficial fan tool, not affiliated with Pocketpair.' + $nl
    $w.Summary.Text = $t
    $w.Busy = $false
    $w.Form.Cursor = [System.Windows.Forms.Cursors]::Default
    $w.P2.Visible = $false
    $w.P3.Visible = $true
}

# ---------------- Window ----------------
try {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'VPal Server Command Center'
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $fw = [Math]::Min(1300, $wa.Width - 40)
    $fh = [Math]::Min(880, $wa.Height - 40)
    $form.Size = New-Object System.Drawing.Size($fw, $fh)
    $form.MinimumSize = New-Object System.Drawing.Size(([Math]::Min(1180, $fw)), ([Math]::Min(680, $fh)))
    $form.StartPosition = 'CenterScreen'
    $form.Font = $FontMain
    $form.BackColor = [VPalUi.Theme]::Navy
    $form.ForeColor = [VPalUi.Theme]::Text
    try { $form.Icon = New-Object System.Drawing.Icon((Join-Path $UiDir 'vpal.ico')) } catch { }

    $ToolTip = New-Object System.Windows.Forms.ToolTip
    $ToolTip.AutoPopDelay = 15000

    function New-Button([string]$Text, [string]$Icon = '', [string]$Kind = 'Outline') {
        # Kind: Outline, Accent (teal edge), Primary (teal), Danger (red edge), Gold
        $b = New-Object VPalUi.RoundButton
        $b.Text = $Text
        $b.AutoSize = $true
        $b.Height = 32
        $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
        $b.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
        if ($Icon) { $b.IconImage = [VPalUi.Theme]::Icon('ui_' + $Icon) }
        $b.Kind = $Kind
        return $b
    }

    # The night scene behind everything, the sidebar on the left
    $shell = New-Object VPalUi.BackdropPanel
    $shell.Dock = 'Fill'
    [VPalUi.Theme]::Host = $shell
    $nav = New-Object VPalUi.NavList
    $nav.Dock = 'Left'
    $nav.Width = 240
    $nav.Logo = [VPalUi.Theme]::Icon('vpal_v128')
    $nav.Title = 'VPal'
    $nav.Subtitle = 'Server Command Center'
    $right = New-Object VPalUi.BackdropPanel
    $right.Dock = 'Fill'

    # Top bar: the server card on the left; Update VPal, Health check and Start or Stop on the right
    $header = New-Object VPalUi.BackdropPanel
    $header.Dock = 'Top'
    $header.Height = 92
    $status = New-Object VPalUi.StatusCard
    $status.ServerName = 'Palworld'
    $status.State = 'Checking...'
    $status.StateColor = [VPalUi.Theme]::Faint
    $status.Location = New-Object System.Drawing.Point(24, 18)
    $header.Controls.Add($status)

    $serverBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $serverBar.Dock = 'Right'
    $serverBar.FlowDirection = 'RightToLeft'
    $serverBar.AutoSize = $true
    $serverBar.WrapContents = $false
    $serverBar.BackColor = $ColorClear
    $serverBar.Padding = New-Object System.Windows.Forms.Padding(0, 27, 24, 0)
    $btnStop   = New-Button 'Stop server' 'stop' 'Danger'
    $btnStart  = New-Button 'Start server' 'start' 'Primary'
    $btnHealth = New-Button 'Health check' 'watchdog' 'Accent'
    $btnVPal   = New-Button 'Update VPal' 'update' 'Gold'
    foreach ($b in @($btnStop, $btnStart, $btnHealth, $btnVPal)) {
        $b.Height = 40
        $b.Margin = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $serverBar.Controls.Add($b)
    }
    $btnStart.Visible = $false
    $btnVPal.Visible = $false
    $ToolTip.SetToolTip($btnVPal, 'A newer VPal is out. Click to see what is new and update. The game server keeps running.')
    $ToolTip.SetToolTip($btnHealth, 'Checks the server, its ports, the watchdog and this PC, and says what to fix.')
    $header.Controls.Add($serverBar)

    # The pages; the sidebar follows them
    $tabs = New-Object VPalUi.PageHost
    $tabs.Dock = 'Fill'
    $tabs.add_SelectedIndexChanged({
        try { if ($null -ne $tabs.SelectedTab -and $tabs.SelectedTab.Text -eq 'Messages') { Update-WelcomeState } } catch { }
        try { if ($null -ne $tabs.SelectedTab -and $tabs.SelectedTab.Text -eq 'Pal Planner' -and -not $script:Busy) { Update-PlannerTab } } catch { }
        try { Update-SelectedTab } catch { }
    })
    $nav.Bind($tabs)

    # Bottom bar: unsaved changes and the last message on the left; the save buttons on the right
    $bottom = New-Object VPalUi.BackdropPanel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 92
    $bottom.Padding = New-Object System.Windows.Forms.Padding(24, 10, 24, 18)
    $bar = New-Object VPalUi.Card
    $bar.Glass = $true
    $bar.Dock = 'Fill'
    $bar.BackColor = $ColorClear

    $chgDot = New-Object VPalUi.Dot
    $chgDot.Location = New-Object System.Drawing.Point(20, 25)
    $lblChanges = New-Object System.Windows.Forms.Label
    $lblChanges.AutoSize = $true
    $lblChanges.UseMnemonic = $false
    $lblChanges.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
    $lblChanges.BackColor = $ColorClear
    $lblChanges.Location = New-Object System.Drawing.Point(42, 21)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $false
    $lblStatus.AutoEllipsis = $true
    $lblStatus.UseMnemonic = $false
    $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
    $lblStatus.ForeColor = $ColorDesc
    $lblStatus.BackColor = $ColorClear
    $lblStatus.TextAlign = 'MiddleLeft'
    $lblStatus.Location = New-Object System.Drawing.Point(236, 12)
    $lblStatus.Size = New-Object System.Drawing.Size(200, 40)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Right'
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.AutoSize = $true
    $buttons.WrapContents = $false
    $buttons.BackColor = $ColorClear
    $buttons.Padding = New-Object System.Windows.Forms.Padding(0, 13, 12, 0)
    $btnClose   = $null                      # the window's own X closes it
    $btnRestart = New-Button 'Save & restart' 'rocket' 'Primary'
    $btnSave    = New-Button 'Save' 'save' 'Accent'
    $btnUndo    = New-Button 'Undo changes' 'undo'
    $btnBackups = New-Button 'Settings backups' 'backups'
    foreach ($b in @($btnRestart, $btnSave, $btnUndo, $btnBackups)) {
        $b.Height = 38
        $b.Margin = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $buttons.Controls.Add($b)
    }
    $ToolTip.SetToolTip($btnRestart, 'Saves your changes, then restarts the server so they apply.')
    $ToolTip.SetToolTip($btnSave, 'Saves your changes. They apply the next time the server starts. Every save keeps a backup.')
    $ToolTip.SetToolTip($btnUndo, 'Throws away unsaved changes and reloads the settings file.')
    $ToolTip.SetToolTip($btnBackups, 'Opens the folder with a backup of the settings file from every save.')
    $bar.Controls.Add($buttons)
    $bar.Controls.Add($chgDot)
    $bar.Controls.Add($lblChanges)
    $bar.Controls.Add($lblStatus)
    $bottom.Controls.Add($bar)

    $right.Controls.Add($tabs)
    $right.Controls.Add($header)
    $right.Controls.Add($bottom)
    $tabs.BringToFront()
    $shell.Controls.Add($right)
    $shell.Controls.Add($nav)
    $right.BringToFront()
    $form.Controls.Add($shell)

    # ---- Button actions ----
    $btnStart.add_Click({
        try {
            $n = Get-ChangeCount
            if ($n -gt 0) {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "You have $n unsaved change(s). Save them first so the server starts with them?",
                    'VPal Server Command Center', 'YesNoCancel', 'Question')
                if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Set-Busy $true
                    if (-not (Save-Settings -Quiet)) { return }
                }
            }
            Set-Busy $true
            [void](Start-PalServer)
        }
        catch { Show-Message ("Could not start the server:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })

    $btnStop.add_Click({
        try {
            if (Test-AutoRestartRunning) {
                Show-Message 'The scheduled restart is in progress right now. Let it finish first.'
                return
            }
            $ask = "Stop the server?`n`nIt saves the world first. Anyone online gets a 30-second warning and is disconnected."
            if (-not (Confirm-Action $ask)) { return }
            Set-Busy $true
            [void](Stop-PalServer 'Server shutting down in 30 seconds. Thanks for playing!')
        }
        catch { Show-Message ("Could not stop the server:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })

    $btnVPal.add_Click({
        try { Start-VPalUpdate }
        catch { Show-Message ("The VPal update hit a problem:`n`n" + $_.Exception.Message) 'Error' }
    })

    $btnHealth.add_Click({
        try { Show-HealthCheck }
        catch { Show-Message ("The health check could not open:`n`n" + $_.Exception.Message) 'Error' }
    })

    $btnSave.add_Click({
        try {
            Set-Busy $true
            $null = Save-Settings
        }
        catch { Show-Message ("Save failed, nothing was changed:`n`n" + $_.Exception.Message) 'Error' }
        finally { Set-Busy $false }
    })

    $btnRestart.add_Click({
        try {
            Set-Busy $true
            if (Save-Settings -Quiet) { Restart-PalServer }
        }
        catch { Show-Message ("Something went wrong:`n`n" + $_.Exception.Message) 'Error' }
        finally {
            Set-Busy $false
            Update-ServerStatus
        }
    })

    $btnUndo.add_Click({
        try {
            $n = Get-ChangeCount
            if ($n -eq 0 -or (Confirm-Action "Throw away $n unsaved change(s) and reload the settings file?")) {
                $null = Build-Editor
                Set-Status 'Reloaded from the settings file.'
            }
        }
        catch { Show-Message ("Could not reload:`n`n" + $_.Exception.Message) 'Error' }
    })

    $btnBackups.add_Click({
        try {
            [void](New-Item -ItemType Directory -Force -Path $BackupDir)
            Start-Process -FilePath $BackupDir
        }
        catch { Show-Message ("Could not open the backups folder:`n`n" + $_.Exception.Message) 'Error' }
    })

    $form.add_FormClosing({
        param($s, $e)
        if ($script:Relaunching) { return }          # reopening on a new VPal version (unsaved changes were dealt with)
        if ($script:Busy) {
            $e.Cancel = $true
            Show-Message 'Please wait until the current step finishes.'
            return
        }
        $n = Get-ChangeCount
        if ($n -gt 0 -and -not (Confirm-Action "You have $n unsaved change(s). Close without saving?")) { $e.Cancel = $true }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 5000
    $timer.add_Tick({
        try { Update-ServerStatus } catch { }
        try { if (-not $script:Busy -and $null -ne $tabs.SelectedTab -and $tabs.SelectedTab.Text -eq 'Pal Planner') { Update-PlannerData } } catch { }
        try { Update-SelectedTab -Timer } catch { }
        try { $script:VU.Ticks++; if ($script:VU.Ticks % 12 -eq 0) { Update-VPalUpdate } } catch { }
    })
    $form.add_Resize({ try { Set-HeaderFit } catch { } })
    $form.add_Shown({
        try { Initialize-Watchdog } catch { }
        try { Update-SelectedTab } catch { }
        try { Set-HeaderFit; Update-VPalUpdate } catch { }
    })

    if (-not (Invoke-FirstRunCheck)) { return }      # a new server: the setup wizard first
    $null = Build-Editor
    Update-ServerStatus
    Set-Status 'Every save keeps a backup.'
    $timer.Start()
    [void]$form.ShowDialog()
    $timer.Stop()
}
catch {
    Show-Message ("The VPal Server Command Center hit a problem and could not open:`n`n" + $_.Exception.Message) 'Error'
}
