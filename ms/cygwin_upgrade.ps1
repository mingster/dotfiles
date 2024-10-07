# Get the ID and security principal of the current user account
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running "as Administrator"
if ($myWindowsPrincipal.IsInRole($adminRole)) {
   # We are running "as Administrator" - so change the title and background color to indicate this
   $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Elevated)"
   $Host.UI.RawUI.BackgroundColor = "DarkBlue"
   clear-host
}
else {
   # We are not running "as Administrator" - so relaunch as administrator

   # Create a new process object that starts PowerShell
   $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";

   # Specify the current script path and name as a parameter
   $newProcess.Arguments = $myInvocation.MyCommand.Definition;

   # Indicate that the process should be elevated
   $newProcess.Verb = "runas";

   # Start the new process
   [System.Diagnostics.Process]::Start($newProcess);

   # Exit from the current, unelevated, process
   exit
}

# Run your code that needs to be elevated here
(new-object System.Net.WebClient).DownloadFile('http://cygwin.com/setup-x86_64.exe','setup-x86_64.exe')

if (!$?) {
   Write-Host "Something wrong happened when downloading the Cygwin installer."
   Write-Host -NoNewLine "Press any key to continue..."
   $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
   exit
}

$p = Start-Process .\setup-x86_64.exe -ArgumentList "--upgrade-also --quiet-mode" -wait -NoNewWindow -PassThru

if ($p.ExitCode -ne 0) {
   Write-Host "Cygwin setup failed with an error!"
}

Remove-Item .\setup-x86_64.exe

Write-Host -NoNewLine "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")