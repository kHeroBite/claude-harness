# UI 자동화 테스트 러너 — PowerShell UIAutomation 직접 방식
# 사용법: powershell.exe -ExecutionPolicy Bypass -File run-ui-test.ps1 -ProcessName "MyApp" -TestScript "test.ps1"
param(
    [Parameter(Mandatory=$true)]
    [string]$ProcessName,

    [Parameter(Mandatory=$false)]
    [string]$TestScript,

    [Parameter(Mandatory=$false)]
    [string]$AutomationId,

    [Parameter(Mandatory=$false)]
    [string]$Value,

    [Parameter(Mandatory=$false)]
    [string]$Action = "verify"  # verify | click | setvalue | getvalue
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

# 프로세스 확인
$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Error "프로세스 '$ProcessName' 실행 중이지 않음"
    exit 1
}

Write-Host "프로세스 발견: $ProcessName (PID: $($proc.Id))"

# 앱 루트 찾기
$pidCond = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
$app = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $pidCond)

if (-not $app) {
    Write-Error "앱 UIAutomation 루트를 찾지 못함"
    exit 1
}

Write-Host "앱 연결 성공: $($app.Current.Name)"

# 외부 테스트 스크립트 실행
if ($TestScript -and (Test-Path $TestScript)) {
    . $TestScript
    exit 0
}

# AutomationId 기반 단순 검증
if ($AutomationId) {
    $cond = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
    $el = $app.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)

    if (-not $el) {
        Write-Error "AutomationId '$AutomationId' 컨트롤 없음"
        exit 1
    }

    Write-Host "컨트롤 발견: $AutomationId (IsEnabled=$($el.Current.IsEnabled))"

    switch ($Action) {
        "click" {
            $pat = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $pat.Invoke()
            Write-Host "클릭 완료"
        }
        "setvalue" {
            $pat = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $pat.SetValue($Value)
            Write-Host "값 설정 완료: $Value"
        }
        "getvalue" {
            $val = $el.GetCurrentPropertyValue([System.Windows.Automation.ValuePattern]::ValueProperty)
            Write-Host "값: $val"
        }
        default {
            Write-Host "컨트롤 상태 확인 완료 (IsEnabled=$($el.Current.IsEnabled))"
        }
    }
}

exit 0
