<#
.SYNOPSIS
  Provider-upgrade test on an existing non-Next-gen MI (s09 standard GP, s10 Business Critical): create with azurerm 4.77.0
  -> plan on each newer version -> no-change apply + plan on 4.78.0 and 5.11.0 -> ignore_changes / storage_iops = null
  variants on 5.11.0 -> destroy with 5.11.0 without ignore_changes. Deploys a real MI. Output goes to results/.
.EXAMPLE
  ./scripts/provider-upgrade-test.ps1 -Scenario s10
#>
param([Parameter(Mandatory)][ValidateSet('s09', 's10')][string]$Scenario)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$results = Join-Path $repo 'results'
$work = Join-Path $results "upgrade-$Scenario"
$status = Join-Path $results "$Scenario-status-upgrade.txt"
$varFile = Join-Path $repo "scenarios\$(@{ s09 = 's09-azurerm-standard-gp-upgrade.tfvars'; s10 = 's10-azurerm-bc-upgrade.tfvars' }[$Scenario])"
$rg = "rg-sqlmi-ng-$Scenario"
$base = '4.77.0'
$versions = @('4.78.0', '4.81.0', '5.0.0', '5.11.0', '5.12.0')
# Own cache: provider binaries in a cache shared with a running terraform are locked on Windows.
$env:TF_PLUGIN_CACHE_DIR = Join-Path $work 'plugin-cache'
Remove-Item Env:TF_WORKSPACE -ErrorAction SilentlyContinue

function Mark($msg) { "$(Get-Date -Format s) $msg" | Add-Content $status }

function StackDir($v) { Join-Path $work "$v\stacks\azurerm" }

# Copy of stacks/azurerm pinned to one version, with storage_iops removed (as a config written before 4.78 would be).
function Prepare($v) {
  $dst = Join-Path $work $v
  New-Item -ItemType Directory -Force (Join-Path $dst 'stacks\azurerm') | Out-Null
  Copy-Item -Recurse -Force (Join-Path $repo 'modules') $dst
  $s = StackDir $v
  foreach ($f in 'main.tf', 'variables.tf', 'outputs.tf', 'providers.tf') { Copy-Item (Join-Path $repo "stacks\azurerm\$f") $s -Force }
  $main = Get-Content (Join-Path $s 'main.tf') -Raw
  $main = $main -replace '(?m)^\s*storage_iops\s*=\s*var\.storage_iops\r?\n', ''
  $main = $main -replace 'ignore_changes = \[azure_active_directory_administrator, storage_iops\]', 'ignore_changes = [azure_active_directory_administrator]'
  Set-Content (Join-Path $s 'main.tf') $main -NoNewline
  $out = Get-Content (Join-Path $s 'outputs.tf') -Raw
  $out = $out -replace '(?s)output "storage_iops" \{.*?\}\r?\n\r?\n', ''
  Set-Content (Join-Path $s 'outputs.tf') $out -NoNewline
  $prov = Get-Content (Join-Path $s 'providers.tf') -Raw
  $prov = $prov -replace 'version = ">= 4\.78\.0"[^\r\n]*', "version = `"= $v`""
  Set-Content (Join-Path $s 'providers.tf') $prov -NoNewline
}

function StateIops($dir) {
  $f = Join-Path $dir 'terraform.tfstate'
  if (-not (Test-Path $f)) { return 'no-state' }
  $v = ((Get-Content $f -Raw | ConvertFrom-Json -Depth 100).resources | Where-Object type -eq 'azurerm_mssql_managed_instance' | ForEach-Object { $_.instances[0].attributes.storage_iops })
  if ($null -eq $v) { 'null' } else { $v }
}

function Tf($name, $dir, $step, [string[]]$tfArgs) {
  $log = Join-Path $work "$name-$step.log"
  Mark "START $name $step"
  $t = Get-Date
  Push-Location $dir
  terraform @tfArgs -no-color *>&1 | Tee-Object $log | Out-Null
  $code = $LASTEXITCODE
  Pop-Location
  $err = (Select-String -Path $log -Pattern 'Error:' -List | Select-Object -First 1).Line
  Mark "END $name $step exit=$code mins=$([math]::Round(((Get-Date) - $t).TotalMinutes, 1)) state.storage_iops=$(StateIops $dir) $err"
  return $code
}

Mark "BEGIN $Scenario upgrade test pid=$PID"
New-Item -ItemType Directory -Force $env:TF_PLUGIN_CACHE_DIR | Out-Null
foreach ($v in @($base) + $versions) {
  Prepare $v
  Tf $v (StackDir $v) 'init' @('init', '-input=false') | Out-Null
  Tf $v (StackDir $v) 'validate' @('validate') | Out-Null
}

$create = Tf $base (StackDir $base) 'apply' @('apply', '-input=false', '-auto-approve', "-var-file=$varFile")
$mi = az sql mi list -g $rg -o json 2>$null | ConvertFrom-Json | Select-Object -First 1
if ($mi) { Mark "SHOW after-create name=$($mi.name) state=$($mi.state) sku=$($mi.sku.name) gpv2=$($mi.isGeneralPurposeV2) iops=$($mi.storageIOps)" }

$destroyDir = StackDir $base
if ($create -eq 0) {
  $state = Join-Path $work 'state-created-by-4.77.0.tfstate'
  Copy-Item (Join-Path (StackDir $base) 'terraform.tfstate') $state
  Tf $base (StackDir $base) 'plan' @('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") | Out-Null
  foreach ($v in $versions) {
    # Fresh copy of the 4.77.0 state each time, so one version's state upgrade can't affect the next.
    Copy-Item $state (Join-Path (StackDir $v) 'terraform.tfstate') -Force
    Tf $v (StackDir $v) 'plan' @('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") | Out-Null
  }

  # A no-change apply saves the refreshed state (storage_iops=0 on 4.78+); plan again on top of it.
  foreach ($v in '4.78.0', '5.11.0') {
    Copy-Item $state (Join-Path (StackDir $v) 'terraform.tfstate') -Force
    Tf $v (StackDir $v) 'apply-nochange' @('apply', '-input=false', '-auto-approve', "-var-file=$varFile") | Out-Null
    Tf $v (StackDir $v) 'plan-after-apply' @('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") | Out-Null
  }

  # Config variants on 5.11.0, all on the persisted state from the no-change apply above.
  $variants = [ordered]@{
    'ignore'      = @{ Iops = $false; Ignore = $true }
    'null'        = @{ Iops = $true;  Ignore = $false }
    'null-ignore' = @{ Iops = $true;  Ignore = $true }
  }
  foreach ($k in $variants.Keys) {
    $dst = Join-Path $work "5.11.0-$k"
    Remove-Item -Recurse -Force $dst -ErrorAction SilentlyContinue
    Copy-Item -Recurse (Join-Path $work '5.11.0') $dst
    $s = Join-Path $dst 'stacks\azurerm'
    $main = Get-Content (Join-Path $s 'main.tf') -Raw
    if ($variants[$k].Iops)   { $main = $main -replace '(general_purpose_v2_enabled = var\.general_purpose_v2_enabled\r?\n)', "`$1  storage_iops               = null`n" }
    if ($variants[$k].Ignore) { $main = $main -replace 'ignore_changes = \[azure_active_directory_administrator\]', 'ignore_changes = [azure_active_directory_administrator, storage_iops]' }
    Set-Content (Join-Path $s 'main.tf') $main -NoNewline
    Tf "5.11.0-$k" $s 'plan' @('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") | Out-Null
  }
  $destroyDir = StackDir '5.11.0'
}

# Destroy with 5.11.0 and no ignore_changes (state has storage_iops=0) when the create succeeded.
$d = Tf 'destroy' $destroyDir 'destroy' @('destroy', '-input=false', '-auto-approve', "-var-file=$varFile")
if ($d -ne 0) {
  $t = Get-Date
  do {
    $left = az resource list -g $rg --query "[?type=='Microsoft.Sql/managedInstances' || type=='Microsoft.Sql/virtualClusters'].name" -o tsv 2>$null
    if ($left) { Start-Sleep 120 }
  } while ($left -and ((Get-Date) - $t).TotalHours -lt 5)
  Mark "WAITED mi-and-virtual-cluster mins=$([math]::Round(((Get-Date) - $t).TotalMinutes, 1))"
  Tf 'destroy' $destroyDir 'destroy-retry' @('destroy', '-input=false', '-auto-approve', "-var-file=$varFile") | Out-Null
}
Mark "VERIFY resource-group $rg exists=$(az group exists -n $rg)"
Mark 'DONE'
