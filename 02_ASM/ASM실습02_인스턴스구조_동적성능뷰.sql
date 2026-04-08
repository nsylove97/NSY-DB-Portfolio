/*
================================================================================
 ASM 실습 02: 인스턴스 구조 & 동적 성능 뷰
================================================================================
 블로그: https://nsylove97.tistory.com/40
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome

 목차
   1. ASM 인스턴스 구조
      1-1. ASM 백그라운드 프로세스 확인
   2. ASM 권한 종류
      2-1. SYSASM / SYSDBA 접속
   3. 시작·종료 순서
      3-1. crsctl — CRS 데몬 레벨 제어
      3-2. srvctl — 서비스 단위 제어
   4. 동적 성능 뷰 실습
      4-1. v$asm_diskgroup — 디스크 그룹 상태 및 용량 확인
      4-2. v$asm_disk      — 개별 디스크 상태 및 경로 확인
      4-3. v$asm_file      — ASM 파일 목록 확인
   5. ASMCMD 실습
      5-1. lsdg  — 디스크 그룹 상세 조회
      5-2. lsdsk — 개별 디스크 조회
      5-3. du    — 사용 중인 공간 확인
      5-4. ls    — ASM 파일 목록 확인
   6. 스트라이핑 & 미러링 & Failure Group
================================================================================
*/


/* ============================================================================
   1. ASM 인스턴스 구조
   ============================================================================
   - ASM(Automatic Storage Management)
     OS 파일 시스템 대신 오라클이 직접 제공하는 전용 스토리지 계층

   - 데이터 접근 흐름
     · 일반 DB : SQL → DB 인스턴스 → OS 파일 시스템 → 디스크
     · ASM 사용 : SQL → DB 인스턴스 → ASM(위치 조회) → 디스크 직접 읽기
     → 파일을 실제로 읽는 것은 DB 인스턴스, 파일의 위치(메타데이터)만 ASM이 관리

   - SGA / PGA
     · SGA : O (메타데이터·파일 관리에 필요)
     · PGA : X (SQL 처리·사용자 세션 없음 → PGA 불필요)

   - 백그라운드 프로세스
     RBAL    : 디스크 파악 및 리밸런스 작업 지시
     ARBn    : 실제 데이터 이동 수행 (n: 병렬 슬롯 번호)
     GMON    : 디스크 상태 지속 체크
     MARK    : 오래된·오프라인 Extent 정리
     Onnn / PZ9n : RAC 환경에서 인스턴스 간 데이터 조회 시 사용
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. ASM 백그라운드 프로세스 확인
   --------------------------------------------------------------------------
   ※ SQL*Plus가 아닌 OS 터미널(MobaXterm)에서 실행
   -------------------------------------------------------------------------- */

-- [grid 계정 — 터미널]
-- ASM 백그라운드 프로세스 조회
-- ps -ef | grep -E "rbal|arbn|gmon|mark|onnn|pz9n" | grep -v grep

/*
 [결과]
   grid      4201     1  0 17:00 ?  00:00:00 asm_rbal_+ASM
   grid      4203     1  0 17:00 ?  00:00:00 asm_arb0_+ASM
   grid      4205     1  0 17:00 ?  00:00:00 asm_gmon_+ASM
   grid      4207     1  0 17:00 ?  00:00:00 asm_mark_+ASM
   → RBAL / ARBn / GMON / MARK 프로세스가 +ASM 인스턴스에 소속되어 실행 중
*/


/* ============================================================================
   2. ASM 권한 종류
   ============================================================================
   SYSASM  : ASM 전체 관리 (최고 관리자 권한, 기본)
   SYSDBA  : ASM에 저장된 데이터에 접근 가능
   SYSOPER : ASM 인스턴스의 시작·정지 제한 권한
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. SYSASM / SYSDBA 접속
   -------------------------------------------------------------------------- */

-- [grid 계정] SYSASM으로 ASM 인스턴스 접속
-- sqlplus / AS SYSASM

/*
 [결과]
   Connected to:
   Oracle Database 19c Enterprise Edition Release 19.0.0.0.0
   ASM instance started
*/

-- [oracle 계정] SYSDBA로 접속 (ASM 파일 접근 시)
-- sqlplus / AS SYSDBA

/*
 [결과]
   Connected to:
   Oracle Database 19c Enterprise Edition Release 19.0.0.0.0
   Database opened.
*/


/* ============================================================================
   3. 시작·종료 순서
   ============================================================================
   시작 (STARTUP)  : ASM 인스턴스 먼저 → DB 인스턴스
   종료 (SHUTDOWN) : DB 인스턴스 먼저 → ASM 인스턴스

   → DB 인스턴스가 ASM 위에 올라가는 구조
   → ASM이 먼저 기동되어야 DB가 데이터파일 위치를 조회할 수 있음
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. crsctl — CRS 데몬 레벨 제어
   --------------------------------------------------------------------------
   ※ root 계정에서 실행
   ※ SQL*Plus가 아닌 OS 터미널(MobaXterm)에서 실행
   -------------------------------------------------------------------------- */

-- [root 계정 — 터미널]

-- Grid Infrastructure 전체 스택 종료 (DB → ASM 순서로 자동 처리)
-- crsctl stop has

/*
 [결과]
   CRS-2791: Starting shutdown of Oracle High Availability Services-managed resources on 'oelsvr1'
   CRS-2673: Attempting to stop 'ora.orcl.db' on 'oelsvr1'
   CRS-2677: Stop of 'ora.orcl.db' on 'oelsvr1' succeeded
   CRS-2673: Attempting to stop 'ora.asm' on 'oelsvr1'
   CRS-2677: Stop of 'ora.asm' on 'oelsvr1' succeeded
   CRS-2793: Shutdown of Oracle High Availability Services-managed resources on 'oelsvr1' has completed
   → DB 먼저 종료 후 ASM 종료 순서 확인
*/

-- Grid Infrastructure 전체 스택 시작 (ASM → DB 순서로 자동 처리)
-- crsctl start has

/*
 [결과]
   CRS-4123: Oracle High Availability Services has been started.
   → 백그라운드에서 ASM → DB 순으로 자동 기동됨
*/

-- CRS 전체 리소스 상태 확인
-- crsctl stat res -t

/*
 [결과]
   --------------------------------------------------------------------------------
   Name           Target  State        Server       State details
   --------------------------------------------------------------------------------
   Local Resources
   --------------------------------------------------------------------------------
   ora.DATA.dg    ONLINE  ONLINE       oelsvr1      STABLE
   ora.FRA.dg     ONLINE  ONLINE       oelsvr1      STABLE
   ora.OCR.dg     ONLINE  ONLINE       oelsvr1      STABLE
   ora.REDO.dg    ONLINE  ONLINE       oelsvr1      STABLE
   ora.asm        ONLINE  ONLINE       oelsvr1      Started,STABLE
   ora.orcl.db    ONLINE  ONLINE       oelsvr1      Open,HOME=/u01/app/oracle/product/19.3.0/dbhome,STABLE
   ora.listener.lsnr ONLINE ONLINE     oelsvr1      STABLE
   --------------------------------------------------------------------------------
   → 4개 디스크 그룹 + ASM + DB 모두 ONLINE 확인
*/


/* --------------------------------------------------------------------------
   3-2. srvctl — 서비스 단위 제어
   --------------------------------------------------------------------------
   ※ oracle 계정에서 실행
   ※ SQL*Plus가 아닌 OS 터미널(MobaXterm)에서 실행
   -------------------------------------------------------------------------- */

-- [oracle 계정 — 터미널]

-- ASM 인스턴스 상태 확인
-- srvctl status asm

/*
 [결과]
   ASM is running on oelsvr1
*/

-- DB 인스턴스 상태 확인
-- srvctl status database -d orcl

/*
 [결과]
   Database is running.
*/

-- DB 인스턴스 종료
-- srvctl stop database -d orcl

/*
 [결과]
   (프롬프트로 돌아옴, 오류 없음)
*/

-- DB 인스턴스 상태 재확인
-- srvctl status database -d orcl

/*
 [결과]
   Database is not running.
*/

-- DB 인스턴스 시작
-- srvctl start database -d orcl

/*
 [결과]
   (프롬프트로 돌아옴, 오류 없음)
*/

-- DB 인스턴스 상태 재확인
-- srvctl status database -d orcl

/*
 [결과]
   Database is running.
*/


/* ============================================================================
   4. 동적 성능 뷰 실습
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. v$asm_diskgroup — 디스크 그룹 상태 및 용량 확인
   --------------------------------------------------------------------------
   주요 컬럼
     STATE    : MOUNTED(정상), DISMOUNTED, CONNECTED 등
     TYPE     : EXTERN / NORMAL / HIGH (미러링 방식)
     TOTAL_MB : 디스크 그룹 전체 용량
     FREE_MB  : 사용 가능한 공간
   -------------------------------------------------------------------------- */

-- [grid 계정] SYSASM으로 접속
CONN / AS SYSASM

-- 현재 마운트된 디스크 그룹 목록 확인
SELECT name, state, type, total_mb, free_mb,
       ROUND((1 - free_mb/total_mb) * 100, 1) AS used_pct
FROM   v$asm_diskgroup
ORDER  BY name;

/*
 [결과]
   NAME   STATE    TYPE    TOTAL_MB  FREE_MB  USED_PCT
   -----  -------  ------  --------  -------  --------
   DATA   MOUNTED  NORMAL  40956     38104    6.9
   FRA    MOUNTED  NORMAL  20476     19704    3.8
   OCR    MOUNTED  NORMAL  30714     29898    2.7
   REDO   MOUNTED  NORMAL  20476     19594    4.3
   → 4개 디스크 그룹 모두 MOUNTED 상태 확인
   → DATA: 4개 디스크 × ~10G, FRA/REDO: 2개 × ~10G, OCR: 3개 × ~10G
*/


/* --------------------------------------------------------------------------
   4-2. v$asm_disk — 개별 디스크 상태 및 경로 확인
   -------------------------------------------------------------------------- */

-- ASM에 등록된 개별 디스크 하나하나의 상태 조회
SELECT group_number, disk_number, name, state, path,
       total_mb, free_mb, label
FROM   v$asm_disk
ORDER  BY group_number, disk_number;

/*
 [결과]
   GROUP_NUMBER  DISK_NUMBER  NAME   STATE   PATH                            TOTAL_MB  FREE_MB  LABEL
   ------------  -----------  -----  ------  ------------------------------  --------  -------  -----
   1             0            DATA1  NORMAL  /dev/oracleasm/disks/DATA1      10238     9526     DATA1
   1             1            DATA2  NORMAL  /dev/oracleasm/disks/DATA2      10238     9526     DATA2
   1             2            DATA3  NORMAL  /dev/oracleasm/disks/DATA3      10238     9526     DATA3
   1             3            DATA4  NORMAL  /dev/oracleasm/disks/DATA4      10238     9526     DATA4
   2             0            FRA1   NORMAL  /dev/oracleasm/disks/FRA1       10238     9852     FRA1
   2             1            FRA2   NORMAL  /dev/oracleasm/disks/FRA2       10238     9852     FRA2
   3             0            OCR1   NORMAL  /dev/oracleasm/disks/OCR1       10238     9966     OCR1
   3             1            OCR2   NORMAL  /dev/oracleasm/disks/OCR2       10238     9966     OCR2
   3             2            OCR3   NORMAL  /dev/oracleasm/disks/OCR3       10238     9966     OCR3
   4             0            REDO1  NORMAL  /dev/oracleasm/disks/REDO1      10238     9797     REDO1
   4             1            REDO2  NORMAL  /dev/oracleasm/disks/REDO2      10238     9797     REDO2
   → 11개 디스크 모두 NORMAL 상태
   → GROUP_NUMBER: 1=DATA, 2=FRA, 3=OCR, 4=REDO
*/


/* --------------------------------------------------------------------------
   4-3. v$asm_file — ASM 파일 목록 확인
   --------------------------------------------------------------------------
   - 어떤 파일이 어떤 그룹에 저장되어 있는지 파악
   - v$asm_file은 파일의 논리적 정보(타입, 크기, 중복도) 표시
   - 실제 익스텐트 위치는 내부 익스텐트 맵으로 관리
   -------------------------------------------------------------------------- */

SELECT group_number, file_number, type, bytes, space, redundancy
FROM   v$asm_file
ORDER  BY group_number, file_number
FETCH FIRST 20 ROWS ONLY;

/*
 [결과]
   GROUP_NUMBER  FILE_NUMBER  TYPE           BYTES       SPACE       REDUNDANCY
   ------------  -----------  -------------  ----------  ----------  ----------
   1             256          PARAMETERFILE  2048        4194304     MIRROR
   1             257          DATAFILE       796917760   798490624   MIRROR
   1             258          DATAFILE       734003200   735739904   MIRROR
   1             259          DATAFILE       524288000   525336576   MIRROR
   1             260          DATAFILE       104857600   105906176   MIRROR
   1             261          CONTROLFILE    18874368    19922944    HIGH
   2             256          ONLINELOG      52428800    53477376    MIRROR
   2             257          ONLINELOG      52428800    53477376    MIRROR
   2             258          ONLINELOG      52428800    53477376    MIRROR
   2             259          ARCHIVELOG     315392      1048576     MIRROR
   4             256          ONLINELOG      52428800    53477376    MIRROR
   4             257          ONLINELOG      52428800    53477376    MIRROR
   4             258          ONLINELOG      52428800    53477376    MIRROR
   → +DATA(1): 파라미터파일, 데이터파일, 컨트롤파일 저장 확인
   → +FRA(2): Redo Log 멤버(FRA 측), 아카이브 로그 저장 확인
   → +REDO(4): Redo Log 멤버(REDO 측) 저장 확인
   → 컨트롤파일만 HIGH Redundancy (3중 미러링) 적용됨
*/


/* ============================================================================
   5. ASMCMD 실습
   ============================================================================
   - ASMCMD: ASM 디스크 그룹과 파일을 터미널에서 직접 관리하기 위한 전용 CLI 도구
   - grid 계정 (ORACLE_SID=+ASM) 에서 실행
   ============================================================================ */

/*
 [ASMCMD 접속] — 터미널에서 실행
   $ asmcmd

 [결과]
   ASMCMD>
*/


/* --------------------------------------------------------------------------
   5-1. lsdg — 디스크 그룹 상세 조회
   --------------------------------------------------------------------------
   주요 컬럼
     Rebal          : 리밸런스 진행 중 여부 (N=정상)
     AU             : Allocation Unit 크기 (bytes)
     Req_mir_free_MB: 미러링 복구를 위해 확보해야 할 여유 공간
     Usable_file_MB : 실제로 파일에 사용 가능한 공간
     Voting_files   : RAC Voting Disk 포함 여부
   -------------------------------------------------------------------------- */

/*
   ASMCMD> lsdg

 [결과]
   State    Type    Rebal  Sector  Logical_Sector  Block  AU       Total_MB  Free_MB  Req_mir_free_MB  Usable_file_MB  Offline_disks  Voting_files  Name
   MOUNTED  NORMAL  N      512     512             4096   1048576  40956     38104    10238            13933           0              N             DATA/
   MOUNTED  NORMAL  N      512     512             4096   1048576  20476     19704    10238            4733            0              N             FRA/
   MOUNTED  NORMAL  N      512     512             4096   1048576  30714     29898    10238            9830            0              Y             OCR/
   MOUNTED  NORMAL  N      512     512             4096   1048576  20476     19594    10238            4678            0              N             REDO/
   → 4개 그룹 모두 MOUNTED, Rebal=N (리밸런스 없음)
   → OCR만 Voting_files=Y (RAC Voting Disk 포함)
   → AU=1048576 bytes = 1MB (기본값)
*/


/* --------------------------------------------------------------------------
   5-2. lsdsk — 개별 디스크 조회
   -------------------------------------------------------------------------- */

/*
   ASMCMD> lsdsk

 [결과]
   Path
   /dev/oracleasm/disks/DATA1
   /dev/oracleasm/disks/DATA2
   /dev/oracleasm/disks/DATA3
   /dev/oracleasm/disks/DATA4
   /dev/oracleasm/disks/FRA1
   /dev/oracleasm/disks/FRA2
   /dev/oracleasm/disks/OCR1
   /dev/oracleasm/disks/OCR2
   /dev/oracleasm/disks/OCR3
   /dev/oracleasm/disks/REDO1
   /dev/oracleasm/disks/REDO2
   → 11개 디스크 경로 확인
*/

-- 상세 옵션 (-k): Failure Group 이름 및 디스크 상세 정보 포함

/*
   ASMCMD> lsdsk -k

 [결과]
   Inst_Num  Incarnation  Failgroup  Label  UDID  Product  Redund  Offset  Size         Path
   1         1069574913   DATA_0000  DATA1  ...   ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA1
   1         1069574914   DATA_0001  DATA2  ...   ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA2
   1         1069574915   DATA_0000  DATA3  ...   ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA3
   1         1069574916   DATA_0001  DATA4  ...   ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA4
   ...
   → Failgroup 컬럼으로 Failure Group 구성 확인 가능
   → DATA1, DATA3 → DATA_0000 / DATA2, DATA4 → DATA_0001 로 분리됨
   → NORMAL Redundancy: Failure Group 2개, 디스크 2개씩 배치
*/


/* --------------------------------------------------------------------------
   5-3. du — 사용 중인 공간 확인
   -------------------------------------------------------------------------- */

/*
   ASMCMD> cd +DATA
   ASMCMD> du

 [결과]
   Used_MB  Mirror_used_MB
   1426     2852
   → 실제 데이터 1426MB 사용, 미러링으로 2852MB 소비 (NORMAL: 2배)
*/


/* --------------------------------------------------------------------------
   5-4. ls — ASM 파일 목록 확인
   -------------------------------------------------------------------------- */

/*
   ASMCMD> cd +DATA/ORCL/DATAFILE
   ASMCMD> ls -l

 [결과]
   Type      Redund   Striped   Time             Sys  Name
   DATAFILE  MIRROR   COARSE    MAR 25 17:00:00  Y    SYSAUX.258.1
   DATAFILE  MIRROR   COARSE    MAR 25 17:00:00  Y    SYSTEM.257.1
   DATAFILE  MIRROR   COARSE    MAR 25 17:00:00  Y    UNDOTBS1.259.1
   DATAFILE  MIRROR   COARSE    MAR 25 17:00:00  Y    USERS.260.1
   → 데이터파일 4개 확인 (MIRROR 중복도, COARSE 스트라이핑 적용)
   → Sys=Y: 시스템이 자동으로 이름을 부여한 파일 (Fully Qualified Name)
*/


/* ============================================================================
   6. 스트라이핑 & 미러링 & Failure Group
   ============================================================================

   AU (Allocation Unit)
     · 정의   : ASM 디스크 공간을 일정 크기로 나눈 가장 기본 단위
     · 기본값 : 1MB
     · 설정   : 1 / 2 / 4 / 8 / 16 / 32 / 64 MB (디스크 그룹 생성 시 지정)
     · 관계   : AU들이 모여 ASM Extent 구성

   스트라이핑 (Striping)
     · 하나의 파일을 AU(Extent) 단위로 쪼개 여러 디스크에 나눠 저장하는 방식
     · 같은 디스크 그룹 내 디스크들에 고르게 분산
     · 효과: 부하 분산(Load Balancing) + Latency 감소

   미러링 (Mirroring)
     EXTERNAL : 미러링 없음 (1개) — 외부 스토리지에 하드웨어 RAID가 있는 경우
     NORMAL   : 2개 (양방향)     — 일반적인 권장 설정, Failure Group 2개 이상 필요
     HIGH     : 3개 (삼방향)     — 최고 가용성 요구 환경, Failure Group 3개 이상 필요

   Failure Group
     · 미러링된 복사본이 같은 장애 도메인에 함께 저장되지 않도록 강제하는 논리적 그룹
     · Failure Group이 다른 디스크에 원본·미러 복사본을 배치
     · 디스크 1개 장애 시 다른 Failure Group의 복사본으로 서비스 지속 가능

   현재 환경 구성 — +DATA, NORMAL Redundancy

     Failure Group DATA_0000    Failure Group DATA_0001
     ┌──────────┐                ┌──────────┐
     │  DATA1   │                │  DATA2   │
     │  DATA3   │                │  DATA4   │
     └──────────┘                └──────────┘
       ↑ 원본 Extent                ↑ 미러 Extent

   +OCR이 3개 디스크를 쓰는 이유
     RAC Voting Disk는 쿼럼(Quorum) 알고리즘 사용
     → 홀수 Failure Group(3개) 필요 → +OCR에 OCR1 / OCR2 / OCR3 각각 독립 Failure Group 구성
   ============================================================================ */

-- Failure Group 구성 확인 (SQL 방식)
CONN / AS SYSASM

SELECT dg.name AS diskgroup, dk.failgroup, dk.name AS disk_name,
       dk.state, dk.total_mb, dk.free_mb
FROM   v$asm_diskgroup dg
       JOIN v$asm_disk dk ON dg.group_number = dk.group_number
ORDER  BY dg.name, dk.failgroup, dk.disk_number;

/*
 [결과]
   DISKGROUP  FAILGROUP  DISK_NAME  STATE   TOTAL_MB  FREE_MB
   ---------  ---------  ---------  ------  --------  -------
   DATA       DATA_0000  DATA1      NORMAL  10238     9526
   DATA       DATA_0000  DATA3      NORMAL  10238     9526
   DATA       DATA_0001  DATA2      NORMAL  10238     9526
   DATA       DATA_0001  DATA4      NORMAL  10238     9526
   FRA        FRA_0000   FRA1       NORMAL  10238     9852
   FRA        FRA_0001   FRA2       NORMAL  10238     9852
   OCR        OCR1       OCR1       NORMAL  10238     9966
   OCR        OCR2       OCR2       NORMAL  10238     9966
   OCR        OCR3       OCR3       NORMAL  10238     9966
   REDO       REDO_0000  REDO1      NORMAL  10238     9797
   REDO       REDO_0001  REDO2      NORMAL  10238     9797
   → DATA, FRA, REDO: 디스크 2개씩 2개 Failure Group 구성 (NORMAL 2중 미러링)
   → OCR: 디스크 1개씩 3개 Failure Group 구성 (RAC Voting Disk 쿼럼 요건 충족)
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                     핵심 포인트
   ----------------------   ---------------------------------------------------
   ASM 인스턴스             SGA는 있음, PGA는 없음 — SQL 처리·사용자 세션 없어 PGA 불필요
   데이터 흐름              DB 인스턴스가 ASM에 파일 위치를 물어보고,
                            DB 인스턴스가 직접 디스크에서 읽음
   백그라운드 프로세스      RBAL(지시) / ARBn(실행) / GMON(감시) / MARK(정리)
   ASM 권한                 SYSASM(최고) / SYSDBA(데이터 접근) / SYSOPER(시작·정지)
   시작·종료 순서           시작: ASM 먼저 → DB / 종료: DB 먼저 → ASM
   crsctl                   CRS 데몬 레벨 제어 (stop has / start has / stat res -t)
   srvctl                   서비스 단위 제어 (start/stop database -d orcl)
   v$asm_diskgroup          디스크 그룹 상태·용량 확인 (STATE, TYPE, FREE_MB)
   v$asm_disk               개별 디스크 상태·경로 확인 (STATE, PATH, GROUP_NUMBER)
   v$asm_file               파일 타입·중복도 확인 (TYPE, REDUNDANCY)
                            → 컨트롤파일만 HIGH, 나머지는 MIRROR
   lsdg                     디스크 그룹 상세 조회 (Rebal 여부, Usable_file_MB, Voting_files)
   lsdsk                    개별 디스크 경로 확인 / -k 옵션으로 Failure Group 확인
   du                       실제 사용 공간 및 미러링 소비 공간 확인 (NORMAL: 2배 소비)
   ls -l                    ASM 파일 타입·중복도·스트라이핑 방식 확인
   AU                       ASM 기본 저장 단위 (기본 1MB, 디스크 그룹 생성 시 결정)
   스트라이핑               파일을 여러 디스크에 분산 → 부하 분산 + 지연 최소화
   미러링                   EXTERNAL(없음) / NORMAL(2중) / HIGH(3중)
   Failure Group            미러링 복사본이 같은 장애 도메인에 놓이지 않도록 격리
                            → DATA/FRA/REDO: 2개 FG / OCR: 3개 FG (쿼럼 요건)

   ============================================================================ */
   
