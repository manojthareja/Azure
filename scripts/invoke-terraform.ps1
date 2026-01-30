param(
    [Parameter(Mandatory = $true)]
    [string]$ModuleFolderPath,
    
    [Parameter(Mandatory = $true)]
    [string]$TfvarsFileName,
    
    [Parameter(Mandatory = $false)]
    [string]$TenantId = "",
    
    [Parameter(Mandatory = $false)]
    [switch]$Destroy,
    
    [Parameter(Mandatory = $false)]
    [switch]$AutoApprove,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipLogin,
    
    [Parameter(Mandatory = $false)]
    [switch]$PlanOnly,
    
    [Parameter(Mandatory = $false)]
    [switch]$ForceApply
)

<#
.SYNOPSIS
    Invokes Terraform operations for Azure Landing Zone deployment or destruction.

.DESCRIPTION
    This script automates the Terraform workflow including Azure authentication, initialization, 
    planning, and applying/destroying infrastructure. It supports both deployment and destruction 
    operations with proper error handling and logging.

.PARAMETER ModuleFolderPath
    The full path to the Terraform module directory.

.PARAMETER TfvarsFileName
    The name of the terraform variables file (e.g., "terraform.tfvars.json").

.PARAMETER TenantId
    The Azure tenant ID to authenticate against. Defaults to "".

.PARAMETER Destroy
    Switch to indicate if this is a destroy operation.

.PARAMETER AutoApprove
    Switch to automatically approve the Terraform apply/destroy without Terraform's manual confirmation.
    Note: Script will still ask for user confirmation unless ForceApply is also used.

.PARAMETER SkipLogin
    Switch to skip Azure login (useful if already authenticated).

.PARAMETER PlanOnly
    Switch to only run terraform plan without applying changes.

.PARAMETER ForceApply
    Switch to skip all confirmations including script's safety confirmation. 
    USE WITH EXTREME CAUTION! Only for automated scenarios.

.EXAMPLE
    .\invoke-terraform.ps1 -ModuleFolderPath "C:\path\to\terraform" -TfvarsFileName "terraform.tfvars.json" -AutoApprove
    
.EXAMPLE
    .\invoke-terraform.ps1 -ModuleFolderPath "C:\path\to\terraform" -TfvarsFileName "terraform.tfvars.json" -Destroy -AutoApprove

.EXAMPLE
    .\invoke-terraform.ps1 -ModuleFolderPath "C:\path\to\terraform" -TfvarsFileName "terraform.tfvars.json" -PlanOnly
#>

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."
    
    # Check if Azure CLI is installed
    try {
        $azVersion = az version --output json 2>$null | ConvertFrom-Json
        Write-Log "Azure CLI version: $($azVersion.'azure-cli')" "SUCCESS"
    }
    catch {
        Write-Log "Azure CLI is not installed or not accessible. Please install Azure CLI." "ERROR"
        exit 1
    }
    
    # Check if Terraform is installed
    try {
        $tfVersion = terraform version -json | ConvertFrom-Json
        Write-Log "Terraform version: $($tfVersion.terraform_version)" "SUCCESS"
    }
    catch {
        Write-Log "Terraform is not installed or not accessible. Please install Terraform." "ERROR"
        exit 1
    }
    
    # Check if module folder exists
    if (-not (Test-Path $ModuleFolderPath)) {
        Write-Log "Module folder path does not exist: $ModuleFolderPath" "ERROR"
        exit 1
    }
    
    # Check if tfvars file exists
    $tfvarsPath = Join-Path $ModuleFolderPath $TfvarsFileName
    if (-not (Test-Path $tfvarsPath)) {
        Write-Log "Terraform variables file does not exist: $tfvarsPath" "ERROR"
        exit 1
    }
    
    Write-Log "Prerequisites check completed successfully." "SUCCESS"
}

function Invoke-AzureLogin {
    if ($SkipLogin) {
        Write-Log "Skipping Azure login as requested."
        return
    }
    
    Write-Log "Step 1: Azure Authentication"
    Write-Log "Authenticating to Azure tenant: $TenantId"
    
    try {
        $loginResult = az login --tenant $TenantId --output json | ConvertFrom-Json
        if ($loginResult) {
            Write-Log "Successfully authenticated to Azure tenant: $TenantId" "SUCCESS"
            Write-Log "Logged in as: $($loginResult[0].user.name)"
        }
    }
    catch {
        Write-Log "Failed to authenticate to Azure. Error: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

function Invoke-TerraformInit {
    Write-Log "Step 2: Terraform Initialization"
    Write-Log "Initializing Terraform in directory: $ModuleFolderPath"
    
    try {
        terraform -chdir="$ModuleFolderPath" init
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Terraform initialization completed successfully." "SUCCESS"
        }
        else {
            Write-Log "Terraform initialization failed with exit code: $LASTEXITCODE" "ERROR"
            exit 1
        }
    }
    catch {
        Write-Log "Error during Terraform initialization: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

function Invoke-TerraformPlan {
    $operation = if ($Destroy) { "Destroy" } else { "Apply" }
    Write-Log "Step 3: Terraform Plan (for $operation)"
    
    $tfvarsPath = Join-Path $ModuleFolderPath $TfvarsFileName
    $planArgs = @(
        "-chdir=`"$ModuleFolderPath`""
        "plan"
        "-out=tfplan"
        "-input=false"
        "-var-file=`"$tfvarsPath`""
    )
    
    if ($Destroy) {
        $planArgs += "-destroy"
        Write-Log "Creating destruction plan for resources in: $ModuleFolderPath"
    }
    else {
        Write-Log "Creating execution plan for resources in: $ModuleFolderPath"
    }
    
    try {
        $planCommand = "terraform $($planArgs -join ' ')"
        Write-Log "Executing: $planCommand"
        
        Invoke-Expression $planCommand
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Terraform plan completed successfully." "SUCCESS"
            if ($Destroy) {
                Write-Log "Destruction plan saved to tfplan file." "SUCCESS"
            }
            else {
                Write-Log "Execution plan saved to tfplan file." "SUCCESS"
            }
        }
        else {
            Write-Log "Terraform plan failed with exit code: $LASTEXITCODE" "ERROR"
            exit 1
        }
    }
    catch {
        Write-Log "Error during Terraform planning: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

function Invoke-TerraformApply {
    if ($PlanOnly) {
        Write-Log "Plan-only mode enabled. Skipping terraform apply." "WARN"
        return
    }
    
    $operation = if ($Destroy) { "destruction" } else { "deployment" }
    Write-Log "Step 4: Terraform Apply"
    Write-Log "Executing the $operation plan..."
    
    # Always ask for confirmation before applying (unless ForceApply is used)
    if (-not $ForceApply) {
        Write-Log "=== CONFIRMATION REQUIRED ===" "WARN"
        Write-Log "You are about to execute a Terraform $operation operation." "WARN"
        Write-Log "Module Path: $ModuleFolderPath" "WARN"
        Write-Log "Variables File: $TfvarsFileName" "WARN"
        if ($Destroy) {
            Write-Log "WARNING: This will DESTROY resources in your Azure environment!" "ERROR"
        }
        else {
            Write-Log "This will CREATE/MODIFY resources in your Azure environment." "WARN"
        }
        Write-Log "==============================" "WARN"
        
        do {
            $confirmation = Read-Host "Do you want to proceed with this $operation? (yes/no)"
            $confirmation = $confirmation.ToLower().Trim()
            
            if ($confirmation -eq "no" -or $confirmation -eq "n") {
                Write-Log "Operation cancelled by user." "WARN"
                return
            }
            elseif ($confirmation -ne "yes" -and $confirmation -ne "y") {
                Write-Log "Please enter 'yes' or 'no'." "WARN"
            }
        } while ($confirmation -ne "yes" -and $confirmation -ne "y")
        
        Write-Log "User confirmed. Proceeding with $operation..." "SUCCESS"
    }
    else {
        Write-Log "ForceApply enabled - skipping safety confirmation." "WARN"
    }
    
    $applyArgs = @(
        "-chdir=`"$ModuleFolderPath`""
        "apply"
        "-input=false"
        "tfplan"
    )
    
    if ($AutoApprove) {
        $applyArgs = $applyArgs[0..($applyArgs.Length-2)] + "-auto-approve" + $applyArgs[-1]
        Write-Log "Auto-approve enabled for Terraform confirmation."
    }
    else {
        Write-Log "Terraform will also ask for confirmation."
    }
    
    try {
        $applyCommand = "terraform $($applyArgs -join ' ')"
        Write-Log "Executing: $applyCommand"
        
        Invoke-Expression $applyCommand
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Terraform $operation completed successfully!" "SUCCESS"
        }
        else {
            Write-Log "Terraform $operation failed with exit code: $LASTEXITCODE" "ERROR"
            exit 1
        }
    }
    catch {
        Write-Log "Error during Terraform apply: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

function Show-Summary {
    Write-Log "=== TERRAFORM OPERATION SUMMARY ===" "SUCCESS"
    Write-Log "Module Path: $ModuleFolderPath"
    Write-Log "Variables File: $TfvarsFileName"
    Write-Log "Tenant ID: $TenantId"
    Write-Log "Operation: $(if ($Destroy) { 'DESTROY' } else { 'DEPLOY' })"
    Write-Log "Auto Approve: $(if ($AutoApprove) { 'YES' } else { 'NO' })"
    Write-Log "Plan Only: $(if ($PlanOnly) { 'YES' } else { 'NO' })"
    Write-Log "Force Apply: $(if ($ForceApply) { 'YES' } else { 'NO' })"
    Write-Log "===================================" "SUCCESS"
}

# Main execution
try {
    Write-Log "Starting Terraform automation script..." "SUCCESS"
    Show-Summary
    
    # Run all steps
    Test-Prerequisites
    Invoke-AzureLogin
    Invoke-TerraformInit
    Invoke-TerraformPlan
    Invoke-TerraformApply
    
    Write-Log "Terraform automation completed successfully!" "SUCCESS"
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# SIG # Begin signature block
# MIIr5wYJKoZIhvcNAQcCoIIr2DCCK9QCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAP495Kmb6PXXNT
# P+EEh8E+X2WuaFZM+1aRPTEOnbgP7qCCEW4wggh+MIIHZqADAgECAhM2AAACDeKE
# D0nu2y38AAIAAAINMA0GCSqGSIb3DQEBCwUAMEExEzARBgoJkiaJk/IsZAEZFgNH
# QkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxFTATBgNVBAMTDEFNRSBDUyBDQSAwMTAe
# Fw0yNTEwMjMyMzA5MzBaFw0yNjA0MjYyMzE5MzBaMCQxIjAgBgNVBAMTGU1pY3Jv
# c29mdCBBenVyZSBDb2RlIFNpZ24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQCpj9ry6z6v08TIeKoxS2+5c928SwYKDXCyPWZHpm3xIHTqBBmlTM1GO7X4
# ap5jj/wroH7TzukJtfLR6Z4rBkjdlocHYJ2qU7ggik1FDeVL1uMnl5fPAB0ETjqt
# rk3Lt2xT27XUoNlKfnFcnmVpIaZ6fnSAi2liEhbHqce5qEJbGwv6FiliSJzkmeTK
# 6YoQQ4jq0kK9ToBGMmRiLKZXTO1SCAa7B4+96EMK3yKIXnBMdnKhWewBsU+t1LHW
# vB8jt8poBYSg5+91Faf9oFDvl5+BFWVbJ9+mYWbOzJ9/ZX1J4yvUoZChaykKGaTl
# k51DUoZymsBuatWbJsGzo0d43gMLAgMBAAGjggWKMIIFhjApBgkrBgEEAYI3FQoE
# HDAaMAwGCisGAQQBgjdbAQEwCgYIKwYBBQUHAwMwPQYJKwYBBAGCNxUHBDAwLgYm
# KwYBBAGCNxUIhpDjDYTVtHiE8Ys+hZvdFs6dEoFgg93NZoaUjDICAWQCAQ4wggJ2
# BggrBgEFBQcBAQSCAmgwggJkMGIGCCsGAQUFBzAChlZodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpaW5mcmEvQ2VydHMvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1F
# JTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBSBggrBgEFBQcwAoZGaHR0cDovL2NybDEu
# YW1lLmdibC9haWEvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUy
# MDAxKDIpLmNydDBSBggrBgEFBQcwAoZGaHR0cDovL2NybDIuYW1lLmdibC9haWEv
# QlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBS
# BggrBgEFBQcwAoZGaHR0cDovL2NybDMuYW1lLmdibC9haWEvQlkyUEtJQ1NDQTAx
# LkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBSBggrBgEFBQcwAoZG
# aHR0cDovL2NybDQuYW1lLmdibC9haWEvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1F
# JTIwQ1MlMjBDQSUyMDAxKDIpLmNydDCBrQYIKwYBBQUHMAKGgaBsZGFwOi8vL0NO
# PUFNRSUyMENTJTIwQ0ElMjAwMSxDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2Vy
# dmljZXMsQ049U2VydmljZXMsQ049Q29uZmlndXJhdGlvbixEQz1BTUUsREM9R0JM
# P2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0
# aG9yaXR5MB0GA1UdDgQWBBS6kl+vZengaA7Cc8nJtd6sYRNA3jAOBgNVHQ8BAf8E
# BAMCB4AwRQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEWMBQGA1UEBRMNMjM2MTY3KzUwNjA0MjCCAeYGA1UdHwSCAd0wggHZMIIB
# 1aCCAdGgggHNhj9odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpaW5mcmEvQ1JM
# L0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmwxLmFtZS5nYmwv
# Y3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmwyLmFtZS5n
# YmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmwzLmFt
# ZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmw0
# LmFtZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGgb1sZGFwOi8v
# L0NOPUFNRSUyMENTJTIwQ0ElMjAwMSgyKSxDTj1CWTJQS0lDU0NBMDEsQ049Q0RQ
# LENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZp
# Z3VyYXRpb24sREM9QU1FLERDPUdCTD9jZXJ0aWZpY2F0ZVJldm9jYXRpb25MaXN0
# P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQwHwYDVR0jBBgw
# FoAUllGE4Gtve/7YBqvD8oXmKa5q+dQwHwYDVR0lBBgwFgYKKwYBBAGCN1sBAQYI
# KwYBBQUHAwMwDQYJKoZIhvcNAQELBQADggEBAJKGB9zyDWN/9twAY6qCLnfDCKc/
# PuXoCYI5Snobtv15QHAJwwBJ7mr907EmcwECzMnK2M2auU/OUHjdXYUOG5TV5L7W
# xvf0xBqluWldZjvnv2L4mANIOk18KgcSmlhdVHT8AdehHXSs7NMG2di0cPzY+4Ol
# 2EJ3nw2JSZimBQdRcoZxDjoCGFmHV8lOHpO2wfhacq0T5NK15yQqXEdT+iRivdhd
# i/n26SOuPDa6Y/cCKca3CQloCQ1K6NUzt+P6E8GW+FtvcLza5dAWjJLVvfemwVyl
# JFdnqejZPbYBRdNefyLZjFsRTBaxORl6XG3kiz2t6xeFLLRTJgPPATx1S7Awggjo
# MIIG0KADAgECAhMfAAAAUeqP9pxzDKg7AAAAAABRMA0GCSqGSIb3DQEBCwUAMDwx
# EzARBgoJkiaJk/IsZAEZFgNHQkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxEDAOBgNV
# BAMTB2FtZXJvb3QwHhcNMjEwNTIxMTg0NDE0WhcNMjYwNTIxMTg1NDE0WjBBMRMw
# EQYKCZImiZPyLGQBGRYDR0JMMRMwEQYKCZImiZPyLGQBGRYDQU1FMRUwEwYDVQQD
# EwxBTUUgQ1MgQ0EgMDEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDJ
# mlIJfQGejVbXKpcyFPoFSUllalrinfEV6JMc7i+bZDoL9rNHnHDGfJgeuRIYO1LY
# /1f4oMTrhXbSaYRCS5vGc8145WcTZG908bGDCWr4GFLc411WxA+Pv2rteAcz0eHM
# H36qTQ8L0o3XOb2n+x7KJFLokXV1s6pF/WlSXsUBXGaCIIWBXyEchv+sM9eKDsUO
# LdLTITHYJQNWkiryMSEbxqdQUTVZjEz6eLRLkofDAo8pXirIYOgM770CYOiZrcKH
# K7lYOVblx22pdNawY8Te6a2dfoCaWV1QUuazg5VHiC4p/6fksgEILptOKhx9c+ia
# piNhMrHsAYx9pUtppeaFAgMBAAGjggTcMIIE2DASBgkrBgEEAYI3FQEEBQIDAgAC
# MCMGCSsGAQQBgjcVAgQWBBQSaCRCIUfL1Gu+Mc8gpMALI38/RzAdBgNVHQ4EFgQU
# llGE4Gtve/7YBqvD8oXmKa5q+dQwggEEBgNVHSUEgfwwgfkGBysGAQUCAwUGCCsG
# AQUFBwMBBggrBgEFBQcDAgYKKwYBBAGCNxQCAQYJKwYBBAGCNxUGBgorBgEEAYI3
# CgMMBgkrBgEEAYI3FQYGCCsGAQUFBwMJBggrBgEFBQgCAgYKKwYBBAGCN0ABAQYL
# KwYBBAGCNwoDBAEGCisGAQQBgjcKAwQGCSsGAQQBgjcVBQYKKwYBBAGCNxQCAgYK
# KwYBBAGCNxQCAwYIKwYBBQUHAwMGCisGAQQBgjdbAQEGCisGAQQBgjdbAgEGCisG
# AQQBgjdbAwEGCisGAQQBgjdbBQEGCisGAQQBgjdbBAEGCisGAQQBgjdbBAIwGQYJ
# KwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHwYDVR0jBBgwFoAUKV5RXmSuNLnrrJwNp4x1AdEJCygwggFoBgNV
# HR8EggFfMIIBWzCCAVegggFToIIBT4YxaHR0cDovL2NybC5taWNyb3NvZnQuY29t
# L3BraWluZnJhL2NybC9hbWVyb290LmNybIYjaHR0cDovL2NybDIuYW1lLmdibC9j
# cmwvYW1lcm9vdC5jcmyGI2h0dHA6Ly9jcmwzLmFtZS5nYmwvY3JsL2FtZXJvb3Qu
# Y3JshiNodHRwOi8vY3JsMS5hbWUuZ2JsL2NybC9hbWVyb290LmNybIaBqmxkYXA6
# Ly8vQ049YW1lcm9vdCxDTj1BTUVSb290LENOPUNEUCxDTj1QdWJsaWMlMjBLZXkl
# MjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPUFNRSxE
# Qz1HQkw/Y2VydGlmaWNhdGVSZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNz
# PWNSTERpc3RyaWJ1dGlvblBvaW50MIIBqwYIKwYBBQUHAQEEggGdMIIBmTBHBggr
# BgEFBQcwAoY7aHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraWluZnJhL2NlcnRz
# L0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUHMAKGK2h0dHA6Ly9jcmwyLmFt
# ZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUHMAKGK2h0dHA6
# Ly9jcmwzLmFtZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUH
# MAKGK2h0dHA6Ly9jcmwxLmFtZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQw
# gaIGCCsGAQUFBzAChoGVbGRhcDovLy9DTj1hbWVyb290LENOPUFJQSxDTj1QdWJs
# aWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9u
# LERDPUFNRSxEQz1HQkw/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNl
# cnRpZmljYXRpb25BdXRob3JpdHkwDQYJKoZIhvcNAQELBQADggIBAFAQI7dPD+jf
# XtGt3vJp2pyzA/HUu8hjKaRpM3opya5G3ocprRd7vdTHb8BDfRN+AD0YEmeDB5HK
# QoG6xHPI5TXuIi5sm/LeADbV3C2q0HQOygS/VT+m1W7a/752hMIn+L4ZuyxVeSBp
# fwf7oQ4YSZPh6+ngZvBHgfBaVz4O9/wcfw91QDZnTgK9zAh9yRKKls2bziPEnxeO
# ZMVNaxyV0v152PY2xjqIafIkUjK6vY9LtVFjJXenVUAmn3WCPWNFC1YTIIHw/mD2
# cTfPy7QA1pT+GPARAKt0bKtq9aCd/Ym0b5tPbpgCiRtzyb7fbNS1dE740re0COE6
# 7YV2wbeo2sXixzvLftH8L7s9xv9wV+G22qyKt6lmKLjFK1yMw4Ni5fMabcgmzRvS
# jAcbqgp3tk4a8emaaH0rz8MuuIP+yrxtREPXSqL/C5bzMzsikuDW9xH10graZzSm
# PjilzpRfRdu20/9UQmC7eVPZ4j1WNa1oqPHfzET3ChIzJ6Q9G3NPCB+7KwX0OQmK
# yv7IDimj8U/GlsHD1z+EF/fYMf8YXG15LamaOAohsw/ywO6SYSreVW+5Y0mzJutn
# BC9Cm9ozj1+/4kqksrlhZgR/CSxhFH3BTweH8gP2FEISRtShDZbuYymynY1un+Ry
# fiK9+iVTLdD1h/SxyxDpZMtimb4CgJQlMYIZzzCCGcsCAQEwWDBBMRMwEQYKCZIm
# iZPyLGQBGRYDR0JMMRMwEQYKCZImiZPyLGQBGRYDQU1FMRUwEwYDVQQDEwxBTUUg
# Q1MgQ0EgMDECEzYAAAIN4oQPSe7bLfwAAgAAAg0wDQYJYIZIAWUDBAIBBQCgga4w
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGC8jwM8za+u3mvFB/mcYWLp2x6UaapG
# Sq9ltjVY6OfhMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYA
# dKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEA
# PFKRkpqqnBist9FiuD2BNrl2+2KBZhI54ao+g1rfJqUgyO0K1Ezu14JFckrU2TP6
# KJU/2J/T/xyQuH4QxbQTtWZBa0R5KJeEBEeNOFjyvoK3n7/Sa6PAC3MsnyybQblr
# iDlRCqBEpEvCyRChPwPCBUEV/fcw3fYU6+JGdrbw5HqSnRE1mub0wCXmNOlGvVo0
# dsMBWz3jAzpeF8clN2fVy8ZDAZTzcd5AEzhlZrGXLoF5L5cPW0Si5amxt43BKdJw
# cEJTuifwbygtwn5JN1m5bJywKexYiPyPXRWl6i8r/hP8KKdnlaPT7splRmZMsJSS
# XWLykClSNJR/UPpm8vUYWKGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqG
# SIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0B
# CRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUA
# BCBEHhJSuWPGmVRWht+FfDedLJ2lXxzI3AQFJF5egcmJBgIGaRYj+qMjGBMyMDI1
# MTEyMDA3NTQxMC42NzVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIH
# IDCCBQigAwIBAgITMwAAAgO7HlwAOGx0ygABAAACAzANBgkqhkiG9w0BAQsFADB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNTAxMzAxOTQyNDZaFw0y
# NjA0MjIxOTQyNDZaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQChl0MH5wAnOx8Uh8RtidF0J0yaFDHJYHTpPvRR16X1KxGDYfT8
# PrcGjCLCiaOu3K1DmUIU4Rc5olndjappNuOgzwUoj43VbbJx5PFTY/a1Z80tpqVP
# 0OoKJlUkfDPSBLFgXWj6VgayRCINtLsUasy0w5gysD7ILPZuiQjace5KxASjKf2M
# VX1qfEzYBbTGNEijSQCKwwyc0eavr4Fo3X/+sCuuAtkTWissU64k8rK60jsGRApi
# ESdfuHr0yWAmc7jTOPNeGAx6KCL2ktpnGegLDd1IlE6Bu6BSwAIFHr7zOwIlFqyQ
# uCe0SQALCbJhsT9y9iy61RJAXsU0u0TC5YYmTSbEI7g10dYx8Uj+vh9InLoKYC5D
# pKb311bYVd0bytbzlfTRslRTJgotnfCAIGMLqEqk9/2VRGu9klJi1j9nVfqyYHYr
# MPOBXcrQYW0jmKNjOL47CaEArNzhDBia1wXdJANKqMvJ8pQe2m8/cibyDM+1BVZq
# uNAov9N4tJF4ACtjX0jjXNDUMtSZoVFQH+FkWdfPWx1uBIkc97R+xRLuPjUypHZ5
# A3AALSke4TaRBvbvTBYyW2HenOT7nYLKTO4jw5Qq6cw3Z9zTKSPQ6D5lyiYpes5R
# R2MdMvJS4fCcPJFeaVOvuWFSQ/EGtVBShhmLB+5ewzFzdpf1UuJmuOQTTwIDAQAB
# o4IBSTCCAUUwHQYDVR0OBBYEFLIpWUB+EeeQ29sWe0VdzxWQGJJ9MB8GA1UdIwQY
# MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYB
# BQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB
# /wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQCQEMbesD6TC08R0oYCdSC452AQrGf/O89GQ54CtgEs
# bxzwGDVUcmjXFcnaJSTNedBKVXkBgawRonP1LgxH4bzzVj2eWNmzGIwO1FlhldAP
# OHAzLBEHRoSZ4pddFtaQxoabU/N1vWyICiN60It85gnF5JD4MMXyd6pS8eADIi6T
# tjfgKPoumWa0BFQ/aEzjUrfPN1r7crK+qkmLztw/ENS7zemfyx4kGRgwY1WBfFqm
# /nFlJDPQBicqeU3dOp9hj7WqD0Rc+/4VZ6wQjesIyCkv5uhUNy2LhNDi2leYtAiI
# FpmjfNk4GngLvC2Tj9IrOMv20Srym5J/Fh7yWAiPeGs3yA3QapjZTtfr7NfzpBIJ
# Q4xT/ic4WGWqhGlRlVBI5u6Ojw3ZxSZCLg3vRC4KYypkh8FdIWoKirjidEGlXsNO
# o+UP/YG5KhebiudTBxGecfJCuuUspIdRhStHAQsjv/dAqWBLlhorq2OCaP+wFhE3
# WPgnnx5pflvlujocPgsN24++ddHrl3O1FFabW8m0UkDHSKCh8QTwTkYOwu99iExB
# VWlbYZRz2qOIBjL/ozEhtCB0auKhfTLLeuNGBUaBz+oZZ+X9UAECoMhkETjb6YfN
# aI1T7vVAaiuhBoV/JCOQT+RYZrgykyPpzpmwMNFBD1vdW/29q9nkTWoEhcEOO0L9
# NzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM
# 57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm
# 95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzB
# RMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBb
# fowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCO
# Mcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYw
# XE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW
# /aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/w
# EPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
# Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2
# BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfH
# CBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYB
# BAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8v
# BO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEF
# BQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBW
# BgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
# AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# L2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518Jx
# Nj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+
# iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2
# pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefw
# C2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7
# T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFO
# Ry3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhL
# mm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3L
# wUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
# m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIB
# ATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UE
# CxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNy
# b3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQDNrxRX/iz6
# ss1lBCXG8P1LFxD0e6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwMA0GCSqGSIb3DQEBCwUAAgUA7MkzVDAiGA8yMDI1MTEyMDA2MjczMloYDzIw
# MjUxMTIxMDYyNzMyWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDsyTNUAgEAMAoC
# AQACAhfvAgH/MAcCAQACAhRAMAoCBQDsyoTUAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAIaJsm7Ir68AE+CorOE91A1GDa3ZRh/Z3MkJfU+mDSKmg1ofnXr5
# dsD8DA8A8zInMk3ItSg7Q/K4tf2qF0EVpmts2hnsmdWHpjhB7Qzwevm+5nkO6aMe
# oaf8F8ANHzH6FRpNnB/tOrRvqvxpQlzFbi+b8S5P0w8lkFuDlpYpHDaoBlN4SiQa
# 0w1cbx/b/bFdnNSZ8SBqUoNrAYDKxbmaif6IdB1gKc1uSFMWk4IYr3P8YwNMUnTv
# YuoDzUVd//Ilb2bxedf1fdP227NpDr+zaKT/vXTaS6Hi0S2rTtiC6UUTFV5TueDf
# azGjBUzSrk0xPV/mcKPjuRE5ES0xQrnoK4sxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAgO7HlwAOGx0ygABAAACAzANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCChKmkGH06xcZNQODR4gSOvxjcEXft8zXyAdub9H7lCijCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEsD3RtxlvaTxFOZZnpQw0DksPmVduo5
# SyK9h9w++hMtMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIDux5cADhsdMoAAQAAAgMwIgQgqqoycAqg2yYwzcAoYatnKfBBLZY1LpU+
# Ib84JnQcn6gwDQYJKoZIhvcNAQELBQAEggIAH9hMJE8zsddVKvaMRb7toa0Y7TyC
# E+f//qE0mVDLcvpmyQxoUXH35f655V/GFOEWNRJEq52GG7pCfQo8442GFe0Pn6Ob
# raCH6fPsAyINn4ILj6cbo/RN0up6lPvK1Ln+/O9d8R475JbmEXyUGWMxBrLSuORV
# hfgi0IB5QFtMRKt8wffhJY6QTjcY8VWiHY5WCLKKNwPCOEJpQWtPuoak/GukDEKn
# YQU8VYyzkp/Im9DQ82+DMLZOyuFaq02vPPT9AG2YrKkgJaV0T9IHlwZWYZ33Sb+T
# rs3bFNWqOPsHd+OH4oVKLZDF0FC1CwnF/l7NDADebJCz6zx1o0FeTMrE3uKem1hb
# TJvU94Z5ku0lLBk8DSKzZzN0RN9v/RGOBaM4QKl5HRGhotO/4AWEMJ5RKVCRC2DL
# BYbKO/okuy0TWqEH5JcLQYDHxAGRWfiaF4cOpybmFvUaHIDJI/VXxqjWRu1lvFae
# anaOlJVfxiLVTjldMrbusm9IsPwEVSjtpmU1dK1+DtYQwd1H9LMZLx7OdGUQQt44
# 5/iOzQEM2Ma+4BldxlxC+ziHCvM1vlaIAVMhJEa4bIpVcnEOsTQ8bkMG9HYc3S7E
# zoPRkCEMySP2lxbqTSADtmLNboLOrW6a/z5yF8DdMYsLjV+R6NTB0CriIKQ7Iazu
# zpxW65Dkf0jbUUc=
# SIG # End signature block
