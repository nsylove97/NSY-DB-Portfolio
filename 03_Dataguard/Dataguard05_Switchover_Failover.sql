/*
================================================================================
 Data Guard 05: Switchover & Failover — 역할 전환 실습 & Reinstate
================================================================================
 블로그: https://nsylove97.tistory.com/50
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome
   - Primary (VM1) : IP 192.168.111.50 / hostname oelsvr1     / db_unique_name orcl
   - Standby (VM3) : IP 192.168.111.60 / hostname oel-standby / db_unique_name orclstby

 목차
   1. Flashback Database 활성화
      1-1. 현재 상태 확인
      1-2. Flashback Database 활성화 (VM3 — Standby)
      1-3. Flashback Database 활성화 (VM1 — Primary)
      1-4. 활성화 확인
   2. Switchover — 계획된 역할 전환
      2-1. Switchover 전 상태 확인
      2-2. Switchover 실행
      2-3. Switchover 결과 확인
   3. Switchback — 역방향 재전환
      3-1. Switchback 실행
      3-2. 원래 상태 복귀 확인
   4. Failover — 장애 시 역할 전환
      4-1. Failover 전 상태 확인
      4-2. Primary 장애 시뮬레이션 (SHUTDOWN ABORT)
      4-3. Failover 실행 (VM3)
      4-4. Failover 결과 확인
   5. Reinstate — 구 Primary를 Standby로 복귀
      5-1. 구 Primary 재기동 (MOUNT 상태)
      5-2. Reinstate 실행
      5-3. Reinstate 결과 확인
      5-4. 원래 구성으로 Switchback (선택)
   6. Switchover vs Failover 비교
================================================================================
*/


/* ============================================================================
   1. Flashback Database 활성화
   ============================================================================
   - Reinstate: Failover 후 구 Primary를 Flashback으로 장애 직전 시점으로
     되돌려 Standby로 복귀시키는 작업
   - Flashback Database가 꺼져 있으면 Reinstate 불가
   - Failover 실습 전 반드시 양쪽 모두 활성화해야 함
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. 현재 상태 확인
   -------------------------------------------------------------------------- */

-- [VM1, VM3 양쪽에서 확인 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT flashback_on FROM v$database;

/*
 [VM1, VM3 결과]
   FLASHBACK_ON
   ------------
   NO
   → 활성화 필요
*/


/* --------------------------------------------------------------------------
   1-2. Flashback Database 활성화 (VM3 — Standby)
   --------------------------------------------------------------------------
   ※ Flashback Database는 DB가 MOUNT 상태일 때만 활성화 가능
   ※ MRP가 동작 중인 Standby(VM3)는
      먼저 MRP를 중단하고 DB를 내린 뒤 MOUNT 상태로 재기동해야 함
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

-- MRP 중지
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Statement processed.
*/

-- MOUNT 상태로 재기동
SHUTDOWN IMMEDIATE;

/*
 [결과]
   Database closed.
   Database dismounted.
   ORACLE instance shut down.
*/

STARTUP MOUNT;

/*
 [결과]
   ORACLE instance started.
   ...
   Database mounted.
*/

-- Flashback Database 활성화
ALTER DATABASE FLASHBACK ON;

/*
 [결과]
   Database altered.
*/

-- MRP 재기동 (Real-Time Apply)
-- ※ SHUTDOWN 후 MOUNT로 재기동하면 MRP가 자동으로 재기동되는 경우 있음
-- ※ 아래 명령 실행 시 이미 동작 중이면 오류 발생하나 정상 동작 중이므로 무시
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
    USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과 — 이미 동작 중인 경우]
   ORA-01153: an incompatible media recovery is active
   → v$managed_standby에서 MRP0 APPLYING_LOG 상태이면 정상
*/


/* --------------------------------------------------------------------------
   1-3. Flashback Database 활성화 (VM1 — Primary)
   --------------------------------------------------------------------------
   ※ Primary는 OPEN 상태에서 바로 활성화 가능
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

ALTER DATABASE FLASHBACK ON;

/*
 [결과]
   Database altered.
*/


/* --------------------------------------------------------------------------
   1-4. 활성화 확인
   -------------------------------------------------------------------------- */

-- [VM1, VM3 양쪽에서 확인]
SELECT flashback_on FROM v$database;

/*
 [VM1, VM3 결과]
   FLASHBACK_ON
   ------------
   YES
   → Flashback Database 활성화 확인
*/


/* ============================================================================
   2. Switchover — 계획된 역할 전환
   ============================================================================
   - Switchover: DBA가 의도적으로 수행하는 계획된 역할 전환
   - 양쪽 DB가 모두 정상 상태에서 진행하며 데이터 손실이 없음
   - OS 패치, DB 업그레이드, 하드웨어 점검 등 유지보수 시 사용
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. Switchover 전 상태 확인
   -------------------------------------------------------------------------- */

-- Gap 없음 확인 — Primary의 Redo가 Standby에 빠짐없이 전달됐는지 확인
-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT name, value
FROM   v$dataguard_stats
WHERE  name IN ('transport lag', 'apply lag');

/*
 [결과]
   NAME           VALUE
   -------------  ----------
   transport lag  +00:00:00
   apply lag      +00:00:00
   → 두 값 모두 0초 — Gap 없음 확인
   → 값이 0초가 아니면 Redo 동기화 완료 후 Switchover 진행
*/

-- Tempfile 존재 여부 확인
-- Tempfile은 Redo로 전달되지 않으므로 Standby → Primary 전환 시 없으면
-- SORT, HASH JOIN, ORDER BY 등에서 오류 발생
SELECT name FROM v$tempfile;

/*
 [결과]
   NAME
   -----------------------------------------------
   +DATA/ORCLSTBY/TEMPFILE/temp.xxx
   → Tempfile 존재 확인
   → 결과가 없으면 Switchover 전에 수동으로 추가 필요
*/

-- ※ Tempfile이 없는 경우 추가 방법 (참고)
-- ALTER TABLESPACE temp ADD TEMPFILE '+DATA' SIZE 100M AUTOEXTEND ON;

-- Switchover 가능 여부 확인
-- [VM1 — oracle 계정, OS 터미널에서 DGMGRL 실행]
-- dgmgrl sys/비밀번호@orcl
/*
   DGMGRL> VALIDATE DATABASE orclstby;

   [결과 일부]
     Ready for Switchover:  Yes
   → Switchover 가능 확인
*/

-- 현재 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Configuration Status:
   SUCCESS
*/


/* --------------------------------------------------------------------------
   2-2. Switchover 실행
   --------------------------------------------------------------------------
   ※ Standby(orclstby)를 새 Primary로 지정
   ※ Broker가 자동으로 역할 전환 수행 — 수동 작업 불필요
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, DGMGRL에서 실행]
/*
   DGMGRL> SWITCHOVER TO orclstby;

   [결과]
   Performing switchover NOW, please wait...
   Operation requires a connection to database "orclstby"
   Connecting ...
   Connected to "orclstby"
   Connected as SYSDBA.
   New primary database "orclstby" is opening...
   Oracle Clusterware is restarting database "orcl" ...
   Connected to "orcl"
   Connected to "orcl"
   Switchover succeeded, new primary is "orclstby"
   DGMGRL>
*/


/* --------------------------------------------------------------------------
   2-3. Switchover 결과 확인
   -------------------------------------------------------------------------- */

-- DGMGRL에서 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orclstby - Primary database
     orcl     - Physical standby database

   Configuration Status:
   SUCCESS
   → orclstby가 Primary, orcl이 Standby로 역할 전환 확인
*/

-- VM1 (새 Standby)에서 역할 확인
-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [VM1 결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----  --------------  ---------------  ---------
   ORCL  orcl            PHYSICAL STANDBY MOUNTED
   → orcl이 Physical Standby로 전환됨 확인
*/

-- VM3 (새 Primary)에서 역할 확인
-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [VM3 결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE  OPEN_MODE
   ----  --------------  -------------  ----------
   ORCL  orclstby        PRIMARY        READ WRITE
   → orclstby가 Primary로 전환됨 확인
*/


/* ============================================================================
   3. Switchback — 역방향 재전환
   ============================================================================
   - Switchover 후 원래 상태(orcl = Primary, orclstby = Standby)로 되돌림
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. Switchback 실행
   --------------------------------------------------------------------------
   ※ 현재 Primary(orclstby)에 접속된 DGMGRL에서 실행
   ※ 또는 새로 접속: dgmgrl sys/비밀번호@orclstby
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SWITCHOVER TO orcl;

   [결과]
   Performing switchover NOW, please wait...
   ...
   Switchover succeeded ..
*/


/* --------------------------------------------------------------------------
   3-2. 원래 상태 복귀 확인
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Configuration Status:
   SUCCESS
   → orcl이 Primary로 복귀 확인
*/


/* ============================================================================
   4. Failover — 장애 시 역할 전환
   ============================================================================
   - Failover: Primary DB 장애 발생 시 Standby를 강제로 Primary로 승격시키는 비계획 전환
   - 데이터 손실이 발생할 수 있음 (보호 모드에 따라 상이)
   - Failover 이후 기존 Primary는 Data Guard 구성에서 제외(disabled) → Reinstate 또는 재생성 필요
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. Failover 전 상태 확인
   -------------------------------------------------------------------------- */

-- 현재 Primary 확인
-- [VM1 — oracle 계정, DGMGRL에서 실행]
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Configuration Status:
   SUCCESS
   → 현재 orcl이 Primary임을 확인 후 장애 시뮬레이션 진행
*/


/* --------------------------------------------------------------------------
   4-2. Primary 장애 시뮬레이션 (SHUTDOWN ABORT)
   --------------------------------------------------------------------------
   ※ SHUTDOWN ABORT: Instance Recovery 없이 즉시 종료 — 장애 상황 재현
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SHUTDOWN ABORT;

/*
 [결과]
   ORACLE instance shut down.
*/

-- VM1에서 SQL*Plus 재접속 시 idle 상태 확인
-- SQLPLUS / AS SYSDBA

/*
 [결과]
   Connected to an idle instance.
   → DB 다운 확인
*/


/* --------------------------------------------------------------------------
   4-3. Failover 실행 (VM3)
   --------------------------------------------------------------------------
   ※ Primary가 다운된 후 VM3(Standby)에서 DGMGRL로 Failover 실행
   ※ Complete Failover (기본값): 가능한 모든 Redo를 적용한 뒤 전환 — 데이터 손실 최소화
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, OS 터미널에서 DGMGRL 실행]
-- dgmgrl sys/비밀번호@orclstby

/*
   DGMGRL> FAILOVER TO orclstby;

   [결과]
   Performing failover NOW, please wait...
   Failover succeeded, new primary is "orclstby"
*/


/* --------------------------------------------------------------------------
   4-4. Failover 결과 확인
   -------------------------------------------------------------------------- */

-- DGMGRL에서 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orclstby - Primary database
     orcl     - Physical standby database (disabled)

   Configuration Status:
   WARNING
   → orclstby가 새 Primary로 승격
   → orcl은 disabled 상태 — Reinstate 필요
*/

-- VM3 (새 Primary)에서 역할 확인
-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [VM3 결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE  OPEN_MODE
   ----  --------------  -------------  ----------
   ORCL  orclstby        PRIMARY        READ WRITE
   → orclstby PRIMARY 승격 확인
*/


/* ============================================================================
   5. Reinstate — 구 Primary를 Standby로 복귀
   ============================================================================
   - Failover 후 기존 Primary(orcl)를 Flashback Database를 이용해
     장애 직전 시점으로 복구하고 새 Standby로 복귀시킴
   - Reinstate 전제 조건
       1. 구 Primary에 Flashback Database가 활성화되어 있어야 함
          → Failover 발생 시점 이후로 되돌릴 Flashback Log 필요
       2. 구 Primary가 MOUNT 상태로 기동되어 있어야 함
          → REINSTATE DATABASE 명령은 MOUNT 상태에서 동작
       3. 리스너가 기동 중이어야 함
          → Broker가 구 Primary에 접속해서 Reinstate 진행
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. 구 Primary 재기동 (MOUNT 상태)
   --------------------------------------------------------------------------
   ※ Failover로 장애가 발생한 VM1 DB를 MOUNT 상태로 기동
   ※ Reinstate는 MOUNT 상태에서 진행
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

STARTUP MOUNT;

/*
 [결과]
   ORACLE instance started.
   ...
   Database mounted.
*/

-- [VM1 — grid 계정, OS 터미널에서 리스너 상태 확인]
-- lsnrctl status

/*
 [결과 — 리스너 내려가 있는 경우]
   TNS-12541: TNS:no listener
   → 리스너 기동 필요
*/

-- 리스너 기동
-- lsnrctl start

/*
 [결과]
   The command completed successfully
*/


/* --------------------------------------------------------------------------
   5-2. Reinstate 실행
   --------------------------------------------------------------------------
   ※ 새 Primary(VM3)에서 DGMGRL로 실행
   ※ Broker가 구 Primary(VM1)에 접속하여 Flashback Database 적용 및 Standby 복구 자동 수행
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, DGMGRL에서 실행]
/*
   DGMGRL> REINSTATE DATABASE orcl;

   [결과]
   Reinstating database "orcl", please wait...
   Reinstatement of database "orcl" succeeded
*/


/* --------------------------------------------------------------------------
   5-3. Reinstate 결과 확인
   -------------------------------------------------------------------------- */

-- DGMGRL에서 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orclstby - Primary database
     orcl     - Physical standby database

   Configuration Status:
   SUCCESS
   → orcl이 Physical Standby로 복귀, SUCCESS 확인
*/

-- VM1 (복귀한 Standby)에서 역할 확인
-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [VM1 결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----  --------------  ---------------  ---------
   ORCL  orcl            PHYSICAL STANDBY MOUNTED
   → orcl Physical Standby 복귀 확인
*/

-- MRP 동작 확인
SELECT process, status, thread#, sequence#
FROM   v$managed_standby
WHERE  process LIKE 'MRP%' OR process LIKE 'RFS%';

/*
 [결과]
   PROCESS  STATUS        THREAD#  SEQUENCE#
   -------  ------------  -------  ---------
   RFS      IDLE                1         xx
   MRP0     APPLYING_LOG        1         xx
   → MRP0 APPLYING_LOG 확인 — Redo Apply 정상 동작
*/


/* --------------------------------------------------------------------------
   5-4. 원래 구성으로 Switchback (선택)
   --------------------------------------------------------------------------
   ※ 실습 환경을 원래 상태(orcl = Primary)로 되돌리려면
      Switchover를 한 번 더 수행
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, DGMGRL에서 실행]
/*
   DGMGRL> SWITCHOVER TO orcl;

   [결과]
   Performing switchover NOW, please wait...
   ...
   Switchover succeeded, new primary is "orcl"
*/

-- 구성 확인
/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Configuration Status:
   SUCCESS
   → 원래 구성으로 복귀 완료
*/


/* ============================================================================
   6. Switchover vs Failover 비교
   ============================================================================

   구분                    Switchover                  Failover
   ----------------------  --------------------------  --------------------------
   발생 조건               DBA의 계획된 전환              Primary 장애
   양쪽 DB 상태            모두 정상                      Primary 다운
   데이터 손실             없음                           보호 모드에 따라 가능
   기존 Primary 처리       자동으로 Standby 전환           disabled — Reinstate 또는 재생성 필요
   Flashback 필요 여부     불필요                         Reinstate 시 필수
   RESETLOGS              없음                          있음
   사용 시점               유지보수, 업그레이드             장애 복구

   ============================================================================ */

/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                              핵심 포인트
   --------------------------------  --------------------------------------------------
   Flashback Database                Reinstate 전제 조건
                                     Failover 실습 전 반드시 활성화
   Flashback 활성화 방법              Primary: OPEN 상태에서 바로 가능
                                     Standby: MRP 중단 → MOUNT → ALTER DATABASE FLASHBACK ON
   Switchover                        계획된 전환 — 데이터 손실 없음, 양쪽 DB 모두 정상 상태
   SWITCHOVER TO                     DGMGRL에서 새 Primary로 지정할 Standby 이름 명시
   Switchover 후 구 Primary          자동으로 Physical Standby로 전환 — 별도 작업 불필요
   Failover                          비계획 전환 — Primary 장애 시 Standby 강제 승격
   FAILOVER TO                       DGMGRL에서 승격할 Standby 이름 명시
   Failover 후 구 Primary             disabled 상태 — Reinstate 또는 재생성 필요
   Complete Failover                 FAILOVER TO 기본값
                                     가능한 모든 Redo 적용 후 전환 (데이터 손실 최소화)
   Reinstate                         Flashback으로 구 Primary를 장애 직전으로 되돌려 Standby 복귀
   Reinstate 실행 위치                새 Primary에서 DGMGRL로 실행
   Reinstate 전 구 Primary 상태       MOUNT + 리스너 기동 필수
   Switchback                        Reinstate 완료 후 원래 구성으로 되돌리려면 Switchover 한 번 더 수행

   ============================================================================ */
