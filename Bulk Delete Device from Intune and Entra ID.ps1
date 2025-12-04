<#
.SYNOPSIS
Removes devices from Intune and Entra ID using strict name + Entra device ID matching.

.DESCRIPTION
This script reads device names from a text file, deletes each device from Intune,
captures the Entra DeviceId (from Intune’s AzureADDeviceId property), and then removes
the device from Entra ID *only if both conditions are true*:
1. DeviceName matches in Entra ID
2. DeviceId matches the Entra DeviceId captured from Intune

This ensures that only the correct and exact device object is deleted in Entra,
avoiding accidental removal of renamed, stale, duplicate, or Hybrid-joined device objects.

A detailed CSV log is created showing the full processing status for each device.


.INPUTS
A plain text (.txt) file containing one device name per line.

.OUTPUTS
A CSV log file containing:
- DeviceName
- FoundInIntune
- FoundInEntra
- RemovedFromIntune
- RemovedFromEntra
- TimeStamp

.PARAMETER inputFile
Specifies the full path to the input file containing the device names.

.PARAMETER logPath
Specifies the output path for the CSV log file.

If the device is registered in Autopilot, then you must first delete the hardware hash in order to remove the device from Entra.
You can follow this video to achieve this: https://youtu.be/tagauZHtLUU?si=iTb5E5v2mU3UfYAj

.NOTES
Author: Chander Mani Pandey
Requires: Microsoft.Graph PowerShell SDK
Graph Permissions Required:
- DeviceManagementManagedDevices.ReadWrite.All
- Directory.Read.All
- Device.ReadWrite.All
#>

# Ensure Graph installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.DeviceManagement -Force
Import-Module Microsoft.Graph.Identity.DirectoryManagement -Force

Connect-MgGraph -Scopes "Device.ReadWrite.All","Directory.Read.All","DeviceManagementManagedDevices.ReadWrite.All"

$inputFile = "C:\Temp\DeviceList.txt"
$logPath   = "C:\Temp\DeviceRemovalLog.csv"
$logOutput = @()

$deviceNames = Get-Content $inputFile | Where-Object { $_.Trim() -ne "" }

foreach ($deviceName in $deviceNames) {

    Write-Host "`n=================================================" -ForegroundColor Cyan
    Write-Host "Processing device: $deviceName" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan

    $intuneFound = $false
    $removedFromIntune = "No"
    $removedFromEntra  = "No"
    $entraFound = $false
    $entraDeviceIdFromIntune = $null

    # -----------------------------------------------------------
    # STEP 1: DELETE FROM INTUNE AND CAPTURE AzureADDeviceId
    # -----------------------------------------------------------
    try {
        $intuneDevice  = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'"

        if ($intuneDevice) {
            $intuneFound = $true

            # REAL Entra DeviceId (GUID)
            $entraDeviceIdFromIntune = $intuneDevice.AzureADDeviceId

            Write-Host "✔ Intune device FOUND." -ForegroundColor Green
            Write-Host "  Intune DeviceName  : $deviceName"
            Write-Host "  AzureADDeviceId    : $entraDeviceIdFromIntune" -ForegroundColor Yellow

            # Remove device from Intune
            Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $intuneDevice.Id
            $removedFromIntune = "Yes"
            Write-Host "✔ Device removed from Intune." -ForegroundColor Green
        }
        else {
            Write-Host "✖ Device NOT found in Intune." -ForegroundColor Red
        }
    }
    catch {
        Write-Warning "Error checking Intune: $_"
    }

    # -----------------------------------------------------------
    # STEP 2: DELETE FROM ENTRA ONLY IF NAME + DEVICEID MATCH
    # -----------------------------------------------------------
    if ($intuneFound -eq $true) {

        Write-Host "`nChecking Entra ID for matching name AND ID..." -ForegroundColor Cyan

        # Fetch all Entra devices with same name
        $entraDevices  = Get-MgDevice -Filter "displayName eq '$deviceName'"
        $entraMatchesCount = $entraDevices.Count

        if ($entraMatchesCount -gt 0) {
            $entraFound = $true
        }

        Write-Host "Found $entraMatchesCount Entra device(s) with displayName: $deviceName" -ForegroundColor Yellow

        foreach ($e in $entraDevices) {
            Write-Host " → Entra DeviceId Found: $($e.DeviceId)" -ForegroundColor DarkYellow
        }

        # Strict match on DeviceId
        $exactMatch = $entraDevices | Where-Object { $_.DeviceId -eq $entraDeviceIdFromIntune }

        if ($exactMatch) {
            Write-Host "✔ MATCH FOUND:" -ForegroundColor Green
            Write-Host "  Entra DeviceName : $($exactMatch.displayName) "
            Write-Host "  Entra DeviceId   : $($exactMatch.DeviceID) " -ForegroundColor Yellow

            # DELETE from Entra
            Remove-MgDevice -DeviceId $exactMatch.Id
            $removedFromEntra = "Yes"
            Write-Host "✔ Device removed from Entra." -ForegroundColor Green
        }
        else {
            Write-Host "✖ NO Entra deletion performed." -ForegroundColor Yellow
            Write-Host "Reason: Either DeviceName or DeviceId did NOT match." -ForegroundColor Red
            Write-Host "Intune DeviceId being checked:  $entraDeviceIdFromIntune" -ForegroundColor DarkYellow
        }
    }

    # -----------------------------------------------------------
    # LOGGING
    # -----------------------------------------------------------
    $logOutput += [pscustomobject]@{
        DeviceName        = $deviceName
        FoundInIntune     = $intuneFound
        FoundInEntra      = $entraFound
        RemovedFromIntune = $removedFromIntune
        RemovedFromEntra  = $removedFromEntra
        TimeStamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

$logOutput | Export-Csv -Path $logPath -NoTypeInformation
Write-Host "`nProcess complete. Log saved to: $logPath" -ForegroundColor Cyan
Invoke-Item $logPath


#DisConnect-MgGraph
