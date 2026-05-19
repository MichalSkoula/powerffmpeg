[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputFolder,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputName,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$OutputFolder,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$FirstLine,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SecondLine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$audioSampleRate = 48000
$audioChannelLayout = 'stereo'
$silentAudioSource = "anullsrc=channel_layout=$audioChannelLayout:sample_rate=$audioSampleRate"
$titleDurationSeconds = 3
$titleBoxX = 'iw*0.15'
$titleBoxY = 'ih*0.18'
$titleBoxWidth = 'iw*0.70'
$titleBoxHeight = 'ih*0.22'
$titleBoxColor = 'black@0.35'
$titleFirstLineFontSize = 'h/12'
$titleSecondLineFontSize = 'h/20'
$titleFirstLineY = 'h*0.24'
$titleSecondLineY = 'h*0.34'
$videoCodecArgs = @(
    '-c:v', 'libx264',
    '-preset', 'slow',
    '-crf', '17',
    '-movflags', '+faststart'
)

function Test-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Escape-FFmpegFilterValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return $Value `
        -replace '\\', '\\\\' `
        -replace ':', '\:' `
        -replace "'", "\\'" `
        -replace ',', '\,'
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
        throw "Failed to read video parameters: $Path"
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

function Remove-StaleTempFolders {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempRoot
    )

    Get-ChildItem -Path $TempRoot -Directory -Filter 'powerffmpeg_*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Failed to remove temporary folder '$($_.FullName)': $($_.Exception.Message)"
            }
        }
}

function Convert-ToFFmpegPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ([IO.Path]::GetFullPath($Path)) -replace '\\', '/'
}

function Get-DrawTextFontFile {
    $candidatePaths = @(
        (Join-Path -Path $env:WINDIR -ChildPath 'Fonts\arial.ttf')
        (Join-Path -Path $env:WINDIR -ChildPath 'Fonts\segoeui.ttf')
        (Join-Path -Path $env:WINDIR -ChildPath 'Fonts\calibri.ttf')
    )

    foreach ($path in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -Path $path -PathType Leaf)) {
            return $path
        }
    }

    throw 'No usable TTF font (arial/segoeui/calibri) was found for drawtext.'
}

function Format-CommandArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument -match '\s|"') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }

    return $Argument
}

function Invoke-FFmpegChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    $formattedArgs = ($Arguments | ForEach-Object { Format-CommandArgument -Argument ([string]$_) }) -join ' '
    $script:ffmpegLogBuffer.Add('')
    $script:ffmpegLogBuffer.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $StepName")
    $script:ffmpegLogBuffer.Add("ffmpeg $formattedArgs")
    $script:ffmpegLogBuffer.Add(('-' * 80))

    Write-Host "-> $StepName"
    $ffmpegOutputLines = @(& ffmpeg @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($ffmpegOutputLines.Count -gt 0) {
        foreach ($line in $ffmpegOutputLines) {
            $script:ffmpegLogBuffer.Add([string]$line)
        }
    }

    $script:ffmpegLogBuffer.Add("ExitCode: $exitCode")
    $script:ffmpegLogBuffer.Add(('=' * 80))

    if ($exitCode -ne 0) {
        if ($ffmpegOutputLines.Count -gt 0) {
            Write-Host ($ffmpegOutputLines -join [Environment]::NewLine)
        }
        throw "$StepName failed."
    }

    Write-Host "   OK"
}

function Write-FFmpegLogFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedInputFolder,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ExceptionMessage
    )

    $content = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        'FFmpeg log',
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Input folder: $ResolvedInputFolder",
        "Output file: $OutputPath",
        ('=' * 80)
    )) {
        $content.Add($line)
    }

    foreach ($line in $script:ffmpegLogBuffer) {
        $content.Add($line)
    }

    if (-not [string]::IsNullOrWhiteSpace($ExceptionMessage)) {
        foreach ($line in @(
            '',
            "EXCEPTION: $ExceptionMessage",
            ('=' * 80)
        )) {
            $content.Add($line)
        }
    }

    Set-Content -Path $LogPath -Value $content -Encoding UTF8
}

if (-not (Test-CommandExists -Name 'ffmpeg')) {
    throw 'ffmpeg was not found in PATH.'
}

if (-not (Test-CommandExists -Name 'ffprobe')) {
    throw 'ffprobe was not found in PATH.'
}

$resolvedInputFolder = (Resolve-Path -Path $InputFolder).Path

$supportedExtensions = @('*.mp4', '*.mov', '*.m4v', '*.avi', '*.mkv', '*.webm')
$videoFiles = @(foreach ($pattern in $supportedExtensions) {
    Get-ChildItem -Path $resolvedInputFolder -Filter $pattern -File
})

$videoFiles = $videoFiles |
    Sort-Object -Property Name -Unique

if ($videoFiles.Count -eq 0) {
    throw "No supported videos were found in folder '$resolvedInputFolder'."
}

$outputExtension = [IO.Path]::GetExtension($OutputName)
$outputFileName = if ([string]::Equals($outputExtension, '.mp4', [StringComparison]::OrdinalIgnoreCase)) {
    $OutputName
}
elseif ([string]::IsNullOrWhiteSpace($outputExtension)) {
    "$OutputName.mp4"
}
else {
    throw 'Output file must be .mp4 or have no extension.'
}

if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $outputDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    }
    else {
        Split-Path -Path $PSCommandPath -Parent
    }
}
else {
    if ([string]::Equals([IO.Path]::GetExtension($OutputFolder), '.mp4', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputFolder must be a folder path, not an .mp4 file path.'
    }

    $outputDirectory = if ([IO.Path]::IsPathRooted($OutputFolder)) {
        $OutputFolder
    }
    else {
        Join-Path -Path (Get-Location).Path -ChildPath $OutputFolder
    }
}

$outputDirectory = [IO.Path]::GetFullPath($outputDirectory)
if (-not (Test-Path -Path $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$outputPath = Join-Path -Path $outputDirectory -ChildPath $outputFileName

$referenceVideo = Get-VideoInfo -Path $videoFiles[0].FullName
$targetWidth = $referenceVideo.Width
$targetHeight = $referenceVideo.Height
$targetFrameRate = $referenceVideo.FrameRate

$logTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$ffmpegLogPath = Join-Path -Path $outputDirectory -ChildPath "video_ffmpeg_log_$logTimestamp.txt"
$script:ffmpegLogBuffer = [System.Collections.Generic.List[string]]::new()

$tempRoot = [IO.Path]::GetTempPath()
Remove-StaleTempFolders -TempRoot $tempRoot

$tempProcessingRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "powerffmpeg_$([guid]::NewGuid().ToString('N'))"
$normalizedFolder = Join-Path -Path $tempProcessingRoot -ChildPath 'normalized'
$concatListPath = Join-Path -Path $tempProcessingRoot -ChildPath 'concat.txt'
$mergedPath = Join-Path -Path $tempProcessingRoot -ChildPath 'merged.mp4'
$finalTempOutputPath = Join-Path -Path $tempProcessingRoot -ChildPath 'final_output.mp4'
$titleFilterPath = Join-Path -Path $tempProcessingRoot -ChildPath 'title_filter.txt'
$titleFirstLinePath = Join-Path -Path $tempProcessingRoot -ChildPath 'title_line_1.txt'
$titleSecondLinePath = Join-Path -Path $tempProcessingRoot -ChildPath 'title_line_2.txt'

New-Item -ItemType Directory -Path $normalizedFolder -Force | Out-Null

try {
    for ($index = 0; $index -lt $videoFiles.Count; $index++) {
        $file = $videoFiles[$index]
        $normalizedPath = Join-Path -Path $normalizedFolder -ChildPath ('{0:D4}.mp4' -f $index)
        $videoFilter = @(
            ('scale={0}:{1}:force_original_aspect_ratio=decrease' -f $targetWidth, $targetHeight)
            ('pad={0}:{1}:(ow-iw)/2:(oh-ih)/2:color=black' -f $targetWidth, $targetHeight)
            "fps=$targetFrameRate"
            'format=yuv420p'
            'setsar=1'
        ) -join ','
        $hasAudio = Test-HasAudioStream -Path $file.FullName

        $ffmpegArgs = @(
            '-y',
            '-i', $file.FullName
        )

        if (-not $hasAudio) {
            $ffmpegArgs += @('-f', 'lavfi', '-i', $silentAudioSource)
        }

        $ffmpegArgs += @(
            '-vf', $videoFilter
        )

        if ($hasAudio) {
            $ffmpegArgs += @('-af', "aresample=$audioSampleRate")
        }
        else {
            $ffmpegArgs += @('-shortest', '-af', "aresample=$audioSampleRate")
        }

        $ffmpegArgs += $videoCodecArgs
        $ffmpegArgs += @(
            '-c:a', 'aac',
            '-b:a', '192k',
            $normalizedPath
        )

        Invoke-FFmpegChecked -Arguments $ffmpegArgs -StepName "Normalizing video: $($file.FullName)"
    }

    $concatLines = for ($index = 0; $index -lt $videoFiles.Count; $index++) {
        "file '$((Convert-ToFFmpegPath -Path (Join-Path -Path $normalizedFolder -ChildPath ('{0:D4}.mp4' -f $index))))'"
    }
    Set-Content -Path $concatListPath -Value $concatLines -Encoding UTF8

    Invoke-FFmpegChecked -Arguments @('-y', '-f', 'concat', '-safe', '0', '-i', $concatListPath, '-c', 'copy', $mergedPath) -StepName 'Merging videos'

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($titleFirstLinePath, $FirstLine, $utf8NoBom)
    [IO.File]::WriteAllText($titleSecondLinePath, $SecondLine, $utf8NoBom)

    $fontFile = Get-DrawTextFontFile
    $fontFileFFmpeg = Escape-FFmpegFilterValue -Value (Convert-ToFFmpegPath -Path $fontFile)
    $titleFirstLinePathFFmpeg = Escape-FFmpegFilterValue -Value (Convert-ToFFmpegPath -Path $titleFirstLinePath)
    $titleSecondLinePathFFmpeg = Escape-FFmpegFilterValue -Value (Convert-ToFFmpegPath -Path $titleSecondLinePath)
    $titleFilter = @(
        ("drawbox=x={0}:y={1}:w={2}:h={3}:color={4}:t=fill:enable='lt(t,{5})'" -f $titleBoxX, $titleBoxY, $titleBoxWidth, $titleBoxHeight, $titleBoxColor, $titleDurationSeconds),
        ("drawtext=fontfile='{0}':textfile='{1}':fontcolor=white:fontsize={2}:text_shaping=0:x=(w-text_w)/2:y={3}:enable='lt(t,{4})'" -f $fontFileFFmpeg, $titleFirstLinePathFFmpeg, $titleFirstLineFontSize, $titleFirstLineY, $titleDurationSeconds),
        ("drawtext=fontfile='{0}':textfile='{1}':fontcolor=white:fontsize={2}:text_shaping=0:x=(w-text_w)/2:y={3}:enable='lt(t,{4})'" -f $fontFileFFmpeg, $titleSecondLinePathFFmpeg, $titleSecondLineFontSize, $titleSecondLineY, $titleDurationSeconds)
    ) -join ','
    [IO.File]::WriteAllText($titleFilterPath, $titleFilter, $utf8NoBom)
    $script:ffmpegLogBuffer.Add('')
    $script:ffmpegLogBuffer.Add('[TITLE_FILTER]')
    $script:ffmpegLogBuffer.Add($titleFilter)
    $script:ffmpegLogBuffer.Add(('=' * 80))

    $finalArgs = @(
        '-y',
        '-i', $mergedPath,
        '-filter_script:v', $titleFilterPath
    )
    $finalArgs += $videoCodecArgs
    $finalArgs += @(
        '-pix_fmt', 'yuv420p',
        '-af', "aresample=async=1:first_pts=0",
        '-c:a', 'aac',
        '-b:a', '192k',
        '-ar', "$audioSampleRate",
        '-ac', '2',
        '-shortest',
        '-map', '0:v:0',
        '-map', '0:a:0?',
        $finalTempOutputPath
    )
    Invoke-FFmpegChecked -Arguments $finalArgs -StepName 'Creating final MP4 with title overlay'

    if (Test-Path -Path $outputPath -PathType Leaf) {
        Remove-Item -Path $outputPath -Force
    }
    Move-Item -Path $finalTempOutputPath -Destination $outputPath
}
catch {
    Write-FFmpegLogFile -LogPath $ffmpegLogPath -ResolvedInputFolder $resolvedInputFolder -OutputPath $outputPath -ExceptionMessage $_.Exception.Message
    throw "$($_.Exception.Message) Detailed log: $ffmpegLogPath"
}
finally {
    if (Test-Path -Path $tempProcessingRoot) {
        Remove-Item -Path $tempProcessingRoot -Recurse -Force
    }
}

Write-Host "Done: $outputPath"
