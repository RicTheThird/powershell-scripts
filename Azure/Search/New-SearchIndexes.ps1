<#
.SYNOPSIS
This script will deploy a list of Azure Search Indexes against a search service. It will delete any existing indexes first.
It has a built in limiter to ensure the API call count is not exceeded. When a defined number of API calls to create search indexes 
is hit, the process will pause for a defined number of seconds. This will stop the occurance of the "You are sending too many requests" error.

.PARAMETER IndexFolder
Folder where the JSON files representing search indexes. Will recursively search this folder to build a list of files to process

.PARAMETER SearchSiteName
Name of the Search Service to use

.PARAMETER ResourceGroupName
Name of the Resource Group the search service resides in.
Should only be used in Azure DevOps pipeline where the API Key won't be known.

.PARAMETER SearchAPIKey
Admin API Key for the search service. Should be populated when run from the command line.

.PARAMETER SearchAPIVersion
Sets the APIVersion to use. Defaults to "2019-05-06"

.PARAMETER MaxAPICallCount
The maximum number of API calls before the process is paused. Defaults to 20

.PARAMETER APICallPauseDuration
Defines how long to wait between groups of API calls. Defaults to 120 seconds

.EXAMPLE
.\New-SearchIndexes.ps1 -IndexFolder C:\Samples\ManyIndexes -SearchSiteName search-std-demo -SearchAPIKey D03F144619CDDDD43E32017D38B6D3E4

.NOTES
The Resource Group name should only be used in the Azure DevOps pipeline component.

#>


param (
    [Parameter(Mandatory)]
    [ValidateScript( { Test-Path -Path $_ -PathType Container })]
    [string] $IndexFolder,

    [Parameter(Mandatory)]
    [string] $SearchSiteName,

    [Parameter(Mandatory, ParameterSetName = 'ByResourceGroup')]
    [string] $ResourceGroupName = "",

    [Parameter(Mandatory, ParameterSetName = 'ByAPIKey')]
    [string] $SearchAPIKey = "",

    [string] $SearchAPIVersion = "2019-05-06",

    [int] $MaxAPICallCount = 20, # max number of requests before we pause so we dont get the "too many requests error". Defaults to 20

    [int] $APICallPauseDuration = 120   # defaults to 120 seconds
)

$indexFiles = Get-ChildItem -Path $IndexFolder -Filter *.json -Recurse

$ErrorActionPreference = "Stop"

# if the API key is not provided and the resource group is, then used the AzureRM.Search module to determine the Admin API Key.
# This is intended to be called inside of a Deployment pipeline in Azure DevOps where the AzureRM modules are available
if ($PSCmdlet.ParameterSetName -eq 'ByResourceGroup') {
    Write-Host "Search API Key was not provided, obtaining from search site $SearchSiteName in resource group $ResourceGroupName"
    
    Install-Module -Name AzureRM.Search -AllowPrerelease -Force
    # Get the Search Service Admin API Key
    $searchKeys = Get-AzureRmSearchAdminKeyPair -ResourceGroupName $ResourceGroupName -ServiceName $SearchSiteName

    if ($searchKeys -eq $null) {
        Write-Error "Unable to access the API Keys for search service $SearchSiteName in resource group $ResourceGroupName." 
    }
    $SearchAPIKey = $searchKeys.Primary
}

# build the header
$headers = @{"Content-Type" = "application/json"
             "api-key"      = $SearchAPIKey }

Write-Host "Using search service name: $SearchSiteName"

# get the list of existing indexes first
$indexesUrl = "https://$SearchSiteName.search.windows.net/indexes?api-version=$SearchAPIVersion"
$response = Invoke-RestMethod -Uri $indexesUrl -Headers $headers

$existingIndexes = $response.value.name
$apiCallCount = 0

if ($existingIndexes) {
    Write-Host "Deleting the existing indexes first. These are: $($existingIndexes -join ", ")"

    $existingIndexes | ForEach-Object { $indexName = $_
        $deleteIndexUrl = "https://$SearchSiteName.search.windows.net/indexes/$($indexName)?api-version=$SearchAPIVersion"
                                         
        try {
            if ($apiCallCount -ge $MaxAPICallCount) {
                Write-Host "Max API Call count of $MaxAPICallCount reached. Pausing for $APICallPauseDuration seconds."
                Start-Sleep -Seconds $APICallPauseDuration
                $apiCallCount = 0
            }
            $apiCallCount++
            $response = Invoke-WebRequest -Method Delete -Uri $deleteIndexUrl -Headers $headers
            if ($response.StatusCode -eq 204) {
                Write-Host "- $indexName deleted"
            }
            else {
                Write-Error "Issues with deleting index $_ with Url $deleteIndexUrl. Status code returned was $($response.StatusCode). Msg: $($response.StatusDescription)"
            }
        }
        catch {
            $summaryMsg = $_.Exception.Message
            $detailed = $_.ErrorDetails.Message | ConvertFrom-Json 
            $detailedMsg = $detailed.error.message
            Write-Error "Error with creating index $indexName with error: $summaryMsg. Detailed error: $detailedMsg"
        }
    }
}
Write-Host "Applying the following $($indexFiles.count) index files: "

$indexFiles | ForEach-Object { $indexData = Get-Content -Path $_.FullName -raw
    $filename = $_.Name
    try {
        if ($apiCallCount -ge $MaxAPICallCount) {
            Write-Host "Max API Call count of $MaxAPICallCount reached. Pausing for $APICallPauseDuration seconds."
            Start-Sleep -Seconds $APICallPauseDuration
            $apiCallCount = 0
        }
        $apiCallCount++
        $response = Invoke-WebRequest -Method Post -Uri $indexesUrl -Headers $headers -Body $indexData
        if ($response.StatusCode -eq 201) {
            Write-Host "- $filename applied"
        }
        else {
            Write-Error "Issues with creating index $filename with Url $indexesUrl. Status code returned was $($response.StatusCode). Msg: $($response.StatusDescription)"
        }
    }
    catch {
        $summaryMsg = $_.Exception.Message
        $detailed = $_.ErrorDetails.Message | ConvertFrom-Json 
        $detailedMsg = $detailed.error.message
        Write-Error "Error with creating index $filename. $summaryMsg. Detailed error: $detailedMsg"
    }
}

# get the list of indexes again and display what is there for confirmation
$response = Invoke-RestMethod -Uri $indexesUrl -Headers $headers
$existingIndexes = $response.value.name
Write-Host "List of indexes now created: $($existingIndexes -join ", ")"
                            
                                