/*
================================================================================
 Data Guard 06: Fast-Start Failover(FSFO) & Snapshot Standby
================================================================================
 블로그: https://nsylove97.tistory.com/51
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS             : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB             : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool           : SQL*Plus, MobaXterm(SSH)
   - Grid HOME      : /u01/app/19.3.0/gridhome
   - DB HOME        : /u01/app/oracle/product/19.3.0/dbhome
   - Primary (VM1)  : IP 192.168.111.50 / hostname oelsvr1     / db_unique_name orcl
   - Standby (VM3)  : IP 192.168.111.60 / hostname oel-standby / db_unique_name orclstby
   - Observer       : VM3 (Standby 서버에서 포그라운드로 실행)

 목차
   1. Fast-Start Failover 개요
   2. FSFO 전제 조건
      2-1. Protection Mode 확인 및 변경
      2-2. Flashback Database 활성화
   3. Observer 개념 및 역할
   4. Observer 서버 구성 절차 (VM3 활용)
   5. FSFO 활성화 절차
      5-1. Observer 기동 (VM3)
      5-2. FSFO 활성화 (VM1 — DGMGRL)
      5-3. FSFO 상태 확인
   6. Primary 장애 유도 및 자동 Failover 확인
      6-1. 장애 전 구성 확인
      6-2. Primary 강제 종료 (장애 시뮬레이션)
      6-3. Failover 완료 후 VM3 상태 확인
      6-4. DGMGRL에서 구성 확인
   7. Failover 이후 상태 점검
      7-1. 데이터베이스 상태 확인
      7-2. VALIDATE DATABASE
   8. Reinstate 절차
      8-1. 구 Primary 재기동 (VM1)
      8-2. Reinstate 실행
      8-3. Reinstate 완료 후 확인
      8-4. Switchover로 원래 구성 복귀
   9. Snapshot Standby 개요
  10. Physical → Snapshot Standby 전환
      10-1. 전환 전 상태 확인
      10-2. FSFO 비활성화
      10-3. Snapshot Standby 전환
      10-4. 전환 후 상태 확인
      10-5. Snapshot Standby에서 테스트 작업
  11. Snapshot Standby → Physical 복귀
      11-1. Physical Standby로 복귀
      11-2. 복귀 후 상태 확인
      11-3. 테스트 데이터 소멸 확인
      11-4. MRP 재기동
  12. 관련 뷰 & 명령어 정리
      12-1. 주요 DGMGRL 명령어
      12-2. 주요 SQL 조회
================================================================================
*/


/* ============================================================================
   1. Fast-Start Failover 개요
   ============================================================================
   - Fast-Start Failover(FSFO)
     : Broker가 Primary 장애를 자동으로 감지하고
       사람 개입 없이 Standby를 Primary로 승격시키는 기능

   구분별 비교
   +--------------------+-------------------------+----------------------------+
   | 구분               | Manual Failover         | Fast-Start Failover        |
   +--------------------+-------------------------+----------------------------+
   | 트리거             | DBA가 직접 실행         | Broker + Observer 자동 감지|
   | 개입 여부          | 수동                    | 자동                       |
   | 전제 조건          | Broker 구성             | Broker + Observer +        |
   |                    |                         | Flashback                  |
   | 복구 속도          | DBA 응답 시간에 따라    | 설정된 Threshold 내        |
   +--------------------+-------------------------+----------------------------+
   ============================================================================ */


/* ============================================================================
   2. FSFO 전제 조건
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. Protection Mode 확인 및 변경
   --------------------------------------------------------------------------
   ※ FSFO는 Maximum Availability 이상의 Protection Mode를 요구
   ※ Broker 기본값은 MaxPerformance이므로 먼저 변경해야 함
   -------------------------------------------------------------------------- */

-- [VM1 — DGMGRL]
-- 현재 Protection Mode 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Fast-Start Failover:  Disabled

   Configuration Status:
   SUCCESS
   -> MaxPerformance 상태 확인 → MaxAvailability로 변경 필요
*/

-- LogXptMode를 SYNC로 먼저 변경한 뒤 Protection Mode 변경
/*
   DGMGRL> EDIT DATABASE orcl     SET PROPERTY LogXptMode=SYNC;
   DGMGRL> EDIT DATABASE orclstby SET PROPERTY LogXptMode=SYNC;

   [결과 (각각)]
   Property "logxptmode" updated

   DGMGRL> EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability;

   [결과]
   Succeeded.

   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Fast-Start Failover:  Disabled

   Configuration Status:
   SUCCESS
   -> MaxAvailability 변경 확인
*/


/* --------------------------------------------------------------------------
   2-2. Flashback Database 활성화
   --------------------------------------------------------------------------
   ※ FSFO 사용 시 Flashback Database 필수
   ※ Failover 이후 Reinstate(구 Primary → Standby 복귀) 시 Flashback 사용
   ※ Primary·Standby 양쪽 모두 활성화해야 함
   -------------------------------------------------------------------------- */

-- [VM1, VM3 — SYSDBA] 현재 Flashback 상태 확인
SELECT name, db_unique_name, flashback_on
FROM   v$database;

/*
 [VM1 결과 예시 — 이전 실습에서 활성화된 경우]
   NAME  DB_UNIQUE_NAME  FLASHBACK_ON
   ----- --------------- ------------------
   ORCL  orcl            YES

 [VM3 결과 예시 — 이전 실습에서 활성화된 경우]
   NAME  DB_UNIQUE_NAME  FLASHBACK_ON
   ----- --------------- ------------------
   ORCL  orclstby        YES

 ※ NO인 경우 아래 명령어로 활성화
*/

-- [VM1 — SYSDBA] FRA 파라미터 확인 (Flashback 활성화를 위해 필요)
SHOW PARAMETER db_recovery_file_dest;

/*
 [결과]
   NAME                       TYPE         VALUE
   -------------------------- ------------ ----------------------------------------
   db_recovery_file_dest      string       +FRA
   db_recovery_file_dest_size big integer  10136M
   -> FRA 설정 확인
*/

-- [VM1 — SYSDBA] Flashback 활성화 (OFF인 경우)
ALTER DATABASE FLASHBACK ON;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] Standby에도 동일하게 활성화 (OFF인 경우)
ALTER DATABASE FLASHBACK ON;

/*
 [결과]
   Database altered.
*/

-- 활성화 후 양쪽 재확인
SELECT name, db_unique_name, flashback_on
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  FLASHBACK_ON
   ----- --------------- ------------------
   ORCL  orcl            YES
   -> YES 확인
*/


/* ============================================================================
   3. Observer 개념 및 역할
   ============================================================================
   - Observer: Primary와 Standby 양쪽을 모두 감시하는 독립 프로세스
   - Primary 장애를 감지했을 때 Failover 판단을 내리는 심판 역할

   Observer 구성 요소
   +---------------------------+---------------------------------------------------+
   | 구분                      | 설명                                              |
   +---------------------------+---------------------------------------------------+
   | 실행 위치                 | Primary·Standby와 별개의 서버가 원칙              |
   |                           | 본 실습에서는 VM3(Standby)에서 포그라운드 실행    |
   | 실행 바이너리             | DB HOME의 dgmgrl 명령 사용                        |
   | 프로세스 형태             | 포그라운드 or 백그라운드 실행 가능                |
   | Failover 판단 기준        | FastStartFailoverThreshold 초 동안 Primary 무응답 |
   | 자동 Reinstate            | AutoReinstate=TRUE 설정 시 자동 처리              |
   +---------------------------+---------------------------------------------------+

   ※ Observer가 없으면 FSFO 활성화 불가
   ※ Observer는 Primary와 Standby 양쪽 네트워크에 모두 접근 가능해야 함
   ============================================================================ */


/* ============================================================================
   4. Observer 서버 구성 절차 (VM3 활용)
   ============================================================================
   - VM3(Standby 서버)를 Observer로 활용
   - VM3의 tnsnames.ora에 Primary·Standby 접속 정보가 이미 있으므로 접속 테스트 진행
   - FSFO 활성화 전 VM3 tnsnames.ora에 orclstby_static 항목 추가 필요
   ============================================================================ */

-- [VM3 — oracle 계정, OS 터미널]
-- tnsnames.ora에 orclstby_static 항목 추가 (없는 경우)
-- vi $ORACLE_HOME/network/admin/tnsnames.ora

/*
 추가할 내용:
   ORCLSTBY_STATIC =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = oel-standby.localdomain)(PORT = 1521))
       (CONNECT_DATA =
         (SERVER = DEDICATED)
         (SERVICE_NAME = orclstby_DGMGRL.localdomain)
         (UR = A)
       )
     )
*/

-- 접속 테스트 (VM3 — oracle 계정, OS 터미널)
-- tnsping orcl
-- tnsping orclstby

/*
 [orcl 결과]
   Used TNSNAMES adapter to resolve the alias
   Attempting to contact (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)
     (HOST = oelsvr1.localdomain)(PORT = 1521))...)
   OK (0 msec)

 [orclstby 결과]
   Used TNSNAMES adapter to resolve the alias
   Attempting to contact (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)
     (HOST = oel-standby.localdomain)(PORT = 1521))...)
   OK (0 msec)
   -> 양쪽 접속 테스트 성공 확인
*/


/* ============================================================================
   5. FSFO 활성화 절차
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. Observer 기동 (VM3)
   --------------------------------------------------------------------------
   ※ VM3 별도 터미널에서 포그라운드로 실행
   ※ START OBSERVER 실행 시 해당 터미널이 Observer 전용으로 점유됨
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, OS 터미널에서 실행]
-- dgmgrl sys/비밀번호@orcl "START OBSERVER"

/*
 [결과]
   DGMGRL for Linux: Release 19.0.0.0.0
   Copyright (c) 1982, 2019, Oracle and/or its affiliates. All rights reserved.
   Welcome to DGMGRL, type "help" for information.
   Connected to "orcl"
   Connected as SYSDBA.
   Observer "oel-standby" started
   Observing...
   -> VM3에서 Observer 정상 기동 확인

   백그라운드 실행이 필요한 경우:
   dgmgrl sys/비밀번호@orcl
   DGMGRL> START OBSERVER FILE=observer.dat LOGFILE=observer.log
             CONNECT IDENTIFIER IS orcl;
*/


/* --------------------------------------------------------------------------
   5-2. FSFO 활성화 (VM1 — DGMGRL)
   --------------------------------------------------------------------------
   ※ Observer 기동 후 VM1에서 별도 터미널을 열어 DGMGRL 접속 후 실행
   -------------------------------------------------------------------------- */

/*
   -- [VM1 — DGMGRL]
   DGMGRL> ENABLE FAST_START FAILOVER;

   [결과]
   Enabled in Zero Data Loss Mode.
   -> Zero Data Loss Mode로 FSFO 활성화 확인
*/


/* --------------------------------------------------------------------------
   5-3. FSFO 상태 확인
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SHOW FAST_START FAILOVER;

   [결과]
   Fast-Start Failover: Enabled in Zero Data Loss Mode

     Protection Mode:    MaxAvailability
     Lag Limit:          0 seconds

     Threshold:          30 seconds
     Active Target:      orclstby
     Potential Targets:  "orclstby"
       orclstby   valid
     Observer:           oel-standby
     Shutdown Primary:   TRUE
     Auto-reinstate:     TRUE
     Observer Reconnect: (none)
     Observer Override:  FALSE

   Configurable Failover Conditions
     Health Conditions:
       Corrupted Controlfile          YES
       Corrupted Dictionary           YES
       Inaccessible Logfile            NO
       Stuck Archiver                  NO
       Datafile Write Errors          YES

     Oracle Error Conditions:
       (none)

   ※ Threshold: 30 seconds — Primary 무응답 30초 후 Failover 시작
   ※ Auto-reinstate: TRUE  — Failover 후 구 Primary 자동 Standby 복귀
   ※ Observer: oel-standby — VM3 Observer 정상 등록 확인
*/

-- 전체 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Fast-Start Failover: Enabled in Zero Data Loss Mode

   Configuration Status:
   SUCCESS
   -> FSFO Enabled + SUCCESS 확인
*/


/* ============================================================================
   6. Primary 장애 유도 및 자동 Failover 확인
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. 장애 전 구성 확인
   -------------------------------------------------------------------------- */

-- [VM1 — SYSDBA]
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE   OPEN_MODE
   ----- --------------- --------------- --------------------
   ORCL  orcl            PRIMARY         READ WRITE
*/


/* --------------------------------------------------------------------------
   6-2. Primary 강제 종료 (장애 시뮬레이션)
   --------------------------------------------------------------------------
   ※ SHUTDOWN ABORT: 인스턴스 즉시 종료 — Failover 조건 충족을 위해 사용
   ※ Observer가 Primary 응답 불가를 감지 → Threshold(30초) 이후 Failover 시작
   -------------------------------------------------------------------------- */

-- [VM1 — SYSDBA]
SHUTDOWN ABORT;

/*
 [결과]
   Oracle instance shut down.
*/

-- Observer 터미널(VM3)에서 Failover 진행 자동 출력 확인
/*
 [VM3 Observer 터미널 출력 예시]
   2026-04-21T15:33:04.571+09:00
   Initiating Fast-Start Failover to database "orclstby"...
   [S002 2026-04-21T15:33:04.571+09:00] Initiating Fast-start Failover.
   Performing failover NOW, please wait...
   Failover succeeded, new primary is "orclstby"
   2026-04-21T15:33:23.098+09:00
   [S002 2026-04-21T15:33:23.098+09:00] Fast-Start Failover finished...
   [W000 2026-04-21T15:33:23.098+09:00] Failover succeeded. Restart pinging.
*/


/* --------------------------------------------------------------------------
   6-3. Failover 완료 후 VM3 상태 확인
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE   OPEN_MODE
   ----- --------------- --------------- --------------------
   ORCL  orclstby        PRIMARY         READ WRITE
   -> orclstby가 PRIMARY / READ WRITE로 승격 확인
*/


/* --------------------------------------------------------------------------
   6-4. DGMGRL에서 구성 확인 (VM3)
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orclstby - Primary database
       Warning: ORA-16824: multiple warnings, including fast-start failover-related
                warnings, detected for the database

       orcl     - (*) Physical standby database (disabled)
         ORA-16661: the standby database needs to be reinstated

   Fast-Start Failover: Enabled in Zero Data Loss Mode

   Configuration Status:
   WARNING   (status updated 14 seconds ago)

   -> orcl: disabled 상태 — 구 Primary 아직 기동되지 않음
   -> orclstby: 새 Primary로 정상 등록
   -> ORA-16661: Reinstate 필요 경고
*/


/* ============================================================================
   7. Failover 이후 상태 점검
   ============================================================================ */

/* --------------------------------------------------------------------------
   7-1. 데이터베이스 상태 확인
   -------------------------------------------------------------------------- */

/*
   -- [VM3 — DGMGRL]
   DGMGRL> SHOW DATABASE orclstby;

   [결과]
   Database - orclstby

     Role:               PRIMARY
     Intended State:     TRANSPORT-ON
     Instance(s):
       orclstby

     Database Warning(s):
       ORA-16817: unsynchronized fast-start failover configuration
       ORA-16869: fast-start failover target not initialized

   Database Status:
   WARNING

   ※ ORA-16817 / ORA-16869:
      Redo를 받아줄 Standby(orcl)가 종료 상태 → 동기화 불가 / 다음 타겟 없음
      Reinstate 완료 후 해소됨
*/


/* --------------------------------------------------------------------------
   7-2. VALIDATE DATABASE
   -------------------------------------------------------------------------- */

/*
   DGMGRL> VALIDATE DATABASE orclstby;

   [결과]
     Database Role:    Primary database

     Ready for Switchover:  Yes

     Managed by Clusterware:
       orclstby:  NO
       Validating static connect identifier for the primary database orclstby...
       The static connect identifier allows for a connection to database "orclstby".

   -> Ready for Switchover: Yes — Switchover 준비 완료 확인
*/


/* ============================================================================
   8. Reinstate 절차
   ============================================================================
   - Reinstate: Failover 이후 구 Primary를 Standby로 복귀시키는 과정
   - Broker가 Flashback → Redo Apply → Standby 등록을 자동 처리
   ============================================================================ */

/* --------------------------------------------------------------------------
   8-1. 구 Primary 재기동 (VM1)
   --------------------------------------------------------------------------
   ※ Reinstate를 위해 MOUNT 상태로만 기동 — OPEN 불필요
   -------------------------------------------------------------------------- */

-- [VM1 — SYSDBA]
STARTUP MOUNT;

/*
 [결과]
   Oracle instance started.
   ...
   Database mounted.
*/


/* --------------------------------------------------------------------------
   8-2. Reinstate 실행 (VM3 — DGMGRL)
   --------------------------------------------------------------------------
   ※ Auto-reinstate=TRUE 설정 시 VM1 MOUNT 기동 후 자동으로 아래 과정 진행
   ※ 수동으로 실행해야 하는 경우 아래 명령어 사용
   -------------------------------------------------------------------------- */

/*
   DGMGRL> REINSTATE DATABASE orcl;

   [결과]
   Reinstating database "orcl", please wait...
   Operation requires shutdown of instance "orcl" on database "orcl"
   Shutting down instance "orcl"...
   ORA-01109: database not open
   Database dismounted.
   Oracle instance shut down.
   Operation requires startup of instance "orcl" on database "orcl"
   Starting up instance "orcl"...
   ...
   Reinstatement of database "orcl" succeeded
   -> Broker가 Flashback → Redo Apply → Standby 등록 자동 처리
*/


/* --------------------------------------------------------------------------
   8-3. Reinstate 완료 후 확인
   -------------------------------------------------------------------------- */

/*
   -- [VM3 — DGMGRL]
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orclstby - Primary database
       orcl     - (*) Physical standby database

   Fast-Start Failover: Enabled in Zero Data Loss Mode

   Configuration Status:
   SUCCESS   (status updated 41 seconds ago)
   -> orcl이 Physical Standby로 정상 복귀됨 / SUCCESS 확인
*/

-- [VM1 — SYSDBA] 역할 확인
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----- --------------- ---------------- --------------------
   ORCL  orcl            PHYSICAL STANDBY MOUNTED
   -> orcl이 PHYSICAL STANDBY로 정상 복귀됨
*/


/* --------------------------------------------------------------------------
   8-4. Switchover로 원래 구성 복귀 (orcl을 다시 Primary로)
   -------------------------------------------------------------------------- */

/*
   -- [VM3 — DGMGRL]
   DGMGRL> SWITCHOVER TO orcl;

   [결과]
   Performing switchover NOW, please wait...
   ...
   Switchover succeeded, new primary is "orcl"

   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Fast-Start Failover: Enabled in Zero Data Loss Mode

   Configuration Status:
   SUCCESS
   -> orcl이 Primary로 복귀됨 / orclstby가 Physical Standby로 전환됨
*/


/* ============================================================================
   9. Snapshot Standby 개요
   ============================================================================
   - Snapshot Standby: Physical Standby를 읽기·쓰기 가능한 테스트용 DB로 임시 전환

   구분별 비교
   +----------------------+--------------------------+----------------------------+
   | 구분                 | Physical Standby         | Snapshot Standby           |
   +----------------------+--------------------------+----------------------------+
   | 역할                 | DR / 읽기 전용 조회      | 읽기·쓰기 가능한 테스트 DB |
   | Redo 수신            | 계속 수신 중             | 수신 계속 / 적용은 보류    |
   | 복귀                 | 해당 없음                | Physical 복귀 시 Redo 재적용|
   | Flashback 의존성     | 불필요                   | 복귀에 Flashback 사용      |
   | 주요 용도            | 운영 DR                  | 테스트·패치 검증           |
   +----------------------+--------------------------+----------------------------+

   ※ Snapshot Standby 기간에도 Primary Redo는 계속 수신됨 (적용만 보류)
   ※ Physical 복귀 시 Flashback으로 전환 시점 복원 → 밀린 Redo 적용 → 동기화
   ============================================================================ */


/* ============================================================================
  10. Physical → Snapshot Standby 전환
   ============================================================================ */

/* --------------------------------------------------------------------------
   10-1. 전환 전 상태 확인
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----- --------------- ---------------- --------------------
   ORCL  orclstby        PHYSICAL STANDBY MOUNTED
*/


/* --------------------------------------------------------------------------
   10-2. FSFO 비활성화
   --------------------------------------------------------------------------
   ※ FSFO 활성화 상태에서는 Failover 대상 Standby를 전환할 수 없음
   ※ Snapshot Standby 전환 전 반드시 FSFO 비활성화 필요
   -------------------------------------------------------------------------- */

/*
   -- [VM1 — DGMGRL]
   DGMGRL> DISABLE FAST_START FAILOVER;

   [결과]
   Disabled.
*/


/* --------------------------------------------------------------------------
   10-3. Snapshot Standby 전환
   -------------------------------------------------------------------------- */

/*
   -- [VM1 — DGMGRL]
   DGMGRL> CONVERT DATABASE orclstby TO SNAPSHOT STANDBY;

   [결과]
   Converting database "orclstby" to a Snapshot Standby database, please wait...
   Database "orclstby" converted successfully.
*/


/* --------------------------------------------------------------------------
   10-4. 전환 후 상태 확인
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----- --------------- ---------------- --------------------
   ORCL  orclstby        SNAPSHOT STANDBY READ WRITE
   -> SNAPSHOT STANDBY / READ WRITE — 읽기·쓰기 가능한 상태로 전환됨
*/

-- [VM1 — DGMGRL] 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Snapshot standby database

   Fast-Start Failover: Disabled

   Configuration Status:
   SUCCESS
*/


/* --------------------------------------------------------------------------
   10-5. Snapshot Standby에서 테스트 작업 수행 (VM3)
   --------------------------------------------------------------------------
   ※ Physical 복귀 시 이 데이터는 모두 사라짐
      Flashback으로 전환 시점으로 되돌리기 때문
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA 또는 일반 계정]
CREATE TABLE test_snap (id NUMBER, val VARCHAR2(50));
INSERT INTO test_snap VALUES (1, 'Snapshot Test Data');
COMMIT;

SELECT * FROM test_snap;

/*
 [결과]
         ID VAL
 ---------- --------------------------------------------------
          1 Snapshot Test Data
*/


/* ============================================================================
  11. Snapshot Standby → Physical 복귀
   ============================================================================ */

/* --------------------------------------------------------------------------
   11-1. Physical Standby로 복귀
   -------------------------------------------------------------------------- */

/*
   -- [VM1 — DGMGRL]
   DGMGRL> CONVERT DATABASE orclstby TO PHYSICAL STANDBY;

   [결과]
   Converting database "orclstby" to a Physical Standby database, please wait...
   Operation requires shutdown of instance "orclstby" on database "orclstby"
   Shutting down instance "orclstby"...
   Database closed.
   Database dismounted.
   Oracle instance shut down.
   Operation requires startup of instance "orclstby" on database "orclstby"
   Starting up instance "orclstby"...
   ...
   Database "orclstby" converted successfully.
*/


/* --------------------------------------------------------------------------
   11-2. 복귀 후 상태 확인
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----- --------------- ---------------- --------------------
   ORCL  orclstby        PHYSICAL STANDBY MOUNTED
   -> PHYSICAL STANDBY / MOUNTED — 정상 복귀됨
*/


/* --------------------------------------------------------------------------
   11-3. 테스트 데이터 소멸 확인 (READ ONLY로 전환 후 확인)
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
ALTER DATABASE OPEN READ ONLY;

SELECT * FROM test_snap;

/*
 [결과]
   ORA-00942: table or view does not exist
   -> Snapshot Standby 기간 중 입력한 데이터 전량 소멸 확인
   -> Flashback으로 전환 시점 복원 후 밀린 Redo가 적용되어 Primary와 동기화됨
*/


/* --------------------------------------------------------------------------
   11-4. MRP 재기동 (Real-Time Apply)
   --------------------------------------------------------------------------
   ※ Physical 복귀 후 MRP가 자동 기동되지 않는 경우 수동 실행
   -------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
*/

-- [VM1 — DGMGRL] 최종 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Fast-Start Failover:  Disabled

   Configuration Status:
   SUCCESS   (status updated 41 seconds ago)
   -> orclstby가 Physical Standby로 복귀됨 / SUCCESS 확인
*/


/* ============================================================================
  12. 관련 뷰 & 명령어 정리
   ============================================================================ */

/* --------------------------------------------------------------------------
   12-1. 주요 DGMGRL 명령어
   --------------------------------------------------------------------------

   명령어                                                    설명
   --------------------------------------------------------  --------------------------------
   SHOW FAST_START FAILOVER                                  FSFO 상태·설정 확인
   ENABLE FAST_START FAILOVER                                FSFO 활성화
   DISABLE FAST_START FAILOVER                               FSFO 비활성화
   START OBSERVER                                            Observer 기동 (포그라운드)
   START OBSERVER FILE=<f> LOGFILE=<l>                       Observer 기동 (백그라운드)
     CONNECT IDENTIFIER IS <n>
   STOP OBSERVER                                             Observer 중지
   SHOW OBSERVERS                                            등록된 Observer 목록 확인
   REINSTATE DATABASE <db>                                   구 Primary를 Standby로 복귀
   SWITCHOVER TO <db>                                        Switchover — 역할 교체
   CONVERT DATABASE <db> TO SNAPSHOT STANDBY                 Snapshot Standby 전환
   CONVERT DATABASE <db> TO PHYSICAL STANDBY                 Physical Standby 복귀
   EDIT DATABASE <db> SET PROPERTY LogXptMode=SYNC           전송 모드 변경 (ASYNC→SYNC)
   EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability Protection Mode 변경
   -------------------------------------------------------------------------- */


/* --------------------------------------------------------------------------
   12-2. 주요 SQL 조회
   -------------------------------------------------------------------------- */

-- Flashback 상태 확인
SELECT name, db_unique_name, flashback_on
FROM   v$database;

-- DB 역할 / 보호 모드 확인
SELECT name, db_unique_name, database_role, open_mode,
       protection_mode, protection_level
FROM   v$database;

-- DG 구성원 목록
SELECT db_unique_name, parent_dbun, dest_role
FROM   v$dataguard_config;

-- Broker 구성원 및 접속 식별자 확인
SELECT database, connect_identifier, dataguard_role, enabled, status
FROM   v$dg_broker_config;

-- Transport / Apply Lag 확인
SELECT name, value, time_computed
FROM   v$dataguard_stats
WHERE  name IN ('transport lag', 'apply lag');

-- MRP 프로세스 상태 확인
SELECT process, status, sequence#, block#, active_agents, known_agents
FROM   v$managed_standby
WHERE  process = 'MRP0';

-- Broker Log 파일 위치 확인 (OS 명령어)
-- [VM1] ls $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/drcorcl.log
-- [VM3] ls $ORACLE_BASE/diag/rdbms/orclstby/orclstby/trace/drcorclstby.log


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                              핵심 포인트
   --------------------------------  -----------------------------------------------
   FSFO 전제 조건                    MaxAvailability 이상
                                     + Flashback ON (Primary·Standby 양쪽)
                                     + Observer 기동
   Observer 위치                     Primary·Standby와 별도 서버 원칙
                                     (본 실습: VM3 포그라운드 실행)
   Observer 기동                     dgmgrl sys/pw@orcl "START OBSERVER"
   FSFO 활성화                       ENABLE FAST_START FAILOVER
   Threshold 기본값                  30초 — Primary 무응답 시 Failover 시작
   Auto-reinstate                    TRUE 설정 시 구 Primary MOUNT 기동 후
                                     자동 Standby 복귀
   수동 Reinstate                    구 Primary를 MOUNT 상태로 기동 후
                                     REINSTATE DATABASE orcl
   Reinstate 내부 동작               Flashback → Redo 재적용 → Standby 등록 자동 처리
   Failover 후 구성 상태             orcl: disabled / ORA-16661 — Reinstate 필요
   Snapshot Standby 전환 전 필수     DISABLE FAST_START FAILOVER
   Snapshot Standby                  Physical Standby를 일시적으로 READ WRITE 전환
                                     Redo 수신은 계속 / 적용만 보류
   Snapshot → Physical 복귀          Flashback으로 전환 시점 복원
                                     → 밀린 Redo 적용 → Primary와 동기화
   Snapshot 기간 데이터              Physical 복귀 시 전량 소멸
   MRP 재기동                        ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
                                     USING CURRENT LOGFILE DISCONNECT FROM SESSION

   ============================================================================ */
