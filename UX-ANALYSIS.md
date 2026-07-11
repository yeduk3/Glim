# Glim UX 개선 분석 보고서

> 2026-07-10 · 기준 코드: `main` @ e3d600a (v1.2.3)
> 분석 순서: ① 현재 코드 → 동작 구조 파악 ② 기능별 사용자 플로우 도출 ③ 성공한 네이티브 에디터·최근 주목받는 앱과 비교 ④ 개선점 우선순위화

---

## 1. 현재 구조 (코드 기준 사실)

| 층 | 구현 | 파일 |
|---|---|---|
| 문서 | `DocumentGroup` + `FileDocument`(순수 `String`) — Open Recent·⌘S·autosave·proxy icon은 시스템 제공 | `MarkdownDocument.swift`, `GlimApp.swift` |
| View 모드 | WKWebView + markdown-it(`html,linkify,typographer`) + KaTeX(texmath) + highlight.js. `data-source-line` 태깅, innerHTML 전체 교체 렌더 | `MarkdownWebView.swift`, `render.js` |
| Edit 모드 | 순수 `NSTextView`(SF Mono 13pt, soft wrap, 720pt measure 중앙정렬, 자동교정 전부 off) + 라인 기반 린터 6종 | `MarkdownEditor.swift`, `MarkdownLinter.swift` |
| 모드 전환 | ⌘E — `switch`로 뷰 **완전 교체** (동시 존재 없음). top-line 기반 ScrollSync + 캐럿 복원(EditCursorStore) | `ContentView.swift`, `AppState.swift` |
| 이미지 | 렌더 시마다 정규식으로 `![]()` 스캔 → 동기 파일 read → base64 data URI 치환 | `MarkdownWebView.swift:102` |
| 링크 | 클릭을 JS가 가로채 native 라우팅: http/mailto→시스템, 상대경로 `.md`→같은 창 탭, 그 외 파일→기본 앱 | `render.js:181`, `MarkdownWebView.swift:221` |
| 사이드바 | 부모 폴더 트리(FSEvents 감시), single-click open, Return 리네임, Trash, 새 파일 | `SidebarView.swift`, `DirectoryWatcher.swift` |
| 탭 모델 | 같은 폴더 = 네이티브 탭(`tabbingIdentifier`=root), 다른 폴더 = 새 창 | `ContentView.swift` (WindowAccessor) |
| 검색 | ⌘F 자체 FindBar(쿼리·case·next/prev·카운트), ⌘O 파일명 fuzzy 팔레트(계층 랭킹, 5000개 캡) | `FindBar.swift`, `QuickOpen.swift` |
| 외부 변경 | 무편집 시 자동 리로드, 충돌 시 Reload/Keep Mine 배너 | `AppState.swift` (FileSync) |
| 전역 상태 | FontScale(⌘+/-, persist), FullWidthMode(⇧⌘F, persist), 창 크기 persist. **Settings 창 없음** | `FontScale.swift`, `FullWidthMode.swift` |
| Quick Look | JSC 인프로세스 정적 HTML (KaTeX 사전 전개) | `QuickLook/` |

강점 (유지할 것): 시스템 시맨틱 컬러 일원화(DESIGN.md), 폴더=탭 모델, 외부 변경 자동 병합, IME까지 다듬은 ⌘O 팔레트, 오프라인 KaTeX, QL 확장. 이 골격은 경쟁 앱 대비 이미 "native-first"에 충실함.

## 2. 기능별 사용자 플로우와 코드에서 확인된 마찰점

### Flow A — 읽기 (Finder → View 모드)
열기 → 렌더 → 스크롤/검색 → 링크 따라가기.

| # | 마찰점 | 근거 (코드) |
|---|---|---|
| A1 | **문서 내 목차 링크가 깨짐** — markdown-it이 heading `id`를 생성하지 않아 `[…](#section)` 앵커가 스크롤되지 않음. `render.js:186`는 `#…`를 "JS가 알아서 스크롤"이라며 통과시키지만 대상 id가 없음 | `render.js` (anchor 플러그인 부재) |
| A2 | **아웃라인/TOC 패널 없음** — 긴 문서에서 이동 수단이 스크롤과 ⌘F뿐 | ContentView 구조 |
| A3 | 체크박스가 렌더 전용 — View에서 클릭해 소스에 반영하는 토글 없음 | `style.css:112` (렌더만) |
| A4 | 코드블록 복사 버튼 없음 | `render.js` highlight 경로 |
| A5 | 이미지: 클릭 확대 없음, 로드 실패 시 침묵, HTML `<img src>`는 base64 치환 대상에서 제외 → 로컬 이미지 안 보임 | `embedLocalImages` 정규식이 `![]()`만 매칭 |
| A6 | 렌더마다 모든 로컬 이미지를 **메인 스레드에서 동기 재인코딩** — 이미지 많은 문서는 ⌘E 복귀·외부 리로드마다 비용 지불, 캐시 없음 | `MarkdownWebView.swift:95,102` |
| A7 | 링크 hover 시 대상 표시 없음(상태 표시), ⌘클릭 등 보조 동작 없음 | `render.js:181` |
| A8 | mermaid·footnote·highlight(`==`) 등 확장 문법 미지원 | `render.js` 플러그인 구성 |

### Flow B — 편집 (⌘E → Edit 모드)
현재 Edit는 "자동교정 끈 TextEdit + 밑줄 린터". 마크다운을 아는 동작이 전무:

| # | 마찰점 | 근거 |
|---|---|---|
| B1 | **소스 신택스 하이라이팅 없음** — 헤딩/볼드/코드/링크가 본문과 동일하게 보임 | `RawTextView` 순수 NSTextView |
| B2 | **리스트 자동 연속 없음** — `- ` 항목에서 Enter 쳐도 다음 마커가 안 생김. Tab/⇧Tab 들여쓰기도 없음 | delegate에 키 처리 없음 |
| B3 | **포맷 단축키 없음** — ⌘B/⌘I/⌘K(링크) 등. ⌘E가 모드 토글에 배정된 것 외 편집 명령 0개 | `GlimApp.swift` commands |
| B4 | **이미지 붙여넣기/드래그 불가** — 스크린샷 ⌘V 워크플로 전무. 이미지 삽입 수단이 손타이핑뿐 | NSTextView 기본 동작만 |
| B5 | URL 붙여넣기 → 선택 텍스트 링크화 없음 | 〃 |
| B6 | **Find & Replace 없음** — FindBar에 replace 필드 자체가 없음 | `FindBar.swift`, `FindController` |
| B7 | 모드 전환 시 undo 스택 유실 — ⌘E마다 NSTextView 재생성 | `ContentView.swift:180` switch |
| B8 | 단어 수/읽기 시간 없음 (선택 글자 수만 있음) | `SelectionCountBar` |
| B9 | 린트 필 클릭 → 해당 라인 점프 없음 (표시 전용) | `LintBar` |

### Flow C — 탐색·전환
- C1: **폴더 내 전문(full-text) 검색 없음** — ⌘O는 파일명/경로만 (`QuickOpen.gather`).
- C2: `.md` 링크를 따라가면 탭이 계속 쌓임 — back/forward 히스토리 없음.
- C3: FolderBrowser 창(폴더 열기)은 detail이 영구 placeholder — 선택 즉시 별도 창으로 나가 브라우징 흐름 단절.

### Flow D — 산출·공유
- D1: **내보내기 전무** — PDF/HTML export 없음, print CSS 없음, Share 메뉴 없음. "읽기 좋게 렌더한 결과"를 앱 밖으로 내보낼 통로가 Quick Look 스크린샷뿐.

### Flow E — 개인화
- E1: **Settings 창 없음** — 시작 모드(View/Edit), 에디터 폰트/크기, 본문 measure 값, 린터 on/off, 이미지 저장 위치 등 모든 정책이 하드코딩.

## 3. 경쟁·참고 앱 분석

### 3.1 앱별 핵심 시사점

| 앱 | 편집 모델 | Glim에 주는 교훈 |
|---|---|---|
| **Typora** | 단일 창 live WYSIWYG + Source Mode(⌘/) 탈출구 | **이미지 스펙의 기준점**: 붙여넣기/드래그 시 "커스텀 폴더로 복사(`./assets`, `${filename}` 변수), 가능하면 상대경로" + 문서별 YAML 오버라이드. 테이블 그리드 편집·아웃라인 패널(⌃⌘1)·⌘클릭=링크 열기. Electron인데도 편집 모델이 그걸 잊게 만듦. 유료 전환 후 방치 → 이탈 중 |
| **iA Writer** | 소스 전용 + 문법 스타일링(심볼 항상 보임), Preview 별도 | 소스 하이라이팅의 "골드 스탠더드". Quick Search(⇧⌘O) 하나에 파일명+전문검색+아웃라인 통합(v8). 최다 불만 = 인라인 렌더 부재 — "소스 전용" 노선의 상한선을 보여줌 |
| **Bear 2** | 인라인 하이브리드(심볼 자동 숨김) | 이미지 드래그=캐럿 위치 삽입, 코너 핸들 리사이즈. ⌘K 링크, 리스트 자동 연속. 반대급부: DB lock-in·"view source 없음" 불만 — 파일 기반 유지가 Glim의 자산 |
| **Ulysses** | 스타일드 소스(Markdown XL) | ⌘O Quick Open이 "최다 요청 기능"이었음 — Glim은 이미 보유. Typewriter mode의 레퍼런스(⌥⌘T, 고정 위치+현재 문장 하이라이트) |
| **Obsidian** | Source / Live Preview / Reading 3모드 | 붙여넣은 이미지 저장 위치 4옵션(vault/고정 폴더/노트 옆/서브폴더). `[[` 자동완성, hover+⌘ 미리보기. **반면교사**: Electron·비네이티브 컨텍스트 메뉴·Services 부재가 Mac 사용자 최다 불만 — 플러그인 생태계 없이는 용서 안 됨 |
| **Craft / Notion** | 블록 에디터 | 네이티브+미려함은 팔리지만, 블록이 흐르는 글을 방해·export 열화가 최대 불만. plain-md 노선 고수의 근거 |
| **Zed** | 소스+분할 프리뷰 | 사용자가 실제로 원하는 건 픽셀 스크롤 싱크가 아니라 **캐럿 기준 점프**("토글하면 내 캐럿 위치가 보여야") — Glim의 line 기반 ScrollSync는 이미 정답 방향. 프리뷰에 heading anchor·footnote 추가 중 |
| **NotePlan 3 / Paper / MarkEdit / Werner** (최근) | 하이브리드 or 스타일드 소스 | Paper: "설정 창 없음, 전부 메뉴바" — Glim의 현 구조와 동일 노선, 미니멀리즘으로 오히려 호평. MarkEdit: 4MB·NSTextView 계열로 force-touch 사전·Writing Tools까지 지원 — "native 체크리스트"의 현행 기준. Werner: 하이브리드의 난관은 **round-trip 충실도**(저장 시 diff 오염 없음) |
| **Marky / MDviewer** (2026 마이크로 트렌드) | **AI 에이전트 출력물 뷰어** | "AI 코딩 에이전트가 생성한 md를 리뷰"하는 용도의 뷰어 수요 급증. 요청 기능: 파일 변경 시 live reload(**Glim은 FileSync로 이미 구현**), 폴더 브라우징(이미 구현), md-aware git diff, 글자 크기 조절(이미 구현). **Glim의 현재 포지션과 정확히 일치하는, 경쟁 적은 시장** |

### 3.2 "Mac다운 앱" 체크리스트 (Daring Fireball·Brent Simmons 계열 담론 + Obsidian 불만 스레드에서 추출)

1. 메뉴바만으로 전 기능 조작·발견 가능 ✅ (Glim 준수)
2. 키보드 우선 내비게이션 ✅ (⌘⇧E, ⌘O 팔레트, Space 프리뷰)
3. 시스템 외관 즉시 추종(다크·액센트·vibrancy) ✅ (DESIGN.md 체계)
4. **시스템 텍스트 스택 통합** — Services, 사전 force-touch, dictation, Writing Tools: NSTextView라 거의 공짜인데 spell/grammar를 전부 꺼놓음 (`MarkdownEditor.swift:88`) — 산문 작성 시 재고 여지
5. 낮은 입력 지연·즉시 실행 ✅ (native 구조상 우위 — Notion/Obsidian 최다 불만이 이것)
6. OS 훅 — Quick Look ✅ / **Share·Print·Shortcuts ✗**

### 3.3 2026년 미니멀 md 앱의 기대 수준 (리서치 빈도순)

1. 문법 숨김 하이브리드 렌더 + 원소스 탈출구 (수요 최다, 구현 난도 최고)
2. ⌘K 링크 + URL 붙여넣기→선택 텍스트 링크화 (전 앱 공통, 구현 최저가)
3. 이미지 붙여넣기→설정 가능한 폴더에 파일 저장+상대경로 (Typora 스펙이 표준)
4. fuzzy quick open ✅ 보유 — 다음 단계는 전문검색·아웃라인 통합(iA v8 패턴)
5. 스마트 리스트 + 프리뷰에서 체크박스 클릭 토글
6. 클릭 가능한 아웃라인/TOC 패널
7. Focus/Typewriter mode (에디터 포지셔닝일 때 table stakes)
8. ⌘클릭 컨벤션·내부 링크 hover 미리보기
9. plain local .md 신뢰 앵커 ✅ — 신기능도 전부 파일-가시적·상대경로로
10. 캐럿 기준 프리뷰 싱크 ✅ (이미 line 기반)

## 4. 개선 로드맵 (우선순위)

원칙: Glim의 정체성(플레인 .md, 파일 가시성, native-first, 미니멀)은 강점이므로 유지. 개선은 "그 정체성 안에서 기대 수준 미달인 것"부터.

> **구현 현황 (2026-07-11)**: 에디터를 로컬 SPM 패키지 `MarkdownEditorKit`으로 분리(재사용 가능) 후, P0 전체 · P1 전체 · P2 전체 구현 완료 (미커밋). 패키지 unit test 75개 통과. A7은 hover 표시만 구현(⌘클릭 확장은 미착수), P3는 미착수. 미검증 항목: GUI 상호작용 동작들(아래 각 단계 리포트 참조) — 실사용 확인 필요.

### P0 — 결함 수준 (기대 동작이 안 됨)

| 항목 | 내용 | 코드 | 난도 |
|---|---|---|---|
| A1 앵커 수복 | markdown-it-anchor(GitHub 슬러그 규칙) 추가 → `[…](#섹션)` 동작. QL 렌더러에도 동일 적용 | `render.js`, `QuickLook/` | S |
| A5 이미지 커버리지 | HTML `<img src>`도 로컬 경로 해석. 로드 실패 시 placeholder(파일명+아이콘) | `embedLocalImages` | S |
| A6 이미지 성능 | base64 인코딩 결과를 (path, mtime) 키로 캐시, 렌더 스레드 밖으로 | `MarkdownWebView.swift:102` | S–M |
| B7 undo 보존 | 모드 전환에도 document 단위 UndoManager 유지 (탭의 NSDocument undoManager를 NSTextView에 연결) | `RawTextView` | M |

### P1 — 최소 기대치 (경쟁 전 앱 공통, 없으면 "에디터"라 부르기 어려움)

| 항목 | 내용 | 코드 | 난도 |
|---|---|---|---|
| B2 스마트 리스트 | Enter→마커 연속(`-`, `1.`, `- [ ]`; 빈 항목이면 마커 제거), Tab/⇧Tab 들여쓰기 | `RawTextView` delegate `insertNewline`/`insertTab` 처리 | M |
| B3+B5 링크 단축키 | ⌘K = 선택→`[sel](캐럿)`; 선택 위 URL 붙여넣기→`[sel](url)`; ⌘B/⌘I 토글 | Edit 메뉴 CommandGroup + textView 액션 | S–M |
| B4 이미지 붙여넣기 | ⌘V/드래그 이미지 → `assets/`(문서 옆, 이름 규칙 `이름-YYYYMMDD-n.png`)에 저장 + 상대경로 `![]()` 삽입. Typora처럼 "가능하면 상대경로" 원칙 | `RawTextView` `paste:`/`performDragOperation` | M |
| B6 Find & Replace | FindBar에 replace 필드·Replace/All 버튼 (edit 모드 한정, view는 기존 유지) | `FindBar.swift`, `FindController` | M |
| A3 체크박스 토글 | View에서 체크박스 클릭 → `data-source-line` 기반으로 소스의 `[ ]`↔`[x]` 치환 후 저장. "뷰어인데 상호작용" — Glim 시그니처 후보 | `render.js` + 새 message handler | M |
| B9+B8 소품 | 린트 필 클릭→라인 점프, 상태 readout에 단어 수 추가 | `LintBar`, `SelectionCountBar` | S |

### P2 — 차별화 (읽기 도구로서의 완성)

| 항목 | 내용 | 난도 |
|---|---|---|
| A2 아웃라인 패널 | 헤딩 TOC — 사이드바 하단 섹션 or ⌃⌘1 토글 패널, 클릭=점프, 현재 위치 하이라이트. "AI 에이전트 산출물 리뷰" 유스케이스의 핵심 | M |
| B1 소스 하이라이팅 | iA 노선(심볼 유지+스타일링): 헤딩 크기/볼드, `**`·`` ` ``·링크 tint. 하이브리드(심볼 숨김)는 round-trip 위험 대비 수익 낮음 — **비추천, 스타일드 소스까지만** | M–L |
| A4 코드블록 copy 버튼 | hover 시 우상단 버튼, `navigator.clipboard` → native로 위임 | S |
| D1 Export | ⌘P print CSS(측정폭 해제·페이지 나눔) + PDF export + Share 메뉴. WKWebView `createPDF` 사용 | M |
| C1 전문검색 | ⌘O 팔레트에 내용 검색 티어 추가(파일명 매치 우선, 내용 매치 후순위 — iA v8 통합 패턴). ⌘⇧F 별도 UI보다 팔레트 확장이 Glim답다 | M |
| A7 링크 hover | 상태 오버레이(하단 좌측, Safari식)로 대상 표시; ⌘클릭=새 탭 | S |

### P3 — 포지셔닝 베팅 (선택)

- **AI 에이전트 뷰어 강화**: live reload ✅·폴더 탭 ✅ 위에 **md-aware git diff 뷰**(변경 블록 하이라이트) 추가 시 Marky/MDviewer 수요를 정면으로 흡수. 경쟁 얇음, Glim 구조(FileSync+data-source-line)와 궁합 좋음.
- Focus/Typewriter mode: "에디터" 포지셔닝 강화 시에만. 뷰어 포지셔닝이면 스킵.
- mermaid: 수요 있으나 번들 무게(수 MB) 대 미니멀리즘 트레이드오프 — footnote 플러그인(경량)만 먼저.
- Settings 창: **만들지 않는 것을 유지** — Paper처럼 "옵션은 전부 메뉴바" 노선이 정체성에 맞음. 단 이미지 저장 폴더 규칙 정도는 메뉴 or 문서별 front-matter로.

### 비추천 (조사 결과 함정으로 확인)

- Typora식 완전 WYSIWYG 전환: round-trip 충실도가 최대 난관(Werner 사례), Glim의 2-모드+위치 싱크가 이미 Zed 사용자들이 요구하는 형태.
- 블록 에디터화, 자체 라이브러리/DB, 구독화: 각각 Craft·Bear·Ulysses의 최다 불만 재생산.

---

## 요약

Glim은 "native 골격"(색·타이포·메뉴바·키보드·QL·파일 감시)은 이미 상위권이나, **에디터가 마크다운을 모르고**(B1–B9) **이미지 워크플로가 없으며**(B4, A5–A6) **문서 내 앵커가 깨져 있고**(A1) **출구(export)가 없다**(D1). 2026년 기대 수준에서 가장 싸고 효과 큰 순서는 P0(결함 수복) → P1(⌘K·스마트 리스트·이미지 붙여넣기·Replace·체크박스 토글) → P2(아웃라인·스타일드 소스·export). 하이브리드 WYSIWYG는 비용 대비 비추천, 대신 "AI 에이전트 md 리뷰 뷰어"라는 빈 시장이 현 구조와 정확히 맞물린다.

