---
name: oskill_livecharts2
description: "LiveCharts2 차트 구현 스킬. oplan에서 차트 설계, odev에서 구현 참조, otest에서 시각적 검증. Auto-activates when: adding charts, real-time monitoring, data visualization, LineSeries, ColumnSeries, PieSeries, dynamic data updates. 차트 추가, 실시간 모니터링, 데이터 시각화 구현 시 자동 활성화. (project)"
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev(차트 감지)]
  calls: []
---

# oskill_livecharts2 — LiveCharts2 차트 구현

LiveCharts2 라이브러리(v2.0.0-rc6.1)를 활용한 차트 추가/수정 스킬.

## 파이프라인 통합

```yaml
oplan:
  - 차트 요구사항 발견 시 이 스킬 자동 로딩
  - 차트 타입 선정 (Line/Column/Pie), 데이터 소스, 업데이트 주기 계획
  - TODO에 "oskill_livecharts2 참조" 명시

odev:
  - 이 스킬의 기본 구조 4단계 + 코드 템플릿 참조하여 구현
  - 기존 구현(CPU/RAM/GPU 모니터링) 패턴 재사용
  - 에이전트 프롬프트에 "oskill_livecharts2 스킬 참조" 포함

otest:
  - 차트 렌더링 확인: 스크린샷 촬영 → 시각적 검증
  - 데이터 업데이트 확인: REST API 또는 Timer 동작 검증
  - 메모리 누수 확인: FormClosed에서 정리 확인
```

## 참고 문서

- **공식 사이트**: https://livecharts.dev
- **기존 구현**: CPU모니터링.cs, RAM모니터링.cs, GPU모니터링.cs

## 사용 시점

- 실시간 모니터링 차트 구현 (CPU, 메모리, 네트워크 등)
- 데이터 시각화 (프로젝트 통계, 매출 분석, 성과 추이)
- LineSeries, ColumnSeries, PieSeries 등 차트 추가/수정
- 동적 데이터 업데이트 (Sliding Window 패턴)

## 필수 NuGet 패키지

```xml
<PackageReference Include="LiveChartsCore.SkiaSharpView.WinForms" Version="2.0.0-rc6.1" />
```

## 기본 구조 (4단계)

### 1단계: 데이터 컬렉션 정의
```csharp
using LiveChartsCore;
using LiveChartsCore.SkiaSharpView;
using LiveChartsCore.SkiaSharpView.Painting;
using SkiaSharp;
using System.Collections.ObjectModel;

// ObservableCollection 사용 (자동 UI 업데이트)
public ObservableCollection<double> CpuValues { get; set; } = new();
```

### 2단계: Series 구성
```csharp
new LineSeries<double>
{
    Values = CpuValues, Name = "CPU 사용률",
    Stroke = new SolidColorPaint(SKColors.Red) { StrokeThickness = 2 },
    Fill = null, LineSmoothness = 0.8, GeometrySize = 0,
    AnimationsSpeed = TimeSpan.FromMilliseconds(0)
}
```

### 3단계: Axis 설정
```csharp
new Axis { MinLimit = 0, MaxLimit = 60, Labeler = v => $"{(int)v}초" }
new Axis { MinLimit = 0, MaxLimit = 100, Labeler = v => $"{(int)v}%" }
```

### 4단계: 실시간 업데이트 (Sliding Window)
```csharp
CpuValues.RemoveAt(0);
CpuValues.Add(newCpuValue);
// ObservableCollection → 자동 UI 업데이트
```

## 차트 타입별 예시

- **LineSeries**: Stroke, Fill=null, LineSmoothness=0.8
- **ColumnSeries**: Fill, Stroke, MaxBarWidth
- **PieSeries**: DataLabelsPosition=Middle

## 한글 폰트 설정

```csharp
LabelsPaint = new SolidColorPaint
{
    Color = SKColors.Black,
    SKTypeface = SKTypeface.FromFamilyName("맑은 고딕")
}
```

## 성능 최적화 (필수)

```csharp
AnimationsSpeed = TimeSpan.FromMilliseconds(0)  // 애니메이션 비활성화
GeometrySize = 0                                 // 점 숨김
Fill = null                                       // 배경 제거
StrokeThickness = 1                               // 최소화
LineSmoothness = 0.8                              // 부드러운 곡선
// Sliding Window: 60~120개 데이터 제한
```

## 주의사항

- Thread Safety: InvokeRequired + Invoke 사용
- ObservableCollection 필수 (List 금지)
- Timer: FormClosing에서 Stop() + Dispose()
- 메모리: FormClosed에서 Clear()

## 체크리스트

- [ ] ObservableCollection 사용
- [ ] 성능 최적화 (AnimationsSpeed=0, GeometrySize=0, Fill=null)
- [ ] Axis MinLimit/MaxLimit 설정
- [ ] 한글 폰트 (SKTypeface)
- [ ] Timer Dispose
- [ ] Sliding Window
- [ ] Thread Safety (Invoke)
