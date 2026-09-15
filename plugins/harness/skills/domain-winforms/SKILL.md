---
name: domain-winforms
description: "WinForms UI 디자인 + MDI 폼 템플릿 통합. 레이아웃, DataGridView, MDI 관리, 폼 생명주기, 이벤트, 커스텀 컨트롤, 새 폼 생성 5단계. Auto-activates when: designing UI, creating forms, MDI patterns, layout, DataGridView, form lifecycle, Menu/MemberAuth sync."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev(UI)]
  calls: []
---

# domain-winforms -- WinForms UI + MDI 폼 템플릿

WinForms UI 디자인 베스트 프랙티스, 고급 개발 기법, MDI 자식 폼 생성 5단계를 통합한 범용 스킬.

## 사용 시점

- 새로운 폼 UI 디자인 / 기존 폼 레이아웃 개선
- 새 비즈니스 폼 추가 (MDI 자식 폼)
- DataGridView 스타일링 / 고급 기능
- 폼 생명주기 관리
- 커스텀 컨트롤 / 드래그 앤 드롭 / 스레드 동기화

---

## Part 1: UI 디자인 원칙

### 폰트 표준
```csharp
Font = new Font("맑은 고딕", 9F, FontStyle.Regular);  // 기본
Font = new Font("맑은 고딕", 11F, FontStyle.Bold);     // 제목
```

### 색상 팔레트
```csharp
public static class AppColors
{
    public static readonly Color Primary = Color.FromArgb(41, 128, 185);
    public static readonly Color Secondary = Color.FromArgb(52, 73, 94);
    public static readonly Color Success = Color.FromArgb(39, 174, 96);
    public static readonly Color Warning = Color.FromArgb(243, 156, 18);
    public static readonly Color Danger = Color.FromArgb(231, 76, 60);
    public static readonly Color Background = Color.FromArgb(236, 240, 241);
    public static readonly Color TextPrimary = Color.FromArgb(44, 62, 80);
    public static readonly Color Border = Color.FromArgb(189, 195, 199);
}
```

---

## Part 2: 레이아웃 패턴

- **FlowLayoutPanel**: 간단한 폼 (TopDown, AutoScroll)
- **TableLayoutPanel**: 정렬된 폼 (ColumnStyles 30/70%)
- **SplitContainer**: 좌우/상하 분할 (FixedPanel)
- **복합 레이아웃**: 검색(Dock.Top) + 그리드(Dock.Fill) + 버튼(Dock.Bottom)

### Anchor / Dock
```csharp
Button닫기.Anchor = AnchorStyles.Top | AnchorStyles.Right;
TextBox1.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
DataGridView1.Dock = Dockstyle.Fill;
Panel검색.Dock = Dockstyle.Top;
```

---

## Part 3: DataGridView

### 기본 스타일
```csharp
dgv.AllowUserToAddRows = false; dgv.ReadOnly = true;
dgv.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
dgv.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
dgv.RowHeadersVisible = false; dgv.BackgroundColor = Color.White;
```

### 헤더/셀/교차행/조건부 색상/가상화 모드
- 헤더: Primary 배경, Bold, 중앙정렬, Height=35
- 교차행: Background 색상
- 조건부: CellFormatting 이벤트로 상태별 색상
- 가상화: VirtualMode=true + CellValueNeeded 이벤트

---

## Part 4: MDI 관리

```csharp
// 중복 실행 방지
foreach (Form child in this.MdiChildren)
    if (child.Name == formName) { child.Activate(); return; }
var form = CreateForm(formName);
if (form != null) { form.MdiParent = this; form.Show(); }
```

---

## Part 5: 폼 생명주기

```yaml
열기: Constructor -> Load -> Shown -> Activated
전환: Deactivate -> Activated
닫기: FormClosing -> FormClosed -> Disposed
```

### 표준 패턴
```csharp
public partial class 폼명 : BaseForm
{
    private bool isFirstShownLoaded = false;
    // Load: 가벼운 초기화 (콤보박스, 초기값)
    // Shown: 무거운 작업 (isFirstShownLoaded 체크 후 데이터 로드)
    // FormClosing: 리소스 정리
}
```

---

## Part 6: 이벤트 처리

### Lambda 클로저 회피
```csharp
for (int i = 0; i < 10; i++)
{
    int index = i;  // 지역 변수로 복사
    btn.Click += (s, e) => MessageBox.Show($"클릭: {index}");
}
```

### 사용자 정의 이벤트
```csharp
public event EventHandler<DataChangedEventArgs> DataChanged;
protected virtual void OnDataChanged(DataChangedEventArgs e)
    => DataChanged?.Invoke(this, e);
```

---

## Part 7: 커스텀 컨트롤 / 드래그 앤 드롭

- UserControl: 속성 + 이벤트 노출 + OnPaint 커스텀 렌더링
- DraggablePanel: MouseDown/MouseMove로 위치 변경
- 파일 드래그: DragEnter(FileDrop) + DragDrop

---

## Part 8: 스레드와 UI

```csharp
// async/await 패턴 (권장)
private async void Button_Click(object sender, EventArgs e)
{
    Button1.Enabled = false;
    var result = await Task.Run(() => LoadData());
    DataGridView1.DataSource = result;
    Button1.Enabled = true;
}
```

---

## Part 9: 반응형 레이아웃 / 접근성

- MinimumSize / MaximumSize 설정
- SizeChanged로 Orientation 전환
- AcceptButton(Enter) / CancelButton(Esc) / ProcessCmdKey
- ToolTip / 고대비 모드 (SystemInformation.HighContrast)

---

## Part 10: MDI 폼 생성 5단계

### 1단계: 폼 클래스 생성

```csharp
public partial class 새폼명 : MDI공통
{
    private bool isFirstShownLoaded = false;

    public 새폼명()
    {
        base.ID = "NNNN";  // Menu 테이블의 ID와 동일 (프로젝트별 DB는 oinfra_{project} 참조)
        this.DoubleBuffered = true;
        Ov윈도우Init();
    }

    public override void Ov윈도우Init()
    {
        isFirstShownLoaded = false;
        // base.titleName, minHeight, defaultWidth 등 설정
        InitializeComponent();
    }

    public override void Ov윈도우Load() { base.Ov윈도우Load(); /* 가벼운 초기화 */ }

    public override void Ov윈도우Shown()
    {
        if (isFirstShownLoaded) return;
        isFirstShownLoaded = true;
        // 무거운 작업 (데이터 로드)
    }
}
```

### 2단계: Designer 파일 생성
- components, Dispose, InitializeComponent 표준 구조
- Panel본문은 MDI공통에서 자동 생성 (Designer에서 추가 금지)
- ★`ApplyResources` 는 .resx 에 키가 없으면 no-op 으로 실패해 메뉴가 빈 칸으로 뜬다(2026-09-15
  사이클131/132 L-1070). .resx 는 .cs 와 별도 파일이라 순서 보장이 없어 hook 물리 차단이
  불가능하다 — resx 키 존재를 직접 확인하거나, 아예 회피(텍스트/이미지를 코드에서 직접
  대입)하는 쪽을 표준으로 권장한다.

### 3단계: Menu 테이블 등록 (MCP)
```sql
-- SET NAMES utf8 -> MAX(ID) 조회 -> INSERT Menu -> 확인
```

### 4단계: MemberAuth 권한 부여 (MCP)
```sql
-- SET NAMES utf8 -> INSERT MemberAuth -> 확인
```

### 5단계: 빌드 및 테스트
- dotnet build -> REST API 폼 열기 -> 스크린샷 확인 -> 로그 분석

---

## MDI공통 주요 설정

```csharp
base.titleName = "폼 제목";         // 타이틀바 (기본: 클래스명)
base.minHeight = 400;               // 최소 높이
base.defaultWidth = "800";          // 기본 너비 (픽셀 또는 "%")
base.isRealDataReceive = true;      // 실시간 데이터 수신
base.isPositionSave = true;         // 위치 저장
base.isDuplicate = false;           // 중복 실행 방지
base.isSDI = true;                  // SDI 모드
```

## 주의사항

- base.ID 필수 (Menu.ID와 동일, 없으면 메뉴 시스템 오류)
- isFirstShownLoaded 패턴 필수 (중복 실행 방지)
- Panel본문: MDI공통에서 자동 생성, Controls.Add로 접근
- DB 연결: GetOpenConnection 사용 (GetConnection 금지)
- 로깅: Log4.Debug2 사용 (Log4.Debug는 파일 미기록)

## 체크리스트

- [ ] 폰트/색상 표준 적용
- [ ] 레이아웃 패턴 선택 + Anchor/Dock
- [ ] DataGridView 스타일링
- [ ] 폼 생명주기 (isFirstShownLoaded)
- [ ] Lambda 클로저 회피
- [ ] 스레드 안전성 (Invoke/async-await)
- [ ] 리소스 해제 (Dispose)
- [ ] MDI 5단계 완료 (해당 시)
- [ ] Menu + MemberAuth 등록 (해당 시)
- [ ] 빌드/REST API/스크린샷/로그 테스트
