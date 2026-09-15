# 외부 스킬 출처 및 라이선스 고지

> 본 ogrill 스킬은 두 개의 외부 MIT 라이선스 스킬에서 영감을 받아 한국어 환경에 맞춰 재설계되었다. 본 문서는 출처 표기 의무를 다하기 위한 라이선스 고지다.

---

## 영감 받은 외부 스킬 (MIT 라이선스)

### 1. deep-interview (devbrother2024)

- **저장소**: https://github.com/devbrother2024/skills
- **라이선스**: MIT
- **차용 범위**:
  - 4행 질문 템플릿 (현재 이해 / 막힌 결정 / 추천 답안 / 질문)
  - 5축 종료 기준 (목표 / 범위 / 제약 / 완료 기준 / 열린 질문)
  - "한 번에 하나씩" 직렬 질문 원칙
  - "코드로 답할 수 있는 건 묻지 마" 원칙

### 2. grill-me (mattpocock)

- **저장소**: https://github.com/mattpocock/skills
- **라이선스**: MIT
- **차용 범위**:
  - "결정 트리 분기" 컨셉 (요구사항을 트리로 명확화하는 사고 모델)
  - 단, 질문 폭격(16~50개 동시 제시) 패턴은 채택하지 않고 우리 환경에 맞춰 직렬화

---

## MIT 라이선스 전문

> 두 저장소 모두 표준 MIT 라이선스를 적용하므로 동일 텍스트로 표기한다. 원저자 저작권은 각 저장소의 LICENSE 파일에 명시되어 있다.

```
MIT License

Copyright (c) devbrother2024 (deep-interview)
Copyright (c) mattpocock (grill-me)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 본 스킬의 위치

본 ogrill 스킬은 위 두 출처에서 영감을 받았으나, 다음과 같이 한국어 환경 + 우리 o시리즈 파이프라인에 통합 재설계된 **새로운 작품**이다.

| 차이점 | deep-interview / grill-me | ogrill (본 스킬) |
|--------|---------------------------|-----------------|
| 언어 | 영어 | 한국어 (모든 본문/예시) |
| 호출 위치 | 독립 실행 | ointaug → ogrill → oplan 파이프라인 통합 |
| 질문 도구 | 자유 양식 | AskUserQuestion 도구 1회 1질문 규약 |
| 종료 기준 | deep-interview 5축만 | deep-interview 5축 + grill-me 결정트리 매핑 |
| 자동 호출 | 수동 | UserPromptSubmit hook의 권장 메시지(자동 호출은 LLM 의지에 의존, 강제 X) |

본 ogrill 스킬은 **본 프로젝트의 라이선스를 따른다**.
