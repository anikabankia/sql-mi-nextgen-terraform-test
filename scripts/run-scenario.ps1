<#
.SYNOPSIS
  Run one or all Next-gen SQL MI scenarios.

.EXAMPLE
  ./scripts/run-scenario.ps1 -Scenario all -Action plan         # safe: plan-only matrix, writes results/summary-plan.md
  ./scripts/run-scenario.ps1 -Scenario s01 -Action apply        # deploys a real MI (hours, $$)
  ./scripts/run-scenario.ps1 -Scenario s01 -Action destroy
#>
param(
  [ValidateSet('all', 's01', 's02', 's03', 's04', 's05', 's06', 's07', 's08')]
  [string]$Scenario = 'all',
  [ValidateSet('plan', 'apply', 'destroy')]
  [string]$Action = 'plan',
  [string]$SubscriptionId = $env:ARM_SUBSCRIPTION_ID
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$scenarios = [ordered]@{
  s01 = @{ Stack = 'azurerm'; File = 's01-azurerm-nextgen-gp.tfvars';       Expect = 'plan OK' }
  s02 = @{ Stack = 'azurerm'; File = 's02-azurerm-nextgen-bc.tfvars';       Expect = 'plan FAIL' }
  s03 = @{ Stack = 'azurerm'; File = 's03-azurerm-nextgen-zr.tfvars';       Expect = 'plan FAIL' }
  s04 = @{ Stack = 'azapi';   File = 's04-azapi-nextgen-zr.tfvars';         Expect = 'plan OK (service decides on apply)' }
  s05 = @{ Stack = 'azurerm'; File = 's05-azurerm-bc-zr-baseline.tfvars';   Expect = 'plan OK' }
  s06 = @{ Stack = 'azapi';   File = 's06-azapi-nextgen-flexmem.tfvars';    Expect = 'plan OK (needs premium-series quota on apply)' }
  s07 = @{ Stack = 'azurerm'; File = 's07-azurerm-standard-gp.tfvars';      Expect = 'plan OK (failed after create while the stack ignored storage_iops)' }
  s08 = @{ Stack = 'azapi';   File = 's08-azapi-nextgen-flexmem-swedencentral.tfvars'; Expect = 'plan OK (apply returned 500 InternalServerError in testing)' }
}

if (-not $SubscriptionId) {
  $SubscriptionId = az account show --query id -o tsv
}
$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

$resultsDir = Join-Path $root 'results'
New-Item -ItemType Directory -Force $resultsDir | Out-Null

$ids = if ($Scenario -eq 'all') { $scenarios.Keys } else { @($Scenario) }
$summary = @()
$savedWorkspace = $env:TF_WORKSPACE

foreach ($id in $ids) {
  $s = $scenarios[$id]
  $stackDir = Join-Path $root "stacks/$($s.Stack)"
  $varFile = Join-Path $root "scenarios/$($s.File)"
  $log = Join-Path $resultsDir "$id-$Action.log"

  Write-Host "`n=== $id ($($s.Stack)) : $Action ===" -ForegroundColor Cyan
  Push-Location $stackDir
  try {
    if (-not (Test-Path .terraform)) { terraform init -input=false *> $null }
    # One workspace per scenario keeps state separate while sharing stack code.
    # TF_WORKSPACE (not `workspace select`) so scenarios on the same stack can run in parallel.
    $env:TF_WORKSPACE = $null
    if (-not (Test-Path "terraform.tfstate.d/$id")) { terraform workspace new $id *> $null }
    $env:TF_WORKSPACE = $id

    switch ($Action) {
      'plan'    { terraform plan -input=false -var-file="$varFile" -out="$id.tfplan" *>&1 | Tee-Object $log }
      'apply'   { terraform apply -input=false -auto-approve -var-file="$varFile" *>&1 | Tee-Object $log }
      'destroy' { terraform destroy -input=false -auto-approve -var-file="$varFile" *>&1 | Tee-Object $log }
    }
    $code = $LASTEXITCODE
  }
  finally {
    Pop-Location
    # Don't leave TF_WORKSPACE pointing at this scenario; a later terraform command would act on its state.
    $env:TF_WORKSPACE = $savedWorkspace
  }

  $firstError = (Select-String -Path $log -Pattern '^\s*│?\s*Error:' -List | Select-Object -First 1).Line
  $summary += [pscustomobject]@{
    Scenario = $id
    Stack    = $s.Stack
    Action   = $Action
    Expected = $s.Expect
    Result   = if ($code -eq 0) { 'OK' } else { 'FAIL' }
    Error    = if ($firstError) { $firstError.Trim(' ', '│') } else { '' }
  }
}

$summary | Format-Table -AutoSize -Wrap

$md = @("| Scenario | Stack | Action | Expected | Result | Error |", "|---|---|---|---|---|---|")
$md += $summary | ForEach-Object { "| $($_.Scenario) | $($_.Stack) | $($_.Action) | $($_.Expected) | $($_.Result) | $($_.Error -replace '\|', '/') |" }
$md | Set-Content (Join-Path $resultsDir "summary-$Action.md")
Write-Host "Summary written to results/summary-$Action.md"
