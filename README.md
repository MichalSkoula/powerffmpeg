# powerffmpeg

PowerShell skript pro spojení všech videí ze zadané složky do jednoho MP4 souboru.

## Co skript dělá

- načte všechna videa ze zadané složky
- seřadí je podle názvu abecedně
- sjednotí je na společný formát
- spojí je do jednoho MP4
- na začátek výsledného videa přidá 3sekundový dvouřádkový nadpis se semitransparentním pozadím

## Požadavky

- PowerShell 7+
- `ffmpeg` a `ffprobe` dostupné v `PATH`

## Podporované vstupní formáty

- `.mp4`
- `.mov`
- `.m4v`
- `.avi`
- `.mkv`
- `.webm`

## Použití

```powershell
pwsh ./New-CombinedVideo.ps1 `
  -InputFolder "C:\Videa" `
  -OutputName "finalni-video" `
  -FirstLine "První řádek" `
  -SecondLine "Druhý řádek"
```

## Parametry

- `InputFolder` – cesta ke složce s videi
- `OutputName` – název výstupního souboru; pokud chybí přípona, doplní se `.mp4`
- `FirstLine` – první řádek úvodního nadpisu
- `SecondLine` – druhý řádek úvodního nadpisu
