# Bunny Storage Zone Copy Utility

A PowerShell script to recursively copy contents between Bunny Storage zones.

## Features

- **Recursive Copy**: Recursively copies all files and directories from the source zone.
- **Parallel Processing**: Utilizes parallel processing for both download and upload operations to maximize throughput.
- **Local Caching**: Downloads files to a local cache directory before uploading, ensuring data integrity and allowing for inspection if needed.
- **GitHub Actions Integration**: Designed to be easily integrated into GitHub Actions workflows.

## Usage

### PowerShell Script

The script `CopyZone.ps1` can be run directly from a PowerShell terminal.

#### Parameters

- `SourceZoneName`: The name of the source Bunny Storage zone.
- `SourceAccessKey`: The access key for the source Bunny Storage zone.
- `SourceEndpoint`: The endpoint for the source Bunny Storage zone (default: `storage.bunnycdn.com`).
- `DestinationZoneName`: The name of the destination Bunny Storage zone.
- `DestinationAccessKey`: The access key for the destination Bunny Storage zone.
- `DestinationEndpoint`: The endpoint for the destination Bunny Storage zone (default: `storage.bunnycdn.com`).
- `LocalCachePath`: The local directory to use as a cache for the transfer.
- `ThrottleLimit`: The maximum number of concurrent threads to use (default: 50).

#### Example

```powershell
./CopyZone.ps1 `
    -SourceZoneName "my-source-zone" `
    -SourceAccessKey "source-key-123" `
    -DestinationZoneName "my-dest-zone" `
    -DestinationAccessKey "dest-key-456" `
    -LocalCachePath "./temp_cache"
```

### GitHub Actions

This repository includes a GitHub Actions workflow `.github/workflows/CopyZone.yml` that can be manually triggered.

#### Inputs

- `source_zone_name`: Source Bunny Storage Zone Name (required).
- `destination_zone_name`: Destination Bunny Storage Zone Name (required).
- `source_endpoint`: Source Endpoint (optional, default: `storage.bunnycdn.com`).
- `destination_endpoint`: Destination Endpoint (optional, default: `storage.bunnycdn.com`).

#### Secrets

Ensure the following secrets are set in your repository:

- `SOURCE_ACCESS_KEY`: Access key for the source zone.
- `DESTINATION_ACCESS_KEY`: Access key for the destination zone.

## Requirements

- PowerShell 7 or later.
- A valid Bunny Storage account and zones.
