# Create or update the BitLocker AD DS backup GPO from a settings file and link it to the client OU (README section 3).
# Run on a domain controller or a domain-joined management computer that has the GroupPolicy and ActiveDirectory modules,
# elevated, in Windows PowerShell 5.1 or PowerShell 7. ASCII-only.
#
# In order - nothing changes before step 4:
#   1. Checks: elevation, settings file, modules, Active Directory (domain-joined, a domain controller answers).
#   2. Checks every policy value name and value against VolumeEncryption.admx (central store first, then the local copy).
#   3. Finds the OU by name in the current domain, reads the GPO and its link, and plans only what differs.
#   4. Shows the plan in yellow and asks Y/N, backs up an existing GPO before changing it, applies, and verifies from
#      AD and SYSVOL. Running it again when everything matches changes nothing and does not ask.
#
#   .\Set-BitLockerAdBackupGpo.ps1                 # settings: BitLockerAdBackupGpo.json next to this script
#   .\Set-BitLockerAdBackupGpo.ps1 -WhatIf         # plan only
#   .\Set-BitLockerAdBackupGpo.ps1 -NoConfirm      # automation: no prompt, still logged
#   .\Set-BitLockerAdBackupGpo.ps1 -SettingsPath D:\cfg\other.json
# Needs Confirm-Change.ps1 in the same folder. Evidence: <LogDir>\Set-BitLockerAdBackupGpo-<time>.log and .csv, GPO backups.
# Undo a GPO this script created: Remove-GPO -Name '<GpoName>' (it also removes the GPO's links in the domain).
# Undo an update: Restore-GPO -Guid <Id> -Path <backup folder shown in the results>.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # JSON settings (GpoName, GpoComment, OuName, Prefixes, Values). Empty = BitLockerAdBackupGpo.json next to this script.
    [ValidatePattern('^$|^[^"*?<>|]+\.json$')][string]$SettingsPath = '',
    # Folder for the transcript, results CSV and GPO backups. Empty = %SystemDrive%\Logs.
    [ValidatePattern('^$|^[A-Za-z]:\\[^"*?<>|]+$')][string]$LogDir = '',
    [switch]$NoConfirm
)
$ErrorActionPreference = 'Stop'

$FveKey        = 'HKLM\SOFTWARE\Policies\Microsoft\FVE'
$AdmxFveKey    = 'SOFTWARE\Policies\Microsoft\FVE'
$KnownPrefixes = @('OS', 'FDV', 'RDV')
$KnownValues   = @('Recovery', 'ManageDRA', 'RecoveryPassword', 'RecoveryKey', 'HideRecoveryPage', 'ActiveDirectoryBackup', 'ActiveDirectoryInfoToStore', 'RequireActiveDirectoryBackup')
$NamePattern   = '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,79}$'   # GPO and OU names: no quotes, so they are safe inside AD filters
$PrefixText    = @{ OS = 'operating system'; FDV = 'fixed data'; RDV = 'removable data' }
# Policy 'Choose drive encryption method and cipher strength (Windows 10 [Version 1511] and later)'
$MethodValueNames = @{ OS = 'EncryptionMethodWithXtsOs'; FDV = 'EncryptionMethodWithXtsFdv'; RDV = 'EncryptionMethodWithXtsRdv' }
$MethodText       = @{ 3 = 'AES-CBC 128'; 4 = 'AES-CBC 256'; 6 = 'XTS-AES 128'; 7 = 'XTS-AES 256' }
$SettingsFields   = @('GpoName', 'GpoComment', 'OuName', 'Prefixes', 'Values', 'EncryptionMethods')

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Status, [string]$Check, [string]$Detail) { $Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail }) }

# --- Decision logic (no system access) ---

# Parse and validate the settings JSON. Returns GpoName, GpoComment, OuName, Prefixes (string[]), Values (ordered name -> int)
# and EncryptionMethods (ordered prefix -> int).
function Read-Settings([string]$Text, [string]$Source) {
    try { $Raw = $Text | ConvertFrom-Json } catch { throw "STOP: $Source is not valid JSON ($($_.Exception.Message)). Nothing was changed." }
    if ($null -eq $Raw -or $Raw -isnot [System.Management.Automation.PSCustomObject]) { throw "STOP: $Source must hold one JSON object. Nothing was changed." }
    $Fields = @($Raw.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($Field in $SettingsFields) {
        if ($Fields -notcontains $Field) { throw "STOP: $Source has no '$Field'. Nothing was changed." }
    }
    $Extra = @($Fields | Where-Object { $SettingsFields -notcontains $_ })
    if ($Extra.Count) { throw "STOP: $Source has unknown field(s): $($Extra -join ', '). Nothing was changed." }

    foreach ($Field in 'GpoName', 'OuName') {
        $V = $Raw.$Field
        if ($V -isnot [string] -or $V -notmatch $NamePattern) { throw "STOP: $Field '$V' in $Source must be 1-80 letters, digits, spaces, '_', '-' or '.', starting with a letter or digit. Nothing was changed." }
    }
    if ($Raw.GpoComment -isnot [string] -or $Raw.GpoComment.Length -gt 2047 -or $Raw.GpoComment -match '[\x00-\x1F]') { throw "STOP: GpoComment in $Source must be text of at most 2047 characters, without control characters. Nothing was changed." }

    if ($Raw.Prefixes -isnot [array] -or @($Raw.Prefixes).Count -eq 0) { throw "STOP: Prefixes in $Source must be a non-empty list, e.g. [ ""OS"", ""FDV"" ]. Nothing was changed." }
    $Prefixes = New-Object System.Collections.Generic.List[string]
    foreach ($P in $Raw.Prefixes) {
        if ($P -isnot [string] -or $KnownPrefixes -cnotcontains $P) { throw "STOP: prefix '$P' in $Source is not one of $($KnownPrefixes -join ', '). Nothing was changed." }
        if ($Prefixes.Contains($P)) { throw "STOP: prefix '$P' is listed twice in $Source. Nothing was changed." }
        $Prefixes.Add($P)
    }

    if ($Raw.Values -isnot [System.Management.Automation.PSCustomObject]) { throw "STOP: Values in $Source must be a JSON object of name: number pairs. Nothing was changed." }
    $Names = @($Raw.Values.PSObject.Properties | ForEach-Object { $_.Name })
    $Unknown = @($Names | Where-Object { $KnownValues -cnotcontains $_ })
    if ($Unknown.Count) { throw "STOP: unknown value name(s) in $Source : $($Unknown -join ', '). Known: $($KnownValues -join ', '). Nothing was changed." }
    $Missing = @($KnownValues | Where-Object { $Names -cnotcontains $_ })
    if ($Missing.Count) { throw "STOP: value(s) missing from $Source : $($Missing -join ', '). Nothing was changed." }
    $Values = [ordered]@{}
    foreach ($Name in $KnownValues) {
        $V = $Raw.Values.$Name
        if (-not ($V -is [int] -or $V -is [long]) -or $V -lt 0 -or $V -gt 4294967295) { throw "STOP: $Name in $Source must be a whole number, not '$V'. Nothing was changed." }
        $Values[$Name] = [long]$V
    }
    if ($Values['ActiveDirectoryBackup'] -ne 1) { throw "STOP: ActiveDirectoryBackup in $Source is $($Values['ActiveDirectoryBackup']); this GPO exists to store recovery information in AD DS, so it must be 1. Nothing was changed." }

    if ($Raw.EncryptionMethods -isnot [System.Management.Automation.PSCustomObject]) { throw "STOP: EncryptionMethods in $Source must be a JSON object such as { ""OS"": 7 } (7 = XTS-AES 256). Nothing was changed." }
    $MethodKeys = @($Raw.EncryptionMethods.PSObject.Properties | ForEach-Object { $_.Name })
    if (@($MethodKeys | Where-Object { $Prefixes -cnotcontains $_ }).Count -or @($Prefixes | Where-Object { $MethodKeys -cnotcontains $_ }).Count) {
        throw "STOP: EncryptionMethods in $Source must name exactly the drive types in Prefixes ($($Prefixes -join ', ')), not ($($MethodKeys -join ', ')). Nothing was changed."
    }
    $Methods = [ordered]@{}
    foreach ($P in $Prefixes) {
        $V = $Raw.EncryptionMethods.$P
        if (-not ($V -is [int] -or $V -is [long]) -or $V -lt 0 -or $V -gt 4294967295) { throw "STOP: EncryptionMethods.$P in $Source must be a whole number (7 = XTS-AES 256), not '$V'. Nothing was changed." }
        $Methods[$P] = [long]$V
    }

    [pscustomobject]@{ GpoName = $Raw.GpoName; GpoComment = $Raw.GpoComment; OuName = $Raw.OuName; Prefixes = $Prefixes.ToArray(); Values = $Values; EncryptionMethods = $Methods }
}

# 'OS XTS-AES 256, FDV XTS-AES 256' for messages
function Get-MethodSummary($Settings) {
    ($Settings.Prefixes | ForEach-Object { $T = $MethodText[[int]$Settings.EncryptionMethods[$_]]; if (-not $T) { $T = "value $($Settings.EncryptionMethods[$_])" }; "$_ $T" }) -join ', '
}

# Allowed values per registry value name under SOFTWARE\Policies\Microsoft\FVE, read from VolumeEncryption.admx
function Get-AdmxAllowedValues([string]$XmlText) {
    $Doc = New-Object System.Xml.XmlDocument
    $Doc.XmlResolver = $null   # never resolve external entities from the file
    try { $Doc.LoadXml($XmlText) } catch { throw "STOP: VolumeEncryption.admx is not valid XML ($($_.Exception.Message)). Nothing was changed." }
    $Ns = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
    $Ns.AddNamespace('p', $Doc.DocumentElement.NamespaceURI)
    $Allowed = @{}
    foreach ($Policy in $Doc.SelectNodes("//p:policy[@key='$AdmxFveKey' and (@class='Machine' or @class='Both')]", $Ns)) {
        $PolicyValue = $Policy.GetAttribute('valueName')
        if ($PolicyValue) {
            $On = $Policy.SelectSingleNode('p:enabledValue/p:decimal', $Ns); $Off = $Policy.SelectSingleNode('p:disabledValue/p:decimal', $Ns)
            $Allowed[$PolicyValue] = @($(if ($On) { [long]$On.GetAttribute('value') } else { 1 }), $(if ($Off) { [long]$Off.GetAttribute('value') } else { 0 }))
        }
        foreach ($El in $Policy.SelectNodes('p:elements/*', $Ns)) {
            $Name = $El.GetAttribute('valueName')
            if (-not $Name) { continue }
            if ($El.GetAttribute('key') -and $El.GetAttribute('key') -ne $AdmxFveKey) { continue }
            if ($El.LocalName -eq 'boolean') {
                $T = $El.SelectSingleNode('p:trueValue/p:decimal', $Ns); $F = $El.SelectSingleNode('p:falseValue/p:decimal', $Ns)
                $Allowed[$Name] = @($(if ($T) { [long]$T.GetAttribute('value') } else { 1 }), $(if ($F) { [long]$F.GetAttribute('value') } else { 0 }))
            }
            elseif ($El.LocalName -eq 'enum') {
                $Allowed[$Name] = @($El.SelectNodes('p:item/p:value/p:decimal', $Ns) | ForEach-Object { [long]$_.GetAttribute('value') })
            }
        }
    }
    return $Allowed
}

# Registry value name -> value: the recovery values for every prefix, then each prefix's encryption method
function Get-DesiredValues($Settings) {
    $Desired = [ordered]@{}
    foreach ($P in $Settings.Prefixes) { foreach ($Name in $Settings.Values.Keys) { $Desired["$P$Name"] = $Settings.Values[$Name] } }
    foreach ($P in $Settings.Prefixes) { $Desired[$MethodValueNames[$P]] = $Settings.EncryptionMethods[$P] }
    return $Desired
}

# Desired values that the GPO does not hold yet (missing, not a DWORD, or a different number).
# List helpers return plain pipeline output and callers wrap them in @(): '@(f)' around 'return , @(...)' nests the array.
function Get-ValueChanges($Desired, $Current) {
    $Changes = New-Object System.Collections.Generic.List[object]
    foreach ($Name in $Desired.Keys) {
        $Have = $Current[$Name]
        if ($null -eq $Have) { $From = '(not set)' }
        elseif ($Have.Type -ne 'DWord') { $From = "$($Have.Value) ($($Have.Type))" }
        elseif ([long]$Have.Value -ne $Desired[$Name]) { $From = [string]$Have.Value }
        else { continue }
        $Changes.Add([pscustomobject]@{ Name = $Name; From = $From; To = $Desired[$Name] })
    }
    $Changes.ToArray()
}

# --- System access (the test harness replaces these with mocks) ---

$UnderTest = [bool](Get-Variable -Name GpoScriptTestHarness -ErrorAction SilentlyContinue)
if (-not $UnderTest) {
    function Test-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

    # $null when the file does not exist
    function Get-SettingsText([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        [IO.File]::ReadAllText($Path)
    }

    # GroupPolicy declares no PowerShell 7 support, but it works there with -SkipEditionCheck. ADPS_LoadDefaultDrive = 0 skips
    # the AD: drive, which this script does not use and which fails to initialize in a PowerShell 7 remote session.
    # In PowerShell 7 each module is probed with a read-only call: inside the PowerShell 7 remoting endpoint the native AD
    # module cannot load System.ServiceModel.NetFramingBase, so it is then loaded through Windows PowerShell compatibility.
    # -WhatIf (global when started with -File, script-scoped when started with &) turns the alias set-up of modules into
    # 'What if' noise, so every module is loaded here with it cleared.
    function Import-GpModules {
        $Saved = $Global:WhatIfPreference
        $Global:WhatIfPreference = $false
        $WhatIfPreference = $false
        try {
            $env:ADPS_LoadDefaultDrive = '0'
            $Core = $PSVersionTable.PSEdition -eq 'Core'
            $AdMode = 'native'; $GpMode = 'native'
            if ($Core) { Import-Module -Name GroupPolicy -SkipEditionCheck -ErrorAction Stop } else { Import-Module -Name GroupPolicy -ErrorAction Stop }
            Import-Module -Name ActiveDirectory -ErrorAction Stop
            Import-Module -Name CimCmdlets -ErrorAction Stop
            if ($Core) {
                try { $null = Get-ADDomain -ErrorAction Stop }
                catch {
                    Remove-Module -Name ActiveDirectory -Force -ErrorAction SilentlyContinue
                    Import-Module -Name ActiveDirectory -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
                    $AdMode = 'Windows PowerShell compatibility'
                }
                try { $null = @(Get-GPO -All -ErrorAction Stop) }
                catch {
                    Remove-Module -Name GroupPolicy -Force -ErrorAction SilentlyContinue
                    Import-Module -Name GroupPolicy -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
                    $GpMode = 'Windows PowerShell compatibility'
                }
            }
            'PowerShell {0} {1}: GroupPolicy {2}, ActiveDirectory {3}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, $GpMode, $AdMode
        }
        finally { $Global:WhatIfPreference = $Saved }
    }

    function Test-DomainJoined { [bool](Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain }

    function Get-DomainInfo {
        $D = Get-ADDomain
        [pscustomobject]@{ DNSRoot = [string]$D.DNSRoot; DistinguishedName = [string]$D.DistinguishedName }
    }

    # Central store first (what GPMC uses), then this computer's copy. $null when neither exists.
    # CentralStore: 'Used', 'MissingFile' (a central store without this ADMX) or 'None'.
    function Get-AdmxSource([string]$DnsRoot) {
        $Store = "\\$DnsRoot\SYSVOL\$DnsRoot\Policies\PolicyDefinitions"
        $Central = Join-Path $Store 'VolumeEncryption.admx'
        if (Test-Path -LiteralPath $Central -PathType Leaf) { return [pscustomobject]@{ Path = $Central; Text = [IO.File]::ReadAllText($Central); CentralStore = 'Used' } }
        $State = 'None'
        if (Test-Path -LiteralPath $Store -PathType Container) { $State = 'MissingFile' }
        $Local = Join-Path $env:SystemRoot 'PolicyDefinitions\VolumeEncryption.admx'
        if (Test-Path -LiteralPath $Local -PathType Leaf) { return [pscustomobject]@{ Path = $Local; Text = [IO.File]::ReadAllText($Local); CentralStore = $State } }
        return $null
    }

    function Find-OuByName([string]$Name, [string]$SearchBase) {
        Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $SearchBase | ForEach-Object { [string]$_.DistinguishedName }
    }

    function Get-OuComputerNames([string]$Dn) { Get-ADComputer -Filter * -SearchBase $Dn | ForEach-Object { [string]$_.Name } }

    function Find-GpoByName([string]$Name) {
        Get-GPO -All | Where-Object { $_.DisplayName -eq $Name } | ForEach-Object { [pscustomobject]@{ Id = [guid]$_.Id; DisplayName = [string]$_.DisplayName; GpoStatus = [string]$_.GpoStatus } }
    }

    # Name -> Type/Value of every value the GPO holds under the FVE key; empty when the key does not exist yet
    function Get-GpoFveValues([guid]$Id) {
        $Map = @{}
        try { $Items = @(Get-GPRegistryValue -Guid $Id -Key $FveKey -ErrorAction Stop) }
        catch { if ($_.FullyQualifiedErrorId -like 'UnableToRetrievePolicyRegistryItem*') { return $Map } else { throw } }
        foreach ($Item in $Items) { if ($Item.ValueName) { $Map[[string]$Item.ValueName] = [pscustomobject]@{ Type = [string]$Item.Type; Value = $Item.Value } } }
        return $Map
    }

    # 'None', 'Enabled' or 'Disabled' for the GPO's link on the target
    function Get-GpoLinkState([string]$Target, [guid]$Id) {
        $Link = @((Get-GPInheritance -Target $Target).GpoLinks | Where-Object { $_.GpoId -eq $Id })
        if ($Link.Count -eq 0) { 'None' } elseif ($Link[0].Enabled) { 'Enabled' } else { 'Disabled' }
    }

    # Other GPOs in effect on the target that also set BitLocker policy values
    function Get-FveCompetitors([string]$Target, [guid]$ExcludeId) {
        $Found = New-Object System.Collections.Generic.List[string]
        foreach ($Link in (Get-GPInheritance -Target $Target).InheritedGpoLinks) {
            if ($Link.GpoId -eq $ExcludeId) { continue }
            if (@(Get-GPRegistryValue -Guid $Link.GpoId -Key $FveKey -ErrorAction SilentlyContinue).Count) { $Found.Add(('{0} (precedence {1}, linked at {2})' -f $Link.DisplayName, $Link.Order, $Link.Target)) }
        }
        $Found.ToArray()
    }

    function Get-GpoEvidence([guid]$Id, [string]$DnsRoot) {
        $G = Get-GPO -Guid $Id
        $Pol = "\\$DnsRoot\SYSVOL\$DnsRoot\Policies\{$($Id.ToString().ToUpperInvariant())}\Machine\Registry.pol"
        $Hash = ''
        if (Test-Path -LiteralPath $Pol -PathType Leaf) { $Hash = (Get-FileHash -LiteralPath $Pol -Algorithm SHA256).Hash }
        [pscustomobject]@{ GpoStatus = [string]$G.GpoStatus; DSVersion = [int]$G.Computer.DSVersion; SysvolVersion = [int]$G.Computer.SysvolVersion; RegistryPol = $Pol; Sha256 = $Hash }
    }

    function Backup-ExistingGpo([guid]$Id, [string]$Path) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        [string](Backup-GPO -Guid $Id -Path $Path).Id
    }

    function New-EscrowGpo([string]$Name, [string]$Comment) {
        $G = New-GPO -Name $Name -Comment $Comment
        [pscustomobject]@{ Id = [guid]$G.Id; DisplayName = [string]$G.DisplayName; GpoStatus = [string]$G.GpoStatus }
    }

    function Set-EscrowValue([guid]$Id, [string]$Name, [long]$Value) { Set-GPRegistryValue -Guid $Id -Key $FveKey -ValueName $Name -Type DWord -Value ([int]$Value) | Out-Null }

    function New-EscrowLink([guid]$Id, [string]$Target) { New-GPLink -Guid $Id -Target $Target -LinkEnabled Yes | Out-Null }

    function Enable-EscrowLink([guid]$Id, [string]$Target) { Set-GPLink -Guid $Id -Target $Target -LinkEnabled Yes | Out-Null }
}

# --- Run ---

if (-not $LogDir) { $LogDir = Join-Path $env:SystemDrive 'Logs' }
$Log = Join-Path $LogDir ('Set-BitLockerAdBackupGpo-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $LogDir -ItemType Directory -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath "$Log.log" -WhatIf:$false | Out-Null
try {
    # 1. Preconditions - nothing is changed until the confirmation below
    if ($UnderTest) {
        foreach ($Name in 'Backup-ExistingGpo', 'New-EscrowGpo', 'Set-EscrowValue', 'New-EscrowLink', 'Enable-EscrowLink') {
            $Cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
            if (-not $Cmd -or $Cmd.CommandType -ne 'Function' -or $Cmd.Module) { throw "STOP: test harness detected, but $Name is not a mock function. Nothing was changed." }
        }
    }
    else {
        $Helper = Join-Path $PSScriptRoot 'Confirm-Change.ps1'
        if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) { throw "STOP: $Helper is missing. Copy Confirm-Change.ps1 next to this script. Nothing was changed." }
        . $Helper
    }
    if (-not (Test-IsAdmin)) { throw 'STOP: this session is not elevated. Run the script from an elevated PowerShell. Nothing was changed.' }

    if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot 'BitLockerAdBackupGpo.json' }
    $SettingsText = Get-SettingsText $SettingsPath
    if ($null -eq $SettingsText) { throw "STOP: settings file $SettingsPath not found. Nothing was changed." }
    $Settings = Read-Settings $SettingsText $SettingsPath
    Add-Result 'PASS' 'Settings' ("{0}: GPO '{1}', OU '{2}', drive types {3}, {4} recovery values each; encryption {5}" -f $SettingsPath, $Settings.GpoName, $Settings.OuName, ($Settings.Prefixes -join '/'), $Settings.Values.Count, (Get-MethodSummary $Settings))

    try { $ModuleInfo = Import-GpModules } catch { throw "STOP: the GroupPolicy and ActiveDirectory modules could not be loaded ($($_.Exception.Message)). Run this on a DC, or install RSAT Group Policy Management and AD DS tools. Nothing was changed." }
    Add-Result 'PASS' 'Modules' ([string]$ModuleInfo)
    if (-not (Test-DomainJoined)) { throw 'STOP: this computer is not joined to an Active Directory domain. Run this on a DC or a domain-joined management computer. Nothing was changed.' }
    try { $Domain = Get-DomainInfo } catch { throw "STOP: no domain controller answered for this computer's domain ($($_.Exception.Message)). Check DNS and DC connectivity. Nothing was changed." }
    Add-Result 'PASS' 'Active Directory' ('domain {0} ({1})' -f $Domain.DNSRoot, $Domain.DistinguishedName)

    # 2. Every value name and value must exist in the ADMX that GPMC uses
    $Admx = Get-AdmxSource $Domain.DNSRoot
    if (-not $Admx) { throw 'STOP: VolumeEncryption.admx was found neither in the central store nor in %SystemRoot%\PolicyDefinitions, so the value names cannot be checked. Nothing was changed.' }
    $Allowed = Get-AdmxAllowedValues $Admx.Text
    $Desired = Get-DesiredValues $Settings
    $Bad = New-Object System.Collections.Generic.List[string]
    foreach ($Name in $Desired.Keys) {
        if (-not $Allowed.ContainsKey($Name)) { $Bad.Add("$Name (not in the ADMX)") }
        elseif (@($Allowed[$Name]) -notcontains $Desired[$Name]) { $Bad.Add("$Name = $($Desired[$Name]) (allowed: $(@($Allowed[$Name]) -join ', '))") }
    }
    if ($Bad.Count) { throw "STOP: settings do not match $($Admx.Path): $($Bad -join '; '). Nothing was changed." }
    Add-Result 'PASS' 'Settings vs ADMX' ('{0} values checked against {1}' -f $Desired.Count, $Admx.Path)
    if ($Admx.CentralStore -eq 'MissingFile') {
        Add-Result 'WARN' 'Central store' ("\\{0}\SYSVOL\{0}\Policies\PolicyDefinitions has no VolumeEncryption.admx, so GPMC shows these values under Extra Registry Settings (clients still apply them). Copy %SystemRoot%\PolicyDefinitions\VolumeEncryption.admx and en-US\VolumeEncryption.adml there to see them as the normal BitLocker settings." -f $Domain.DNSRoot)
    }

    # 3. OU, GPO, link - read and plan
    $Ous = @(Find-OuByName $Settings.OuName $Domain.DistinguishedName)
    if ($Ous.Count -ne 1) { throw "STOP: expected 1 OU named '$($Settings.OuName)' in $($Domain.DistinguishedName), found $($Ous.Count). Create it, or change OuName in the settings. Nothing was changed." }
    $Target = $Ous[0]
    $Computers = @(Get-OuComputerNames $Target)
    if ($Computers.Count) { Add-Result 'PASS' 'Target OU' ('{0} ({1} computer(s): {2})' -f $Target, $Computers.Count, (($Computers | Select-Object -First 10) -join ', ')) }
    else { Add-Result 'WARN' 'Target OU' "$Target holds no computer objects, so the GPO applies to nothing yet" }

    $Gpos = @(Find-GpoByName $Settings.GpoName)
    if ($Gpos.Count -gt 1) { throw "STOP: $($Gpos.Count) GPOs are named '$($Settings.GpoName)' ($(($Gpos | ForEach-Object { $_.Id }) -join ', ')). Rename or remove the extras first. Nothing was changed." }
    $Gpo = $null
    if ($Gpos.Count -eq 1) { $Gpo = $Gpos[0] }
    if ($Gpo) {
        if ($Gpo.GpoStatus -eq 'ComputerSettingsDisabled' -or $Gpo.GpoStatus -eq 'AllSettingsDisabled') { throw "STOP: GPO '$($Gpo.DisplayName)' has its computer settings disabled ($($Gpo.GpoStatus)), so these computer policies would not apply. Enable them first. Nothing was changed." }
        $Current = Get-GpoFveValues $Gpo.Id
        $LinkState = Get-GpoLinkState $Target $Gpo.Id
        Add-Result 'PASS' 'GPO' ("'{0}' exists ({1}, {2}); {3} BitLocker value(s); link on the OU: {4}" -f $Gpo.DisplayName, $Gpo.Id, $Gpo.GpoStatus, $Current.Count, $LinkState)
        $Others = @($Current.Keys | Where-Object { -not $Desired.Contains($_) } | Sort-Object)
        if ($Others.Count) { Add-Result 'WARN' 'Other GPO values' "the GPO also holds $($Others -join ', '); left as they are" }
    }
    else {
        $Current = @{}
        $LinkState = 'None'
        Add-Result 'PASS' 'GPO' "'$($Settings.GpoName)' does not exist yet"
    }
    $Changes = @(Get-ValueChanges $Desired $Current)

    $ExcludeId = [guid]::Empty
    if ($Gpo) { $ExcludeId = $Gpo.Id }
    $Competitors = @(Get-FveCompetitors $Target $ExcludeId)
    if ($Competitors.Count) { Add-Result 'WARN' 'Other BitLocker GPOs' "also in effect at $Target, and the one with the better precedence wins per value: $($Competitors -join '; ')" }

    $NeedCreate = $null -eq $Gpo
    $NeedLink = $LinkState -eq 'None'
    $NeedEnable = $LinkState -eq 'Disabled'

    if (-not ($NeedCreate -or $Changes.Count -or $NeedLink -or $NeedEnable)) {
        Add-Result 'PASS' 'Plan' 'GPO, values and link already match the settings - nothing to change'
    }
    else {
        # 4. Confirm - one yellow Y/N for everything below
        if (-not $WhatIfPreference) {
            $Detail = New-Object System.Collections.Generic.List[string]
            $Detail.Add("Domain: $($Domain.DNSRoot) ($($Domain.DistinguishedName))")
            if ($NeedCreate) { $Detail.Add("GPO: create '$($Settings.GpoName)' - $($Settings.GpoComment)") }
            else { $Detail.Add("GPO: update '$($Gpo.DisplayName)' ($($Gpo.Id)); it is backed up first") }
            if ($Changes.Count) {
                $Detail.Add("Values under $FveKey ($($Changes.Count) of $($Desired.Count)):")
                foreach ($C in $Changes) { $Detail.Add(('  {0} : {1} -> {2}' -f $C.Name, $C.From, $C.To)) }
            }
            if ($NeedLink) { $Detail.Add("Link: new, enabled, on $Target") }
            if ($NeedEnable) { $Detail.Add("Link: enable the existing, disabled link on $Target") }
            $Detail.Add(('Applies to: {0} computer(s) in that OU{1}' -f $Computers.Count, $(if ($Computers.Count) { ': ' + (($Computers | Select-Object -First 10) -join ', ') } else { '' })))
            $Detail.Add('Effect: at their next Group Policy refresh, BitLocker on those computers writes recovery information to AD DS.')
            if ($Settings.Values['RequireActiveDirectoryBackup'] -eq 1) {
                $Detail.Add('        BitLocker will not turn on for ' + (($Settings.Prefixes | ForEach-Object { $PrefixText[$_] }) -join ', ') + ' drives until that write succeeds.')
            }
            $Detail.Add("        Drives encrypted from then on use: $(Get-MethodSummary $Settings). Drives that are already encrypted keep")
            $Detail.Add('        their method until they are decrypted and encrypted again.')
            if ($NeedCreate) { $Detail.Add("Undo: Remove-GPO -Name '$($Settings.GpoName)'   (also removes its links)") }
            else { $Detail.Add("Undo: Restore-GPO -Guid $($Gpo.Id) -Path <the backup folder listed in the results>") }
            Confirm-Change -NoConfirm:$NoConfirm -Action "create or update the BitLocker AD DS backup GPO in $($Domain.DNSRoot)" -Detail $Detail.ToArray()
            $ConfirmPreference = 'None'
        }

        # 5. Back up, apply
        if (-not $NeedCreate -and $Changes.Count) {
            if ($PSCmdlet.ShouldProcess("GPO $($Gpo.Id)", 'Back up before changing it')) {
                $BackupId = Backup-ExistingGpo $Gpo.Id "$Log-gpo-backup"
                Add-Result 'PASS' 'Backup' "$Log-gpo-backup (backup ID $BackupId)"
            }
        }
        if ($NeedCreate) {
            if ($PSCmdlet.ShouldProcess($Settings.GpoName, 'Create GPO')) {
                $Gpo = New-EscrowGpo $Settings.GpoName $Settings.GpoComment
                Add-Result 'PASS' 'GPO created' ('{0} ({1})' -f $Gpo.DisplayName, $Gpo.Id)
            }
            else { Add-Result 'PASS' 'GPO' "-WhatIf: would create '$($Settings.GpoName)'" }
        }
        if ($Changes.Count) {
            if ($Gpo -and $PSCmdlet.ShouldProcess("GPO '$($Settings.GpoName)'", "Set $($Changes.Count) value(s) under $FveKey")) {
                foreach ($C in $Changes) { Set-EscrowValue $Gpo.Id $C.Name $C.To }
                Add-Result 'PASS' 'Values set' "$($Changes.Count) value(s)"
            }
            else { Add-Result 'PASS' 'Values' "-WhatIf: would set $($Changes.Count) value(s)" }
        }
        if ($NeedLink -or $NeedEnable) {
            if ($Gpo -and $PSCmdlet.ShouldProcess($Target, "Link GPO '$($Settings.GpoName)'")) {
                if ($NeedLink) { New-EscrowLink $Gpo.Id $Target } else { Enable-EscrowLink $Gpo.Id $Target }
                Add-Result 'PASS' 'Link' "enabled on $Target"
            }
            else { Add-Result 'PASS' 'Link' "-WhatIf: would link to $Target" }
        }
    }

    # 6. Verify from AD and SYSVOL (also when nothing had to change)
    if ($Gpo -and -not $WhatIfPreference) {
        $After = Get-GpoFveValues $Gpo.Id
        $Wrong = @(Get-ValueChanges $Desired $After)
        if ($Wrong.Count) { Add-Result 'FAIL' 'Verify values' (($Wrong | ForEach-Object { '{0} is {1}, expected {2}' -f $_.Name, $_.From, $_.To }) -join '; ') }
        else { Add-Result 'PASS' 'Verify values' ('all {0} values match (DWORD) in GPO {1}' -f $Desired.Count, $Gpo.Id) }
        $LinkAfter = Get-GpoLinkState $Target $Gpo.Id
        if ($LinkAfter -eq 'Enabled') { Add-Result 'PASS' 'Verify link' "enabled on $Target" }
        else { Add-Result 'FAIL' 'Verify link' "the link on $Target is '$LinkAfter', expected 'Enabled'" }
        $Ev = Get-GpoEvidence $Gpo.Id $Domain.DNSRoot
        if ($Ev.Sha256) { Add-Result 'PASS' 'Registry.pol SHA-256' ('{0} ({1})' -f $Ev.Sha256, $Ev.RegistryPol) }
        else { Add-Result 'FAIL' 'Registry.pol' "not found at $($Ev.RegistryPol)" }
        if ($Ev.DSVersion -eq $Ev.SysvolVersion) { Add-Result 'PASS' 'GPO version' ('computer version {0} in AD and SYSVOL; status {1}' -f $Ev.DSVersion, $Ev.GpoStatus) }
        else { Add-Result 'WARN' 'GPO version' ('AD has computer version {0}, SYSVOL {1}: replication may still be running' -f $Ev.DSVersion, $Ev.SysvolVersion) }
    }
}
catch { Add-Result 'FAIL' 'Stopped' $_.Exception.Message }
finally {
    $FailCount = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $WarnCount = @($Results | Where-Object { $_.Status -eq 'WARN' }).Count
    if ($FailCount) { $Summary = 'FAILED'; $Color = 'Red' }
    elseif ($WarnCount) { $Summary = "PASSED with $WarnCount warning(s)"; $Color = 'Yellow' }
    else { $Summary = 'PASSED'; $Color = 'Green' }
    $Results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Write-Host $Summary -ForegroundColor $Color
    $Results | Export-Csv -LiteralPath "$Log.csv" -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "Transcript: $Log.log   Results: $Log.csv"
    $StopArgs = @{}
    if ((Get-Command -Name Stop-Transcript).Parameters.ContainsKey('WhatIf')) { $StopArgs['WhatIf'] = $false }
    try { Stop-Transcript @StopArgs | Out-Null } catch { }
}
# Always set the exit code, so a caller never reads one left over from an earlier command
if ($FailCount) { exit 1 }
exit 0
