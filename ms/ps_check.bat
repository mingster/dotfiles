Set-ExecutionPolicy unrestricted
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass -Force;
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted -Force;

Get-ExecutionPolicy


powershell.exe -noprofile -executionpolicy bypass -file .\cygwin_upgrade.ps1