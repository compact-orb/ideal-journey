<#
.SYNOPSIS
    Recursively copies contents from a source Bunny Storage zone to a destination zone using a local cache.

.DESCRIPTION
    This script downloads all files from a source Bunny Storage zone to a local cache directory,
    and then uploads them to a destination Bunny Storage zone.
    It uses parallel processing for both download and upload operations.

.PARAMETER SourceZoneName
    The name of the source Bunny Storage zone.

.PARAMETER SourceAccessKey
    The access key for the source Bunny Storage zone.

.PARAMETER SourceEndpoint
    The endpoint for the source Bunny Storage zone. Defaults to storage.bunnycdn.com.

.PARAMETER DestinationZoneName
    The name of the destination Bunny Storage zone.

.PARAMETER DestinationAccessKey
    The access key for the destination Bunny Storage zone.

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
    [Parameter(Mandatory = $true)]
    [string]$SourceAccessKey,
    [string]$SourceEndpoint = "storage.bunnycdn.com",
    [Parameter(Mandatory = $true)]
    [string]$DestinationZoneName,
    [Parameter(Mandatory = $true)]
    [string]$DestinationAccessKey,
    [string]$DestinationEndpoint = "storage.bunnycdn.com",
    [Parameter(Mandatory = $true)]
    [string]$LocalCachePath,
    [Int32]$ThrottleLimit = 50
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

# Ensure LocalCachePath exists
if (-not (Test-Path -Path $LocalCachePath)) {
    New-Item -Path $LocalCachePath -ItemType Directory | Out-Null
}

Write-Output -InputObject "Starting download from source zone: $SourceZoneName"

# --- Download Phase ---
# Initialize the list of directories to process with the starting path (root)
$Directories = "/"
$FilesToDownload = @()

# Loop until there are no more directories to process
do {
    # Process directories in parallel to list their contents
    $Directories = $Directories | ForEach-Object -Parallel {
        $CurrentDir = $_
        # List the contents of the current directory using the Bunny Storage API
        # Note: Using SourceEndpoint (Storage API) as requested, not CDN endpoint
        $Uri = "https://$using:SourceEndpoint/$using:SourceZoneName$CurrentDir/"
        
        try {
            $response = Invoke-RestMethod -StatusCodeVariable httpStatusCode -Uri $Uri -Headers @{ "accept" = "application/json"; "AccessKey" = $using:SourceAccessKey } -Method GET
        }
        catch {
            Write-Error -Message "Failed to list directory $CurrentDir : $_"
            return
        }

        $response | ForEach-Object {
            $ItemPath = $_.Path
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
    } -ThrottleLimit $ThrottleLimit | ForEach-Object {
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

# Download all collected files in parallel
if ($FilesToDownload.Count -gt 0) {
    $FilesToDownload | ForEach-Object -Parallel {
        $FileObj = $_
        Write-Output -InputObject "Downloading $($FileObj.Path) to $($FileObj.LocalPath)"

        # Download the file from Bunny Storage
        $Uri = "https://$using:SourceEndpoint/$using:SourceZoneName$($FileObj.Path)"
        Invoke-WebRequest -Uri $Uri -Headers @{ accept = '*/*'; AccessKey = $using:SourceAccessKey } -OutFile $FileObj.LocalPath
    } -ThrottleLimit $ThrottleLimit
}
else {
    Write-Output -InputObject "No files found to download."
}

Write-Output -InputObject "Download complete. Starting upload to destination zone: $DestinationZoneName"

# --- Upload Phase ---
# Recursively find all files in the local cache path and upload them in parallel
Get-ChildItem -Path $LocalCachePath -Recurse -File | ForEach-Object -Parallel {
    $File = $_
    # Calculate relative path for destination
    # We want the path relative to LocalCachePath
    $RelativePath = $File.FullName.Substring($using:LocalCachePath.Length).Replace('\', '/')
    
    # Ensure relative path starts with /
    if (-not $RelativePath.StartsWith('/')) {
        $RelativePath = "/$RelativePath"
    }

    $Uri = "https://$using:DestinationEndpoint/$using:DestinationZoneName$RelativePath"
    
    Write-Output -InputObject "Uploading $($File.Name) to $RelativePath"

    # Upload the file using the Bunny Storage API
    Invoke-RestMethod -Uri $Uri -Headers @{"accept" = "application/json"; "AccessKey" = $using:DestinationAccessKey } -Method PUT -ContentType "application/octet-stream" -InFile $File.FullName | Out-Null

} -ThrottleLimit $ThrottleLimit

Write-Output -InputObject "Copy operation complete."
