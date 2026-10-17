<#!
.SYNOPSIS
Builds slide-reconstruction assets for every MP4 in this directory.

.DESCRIPTION
Each source video gets a folder under video-assets containing:
  - metadata.json: complete container/stream probe plus extraction details
  - frames/frame_00000001.png ...: one lossless image per decoded video frame
  - frames/frame_index.json: frame timing and technical properties from ffprobe
#>

[CmdletBinding()]
param(
    [string]$InputDirectory = $PSScriptRoot,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'video-assets')
)

$ErrorActionPreference = 'Stop'

foreach ($requiredCommand in @('ffmpeg', 'ffprobe')) {
    if (-not (Get-Command $requiredCommand -ErrorAction SilentlyContinue)) {
        throw "Required command '$requiredCommand' was not found on PATH."
    }
}

$inputPath = (Resolve-Path -LiteralPath $InputDirectory).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDirectory).Path

function ConvertTo-SafeFolderName {
    param([string]$Name)

    $clean = $Name -replace '[\\/:*?"<>|]', '_'
    $clean = $clean.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'untitled-video' }
    return $clean
}

$videos = Get-ChildItem -LiteralPath $inputPath -File -Filter '*.mp4' | Sort-Object Name
if ($videos.Count -eq 0) {
    Write-Warning "No MP4 files found in $inputPath"
    exit 0
}

foreach ($video in $videos) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
    $assetName = ConvertTo-SafeFolderName $baseName
    $assetDirectory = Join-Path $outputPath $assetName
    $framesDirectory = Join-Path $assetDirectory 'frames'
    $metadataPath = Join-Path $assetDirectory 'metadata.json'
    $frameIndexPath = Join-Path $framesDirectory 'frame_index.json'
    $referenceVideoPath = Join-Path $assetDirectory $video.Name

    New-Item -ItemType Directory -Force -Path $framesDirectory | Out-Null

    Write-Host "Processing: $($video.Name)"
    $sourceHash = (Get-FileHash -LiteralPath $video.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    # Keep a self-contained, byte-for-byte reference of the original alongside
    # its extracted slide assets.
    Copy-Item -LiteralPath $video.FullName -Destination $referenceVideoPath -Force

    # This preserves format- and stream-level metadata, including codec settings,
    # bitrate, timing, disposition, tags, and audio/subtitle streams.
    $probeJson = & ffprobe -v error -show_format -show_streams -show_chapters -show_programs -of json -- $video.FullName
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for $($video.Name)" }
    $probe = $probeJson | ConvertFrom-Json

    # Timing/properties for every decoded video frame; filenames use this same order.
    $frameIndexJson = & ffprobe -v error -select_streams v:0 -show_frames `
        -show_entries 'frame=media_type,stream_index,key_frame,pkt_pts,pkt_pts_time,pkt_dts,pkt_dts_time,best_effort_timestamp,best_effort_timestamp_time,pkt_duration,pkt_duration_time,pkt_pos,pkt_size,width,height,pix_fmt,sample_aspect_ratio,pict_type,coded_picture_number,display_picture_number,interlaced_frame,top_field_first,repeat_pict,color_range,color_space,color_primaries,color_transfer,chroma_location' `
        -of json -- $video.FullName
    if ($LASTEXITCODE -ne 0) { throw "ffprobe frame indexing failed for $($video.Name)" }
    $frameIndexJson | Set-Content -LiteralPath $frameIndexPath -Encoding utf8
    $frameIndex = $frameIndexJson | ConvertFrom-Json
    $indexedFrameCount = @($frameIndex.frames).Count

    # Remove frames from a previous partial run, then write every decoded frame as
    # a lossless PNG. The 8-digit suffix is stable and one-based.
    Get-ChildItem -LiteralPath $framesDirectory -File -Filter 'frame_*.png' | Remove-Item -Force
    $imagePattern = Join-Path $framesDirectory 'frame_%08d.png'
    & ffmpeg -hide_banner -loglevel error -y -i $video.FullName -map 0:v:0 -fps_mode passthrough -pix_fmt rgb24 $imagePattern
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg frame extraction failed for $($video.Name)" }

    $extractedFrameCount = @(Get-ChildItem -LiteralPath $framesDirectory -File -Filter 'frame_*.png').Count
    if ($extractedFrameCount -ne $indexedFrameCount) {
        throw "Frame verification failed for $($video.Name): ffprobe indexed $indexedFrameCount frames, but ffmpeg wrote $extractedFrameCount PNGs."
    }

    $videoStream = @($probe.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
    $metadata = [ordered]@{
        schema_version = '1.0'
        generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        source = [ordered]@{
            filename = $video.Name
            original_path = $video.FullName
            reference_copy = $video.Name
            file_size_bytes = $video.Length
            sha256 = $sourceHash
        }
        frame_extraction = [ordered]@{
            image_format = 'PNG'
            pixel_format = 'rgb24'
            filename_pattern = 'frames/frame_%08d.png'
            frame_index_file = 'frames/frame_index.json'
            numbering = 'one-based, decode order'
            extracted_frame_count = $extractedFrameCount
            indexed_frame_count = $indexedFrameCount
            fps_mode = 'passthrough'
            extraction_command = 'ffmpeg -map 0:v:0 -fps_mode passthrough -pix_fmt rgb24'
        }
        primary_video_summary = [ordered]@{
            codec = $videoStream.codec_name
            codec_long_name = $videoStream.codec_long_name
            profile = $videoStream.profile
            width = $videoStream.width
            height = $videoStream.height
            display_aspect_ratio = $videoStream.display_aspect_ratio
            sample_aspect_ratio = $videoStream.sample_aspect_ratio
            pixel_format = $videoStream.pix_fmt
            average_frame_rate = $videoStream.avg_frame_rate
            nominal_frame_rate = $videoStream.r_frame_rate
            time_base = $videoStream.time_base
            duration_seconds = $videoStream.duration
            bit_rate_bps = $videoStream.bit_rate
            nb_frames_reported_by_container = $videoStream.nb_frames
            color_range = $videoStream.color_range
            color_space = $videoStream.color_space
            color_transfer = $videoStream.color_transfer
            color_primaries = $videoStream.color_primaries
        }
        ffprobe = $probe
    }

    $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8
    Write-Host "Completed: $assetName ($extractedFrameCount frames)"
}

Write-Host "All video assets are available in: $outputPath"
