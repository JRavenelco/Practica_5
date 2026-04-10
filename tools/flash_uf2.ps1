$vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'RPI-RP2' }
if ($vol) {
    $drive = $vol.DriveLetter + ":\"
    Write-Host "Found RPI-RP2 at drive $drive"
    Copy-Item '.\build\uart_test.uf2' -Destination $drive -Force
    Write-Host "UF2 copied successfully!"
} else {
    Write-Host "ERROR: RPI-RP2 drive not found. Is Pico in BOOTSEL mode?"
    exit 1
}
