[CmdletBinding()]
param
(
    $ResourceId,
    $ResourceGroup,
    $Sub
)


$ErrorActionPreference = 'Continue';

$connectionName = "AzureRunAsConnection"
$servicePrincipalConnection=Get-AutomationConnection -Name $connectionName
$SubId = $ServicePrincipalConnection.SubscriptionId

# Loggit to Azure
try
{
   "Logging in to Azure..."
   Add-AzAccount `
     -ServicePrincipal `
     -TenantId $servicePrincipalConnection.TenantId `
     -ApplicationId $servicePrincipalConnection.ApplicationId `
     -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
   "Setting context to a specific subscription"  
   $context = Set-AzContext -SubscriptionId $SubId     
}
catch {
    if (!$servicePrincipalConnection)
    {
       $ErrorMessage = "Connection $connectionName not found."
       throw $ErrorMessage
     } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
     }
}

# Obtaining the authentication headers and URL DevOps and GeneralRunbooks repositry
$VSOAuthUserName = 'GITusername'
$VSOAuthPassword = 'GITPassword'
$basicAuth = ("{0}:{1}" -f $VSOAuthUserName,$VSOAuthPassword)
$basicAuth = [System.Text.Encoding]::UTF8.GetBytes($basicAuth) 
$basicAuth = [System.Convert]::ToBase64String($basicAuth) 
$DevopsHeaders = @{Authorization=("Basic {0}" -f $basicAuth)} 
$DevopsUrl = "https://Company.visualstudio.com/Project/_apis/git/repositories/Repo"
$DevopsApiVersion = "api-version=5.0"
$DevopsBranch = 'master'

# Obtaining the authentication header for Azure API
$cache = $context.TokenCache
$cacheItem = $cache.ReadItems() 
$token = ($cacheItem | Where-Object { $_.Resource -eq "https://management.core.windows.net/" }).accessToken
$AzureHeaders = @{}
$AzureHeaders.Add("Authorization","Bearer $($token)") 
$Date = Get-Date

# Obtaining the json of the Resource
$ResourceName = (Get-AzResource -ResourceId $ResourceId).Name
$ResourceType = (Get-AzResource -ResourceId $ResourceId).type.split('/')[0]
$DevopsFolder = "/$Sub/$ResourceGroup/$ResourceType"
$Resource = Export-AzResourceGroup -ResourceGroupName $ResourceGroup -SkipAllParameterization -Resource $ResourceId -force


# Upload existing in the automation account missing it the source control
$JSON = GC -path $Resource.path

If ($JSON)
{

    $ResourceContent = $JSON.replace('"','\"')
    "$ResourceContent"

    $ObjectId = ((Invoke-RestMethod -Method Get -Headers $DevopsHeaders -Uri "$DevopsUrl/refs?$DevopsApiVersion").value | where name -like "refs/heads/$DevopsBranch").objectId
    $sources = Invoke-RestMethod -Method Get -Headers $DevopsHeaders -Uri "$DevopsUrl/items?scopepath=/&recursionlevel=full&includecontentmetadata=true&$DevopsApiVersion" | Select-Object -ExpandProperty value | Select-Object -ExpandProperty path
    

    If ("$($DevopsFolder)/$($ResourceName).json" -in $sources){
        $JsonRequest = '{"refUpdates": [{"name": "refs/heads/' + $DevopsBranch + '", "oldObjectId": "' + $ObjectId + '"}], "commits": [{"comment": "Imported ARM template on '+ $Date +'", "changes": [{"changeType": "edit","item": {"path": "' + $DevopsFolder + '/' + $ResourceName + '.json"}, "newContent": {"content": "' + $ResourceContent + '", "contentType": "rawtext"}}]}]}'
        write-output "Resource exists, updating $DevopsFolder/$ResourceName"
    }
    else {
        $JsonRequest = '{"refUpdates": [{"name": "refs/heads/' + $DevopsBranch + '", "oldObjectId": "' + $ObjectId + '"}], "commits": [{"comment": "Imported ARM template on '+ $Date +'", "changes": [{"changeType": "add","item": {"path": "' + $DevopsFolder + '/' + $ResourceName + '.json"}, "newContent": {"content": "' + $ResourceContent + '", "contentType": "rawtext"}}]}]}'
        write-output "New Resource created $DevopsFolder/$ResourceName"
    }

    
    $params = @{
        Uri         = "$DevopsUrl/pushes?$DevopsApiVersion"
        Headers     = $DevopsHeaders
        Method      = 'POST'
        Body        =  ([System.Text.Encoding]::UTF8.GetBytes($JsonRequest))
        ContentType = 'application/json'
    }
    
    Invoke-RestMethod @params
}
