$port = New-Object System.IO.Ports.SerialPort('COM16', 115200, 'None', 8, 'One')
$port.ReadTimeout = 60000
$port.Open()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($sw.Elapsed.TotalSeconds -lt 90) {
        try {
            $line = $port.ReadLine()
            $ts = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Write-Host "[${ts}s] $line"
        } catch [System.TimeoutException] {
            Write-Host '--- timeout waiting for data ---'
        }
    }
} finally {
    $port.Close()
}
