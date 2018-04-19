<#
    .SYNOPSIS
        Removes an Elevated (i.e. "Run As Administrator") PSSession for the current user in the current PowerShell Session and
        and reverts any changes in WSMAN/WinRM and GPO configuration made by the companion New-SudoSession function.

        This is a companion function with New-SudoSession. If you DO NOT want to ensure that WinRM/WSMan and GPO configuration
        is as it was prior to running New-SudoSession, there is no reason to use this function. You can simply use...
            Get-PSSession | Remove-PSession
        ...like any other normal PSSession.

        If you DO want to ensure that WinRM/WSMan and GPO configuration is as it was prior to running New-SudoSession, then
        use this function with its -RevertConfig switch and -OriginalConfigInfo parameter.

    .DESCRIPTION
        Removes an Elevated (i.e. "Run As Administrator") PSSession for the current user in the current PowerShell Session and
        and reverts any changes in WSMAN/WinRM and GPO configuration made by the companion New-SudoSession function.
        
        This is a companion function with New-SudoSession. If you DO NOT want to ensure that WinRM/WSMan and GPO configuration
        is as it was prior to running New-SudoSession, there is no reason to use this function. You can simply use...
            Get-PSSession | Remove-PSession
        ...like any other normal PSSession.

        If you DO want to ensure that WinRM/WSMan and GPO configuration is as it was prior to running New-SudoSession, then
        use this function with its -RevertConfig switch and -OriginalConfigInfo parameter.

    .PARAMETER UserName
        This is a string that represents a UserName with Administrator privileges. Defaults to current user.

        This parameter is mandatory if you do NOT use the -Credentials parameter.

    .PARAMETER Password
        This can be either a plaintext string or a secure string that represents the password for the -UserName.

        This parameter is mandatory if you do NOT use the -Credentials parameter.

    .PARAMETER Credentials
        This is a System.Management.Automation.PSCredential object used to create an elevated PSSession.

    .PARAMETER OriginalConfigInfo
        A PSCustomObject that can be found in the "WSManAndRegistryChanges" property of the PSCustomObject generated
        by the New-SudoSession function. The "WSManAndRegistryChanges" property is itself a PSCustomObject with the
        following properties:
            [bool]WinRMStateChange
            [bool]WSMANServerCredSSPStateChange
            [bool]WSMANClientCredSSPStateChange
            [System.Collections.ArrayList]RegistryKeyCreated
            [System.Collections.ArrayList]RegistryKeyPropertiesCreated

    .PARAMETER SessionToRemove
        A System.Management.Automation.Runspaces.PSSession object that you would like to remove. You can use the 
        "ElevatedPSSession" property of the PSCustomObject generated by the New-SudoSession function, or, you can simply
        get whichever PSSession you would like to remove by doing the typical...
            Get-PSSession -Name <Name>
        
        This parameter accepts value from the pipeline.

    .EXAMPLE
        Get-PSSession -Name <Name>
        $ModuleToInstall = "PackageManagement"
        $LatestVersion = $(Find-Module PackageManagement).Version
        # PLEASE NOTE the use of single quotes in the below $InstallModuleExpression string
        $InstallModuleExpression = 'Install-Module -Name $ModuleToInstall -RequiredVersion $LatestVersion'

        $SudoSession = New-SudoSession -Credentials $MyCreds -Expression $InstallModuleExpression

        Remove-SudoSession -Credentials $MyCreds -OriginalConfigInfo $SudoSession.WSManAndRegistryChanges -SessionToRemove $SudoSession.ElevatedPSSession

#>
function Remove-SudoSession {
    [CmdletBinding(DefaultParameterSetName='Supply UserName and Password')]
    Param(
        [Parameter(
            Mandatory=$True,
            ValueFromPipeline=$True,
            Position=0
        )]
        [System.Management.Automation.Runspaces.PSSession]$SessionToRemove,

        [Parameter(Mandatory=$False)]
        $OriginalConfigInfo = $global:NewSessionAndOriginalStatus.WSManAndRegistryChanges
    )

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    if (GetElevation) {
        Write-Error "The current PowerShell Session is already being run with elevated permissions. There is no reason to use the Start-SudoSession function. Halting!"
        $global:FunctionResult = "1"
        return
    }

    if ($OriginalConfigInfo -eq $null) {
        Write-Warning "Unable to determine the original configuration of WinRM/WSMan and AllowFreshCredentials Registry prior to using New-SudoSession. No configuration changes will be made/reverted."
        Write-Warning "The only action will be removing the Elevated PSSession specified by the -SessionToRemove parameter."
    }

    ##### END Variable/Parameter Transforms and PreRunPrep #####

    ##### BEGIN Main Body #####

    if ($OriginalConfigInfo -ne $null) {
        # Use the existing SudoSession to revert Registry/WSMAN configs so that there's no UAC prompt
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
                        Remove-ItemProperty -Path $PropertyPath -Name $PropertyName
                        $null = $RegistryKeyPropertiesRemoved.Add($Property)
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

        $CurrentUser = $($(whoami) -split "\\")[-1]
        $SudoSessionFolder = "$HOME\SudoSession_$CurrentUser_$(Get-Date -Format MMddyyy)"
        if (!$(Test-Path $SudoSessionFolder)) {
            $SudoSessionFolder = $(New-Item -ItemType Directory -Path $SudoSessionFolder).FullName
        }
        $SudoSessionRevertChangesPSObject = "$SudoSessionFolder\SudoSession_Config_Revert_Changes__$CurrentUser_$(Get-Date -Format MMddyyy_hhmmss).xml"

        $WSMandAndRegistryRevertChangesResult = Invoke-Command -Session $SessionToRemove -Scriptblock $SystemConfigSB
        $WSMandAndRegistryRevertChangesResult | Export-CliXml $SudoSessionRevertChangesPSObject
    }

    try {
        Remove-PSSession $SessionToRemove -ErrorAction Stop
    }
    catch {
        Write-Error $_
        $global:FunctionResult = "1"
        return
    }

    ##### END Main Body #####

}




















# SIG # Begin signature block
# MIIMiAYJKoZIhvcNAQcCoIIMeTCCDHUCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUGC6iUkim/j8VHdnSa3SKLuHb
# NiWgggn9MIIEJjCCAw6gAwIBAgITawAAAB/Nnq77QGja+wAAAAAAHzANBgkqhkiG
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFFmjSQkDNMSlTP3d
# N024rjFZ4NUkMA0GCSqGSIb3DQEBAQUABIIBAGhSe2VwO20lEjb/QLzvEvfDQJ9m
# SGC/cl+z3haxH04J8vWbfR+CRJxlByNaxM1AlRwzszeIw4mwCr5cyxXJShF+PISW
# lmwMSRwIVvhN9Oh2OelUd7pX3Zs3G7B1pdLI5ldvc8+KcasOiUQNmDzLReGWMrRw
# LD6NyQLcB8FAkirXR17ygLJmzbOvayPnWq8psSU2HqYGoZnrk0L7+/rgXDdnN4rp
# PQH/agypgPM69OYuQTKCe79ze6I/pK97rnYQxuX+ef9cW2WeY1BmUsTHXOjb6FMy
# dG3mxlIUP5Cobud6NiQc16M+boHqCEUJmdDVovGFOq5vvCpN8Hcmeqg/k2Q=
# SIG # End signature block
