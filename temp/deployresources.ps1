#Requires -Modules Hiscox-Azure
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

# GET PARAMETERS
#Read in config file
$configVariables = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json

#Get Bamboo environment variables (plan key, build no. etc)
$envVariables = [System.Environment]::GetEnvironmentVariables()
If ([string]::IsNullOrEmpty($envVariables["bamboo_deploy_environment"])) {
  $planName = $envVariables["bamboo_planRepository_branchName"].ToLower()
  $puppetMaster = "puppet"
} Else {
  $planName = $envVariables["bamboo_deploy_environment"].ToLower()
  $puppetMaster = "dvpuppetmaster.davincipoc.local"
}
$versionNumber = "$($configVariables.majorMinor)-" + $envVariables["bamboo_buildNumber"]
$tags = @{
    project = $configVariables.projectId;
    applicationname = $configVariables.product;
    businessunit = $configVariables.businessUnit
  }

# get BitBucket OAuth URI and token, valid for an hour
$bitbucketAccessToken = Get-BitbucketToken -key $bitbucketOAuthKey `
                                           -secret $bitbucketOAuthSecret `
                                           -username $configVariables.bitbucketUsername `
                                           -password $bitbucketPassword

$templateBaseUri = Get-DeployTemplateURL -accountname $configVariables.deployTemplatesAccount `
                                         -reposlug $configVariables.deployTemplatesRepo `
                                         -accesstoken $bitbucketAccessToken

#Authenticate to Azure
Authenticate-Azure -Account $configVariables.azureAccount `
                   -CertificateSubject $configVariables.certificateSubject `
                   -TenantId $configVariables.azureTenantId

Select-AzureRmSubscription -SubscriptionName $configVariables.azureSubscriptionName

# Check that there are enough free public IPs
$publicIps = @(Get-AzureRmPublicIpAddress -ResourceGroupName $configVariables.publicIpAddressResourceGroup |
  Where-Object { ($_.IpConfiguration -eq $null) -and ($_.Tag["whitelisted"] -eq "true") })
if ($publicIps.Count -lt $ProductNames.Count)
{
  Throw "Not enough free public IPs"
}

$count = 0
foreach ($productName in $ProductNames)
{  
  ## convert to valid parameters
  $productName = $productName.ToLower()

  # resource group
  $resourcegroups = @()
  $dateTime = Get-Date -UFormat "%Y%m%d%H%M"
  $resourceGroupName = "$productName-$planName-$versionNumber-$dateTime"
  $resourcegroups += $resourceGroupName

  # product specific variables
  $SubnetName = $configVariables.${productName}.subnetName
  $publicIPAddressName = $publicIps[$count].Name
  $publicIPAddressResourceGroupName = $configVariables.publicIPAddressResourceGroup
  $count++

  If ($resourceGroupName.Length -gt 64)
  {
    Throw "The resource group name '$resourceGroupName' is too long, try making the branch name '$planName' shorter"
  }

# CREATE RESOURCE GROUPS
  Write-Output "Creating $resourceGroupName resource group"
  New-AzureRmResourceGroup -Name $resourceGroupName `
                            -Location $SiteLocation `
                            -Tag $tags
  Write-Output "Successfully created $resourceGroupName resource group."
  
  $jobs = @()
  $jobs += Start-Job -ScriptBlock {
    param ($scriptRoot)
    $vars = $using:configVariables
    #Authenticate to Azure
    Authenticate-Azure -Account $vars.azureAccount `
                       -CertificateSubject $vars.CertificateSubject `
                       -TenantId $vars.azureTenantId
    Select-AzureRmSubscription -SubscriptionName $vars.azureSubscriptionName
    # nsg
    $nsgName = -join ((65..90) + (97..122) | Get-Random -Count 10 | ForEach-Object {[char]$_})
    $nsgRules = Deserialize-Json -JsonFile "$scriptRoot\nsgrules.json"

    # template parameters
    $templateParameters = @{
      bitbucketAccessToken = $using:bitbucketAccessToken
      templateBaseUri = $using:templateBaseUri
      subnetName = $using:SubnetName
      adminPassword = $using:AdminPassword
      nsgName = $nsgName
      nsgRules = $nsgRules
      publicIPAddressName = $using:publicIPAddressName
      publicIPAddressResourceGroupName = $using:publicIPAddressResourceGroupName
      domainPassword = $using:DomainJoinPassword
      puppetMaster = $using:puppetMaster
      puppetHiscoxEnvironment = $using:planName
    }

    $templateFileLocation = "$ScriptRoot\azuredeploy.json"
    $deploymentGroupName = "$using:resourceGroupName"
    $deployParams = @{
      Name = $deploymentGroupName;
      ResourceGroupName = $using:resourceGroupName;
      TemplateFile = $templateFileLocation;
      TemplateParameters = $templateParameters
    }
    Deploy-Resources @deployParams
    Write-Output "Successfully deployed in ${using:resourceGroupName} resource group."
  } -ArgumentList $PSScriptRoot
}

if ($jobs.Count -gt 0)
{
  Wait-Job -Job $jobs
  $jobs | Receive-Job
}

# ADD NSGS TO EACH RESOURCE GROUP
foreach ($rg in $resourcegroups)
{
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
  $secureAdminPw = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
  $vms = Get-AzureRmVm -ResourceGroupName $rg
  foreach ($vm in $vms)
  {
    $vmResource = Get-AzureRmResource -ResourceId $vm.Id
    Set-AzureKeyVaultSecret -VaultName $configVariables.keyVaultName -Name $vmResource.Properties.vmId -SecretValue $secureAdminPw
  }
}
