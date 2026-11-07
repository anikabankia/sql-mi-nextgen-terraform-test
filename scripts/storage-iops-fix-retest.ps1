<#
.SYNOPSIS
  Retest of the azurerm storage_iops fix (hashicorp/terraform-provider-azurerm#33778) with storage_iops in ignore_changes.
  s11 standard GP, s12 Business Critical: create with 5.12.0 -> plan on 5.12.0 (must fail) -> plan config variants, no-change
  apply and import on the fixed version -> destroy on the fixed version with ignore_changes still in place.
  s13 standard GP: create, plan and destroy on the fixed version only.
  Deploys a real MI unless -PrepareOnly is set. Output goes to results/.
.EXAMPLE
  ./scripts/storage-iops-fix-retest.ps1 -Scenario s11
.EXAMPLE
  ./scripts/storage-iops-fix-retest.ps1 -Scenario s11 -FixVersion 5.12.0 -PrepareOnly
#>
param(
  [Parameter(Mandatory)][ValidateSet('s11', 's12', 's13')][string]$Scenario,
  [string]$FixVersion = '5.13.0',
  [switch]$PrepareOnly
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$results = Join-Path $repo 'results'
$work = Join-Path $results "retest-$Scenario"
$status = Join-Path $results "$Scenario-status-retest.txt"
$varFile = Join-Path $repo "scenarios\$(@{ s11 = 's11-azurerm-standard-gp-fix-retest.tfvars'; s12 = 's12-azurerm-bc-fix-retest.tfvars'; s13 = 's13-azurerm-standard-gp-fix-create.tfvars' }[$Scenario])"
$rg = "rg-sqlmi-ng-$Scenario"
$base = '5.12.0'
$bug = 'can only be set when'
$addr = 'azurerm_mssql_managed_instance.this'
# Own cache: provider binaries in a cache shared with a running terraform are locked on Windows.
$env:TF_PLUGIN_CACHE_DIR = Join-Path $work 'plugin-cache'
Remove-Item Env:TF_WORKSPACE -ErrorAction SilentlyContinue

function Mark($msg) { "$(Get-Date -Format s) $msg" | Add-Content $status }

function StackDir($name) { Join-Path $work "$name\stacks\azurerm" }

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

# Copy of stacks/azurerm pinned to one version, with or without storage_iops in the config and in ignore_changes.
function Prepare($name, $v, [bool]$Ignore, [bool]$KeepIops = $true) {
  $dst = Join-Path $work $name
  New-Item -ItemType Directory -Force (Join-Path $dst 'stacks\azurerm') | Out-Null
  Copy-Item -Recurse -Force (Join-Path $repo 'modules') $dst
  $s = StackDir $name
  foreach ($f in 'main.tf', 'variables.tf', 'outputs.tf', 'providers.tf') { Copy-Item (Join-Path $repo "stacks\azurerm\$f") $s -Force }
  $main = Get-Content (Join-Path $s 'main.tf') -Raw
  if (-not $KeepIops) { $main = $main -replace '(?m)^\s*storage_iops\s*=\s*var\.storage_iops\r?\n', '' }
  if ($Ignore) { $main = $main -replace 'ignore_changes = \[azure_active_directory_administrator\]', 'ignore_changes = [azure_active_directory_administrator, storage_iops]' }
  Set-Content (Join-Path $s 'main.tf') $main -NoNewline
  $prov = Get-Content (Join-Path $s 'providers.tf') -Raw
  $prov = $prov -replace 'version = ">= 4\.78\.0"[^\r\n]*', "version = `"= $v`""
  Set-Content (Join-Path $s 'providers.tf') $prov -NoNewline
  Tf $name $s 'init' @('init', '-input=false') | Out-Null
  Tf $name $s 'validate' @('validate') | Out-Null
}

# Records whether a step matched the expected exit code and, for expected failures, the expected error text.
function Check($label, $name, $step, $code, $expected, $pattern) {
  $ok = $code -eq $expected
  if ($pattern) { $ok = $ok -and [bool](Select-String -Path (Join-Path $work "$name-$step.log") -Pattern $pattern -SimpleMatch -List) }
  Mark "$(if ($ok) { 'PASS' } else { 'FAIL' }) $label exit=$code expected=$expected"
}

function Plan($name, [string[]]$extra = @()) {
  Tf $name (StackDir $name) 'plan' (@('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") + $extra)
}

# Destroys with the given stack, then retries once the MI and virtual cluster are gone if the first attempt failed.
function Destroy($name) {
  $d = Tf $name (StackDir $name) 'destroy' @('destroy', '-input=false', '-auto-approve', "-var-file=$varFile")
  Check "destroy on $name" $name 'destroy' $d 0
  if ($d -ne 0) {
    $t = Get-Date
    do {
      $left = az resource list -g $rg --query "[?type=='Microsoft.Sql/managedInstances' || type=='Microsoft.Sql/virtualClusters'].name" -o tsv 2>$null
      if ($left) { Start-Sleep 120 }
    } while ($left -and ((Get-Date) - $t).TotalHours -lt 5)
    Mark "WAITED mi-and-virtual-cluster mins=$([math]::Round(((Get-Date) - $t).TotalMinutes, 1))"
    Tf $name (StackDir $name) 'destroy-retry' @('destroy', '-input=false', '-auto-approve', "-var-file=$varFile") | Out-Null
  }
}

if (-not $PrepareOnly) {
  $published = (Invoke-RestMethod 'https://registry.terraform.io/v1/providers/hashicorp/azurerm/versions').versions.version
  if ($FixVersion -notin $published) { throw "azurerm $FixVersion isn't on the Terraform registry yet. Nothing was deployed." }
}

Mark "BEGIN $Scenario fix retest pid=$PID fix=$FixVersion prepareOnly=$PrepareOnly"
New-Item -ItemType Directory -Force $env:TF_PLUGIN_CACHE_DIR | Out-Null

if ($Scenario -eq 's13') {
  $fix = "$FixVersion-ignore"
  Prepare $fix $FixVersion $true
  if ($PrepareOnly) { Mark 'DONE prepare-only'; return }
  $create = Tf $fix (StackDir $fix) 'apply' @('apply', '-input=false', '-auto-approve', "-var-file=$varFile")
  Check 'create on fixed version with ignore_changes' $fix 'apply' $create 0
  $mi = az sql mi list -g $rg -o json 2>$null | ConvertFrom-Json | Select-Object -First 1
  if ($mi) { Mark "SHOW after-create name=$($mi.name) state=$($mi.state) sku=$($mi.sku.name) gpv2=$($mi.isGeneralPurposeV2) iops=$($mi.storageIOps)" }
  if ($create -eq 0) { Check 'plan after create' $fix 'plan' (Plan $fix) 0 }
  Destroy $fix
  Mark "VERIFY resource-group $rg exists=$(az group exists -n $rg)"
  Mark 'DONE'
  return
}

$control = "$base-control"
$fix = "$FixVersion-ignore"
$noAttr = "$FixVersion-ignore-noattr"
$noIgnore = "$FixVersion-noignore"
$setIops = "$FixVersion-set1000"
$noChange = "$FixVersion-nochange"
$import = "$FixVersion-import"
Prepare $control $base $true
Prepare $fix $FixVersion $true
Prepare $noAttr $FixVersion $true $false
Prepare $noIgnore $FixVersion $false
Prepare $setIops $FixVersion $false
Prepare $noChange $FixVersion $true
Prepare $import $FixVersion $true
if ($PrepareOnly) { Mark 'DONE prepare-only'; return }

$create = Tf $control (StackDir $control) 'apply' @('apply', '-input=false', '-auto-approve', "-var-file=$varFile")
Check "create on $base with ignore_changes" $control 'apply' $create 0
$mi = az sql mi list -g $rg -o json 2>$null | ConvertFrom-Json | Select-Object -First 1
if ($mi) { Mark "SHOW after-create name=$($mi.name) state=$($mi.state) sku=$($mi.sku.name) gpv2=$($mi.isGeneralPurposeV2) iops=$($mi.storageIOps)" }

$destroyName = $control
if ($create -eq 0) {
  $state = Join-Path $work "state-created-by-$base.tfstate"
  Copy-Item (Join-Path (StackDir $control) 'terraform.tfstate') $state
  # Fresh copy of the state each time, so one step can't affect the next.
  foreach ($n in $fix, $noAttr, $noIgnore, $setIops, $noChange, $import) { Copy-Item $state (Join-Path (StackDir $n) 'terraform.tfstate') -Force }

  Check "control: $base plan still hits the bug" $control 'plan' (Plan $control) 1 $bug
  Check 'fixed version plan, storage_iops = null + ignore_changes' $fix 'plan' (Plan $fix) 0
  Check 'fixed version plan, no storage_iops + ignore_changes' $noAttr 'plan' (Plan $noAttr) 0
  Check 'fixed version plan, no ignore_changes' $noIgnore 'plan' (Plan $noIgnore) 0
  # The fix must not remove the validation: a real value on a non-Next-gen instance is still rejected.
  Check 'fixed version still rejects storage_iops = 1000 without Next-gen' $setIops 'plan' (Plan $setIops @('-var=storage_iops=1000')) 1 $bug

  $a = Tf $noChange (StackDir $noChange) 'apply-nochange' @('apply', '-input=false', '-auto-approve', "-var-file=$varFile")
  Check 'fixed version no-change apply' $noChange 'apply-nochange' $a 0
  Check 'fixed version plan after no-change apply' $noChange 'plan' (Plan $noChange) 0

  Tf $import (StackDir $import) 'state-rm' @('state', 'rm', $addr) | Out-Null
  $i = Tf $import (StackDir $import) 'import' @('import', '-input=false', "-var-file=$varFile", $addr, $mi.id)
  Check 'fixed version import' $import 'import' $i 0
  # Import doesn't read everything back, so the plan may propose changes; what matters is that it doesn't error.
  $p = Plan $import
  Check 'fixed version plan after import has no error' $import 'plan' ([int]($p -eq 1)) 0

  $destroyName = $fix
}

# Destroy on the fixed version with storage_iops still in ignore_changes and storage_iops=0 in state.
Destroy $destroyName
Mark "VERIFY resource-group $rg exists=$(az group exists -n $rg)"
Mark 'DONE'
