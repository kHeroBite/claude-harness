# FlaUI 컨트롤 타입별 API 레퍼런스

## 공통 패턴

```csharp
// 탐색
var el = window.FindFirstDescendant(cf => cf.ByAutomationId("id"));
var els = window.FindAllDescendants(cf => cf.ByControlType(ControlType.Button));

// null 안전 접근
var btn = el?.AsButton();
btn?.Click();
```

## 컨트롤별 API

### Button
```csharp
var btn = window.FindFirstDescendant(cf => cf.ByAutomationId("btnSave"))?.AsButton();
btn.Click();
btn.IsEnabled  // 활성화 여부
```

### TextBox
```csharp
var txt = window.FindFirstDescendant(cf => cf.ByAutomationId("txtName"))?.AsTextBox();
txt.Enter("입력값");     // 기존 내용 지우고 입력
txt.Text                 // 현재 값
txt.IsReadOnly           // 읽기전용 여부
```

### Label
```csharp
var lbl = window.FindFirstDescendant(cf => cf.ByAutomationId("lblStatus"))?.AsLabel();
lbl.Text  // 텍스트 값
```

### ComboBox
```csharp
var cmb = window.FindFirstDescendant(cf => cf.ByAutomationId("cmbType"))?.AsComboBox();
cmb.Select("옵션값");   // 값으로 선택
cmb.SelectedItem.Text   // 현재 선택값
```

### Checkbox
```csharp
var chk = window.FindFirstDescendant(cf => cf.ByAutomationId("chkactive"))?.AsCheckbox();
chk.IsChecked           // 체크 상태
chk.Toggle();           // 토글
```

### DataGridView
```csharp
var grid = window.FindFirstDescendant(cf => cf.ByAutomationId("dgvList"))?.AsDataGridView();
grid.Rows.Length        // 행 수
grid.Rows[0].Cells[1].Value  // 특정 셀 값
```

### Tab
```csharp
var tab = window.FindFirstDescendant(cf => cf.ByAutomationId("tabMain"))?.AsTab();
tab.SelectTabItem(1);   // 인덱스로 탭 선택
tab.SelectedTabItem.Name  // 현재 탭명
```

## Wait 패턴

```csharp
using FlaUI.Core.Tools;

// 요소 나타날 때까지 대기
var el = Retry.WhileNull(
    () => window.FindFirstDescendant(cf => cf.ByAutomationId("lblResult")),
    TimeSpan.FromSeconds(5)
).Result;

// 조건 충족까지 대기
Retry.WhileFalse(
    () => btn.IsEnabled,
    TimeSpan.FromSeconds(3)
);
```
