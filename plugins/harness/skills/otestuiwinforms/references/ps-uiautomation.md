# PowerShell UIAutomation 설정 가이드

## 사전 조건

- Windows 7+ (UIAutomationClient.dll 내장)
- .NET Framework 3.0+ (기본 설치됨)
- PowerShell 5.1 또는 PowerShell 7+

**NuGet 설치 불필요** — Windows 내장 어셈블리 사용.

## 어셈블리 로드

```powershell
Add-Type -AssemblyName UIAutomationClient   # 필수
Add-Type -AssemblyName UIAutomationTypes    # ControlType, TreeScope 등 상수
```

## WSL에서 실행

UIAutomation은 Windows 프로세스 — WSL에서 직접 실행 불가. 반드시 `powershell.exe`로 호출:

```bash
# WSL → Windows PowerShell 호출
powershell.exe -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName UIAutomationClient; ..."

# 스크립트 파일 실행
powershell.exe -ExecutionPolicy Bypass -File "/mnt/c/path/to/test.ps1"
# Windows 경로로 변환 필요:
powershell.exe -ExecutionPolicy Bypass -File "C:\\path\\to\\test.ps1"
```

## AutomationId 확인 방법

Inspect.exe (Windows SDK) 또는 아래 PowerShell로 확인:

```powershell
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement
$proc = Get-Process -Name "MyApp"
$cond = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
$app = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)

# 전체 트리 덤프
function Dump-Tree($el, $depth=0) {
    $indent = "  " * $depth
    Write-Host "$indent[$($el.Current.ControlType.ProgrammaticName)] Name='$($el.Current.Name)' AutoId='$($el.Current.AutomationId)'"
    $children = $el.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($child in $children) { Dump-Tree $child ($depth+1) }
}
Dump-Tree $app
```

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| FindFirst → null | AutomationId 없음 | Name 또는 ControlType으로 대체 |
| GetCurrentPattern 예외 | 패턴 미지원 컨트롤 | `TryGetCurrentPattern` 사용 |
| 앱 루트 못 찾음 | 관리자 권한 앱 | PowerShell을 관리자로 실행 |
| IsOffscreen=true | 최소화/숨김 상태 | 앱 활성화 후 재시도 |
