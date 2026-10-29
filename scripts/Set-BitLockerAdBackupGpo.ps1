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
    # JSON settings (GpoName, GpoComment, OuName, Prefixes, Values, EncryptionMethods, OtherValues).
    # Empty = BitLockerAdBackupGpo.json next to this script.
    [ValidatePattern('^$|^[^"*?<>|]+\.json$')][string]$SettingsPath = '',
    # Folder for the transcript, results CSV and GPO backups. Empty = %SystemDrive%\Logs.
    [ValidatePattern('^$|^[A-Za-z]:\\[^"*?<>|]+$')][string]$LogDir = '',
    [switch]$NoConfirm
)
$ErrorActionPreference = 'Stop'

$FveKey        = 'HKLM\SOFTWARE\Policies\Microsoft\FVE'
$FveSystemKey  = 'HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE'   # where the 'Deny write access ...' policies live
# ADMX key -> the Group Policy key this script writes. Hashtable lookups ignore case; the ADMX spells 'SOFTWARE' and 'Software'.
$AdmxKeys      = @{ 'SOFTWARE\Policies\Microsoft\FVE' = $FveKey; 'SYSTEM\CurrentControlSet\Policies\Microsoft\FVE' = $FveSystemKey }
$KnownPrefixes = @('OS', 'FDV', 'RDV')
$KnownValues   = @('Recovery', 'ManageDRA', 'RecoveryPassword', 'RecoveryKey', 'HideRecoveryPage', 'ActiveDirectoryBackup', 'ActiveDirectoryInfoToStore', 'RequireActiveDirectoryBackup')
$NamePattern   = '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,79}$'   # GPO and OU names: no quotes, so they are safe inside AD filters
$PrefixText    = @{ OS = 'operating system'; FDV = 'fixed data'; RDV = 'removable data' }
# Policy 'Choose drive encryption method and cipher strength (Windows 10 [Version 1511] and later)'
$MethodValueNames = @{ OS = 'EncryptionMethodWithXtsOs'; FDV = 'EncryptionMethodWithXtsFdv'; RDV = 'EncryptionMethodWithXtsRdv' }
$MethodText       = @{ 3 = 'AES-CBC 128'; 4 = 'AES-CBC 256'; 6 = 'XTS-AES 128'; 7 = 'XTS-AES 256' }
$SettingsFields   = @('GpoName', 'GpoComment', 'OuName', 'Prefixes', 'Values', 'EncryptionMethods', 'OtherValues')
$OtherNamePattern = '^[A-Za-z][A-Za-z0-9]{2,63}$'   # registry value names in OtherValues

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Status, [string]$Check, [string]$Detail) { $Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail }) }

# --- Decision logic (no system access) ---

# Parse and validate the settings JSON. Returns GpoName, GpoComment, OuName, Prefixes (string[]), Values (ordered name -> int),
# EncryptionMethods (ordered prefix -> int) and OtherValues (ordered registry value name -> int; checked against the ADMX later).
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

    if ($Raw.OtherValues -isnot [System.Management.Automation.PSCustomObject]) { throw "STOP: OtherValues in $Source must be a JSON object of registry value name: number or text pairs (it may be empty: {}). Nothing was changed." }
    $Other = [ordered]@{}
    foreach ($Pr in $Raw.OtherValues.PSObject.Properties) {
        if ($Pr.Name -notmatch $OtherNamePattern) { throw "STOP: '$($Pr.Name)' in OtherValues of $Source is not a registry value name (3-64 letters and digits). Nothing was changed." }
        $V = $Pr.Value
        if ($V -is [string]) {
            # Printable ASCII only: the pre-boot recovery screen shows a limited character set, and nothing else is needed
            if ($V.Length -eq 0 -or $V.Length -gt 1024 -or $V -cnotmatch '^[\x20-\x7E]+$') { throw "STOP: OtherValues.$($Pr.Name) in $Source must be 1-1024 printable ASCII characters. Nothing was changed." }
            $Other[$Pr.Name] = $V
        }
        elseif (($V -is [int] -or $V -is [long]) -and $V -ge 0 -and $V -le 4294967295) { $Other[$Pr.Name] = [long]$V }
        else { throw "STOP: OtherValues.$($Pr.Name) in $Source must be a whole number or text, not '$V'. Nothing was changed." }
    }

    [pscustomobject]@{ GpoName = $Raw.GpoName; GpoComment = $Raw.GpoComment; OuName = $Raw.OuName; Prefixes = $Prefixes.ToArray(); Values = $Values; EncryptionMethods = $Methods; OtherValues = $Other }
}

# 'OS XTS-AES 256, FDV XTS-AES 256' for messages
function Get-MethodSummary($Settings) {
    ($Settings.Prefixes | ForEach-Object { $T = $MethodText[[int]$Settings.EncryptionMethods[$_]]; if (-not $T) { $T = "value $($Settings.EncryptionMethods[$_])" }; "$_ $T" }) -join ', '
}

# Registry value name -> Key (the Group Policy key it belongs under), Type (DWord, String or ExpandString), Values (allowed
# numbers, for DWord) and MaxLength (for text), for every machine policy in VolumeEncryption.admx that writes one of the two
# BitLocker policy keys.
function Get-AdmxAllowedValues([string]$XmlText) {
    $Doc = New-Object System.Xml.XmlDocument
    $Doc.XmlResolver = $null   # never resolve external entities from the file
    try { $Doc.LoadXml($XmlText) } catch { throw "STOP: VolumeEncryption.admx is not valid XML ($($_.Exception.Message)). Nothing was changed." }
    $Ns = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
    $Ns.AddNamespace('p', $Doc.DocumentElement.NamespaceURI)
    $Allowed = @{}
    foreach ($Policy in $Doc.SelectNodes('//p:policy', $Ns)) {
        if (@('Machine', 'Both') -notcontains $Policy.GetAttribute('class')) { continue }
        $PolicyKey = $AdmxKeys[$Policy.GetAttribute('key')]
        if (-not $PolicyKey) { continue }
        $PolicyValue = $Policy.GetAttribute('valueName')
        if ($PolicyValue) {
            $On = $Policy.SelectSingleNode('p:enabledValue/p:decimal', $Ns); $Off = $Policy.SelectSingleNode('p:disabledValue/p:decimal', $Ns)
            $Allowed[$PolicyValue] = [pscustomobject]@{ Key = $PolicyKey; Type = 'DWord'; MaxLength = 0; Values = @($(if ($On) { [long]$On.GetAttribute('value') } else { 1 }), $(if ($Off) { [long]$Off.GetAttribute('value') } else { 0 })) }
        }
        foreach ($El in $Policy.SelectNodes('p:elements/*', $Ns)) {
            $Name = $El.GetAttribute('valueName')
            if (-not $Name) { continue }
            $ElKey = $PolicyKey
            if ($El.GetAttribute('key')) { $ElKey = $AdmxKeys[$El.GetAttribute('key')]; if (-not $ElKey) { continue } }
            if ($El.LocalName -eq 'boolean') {
                $T = $El.SelectSingleNode('p:trueValue/p:decimal', $Ns); $F = $El.SelectSingleNode('p:falseValue/p:decimal', $Ns)
                $Allowed[$Name] = [pscustomobject]@{ Key = $ElKey; Type = 'DWord'; MaxLength = 0; Values = @($(if ($T) { [long]$T.GetAttribute('value') } else { 1 }), $(if ($F) { [long]$F.GetAttribute('value') } else { 0 })) }
            }
            elseif ($El.LocalName -eq 'enum') {
                $Allowed[$Name] = [pscustomobject]@{ Key = $ElKey; Type = 'DWord'; MaxLength = 0; Values = @($El.SelectNodes('p:item/p:value/p:decimal', $Ns) | ForEach-Object { [long]$_.GetAttribute('value') }) }
            }
            elseif ($El.LocalName -eq 'text') {
                $Max = 1023
                if ($El.GetAttribute('maxLength')) { $Max = [int]$El.GetAttribute('maxLength') }
                $Type = 'String'
                if ($El.GetAttribute('expandable') -eq 'true') { $Type = 'ExpandString' }
                $Allowed[$Name] = [pscustomobject]@{ Key = $ElKey; Type = $Type; MaxLength = $Max; Values = @() }
            }
        }
    }
    return $Allowed
}

# Registry value name -> value: the recovery values for every prefix, each prefix's encryption method, then OtherValues
function Get-DesiredValues($Settings) {
    $Desired = [ordered]@{}
    foreach ($P in $Settings.Prefixes) { foreach ($Name in $Settings.Values.Keys) { $Desired["$P$Name"] = $Settings.Values[$Name] } }
    foreach ($P in $Settings.Prefixes) { $Desired[$MethodValueNames[$P]] = $Settings.EncryptionMethods[$P] }
    foreach ($Name in $Settings.OtherValues.Keys) {
        if ($Desired.Contains($Name)) { throw "STOP: OtherValues.$Name is already set through Values or EncryptionMethods. Set it in one place only. Nothing was changed." }
        $Desired[$Name] = $Settings.OtherValues[$Name]
    }
    return $Desired
}

# Desired values that the GPO does not hold yet (missing, under another key, another type, or a different value).
# Keys and Types map each name to the registry key and type the ADMX gives it.
# List helpers return plain pipeline output and callers wrap them in @(): '@(f)' around 'return , @(...)' nests the array.
function Get-ValueChanges($Desired, $Current, $Keys, $Types) {
    $Changes = New-Object System.Collections.Generic.List[object]
    foreach ($Name in $Desired.Keys) {
        $Have = $Current[$Name]
        $Type = $Types[$Name]
        if ($null -eq $Have -or $Have.Key -ne $Keys[$Name]) { $From = '(not set)' }
        elseif ($Have.Type -ne $Type) { $From = "$($Have.Value) ($($Have.Type))" }
        elseif ($Type -eq 'DWord' -and [long]$Have.Value -ne $Desired[$Name]) { $From = [string]$Have.Value }
        elseif ($Type -ne 'DWord' -and [string]$Have.Value -cne $Desired[$Name]) { $From = "'$($Have.Value)'" }
        else { continue }
        $Changes.Add([pscustomobject]@{ Name = $Name; Key = $Keys[$Name]; Type = $Type; From = $From; To = $Desired[$Name] })
    }
    $Changes.ToArray()
}

# How a change is shown in the plan: numbers as they are, text in quotes
function Format-PolicyValue($Value) { if ($Value -is [string]) { "'$Value'" } else { [string]$Value } }

# Set-GPRegistryValue rewrites Registry.pol in SYSVOL on every call. Right after a write, SYSVOL replication or a scanner can
# hold the file for a moment, and the next call fails with E_ACCESSDENIED (seen on DC25-1 after 10 of 12 writes) or a sharing
# violation. Those two errors are retried with a short wait; any other error stops the run at once.
function Invoke-GpWrite([scriptblock]$Action, [int]$Tries = 5) {
    for ($Try = 1; ; $Try++) {
        try { & $Action; return }
        catch {
            $HResult = $_.Exception.HResult
            $Transient = $HResult -eq -2147024891 -or $HResult -eq -2147024864 -or $_.Exception.Message -match '0x80070005|0x80070020'
            if (-not $Transient -or $Try -ge $Tries) { throw }
            Start-Sleep -Seconds (2 * $Try)
        }
    }
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

    # Name -> Key/Type/Value of every value the GPO holds under the two BitLocker keys; a key that does not exist yet adds nothing
    function Get-GpoFveValues([guid]$Id) {
        $Map = @{}
        foreach ($Key in $FveKey, $FveSystemKey) {
            try { $Items = @(Get-GPRegistryValue -Guid $Id -Key $Key -ErrorAction Stop) }
            catch { if ($_.FullyQualifiedErrorId -like 'UnableToRetrievePolicyRegistryItem*') { continue } else { throw } }
            foreach ($Item in $Items) { if ($Item.ValueName) { $Map[[string]$Item.ValueName] = [pscustomobject]@{ Key = $Key; Type = [string]$Item.Type; Value = $Item.Value } } }
        }
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
            $Count = @(Get-GPRegistryValue -Guid $Link.GpoId -Key $FveKey -ErrorAction SilentlyContinue).Count + @(Get-GPRegistryValue -Guid $Link.GpoId -Key $FveSystemKey -ErrorAction SilentlyContinue).Count
            if ($Count) { $Found.Add(('{0} (precedence {1}, linked at {2})' -f $Link.DisplayName, $Link.Order, $Link.Target)) }
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

    function Set-EscrowValue([guid]$Id, [string]$Key, [string]$Name, $Value, [string]$Type) {
        if ($Type -eq 'DWord') { $Data = [int]$Value } else { $Data = [string]$Value }
        Set-GPRegistryValue -Guid $Id -Key $Key -ValueName $Name -Type $Type -Value $Data | Out-Null
    }

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
    $DesiredKeys = @{}
    $DesiredTypes = @{}
    foreach ($Name in $Desired.Keys) {
        $A = $Allowed[$Name]
        $Want = $Desired[$Name]
        if (-not $A) { $Bad.Add("$Name (not in the ADMX)"); continue }
        if ($A.Type -eq 'DWord') {
            if ($Want -is [string]) { $Bad.Add("$Name must be a number, not text"); continue }
            if (@($A.Values) -notcontains $Want) { $Bad.Add("$Name = $Want (allowed: $(@($A.Values) -join ', '))"); continue }
        }
        else {
            if ($Want -isnot [string]) { $Bad.Add("$Name must be text, not a number"); continue }
            if ($Want.Length -gt $A.MaxLength) { $Bad.Add("$Name is $($Want.Length) characters long (at most $($A.MaxLength))"); continue }
        }
        $DesiredKeys[$Name] = $A.Key
        $DesiredTypes[$Name] = $A.Type
    }
    if ($Bad.Count) { throw "STOP: settings do not match $($Admx.Path): $($Bad -join '; '). Nothing was changed." }
    $InSystem = @($Desired.Keys | Where-Object { $DesiredKeys[$_] -eq $FveSystemKey }).Count
    Add-Result 'PASS' 'Settings vs ADMX' ('{0} values checked against {1}: {2} under {3}, {4} under {5}' -f $Desired.Count, $Admx.Path, ($Desired.Count - $InSystem), $FveKey, $InSystem, $FveSystemKey)
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
    $Changes = @(Get-ValueChanges $Desired $Current $DesiredKeys $DesiredTypes)

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
                $Detail.Add("Policy values to set ($($Changes.Count) of $($Desired.Count)):")
                foreach ($K in $FveKey, $FveSystemKey) {
                    $InKey = @($Changes | Where-Object { $_.Key -eq $K })
                    if ($InKey.Count) {
                        $Detail.Add("  under $K")
                        foreach ($C in $InKey) { $Detail.Add(('    {0} : {1} -> {2}' -f $C.Name, $C.From, (Format-PolicyValue $C.To))) }
                    }
                }
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
            $Full = @('OS', 'FDV', 'RDV' | Where-Object { $Desired["$($_)EncryptionType"] -eq 1 })
            if ($Full.Count) { $Detail.Add("        Whole-drive encryption is required (used-space-only is refused) for: $($Full -join ', ').") }
            if ($Desired['FDVDenyWriteAccess'] -eq 1) { $Detail.Add('        Fixed data drives without BitLocker become read-only.') }
            if ($Desired['RDVDenyWriteAccess'] -eq 1) { $Detail.Add('        Removable drives without BitLocker become read-only.') }
            if ($Desired['RecoveryKeyMessageSource'] -eq 2 -and $Desired['RecoveryKeyMessage']) { $Detail.Add("        The recovery screen shows: '$($Desired['RecoveryKeyMessage'])'") }
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
            if ($Gpo -and $PSCmdlet.ShouldProcess("GPO '$($Settings.GpoName)'", "Set $($Changes.Count) BitLocker policy value(s)")) {
                foreach ($C in $Changes) { Invoke-GpWrite { Set-EscrowValue $Gpo.Id $C.Key $C.Name $C.To $C.Type } }
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
        $Wrong = @(Get-ValueChanges $Desired $After $DesiredKeys $DesiredTypes)
        if ($Wrong.Count) { Add-Result 'FAIL' 'Verify values' (($Wrong | ForEach-Object { '{0} is {1}, expected {2}' -f $_.Name, $_.From, (Format-PolicyValue $_.To) }) -join '; ') }
        else { Add-Result 'PASS' 'Verify values' ('all {0} values match (key, type and value) in GPO {1}' -f $Desired.Count, $Gpo.Id) }
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
