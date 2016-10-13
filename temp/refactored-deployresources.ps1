[CmdletBinding()]
Param (
  [ValidateNotNullOrEmpty()]
  [string]$BitbucketPassword,
  [ValidateNotNullOrEmpty()]
  [string]$BitbucketOAuthKey,
  [ValidateNotNullOrEmpty()]
  [string]$BitbucketOAuthSecret,
  [ValidateNotNullOrEmpty()]
  [string[]]$ProductNames,
  [ValidateNotNullOrEmpty()]
  [string]$AdminPassword,
  [ValidateNotNullOrEmpty()]
  [string]$DomainJoinPassword,
  [ValidateNotNullOrEmpty()]
  [ValidateSet("northeurope","westeurope")]
  [string]$SiteLocation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$config = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json

# Get BitBucket OAuth URI and token, valid for an hour
$bitbucketAccessToken = Get-BitbucketToken -key $bitbucketOAuthKey `
                                           -secret $bitbucketOAuthSecret `
                                           -username $config.bitbucketUsername `
                                           -password $bitbucketPassword

$templateBaseURI = Get-DeployTemplateURL -accountname $config.deployTemplatesAccount `
                                         -reposlug $config.deployTemplatesRepo `
                                         -accesstoken $bitbucketAccessToken
                                         


function Choose-Subscription {
    Authenticate-Azure -Account $config.azureAccount `
                       -CertificateSubject $config.certificateSubject `
                       -TenantId $config.azureTenantId

    Select-AzureRmSubscription -SubscriptionName $config.azureSubscriptionName
}

function Get-PublicIPAvailability {
    $publicIps = @(Get-AzureRmPublicIpAddress -ResourceGroupName $config.publicIpAddressResourceGroup |
                        Where-Object { ($_.IpConfiguration -eq $null) -and ($_.Tag["whitelisted"] -eq "true") })
    if ($publicIps.Count -lt $ProductNames.Count) 
    {
        Throw "Not enough free public IPs"
    }    
}

function Set-ResourceGroupName  { 
    $envVariables = [System.Environment]::GetEnvironmentVariables()
    switch ([string]::IsNullOrEmpty($envVariables["bamboo_deploy_environment"])) {
        True 
        { 
            $planName = $envVariables["bamboo_planRepository_branchName"].ToLower()
            $puppetMaster = "puppet" 
        }
        default 
        { 
            $planName = $envVariables["bamboo_deploy_environment"].ToLower()
            $puppetMaster = "dvpuppetmaster.davincipoc.local" 
        }
    }
    $versionNumber = "$($config.majorMinor)-" + $envVariables["bamboo_buildNumber"]
    $dateTime = Get-Date -UFormat "%Y%m%d%H%M"
    $resourceGroupName = "$productName-$planName-$versionNumber-$dateTime"
    If ($resourceGroupName.Length -gt 64) 
    {
        Throw "The resource group name '$resourceGroupName' is too long, try making the branch name '$planName' shorter"
    }
    $resourceGroupName 
}

Param (
    [ValidateNotNullOrEmpty()]
    [int]$count,
    [ValidateNotNullOrEmpty()]
    [string]$productName
    )
function Set-ProductVariables {
    $publicIps = @(Get-AzureRmPublicIpAddress -ResourceGroupName $configVariables.publicIpAddressResourceGroup | 
                    Where-Object { ($_.IpConfiguration -eq $null) -and ($_.Tag["whitelisted"] -eq "true") })
    $SubnetName = $config.${productName}.subnetName
    $publicIPAddressName = $publicIps[$count].Name
    $publicIPAddressResourceGroupName = $config.publicIPAddressResourceGroup
} 


Param (
    [string]$ResourceGroupName
    )
function New-ResourceGroup {
    $tags = @{ project = $config.projectId;
            applicationname = $config.product;
            businessunit = $config.businessUnit 
            }

    Write-Output "Creating $resourceGroupName resource group"
    New-AzureRmResourceGroup -Name $resourceGroupName `
                            -Location $SiteLocation `
                            -Tag $tags
    Write-Output "Successfully created $resourceGroupName resource group."
}

function Start-DeploymentJobs {
  $jobs = @()
  $jobs += Start-Job -ScriptBlock {
    param ($scriptRoot)
    Choose-Subscription
    # Set NSG parameters for template azuredeploy.json 
    $nsgName = -join ((65..90) + (97..122) | Get-Random -Count 10 | ForEach-Object {[char]$_})
    $nsgRules = Deserialize-Json -JsonFile "$scriptRoot\nsgrules.json"

    # Set parameters for Deploy-Resources function
    $deployParams = @{
      DeploymentName = $using:resourceGroupNameme;
      ResourceGroupName = $using:resourceGroupName;
      TemplateFile = "$scriptRoot\azuredeploy.json";
      TemplateParameters = @{ nsgName = $nsgName
                              nsgRules = $nsgRules
                              bitbucketAccessToken = $using:bitbucketAccessToken
                              templateBaseUri = $using:templateBaseUri
                              subnetName = $using:SubnetName
                              adminPassword = $using:AdminPassword
                              publicIPAddressName = $using:publicIPAddressName
                              publicIPAddressResourceGroupName = $using:publicIPAddressResourceGroupName
                              domainPassword = $using:DomainJoinPassword
                              puppetMaster = $using:puppetMaster
                              puppetHiscoxEnvironment = $using:planName
                            }
    }

    # Deploy!!
    Deploy-Resources @deployParams
    Write-Output "Successfully deployed in ${using:resourceGroupName} resource group."
  } -ArgumentList $PSScriptRoot

  if ($jobs.Count -gt 0) 
  {
      Wait-Job -Job $jobs
      $jobs | Receive-Job
  }
}

function Set-EachVMPassword {
    $vms = Get-AzureRmVm -ResourceGroupName $rg
    $secureAdminPw = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force

    foreach ($vm in $vms) 
    {
        $vmResource = Get-AzureRmResource -ResourceId $vm.Id
        Set-AzureKeyVaultSecret -VaultName $config.keyVaultName `
                                -Name $vmResource.Properties.vmId `
                                -SecretValue $secureAdminPw
    }
}

function Set-NetworkInterfaceCards {
    $nsg = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $rg
    if ($nsg -ne $null) 
    {
        $nics = @(Get-AzureRmNetworkInterface -ResourceGroupName $rg)
        foreach ($nic in $nics) 
        {
            $nic.NetworkSecurityGroup = $nsg
            $nic | Set-AzureRmNetworkInterface
        }
    }
}

function Create-AzureResources {
    Choose-Subscription
    Get-PublicIPAvailability

    $productcount = 0
    foreach ($productName in ($ProductNames | % {$_.ToLower()}))
    {
        $resourceGroupNames = @()
        $resourceGroupName = Set-ResourceGroupName
        $resourceGroupNames += $resourceGroupName

        # product specific variables
        Set-ProductVariables -ProductName $productName-StartCountAt $productcount
        New-ResourceGroup -Name $resourceGroupName
        Start-DeploymentJobs  
        $productcount++  
    }

    $resourceGroupNames
}

Param (
    [string]$ResourceGroupNames
)
function Add-NetworkSecurityGroups {
    foreach ($rg in $resourceGroupNames)
    {
    Set-EachVMPassword -ResourceGroupName $rg
    Set-NetworkInterfaceCards -ResourceGroupName $rg 
    }
}

# main(); This may change.
&{
    #Create-AzureResources | Add-NetworkSecurityGroups
    $resourceGroupNames = Create-AzureResources
    Add-NetworkSecurityGroups -ResourceGroupNames $resourceGroupNames
}

