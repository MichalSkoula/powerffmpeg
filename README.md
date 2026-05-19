# powerffmpeg

A PowerShell script that combines all the videos in a specified folder into a single MP4 file. I use it to make monthly videos of my children.

<img width="500" height="375" alt="EXbjFt5XQAMHf8C" src="https://github.com/user-attachments/assets/83fa68ab-8234-4ef3-a1a3-300cb6914e24" />

## What the script does

- loads all videos from the specified folder
- merges them into a single MP4, alphabetically by filename
- adds a 3-second two-line title with a semi-transparent background at the beginning of the final video
- supports `.mp4, .mov, .m4v, .avi, .mkv, .webm`

## Requirements

- PowerShell 7+, ffmpeg in PATH
- Windows: `sudo winget install Gyan.FFmpeg`
- Lignux: `sudo apt install ffmpeg`

## Usage

```powershell
.\video.ps1 -InputFolder "2026-03" -OutputName "My Video.mp4" -FirstLine "Header 1" -SecondLine "Header 2"
```

## Parameters

- `InputFolder` - path to the folder containing videos
- `OutputFolder` - path to the folder where the output video will be saved; if missing, the output video is saved in the input folder
- `OutputName` - output filename; if extension is missing, `.mp4` is added
- `FirstLine` - first line of the opening title
- `SecondLine` - second line of the opening title
