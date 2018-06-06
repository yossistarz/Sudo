<#
    .SYNOPSIS
        Restores WSMan and CredSSP settings to what they were prior to running the 'New-SudoSession' or 'Start-SudoSession'
        functions.

        IMPORTANT NOTE: You would use this function as opposed to the 'Remove-SudoSession' function under the following circumstance:
            - You use the New-SudoSession with the -KeepOpen switch in a PowerShell Process we'll call 'A'
            - PowerShell Process 'A' is killed/closed unexpectedly prior to the user running the Remove-SudoSession function
            - PowerShell Process 'B' is started, the Sudo Module is imported, and this Restore-OriginalSystemConfig function
            is used to revert WSMAN/CredSSP config changes made by the New-SudoSession function in PowerShell Process 'A'

    .DESCRIPTION
        See .SYNOPSIS

    .PARAMETER ExistingSudoSession
        Unless you are using the -ForceCredSSPReset switch, this parameter is MANDATORY.

        This parameter takes a System.Management.Automation.Runspaces.PSSession object.

    .PARAMETER SudoSessionChangesLogFilePath
        Unless you are using the -ForceCredSSPReset switch, this parameter is MANDATORY.

        This parameter taks a path to the .xml file generated by the New-SudoSession or Start-SudoSession functins
        that logs exactly what changes to WSMan and CredSSP were made. The file name for this file defaults to the
        format 'SudoSession_Config_Changes_<User>_<MMddyyyy>_<hhmmss>.xml'

    .PARAMETER OriginalConfigInfo
        This parameter is OPTIONAL.

        This parameter takes a PSCustomObject that can be found in the "WSManAndRegistryChanges" property of the
        PSCustomObject generated by the New-SudoSession function. The "WSManAndRegistryChanges" property is itself a
        PSCustomObject with the following properties:
            [bool]WinRMStateChange
            [bool]WSMANServerCredSSPStateChange
            [bool]WSMANClientCredSSPStateChange
            [System.Collections.ArrayList]RegistryKeyCreated
            [System.Collections.ArrayList]RegistryKeyPropertiesCreated

    .PARAMETER UserName
        This parameter is OPTIONAL.

        This parameter takes a string and defaults to the Current User.

        If you are running the Restore-OriginalSystemConfig function from a non-elevated PowerShell session, then credentials
        with Adminstrator privileges must be provided in order to revert the WSMan and CredSSP changes that were made by the
        New-SudoSession and/or the Start-SudoSession functions.

    .PARAMETER Password
        This parameter is OPTIONAL.

        This parameter takes a SecureString. It should only be used if this function is being run from a non-elevated PowerShell
        Session and if the -Credentials parameter is NOT used.

        If you are running the Restore-OriginalSystemConfig function from a non-elevated PowerShell session, then credentials
        with Adminstrator privileges must be provided in order to revert the WSMan and CredSSP changes that were made by the
        New-SudoSession and/or the Start-SudoSession functions.

    .PARAMETER Credentials
        This parameter is OPTIONAL.

        This parameter takes a System.Management.Automation.PSCredential. It should only be used if this function is being run from
        a non-elevated PowerShell Session and if the -Password parameter is NOT used.

        If you are running the Restore-OriginalSystemConfig function from a non-elevated PowerShell session, then credentials
        with Adminstrator privileges must be provided in order to revert the WSMan and CredSSP changes that were made by the
        New-SudoSession and/or the Start-SudoSession functions.

    .PARAMETER ForceCredSSPReset
        This parameter is OPTIONAL.

        This parameter is a switch.

        If used, all CredSSP settings will be set to disallow CredSSP authentication regardless of current system configuration state.

    .EXAMPLE
        PS C:\Users\zeroadmin> $SudoSessionInfo = New-SudoSession -Credentials $MyCreds
        PS C:\Users\zeroadmin> Remove-SudoSession -Credentials $MyCreds -OriginalConfigInfo $SudoSessionInfo.WSManAndRegistryChanges -SessionToRemove $SudoSessionInfo.ElevatedPSSession

#>
# Just in case the PowerShell Session in which you originally created the SudoSession is killed/interrupted,
# you can use this function to revert WSMAN/Registry changes that were made with the New-SudoSession function.
# Example:
#   Restore-OriginalSystemConfig -SudoSessionChangesLogFilePath "$HOME\SudoSession_04182018\SudoSession_Config_Changes_04182018_082747.xml"
function Restore-OriginalSystemConfig {
    [CmdletBinding(DefaultParameterSetName='Supply UserName and Password')]
    Param(
        [Parameter(Mandatory=$False)]
        [System.Management.Automation.Runspaces.PSSession]$ExistingSudoSession,

        [Parameter(Mandatory=$False)]
        [string]$SudoSessionChangesLogFilePath,

        [Parameter(Mandatory=$False)]
        $OriginalConfigInfo,

        [Parameter(
            Mandatory=$False,
            ParameterSetName='Supply UserName and Password'
        )]
        [string]$UserName,

        [Parameter(
            Mandatory=$False,
            ParameterSetName='Supply UserName and Password'
        )]
        [securestring]$Password,

        [Parameter(
            Mandatory=$False,
            ParameterSetName='Supply Credentials'
        )]
        [System.Management.Automation.PSCredential]$Credentials,

        [Parameter(Mandatory=$False)]
        [switch]$ForceCredSSPReset
    )

    # CredSSP Reset In Case of Emergency
    if ($ForceCredSSPReset) {
        $CredSSPRegistryKey = Get-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\CredentialsDelegation" -ErrorAction SilentlyContinue

        if ($CredSSPRegistryKey) {
            Remove-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\CredentialsDelegation" -Recurse -Force

            [pscustomobject]@{
                RegistryKeysRemoved = @($CredSSPRegistryKey)
            }
        }
        else {
            Write-Warning "CredSSP is not enabled. No action taken."
        }
        
        return
    }

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    if ($(!$SudoSessionChangesLogFilePath -and !$OriginalConfigInfo) -or $($SudoSessionChangesLogFilePath -and $OriginalConfigInfo)) {
        Write-Error "The $($MyInvocation.MyCommand.Name) function requires either the -SudoSessionChangesLogFilePath parameter or the -OriginalConfigInfoParameter! Halting!"
        $global:FunctionResult = "1"
        return
    }

    if ($SudoSessionChangesLogFilePath) {
        # First, ingest SudoSessionChangesLogFilePath
        if (!$(Test-Path $SudoSessionChangesLogFilePath)) {
            Write-Error "The path $SudoSessionChangesLogFilePath was not found! Halting!"
            $global:FunctionResult = "1"
            return
        }
        else {
            $OriginalConfigInfo = Import-CliXML $SudoSessionChangesLogFilePath
        }
    }

    # Validate $OriginalConfigInfo
    if ($OriginalConfigInfo) {
        $ValidNoteProperties = @("RegistryKeyPropertiesCreated","RegistryKeysCreated","WinRMStateChange","WSMANServerCredSSPStateChange","WSMANClientCredSSPStateChange")
        $ParamObjNoteProperties = $($OriginalConfigInfo | Get-Member -Type NoteProperty).Name
        foreach ($Prop in $ParamObjNoteProperties) {
            if ($ValidNoteProperties -notcontains $Prop) {
                if ($PSBoundParameters['SudoSessionChangesLogFilePath']) {
                    $ErrMsg = "The `$OriginalConfigInfo Object derived from the '$SudoSessionChangesLogFilePath' file is not valid! Halting!"
                }
                if ($PSBoundParameters['OriginalConfigInfo']) {
                    $ErrMsg = "The `$OriginalConfigInfo Object passed to the -OriginalConfigInfo parameter is not valid! Halting!"
                }
                Write-Error $ErrMsg
                $global:FunctionResult = "1"
                return
            }
        }
    }

    $CurrentUser = $($(GetCurrentUser) -split "\\")[-1]
    $SudoSessionFolder = "$HOME\SudoSession_$CurrentUser`_$(Get-Date -Format MMddyyy)"
    if (!$(Test-Path $SudoSessionFolder)) {
        $SudoSessionFolder = $(New-Item -ItemType Directory -Path $SudoSessionFolder).FullName
    }
    $SudoSessionRevertChangesPSObject = "$SudoSessionFolder\SudoSession_Config_Revert_Changes_$CurrentUser`_$(Get-Date -Format MMddyyy_hhmmss).xml"

    if (!$UserName) {
        $UserName = GetCurrentUser
    }

    if (!$(GetElevation)) {
        if ($global:SudoCredentials) {
            if (!$Credentials) {
                if ($Username -match "\\") {
                    $UserName = $($UserName -split "\\")[-1]
                }
                if ($global:SudoCredentials.UserName -match "\\") {
                    $SudoUserName = $($global:SudoCredentials.UserName -split "\\")[-1]
                }
                else {
                    $SudoUserName = $global:SudoCredentials.UserName
                }
                if ($SudoUserName -match $UserName) {
                    $Credentials = $global:SudoCredentials
                }
            }
            else {
                if ($global:SudoCredentials.UserName -ne $Credentials.UserName) {
                    $global:SudoCredentials = $Credentials
                }
            }
        }
    
        if (!$Credentials) {
            if (!$Password) {
                $Password = Read-Host -Prompt "Please enter the password for $UserName" -AsSecureString
            }
            $Credentials = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $UserName, $Password
        }
    
        if ($Credentials.UserName -match "\\") {
            $UserName = $($Credentials.UserName -split "\\")[-1]
        }
        if ($Username -match "\\") {
            $UserName = $($UserName -split "\\")[-1]
        }
    
        $global:SudoCredentials = $Credentials
    }
    
    ##### END Variable/Parameter Transforms and PreRun Prep #####

    ##### BEGIN Main Body #####

    if (GetElevation) {
        # Collect $Output as we go...
        $Output = [ordered]@{}

        if ($OriginalConfigInfo.WSMANServerCredSSPStateChange) {
            Set-Item -Path "WSMan:\localhost\Service\Auth\CredSSP" -Value false
            $Output.Add("CredSSPServer","Off")
        }
        if ($OriginalConfigInfo.WSMANClientCredSSPStateChange) {
            Set-Item -Path "WSMan:\localhost\Client\Auth\CredSSP" -Value false
            $Output.Add("CredSSPClient","Off")
        }
        if ($OriginalConfigInfo.WinRMStateChange) {
            if ([bool]$(Test-WSMan -ErrorAction SilentlyContinue)) {
                try {
                    Disable-PSRemoting -Force -ErrorAction Stop -WarningAction SilentlyContinue
                    $Output.Add("PSRemoting","Disabled")
                    Stop-Service winrm -ErrorAction Stop
                    $Output.Add("WinRMService","Stopped")
                    Set-Item "WSMan:\localhost\Service\AllowRemoteAccess" -Value false -ErrorAction Stop
                    $Output.Add("WSMANServerAllowRemoteAccess",$False)
                }
                catch {
                    Write-Error $_
                    if ($Output.Count -gt 0) {[pscustomobject]$Output}
                    $global:FunctionResult = "1"
                    return
                }
            }
        }

        if ($OriginalConfigInfo.RegistryKeyPropertiesCreated.Count -gt 0) {
            [System.Collections.ArrayList]$RegistryKeyPropertiesRemoved = @()

            foreach ($Property in $OriginalConfigInfo.RegistryKeyPropertiesCreated) {
                $PropertyName = $($Property | Get-Member -Type NoteProperty | Where-Object {$_.Name -notmatch "PSPath|PSParentPath|PSChildName|PSDrive|PSProvider"}).Name
                $PropertyPath = $Property.PSPath

                if (Test-Path $PropertyPath) {
                    if ([bool]$(Get-ItemProperty -Path $PropertyPath -Name $PropertyName -ErrorAction SilentlyContinue)) {
                        Remove-ItemProperty -Path $PropertyPath -Name $PropertyName
                        $null = $RegistryKeyPropertiesRemoved.Add($Property)
                    }
                }
            }

            $Output.Add("RegistryKeyPropertiesRemoved",$RegistryKeyPropertiesRemoved)
        }

        if ($OriginalConfigInfo.RegistryKeysCreated.Count -gt 0) {
            [System.Collections.ArrayList]$RegistryKeysRemoved = @()

            foreach ($RegKey in $OriginalConfigInfo.RegistryKeysCreated) {
                $RegPath = $RegKey.PSPath

                if (Test-Path $RegPath) {
                    Remove-Item $RegPath -Recurse -Force
                    $null = $RegistryKeysRemoved.Add($RegKey)
                }
            }

            $Output.Add("RegistryKeysRemoved",$RegistryKeysRemoved)
        }

        if ($Output.Count -gt 0) {
            $Output.Add("RevertConfigChangesFilePath",$SudoSessionRevertChangesPSObject)

            $FinalOutput = [pscustomobject]$Output
            $FinalOutput | Export-CliXml $SudoSessionRevertChangesPSObject
        }
    }
    
    if (!$(GetElevation) -and $ExistingSudoSession) {
        if ($ExistingSudoSession.State -eq "Opened") {
            $SystemConfigSB = {
                $OriginalConfigInfo = $using:OriginalConfigInfo

                # Collect $Output as we go...
                $Output = [ordered]@{}

                if ($OriginalConfigInfo.WSMANServerCredSSPStateChange) {
                    Set-Item -Path "WSMan:\localhost\Service\Auth\CredSSP" -Value false
                    $Output.Add("CredSSPServer","Off")
                }
                if ($OriginalConfigInfo.WSMANClientCredSSPStateChange) {
                    Set-Item -Path "WSMan:\localhost\Client\Auth\CredSSP" -Value false
                    $Output.Add("CredSSPClient","Off")
                }
                if ($OriginalConfigInfo.WinRMStateChange) {
                    if ([bool]$(Test-WSMan -ErrorAction SilentlyContinue)) {
                        try {
                            Disable-PSRemoting -Force -ErrorAction Stop -WarningAction SilentlyContinue
                            $Output.Add("PSRemoting","Disabled")
                            Stop-Service winrm -ErrorAction Stop
                            $Output.Add("WinRMService","Stopped")
                            Set-Item "WSMan:\localhost\Service\AllowRemoteAccess" -Value false -ErrorAction Stop
                            $Output.Add("WSMANServerAllowRemoteAccess",$False)
                        }
                        catch {
                            Write-Error $_
                            if ($Output.Count -gt 0) {[pscustomobject]$Output}
                            $global:FunctionResult = "1"
                            return
                        }
                    }
                }
        
                if ($OriginalConfigInfo.RegistryKeyPropertiesCreated.Count -gt 0) {
                    [System.Collections.ArrayList]$RegistryKeyPropertiesRemoved = @()

                    foreach ($Property in $OriginalConfigInfo.RegistryKeyPropertiesCreated) {
                        $PropertyName = $($Property | Get-Member -Type NoteProperty | Where-Object {$_.Name -notmatch "PSPath|PSParentPath|PSChildName|PSDrive|PSProvider"}).Name
                        $PropertyPath = $Property.PSPath
        
                        if (Test-Path $PropertyPath) {
                            if ([bool]$(Get-ItemProperty -Path $PropertyPath -Name $PropertyName -ErrorAction SilentlyContinue)) {
                                Remove-ItemProperty -Path $PropertyPath -Name $PropertyName
                                $null = $RegistryKeyPropertiesRemoved.Add($Property)
                            }
                        }
                    }

                    $Output.Add("RegistryKeyPropertiesRemoved",$RegistryKeyPropertiesRemoved)
                }
        
                if ($OriginalConfigInfo.RegistryKeysCreated.Count -gt 0) {
                    [System.Collections.ArrayList]$RegistryKeysRemoved = @()

                    foreach ($RegKey in $OriginalConfigInfo.RegistryKeysCreated) {
                        $RegPath = $RegKey.PSPath
        
                        if (Test-Path $RegPath) {
                            Remove-Item $RegPath -Recurse -Force
                            $null = $RegistryKeysRemoved.Add($RegKey)
                        }
                    }

                    $Output.Add("RegistryKeysRemoved",$RegistryKeysRemoved)
                }

                if ($Output.Count -gt 0) {
                    [pscustomobject]$Output
                }
            }

            $FinalOutput = Invoke-Command -Session $ExistingSudoSession -Scriptblock $SystemConfigSB
            $FinalOutput | Export-CliXml $SudoSessionRevertChangesPSObject
        }
        else {
            $useAltMethod = $True
        }
    }

    if ($(!$(GetElevation) -and !$ExistingSudoSession) -or $UseAltMethod) {
        [System.Collections.ArrayList]$SystemConfigScript = @()

        $Line = '$Output = [ordered]@{}'
        $null = $SystemConfigScript.Add($Line)

        if ($OriginalConfigInfo.WSMANServerCredSSPStateChange) {
            $Line = 'Set-Item -Path "WSMan:\localhost\Service\Auth\CredSSP" -Value false'
            $null = $SystemConfigScript.Add($Line)
            $Line = '$Output.Add("CredSSPServer","Off")'
            $null = $SystemConfigScript.Add($Line)
        }
        if ($OriginalConfigInfo.WSMANClientCredSSPStateChange) {
            $Line = 'Set-Item -Path "WSMan:\localhost\Client\Auth\CredSSP" -Value false'
            $null = $SystemConfigScript.Add($Line)
            $Line = '$Output.Add("CredSSPClient","Off")'
            $null = $SystemConfigScript.Add($Line)
        }
        if ($OriginalConfigInfo.WinRMStateChange) {
            if ([bool]$(Test-WSMan -ErrorAction SilentlyContinue)) {
                $AdditionalLines = @(
                    'try {'
                    '    Disable-PSRemoting -Force -ErrorAction Stop -WarningAction SilentlyContinue'
                    '    $Output.Add("PSRemoting","Disabled")'
                    '    Stop-Service winrm -ErrorAction Stop'
                    '    $Output.Add("WinRMService","Stopped")'
                    '    Set-Item "WSMan:\localhost\Service\AllowRemoteAccess" -Value false -ErrorAction Stop'
                    '    $Output.Add("WSMANServerAllowRemoteAccess",$False)'
                    '}'
                    'catch {'
                    '    Write-Error $_'
                    '    if ($Output.Count -gt 0) {[pscustomobject]$Output}'
                    '    $global:FunctionResult = "1"'
                    '    return'
                    '}'
                )
                foreach ($AdditionalLine in $AdditionalLines) {
                    $null = $SystemConfigScript.Add($AdditionalLine)
                }
            }
        }

        if ($OriginalConfigInfo.RegistryKeyPropertiesCreated.Count -gt 0) {
            $Line = '[System.Collections.ArrayList]$RegistryKeyPropertiesRemoved = @()'
            $null = $SystemConfigScript.Add($Line)

            foreach ($Property in $OriginalConfigInfo.RegistryKeyPropertiesCreated) {
                $PropertyName = $($Property | Get-Member -Type NoteProperty | Where-Object {$_.Name -notmatch "PSPath|PSParentPath|PSChildName|PSDrive|PSProvider"}).Name
                $PropertyPath = $Property.PSPath

                if (Test-Path $PropertyPath) {
                    $MoreLinesToAdd = @(
                        "if ([bool](Get-ItemProperty -Path '$PropertyPath' -Name '$PropertyName' -EA SilentlyContinue)) {"
                        "    `$null = `$RegistryKeyPropertiesRemoved.Add((Get-ItemProperty -Path '$PropertyPath' -Name '$PropertyName'))"
                        "    Remove-ItemProperty -Path '$PropertyPath' -Name '$PropertyName'"
                        "}"
                    )

                    foreach ($Line in $MoreLinesToAdd) {
                        $null = $SystemConfigScript.Add($Line)
                    }
                }
            }

            $Line = '$Output.Add("RegistryKeyPropertiesRemoved",$RegistryKeyPropertiesRemoved)'
            $null = $SystemConfigScript.Add($Line)
        }

        if ($OriginalConfigInfo.RegistryKeysCreated.Count -gt 0) {
            $Line = '[System.Collections.ArrayList]$RegistryKeysRemoved = @()'
            $null = $SystemConfigScript.Add($Line)

            foreach ($RegKey in $OriginalConfigInfo.RegistryKeysCreated) {
                $RegPath = $RegKey.PSPath

                if (Test-Path $RegPath) {
                    $Line = "if ([bool](Get-Item '$RegPath' -EA SilentlyContinue)) {`$null = `$RegistryKeysRemoved.Add((Get-Item '$RegPath'))}"
                    $null = $SystemConfigScript.Add($Line)
                    $Line = "Remove-Item '$RegPath' -Recurse -Force"
                    $null = $SystemConfigScript.Add($Line)
                }
            }

            $Line = '$Output.Add("RegistryKeysRemoved",$RegistryKeysRemoved)'
            $null = $SystemConfigScript.Add($Line)
        }

        $AdditionalLines = @(
            'if ($Output.Count -gt 0) {'
            "    `$Output.Add('RevertConfigChangesFilePath','$SudoSessionRevertChangesPSObject')"
            "    [pscustomobject]`$Output | Export-CliXml '$SudoSessionRevertChangesPSObject'"
            '}'
        )
        foreach ($AdditionalLine in $AdditionalLines) {
            $null = $SystemConfigScript.Add($AdditionalLine)
        }

        $SystemConfigScriptFilePath = "$SudoSessionFolder\SystemConfigScript.ps1"
        $SystemConfigScript | Set-Content $SystemConfigScriptFilePath

        # IMPORTANT NOTE: You CANNOT use the RunAs Verb if UseShellExecute is $false, and you CANNOT use
        # RedirectStandardError or RedirectStandardOutput if UseShellExecute is $true, so we have to write
        # output to a file temporarily
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = "powershell.exe"
        $ProcessInfo.RedirectStandardError = $false
        $ProcessInfo.RedirectStandardOutput = $false
        $ProcessInfo.UseShellExecute = $true
        $ProcessInfo.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"& $SystemConfigScriptFilePath`""
        $ProcessInfo.Verb = "RunAs"
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        $Process.Start() | Out-Null
        $Process.WaitForExit()
        
        $FinalOutput = Import-CliXML $SudoSessionRevertChangesPSObject
    }

    $FinalOutput

    ##### END Main Body #####
        
}























# SIG # Begin signature block
# MIIMiAYJKoZIhvcNAQcCoIIMeTCCDHUCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUQGa7ZUSt6q6tohd9WquBp/Sm
# pyKgggn9MIIEJjCCAw6gAwIBAgITawAAAB/Nnq77QGja+wAAAAAAHzANBgkqhkiG
# 9w0BAQsFADAwMQwwCgYDVQQGEwNMQUIxDTALBgNVBAoTBFpFUk8xETAPBgNVBAMT
# CFplcm9EQzAxMB4XDTE3MDkyMDIxMDM1OFoXDTE5MDkyMDIxMTM1OFowPTETMBEG
# CgmSJomT8ixkARkWA0xBQjEUMBIGCgmSJomT8ixkARkWBFpFUk8xEDAOBgNVBAMT
# B1plcm9TQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDCwqv+ROc1
# bpJmKx+8rPUUfT3kPSUYeDxY8GXU2RrWcL5TSZ6AVJsvNpj+7d94OEmPZate7h4d
# gJnhCSyh2/3v0BHBdgPzLcveLpxPiSWpTnqSWlLUW2NMFRRojZRscdA+e+9QotOB
# aZmnLDrlePQe5W7S1CxbVu+W0H5/ukte5h6gsKa0ktNJ6X9nOPiGBMn1LcZV/Ksl
# lUyuTc7KKYydYjbSSv2rQ4qmZCQHqxyNWVub1IiEP7ClqCYqeCdsTtfw4Y3WKxDI
# JaPmWzlHNs0nkEjvnAJhsRdLFbvY5C2KJIenxR0gA79U8Xd6+cZanrBUNbUC8GCN
# wYkYp4A4Jx+9AgMBAAGjggEqMIIBJjASBgkrBgEEAYI3FQEEBQIDAQABMCMGCSsG
# AQQBgjcVAgQWBBQ/0jsn2LS8aZiDw0omqt9+KWpj3DAdBgNVHQ4EFgQUicLX4r2C
# Kn0Zf5NYut8n7bkyhf4wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDgYDVR0P
# AQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUdpW6phL2RQNF
# 7AZBgQV4tgr7OE0wMQYDVR0fBCowKDAmoCSgIoYgaHR0cDovL3BraS9jZXJ0ZGF0
# YS9aZXJvREMwMS5jcmwwPAYIKwYBBQUHAQEEMDAuMCwGCCsGAQUFBzAChiBodHRw
# Oi8vcGtpL2NlcnRkYXRhL1plcm9EQzAxLmNydDANBgkqhkiG9w0BAQsFAAOCAQEA
# tyX7aHk8vUM2WTQKINtrHKJJi29HaxhPaHrNZ0c32H70YZoFFaryM0GMowEaDbj0
# a3ShBuQWfW7bD7Z4DmNc5Q6cp7JeDKSZHwe5JWFGrl7DlSFSab/+a0GQgtG05dXW
# YVQsrwgfTDRXkmpLQxvSxAbxKiGrnuS+kaYmzRVDYWSZHwHFNgxeZ/La9/8FdCir
# MXdJEAGzG+9TwO9JvJSyoGTzu7n93IQp6QteRlaYVemd5/fYqBhtskk1zDiv9edk
# mHHpRWf9Xo94ZPEy7BqmDuixm4LdmmzIcFWqGGMo51hvzz0EaE8K5HuNvNaUB/hq
# MTOIB5145K8bFOoKHO4LkTCCBc8wggS3oAMCAQICE1gAAAH5oOvjAv3166MAAQAA
# AfkwDQYJKoZIhvcNAQELBQAwPTETMBEGCgmSJomT8ixkARkWA0xBQjEUMBIGCgmS
# JomT8ixkARkWBFpFUk8xEDAOBgNVBAMTB1plcm9TQ0EwHhcNMTcwOTIwMjE0MTIy
# WhcNMTkwOTIwMjExMzU4WjBpMQswCQYDVQQGEwJVUzELMAkGA1UECBMCUEExFTAT
# BgNVBAcTDFBoaWxhZGVscGhpYTEVMBMGA1UEChMMRGlNYWdnaW8gSW5jMQswCQYD
# VQQLEwJJVDESMBAGA1UEAxMJWmVyb0NvZGUyMIIBIjANBgkqhkiG9w0BAQEFAAOC
# AQ8AMIIBCgKCAQEAxX0+4yas6xfiaNVVVZJB2aRK+gS3iEMLx8wMF3kLJYLJyR+l
# rcGF/x3gMxcvkKJQouLuChjh2+i7Ra1aO37ch3X3KDMZIoWrSzbbvqdBlwax7Gsm
# BdLH9HZimSMCVgux0IfkClvnOlrc7Wpv1jqgvseRku5YKnNm1JD+91JDp/hBWRxR
# 3Qg2OR667FJd1Q/5FWwAdrzoQbFUuvAyeVl7TNW0n1XUHRgq9+ZYawb+fxl1ruTj
# 3MoktaLVzFKWqeHPKvgUTTnXvEbLh9RzX1eApZfTJmnUjBcl1tCQbSzLYkfJlJO6
# eRUHZwojUK+TkidfklU2SpgvyJm2DhCtssFWiQIDAQABo4ICmjCCApYwDgYDVR0P
# AQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBS5d2bhatXq
# eUDFo9KltQWHthbPKzAfBgNVHSMEGDAWgBSJwtfivYIqfRl/k1i63yftuTKF/jCB
# 6QYDVR0fBIHhMIHeMIHboIHYoIHVhoGubGRhcDovLy9DTj1aZXJvU0NBKDEpLENO
# PVplcm9TQ0EsQ049Q0RQLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNl
# cnZpY2VzLENOPUNvbmZpZ3VyYXRpb24sREM9emVybyxEQz1sYWI/Y2VydGlmaWNh
# dGVSZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNzPWNSTERpc3RyaWJ1dGlv
# blBvaW50hiJodHRwOi8vcGtpL2NlcnRkYXRhL1plcm9TQ0EoMSkuY3JsMIHmBggr
# BgEFBQcBAQSB2TCB1jCBowYIKwYBBQUHMAKGgZZsZGFwOi8vL0NOPVplcm9TQ0Es
# Q049QUlBLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENO
# PUNvbmZpZ3VyYXRpb24sREM9emVybyxEQz1sYWI/Y0FDZXJ0aWZpY2F0ZT9iYXNl
# P29iamVjdENsYXNzPWNlcnRpZmljYXRpb25BdXRob3JpdHkwLgYIKwYBBQUHMAKG
# Imh0dHA6Ly9wa2kvY2VydGRhdGEvWmVyb1NDQSgxKS5jcnQwPQYJKwYBBAGCNxUH
# BDAwLgYmKwYBBAGCNxUIg7j0P4Sb8nmD8Y84g7C3MobRzXiBJ6HzzB+P2VUCAWQC
# AQUwGwYJKwYBBAGCNxUKBA4wDDAKBggrBgEFBQcDAzANBgkqhkiG9w0BAQsFAAOC
# AQEAszRRF+YTPhd9UbkJZy/pZQIqTjpXLpbhxWzs1ECTwtIbJPiI4dhAVAjrzkGj
# DyXYWmpnNsyk19qE82AX75G9FLESfHbtesUXnrhbnsov4/D/qmXk/1KD9CE0lQHF
# Lu2DvOsdf2mp2pjdeBgKMRuy4cZ0VCc/myO7uy7dq0CvVdXRsQC6Fqtr7yob9NbE
# OdUYDBAGrt5ZAkw5YeL8H9E3JLGXtE7ir3ksT6Ki1mont2epJfHkO5JkmOI6XVtg
# anuOGbo62885BOiXLu5+H2Fg+8ueTP40zFhfLh3e3Kj6Lm/NdovqqTBAsk04tFW9
# Hp4gWfVc0gTDwok3rHOrfIY35TGCAfUwggHxAgEBMFQwPTETMBEGCgmSJomT8ixk
# ARkWA0xBQjEUMBIGCgmSJomT8ixkARkWBFpFUk8xEDAOBgNVBAMTB1plcm9TQ0EC
# E1gAAAH5oOvjAv3166MAAQAAAfkwCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFOkNLWbXBf8LY1nu
# ySHLcWjHxma3MA0GCSqGSIb3DQEBAQUABIIBAG2COqdkb3L/PUQI8oOVxRLjGUjX
# +d3Fvbf0kuIESa1cBhTby+qFb5SqarUhrU+VrVaDQNYhk/qWlFvwH/rfJm2D28Wd
# c3bwxJcvZtbEZt5RU+zLyD61V2dPsZjGo1f46utByUZOeeelkgY2W7jTqx5QxJ36
# WFhxqwLfWZ3i6b3YFU1Cs57QkI+MkGt9WL4uGXvbSJ1xw1MHV5cdhrYOumGUopwc
# nVLscfmfKh1G+i980NOGBluvZ6BHrSqmp9WcUr5C+hg866z3iGDwgJie2bTR+ZOB
# 1kZy5Ld+FQPXwCBK9M7eaCZ38yalTIiDpyfx/2Zc070wnp9Rg+C8XDpahys=
# SIG # End signature block
