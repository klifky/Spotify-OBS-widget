# widget-tray.ps1
# Spotify Widget tray manager
# Auto-start: copy run-tray.vbs to shell:startup

$ServerDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile    = Join-Path $ServerDir "widget-tray.log"
$EqScript   = Join-Path $ServerDir "eq_capture.py"
$SmtcScript = Join-Path $ServerDir "smtc_reader.py"
$TrayPort   = 8766

# Find node.exe
$NodeExe = @("node", "$env:ProgramFiles\nodejs\node.exe", "$env:ProgramFiles(x86)\nodejs\node.exe") |
    Where-Object { try { if (Test-Path $_) { $true } else { Get-Command $_ -EA Stop | Out-Null; $true } } catch { $false } } |
    Select-Object -First 1
if (-not $NodeExe) { $NodeExe = "node" }

# Find python
$PythonExe = @("python", "python3") |
    Where-Object { try { Get-Command $_ -EA Stop | Out-Null; $true } catch { $false } } |
    Select-Object -First 1
if (-not $PythonExe) { $PythonExe = "python" }

"[$(Get-Date)] Starting tray. ServerDir=$ServerDir Node=$NodeExe Python=$PythonExe" | Out-File $LogFile -Append

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$serverProcess = $null
$smtcProcess   = $null
$eqProcess     = $null

function Make-Icon($char, $color) {
    $bmp  = New-Object System.Drawing.Bitmap(16, 16)
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $g.DrawString($char, $font, (New-Object System.Drawing.SolidBrush($color)), 0, 1)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$iconOn  = Make-Icon ">" ([System.Drawing.Color]::LimeGreen)
$iconOff = Make-Icon "." ([System.Drawing.Color]::Gray)

$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = $iconOff
$tray.Text    = "Spotify Widget - stopped"
$tray.Visible = $true

$menuStart    = New-Object System.Windows.Forms.ToolStripMenuItem("Start Widget")
$menuStop     = New-Object System.Windows.Forms.ToolStripMenuItem("Stop Widget")
$menuStop.Enabled = $false

$menuEqStart  = New-Object System.Windows.Forms.ToolStripMenuItem("Start Equalizer")
$menuEqStop   = New-Object System.Windows.Forms.ToolStripMenuItem("Stop Equalizer")
$menuEqDevice = New-Object System.Windows.Forms.ToolStripMenuItem("Select capture device...")
$menuEqStop.Enabled = $false

$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$ctx.Items.AddRange(@(
    $menuStart, $menuStop,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $menuEqStart, $menuEqStop, $menuEqDevice,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $menuExit
))
$tray.ContextMenuStrip = $ctx

function Start-Widget {
    if ($script:serverProcess -and -not $script:serverProcess.HasExited) { return "already" }
    $script:serverProcess = Start-Process `
        -FilePath $NodeExe -ArgumentList "server.js" `
        -WorkingDirectory $ServerDir -PassThru -WindowStyle Hidden
    "[$(Get-Date)] Widget started PID=$($script:serverProcess.Id)" | Out-File $LogFile -Append
    Start-Sleep -Milliseconds 800
    if (Test-Path $SmtcScript) {
        $script:smtcProcess = Start-Process `
            -FilePath $PythonExe -ArgumentList "`"$SmtcScript`"" `
            -WorkingDirectory $ServerDir -PassThru -WindowStyle Hidden
        "[$(Get-Date)] SMTC reader started PID=$($script:smtcProcess.Id)" | Out-File $LogFile -Append
    } else {
        "[$(Get-Date)] WARNING: smtc_reader.py not found" | Out-File $LogFile -Append
    }
    $tray.Icon = $script:iconOn
    $tray.Text = "Spotify Widget - running"
    $menuStart.Enabled = $false
    $menuStop.Enabled  = $true
    return "started"
}

function Stop-Widget {
    if (-not $script:serverProcess -or $script:serverProcess.HasExited) { return "already" }
    if ($script:smtcProcess -and -not $script:smtcProcess.HasExited) {
        Stop-Process -Id $script:smtcProcess.Id -Force -EA SilentlyContinue
        $script:smtcProcess = $null
        "[$(Get-Date)] SMTC reader stopped" | Out-File $LogFile -Append
    }
    Stop-Process -Id $script:serverProcess.Id -Force -EA SilentlyContinue
    $script:serverProcess = $null
    $tray.Icon = $script:iconOff
    $tray.Text = "Spotify Widget - stopped"
    $menuStart.Enabled = $true
    $menuStop.Enabled  = $false
    Stop-Eq | Out-Null
    "[$(Get-Date)] Widget stopped" | Out-File $LogFile -Append
    return "stopped"
}

function Get-Status {
    if ($script:serverProcess -and -not $script:serverProcess.HasExited) { return "running" }
    return "stopped"
}

function Start-Eq {
    if ($script:eqProcess -and -not $script:eqProcess.HasExited) { return "already" }
    if (-not (Test-Path $EqScript)) {
        [System.Windows.Forms.MessageBox]::Show("eq_capture.py not found in:`n$ServerDir", "Spotify Widget", "OK", "Warning") | Out-Null
        return "error"
    }
    $script:eqProcess = Start-Process `
        -FilePath $PythonExe -ArgumentList "`"$EqScript`"" `
        -WorkingDirectory $ServerDir -PassThru -WindowStyle Hidden
    $menuEqStart.Enabled = $false
    $menuEqStop.Enabled  = $true
    $menuEqStart.Text    = "Equalizer - running"
    "[$(Get-Date)] EQ started PID=$($script:eqProcess.Id)" | Out-File $LogFile -Append
    return "started"
}

function Stop-Eq {
    if (-not $script:eqProcess -or $script:eqProcess.HasExited) { return "already" }
    Stop-Process -Id $script:eqProcess.Id -Force -EA SilentlyContinue
    $script:eqProcess    = $null
    $menuEqStart.Enabled = $true
    $menuEqStop.Enabled  = $false
    $menuEqStart.Text    = "Start Equalizer"
    "[$(Get-Date)] EQ stopped" | Out-File $LogFile -Append
    return "stopped"
}

function Get-EqStatus {
    if ($script:eqProcess -and -not $script:eqProcess.HasExited) { return "running" }
    return "stopped"
}

function Show-DevicePicker {
    # Write a temp Python script to get device list
    $tmpScript = Join-Path $env:TEMP "eq_list_devices.py"
    $tmpOut    = Join-Path $env:TEMP "eq_devices.json"
@'
import json, sys
try:
    import pyaudiowpatch as pa
    p = pa.PyAudio()
    devs = []
    for i in range(p.get_device_count()):
        d = p.get_device_info_by_index(i)
        if d.get("isLoopbackDevice"):
            devs.append({"index": i, "name": d["name"]})
    p.terminate()
    with open(sys.argv[1], "w") as f:
        json.dump(devs, f)
except Exception as e:
    with open(sys.argv[1], "w") as f:
        json.dump([], f)
'@ | Set-Content $tmpScript -Encoding UTF8

    Start-Process -FilePath $PythonExe -ArgumentList "`"$tmpScript`" `"$tmpOut`"" `
        -Wait -WindowStyle Hidden

    if (-not (Test-Path $tmpOut)) {
        [System.Windows.Forms.MessageBox]::Show("Could not get device list.", "Spotify Widget", "OK", "Warning") | Out-Null
        return
    }

    $devices = Get-Content $tmpOut -Raw | ConvertFrom-Json
    if (-not $devices -or $devices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No loopback devices found.`nIs VB-Audio Virtual Cable installed?", "Spotify Widget", "OK", "Warning") | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select capture device"
    $form.Size = New-Object System.Drawing.Size(420, 170)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Select audio device to capture Spotify:"
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size = New-Object System.Drawing.Size(390, 20)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point(12, 38)
    $combo.Size = New-Object System.Drawing.Size(390, 24)
    $combo.DropDownStyle = "DropDownList"
    $devices | ForEach-Object { $combo.Items.Add($_.name) | Out-Null }

    # Default to CABLE Input if present
    $cableIdx = -1
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
        if ($combo.Items[$i] -like "*CABLE Input*") { $cableIdx = $i; break }
    }
    $combo.SelectedIndex = if ($cableIdx -ge 0) { $cableIdx } else { 0 }

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Select"
    $btnOk.Location = New-Object System.Drawing.Point(230, 90)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)
    $btnOk.DialogResult = "OK"

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(320, 90)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
    $btnCancel.DialogResult = "Cancel"

    $form.Controls.AddRange(@($label, $combo, $btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq "OK") {
        $selected = $devices[$combo.SelectedIndex]
        $config = "{`"device_name`": `"$($selected.name)`"}"
        $config | Set-Content (Join-Path $ServerDir "eq_config.json") -Encoding UTF8
        "[$(Get-Date)] Device saved: $($selected.name)" | Out-File $LogFile -Append
        [System.Windows.Forms.MessageBox]::Show("Device saved:`n$($selected.name)`n`nRestart Equalizer to apply.", "Spotify Widget", "OK", "Information") | Out-Null
        if ((Get-EqStatus) -eq "running") {
            Stop-Eq | Out-Null
            Start-Sleep -Milliseconds 500
            Start-Eq | Out-Null
        }
    }
}

$menuStart.Add_Click({    Start-Widget    | Out-Null })
$menuStop.Add_Click({     Stop-Widget     | Out-Null })
$menuEqStart.Add_Click({  Start-Eq        | Out-Null })
$menuEqStop.Add_Click({   Stop-Eq         | Out-Null })
$menuEqDevice.Add_Click({ Show-DevicePicker })
$menuExit.Add_Click({
    Stop-Widget | Out-Null
    Stop-Eq     | Out-Null
    $tray.Visible = $false
    $listener.Stop()
    [System.Windows.Forms.Application]::Exit()
})

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$TrayPort/")
$listener.Start()
"[$(Get-Date)] HTTP listener started on port $TrayPort" | Out-File $LogFile -Append

$asyncCallback = {
    while ($listener.IsListening) {
        try {
            $ctx  = $listener.GetContext()
            $resp = $ctx.Response
            $resp.Headers.Add("Access-Control-Allow-Origin", "*")
            $resp.ContentType = "application/json"
            $result = switch ($ctx.Request.Url.AbsolutePath) {
                "/toggle"    { Toggle-Widget }
                "/start"     { Start-Widget  }
                "/stop"      { Stop-Widget   }
                "/status"    { Get-Status    }
                "/eq/start"  { Start-Eq      }
                "/eq/stop"   { Stop-Eq       }
                "/eq/status" { Get-EqStatus  }
                default      { "unknown"     }
            }
            $body = [System.Text.Encoding]::UTF8.GetBytes("{`"status`":`"$result`"}")
            $resp.ContentLength64 = $body.Length
            $resp.OutputStream.Write($body, 0, $body.Length)
            $resp.OutputStream.Close()
        } catch { }
    }
}

$runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable("listener",  $listener)
$runspace.SessionStateProxy.SetVariable("ServerDir", $ServerDir)
$runspace.SessionStateProxy.SetVariable("NodeExe",   $NodeExe)
$runspace.SessionStateProxy.SetVariable("tray",      $tray)
$runspace.SessionStateProxy.SetVariable("iconOn",    $iconOn)
$runspace.SessionStateProxy.SetVariable("iconOff",   $iconOff)
$runspace.SessionStateProxy.SetVariable("menuStart", $menuStart)
$runspace.SessionStateProxy.SetVariable("menuStop",  $menuStop)

$ps2 = [System.Management.Automation.PowerShell]::Create()
$ps2.Runspace = $runspace
$ps2.AddScript($asyncCallback) | Out-Null
$ps2.BeginInvoke() | Out-Null

"[$(Get-Date)] Tray ready" | Out-File $LogFile -Append
[System.Windows.Forms.Application]::Run()

$listener.Stop()
$tray.Visible = $false
