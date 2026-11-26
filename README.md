# Femto Gain Controller Rev.2 — EPICS IOC (`femtogain`)

ODROID-C5 위에서 FEMTO DLPCA-200 전류 증폭기 4대의 게인(채널당 3비트)을 설정하고
Overload(채널당 1비트)를 읽는 IOC입니다. Signal Distributor(`sigdist`)의 구조를 그대로 가져왔고
`devGpio.c`는 sigdist와 바이트 단위로 같습니다. PV 이름은 Rev.1(`FEMTO` IOC)을 따르되, 게인 레코드만 `<S>GainValue` → `<S>Gain`으로 바꿨습니다(2026-11-26).

```
/usr/local/epics/
├── base -> base-7.0.10             EPICS Base 7.0.10 (linux-aarch64)
├── support/autosave/               autosave R5-11
└── iocs/femtogain/                 이 IOC  (~/femtogain 바로가기)
    ├── femtogainApp/src/devGpio.c          libgpiod 기반 bo/bi 디바이스 서포트 (sigdist와 동일)
    ├── femtogainApp/Db/femtogainCh.template 채널 1개 분량 레코드 (4번 로드)
    ├── femtogainApp/Db/femtogain.db         Info 레코드
    ├── iocBoot/iocfemtogain/
    │   ├── ioc.conf                ★ PREFIX, 채널 이름, GPIO 라인, 공장 기본값
    │   ├── web.conf                웹 포트/계정 (root 600)
    │   ├── st.cmd, start_ioc.sh    IOC 시작
    │   ├── autosave/               (사용 안 함, autosave 제거)
    │   └── femtogain-*.service     systemd 유닛 원본
    └── tools/
        ├── femtogainctl            ★ 관리 CLI (/usr/local/bin/femtogainctl)
        ├── femtogain-web.py/.html  웹 UI (python3 표준 라이브러리, 포트 8080)
        ├── femtogain-gpio-init.sh  게인 선 = 입력+풀다운, OVL 선 = 입력+풀업
        ├── femtogain-reset-button.py / femtogain-factory-reset.sh   리셋 점퍼
        ├── femtogain-motd.sh       로그인 배너
        └── install.sh              유닛·링크·권한 등록
```
`/opt/epics/base`는 `/usr/local/epics/base`를 가리키는 링크입니다(Base 라이브러리의 RUNPATH용). 지우지 마세요.

## GPIO (40핀 헤더, gpiochip0)

| 신호 | 핀 | 라인 | | 신호 | 핀 | 라인 |
|---|---|---|---|---|---|---|
| C1_G0 | 7 | 28 | | C3_G0 | 18 | 31 |
| C1_G1 | 11 | 53 | | C3_G1 | 19 | 56 |
| C1_G2 | 12 | 54 | | C3_G2 | 21 | 57 |
| C2_G0 | 13 | 63 | | C4_G0 | 22 | 62 |
| C2_G1 | 15 | 52 | | C4_G1 | 23 | 59 |
| C2_G2 | 16 | 30 | | C4_G2 | 24 | 58 |
| OVL1 | 26 | 55 | | OVL3 | 31 | 41 |
| OVL2 | 29 | 40 | | OVL4 | 32 | 50 |
| RESET | 36 (↔ GND 34) | 51 | | | | |

라인 번호 = 커널이 붙인 `PIN_n` 이름의 gpio 번호 − 428 (`cat /sys/kernel/debug/gpio`).
핀 19/21/23/24는 기본 이미지에서 SPI로 잡혀 있으므로 `/boot/config.ini`의 `overlays`에서 `spi0`를 뺐습니다.

## PV (`<P>` = PREFIX, 기본 `GC01:` · `<S>` = 채널 이름 Io/It/If/Ir)

| PV | 타입 | 설명 |
|---|---|---|
| `<P><S>Gain` | mbbo | 게인 선택 0–6 = `E3`…`E9` (문자열은 Rev.1과 같고, 이름은 Rev.1의 `<S>GainValue`에서 변경). 저장하지 않음(IOC 시작 시 항상 E3). 7과 범위 밖 값은 핀에 나가지 않고 직전 값으로 되돌아감 |
| `<P><S>Gain-RB` | mbbi | G0–G2 핀에서 합성한 코드 |
| `<P><S>GainFactor-RB` | calc | 게인 숫자 값 V/A (저잡음 모드 기준, 코드 7이면 0) |
| `<P><S>Overload` | bi | Normal / Overload (Rev.1 이름). 0.1 s 폴링, 핀 LOW = Overload |
| `<P><S>OverloadLatch` | bi | 한 번 발생하면 해제 전까지 유지 |
| `<P><S>OverloadReset` | bo | 1을 쓰면 래치와 횟수 해제 |
| `<P><S>OverloadCount` | longout | 해제 이후 과부하 발생 횟수 |
| `<P><S>GainMismatch` | bi | OK / Mismatch: 설정한 코드와 핀의 코드가 다름 |
| `<P>OverloadAny`, `OverloadLatchAny` | bi | 4채널 중 하나라도 과부하 / 래치 |
| `<P>OverloadResetAll` | bo | 1을 쓰면 4채널 래치 일괄 해제 |
| `<P><S>G0`, `G1`, `G2` | bo | 비트 raw 출력 (디버그) |
| `<P><S>G0-RB`, `G1-RB`, `G2-RB` | bi | 핀 readback |
| `<P>Info:Prefix`, `Model`, `GpioChip`, `Heartbeat` | | 정보 / 1 Hz 카운터 |

이 IOC는 증폭기가 저잡음 모드(L)라고 가정합니다. 고속 모드로 쓰면 실제 게인은 표시값의 100배입니다.

## 안전 동작

- 게인 변경은 한 번의 처리 안에서 "내려갈 비트 먼저 LOW → 올라갈 비트 HIGH" 순서로 씁니다. 중간 코드는 이전 코드나 새 코드의 부분집합이므로 7을 거치지 않습니다.
- raw 비트를 직접 써서 세 비트가 모두 HIGH가 되면 약 20 ms 뒤 마지막 유효 코드로 되돌립니다.
- `femtogain-gpio-init.sh`가 부팅 초기, IOC 시작 전, IOC 정지 후에 게인 선을 입력+내부 풀다운으로 둡니다.
  이 커널은 프로세스가 선을 놓아도 출력 상태를 유지하므로, 이 스크립트가 없으면 IOC 정지 후에도 마지막 게인이 남습니다.
- ODROID-C5는 전원 투입 직후 핀 11, 13, 15, 19, 21, 22, 23, 24에 SoC 내부 풀업이 켜져 있습니다.
  위 스크립트가 돌기 전 몇 초는 소프트웨어로 막을 수 없습니다(보드 풀다운 저항값으로 해결).

## 운영

```bash
femtogainctl status            # 서비스 + 채널별 게인/readback/Overload/래치
femtogainctl gain 2 1e6        # 채널 2를 1e6 V/A로 (코드 3, E6, It 같은 이름도 가능)
femtogainctl ovl reset         # Overload 래치 전체 해제
femtogainctl test              # 자가 시험 (실제 게인이 바뀜, 끝나면 복원)
femtogainctl setup             # 호스트명 → PREFIX → 비밀번호 → IP
femtogainctl console | log | restart | pvs | autosave | web | help
```

- 게인은 저장하지 않는다(autosave 제거, 2026-11-26). IOC가 시작할 때마다 전 채널이 `DEFAULT_GAIN`(기본 0 = E3)으로 시작한다. 전원 재투입, 재부팅, 서비스 재시작, IOC 이상 종료 후 자동 재기동 모두 해당합니다.
- 웹 UI: `http://<IP>:8080/`, 로그인은 SSH와 같은 계정·비밀번호. 공장 초기화는 웹과 CLI에 없습니다.
- 공장 초기화: 헤더 핀 36을 GND(핀 34)에 5초 이상 연결 → ODROID 파란 LED가 5회 깜박인 뒤
  비밀번호와 네트워크가 `ioc.conf`의 `DEFAULT_*` 값으로 바뀝니다. 기록: `/var/log/femtogain/reset.log`.
- 복제: `femtogainctl clone-prep && poweroff` → eMMC 복제 → 각 장비에서 `femtogainctl setup` → `femtogainctl test`.
  - `femtogainctl clone-prep --dry-run`은 아무것도 바꾸지 않고 할 일과 지울 파일 목록만 보여 줍니다.
  - `clone-prep`은 `/boot/config.ini`에서 `spi0` 오버레이가 빠져 있는지 확인하고, 홈 디렉터리의 개발 작업 파일(소스, 백업, 문서, 작업 기록)을 지울지 따로 묻습니다(기본값은 유지).
- 채널 이름(CH1–CH4, 기본 `Io It If Ir`)은 `femtogainctl chname`이나 웹 UI의 "장비 설정"에서 바꿉니다. 예: `femtogainctl chname 2 If`(한 채널), `femtogainctl chname Io If It Ir`(네 채널 한 번에, 이름을 서로 바꿀 때). PV 이름이 `<PREFIX><이름>Gain`으로 바뀌고 IOC가 재시작되어 전 채널이 E3로 돌아갑니다.
- 게인을 바꾼 직후 0.5초(`ioc.conf`의 `OVL_BLANK`) 동안은 `<S>OverloadLatch`와 `<S>OverloadCount`가 Overload 입력을 무시합니다. 증폭기가 최고 게인으로 들어가거나 나올 때 0.1–0.25초 동안 Overload를 내기 때문입니다. `<S>Overload` 자체는 가리지 않습니다.
- `tools/install.sh`는 `tools/femtogain-boot-overlay.sh`로 `/boot/config.ini`의 `spi0` 오버레이를 뺍니다. `spi0`가 핀 19/21/23/24(C3_G1, C3_G2, C4_G1, C4_G2)를 잡기 때문이며, 설치 후 재부팅해야 적용됩니다. 부트 파티션이 `/boot`에 마운트되어 있지 않으면 수정하지 않고 오류를 냅니다.

## 빌드 (처음부터)

```bash
apt install build-essential libreadline-dev libgpiod-dev gpiod procserv telnet python3-yaml
make -C /usr/local/epics/base -j4
make -C /usr/local/epics/support/autosave
make -C /usr/local/epics/iocs/femtogain
/usr/local/epics/iocs/femtogain/tools/install.sh
```

## MEDM 화면

`femtogainApp/op/adl/femtogain_4CH.adl` — Rev.1의 `FEMTO_5CH.adl`을 바탕으로 만든 4채널 화면입니다.
채널 이름을 바꿀 수 있으므로 매크로로 넘깁니다(`ioc.conf`의 `PREFIX`, `CH1_NAME`–`CH4_NAME`과 같은 값).

    medm -x -macro "P=GC01:,CH1=Io,CH2=If,CH3=It,CH4=Ir" femtogain_4CH.adl

채널마다 Overload 상태, 래치, 횟수, 게인 선택, 게인 읽기값, 불일치 표시, 래치 리셋 버튼이 있고 아래에 전체 리셋 버튼이 있습니다.
