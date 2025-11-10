#!/usr/bin/env pwsh

$AllSongsSchemas = "https://sekai-world.github.io/sekai-master-db-diff/musics.json";
$AllSongsAssets = "https://sekai-world.github.io/sekai-master-db-diff/musicVocals.json";

$SongAssetFlacUrlTemplate = "https://storage.sekai.best/sekai-jp-assets/music/long/{0}/{0}.flac";
$SongCoverArtUrlTemplate = "https://storage.sekai.best/sekai-jp-assets/music/jacket/{0}/{0}.png";

class SongSchemaResponse {
    [int]$id
    [int]$seq
    [int]$releaseConditionId
    [string[]]$categories
    [string]$title
    [string]$pronunciation
    [int]$creatorArtistId
    [string]$lyricist
    [string]$composer
    [string]$arranger
    [int]$dancerCount
    [int]$selfDancerPosition
    [string]$assetbundleName
    [string]$liveTalkBackgroundAssetbundleName
    [long]$publishedAt
    [long]$releasedAt
    [int]$liveStageId
    [double]$fillerSec
    [Nullable[int]]$musicCollaborationId
    [bool]$isNewlyWrittenMusic
    [bool]$isFullLength
}

class SongAssetResponse {
    [int]$id
    [int]$musicId
    [string]$musicVocalType
    [int]$seq
    [int]$releaseConditionId
    [string]$caption
    [object[]]$characters
    [string]$assetbundleName
    [Nullable[long]]$archivePublishedAt
    [string]$archiveDisplayType
    [Nullable[int]]$specialSeasonId
}

class SongResource {
    [SongSchemaResponse]$Schema
    [SongAssetResponse]$Asset
}

#

# Check if metaflac is available
function Test-MetaflacAvailable {
    try {
        $null = Get-Command metaflac -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "metaflac command not found. FLAC metadata will not be set."
        Write-Warning "Please install FLAC tools: https://xiph.org/flac/download.html"
        return $false
    }
}

# Fetch all song schemas
function Fetch-AllSongSchemas {
    $response = Invoke-RestMethod -Uri $AllSongsSchemas -Method Get
    return $response | ForEach-Object { [SongSchemaResponse]$_ }
}

# Fetch all song assets
function Fetch-AllSongAssets {
    $response = Invoke-RestMethod -Uri $AllSongsAssets -Method Get
    return $response | ForEach-Object { [SongAssetResponse]$_ }
}

function Fetch-AllSongResources {

    $schemas = Fetch-AllSongSchemas
    $assets = Fetch-AllSongAssets

    $resources = @()

    foreach ($schema in $schemas) {
        $matchingAssets = $assets | Where-Object { $_.musicId -eq $schema.id }
        foreach ($asset in $matchingAssets) {
            $resource = [SongResource]::new()
            $resource.Schema = $schema
            $resource.Asset = $asset
            $resources += $resource
        }
    }

    return $resources
}

#

function Get-SongAssetUrl {
    param (
        [SongResource]$SongResource
    )

    # Use the asset bundle name instead of the schema ID
    $assetBundleName = $SongResource.Asset.assetbundleName
    return [string]::Format($SongAssetFlacUrlTemplate, $assetBundleName)
}

function Set-FlacMetadata {
    param (
        [string]$FilePath,
        [SongResource]$SongResource
    )

    if (-not (Test-Path $FilePath)) {
        Write-Warning "File not found for metadata tagging: $FilePath"
        return
    }

    try {
        # Remove all existing tags first
        & metaflac --remove-all-tags "$FilePath" 2>$null

        # Song title with caption
        $title = $SongResource.Schema.title
        if ($SongResource.Asset.caption) {
            $title = "$title - $($SongResource.Asset.caption)"
        }
        & metaflac --set-tag="TITLE=$title" "$FilePath"

        # Composer (or "Various Artists" if empty)
        $artist = if ($SongResource.Schema.composer) { 
            $SongResource.Schema.composer 
        } else { 
            "Various Artists" 
        }
        & metaflac --set-tag="ARTIST=$artist" "$FilePath"

        # Use composer as album artist
        & metaflac --set-tag="ALBUMARTIST=$artist" "$FilePath"

        # Use the song title as album name
        $album = $SongResource.Schema.title
        & metaflac --set-tag="ALBUM=$album" "$FilePath"

        # Set composer field
        if ($SongResource.Schema.composer) {
            & metaflac --set-tag="COMPOSER=$($SongResource.Schema.composer)" "$FilePath"
        }

        # Additional metadata
        if ($SongResource.Schema.lyricist) {
            & metaflac --set-tag="LYRICIST=$($SongResource.Schema.lyricist)" "$FilePath"
        }

        if ($SongResource.Schema.arranger) {
            & metaflac --set-tag="ARRANGER=$($SongResource.Schema.arranger)" "$FilePath"
        }

        # Use published date if available
        if ($SongResource.Schema.publishedAt -gt 0) {
            $date = [DateTimeOffset]::FromUnixTimeMilliseconds($SongResource.Schema.publishedAt).Year
            & metaflac --set-tag="DATE=$date" "$FilePath"
        }

        Write-Output "  > Metadata set successfully"
    }
    catch {
        Write-Warning "  > Failed to set metadata: $($_.Exception.Message)"
    }
}

function Download-SongAsset {
    param (
        [SongResource]$SongResource,
        [string]$BaseFolder,
        [bool]$SetMetadata
    )

    $url = Get-SongAssetUrl -SongResource $SongResource
    
    $sanitizedTitle = $SongResource.Schema.title -replace '[\\/:*?"<>|]', '_'
    $caption = $SongResource.Asset.caption -replace '[\\/:*?"<>|]', '_'
    
    # remove trailing dots from caption to avoid double dots before extension
    $caption = $caption.TrimEnd('.')

    # BaseFolder/SongName/
    $songFolder = Join-Path -Path $BaseFolder -ChildPath $sanitizedTitle
    if (-not (Test-Path -Path $songFolder)) {
        New-Item -ItemType Directory -Path $songFolder -Force | Out-Null
    }
    
    # filename: SongName_Caption.extension
    $fileName = "${sanitizedTitle}_${caption}.flac"
    $destinationPath = Join-Path -Path $songFolder -ChildPath $fileName

    try {
        Invoke-WebRequest -Uri $url -OutFile $destinationPath
        Write-Output "  > Downloaded: $fileName"
        
        # Set metadata if metaflac is available
        if ($SetMetadata) {
            Set-FlacMetadata -FilePath $destinationPath -SongResource $SongResource
        }
    }
    catch {
        Write-Warning "  > Failed to download: $fileName (URL: $url)"
        Write-Warning "  > Error: $($_.Exception.Message)"
    }
}

#

function Get-SongCoverArtUrl {
    param (
        [SongResource]$SongResource
    )

    $assetBundleName = $SongResource.Schema.assetbundleName
    return [string]::Format($SongCoverArtUrlTemplate, $assetBundleName)
}

function Download-SongCoverArt {
    param (
        [SongResource]$SongResource,
        [string]$BaseFolder
    )

    $url = Get-SongCoverArtUrl -SongResource $SongResource
    
    $sanitizedTitle = $SongResource.Schema.title -replace '[\\/:*?"<>|]', '_'

    # BaseFolder/SongName/
    $songFolder = Join-Path -Path $BaseFolder -ChildPath $sanitizedTitle
    if (-not (Test-Path -Path $songFolder)) {
        New-Item -ItemType Directory -Path $songFolder -Force | Out-Null
    }
    
    $fileName = "cover.png"
    $destinationPath = Join-Path -Path $songFolder -ChildPath $fileName

    try {
        Invoke-WebRequest -Uri $url -OutFile $destinationPath
        Write-Output "  > Downloaded Cover Art: $fileName"
    }
    catch {
        Write-Warning "  > Failed to download Cover Art: $fileName (URL: $url)"
        Write-Warning "  > Error: $($_.Exception.Message)"
    }
}

#

$outputFolder = "./output"

# Check if metaflac is available
$metaflacAvailable = Test-MetaflacAvailable
if ($metaflacAvailable) {
    Write-Output "metaflac found - FLAC metadata will be set`n"
} else {
    Write-Output "Continuing without metadata tagging...`n"
}

#

Write-Output "Fetching song metadata..."
$songResources = Fetch-AllSongResources
Write-Output "Found $($songResources.Count) song assets. Starting downloads...`n"

foreach ($resource in $songResources) {
    Write-Output "Processing: $($resource.Schema.title) [$($resource.Asset.assetbundleName)]"
    Download-SongAsset -SongResource $resource -BaseFolder $outputFolder -SetMetadata $metaflacAvailable
    Download-SongCoverArt -SongResource $resource -BaseFolder $outputFolder
    Write-Output ""
}

Write-Output "Download process complete!"