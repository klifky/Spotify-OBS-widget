' run-tray.vbs
' Запускает трей-скрипт без чёрного окна PowerShell
' Скопируй этот файл в shell:startup для автозагрузки

Dim ps
ps = "C:\Users\WINKOI\AppData\Roaming\spicetify\Widget_server\widget-tray.ps1"  ' <-- тот же путь

CreateObject("WScript.Shell").Run _
    "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """", _
    0, False
