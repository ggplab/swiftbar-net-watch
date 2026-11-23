# CLAUDE.md

유형: 상시
설명: 맥 메뉴바에 네트워크 지연과 손실을 띄우고 끊기면 알리는 SwiftBar 플러그인(공개 오픈소스)

## 규칙
- 공개 레포다. 개인 경로, 사내 호스트, 공유기 주소 같은 개인 환경 값을 커밋하지 않는다. 개인 설정은 `~/.config/net-watch/config`에 둔다.
- 플러그인은 `net-watch.30s.sh` 한 파일로 유지한다. macOS 기본 명령(`ping`, `curl`, `route`, `od`, `open`)만 쓴다. 설치할 의존성을 늘리지 않는다.
- 사용자 설정 항목을 더하면 `config.example`과 README의 설정 표를 함께 고친다.
- README는 한국어로 쓰고, 고친 뒤 문체 지표를 잰다.

## 시험
고친 뒤 아래를 돌려 판정 경로를 확인한다. 상세는 `ARCHITECTURE.md` "시험".

```bash
bash -n net-watch.30s.sh && NET_WATCH_NO_NOTIFY=1 bash net-watch.30s.sh
```
