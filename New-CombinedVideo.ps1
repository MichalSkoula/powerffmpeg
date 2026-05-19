[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputFolder,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputName,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$FirstLine,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SecondLine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Escape-FFmpegText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    return $Text `
        -replace '\\', '\\\\' `
        -replace "'", "\\'" `
        -replace ':', '\:' `
        -replace ',', '\,' `
        -replace ';', '\;' `
        -replace '\[', '\[' `
        -replace '\]', '\]' `
        -replace '%', '\%'
}

function Get-VideoInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $width = & ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 -- $Path
    $height = & ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 -- $Path
    $frameRate = & ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- $Path

    if ([string]::IsNullOrWhiteSpace($width) -or [string]::IsNullOrWhiteSpace($height) -or [string]::IsNullOrWhiteSpace($frameRate)) {
        throw "Nepodařilo se načíst parametry videa: $Path"
    }

    return [pscustomobject]@{
        Width = [int]$width.Trim()
        Height = [int]$height.Trim()
        FrameRate = $frameRate.Trim()
    }
}

function Test-HasAudioStream {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $audioStream = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 -- $Path
    return -not [string]::IsNullOrWhiteSpace($audioStream)
}

if (-not (Test-CommandExists -Name 'ffmpeg')) {
    throw 'Příkaz ffmpeg nebyl nalezen v PATH.'
}

if (-not (Test-CommandExists -Name 'ffprobe')) {
    throw 'Příkaz ffprobe nebyl nalezen v PATH.'
}

$resolvedInputFolder = (Resolve-Path -Path $InputFolder).Path

$supportedExtensions = @('*.mp4', '*.mov', '*.m4v', '*.avi', '*.mkv', '*.webm')
$videoFiles = foreach ($pattern in $supportedExtensions) {
    Get-ChildItem -Path $resolvedInputFolder -Filter $pattern -File
}

$videoFiles = $videoFiles |
    Sort-Object -Property Name -Unique

if ($videoFiles.Count -eq 0) {
    throw "Ve složce '$resolvedInputFolder' nebyla nalezena žádná podporovaná videa."
}

$outputFileName = if ([IO.Path]::GetExtension($OutputName)) {
    $OutputName
}
else {
    "$OutputName.mp4"
}

$outputPath = Join-Path -Path $resolvedInputFolder -ChildPath $outputFileName

$referenceVideo = Get-VideoInfo -Path $videoFiles[0].FullName
$targetWidth = $referenceVideo.Width
$targetHeight = $referenceVideo.Height
$targetFrameRate = $referenceVideo.FrameRate

$tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("powerffmpeg_" + [guid]::NewGuid().ToString('N'))
$normalizedFolder = Join-Path -Path $tempRoot -ChildPath 'normalized'
$concatListPath = Join-Path -Path $tempRoot -ChildPath 'concat.txt'
$mergedPath = Join-Path -Path $tempRoot -ChildPath 'merged.mp4'

New-Item -ItemType Directory -Path $normalizedFolder -Force | Out-Null

try {
    for ($index = 0; $index -lt $videoFiles.Count; $index++) {
        $file = $videoFiles[$index]
        $normalizedPath = Join-Path -Path $normalizedFolder -ChildPath ('{0:D4}.mp4' -f $index)
        $videoFilter = "scale=$targetWidth`:$targetHeight`:`force_original_aspect_ratio=decrease,pad=$targetWidth`:$targetHeight`:(ow-iw)/2`:(oh-ih)/2`:`color=black,fps=$targetFrameRate,format=yuv420p,setsar=1"

        $ffmpegArgs = @(
            '-y',
            '-i', $file.FullName
        )

        if (-not (Test-HasAudioStream -Path $file.FullName)) {
            $ffmpegArgs += @('-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000')
        }

        $ffmpegArgs += @(
            '-vf', $videoFilter
        )

        if (Test-HasAudioStream -Path $file.FullName) {
            $ffmpegArgs += @('-af', 'aresample=48000')
        }
        else {
            $ffmpegArgs += @('-shortest', '-af', 'aresample=48000')
        }

        $ffmpegArgs += @(
            '-c:v', 'libx264',
            '-preset', 'medium',
            '-crf', '20',
            '-c:a', 'aac',
            '-b:a', '192k',
            '-movflags', '+faststart',
            $normalizedPath
        )

        & ffmpeg @ffmpegArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Normalizace videa selhala: $($file.FullName)"
        }
    }

    $concatLines = for ($index = 0; $index -lt $videoFiles.Count; $index++) {
        "file '$($normalizedFolder.Replace('\', '/'))/{0:D4}.mp4'" -f $index
    }
    Set-Content -Path $concatListPath -Value $concatLines -Encoding UTF8

    & ffmpeg -y -f concat -safe 0 -i $concatListPath -c copy $mergedPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Spojení videí selhalo.'
    }

    $safeFirstLine = Escape-FFmpegText -Text $FirstLine
    $safeSecondLine = Escape-FFmpegText -Text $SecondLine
    $titleFilter = @(
        "drawbox=x=iw*0.15:y=ih*0.18:w=iw*0.70:h=ih*0.22:color=black@0.35:t=fill:enable='lt(t,3)'",
        "drawtext=text='$safeFirstLine':fontcolor=white:fontsize=h/18:x=(w-text_w)/2:y=h*0.24:enable='lt(t,3)'",
        "drawtext=text='$safeSecondLine':fontcolor=white:fontsize=h/24:x=(w-text_w)/2:y=h*0.34:enable='lt(t,3)'"
    ) -join ','

    & ffmpeg -y -i $mergedPath -vf $titleFilter -c:v libx264 -preset medium -crf 20 -c:a copy -movflags +faststart $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Vytvoření výsledného MP4 videa selhalo.'
    }
}
finally {
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}

Write-Host "Hotovo: $outputPath"
