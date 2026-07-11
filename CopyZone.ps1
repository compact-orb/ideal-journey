<#
.SYNOPSIS
    Recursively copies contents from a source Bunny Storage zone to a destination zone using a local cache.

.DESCRIPTION
    Downloads all files from a source Bunny Storage zone and uploads them to a destination zone.
    Uses parallel processing for both operations. Access keys are read from environment
    variables SOURCE_ACCESS_KEY and DESTINATION_ACCESS_KEY.

    When SourcePullZoneUrl is specified, file downloads use the pull zone (unauthenticated)
    instead of the storage API. Directory listings always use the storage API.

.PARAMETER SourceZoneName
    The name of the source Bunny Storage zone.

.PARAMETER SourceEndpoint
    The endpoint for the source Bunny Storage zone. Defaults to storage.bunnycdn.com.

.PARAMETER SourcePullZoneUrl
    Optional pull zone base URL (e.g. https://myzone.b-cdn.net) for unauthenticated downloads.
    When set, file downloads use this URL instead of the storage API.

.PARAMETER DestinationZoneName
    The name of the destination Bunny Storage zone.

.PARAMETER DestinationEndpoint
    The endpoint for the destination Bunny Storage zone. Defaults to storage.bunnycdn.com.

.PARAMETER LocalCachePath
    The local directory to use as a cache for the transfer.

.PARAMETER ThrottleLimit
    The maximum number of concurrent threads to use for parallel operations. Default is 50.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceZoneName,
    [string]$SourceEndpoint = "storage.bunnycdn.com",
    [string]$SourcePullZoneUrl,
    [Parameter(Mandatory = $true)]
    [string]$DestinationZoneName,
    [string]$DestinationEndpoint = "storage.bunnycdn.com",
    [Parameter(Mandatory = $true)]
    [string]$LocalCachePath,
    [Int32]$ThrottleLimit = 50
)

$UsePullZone = -not [string]::IsNullOrWhiteSpace($SourcePullZoneUrl)
if ($UsePullZone) { $SourcePullZoneUrl = $SourcePullZoneUrl.TrimEnd('/') }
$SourceAccessKey = $env:SOURCE_ACCESS_KEY
$DestinationAccessKey = $env:DESTINATION_ACCESS_KEY

if ([string]::IsNullOrWhiteSpace($SourceAccessKey)) {
    throw "SOURCE_ACCESS_KEY environment variable is required."
}
if ([string]::IsNullOrWhiteSpace($DestinationAccessKey)) {
    throw "DESTINATION_ACCESS_KEY environment variable is required."
}

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

# Ensure LocalCachePath exists
if (-not (Test-Path -Path $LocalCachePath)) {
    New-Item -Path $LocalCachePath -ItemType Directory | Out-Null
}

function Test-BunnyZoneRead {
    param (
        [string]$ZoneName,
        [string]$AccessKey,
        [string]$Endpoint
    )

    Write-Output -InputObject "Validating read access for zone: $ZoneName..."
    $Uri = "https://$Endpoint/$ZoneName/"
    try {
        Invoke-RestMethod -Uri $Uri -Headers @{ "accept" = "application/json"; "AccessKey" = $AccessKey } -Method GET | Out-Null
        Write-Output -InputObject "Read access validation successful for zone: $ZoneName"
    }
    catch {
        throw "Failed to validate read access for zone $ZoneName : $_"
    }
}

function Test-BunnyZoneWrite {
    param (
        [string]$ZoneName,
        [string]$AccessKey,
        [string]$Endpoint
    )

    Write-Output -InputObject "Validating write access for zone: $ZoneName..."

    $TestFileName = "validation-test-$([guid]::NewGuid()).txt"
    $TestContent = -join ((65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object -Process { [char]$_ })
    $Uri = "https://$Endpoint/$ZoneName/$TestFileName"
    $Headers = @{ "accept" = "application/json"; "AccessKey" = $AccessKey }

    try {
        # 1. Upload Test File
        Invoke-RestMethod -Uri $Uri -Headers $Headers -Method PUT -Body $TestContent -ContentType "text/plain" | Out-Null
        
        # 2. Verify Content (Read)
        $DownloadedContent = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method GET
        if ($DownloadedContent -ne $TestContent) {
            throw "Content verification failed for zone $ZoneName"
        }

        Write-Output -InputObject "Write access validation successful for zone: $ZoneName"
    }
    catch {
        throw "Failed to validate write access for zone $ZoneName : $_"
    }
    finally {
        # 3. Cleanup (Delete) - Attempt even if previous steps failed
        try {
            Invoke-RestMethod -Uri $Uri -Headers $Headers -Method DELETE | Out-Null
        }
        catch {
            Write-Warning -Message "Failed to clean up validation file $TestFileName in zone $ZoneName : $_"
        }
    }
}

# Validate Source Zone (Read)
Test-BunnyZoneRead -ZoneName $SourceZoneName -AccessKey $SourceAccessKey -Endpoint $SourceEndpoint

# Validate Destination Zone (Write)
Test-BunnyZoneWrite -ZoneName $DestinationZoneName -AccessKey $DestinationAccessKey -Endpoint $DestinationEndpoint

if ($UsePullZone) {
    Write-Output -InputObject "Starting download from source: $SourceZoneName (via pull zone $SourcePullZoneUrl)"
} else {
    Write-Output -InputObject "Starting download from source: $SourceZoneName"
}

# --- Download Phase ---
# Initialize the list of directories to process with the starting path (root)
$Directories = "/"
$FilesToDownload = @()

# Loop until there are no more directories to process
do {
    # Process directories in parallel to list their contents
    $Directories = $Directories | ForEach-Object -Parallel {
        $CurrentDir = $_
        $Uri = "https://$using:SourceEndpoint/$using:SourceZoneName$CurrentDir/"

        try {
            $response = Invoke-RestMethod -StatusCodeVariable httpStatusCode -Uri $Uri -Headers @{ "accept" = "application/json"; "AccessKey" = $using:SourceAccessKey } -Method GET
        }
        catch {
            Write-Error -Message "Failed to list directory $CurrentDir : $_"
            return
        }

        $response | ForEach-Object -Process {
            $ItemPath = $_.Path
            $ZonePrefix = "/$($using:SourceZoneName)"

            # Strip the zone name prefix if present
            if ($ItemPath.StartsWith($ZonePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ItemPath = $ItemPath.Substring($ZonePrefix.Length)
            }

            # Ensure ItemPath starts with / if it's empty (for root) or doesn't have it
            if (-not $ItemPath.StartsWith("/")) {
                $ItemPath = "/$ItemPath"
            }

            $ObjectName = $_.ObjectName
            $FullPath = "$($ItemPath)$($ObjectName)"
            
            # Construct local path
            # Remove leading slash from FullPath if present to join correctly with LocalCachePath
            $RelativePath = $FullPath.TrimStart('/')
            $LocalPath = Join-Path -Path $using:LocalCachePath -ChildPath $RelativePath

            if ($_.IsDirectory) {
                # If it's a directory, create the corresponding local directory
                if (-not (Test-Path -Path $LocalPath)) {
                    New-Item -Path $LocalPath -ItemType Directory | Out-Null
                }

                # Return the directory path to be processed in the next iteration
                [PSCustomObject]@{
                    IsDirectory = $true;
                    Path        = "$FullPath/"
                }
            }
            else {
                # If it's a file, return the file path to be added to the download list
                [PSCustomObject]@{
                    IsDirectory = $false;
                    Path        = $FullPath
                    LocalPath   = $LocalPath
                }
            }
        }
    } -ThrottleLimit $ThrottleLimit | ForEach-Object -Process {
        if ($_.IsDirectory) {
            # Add subdirectory to the list for the next pass
            $_.Path
        }
        else {
            # Add file to the list of files to download
            $FilesToDownload += $_
        }
    }
} while (![string]::IsNullOrWhiteSpace($Directories))

# Transfer files in parallel (Download -> Upload -> Delete)
if ($FilesToDownload.Count -gt 0) {
    Write-Output -InputObject "Starting transfer of $($FilesToDownload.Count) files..."

    $FailedTransfers = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

    # 3 retries with exponential backoff, increase if transfers routinely need more
    $FilesToDownload | ForEach-Object -Parallel {
        $FileObj = $_
        if ($using:UsePullZone) {
            $SourceUri = "$($using:SourcePullZoneUrl)$($FileObj.Path)"
            $DownloadHeaders = @{ accept = '*/*' }
        } else {
            $SourceUri = "https://$using:SourceEndpoint/$using:SourceZoneName$($FileObj.Path)"
            $DownloadHeaders = @{ accept = '*/*'; AccessKey = $using:SourceAccessKey }
        }
        $DestUri = "https://$using:DestinationEndpoint/$using:DestinationZoneName$($FileObj.Path)"
        $MaxRetries = 3

        for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++) {
            try {
                # 1. Download
                $Suffix = if ($Attempt -gt 1) { " (attempt $Attempt)" } else { "" }
                Write-Output -InputObject "Downloading $($FileObj.Path)$Suffix..."
                Invoke-WebRequest -Uri $SourceUri -Headers $DownloadHeaders -OutFile $FileObj.LocalPath

                # 2. Upload
                Write-Output -InputObject "Uploading $($FileObj.Path)..."
                Invoke-RestMethod -Uri $DestUri -Headers @{"accept" = "application/json"; "AccessKey" = $using:DestinationAccessKey } -Method PUT -ContentType "application/octet-stream" -InFile $FileObj.LocalPath | Out-Null

                # 3. Delete
                Remove-Item -Path $FileObj.LocalPath -Force
                break
            }
            catch {
                if ($Attempt -lt $MaxRetries) {
                    $Delay = [math]::Pow(2, $Attempt)
                    Write-Warning -Message "Attempt $Attempt failed for $($FileObj.Path): $_ — retrying in ${Delay}s..."
                    Start-Sleep -Seconds $Delay
                }
                else {
                    Write-Warning -Message "Failed to transfer $($FileObj.Path) after $MaxRetries attempts: $_"
                    ($using:FailedTransfers).Add($FileObj.Path)
                }
            }
        }
    } -ThrottleLimit $ThrottleLimit

    if ($FailedTransfers.Count -gt 0) {
        Write-Output -InputObject "`n--- $($FailedTransfers.Count) failed transfer(s) ---"
        $FailedTransfers | Sort-Object | ForEach-Object -Process { Write-Output -InputObject "  $_" }
        Write-Output -InputObject ""
        exit 1
    }
}
else {
    Write-Output -InputObject "No files found to transfer."
}

Write-Output -InputObject "Copy operation complete."
