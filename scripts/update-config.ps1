# Platform Landing Zone Configuration Update Script
#
# This script updates terraform.tfvars.json files with values from inputs.yaml configuration.
# It automatically handles the installation of required PowerShell modules and processes
# both bootstrap and starter module configurations.
#
# Features:
# - Automatically installs the powershell-yaml module if not present
# - Reads configuration from config/inputs.yaml
# - Dynamically detects array fields from YAML syntax and preserves array data types
# - Updates terraform.tfvars.json files in bootstrap and starter output folders
# - Sets module_folder_path to the absolute path of the platform_landing_zone directory
# - Copies platform-landing-zone.tfvars content to auto.tfvars files
# - Provides detailed logging of all operations
#
# Usage:
#   PowerShell -ExecutionPolicy Bypass -File ".\scripts\update-config.ps1"
#
# Dependencies:
#   - PowerShell 5.0 or later
#   - powershell-yaml module (automatically installed if needed)
#

# Get script directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Path to inputs.yaml
$InputsYamlPath = Join-Path (Join-Path $ScriptDir '..') 'config' | Join-Path -ChildPath 'inputs.yaml'

# Function to ensure powershell-yaml module is installed
function Ensure-PowerShellYamlModule {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "Installing required powershell-yaml module..."
        try {
            Install-Module -Name powershell-yaml -Force -Scope CurrentUser -AllowClobber
            Write-Host "Successfully installed powershell-yaml module."
        } catch {
            Write-Error "Failed to install powershell-yaml module: $_"
            throw
        }
    } else {
        Write-Host "powershell-yaml module is already installed."
    }
}

# Function to parse YAML (requires powershell-yaml module)
function Parse-Yaml {
    param([string]$Path)
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        if (Test-Path $Path) {
            return ConvertFrom-Yaml (Get-Content $Path -Raw)
        } else {
            throw "File not found: $Path"
        }
    } catch {
        Write-Error "Failed to parse YAML file '$Path': $_"
        throw
    }
}

# Helper function to handle common object property iteration
function Invoke-ForEachProperty {
    param([object]$Object, [scriptblock]$ScriptBlock)
    
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $Object.PSObject.Properties | ForEach-Object { & $ScriptBlock $_.Name $_.Value $Object }
    } elseif ($Object -is [System.Collections.IDictionary]) {
        $Object.Keys | ForEach-Object { & $ScriptBlock $_ $Object[$_] $Object }
    }
}

# Function to scan existing JSON files and detect array patterns
function Get-ArrayKeysFromJsonFiles {
    param([array]$JsonFiles)
    
    $detectedArrayKeys = @()
    
    foreach ($file in $JsonFiles) {
        if (Test-Path $file) {
            try {
                $jsonContent = Get-Content $file -Raw | ConvertFrom-Json
                $foundArrays = Get-ArrayKeysFromObject -Object $jsonContent -Path ""
                foreach ($key in $foundArrays) {
                    if ($detectedArrayKeys -notcontains $key) {
                        $detectedArrayKeys += $key
                        Write-Host "  Detected array field from existing JSON: $key"
                    }
                }
            } catch {
                Write-Warning "Could not parse JSON file: $file"
            }
        }
    }
    
    return $detectedArrayKeys
}

# Helper function to recursively find array keys in JSON objects
function Get-ArrayKeysFromObject {
    param([object]$Object, [string]$Path)
    
    $arrayKeys = @()
    
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            $currentPath = if ($Path) { "$Path.$($prop.Name)" } else { $prop.Name }
            
            if ($prop.Value -is [System.Array]) {
                $arrayKeys += $prop.Name
            } elseif ($prop.Value -is [System.Management.Automation.PSCustomObject] -or 
                     $prop.Value -is [System.Collections.IDictionary]) {
                $nestedArrays = Get-ArrayKeysFromObject -Object $prop.Value -Path $currentPath
                $arrayKeys += $nestedArrays
            }
        }
    } elseif ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $currentPath = if ($Path) { "$Path.$key" } else { $key }
            
            if ($Object[$key] -is [System.Array]) {
                $arrayKeys += $key
            } elseif ($Object[$key] -is [System.Management.Automation.PSCustomObject] -or 
                     $Object[$key] -is [System.Collections.IDictionary]) {
                $nestedArrays = Get-ArrayKeysFromObject -Object $Object[$key] -Path $currentPath
                $arrayKeys += $nestedArrays
            }
        }
    }
    
    return $arrayKeys
}

# Function to ensure arrays remain arrays (handle single-element array conversion)
function Ensure-ArrayType {
    param([object]$Value, [string]$Key, [array]$ArrayKeys)
    
    if ($ArrayKeys -contains $Key) {
        if ($Value -is [System.Array]) {
            Write-Host "    $Key is already an array with $($Value.Count) items"
            return $Value
        } else {
            # Convert single value to array
            Write-Host "    Converting $Key from '$Value' to array format"
            $result = @($Value)
            Write-Host "    Result is array: $($result -is [System.Array]), Count: $($result.Count)"
            return $result
        }
    }
    
    return $Value
}

# Function to recursively update JSON object
function Update-JsonProperties {
    param([object]$JsonObj, [hashtable]$Inputs, [array]$ArrayKeys)
    
    if ($null -eq $JsonObj) { return }
    
    # Handle objects (both PSCustomObject and IDictionary)
    if ($JsonObj -is [System.Management.Automation.PSCustomObject] -or $JsonObj -is [System.Collections.IDictionary]) {
        Invoke-ForEachProperty -Object $JsonObj -ScriptBlock {
            param($key, $value, $obj)
            if ($Inputs.ContainsKey($key)) {
                Write-Host "  Updating property: $key"
                $newValue = Ensure-ArrayType -Value $Inputs[$key] -Key $key -ArrayKeys $ArrayKeys
                if ($obj -is [System.Management.Automation.PSCustomObject]) {
                    $obj.$key = $newValue
                } else {
                    $obj[$key] = $newValue
                }
            } else {
                Update-JsonProperties -JsonObj $value -Inputs $Inputs -ArrayKeys $ArrayKeys
            }
        }
    } elseif ($JsonObj -is [System.Array] -or ($JsonObj -is [System.Collections.IEnumerable] -and $JsonObj -isnot [string])) {
        foreach ($item in $JsonObj) {
            Update-JsonProperties -JsonObj $item -Inputs $Inputs -ArrayKeys $ArrayKeys
        }
    }
}

# Helper: Convert PSCustomObject to Hashtable recursively (for JSON output)
function ConvertTo-Hashtable {
    param([object]$Object, [array]$ArrayKeys)
    
    if ($null -eq $Object) {
        return $null
    }
    
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        # Check if this is an empty object that should remain an empty object
        if ($Object.PSObject.Properties.Count -eq 0) {
            return [ordered]@{}
        }
        
        $hash = [ordered]@{}
        # Sort properties alphabetically for consistent output
        $sortedProps = $Object.PSObject.Properties | Sort-Object Name
        foreach ($prop in $sortedProps) {
            $value = ConvertTo-Hashtable $prop.Value $ArrayKeys
            
            # Check if this property should be an array (even if it's currently empty or scalar)
            if ($ArrayKeys -contains $prop.Name) {
                if ($value -eq $null -or ($value -is [hashtable] -and $value.Count -eq 0)) {
                    # Convert empty object to empty array for known array fields
                    $value = @()
                    Write-Host "    Converting empty object to empty array for: $($prop.Name)"
                } elseif ($value -isnot [System.Array] -and $null -ne $value) {
                    $value = @($value)
                    Write-Host "    Forcing $($prop.Name) to array in hashtable conversion"
                }
            }
            $hash[$prop.Name] = $value
        }
        return $hash
    } elseif ($Object -is [System.Collections.IDictionary]) {
        # Check if this is an empty dictionary that should remain an empty object
        if ($Object.Count -eq 0) {
            return [ordered]@{}
        }
        
        $hash = [ordered]@{}
        # Sort keys alphabetically for consistent output
        $sortedKeys = $Object.Keys | Sort-Object
        foreach ($key in $sortedKeys) {
            $value = ConvertTo-Hashtable $Object[$key] $ArrayKeys
            
            # Check if this key should be an array (even if it's currently empty or scalar)
            if ($ArrayKeys -contains $key) {
                if ($value -eq $null -or ($value -is [hashtable] -and $value.Count -eq 0)) {
                    # Convert empty object to empty array for known array fields
                    $value = @()
                    Write-Host "    Converting empty object to empty array for: $key"
                } elseif ($value -isnot [System.Array] -and $null -ne $value) {
                    $value = @($value)
                    Write-Host "    Forcing $key to array in hashtable conversion"
                }
            }
            $hash[$key] = $value
        }
        return $hash
    } elseif ($Object -is [System.Array]) {
        # Handle arrays explicitly - preserve empty arrays as arrays
        if ($Object.Count -eq 0) {
            return @()
        }
        
        # Process array elements and remove empty objects if this is a known array field
        $processedArray = @()
        foreach ($item in $Object) {
            $processedItem = ConvertTo-Hashtable $item $ArrayKeys
            # Skip empty objects in arrays that should contain meaningful data
            if ($processedItem -is [hashtable] -and $processedItem.Count -eq 0) {
                # Skip empty objects in known array fields
                continue
            }
            $processedArray += $processedItem
        }
        return $processedArray
    } elseif ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        # Handle other enumerable types
        $array = @($Object)
        if ($array.Count -eq 0) {
            return @()
        }
        return @($array | ForEach-Object { ConvertTo-Hashtable $_ $ArrayKeys })
    } else {
        return $Object
    }
}

# Function to update module_folder_path property specifically
function Update-ModuleFolderPath {
    param([object]$JsonObj, [string]$NewPath)
    
    if ($null -eq $JsonObj) { return }
    
    # Handle objects (both PSCustomObject and IDictionary)
    if ($JsonObj -is [System.Management.Automation.PSCustomObject] -or $JsonObj -is [System.Collections.IDictionary]) {
        Invoke-ForEachProperty -Object $JsonObj -ScriptBlock {
            param($key, $value, $obj)
            if ($key -eq "module_folder_path") {
                Write-Host "  Updating module_folder_path to: $NewPath"
                if ($obj -is [System.Management.Automation.PSCustomObject]) {
                    $obj.$key = $NewPath
                } else {
                    $obj[$key] = $NewPath
                }
            } else {
                Update-ModuleFolderPath -JsonObj $value -NewPath $NewPath
            }
        }
    } elseif ($JsonObj -is [System.Array] -or ($JsonObj -is [System.Collections.IEnumerable] -and $JsonObj -isnot [string])) {
        foreach ($item in $JsonObj) {
            Update-ModuleFolderPath -JsonObj $item -NewPath $NewPath
        }
    }
}

# Parse inputs.yaml
try {
    # Ensure required module is installed
    Ensure-PowerShellYamlModule
    
    Write-Host "Reading inputs from: $InputsYamlPath"
    $Inputs = Parse-Yaml -Path $InputsYamlPath
    
    # Convert inputs to hashtable for easy lookup
    $InputsHash = @{}
    
    # Handle both hashtable and PSCustomObject inputs uniformly
    $inputKeys = if ($Inputs -is [System.Collections.IDictionary]) { 
        $Inputs.Keys 
    } else { 
        $Inputs.PSObject.Properties.Name 
    }
    
    foreach ($key in $inputKeys) {
        $value = if ($Inputs -is [System.Collections.IDictionary]) { 
            $Inputs[$key] 
        } else { 
            $Inputs.$key 
        }
        $InputsHash[$key] = $value
    }
    
    Write-Host "Found $($InputsHash.Keys.Count) input properties to process"
} catch {
    Write-Error "Failed to read inputs.yaml: $_"
    exit 1
}

# Find all terraform.tfvars.json files under output/bootstrap and output/starter
$BootstrapPath = Join-Path (Join-Path $ScriptDir '..') 'output' | Join-Path -ChildPath 'bootstrap'
$StarterPath = Join-Path (Join-Path $ScriptDir '..') 'output' | Join-Path -ChildPath 'starter'

Write-Host "Searching for terraform.tfvars.json files in:"
Write-Host "  Bootstrap: $BootstrapPath"
Write-Host "  Starter: $StarterPath"

$TfvarsFiles = @()
if (Test-Path $BootstrapPath) {
    $TfvarsFiles += Get-ChildItem -Path $BootstrapPath -Recurse -Filter 'terraform.tfvars.json' | Select-Object -ExpandProperty FullName
}
if (Test-Path $StarterPath) {
    $TfvarsFiles += Get-ChildItem -Path $StarterPath -Recurse -Filter 'terraform.tfvars.json' | Select-Object -ExpandProperty FullName
}

Write-Host "Found $($TfvarsFiles.Count) terraform.tfvars.json files to process"

# Pre-scan all JSON files to build comprehensive array keys list
Write-Host "Pre-scanning JSON files to identify all array fields..."
$AllArrayKeys = Get-ArrayKeysFromJsonFiles -JsonFiles $TfvarsFiles

Write-Host "Final array fields list: $($AllArrayKeys.Count) fields"
Write-Host "Array fields: $($AllArrayKeys -join ', ')"

foreach ($File in $TfvarsFiles) {
    Write-Host "Processing $File"
    try {
        $JsonContent = Get-Content $File -Raw | ConvertFrom-Json
        Update-JsonProperties -JsonObj $JsonContent -Inputs $InputsHash -ArrayKeys $AllArrayKeys
        
        # Special handling for module_folder_path - set to absolute path of platform_landing_zone
        if ($File -like "*bootstrap*") {
            # Find platform_landing_zone folder dynamically under starter directory
            $StarterBasePath = Join-Path (Join-Path $ScriptDir '..') 'output' | Join-Path -ChildPath 'starter'
            $PlatformLandingZonePath = Get-ChildItem -Path $StarterBasePath -Recurse -Directory -Name "platform_landing_zone" -ErrorAction SilentlyContinue | Select-Object -First 1
            
            if ($PlatformLandingZonePath) {
                $FullPlatformPath = Join-Path $StarterBasePath $PlatformLandingZonePath
                $PlatformLandingZoneAbsolutePath = Resolve-Path $FullPlatformPath -ErrorAction SilentlyContinue
                if ($PlatformLandingZoneAbsolutePath) {
                    Update-ModuleFolderPath -JsonObj $JsonContent -NewPath $PlatformLandingZoneAbsolutePath.Path
                }
            } else {
                Write-Warning "Could not find platform_landing_zone folder under $StarterBasePath"
            }
        }
        
        # Convert to hashtable for proper JSON serialization
        $JsonHashtable = ConvertTo-Hashtable $JsonContent $AllArrayKeys
        $JsonHashtable | ConvertTo-Json -Depth 100 -Compress:$false | Set-Content $File
        Write-Host "  Successfully updated $File with sorted JSON output"
    } catch {
        Write-Error "Failed to process $File`: $_"
    }
}

# Copy platform-landing-zone.tfvars from config to platform-landing-zone.auto.tfvars under output/starter
try {
    $SourceTfvarsPath = Join-Path (Join-Path $ScriptDir '..') 'config' | Join-Path -ChildPath 'platform-landing-zone.tfvars'
    
    if (Test-Path $SourceTfvarsPath) {
        Write-Host "Copying platform-landing-zone.tfvars content..."
        
        # Find platform-landing-zone.auto.tfvars files under starter directory
        $StarterBasePath = Join-Path (Join-Path $ScriptDir '..') 'output' | Join-Path -ChildPath 'starter'
        $AutoTfvarsFiles = Get-ChildItem -Path $StarterBasePath -Recurse -Filter 'platform-landing-zone.auto.tfvars' -ErrorAction SilentlyContinue
        
        if ($AutoTfvarsFiles) {
            $SourceContent = Get-Content $SourceTfvarsPath -Raw
            
            foreach ($AutoTfvarsFile in $AutoTfvarsFiles) {
                Write-Host "  Updating $($AutoTfvarsFile.FullName)"
                Set-Content -Path $AutoTfvarsFile.FullName -Value $SourceContent
            }
            
            Write-Host "Successfully copied platform-landing-zone.tfvars content to $($AutoTfvarsFiles.Count) file(s)"
        } else {
            Write-Warning "Could not find platform-landing-zone.auto.tfvars files under $StarterBasePath"
        }
    } else {
        Write-Warning "Source file not found: $SourceTfvarsPath"
    }
} catch {
    Write-Error "Failed to copy platform-landing-zone.tfvars content: $_"
}

# Copy the lib folder from config to output/starter
try {
    $SourceLibPath = Join-Path (Join-Path $ScriptDir '..') 'config' | Join-Path -ChildPath 'lib'
    
    if (Test-Path $SourceLibPath) {
        Write-Host "Copying lib folder..."
        
        # Find lib destination path under output/starter
        $StarterBasePath = Join-Path (Join-Path (Join-Path $ScriptDir '..') 'output') 'starter'
        
        # Find the platform_landing_zone directory dynamically under starter
        $PlatformLandingZoneDir = Get-ChildItem -Path $StarterBasePath -Recurse -Directory -Name "platform_landing_zone" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($PlatformLandingZoneDir) {
            $PlatformLandingZonePath = Join-Path $StarterBasePath $PlatformLandingZoneDir
            $DestinationLibPath = Join-Path $PlatformLandingZonePath 'lib'
        } else {
            Write-Warning "Could not find platform_landing_zone directory under $StarterBasePath"
            return
        } 
        
        # Remove existing lib folder if it exists
        if (Test-Path $DestinationLibPath) {
            Remove-Item -Path $DestinationLibPath -Recurse -Force
            Write-Host "  Removed existing lib folder at $DestinationLibPath"
        }
        
        # Copy lib folder
        Copy-Item -Path $SourceLibPath -Destination $DestinationLibPath -Recurse
        Write-Host "Successfully copied lib folder to $DestinationLibPath"
    } else {
        Write-Warning "Source lib folder not found: $SourceLibPath"
    }
} catch {
    Write-Error "Failed to copy lib folder: $_"
}

Write-Host "Update complete."

# SIG # Begin signature block
# MIIsDwYJKoZIhvcNAQcCoIIsADCCK/wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBmacFSC63nQc3X
# Cv8tywS6hC0IPLi7KZ+yEWeYrrzYY6CCEX0wggiNMIIHdaADAgECAhM2AAACDnmX
# oOn9X5/TAAIAAAIOMA0GCSqGSIb3DQEBCwUAMEExEzARBgoJkiaJk/IsZAEZFgNH
# QkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxFTATBgNVBAMTDEFNRSBDUyBDQSAwMTAe
# Fw0yNTEwMjMyMzEyMDNaFw0yNjA0MjYyMzIyMDNaMCQxIjAgBgNVBAMTGU1pY3Jv
# c29mdCBBenVyZSBDb2RlIFNpZ24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQCfrw9mbjhRpCz0Wh+dmWU4nlBbeiDkl5NfNWFA9NWUAfDcSAEtWiJTZLIB
# Vt+E5kjpxQfCeObdxk0aaPKmhkANla5kJ5egjmrttmGvsI/SPeeQ890j/QO4YI4g
# QWpXnt8EswtW6xzmRdMMP+CASyAYJ0oWQMVXXMNhBG9VBdrZe+L1+DzLawq42AWG
# NoKL6JdGg21P0W11MN1OtwrhubgTqEBkgYp7m1Bt4EeOxBz0GwZfPODbLVTblACS
# LmGlfEePEdVamqIUTTdsrAKG8NM/gGx010AiqAv6p2sCtSeZpvV7fkppLY9ajdm8
# Yc4Kf1KNI3U5ZNMdLIDz9fA5Q+ulAgMBAAGjggWZMIIFlTApBgkrBgEEAYI3FQoE
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
# aG9yaXR5MB0GA1UdDgQWBBSbKJrguVhFagj1tSbzFntHGtugCTAOBgNVHQ8BAf8E
# BAMCB4AwVAYDVR0RBE0wS6RJMEcxLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5k
# IE9wZXJhdGlvbnMgTGltaXRlZDEWMBQGA1UEBRMNMjM2MTY3KzUwNjA1MjCCAeYG
# A1UdHwSCAd0wggHZMIIB1aCCAdGgggHNhj9odHRwOi8vY3JsLm1pY3Jvc29mdC5j
# b20vcGtpaW5mcmEvQ1JML0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6
# Ly9jcmwxLmFtZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0
# dHA6Ly9jcmwyLmFtZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyG
# MWh0dHA6Ly9jcmwzLmFtZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5j
# cmyGMWh0dHA6Ly9jcmw0LmFtZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgy
# KS5jcmyGgb1sZGFwOi8vL0NOPUFNRSUyMENTJTIwQ0ElMjAwMSgyKSxDTj1CWTJQ
# S0lDU0NBMDEsQ049Q0RQLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNl
# cnZpY2VzLENOPUNvbmZpZ3VyYXRpb24sREM9QU1FLERDPUdCTD9jZXJ0aWZpY2F0
# ZVJldm9jYXRpb25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9u
# UG9pbnQwHwYDVR0jBBgwFoAUllGE4Gtve/7YBqvD8oXmKa5q+dQwHwYDVR0lBBgw
# FgYKKwYBBAGCN1sBAQYIKwYBBQUHAwMwDQYJKoZIhvcNAQELBQADggEBAKaBh/B8
# 42UPFqNHP+m2mYSY80orKjPVnXEb+KlCoxL1Ikl2DfziE1PBZXtCDbYtvyMqC9Pj
# KvB8TNz71+CWrO0lqV2f0KITMmtXiCy+yThBqLYvUZrbrRzlXYv2lQmqWMy0OqrK
# TIdMza2iwUp2gdLnKzG7DQ8IcbguYXwwh+GzbeUjY9hEi7sX7dgVP4Ls1UQNkRqR
# FcRPOAoTBZvBGhPSkOAnl9CShvCHfKrHl0yzBk/k/lnt4Di6A6wWq4Ew1BveHXMH
# 1ZT+sdRuikm5YLLqLc/HhoiT3rid5EHVQK3sng95fIdBMgj26SScMvyKWNC9gKkp
# emezUSM/c91wEhwwggjoMIIG0KADAgECAhMfAAAAUeqP9pxzDKg7AAAAAABRMA0G
# CSqGSIb3DQEBCwUAMDwxEzARBgoJkiaJk/IsZAEZFgNHQkwxEzARBgoJkiaJk/Is
# ZAEZFgNBTUUxEDAOBgNVBAMTB2FtZXJvb3QwHhcNMjEwNTIxMTg0NDE0WhcNMjYw
# NTIxMTg1NDE0WjBBMRMwEQYKCZImiZPyLGQBGRYDR0JMMRMwEQYKCZImiZPyLGQB
# GRYDQU1FMRUwEwYDVQQDEwxBTUUgQ1MgQ0EgMDEwggEiMA0GCSqGSIb3DQEBAQUA
# A4IBDwAwggEKAoIBAQDJmlIJfQGejVbXKpcyFPoFSUllalrinfEV6JMc7i+bZDoL
# 9rNHnHDGfJgeuRIYO1LY/1f4oMTrhXbSaYRCS5vGc8145WcTZG908bGDCWr4GFLc
# 411WxA+Pv2rteAcz0eHMH36qTQ8L0o3XOb2n+x7KJFLokXV1s6pF/WlSXsUBXGaC
# IIWBXyEchv+sM9eKDsUOLdLTITHYJQNWkiryMSEbxqdQUTVZjEz6eLRLkofDAo8p
# XirIYOgM770CYOiZrcKHK7lYOVblx22pdNawY8Te6a2dfoCaWV1QUuazg5VHiC4p
# /6fksgEILptOKhx9c+iapiNhMrHsAYx9pUtppeaFAgMBAAGjggTcMIIE2DASBgkr
# BgEEAYI3FQEEBQIDAgACMCMGCSsGAQQBgjcVAgQWBBQSaCRCIUfL1Gu+Mc8gpMAL
# I38/RzAdBgNVHQ4EFgQUllGE4Gtve/7YBqvD8oXmKa5q+dQwggEEBgNVHSUEgfww
# gfkGBysGAQUCAwUGCCsGAQUFBwMBBggrBgEFBQcDAgYKKwYBBAGCNxQCAQYJKwYB
# BAGCNxUGBgorBgEEAYI3CgMMBgkrBgEEAYI3FQYGCCsGAQUFBwMJBggrBgEFBQgC
# AgYKKwYBBAGCN0ABAQYLKwYBBAGCNwoDBAEGCisGAQQBgjcKAwQGCSsGAQQBgjcV
# BQYKKwYBBAGCNxQCAgYKKwYBBAGCNxQCAwYIKwYBBQUHAwMGCisGAQQBgjdbAQEG
# CisGAQQBgjdbAgEGCisGAQQBgjdbAwEGCisGAQQBgjdbBQEGCisGAQQBgjdbBAEG
# CisGAQQBgjdbBAIwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQD
# AgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUKV5RXmSuNLnrrJwN
# p4x1AdEJCygwggFoBgNVHR8EggFfMIIBWzCCAVegggFToIIBT4YxaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraWluZnJhL2NybC9hbWVyb290LmNybIYjaHR0cDov
# L2NybDIuYW1lLmdibC9jcmwvYW1lcm9vdC5jcmyGI2h0dHA6Ly9jcmwzLmFtZS5n
# YmwvY3JsL2FtZXJvb3QuY3JshiNodHRwOi8vY3JsMS5hbWUuZ2JsL2NybC9hbWVy
# b290LmNybIaBqmxkYXA6Ly8vQ049YW1lcm9vdCxDTj1BTUVSb290LENOPUNEUCxD
# Tj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1
# cmF0aW9uLERDPUFNRSxEQz1HQkw/Y2VydGlmaWNhdGVSZXZvY2F0aW9uTGlzdD9i
# YXNlP29iamVjdENsYXNzPWNSTERpc3RyaWJ1dGlvblBvaW50MIIBqwYIKwYBBQUH
# AQEEggGdMIIBmTBHBggrBgEFBQcwAoY7aHR0cDovL2NybC5taWNyb3NvZnQuY29t
# L3BraWluZnJhL2NlcnRzL0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUHMAKG
# K2h0dHA6Ly9jcmwyLmFtZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYI
# KwYBBQUHMAKGK2h0dHA6Ly9jcmwzLmFtZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9v
# dC5jcnQwNwYIKwYBBQUHMAKGK2h0dHA6Ly9jcmwxLmFtZS5nYmwvYWlhL0FNRVJv
# b3RfYW1lcm9vdC5jcnQwgaIGCCsGAQUFBzAChoGVbGRhcDovLy9DTj1hbWVyb290
# LENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxD
# Tj1Db25maWd1cmF0aW9uLERDPUFNRSxEQz1HQkw/Y0FDZXJ0aWZpY2F0ZT9iYXNl
# P29iamVjdENsYXNzPWNlcnRpZmljYXRpb25BdXRob3JpdHkwDQYJKoZIhvcNAQEL
# BQADggIBAFAQI7dPD+jfXtGt3vJp2pyzA/HUu8hjKaRpM3opya5G3ocprRd7vdTH
# b8BDfRN+AD0YEmeDB5HKQoG6xHPI5TXuIi5sm/LeADbV3C2q0HQOygS/VT+m1W7a
# /752hMIn+L4ZuyxVeSBpfwf7oQ4YSZPh6+ngZvBHgfBaVz4O9/wcfw91QDZnTgK9
# zAh9yRKKls2bziPEnxeOZMVNaxyV0v152PY2xjqIafIkUjK6vY9LtVFjJXenVUAm
# n3WCPWNFC1YTIIHw/mD2cTfPy7QA1pT+GPARAKt0bKtq9aCd/Ym0b5tPbpgCiRtz
# yb7fbNS1dE740re0COE67YV2wbeo2sXixzvLftH8L7s9xv9wV+G22qyKt6lmKLjF
# K1yMw4Ni5fMabcgmzRvSjAcbqgp3tk4a8emaaH0rz8MuuIP+yrxtREPXSqL/C5bz
# MzsikuDW9xH10graZzSmPjilzpRfRdu20/9UQmC7eVPZ4j1WNa1oqPHfzET3ChIz
# J6Q9G3NPCB+7KwX0OQmKyv7IDimj8U/GlsHD1z+EF/fYMf8YXG15LamaOAohsw/y
# wO6SYSreVW+5Y0mzJutnBC9Cm9ozj1+/4kqksrlhZgR/CSxhFH3BTweH8gP2FEIS
# RtShDZbuYymynY1un+RyfiK9+iVTLdD1h/SxyxDpZMtimb4CgJQlMYIZ6DCCGeQC
# AQEwWDBBMRMwEQYKCZImiZPyLGQBGRYDR0JMMRMwEQYKCZImiZPyLGQBGRYDQU1F
# MRUwEwYDVQQDEwxBTUUgQ1MgQ0EgMDECEzYAAAIOeZeg6f1fn9MAAgAAAg4wDQYJ
# YIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYB
# BAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICDyTc9Ym0Vs
# ObyKKxq9ERYqA8sUirF8SIPRcrjY7nw4MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBN
# AGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJ
# KoZIhvcNAQEBBQAEggEAHvFE8SG5qY1wbB6H9UHPd9kXFdlk0bRmfzQ5dvvr9RP+
# kU5U2jUQStAYxDHijqbSR/gcI4S0F5GciNhODNclUYdzahphbPiyMpOtTpUh7Y1U
# dlJW45fXK8TgKZgcu/atDhVF3f7Wmw+ZzMAumoZzuquTulBFHjOqbeCpc5ldVEKM
# bdqRSyO5ApY2w1A3cY8Rj0d8oMFSfSWeNkqsYJO8eDsGnNng8N82RWK3j6Q1Reea
# 88EFUsJZWMdznZTDuFlkxpiS7Ii57FCX+ddp5QCB0NAk3NaNvHRb8dxf6TMySgFh
# AEeMZ7jdoDWOZY7xx2HGl+ucI2i/bIgPyVTVPgtvQ6GCF7AwghesBgorBgEEAYI3
# AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIB
# BQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAx
# MA0GCWCGSAFlAwQCAQUABCDPrlpljINAOFoD4hg5QKir4/yzVd/LqKnHstfcYW1N
# ZAIGaR33rH/nGBMyMDI1MTEyMDA3NTQxMS45NzJaMASAAgH0oIHZpIHWMIHTMQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNy
# b3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGll
# bGQgVFNTIEVTTjoyQTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACEKvN5BYY7zmw
# AAEAAAIQMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwMB4XDTI1MDgxNDE4NDgxMloXDTI2MTExMzE4NDgxMlowgdMxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJ
# cmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1Mg
# RVNOOjJBMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjcc4q057
# ZwIgpKu4pTXWLejvYEduRf+1mIpbiJEMFWWmU2xpip+zK7xFxKGB1CclUXBU0/ZQ
# Z6LG8H0gI7yvosrsPEI1DPB/XccGCvswKbAKckngOuGTEPGk7K/vEZa9h0Xt02b7
# m2n9MdIjkLrFl0pDriKyz0QHGpdh93X6+NApfE1TL24Vo0xkeoFGpL3rX9gXhIOF
# 59EMnTd2o45FW/oxMgY9q0y0jGO0HrCLTCZr50e7TZRSNYAy2lyKbvKI2MKlN1wL
# zJvZbbc//L3s1q3J6KhS0KC2VNEImYdFgVkJej4zZqHfScTbx9hjFgFpVkJl4xH5
# VJ8tyJdXE9+vU0k9AaT2QP1Zm3WQmXedSoLjjI7LWznuHwnoGIXLiJMQzPqKqRIF
# L3wzcrDrZeWgtAdBPbipglZ5CQns6Baj5Mb6a/EZC9G3faJYK5QVHeE6eLoSEwp1
# dz5WurLXNPsp0VWplpl/FJb8jrRT/jOoHu85qRcdYpgByU9W7IWPdrthmyfqeAw0
# omVWN5JxcogYbLo2pANJHlsMdWnxIpN5YwHbGEPCuosBHPk2Xd9+E/pZPQUR6v+D
# 85eEN5A/ZM/xiPpxa8dJZ87BpTvui7/2uflUMJf2Yc9ZLPgEdhQQo0LwMDSTDT48
# y3sV7Pdo+g5q+MqnJztN/6qt1cgUTe9u+ykCAwEAAaOCAUkwggFFMB0GA1UdDgQW
# BBSe42+FrpdF2avbUhlk86BLSH5kejAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJl
# pxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3Rh
# bXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEA
# vs4rO3oo8czOrxPqnnSEkUVq718QzlrIiy7/EW7JmQXsJoFxHWUF0Ux0PDyKFDRX
# PJVv29F7kpJkBJJmcQg5HQV7blUXIMWQ1qX0KdtFQXI/MRL77Z+pK5x1jX+tbRkA
# 7a5Ft7vWuRoAEi02HpFH5m/Akh/dfsbx8wOpecJbYvuHuy4aG0/tGzOWFCxMMNhG
# AIJ4qdV87JnY/uMBmiodlm+Gz357XWW5tg3HrtNZXuQ0tWUv26ud4nGKJo/oLZHP
# 75p4Rpt7dMdYKUF9AuVFBwxYZYpvgk12tfK+/yOwq84/fjXVCdM83Qnawtbenbk/
# lnbc9KsZom+GnvA4itAMUpSXFWrcRkqdUQLN+JrG6fPBoV8+D8U2Q2F4XkiCR6EU
# 9JzYKwTuvL6t3nFuxnkLdNjbTg2/yv2j3WaDuCK5lSPgsndIiH6Bku2Ui3A0aUo6
# D9z9v+XEuBs9ioVJaOjf/z+Urqg7ESnxG0/T1dKci7vLQ2XNgWFYO+/OlDjtGoma
# 1ijX4m14N9qgrXTuWEGwgC7hhBgp3id/LAOf9BSTWA5lBrilsEoexXBrOn/1wM3r
# jG0hIsxvF5/YOK78mVRGY6Y7zYJ+uXt4OTOFBwadPv8MklreQZLPnQPtiwop4rlL
# UYaPCiD4YUqRNbLp8Sgyo9g0iAcZYznTuc+8Q8ZIrgwwggdxMIIFWaADAgECAhMz
# AAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9v
# dCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0z
# MDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP9
# 7pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMM
# tY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gm
# U3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130
# /o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP
# 3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7
# vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+A
# utuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz
# 1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6
# EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/Zc
# UlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZy
# acaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJ
# KwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVd
# AF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8G
# CCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3Mv
# UmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQC
# BAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYD
# VR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZF
# aHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9v
# Q2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcw
# AoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJB
# dXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cB
# MSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7
# bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/
# SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2
# EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2Fz
# Lixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0
# /fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9
# swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJ
# Xk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+
# pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW
# 4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N
# 7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHWMIHTMQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNy
# b3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGll
# bGQgVFNTIEVTTjoyQTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIaAxUAOsyf2b6riPKnnXlIgIL2
# f53PUsKggYMwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkq
# hkiG9w0BAQsFAAIFAOzJHuYwIhgPMjAyNTExMjAwNTAwMjJaGA8yMDI1MTEyMTA1
# MDAyMlowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7Mke5gIBADAKAgEAAgIPSwIB
# /zAHAgEAAgITIjAKAgUA7MpwZgIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEE
# AYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IB
# AQCx6QXS9KtgyBUGrqsHlZpRnvGeuJoaQWU/kE83pGvouFxYT7xta6ydW0fzgRnK
# JXHf9NuGQGnv9Q1+78xbpjh7zSPwiE83SWOxhLWr7GIuu5mxZykdZRvp61f8+/bb
# vyg0AbeQV36B7QQ+91ymr4XfsuVCgJzOpieu6LAhCVhcvgGChOSC6zgcPT0NKJFQ
# hPjwXNzuQrImitTMLMh+pNhJxSGkpD4iuVLuw5auPoT0nTh+oSjIBLuxLlDOYI8I
# CuFlejj8u0n3eE09WJ48cUGgR5Yh4Y9rYwwuDhr6Ers9jnbVmBwWk2I1J76baDEb
# 69qFhzm0lPWLap0Ofp2xNaMQMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTACEzMAAAIQq83kFhjvObAAAQAAAhAwDQYJYIZIAWUDBAIB
# BQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQx
# IgQg0GfEn3zkRvgQcp5AC6hiKn+ojgOpzToPynGj5vl7fTgwgfoGCyqGSIb3DQEJ
# EAIvMYHqMIHnMIHkMIG9BCDD1SHufsjzY59S1iHUQY9hnsKSrJPg5a9Mc4YnGmPH
# xjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACEKvN
# 5BYY7zmwAAEAAAIQMCIEIPK3taidMd3fbjQ95Yd4N/epQ6bHHvRyLj8PN6MX9Zb7
# MA0GCSqGSIb3DQEBCwUABIICAHS0mFgcpvwExu6ckN9pXUbnxhNNH7c6wsmqobea
# OtvtzKcVqfPsnwcRa+PRn0Q8OYVk/pczPAXN0Ti/F15QbDN54B+9ecxzyB1jjCGN
# ah165Mt1uoKLOiKA4klMguStr6hA6QoHVaFB6TS41ydz1HrXUK21R5eVNCDdS9yO
# C1sWyLuOo3qjo6KKBQJlUwMYOiy7tQpV4uvEqFaieBDh0dGSq5WLD7Fg+nhVMpgR
# 2YGA27lRRCJHfAb3dkxDU3BpWbaSwB7uk0O+AUN4kXHJQhRgh6QpY33mtMey2JDQ
# ICr4oJxkl8yjDg2b6aTtKKpssqngO+hXF2N7PL9YeAXlHrgJBHfz/ht7uBtTA79r
# 7zPh1uSs9s1nq1r0AzQKCoqb3+2IBJhPvOPWI/ZiQlWxY1kFzprzwz6jMCbwE30w
# fiIYFrKPHG9+bGOI/8oglqZC1zS87mIStOhAeoq1Uwq7q1KloZvVh4WRaMK00mOI
# iH/IJQ8M3wsJ3Gl55w+Z9FfcbASnXRMKKQibF4iWi3SeHuI8RMgElDkrZqqSFgEN
# MEqL02Vgy8a//8bk5PZUbqbUY8KVJBpOK593mI6Uh+pdoZA02bgiPsh9fs4EgALr
# XdBpb4TPnJkqYndMLokzND5dmHWNsfmt4luJ1zePxUQJxW16swt/6GZfOXEddqJn
# bxN7
# SIG # End signature block
