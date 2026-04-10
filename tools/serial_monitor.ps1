# Serial Monitor for debugprobe UART bridge
# Usage: powershell -ExecutionPolicy Bypass -File tools\serial_monitor.ps1 -Port COM16 -Baud 115200

param(
    [string]$Port = "COM16",
    [int]$Baud = 115200,
    [int]$TimeoutSec = 60
)

Write-Host "=== Serial Monitor ===" -ForegroundColor Cyan
Write-Host "Port: $Port | Baud: $Baud | Timeout: ${TimeoutSec}s" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host ""

try {
    $serial = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $serial.ReadTimeout = 1000
    $serial.DtrEnable = $true
    $serial.RtsEnable = $true
    $serial.Open()
    Write-Host "[OK] Port $Port opened" -ForegroundColor Green
    
    $startTime = Get-Date
    $dataReceived = $false
    
    while ($true) {
        try {
            $line = $serial.ReadLine()
            if (-not $dataReceived) {
                $dataReceived = $true
                Write-Host "[OK] Receiving data!" -ForegroundColor Green
            }
            $ts = (Get-Date).ToString("HH:mm:ss.fff")
            Write-Host "[$ts] $line"
        }
        catch [System.TimeoutException] {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if (-not $dataReceived -and $elapsed -gt $TimeoutSec) {
                Write-Host "[TIMEOUT] No data received in ${TimeoutSec}s" -ForegroundColor Red
                break
            }
            if (-not $dataReceived) {
                Write-Host "." -NoNewline -ForegroundColor DarkGray
            }
        }
    }
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($serial -and $serial.IsOpen) {
        $serial.Close()
        Write-Host "`n[INFO] Port closed" -ForegroundColor Yellow
    }
}
