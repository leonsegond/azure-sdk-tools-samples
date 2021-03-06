<#
.Synopsis
   Do the Windows update of the VMs deployed to the given service.
.DESCRIPTION
   Uses psexec.exe from sysinternals to run Windows Update on the VMs in sequence.
.EXAMPLE
    Update-AzureWindowsVm.ps1 -ServiceName aService
.INPUTS
   None
.OUTPUTS
   None
#>
param
(
    
    # Name of the service the VMs will be updated
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName
)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# Check if Windows Azure Powershell is avaiable
if ((Get-Module -ListAvailable Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please install from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

<#
.SYNOPSIS
   Installs a WinRm certificate to the local store
.DESCRIPTION
   Gets the WinRM certificate from the Virtual Machine in the Service Name specified, and 
   installs it on the Current User's personal store.
.EXAMPLE
    Install-WinRmCertificate -ServiceName testservice -vmName testVm
.INPUTS
   None
.OUTPUTS
   None
#>
function Install-WinRmCertificate($ServiceName, $VMName)
{
    $vm = Get-AzureVM -ServiceName $ServiceName -Name $VMName
    $winRmCertificateThumbprint = $vm.VM.DefaultWinRMCertificateThumbprint
    
    $winRmCertificate = Get-AzureCertificate -ServiceName $ServiceName -Thumbprint $winRmCertificateThumbprint -ThumbprintAlgorithm sha1
    
    $installedCert = Get-Item Cert:\CurrentUser\My\$winRmCertificateThumbprint -ErrorAction SilentlyContinue
    
    if ($installedCert -eq $null)
    {
        $certBytes = [System.Convert]::FromBase64String($winRmCertificate.Data)
        $x509Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate
        $x509Cert.Import($certBytes)
        
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
        $store.Open("ReadWrite")
        $store.Add($x509Cert)
        $store.Close()
    }
}

$vms = Get-AzureVM -ServiceName $ServiceName

$credential = Get-Credential

$updateScriptContent = '
$updateSession = New-Object -ComObject ''Microsoft.Update.Session''
    $updateSession.ClientApplicationID = ''Install Windows Updates via PowerShell''
    $rebootRequired = $false

    $updateSearcher = $UpdateSession.CreateUpdateSearcher()
    $searchQuery = "IsInstalled=0 and Type=''Software''"

    $searchResult = $updateSearcher.Search($searchQuery)

    if($searchResult.Updates.Count -gt 0)
    {
        $updatesToDownload = New-Object -ComObject ''Microsoft.Update.UpdateColl''

        foreach ($update in $searchResult.Updates) 
        {
            if (!$update.InstallationBehavior.CanRequestUserInput)
            {
                if ($update.EulaAccepted -eq $false)
                {
                    $update.AcceptEula()
                }

                $updatesToDownload.Add($update) | Out-Null
            }
        }

        if ($updatesToDownload.Count -gt 0) 
        {
            $downloader = $updateSession.CreateUpdateDownloader()
            $downloader.Updates = $updatesToDownload
            $downloader.Download() | Out-Null
        }

        $updatesToInstall = New-Object -ComObject ''Microsoft.Update.UpdateColl''
        $rebootRequired = $false
                   
        foreach ($update in $searchResult.Updates) 
        {
            if ($update.IsDownloaded) 
            {
                $updatesToInstall.Add($update) | Out-Null

                if ($update.InstallationBehavior.RebootBehavior -gt 0)
                {
                    $rebootRequired = $true
                }
            }
        }

        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $updatesToInstall
        $installationResult = $installer.Install()

        if ($installationResult.RebootRequired) 
        {
            $rebootRequired = $true
        }

        if($rebootRequired -or $ForceReboot)
        {
            Restart-Computer
        }
    }
    else
    {
        Write-Warning "No windows updates found"
    }
'

$remoteScript = {
    param ($updateScriptContent)
    
    $VerbosePreference = "Continue"
    
    $updateUtilsFolder = "c:\UpdateUtils"
    $psExec = "psexec.exe"
    $updateScript = "Update-Computer.ps1"
    
    # Create the update utils folder if not created
    if (!(Test-Path $updateUtilsFolder))
    {
        New-Item -ItemType Directory -Force -Path $updateUtilsFolder | Out-Null
    }
    
    # Download the sysinternals utilities. The WSUS interface (IUpdateSession) required to download updates 

    # does not support running it remotely. Please see

    # http://msdn.microsoft.com/en-us/library/windows/desktop/aa386862(v=vs.85).aspx

    # thus we will be using the psexec.exe tool to run a script locally.
    if (!(Test-Path "$updateUtilsFolder\$psExec"))
    {      
        $psToolsSource = "http://download.sysinternals.com/files/PSTools.zip"
        $zipFilePath = "$updateUtilsFolder\PSTools.zip"
        
        Invoke-WebRequest -Uri $psToolsSource -OutFile $zipFilePath
        
        $shellApp = New-Object -com shell.application
        $destination = $shellApp.namespace($updateUtilsFolder)
        $destination.Copyhere($shellApp.namespace($zipFilePath).items())
        Write-Verbose "Downloaded pstools"
    }
    
    # Copy the update script if not already there
    $updateScriptPath = "$updateUtilsFolder\$updateScript"
    if (!(Test-Path $updateScriptPath))
    {
        $updateScriptContent | Out-File -Encoding ASCII -FilePath $updateScriptPath 
        Write-Verbose "Created the update script"
    }
    
    # Copy the update script runner if not already there
    $runUpdateCmdFileName = "runupdate.cmd"
    $updateCmdFilePath = "$updateUtilsFolder\$runUpdateCmdFileName"
    if (!(Test-Path $updateCmdFilePath))
    {        
        $updateCmdFileContent += "C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy RemoteSigned "
        $updateCmdFileContent += "-File $updateScriptPath >> Out.txt"
        $updateCmdFileContent | Out-File -Encoding ASCII -FilePath "$updateCmdFilePath" 
        Write-Verbose "Created the update cmd file"
    }
    
    # Start a local process to do the update
    cd $updateUtilsFolder
    Start-Process -FilePath .\PsExec.exe -ArgumentList "-accepteula -s -i \\$env:COMPUTERNAME $updateCmdFilePath" -Verb RunAs -Wait
    Write-Verbose "Update process finished."
}

foreach ($vm in $vms)
{
    # prepare to run the remote execution
    
    # Get the RemotePS/WinRM Uri to connect to
    $vmWinRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $vm.Name    
    
    Install-WinRmCertificate $ServiceName $vm.Name
    
    Write-Verbose "Update will run on $($vm.Name)"
    Invoke-Command -ConnectionUri $vmWinRmUri.ToString() -Credential $credential -ScriptBlock $remoteScript -ArgumentList $updateScriptContent
    
    # Wait a while to see if the VM is restarting
    Write-Verbose "Waiting for 60 seconds for the VM's status update"
    Start-Sleep -Seconds 60
    
    # And wait until it restarts
    do
    {
        Start-Sleep -Seconds 15
        Write-Verbose "Checking the status of $($vm.Name)"
        $updatedVm = Get-AzureVM -ServiceName $ServiceName -Name $vm.Name
        Write-Verbose "PowerState of $($updatedVm.Name) is $($updatedVm.PowerState)"
    }
    until ($updatedVm.PowerState -eq "Started")
}
