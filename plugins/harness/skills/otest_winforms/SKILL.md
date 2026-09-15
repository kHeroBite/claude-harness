---
name: otest_winforms
description: "WinForms/WPF UI 자동화 테스트 — FlaUI/UIAutomation. otest_ui에서 호출. 기존 otestuiwinforms 흡수."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest_ui"]
  calls: []
---

# otest_winforms — WinForms/WPF UI 자동화 테스트

PowerShell + Windows UIAutomation API 직접 방식. C# 컴파일 불필요 — 즉시 실행.

## 핵심 원칙

```yaml
방식: PowerShell에서 UIAutomationClient 어셈블리 직접 로드
속도: C# 컴파일(3~8초) 없이 즉시 실행
의존성: Windows 내장 (.NET Framework UIAutomation) — NuGet 설치 불필요
실행: Windows powershell.exe 전용 — WSL2 pwsh 절대 불가 (L-293)
  이유: UIAutomationClient는 Windows .NET Framework 어셈블리
        WSL2 pwsh는 .NET Core 기반 → TypeNotFound 발생
  WSL에서_호출: powershell.exe -ExecutionPolicy Bypass -Command "..." 또는 -File
  금지: WSL 내부 pwsh -Command / pwsh -File 사용
```

## 기본 패턴

### 앱 연결 + 루트 요소 취득

```powershell
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

# 프로세스명으로 앱 찾기
$proc = Get-Process -Name "MyApp" -ErrorAction SilentlyContinue
if (-not $proc) { throw "앱이 실행 중이지 않습니다" }

$cond = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
$app = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
```

### ⚠️ PS 5.1 TypeNotFound 우회 — 정적 캐스팅 실패 시 (L-606)

`Add-Type` 이 정상 실행됐는데도 `[System.Windows.Automation.AutomationElement]::RootElement` 가 **TypeNotFound** 로 실패하는 경우가 있다. PS 5.1 파서가 스크립트 파싱 시점에 타입 리터럴을 해석하려 하는데 그 시점에 어셈블리가 아직 반영되지 않기 때문이다. `[Type]::GetType(...)` 동적 로딩으로 우회한다.

```powershell
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# 정적 캐스팅이 TypeNotFound 로 실패하면 동적 로딩으로 폴백
$aeType = [Type]::GetType("System.Windows.Automation.AutomationElement, UIAutomationClient")
if (-not $aeType) { throw "AutomationElement 타입 로딩 실패" }

$root = $aeType::RootElement          # 정적 프로퍼티 접근은 타입 객체로 가능
# 또는 reflection 경유
# $root = $aeType.GetProperty("RootElement").GetValue($null)

# 조건 생성도 동일하게 타입 객체 경유
$pcType  = [Type]::GetType("System.Windows.Automation.PropertyCondition, UIAutomationClient")
$procIdProp = $aeType.GetField("ProcessIdProperty").GetValue($null)
$cond = [Activator]::CreateInstance($pcType, @($procIdProp, [object]$proc.Id))
```

**판정 순서**: ① 정적 캐스팅을 먼저 시도한다(가독성 우위). ② TypeNotFound 발생 시에만 위 동적 로딩으로 폴백한다.

### ⚠️ 좌표 클릭 금지 — AutomationId/Name 이 정본

멀티모니터 환경에서 보조 모니터는 **음수 좌표**를 가질 수 있다(실측: DISPLAY2 가 X=-2560). 좌표 기반 클릭은 이 환경에서 원천적으로 불안정하므로 사용하지 않는다. 이 스킬의 정본 접근은 **AutomationId → Name → ControlType** 순의 요소 검색이며, 조작은 `InvokePattern`/`ValuePattern` 으로 수행한다. 요소를 못 찾는 것을 좌표 클릭으로 우회하지 마라 — 그것은 검색 조건이 틀렸다는 신호다.

### 🔴 좌표 클릭이 불가피할 때 — `safe_click.ps1` 경유 ★필수★

위 금지가 원칙이다. 그러나 UIAutomation 이 도달하지 못하는 대상(커스텀 렌더링 컨트롤,
`ToolStripMenuItem` 미부여 항목, 오너드로우 셀 등)이 실재한다. 그 경우에만 아래를 지킨다.

```yaml
필수:
  - 물리 좌표 클릭은 ★.claude/scripts/safe_click.ps1 경유★ 로만 수행한다.
  - ★SetCursorPos / mouse_event / SendInput 직접 호출 금지★ (스크립트 안에서만 허용).
  - ★이미지 좌표를 스크린 좌표로 그대로 쓰지 마라★ — safe_click.ps1 의
    -ImageX/-ImageY 를 쓰거나 ConvertTo-ScreenX 를 경유한다.
  - ★-ExpectedProcessId 를 반드시 넘겨라★ — 미지정 시 창 소유권 검증이 스킵된다.

호출:
  powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File "C:\DATA\Project\MyApp\.claude\scripts\safe_click.ps1" \
    -ImageX 5600 -ImageY 500 -ExpectedProcessId <PID>
  # 검증만: -NoClick

파라미터:
  -Button <Left|Right|Middle>   기본 Left.
      ★헤더 컨텍스트 메뉴 등 우클릭 전용 UI 에는 -Button Right 필수★
      (util.DataGridView.cs:917  if (e.Button == MouseButtons.Right))
  -ExpectedWindowTitle <문자열>  선택. 최상위 창 제목 부분 일치 검사(가드 ④).
      ★②(PID)는 같은 앱의 다른 탭/폼도 통과시킨다★ — 탭 오인이 우려되면 지정하라.
  -Tolerance <픽셀>              기본 4. ③ DPI 사후 검증 허용 오차.
      ★SetProcessDPIAware 이후에도 ±2px 잔차가 실재한다★(실측). 0 은 과잉 엄격.
      픽셀 정밀도가 필요할 때만 -Tolerance 0. 추가

판정:
  - ★exit code 0 = 3축 검증 통과★. 0 이 아니면 클릭이 수행되지 않은 것이다.
  - ★rc 를 확인하지 않으면 실패를 알 수 없다.★ 2>/dev/null 로 stderr 를 버리지 마라.
```

**왜 스크립트를 거쳐야 하는가 (사이클41 실사고):**

```
tmp_stepC.ps1 이 SetCursorPos(5600, 100) 을 ★하드코딩★ 했다.
VirtualScreen 은 X=-2560 · W=7040 ⇒ Right=4480 ⇒ 5600 은 ★1120px 초과★.
원인은 ★대상 창을 한 번도 조회하지 않고 좌표를 추정 기입★ 한 것이다.
A/B 단계엔 변환을 적용했고 ★C 단계에만 빠뜨렸다★ (L-546 동형).

⚠️ 당시 스크립트에 WindowFromPoint 검사가 ★이미 있었다★.
   그러나 ★출력만 하고 중단하지 않아★ 무용지물이었다 (L-791 동형 —
   "반응했다" 와 "결과가 달라졌다" 는 다르다).
⇒ ★검사만 하고 exit 하지 않는 가드는 가드가 아니다.★
   safe_click.ps1 은 3축 전부 실패 시 ★throw★ 한다.
```

**이 가드가 못 잡는 것** — `safe_click.ps1` 상단 주석의 "사각지대" 절을 읽어라.
특히 `-ExpectedProcessId` 를 넘기지 않으면 ②가 통째로 스킵되어
**올바른 좌표로 엉뚱한 창을 클릭하는 사고는 막지 못한다.**

### 컨트롤 검색

```powershell
# AutomationId로 검색 (가장 안정적)
$cond = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "btnSearch")
$btn = $app.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)

# Name으로 검색
$cond = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "검색")
$btn = $app.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)

# ControlType으로 검색 (여러 개 반환)
$cond = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
$buttons = $app.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
```

### 컨트롤 조작

```powershell
# 버튼 클릭
$invokePattern = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$invokePattern.Invoke()

# 텍스트박스 입력
$valuePattern = $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$valuePattern.SetValue("검색어")

# 텍스트 읽기
$tb.Current.Name
$tb.GetCurrentPropertyValue([System.Windows.Automation.ValuePattern]::ValueProperty)

# 활성화/가시성 확인
$btn.Current.IsEnabled
$btn.Current.IsOffscreen  # true면 화면 밖
```

### 대기 패턴

```powershell
# 컨트롤이 나타날 때까지 대기 (최대 5초)
$timeout = 50  # 100ms × 50 = 5초
$found = $null
for ($i = 0; $i -lt $timeout; $i++) {
    $found = $app.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($found) { break }
    Start-Sleep -Milliseconds 100
}
if (-not $found) { throw "컨트롤을 찾지 못했습니다 (5초 초과)" }
```

## oinfra_{project} 설정 활용

프로젝트별 세부 정보는 `Skill('oinfra_{project}')` 호출로 취득:
- `process_name`: Get-Process에서 사용할 프로세스명
- `test_capabilities.ui_automation`: true일 때만 이 스킬 사용

## 테스트 스크립트 실행

```yaml
실행_방법:
  # WSL에서 Windows PowerShell 호출
  powershell.exe -ExecutionPolicy Bypass -File "C:\path\test.ps1"
  # 또는 인라인 스크립트
  powershell.exe -Command "Add-Type ...; ..."

결과_검증:
  - 컨트롤 상태 직접 읽기 ($btn.Current.IsEnabled 등)
  - 예외 발생 시 실패로 판정
  - exit code 0 = 성공, 0이 아님 = 실패
```

## WPF AutomationProperties 패턴

WPF 앱에서는 XAML에 `AutomationProperties`를 설정하여 UIAutomation 접근성을 확보:

```xml
<!-- XAML에서 AutomationId 설정 -->
<Button x:Name="btnSearch"
        AutomationProperties.AutomationId="btnSearch"
        AutomationProperties.Name="검색" />

<TextBox x:Name="txtInput"
         AutomationProperties.AutomationId="txtInput" />

<!-- ItemsControl/ListView 내부 아이템 -->
<ListView AutomationProperties.AutomationId="listResults">
    <ListView.ItemTemplate>
        <DataTemplate>
            <TextBlock AutomationProperties.AutomationId="{Binding Id}" />
        </DataTemplate>
    </ListView.ItemTemplate>
</ListView>
```

### WPF vs WinForms 차이점

```yaml
WinForms:
  AutomationId: Control.Name 속성이 자동 매핑
  검색: AutomationIdProperty로 바로 검색 가능

WPF:
  AutomationId: AutomationProperties.AutomationId 명시 설정 필요
  미설정_시: x:Name이 AutomationId로 Fallback (단, Style/Template 내부는 불가)
  권장: 테스트 대상 컨트롤에 AutomationProperties.AutomationId 명시적 설정

공통:
  PowerShell 검색 코드는 WinForms/WPF 동일 (UIAutomation API 공유)
  프로세스명만 oinfra_{project}.app_process_name으로 교체
```

## ItemsControl/반복 컨트롤 검증 필수 규칙 (L-425)

```yaml
DataItem_검증_2단계_필수:
  규칙: ItemsControl/ListBox/ListView 등 반복 컨트롤 검증 시 개수 확인만으로 PASS 불가
  필수_2단계:
    1_개수_확인: DataItem 또는 ListItem 수가 예상값과 일치
    2_Rect_좌표_분산: 각 아이템의 BoundingRectangle.Y 값이 서로 달라야 함 (분산 확인)
  판정_기준:
    PASS: 개수 일치 AND 각 Y 좌표가 모두 다름 (단조 증가 권장)
    FAIL: 모든 Y가 동일 → ItemsControl 겹침 (시각적 1개 표시) 증거
  이유: 개수=N이어도 모두 동일 Rect에 겹치면 사용자에게는 1개만 보임 — 레이아웃 버그 미감지
  발생_패턴: WPF ItemsControl + ItemsPanelTemplate=Grid 잘못된 RowDefinition → Y=동일값 겹침

  PowerShell_검증_예시:
    # DataItem 개수 + Rect Y 분산 동시 검증
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataItem)
    $items = $container.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    $count = $items.Count
    $yValues = $items | ForEach-Object { $_.Current.BoundingRectangle.Y }
    $uniqueYCount = ($yValues | Sort-Object -Unique).Count
    if ($count -gt 1 -and $uniqueYCount -eq 1) {
        throw "FAIL: DataItem $count개 모두 동일 Y=$($yValues[0]) — 겹침 감지"
    }
    Write-Host "PASS: DataItem $count개, Y분산=$uniqueYCount개 위치"
```

## 완료 증거파일 생성 (필수 — L-240)

otest_winforms 완료 시 반드시 실행:
```bash
UUID=$PIPELINE_UUID
touch $HOME/.claude/session-env/${UUID}/evidence/ui_test_done       # EXT4($HOME) — oio 불필요
touch $HOME/.claude/session-env/${UUID}/evidence/winforms_test_done  # EXT4($HOME) — C# 프로젝트 판별용
echo "✅ otest_winforms 증거파일 생성: ui_test_done + winforms_test_done"
```
이 명령 없이 odone으로 진입 시 ui_test_done_guard.sh hook에 의해 차단됨.

## 상세 참조

- 컨트롤 타입/패턴 목록: [references/control-reference.md](references/control-reference.md)
- PowerShell UIAutomation 설정: [references/ps-uiautomation.md](references/ps-uiautomation.md)
- 테스트 실행 스크립트: [scripts/run-ui-test.ps1](scripts/run-ui-test.ps1)
- 프로젝트별 AutomationId 목록: `Skill('oinfra_{project}')` 호출
