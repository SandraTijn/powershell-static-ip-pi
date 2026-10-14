
$ErrorActionPreference = "Stop"

function Read-RequiredInput {
    param(
        [string]$Message,
        [string]$Default = ""
    )

    while ($true) {
        if ($Default -ne "") {
            $value = Read-Host "$Message [$Default]"
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = $Default
            }
        }
        else {
            $value = Read-Host $Message
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        Write-Host "Deze waarde is verplicht." -ForegroundColor Yellow
    }
}

function Test-IPv4 {
    param([string]$Address)

    $parsed = $null
    return (
        [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -and
        $parsed.AddressFamily -eq
            [System.Net.Sockets.AddressFamily]::InterNetwork
    )
}

function Read-IPv4 {
    param([string]$Message)

    while ($true) {
        $value = Read-RequiredInput $Message

        if (Test-IPv4 $value) {
            return $value
        }

        Write-Host "Ongeldig IPv4-adres. Probeer opnieuw." `
            -ForegroundColor Yellow
    }
}

Write-Host " Raspberry Pi - netplan generator" 


# 1. Bootpartitie zoeken
Write-Host "Zoeken naar een partitie met label 'bootfs'..."

$bootVolume = Get-Volume -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FileSystemLabel -eq "bootfs" -and
        $_.DriveLetter
    } |
    Select-Object -First 1

if ($bootVolume) {
    $detectedDrive = "$($bootVolume.DriveLetter):"
    Write-Host "Gevonden: $detectedDrive (bootfs)" `
}
else {
    $detectedDrive = ""
    Write-Host "Geen gemounte bootfs-partitie gevonden." `
}

# 2. Driveletter vragen of gevonden drive bevestigen
if ($detectedDrive) {
    $driveChoice = Read-Host `
        "Gebruik $detectedDrive? Druk Enter voor ja of typ een andere driveletter"

    if ([string]::IsNullOrWhiteSpace($driveChoice)) {
        $drive = $detectedDrive
    }
    else {
        $drive = $driveChoice.Trim()
    }
}
else {
    $drive = Read-RequiredInput `
        "Geef de driveletter van de bootpartitie (bv. E:  ':' moet aanwezig zijn)"
}

$drive = $drive.TrimEnd('\')

if ($drive -notmatch '^[A-Za-z]:$') {
    throw "Ongeldige driveletter. Gebruik bijvoorbeeld E:. ':' moet aanwezig zijn"
}

$root = "$drive\"

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "De drive $drive bestaat niet of is niet toegankelijk."
}

# 3. Controle bootpartitie
$volume = Get-Volume -DriveLetter $drive.Substring(0, 1) `
    -ErrorAction SilentlyContinue

if ($volume -and $volume.FileSystemLabel -ne "bootfs") {
    Write-Host "Waarschuwing: het label is '$($volume.FileSystemLabel)', niet 'bootfs'." `

    $continue = Read-Host "Toch doorgaan? (y/n)"
    if ($continue -notmatch '^(y|yes|Y)$') {
        Write-Host "Geannuleerd."
        exit
    }
}

# 4. Welke mount locatie
Write-Host ""
Write-Host "Welke mountlocatie gebruikt Raspberry Pi OS?"
Write-Host "1. /boot/firmware (moderne installaties)"
Write-Host "2. /boot (oudere installaties)"

do {
    $bootLayout = Read-Host "Kies 1 of 2"
} until ($bootLayout -in @("1", "2"))

if ($bootLayout -eq "1") {
    Write-Host "Gekozen: /boot/firmware"
}
else {
    Write-Host "Gekozen: /boot"
}

$outputFile = Join-Path $root "network-config"

# 5. Netwerkgegevens
Write-Host ""
Write-Host "--- Netwerkinstellingen ---"

$interface = Read-RequiredInput `
    "Netwerkinterface (meestal eth0)" "eth0"

if ($interface -notmatch '^[a-zA-Z0-9_.:-]+$') {
    throw "Ongeldige netwerkinterfacenaam."
}

$ipAddress = Read-IPv4 "Statisch IPv4-adres (bv. 192.168.1.50)"

do {
    $prefixText = Read-RequiredInput `
        "Subnetprefix (bv. 24 voor 255.255.255.0)"
    $prefix = 0

    $validPrefix = [int]::TryParse($prefixText, [ref]$prefix) `
        -and $prefix -ge 1 -and $prefix -le 32

    if (-not $validPrefix) {
        Write-Host "Geef een geheel getal van 1 tot 32." `
    }
} until ($validPrefix)

$gateway = Read-IPv4 "Default gateway (bv. 192.168.1.1)"

do {
    $dnsInput = Read-RequiredInput `
        "DNS-server(s), gescheiden door komma's (bv. 1.1.1.1,8.8.8.8)"

    $dnsServers = @(
        $dnsInput -split ',' |
        ForEach-Object { $_.Trim() }
    )

    $validDns = $dnsServers.Count -gt 0

    foreach ($dns in $dnsServers) {
        if (-not (Test-IPv4 $dns)) {
            $validDns = $false
        }
    }

    if (-not $validDns) {
        Write-Host "Een of meer DNS-adressen zijn ongeldig." `
    }
} until ($validDns)

# 6. YAML genereren
$dnsYaml = ($dnsServers | ForEach-Object {
    "        - $_"
}) -join "`n"

$yaml = @"
version: 2
ethernets:
  $($interface):
    dhcp4: false
    addresses:
      - $($ipAddress)/$($prefix)
    routes:
      - to: default
        via: $($gateway)
    nameservers:
      addresses:
$dnsYaml
"@

# File naar valid Linux
$yaml = $yaml -replace "`r`n", "`n"
$yaml = $yaml -replace "`r", "`n"
$yaml = $yaml.TrimEnd("`n") + "`n"

Write-Host ""
Write-Host "--- Gegenereerde configuratie ---"
Write-Host $yaml

# 7. Bestaand bestand controleren
if (Test-Path -LiteralPath $outputFile) {
    Write-Host "Er bestaat al een network-config-bestand." `
        -ForegroundColor Yellow

    $overwrite = Read-Host `
        "Bestaand bestand volledig vervangen? (j/n)"

    if ($overwrite -notmatch '^(j|ja)$') {
        Write-Host "Geannuleerd. Het bestaande bestand is behouden."
        exit
    }
}

# 8. Atomair schrijven: UTF-8 zonder BOM, met Linux-LF
$tempFile = Join-Path $root "network-config.tmp"

try {
    $encoding = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $tempFile,
        $yaml,
        $encoding
    )

    # Vervang het doelbestand pas nadat het tijdelijke bestand
    # succesvol geschreven is.
    Move-Item -LiteralPath $tempFile `
        -Destination $outputFile -Force

    Write-Host ""
    Write-Host "Configuratie succesvol opgeslagen!" `
        -ForegroundColor Green
    Write-Host "Bestand: $outputFile"
    Write-Host "Encoding: UTF-8 zonder BOM"
    Write-Host "Regeleinden: LF (Linux)"
    Write-Host ""
    Write-Host "Plaats de SD-kaart in de Raspberry Pi en start op."
}
catch {
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force `
            -ErrorAction SilentlyContinue
    }

    throw "Het bestand kon niet veilig worden geschreven: $($_.Exception.Message)"
}
