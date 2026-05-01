# setup-services.ps1 - Post-install service configuration for Windows target VM
# Runs via FirstLogonCommands in autounattend.xml
# Requires: Administrator privileges

$ErrorActionPreference = "Stop"
$LogFile = "C:\setup-services.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "=== Starting post-install service setup ==="

# ── 1. Enable RDP ──────────────────────────────────────────────────────
Write-Log "Enabling RDP..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
                 -Name "fDenyTSConnections" -Value 0
# Allow RDP through firewall
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Write-Log "RDP enabled."

# ── 2. Enable WinRM ───────────────────────────────────────────────────
Write-Log "Enabling WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Client\TrustedHosts "*" -Force
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
# Allow WinRM through firewall (Enable-PSRemoting should do this, but be explicit)
Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP-Public" -ErrorAction SilentlyContinue
Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -ErrorAction SilentlyContinue
Write-Log "WinRM enabled."

# ── 3. Install SNMP Service ───────────────────────────────────────────
Write-Log "Installing SNMP Service..."
$snmpCap = Get-WindowsCapability -Online -Name "SNMP.Server*" -ErrorAction SilentlyContinue
if ($snmpCap -and $snmpCap.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $snmpCap.Name
    Write-Log "SNMP Server capability installed."
} else {
    # Fallback: try installing via optional feature (older Server builds)
    $snmpFeature = Get-WindowsOptionalFeature -Online -FeatureName "SNMP" -ErrorAction SilentlyContinue
    if ($snmpFeature -and $snmpFeature.State -ne "Enabled") {
        Enable-WindowsOptionalFeature -Online -FeatureName "SNMP" -NoRestart
        Write-Log "SNMP optional feature enabled."
    } else {
        Write-Log "SNMP already installed or not available via capability/feature."
    }
}

# ── 4. Configure SNMP ─────────────────────────────────────────────────
Write-Log "Configuring SNMP settings..."
$snmpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters"

# Ensure SNMP service registry keys exist
if (Test-Path $snmpReg) {
    # Read-only community: public (accessible from any host)
    $rocPath = "$snmpReg\ValidCommunities"
    if (-not (Test-Path $rocPath)) { New-Item -Path $rocPath -Force | Out-Null }
    Set-ItemProperty -Path $rocPath -Name "public" -Value 4 -Type DWord
    # 4 = READ-ONLY

    # Read-write community: private (restricted to 10.10.10.0/24)
    Set-ItemProperty -Path $rocPath -Name "private" -Value 8 -Type DWord
    # 8 = READ-WRITE

    # Permitted managers for read-write community
    $pmPath = "$snmpReg\PermittedManagers"
    if (-not (Test-Path $pmPath)) { New-Item -Path $pmPath -Force | Out-Null }
    # Allow from lab subnet
    Set-ItemProperty -Path $pmPath -Name "1" -Value "10.10.10.0" -Type String
    # Also allow localhost
    $existing = Get-ItemProperty -Path $pmPath
    if (-not $existing."2") {
        New-ItemProperty -Path $pmPath -Name "2" -Value "127.0.0.1" -PropertyType String -Force | Out-Null
    }

    # RFC1213-MIB: sysLocation and sysContact
    Set-ItemProperty -Path "$snmpReg\RFC1156Agent" -Name "sysLocation" -Value "Test Lab Rack 3" -Type String -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "$snmpReg\RFC1156Agent" -Name "sysContact"   -Value "admin@test.local" -Type String -ErrorAction SilentlyContinue

    # Restart SNMP to pick up changes
    Restart-Service -Name "SNMP" -Force -ErrorAction SilentlyContinue
    Write-Log "SNMP configured: public (RO), private (RW from 10.10.10.0/24)."
} else {
    Write-Log "WARN: SNMP registry path not found; skipping SNMP configuration."
}

# ── 5. Create SMB share with test files ────────────────────────────────
Write-Log "Creating SMB share..."
$shareDir = "C:\Shares\Public"
if (-not (Test-Path $shareDir)) {
    New-Item -Path $shareDir -ItemType Directory -Force | Out-Null
}

# Create test files
"NetUtility Test Lab - Windows Target" | Out-File -FilePath "$shareDir\readme.txt" -Encoding ASCII
"This is a test document for SMB scanning." | Out-File -FilePath "$shareDir\test-document.txt" -Encoding ASCII
"username,password,role`nadmin,admin123,administrator`nuser,user123,standard" | Out-File -FilePath "$shareDir\credentials.csv" -Encoding ASCII
Get-Date | Out-File -FilePath "$shareDir\install-date.txt" -Encoding ASCII

# Remove existing share if it exists (ignore errors)
Remove-SmbShare -Name "Public" -Force -ErrorAction SilentlyContinue
# Create the share (read/write for Everyone)
New-SmbShare -Name "Public" -Path $shareDir -ChangeAccess "Everyone" -Description "Public lab share"
Write-Log "SMB share created: $shareDir (read/write for Everyone)."

# ── 6. Configure firewall rules ───────────────────────────────────────
Write-Log "Configuring firewall rules..."

# RDP (3389/tcp) - already enabled above via Enable-NetFirewallRule
# WinRM (5985/tcp) - already enabled above

# SNMP (161/udp)
$snmpRule = Get-NetFirewallRule -DisplayName "SNMP UDP 161" -ErrorAction SilentlyContinue
if (-not $snmpRule) {
    New-NetFirewallRule -DisplayName "SNMP UDP 161" `
                        -Direction Inbound `
                        -Protocol UDP `
                        -LocalPort 161 `
                        -Action Allow `
                        -Profile Any
    Write-Log "Firewall rule added: SNMP UDP 161."
}

# SMB (445/tcp) - should be enabled by default with the share, but ensure it
$smbRule = Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue |
           Where-Object { $_.Enabled -eq $false }
if ($smbRule) {
    Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"
    Write-Log "Enabled File and Printer Sharing firewall rules."
}

# WinRM explicit (5985/tcp)
$winrmRule = Get-NetFirewallRule -DisplayName "WinRM HTTP 5985" -ErrorAction SilentlyContinue
if (-not $winrmRule) {
    New-NetFirewallRule -DisplayName "WinRM HTTP 5985" `
                        -Direction Inbound `
                        -Protocol TCP `
                        -LocalPort 5985 `
                        -Action Allow `
                        -Profile Any
    Write-Log "Firewall rule added: WinRM HTTP 5985."
}

# Allow ICMP (ping) for network discovery
$icmpRule = Get-NetFirewallRule -DisplayName "ICMPv4 Allow" -ErrorAction SilentlyContinue
if (-not $icmpRule) {
    New-NetFirewallRule -DisplayName "ICMPv4 Allow" `
                        -Direction Inbound `
                        -Protocol ICMPv4 `
                        -Action Allow `
                        -Profile Any
    Write-Log "Firewall rule added: ICMPv4 (ping)."
}

Write-Log "Firewall rules configured."

# ── 7. Install IIS ────────────────────────────────────────────────────
Write-Log "Installing IIS..."
$iisResult = Install-WindowsFeature -Name Web-Server -IncludeManagementTools
if ($iisResult.Success) {
    Write-Log "IIS installed successfully."

    # Replace default page with custom content
    $defaultPage = "C:\inetpub\wwwroot\iisstart.htm"
    $customHtml = @"
<!DOCTYPE html>
<html>
<head><title>NetUtility Test Lab - Windows Target</title></head>
<body>
<h1>Windows Server Test Target</h1>
<p>This is a test web server for the NetUtility security assessment lab.</p>
<ul>
<li>OS: Windows Server 2022 Standard (Desktop Experience)</li>
<li>Role: Vulnerable target for scanning exercises</li>
<li>Services: IIS, SMB, SNMP, RDP, WinRM</li>
</ul>
<hr/>
<p><small>NetUtility Test Lab - $(Get-Date -Format 'yyyy-MM-dd')</small></p>
</body>
</html>
"@
    Set-Content -Path $defaultPage -Value $customHtml -Encoding UTF8
    Write-Log "Custom IIS default page set."
} else {
    Write-Log "WARN: IIS installation failed or was skipped."
}

# ── 8. Set static IP on VLAN interface ─────────────────────────────────
Write-Log "Configuring static IP on VLAN interface..."
# Identify the trunk NIC by MAC address (set in vm-windows.tf)
# Management: 52:54:00:16:63:56 (netutil-lab-mgmt, DHCP)
# Trunk:     52:54:00:0e:01:01 (netutil-lab-ovs, static VLAN IP)
$trunkMac = "52:54:00:0e:01:01"
$trunkAdapter = Get-NetAdapter | Where-Object { $_.MacAddress -replace '-',':' -eq $trunkMac }

if (-not $trunkAdapter) {
    Write-Log "WARN: Trunk adapter (MAC $trunkMac) not found. Attempting fallback by adapter without DHCP..."
    # Fallback: pick the adapter that doesn't have a 192.168.100.x DHCP address
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object InterfaceIndex
    foreach ($a in $adapters) {
        $dhcp = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dhcp -and $dhcp.IPAddress -like '192.168.100.*') { continue }
        $trunkAdapter = $a
        break
    }
}

if ($trunkAdapter) {
    $existingIp = (Get-NetIPAddress -InterfaceIndex $trunkAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($existingIp -eq '10.10.10.30') {
        Write-Log "Trunk adapter '$($trunkAdapter.Name)' already configured with 10.10.10.30."
    } else {
        try {
            # Remove any existing IP on this adapter first
            Get-NetIPAddress -InterfaceIndex $trunkAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $trunkAdapter.ifIndex `
                             -IPAddress '10.10.10.30' `
                             -PrefixLength 24 `
                             -DefaultGateway '10.10.10.1' `
                             -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $trunkAdapter.ifIndex `
                                       -ServerAddresses @('10.10.10.1', '8.8.8.8')
            Write-Log "Static IP 10.10.10.30/24 set on trunk adapter '$($trunkAdapter.Name)'."
        } catch {
            Write-Log "WARN: Could not set static IP: $_"
        }
    }
} else {
    Write-Log "ERROR: Could not identify trunk adapter. Static IP not configured."
}

# ── Final status ───────────────────────────────────────────────────────
Write-Log "=== Post-install setup complete ==="
Write-Log "Services: RDP (3389), WinRM (5985), SNMP (161/udp), SMB (445), IIS (80)"
Write-Log "Admin password: P@ssw0rdLab!"
Write-Log "VLAN IP: 10.10.10.30/24"
