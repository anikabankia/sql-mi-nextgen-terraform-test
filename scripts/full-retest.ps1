<#
.SYNOPSIS
  Retests every customer question on one azurerm version (default 5.13.0). Deploys real Managed Instances unless -PrepareOnly is set.

  s20 no Azure resources: s02/s03 plan rejections, minimum provider versions, no flexible memory argument in azurerm
  s21 azurerm Next-gen GP, default IOPS: create, plan, ignore_changes plan, import, IOPS PATCH 1500 and 2000, azurerm IOPS and tags updates, destroy
  s22 azurerm Next-gen GP, storage_iops = 1500 at create: create, plan, azurerm IOPS update, destroy
  s23 azapi Next-gen GP + zone redundancy: create, plan, IOPS 1500, plan, destroy
  s24 azurerm BC + zone redundancy with storage_iops in ignore_changes: create, plans, no-change apply, import, destroy
  s25 flexible memory control, Sweden Central, GA API: premium-series Next-gen with no memory setting, then resize to 40 GB
  s26 flexible memory, Sweden Central, preview API: 40 GB at create, then resize to 48 GB
  s27 flexible memory, UK South, GA API: 40 GB at create, then resize to 48 GB
  s28 standard GP created on 4.77.0, then plan, no-change apply, plan and destroy on the target version
  s29 Business Critical, same as s28

  Output: results/<scenario>-status-full.txt (PASS/FAIL/RESULT lines) and logs in results/full-<scenario>/.
  RESULT lines record an outcome where no single outcome is expected.
.EXAMPLE
  ./scripts/full-retest.ps1 -Scenario s20
.EXAMPLE
  ./scripts/full-retest.ps1 -Scenario s21 -PrepareOnly
#>
param(
  [Parameter(Mandatory)][ValidateSet('s20', 's21', 's22', 's23', 's24', 's25', 's26', 's27', 's28', 's29')][string]$Scenario,
  [string]$Version = '5.13.0',
  [switch]$PrepareOnly
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$results = Join-Path $repo 'results'
$work = Join-Path $results "full-$Scenario"
$status = Join-Path $results "$Scenario-status-full.txt"
$rg = "rg-sqlmi-ng-$Scenario"
$addr = 'azurerm_mssql_managed_instance.this'
$readApi = '2025-08-01-preview'
$bug = 'can only be set when'
# Own cache: provider binaries in a cache shared with a running terraform are locked on Windows.
$env:TF_PLUGIN_CACHE_DIR = Join-Path $work 'plugin-cache'
Remove-Item Env:TF_WORKSPACE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $env:TF_PLUGIN_CACHE_DIR | Out-Null

$gen5Azapi = 'sku_name = "GP_Gen5"', 'sku_tier = "GeneralPurpose"', 'sku_family = "Gen5"', 'is_general_purpose_v2 = true'
$g8imAzapi = 'sku_name = "GP_G8IM"', 'sku_tier = "GeneralPurpose"', 'sku_family = "G8IM"', 'is_general_purpose_v2 = true', 'zone_redundant = false', 'backup_storage_redundancy = "Local"'
$vars = @{
  s21 = 'sku_name = "GP_Gen5"', 'general_purpose_v2_enabled = true', 'zone_redundant_enabled = false', 'storage_account_type = "LRS"'
  s22 = 'sku_name = "GP_Gen5"', 'general_purpose_v2_enabled = true', 'storage_iops = 1500', 'zone_redundant_enabled = false', 'storage_account_type = "LRS"'
  s23 = $gen5Azapi + 'zone_redundant = true', 'backup_storage_redundancy = "Zone"'
  s24 = 'sku_name = "BC_Gen5"', 'general_purpose_v2_enabled = false', 'zone_redundant_enabled = true', 'storage_account_type = "ZRS"'
  s25 = $g8imAzapi + 'location = "swedencentral"'
  s26 = $g8imAzapi + 'location = "swedencentral"', 'memory_size_in_gb = 40', 'api_version = "2026-08-01-preview"'
  s27 = $g8imAzapi + 'location = "uksouth"', 'memory_size_in_gb = 40'
  s28 = 'sku_name = "GP_Gen5"', 'general_purpose_v2_enabled = false', 'zone_redundant_enabled = false', 'storage_account_type = "LRS"'
  s29 = 'sku_name = "BC_Gen5"', 'general_purpose_v2_enabled = false', 'zone_redundant_enabled = false', 'storage_account_type = "LRS"'
}
$varFile = Join-Path $work "$Scenario.tfvars"
if ($vars[$Scenario]) {
  $n = [int]$Scenario.Substring(1)
  (@("scenario = `"$Scenario`"", "address_space = `"10.60.$n.0/24`"") + $vars[$Scenario]) | Set-Content $varFile
}

function Mark($msg) { "$(Get-Date -Format s) $msg" | Add-Content $status }

function StackDir($name, $stack = 'azurerm') { Join-Path $work "$name\stacks\$stack" }

function Tf($name, $dir, $step, [string[]]$tfArgs) {
  $log = Join-Path $work "$name-$step.log"
  Mark "START $name $step"
  $t = Get-Date
  Push-Location $dir
  terraform @tfArgs -no-color *>&1 | Tee-Object $log | Out-Null
  $code = $LASTEXITCODE
  Pop-Location
  $err = (Select-String -Path $log -Pattern 'Error:' -List | Select-Object -First 1).Line
  Mark "END $name $step exit=$code mins=$([math]::Round(((Get-Date) - $t).TotalMinutes, 1)) $err"
  return $code
}

# Copy of one stack pinned to one provider version. Ignore adds storage_iops to ignore_changes; KeepIops = false removes the argument.
function Prepare($name, $v, $stack = 'azurerm', [bool]$Ignore = $false, [bool]$KeepIops = $true, $CreateTimeout = $null) {
  $dst = Join-Path $work $name
  $s = StackDir $name $stack
  New-Item -ItemType Directory -Force $s | Out-Null
  Copy-Item -Recurse -Force (Join-Path $repo 'modules') $dst
  Copy-Item (Join-Path $repo "stacks\$stack\*.tf") $s -Force
  $main = Get-Content (Join-Path $s 'main.tf') -Raw
  if (-not $KeepIops) {
    $main = $main -replace '(?m)^\s*storage_iops\s*=\s*var\.storage_iops\r?\n', ''
    $o = Join-Path $s 'outputs.tf'
    (Get-Content $o -Raw) -replace '(?s)output "storage_iops" \{.*?\}\r?\n(\r?\n)?', '' | Set-Content $o -NoNewline
  }
  if ($Ignore) { $main = $main -replace 'ignore_changes = \[azure_active_directory_administrator\]', 'ignore_changes = [azure_active_directory_administrator, storage_iops]' }
  if ($CreateTimeout) { $main = $main -replace 'create = "24h"', "create = `"$CreateTimeout`"" }
  Set-Content (Join-Path $s 'main.tf') $main -NoNewline
  $pf = Join-Path $s 'providers.tf'
  (Get-Content $pf -Raw) -replace 'version = ">= 4\.78\.0"[^\r\n]*', "version = `"= $v`"" | Set-Content $pf -NoNewline
  Tf $name $s 'init' @('init', '-input=false') | Out-Null
  Tf $name $s 'validate' @('validate') | Out-Null
}

# Records whether a step matched the expected exit code and, for expected failures, the expected error text.
function Check($label, $name, $step, $code, $expected, $pattern) {
  $ok = $code -eq $expected
  if ($pattern) { $ok = $ok -and [bool](Select-String -Path (Join-Path $work "$name-$step.log") -Pattern $pattern -SimpleMatch -List) }
  Mark "$(if ($ok) { 'PASS' } else { 'FAIL' }) $label exit=$code expected=$expected"
}

# Records an outcome with no single expected value: the exit code, the plan summary and the first error.
function Result($label, $name, $step, $code) {
  $log = Join-Path $work "$name-$step.log"
  $sum = (Select-String -Path $log -Pattern '^(Plan:|No changes|Apply complete|Changes to Outputs|Terraform will perform|Terraform detected|Note: Objects have changed)' | ForEach-Object { $_.Line }) -join ' / '
  $err = (Select-String -Path $log -Pattern 'RequestDisallowedByPolicy|InternalServerError|Error:' | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() }) -join ' / '
  Mark "RESULT $label exit=$code $sum $err"
}

function Plan($name, $stack, [string[]]$extra = @()) {
  Tf $name (StackDir $name $stack) 'plan' (@('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") + $extra)
}

function PlanAs($name, $stack, $step, [string[]]$extra = @()) {
  Tf $name (StackDir $name $stack) $step (@('plan', '-input=false', '-detailed-exitcode', "-var-file=$varFile") + $extra)
}

function Apply($name, $stack, $step, [string[]]$extra = @()) {
  Tf $name (StackDir $name $stack) $step (@('apply', '-input=false', '-auto-approve', "-var-file=$varFile") + $extra)
}

# What Azure stored, read with a recent API version because older versions omit some properties.
function Show($step) {
  $sub = az account show --query id -o tsv
  $raw = az rest --method get --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Sql/managedInstances?api-version=$readApi" -o json 2>$null | ConvertFrom-Json
  $mi = $raw.value | Select-Object -First 1
  if (-not $mi) { Mark "SHOW $step no MI in $rg"; return $null }
  $mi | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $work "show-$step.json")
  $p = $mi.properties
  Mark "SHOW $step name=$($mi.name) state=$($p.state) sku=$($mi.sku.name) gpv2=$($p.isGeneralPurposeV2) zr=$($p.zoneRedundant) iops=$($p.storageIOps) memGb=$($p.memorySizeInGB) backup=$($p.requestedBackupStorageRedundancy)"
  return $mi
}

function CheckValue($label, $actual, $expected) {
  Mark "$(if ("$actual" -eq "$expected") { 'PASS' } else { 'FAIL' }) $label actual=$actual expected=$expected"
}

function WriteHistory {
  $sum = az monitor activity-log list -g $rg --offset 24h --query "[?operationName.value=='Microsoft.Sql/managedInstances/write' && status.value=='Failed'].{time:eventTimestamp,sub:subStatus.value,corr:correlationId}" -o json 2>$null
  $sum | Set-Content (Join-Path $work 'failed-mi-writes.json')
  $n = ($sum | ConvertFrom-Json | Measure-Object).Count
  Mark "RESULT failed Managed Instance writes in the activity log count=$n"
}

# Destroys with the given stack, then retries once the MI and virtual cluster are gone if the first attempt failed.
function Destroy($name, $stack) {
  $d = Tf $name (StackDir $name $stack) 'destroy' @('destroy', '-input=false', '-auto-approve', "-var-file=$varFile")
  Check "destroy on $name" $name 'destroy' $d 0
  if ($d -ne 0) {
    $t = Get-Date
    do {
      $left = az resource list -g $rg --query "[?type=='Microsoft.Sql/managedInstances' || type=='Microsoft.Sql/virtualClusters'].name" -o tsv 2>$null
      if ($left) { Start-Sleep 120 }
    } while ($left -and ((Get-Date) - $t).TotalHours -lt 5)
    Mark "WAITED mi-and-virtual-cluster mins=$([math]::Round(((Get-Date) - $t).TotalMinutes, 1))"
    $r = Tf $name (StackDir $name $stack) 'destroy-retry' @('destroy', '-input=false', '-auto-approve', "-var-file=$varFile")
    Check "destroy retry on $name" $name 'destroy-retry' $r 0
  }
}

function Finish {
  Mark "VERIFY resource-group $rg exists=$(az group exists -n $rg)"
  Mark 'DONE'
}

function CopyState($from, $to, $stack = 'azurerm') { Copy-Item (Join-Path (StackDir $from $stack) 'terraform.tfstate') (Join-Path (StackDir $to $stack) 'terraform.tfstate') -Force }

Mark "BEGIN $Scenario full retest pid=$PID version=$Version prepareOnly=$PrepareOnly"

switch ($Scenario) {
  's20' {
    # Rejections on the target version, from the repo's own scenario files.
    $p = "$Version-plan"
    Prepare $p $Version
    $d = StackDir $p
    $c = Tf $p $d 'plan-s02' @('plan', '-input=false', "-var-file=$(Join-Path $repo 'scenarios\s02-azurerm-nextgen-bc.tfvars')")
    Check 'azurerm rejects Business Critical + Next-gen at plan' $p 'plan-s02' $c 1 'cannot be set to `true` on Business Critical SKUs'
    $c = Tf $p $d 'plan-s03' @('plan', '-input=false', "-var-file=$(Join-Path $repo 'scenarios\s03-azurerm-nextgen-zr.tfvars')")
    Check 'azurerm rejects Next-gen + zone redundancy at plan' $p 'plan-s03' $c 1 '`zone_redundant_enabled` cannot be set to `true` when `general_purpose_v2_enabled` is `true`'
    # Flexible memory argument in the provider schema.
    Push-Location $d
    $attrs = (terraform providers schema -json | ConvertFrom-Json -Depth 100 -AsHashtable).provider_schemas['registry.terraform.io/hashicorp/azurerm'].resource_schemas['azurerm_mssql_managed_instance'].block.attributes.Keys
    Pop-Location
    CheckValue "azurerm $Version has no memory argument on the Managed Instance resource" (@($attrs | Where-Object { $_ -match 'memory' }).Count) 0
    # Minimum versions.
    foreach ($t in @(
        @{ V = '4.67.0'; Keep = $false; Exit = 1; Pattern = 'An argument named "general_purpose_v2_enabled" is not expected here' },
        @{ V = '4.68.0'; Keep = $false; Exit = 0; Pattern = $null },
        @{ V = '4.77.0'; Keep = $true; Exit = 1; Pattern = 'An argument named "storage_iops" is not expected here' },
        @{ V = '4.78.0'; Keep = $true; Exit = 0; Pattern = $null })) {
      Prepare "v$($t.V)" $t.V 'azurerm' $false $t.Keep
      $c = Tf "v$($t.V)" (StackDir "v$($t.V)") 'validate2' @('validate')
      Check "azurerm $($t.V) validate" "v$($t.V)" 'validate2' $c $t.Exit $t.Pattern
    }
    # The azapi stack still plans for the zone-redundant workaround.
    Prepare "$Version-azapi" $Version 'azapi'
    $c = Tf "$Version-azapi" (StackDir "$Version-azapi" 'azapi') 'plan-s04' @('plan', '-input=false', '-detailed-exitcode', "-var-file=$(Join-Path $repo 'scenarios\s04-azapi-nextgen-zr.tfvars')")
    Check 'azapi Next-gen + zone redundancy plans' "$Version-azapi" 'plan-s04' $c 2
    Mark 'DONE'
  }

  's21' {
    $m = "$Version-main"; $ig = "$Version-ignore"; $im = "$Version-import"; $up = "$Version-azurerm-iops"; $tg = "$Version-azurerm-tags"
    Prepare $m $Version
    Prepare $ig $Version 'azurerm' $true
    Prepare $im $Version
    Prepare $up $Version
    Prepare $tg $Version
    $tm = Join-Path (StackDir $tg) 'main.tf'
    (Get-Content $tm -Raw) -replace '(?m)^(\s*)tags = local\.tags(\r?\n\r?\n\s*# azure_active_directory_administrator)', '$1tags = merge(local.tags, { retest = "tags-only" })$2' | Set-Content $tm -NoNewline
    if ($PrepareOnly) { Mark 'DONE prepare-only'; return }

    $c = Apply $m 'azurerm' 'apply'
    Check 'create Next-gen GP with azurerm' $m 'apply' $c 0
    $mi = Show 'after-create'
    if ($c -eq 0 -and $mi) {
      CheckValue 'Azure reports Next-gen on' $mi.properties.isGeneralPurposeV2 'True'
      CheckValue 'SKU stays GP_Gen5' $mi.sku.name 'GP_Gen5'
      CheckValue 'default IOPS is 768 for 256 GB' $mi.properties.storageIOps 768
      Check 'plan after create' $m 'plan' (Plan $m 'azurerm') 0
      CopyState $m $ig
      Check 'plan with storage_iops in ignore_changes on Next-gen' $ig 'plan' (Plan $ig 'azurerm') 0

      CopyState $m $im
      Tf $im (StackDir $im) 'state-rm' @('state', 'rm', $addr) | Out-Null
      $i = Tf $im (StackDir $im) 'import' @('import', '-input=false', "-var-file=$varFile", $addr, $mi.id)
      Check 'import without storage_iops in ignore_changes' $im 'import' $i 0
      $p = Plan $im 'azurerm'
      Result 'plan after import' $im 'plan' $p

      foreach ($iops in 1500, 2000) {
        $a = Apply $m 'azurerm' "apply-patch-$iops" @("-var=storage_iops_patch=$iops")
        Check "azapi PATCH IOPS to $iops" $m "apply-patch-$iops" $a 0
        $s = Show "after-patch-$iops"
        CheckValue "Azure reports IOPS $iops" $s.properties.storageIOps $iops
        CheckValue "instance Ready after IOPS $iops" $s.properties.state 'Ready'
        $p = PlanAs $m 'azurerm' "plan-after-patch-$iops" @("-var=storage_iops_patch=$iops")
        Result "plan after PATCH to $iops, stack without storage_iops in ignore_changes" $m "plan-after-patch-$iops" $p
      }

      # Run on copies of the state: a failed azurerm update can leave state out of step with Azure.
      CopyState $m $up
      $u = Apply $up 'azurerm' 'apply' @('-var=storage_iops=2500', '-var=storage_iops_patch=2000')
      Result 'azurerm storage_iops update to 2500 under the Entra-only policy' $up 'apply' $u
      Show 'after-azurerm-iops' | Out-Null
      CopyState $m $tg
      $u = Apply $tg 'azurerm' 'apply' @('-var=storage_iops_patch=2000')
      Result 'azurerm tags-only update under the Entra-only policy' $tg 'apply' $u
      Show 'after-azurerm-tags' | Out-Null
    }
    Destroy $m 'azurerm'
    Finish
  }

  's22' {
    $m = "$Version-main"; $up = "$Version-azurerm-iops"
    Prepare $m $Version
    Prepare $up $Version
    if ($PrepareOnly) { Mark 'DONE prepare-only'; return }
    $c = Apply $m 'azurerm' 'apply'
    Check 'create Next-gen GP with storage_iops = 1500 through azurerm' $m 'apply' $c 0
    $mi = Show 'after-create'
    if ($c -eq 0 -and $mi) {
      CheckValue 'Azure reports IOPS 1500 from create' $mi.properties.storageIOps 1500
      Check 'plan after create' $m 'plan' (Plan $m 'azurerm') 0
      CopyState $m $up
      $u = Apply $up 'azurerm' 'apply' @('-var=storage_iops=2500')
      Result 'azurerm storage_iops update to 2500 under the Entra-only policy' $up 'apply' $u
      Show 'after-azurerm-iops' | Out-Null
    }
    Destroy $m 'azurerm'
    Finish
  }

  's23' {
    $m = "$Version-main"
    Prepare $m $Version 'azapi'
    if ($PrepareOnly) { Mark 'DONE prepare-only'; return }
    $c = Apply $m 'azapi' 'apply'
    Check 'create Next-gen GP + zone redundancy with azapi' $m 'apply' $c 0
    $mi = Show 'after-create'
    if ($c -eq 0 -and $mi) {
      CheckValue 'Azure reports Next-gen on' $mi.properties.isGeneralPurposeV2 'True'
      CheckValue 'Azure reports zone redundancy on' $mi.properties.zoneRedundant 'True'
      Check 'plan after create' $m 'plan' (Plan $m 'azapi') 0
      $a = Apply $m 'azapi' 'apply-iops-1500' @('-var=storage_iops=1500')
      Check 'azapi IOPS change to 1500' $m 'apply-iops-1500' $a 0
      $s = Show 'after-iops-1500'
      CheckValue 'Azure reports IOPS 1500' $s.properties.storageIOps 1500
      Check 'plan after IOPS change' $m 'plan-after-iops' (PlanAs $m 'azapi' 'plan-after-iops' @('-var=storage_iops=1500')) 0
    }
    Destroy $m 'azapi'
    Finish
  }

  's24' {
    $m = "$Version-ignore"; $no = "$Version-noignore"; $nc = "$Version-nochange"; $im = "$Version-import"
    Prepare $m $Version 'azurerm' $true
    Prepare $no $Version
    Prepare $nc $Version 'azurerm' $true
    Prepare $im $Version 'azurerm' $true
    if ($PrepareOnly) { Mark 'DONE prepare-only'; return }
    $c = Apply $m 'azurerm' 'apply'
    Check 'create zone-redundant BC with storage_iops in ignore_changes' $m 'apply' $c 0
    $mi = Show 'after-create'
    if ($c -eq 0 -and $mi) {
      CheckValue 'Azure reports zone redundancy on' $mi.properties.zoneRedundant 'True'
      Check 'plan with ignore_changes' $m 'plan' (Plan $m 'azurerm') 0
      CopyState $m $no
      Check 'plan without ignore_changes' $no 'plan' (Plan $no 'azurerm') 0
      CopyState $m $nc
      $a = Apply $nc 'azurerm' 'apply-nochange'
      Check 'no-change apply' $nc 'apply-nochange' $a 0
      Check 'plan after no-change apply' $nc 'plan' (Plan $nc 'azurerm') 0
      CopyState $m $im
      Tf $im (StackDir $im) 'state-rm' @('state', 'rm', $addr) | Out-Null
      $i = Tf $im (StackDir $im) 'import' @('import', '-input=false', "-var-file=$varFile", $addr, $mi.id)
      Check 'import' $im 'import' $i 0
      $p = Plan $im 'azurerm'
      Result 'plan after import' $im 'plan' $p
    }
    Destroy $m 'azurerm'
    Finish
  }

  { $_ -in 's25', 's26', 's27' } {
    $m = "$Version-main"
    # azapi retries a 500 until the timeout; s08 kept retrying for hours. Bound it, while leaving room for a normal 2.5-hour create.
    Prepare $m $Version 'azapi' $false $true '5h'
    if ($PrepareOnly) { Mark 'DONE prepare-only'; return }
    $target = if ($Scenario -eq 's25') { 40 } else { 48 }
    $c = Apply $m 'azapi' 'apply'
    Result 'create premium-series Next-gen GP' $m 'apply' $c
    $mi = Show 'after-create'
    if ($c -eq 0 -and $mi) {
      Check 'plan after create' $m 'plan' (Plan $m 'azapi') 0
      $a = Apply $m 'azapi' "apply-memory-$target" @("-var=memory_size_in_gb=$target")
      Result "resize flexible memory to $target GB" $m "apply-memory-$target" $a
      $s = Show "after-memory-$target"
      if ($a -eq 0) {
        CheckValue "Azure reports $target GB" $s.properties.memorySizeInGB $target
        Check 'plan after resize' $m 'plan-after-memory' (PlanAs $m 'azapi' 'plan-after-memory' @("-var=memory_size_in_gb=$target")) 0
      }
    }
    WriteHistory
    Destroy $m 'azapi'
    Finish
  }

  { $_ -in 's28', 's29' } {
    $old = '4.77.0-main'; $new = "$Version-upgraded"; $nc = "$Version-nochange"
    Prepare $old '4.77.0' 'azurerm' $false $false
    Prepare $new $Version 'azurerm' $false $false
    Prepare $nc $Version 'azurerm' $false $false
    if ($PrepareOnly) { Mark 'DONE prepare-only'; return }
    $c = Apply $old 'azurerm' 'apply'
    Check 'create on 4.77.0' $old 'apply' $c 0
    Show 'after-create' | Out-Null
    $destroyName = $old
    if ($c -eq 0) {
      CopyState $old $new
      CopyState $old $nc
      Check "plan on $Version with state written by 4.77.0" $new 'plan' (Plan $new 'azurerm') 0
      $a = Apply $nc 'azurerm' 'apply-nochange'
      Check "no-change apply on $Version" $nc 'apply-nochange' $a 0
      Check "plan on $Version after no-change apply" $nc 'plan' (Plan $nc 'azurerm') 0
      $destroyName = $nc
    }
    Destroy $destroyName 'azurerm'
    Finish
  }
}
