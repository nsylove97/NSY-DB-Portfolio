/*
================================================================================
 Data Guard 07: 운영 진단 & Active Data Guard & Logical Standby
================================================================================
 블로그: https://nsylove97.tistory.com/52
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
   1.  운영 진단 개요
   2.  Redo Transport 상태 진단
       2-1. Transport Lag / Apply Lag 확인 (VM3)
       2-2. Archive Dest 상태 확인 (VM1)
       2-3. Gap 감지 및 해소 확인 (VM3)
   3.  MRP 프로세스 진단
       3-1. MRP 상태 확인 (VM3)
       3-2. MRP 재기동 (VM3)
   4.  Data Guard 진단 뷰 심화
       4-1. v$dataguard_status — 이벤트 로그 (VM1 또는 VM3)
       4-2. v$dataguard_process — Redo Apply 진행 상태 (VM3)
       4-3. v$standby_log — SRL 상태 (VM3)
       4-4. LOG_ARCHIVE_TRACE 옵션 (VM1)
   5.  Alert Log & Broker Log 확인
       5-1. Primary Alert Log (VM1 — OS 터미널)
       5-2. Standby Alert Log (VM3 — OS 터미널)
       5-3. Broker Log (VM1, VM3 — OS 터미널)
   6.  Active Data Guard (Real-Time Query)
       6-1. Real-Time Query 활성화 및 확인 (VM3)
       6-2. Primary 데이터 입력 → Standby 즉시 조회 (VM1 → VM3)
       6-3. STANDBY_MAX_DATA_DELAY (VM3)
       6-4. Global Sequence (VM1 → VM3)
       6-5. ADG DML Redirect (VM1, VM3)
   7.  Logical Standby 개요
       7-1. SQL Apply 프로세스 확인
   8.  Logical Standby 구축
       8-1. LogMiner 딕셔너리 빌드 (VM1)
       8-2. 딕셔너리 전송 확인 및 Physical → Logical 전환 (VM1, VM3)
       8-3. DB 재기동 및 SQL Apply 시작 (VM3)
       8-4. 전환 후 상태 확인 (VM3)
   9.  Logical Standby 운영
       9-1. DBA_LOGSTDBY_EVENTS 조회 (VM3)
       9-2. 지원되지 않는 객체 확인 (VM3)
       9-3. Skip 규칙 설정 (VM3)
   10. Logical Standby에서 읽기·쓰기 테스트
       10-1. 읽기 전용 쿼리 (VM1 → VM3)
       10-2. Standby 전용 테이블 생성 및 조회 (VM3)
   11. Physical Standby 복귀
       11-1. SQL Apply 중지 및 NOMOUNT 재기동 (VM3)
       11-2. RMAN DUPLICATE로 Physical Standby 재구축 (VM1)
       11-3. MRP 재기동 및 역할 확인 (VM3)
   12. RMAN Backup from Standby
       12-1. 아카이브 로그 삭제 정책 설정 (VM3 — RMAN)
       12-2. Standby에서 전체 백업 (VM3 — RMAN)
       12-3. Primary에서 백업 파일 등록 및 검증 (VM1 — RMAN)
   13. 관련 뷰 & 명령어 정리
================================================================================
*/


/* ============================================================================
   1. 운영 진단 개요
   ============================================================================
   Data Guard 운영 중 핵심 점검 항목

   항목              설명
   ----------------  ---------------------------------------------------------
   Transport Lag     Primary에서 생성된 Redo가 Standby에 전달되기까지의 지연
   Apply Lag         Standby에 수신된 Redo가 실제로 적용되기까지의 지연

   두 값이 모두 0 → 실시간 동기화 상태
   Apply Lag이 커지면 → MRP 상태를 섹션 3에서 확인

   ============================================================================ */


/* ============================================================================
   2. Redo Transport 상태 진단
   ============================================================================ */

/* ----------------------------------------------------------------------------
   2-1. Transport Lag / Apply Lag 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SELECT name, value, time_computed
FROM   v$dataguard_stats
WHERE  name IN ('transport lag', 'apply lag');

/*
 [결과]
   NAME           VALUE        TIME_COMPUTED
   -------------- ------------ ----------------------------
   transport lag  +00 00:00:00 04/22/2026 21:08:03
   apply lag      +00 00:00:00 04/22/2026 21:08:03
   -> value가 +00 00:00:00 → 지연 없음 (실시간 동기화 상태)
   -> Apply Lag이 계속 커지면 MRP 프로세스 상태를 섹션 3에서 확인
*/

/* ----------------------------------------------------------------------------
   2-2. Archive Dest 상태 확인
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA]
SELECT dest_id, dest_name, status, target, archiver,
       schedule, destination, error
FROM   v$archive_dest
WHERE  dest_id IN (1, 2);

/*
 [결과]
   DEST_ID  DEST_NAME            STATUS   TARGET   ARCHIVER  SCHEDULE  DESTINATION            ERROR
   -------  -------------------  -------  -------  --------  --------  ---------------------  -----
         1  LOG_ARCHIVE_DEST_1   VALID    PRIMARY  ARCH      ACTIVE    USE_DB_RECOVERY_DEST
         2  LOG_ARCHIVE_DEST_2   VALID    STANDBY  LGWR      ACTIVE    orclstby_static
   -> DEST_2 STATUS=VALID, ERROR 컬럼 공백 → 전송 정상 확인
   -> STATUS=ERROR 또는 ERROR 컬럼에 값이 있으면 네트워크·Standby 상태 점검
*/

/* ----------------------------------------------------------------------------
   2-3. Gap 감지 및 해소 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
-- Standby에서 수신되지 않은 아카이브 로그 Gap 확인
SELECT thread#, low_sequence#, high_sequence#
FROM   v$archive_gap;

/*
 [결과 — Gap 없는 정상 상태]
   no rows selected
   -> Gap 없음 확인

 [Gap 발생 시 결과 예시]
   THREAD#  LOW_SEQUENCE#  HIGH_SEQUENCE#
   -------  -------------  ---------------
         1            105             107
   -> GAP 발생 시: FAL 프로세스가 자동으로 요청·복구 시도
   -> 자동 복구가 되지 않으면 Primary에서 아카이브 파일 직접 전송
*/


/* ============================================================================
   3. MRP 프로세스 진단
   ============================================================================ */

/* ----------------------------------------------------------------------------
   3-1. MRP 상태 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SELECT process, status, sequence#, block#, active_agents, known_agents
FROM   v$managed_standby
WHERE  process IN ('MRP0', 'RFS');

/*
 [정상 상태 결과]
   PROCESS  STATUS        SEQUENCE#  BLOCK#  ACTIVE_AGENTS  KNOWN_AGENTS
   -------  ------------  ---------  ------  -------------  ------------
   MRP0     APPLYING_LOG        112       1              1             1
   RFS      IDLE                  0       0              0             0
   -> MRP0 STATUS=APPLYING_LOG → Redo 적용 중 (정상)
   -> STATUS=WAIT_FOR_LOG  → Primary Redo 수신 대기 (정상 대기 상태)
   -> STATUS=WAIT_FOR_GAP  → Gap 해소 대기 중
   -> no rows selected     → MRP 미기동 → 3-2에서 재기동 필요
*/

/* ----------------------------------------------------------------------------
   3-2. MRP 재기동
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] MRP 중지 (이미 기동된 경우)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] MRP 재기동 (Real-Time Apply)
-- USING CURRENT LOGFILE : Online Redo Log 실시간 수신 즉시 적용
-- DISCONNECT FROM SESSION: 백그라운드 실행 — 세션 종료 후에도 MRP 유지
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
   -> MRP 재기동 완료
*/

-- [VM3 — SYSDBA] 재기동 후 상태 재확인
SELECT process, status, sequence#
FROM   v$managed_standby
WHERE  process IN ('MRP0', 'RFS');

/*
 [결과]
   PROCESS  STATUS        SEQUENCE#
   -------  ------------  ---------
   MRP0     APPLYING_LOG        112
   RFS      IDLE                  0
   -> APPLYING_LOG 확인
*/


/* ============================================================================
   4. Data Guard 진단 뷰 심화
   ============================================================================ */

/* ----------------------------------------------------------------------------
   4-1. v$dataguard_status — 이벤트 로그
   ---------------------------------------------------------------------------- */

/*
   v$dataguard_status 개요

   항목      설명
   --------  ---------------------------------------------------------------
   역할      Data Guard 관련 메시지(Redo 전송·Apply·오류)를 시간순 기록
             Alert Log에서 Data Guard 항목만 별도 조회하는 것과 동일한 역할
   SEVERITY  INFORMATIONAL → WARNING → ERROR → FATAL 순으로 심각도 증가
*/

-- [VM1 또는 VM3 — SYSDBA] 최근 Data Guard 이벤트 20건 조회
SELECT timestamp, severity, message
FROM   v$dataguard_status
ORDER BY timestamp DESC
FETCH FIRST 20 ROWS ONLY;

/*
 [결과 예시]
   TIMESTAMP          SEVERITY       MESSAGE
   ------------------ -------------- -----------------------------------------
   22-APR-26          Control        Beginning to archive T-1.S-26 ...
   22-APR-26          Control        Completed archiving T-1.S-26 ...
   22-APR-26          Control        Completed archiving LNO:1 T-1.S-26
   -> SEVERITY=WARNING 이상 항목은 원인 추가 조사 필요
*/

-- 오류·경고만 필터링
-- 트러블슈팅 시 아래 조건으로 필터링
SELECT timestamp, severity, message
FROM   v$dataguard_status
WHERE  severity IN ('Warning', 'Error', 'Fatal')
ORDER BY timestamp DESC;

/*
 [결과]
   -> 해당 없으면 no rows selected
   -> Warning·Error·Fatal 항목 발생 시 message 컬럼 내용으로 원인 파악
*/

/* ----------------------------------------------------------------------------
   4-2. v$dataguard_process — Redo Apply 진행 상태
   ---------------------------------------------------------------------------- */

/*
   v$dataguard_process 개요

   항목        설명
   ----------  -----------------------------------------------------------------
   역할        Data Guard 백그라운드 프로세스(MRP·RFS·TTnn 등) 역할 및 진행 상태
               v$managed_standby보다 더 넓은 범위의 프로세스 정보 제공
   DELAY_MINS  LOG_ARCHIVE_DEST_n의 DELAY= 옵션이 설정된 경우에만 값 채워짐
*/

-- [VM3 — SYSDBA]
SELECT name, role, action, sequence#, block#, delay_mins
FROM   v$dataguard_process
ORDER BY name;

/*
 [결과 예시]
   NAME   ROLE           ACTION           SEQUENCE#  BLOCK#  DELAY_MINS
   -----  -------------  ---------------  ---------  ------  ----------
   MRP0   MRP            APPLYING_LOG           113       1           0
   RFS    RFS            IDLE                     0       0           0
   TTnn   REDO TRANSPORT TRANSPORT                0       0           0
   -> MRP0 ACTION=APPLYING_LOG → 현재 시퀀스 113 적용 중
   -> DELAY_MINS=0             → 지연 없음 (DELAY 파라미터 미설정 상태)
*/

/* ----------------------------------------------------------------------------
   4-3. v$standby_log — SRL 상태
   ---------------------------------------------------------------------------- */

/*
   Standby Redo Log(SRL) 개요

   항목                설명
   ------------------  -------------------------------------------------------
   역할                Physical Standby가 Primary로부터 실시간 수신한 Redo를
                       임시 저장하는 로그 — Real-Time Apply의 전제 조건
   그룹 수 권장 기준   Online Redo Log 그룹 수 + 1 이상
   UNASSIGNED 그룹     대기 중인 그룹 (정상 상태)
                       UNASSIGNED 그룹이 없으면 SRL 부족 — 그룹 추가 필요
*/

-- [VM3 — SYSDBA]
SELECT group#, dbid, thread#, sequence#, bytes/1024/1024 AS size_mb,
       used, archived, status
FROM   v$standby_log
ORDER BY group#;

/*
 [결과 예시]
   GROUP#  DBID        THREAD#  SEQUENCE#  SIZE_MB  USED     ARCHIVED  STATUS
   ------  ----------  -------  ---------  -------  -------  --------  ----------
        4  UNASSIGNED        1          0      200        0  NO        UNASSIGNED
        5  1756622302        1         27      200  2982400  YES       ACTIVE
        6  UNASSIGNED        1          0      200        0  NO        UNASSIGNED
   -> STATUS=ACTIVE     : 현재 Primary로부터 Redo 수신 중인 그룹
   -> STATUS=UNASSIGNED : 대기 중인 그룹 (정상)
*/

-- [VM3 — SYSDBA] SRL 그룹 추가 (UNASSIGNED 그룹이 없는 경우)
-- ALTER DATABASE ADD STANDBY LOGFILE THREAD 1
--   GROUP 7 ('+REDO') SIZE 200M;

/* ----------------------------------------------------------------------------
   4-4. LOG_ARCHIVE_TRACE 옵션
   ---------------------------------------------------------------------------- */

/*
   LOG_ARCHIVE_TRACE 값 체계

   값   추적 대상
   ---  ----------------------------------------------------------
     1  아카이브 로그 파일 생성 추적
     2  아카이브 로그 목적지(dest) 활동 추적
     4  아카이브 로그 I/O 추적
     8  아카이브 로그 파일 상태 추적
    16  MAP 오퍼레이션 추적
    32  Race condition 해결 추적

   값을 합산하여 원하는 항목을 조합 (예: 1+2=3 → 생성·dest 활동 동시 추적)
   추적 결과는 Alert Log에 기록됨
   주의: 트러블슈팅 완료 후 반드시 0으로 되돌릴 것
*/

-- [VM1 — SYSDBA] 현재 설정 확인
SHOW PARAMETER log_archive_trace;

/*
 [결과]
   NAME               TYPE     VALUE
   ------------------ -------- -----
   log_archive_trace  integer  0
   -> 기본값 0 (비활성) 확인
*/

-- [VM1 — SYSDBA] 아카이브 생성 + dest 활동 추적 활성화 (1+2=3)
ALTER SYSTEM SET log_archive_trace = 3 SCOPE=BOTH;

/*
 [결과]
   System altered.
*/

SHOW PARAMETER log_archive_trace;

/*
 [결과]
   NAME               TYPE     VALUE
   ------------------ -------- -----
   log_archive_trace  integer  3
   -> 추적 활성화 확인 — Alert Log에서 아카이브 관련 상세 로그 확인 가능
*/

-- [VM1 — SYSDBA] 추적 비활성화 (트러블슈팅 완료 후 반드시 실행)
ALTER SYSTEM SET log_archive_trace = 0 SCOPE=BOTH;

/*
 [결과]
   System altered.
*/

SHOW PARAMETER log_archive_trace;

/*
 [결과]
   NAME               TYPE     VALUE
   ------------------ -------- -----
   log_archive_trace  integer  0
   -> 0으로 복원 확인
*/


/* ============================================================================
   5. Alert Log & Broker Log 확인
   ============================================================================ */

/* ----------------------------------------------------------------------------
   5-1. Primary Alert Log (VM1 — OS 터미널)
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — oracle 계정, OS 터미널]
   tail -f $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/alert_orcl.log

   확인 대상 키워드
   키워드                             의미
   --------------------------------   ------------------------------------------
   ARC                                아카이브 로그 생성 확인
   LGWR                               Standby로 Redo 전송 확인
   ORA-                               오류 발생 여부 확인
   Redo shipping client connected     Standby RFS 접속 확인
*/

/* ----------------------------------------------------------------------------
   5-2. Standby Alert Log (VM3 — OS 터미널)
   ---------------------------------------------------------------------------- */

/*
   # [VM3 — oracle 계정, OS 터미널]
   tail -f $ORACLE_BASE/diag/rdbms/orclstby/orclstby/trace/alert_orclstby.log

   확인 대상 키워드
   키워드             의미
   ----------------   -----------------------------------------------------------
   RFS                Primary에서 Redo 수신 확인
   MRP0               Redo 적용 확인
   Media Recovery Log 어느 시퀀스까지 적용됐는지 확인
   ORA-               오류 여부 확인
*/

/* ----------------------------------------------------------------------------
   5-3. Broker Log (VM1, VM3 — OS 터미널)
   ---------------------------------------------------------------------------- */

/*
   # [VM1] Broker Log 위치 확인
   ls $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/drcorcl.log

   # [VM3] Broker Log 위치 확인
   ls $ORACLE_BASE/diag/rdbms/orclstby/orclstby/trace/drcorclstby.log

   # [VM3] 실시간 확인
   tail -f $ORACLE_BASE/diag/rdbms/orclstby/orclstby/trace/drcorclstby.log

   Configuration·Switchover·Failover 관련 이벤트 모두 기록됨
   Broker 오류 발생 시 이 로그에서 상세 원인 확인
*/


/* ============================================================================
   6. Active Data Guard (Real-Time Query)
   ============================================================================ */

/*
   Active Data Guard(ADG) 개요

   구분             Physical Standby (기본)              Active Data Guard
   ---------------  -----------------------------------  --------------------------------
   Open 모드        MOUNTED 또는 READ ONLY               READ ONLY WITH APPLY
   Redo Apply       MOUNTED일 때 실행 가능               열린 상태에서도 계속 실행
   읽기 쿼리        READ ONLY로 열면 MRP 중단 필요       MRP 유지하면서 쿼리 가능
   라이선스         기본 포함                            Oracle Active Data Guard 옵션 필요
   주요 용도        DR                                   보고서 쿼리 분산, 읽기 부하 분산

   주의: ADG는 별도 Oracle Active Data Guard 라이선스 필요
         실습 환경에서는 기능 확인 목적으로 진행
*/

/* ----------------------------------------------------------------------------
   6-1. Real-Time Query 활성화 및 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] MRP 중지
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] READ ONLY로 오픈
ALTER DATABASE OPEN READ ONLY;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] MRP 재기동 (Real-Time Apply)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] READ ONLY WITH APPLY 상태 확인
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----  --------------  ---------------  ----------------------
   ORCL  orclstby        PHYSICAL STANDBY READ ONLY WITH APPLY
   -> READ ONLY WITH APPLY → ADG 활성 상태 확인
*/

/* ----------------------------------------------------------------------------
   6-2. Primary 데이터 입력 → Standby 즉시 조회
   ---------------------------------------------------------------------------- */

-- [VM1 — Primary] 데이터 입력
INSERT INTO hr.departments (department_id, department_name)
VALUES (999, 'ADG Test Dept');
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
*/

-- [VM3 — Standby] 실시간 반영 확인 (Real-Time Query)
SELECT department_id, department_name
FROM   hr.departments
WHERE  department_id = 999;

/*
 [결과]
   DEPARTMENT_ID  DEPARTMENT_NAME
   -------------  ---------------
             999  ADG Test Dept
   -> Primary 커밋 직후 Standby에서 즉시 조회 가능 (Real-Time Query) 확인
*/

/* ----------------------------------------------------------------------------
   6-3. STANDBY_MAX_DATA_DELAY
   ---------------------------------------------------------------------------- */

/*
   STANDBY_MAX_DATA_DELAY 개요

   역할       ADG에서 클라이언트 세션이 허용하는 최대 Apply Lag 지정 (세션 파라미터)
   기본값     NONE (제한 없음)
   초과 시    ORA-03172 반환 → 낡은 데이터 읽지 않도록 보호
   활용 패턴  읽기 정합성이 중요한 배치 쿼리에 세션 단위로 적용
*/

-- [VM3 — Standby, hr 계정 또는 일반 세션]
-- 허용 Apply Lag을 30초로 제한
ALTER SESSION SET standby_max_data_delay = 30;

/*
 [결과]
   Session altered.
*/

-- [VM3 — SYSDBA] 현재 Apply Lag 확인
SELECT name, value
FROM   v$dataguard_stats
WHERE  name = 'apply lag';

/*
 [결과 — Lag 기준 미만 시]
   NAME       VALUE
   ---------  ------------
   apply lag  +00 00:00:00
   -> Lag 0 → 쿼리 정상 실행 가능

 [결과 — Lag 기준 초과 시]
   ORA-03172: STANDBY_MAX_DATA_DELAY of 30 seconds exceeded
   -> Apply Lag이 30초를 넘으면 쿼리 차단
   -> Primary에서 직접 조회하도록 애플리케이션 로직 전환 필요
*/

/* ----------------------------------------------------------------------------
   6-4. Global Sequence
   ---------------------------------------------------------------------------- */

/*
   Session Sequence vs Global Sequence

   구분              설명
   ----------------  ---------------------------------------------------------
   Session Sequence  세션 내에서만 고유. Standby에서 로컬 캐시로 발급
                     Primary와 완전 동기화 아님 (기존 시퀀스 기본 동작)
   Global Sequence   Primary와 완전히 동기화된 값을 Standby에서 발급
                     CREATE SEQUENCE ... GLOBAL 키워드로 생성
*/

-- [VM1 — Primary] Global Sequence 생성
CREATE SEQUENCE seq_global_test
  START WITH 1
  INCREMENT BY 1
  GLOBAL;

/*
 [결과]
   Sequence created.
*/

-- [VM3 — Standby] ADG에서 시퀀스 발급 확인
SELECT seq_global_test.NEXTVAL FROM dual;

/*
 [결과]
   NEXTVAL
   -------
         1
   -> Standby에서도 시퀀스 발급 가능 확인
   -> GLOBAL 시퀀스는 Primary와 충돌 없이 고유 값 보장
*/

/* ----------------------------------------------------------------------------
   6-5. ADG DML Redirect
   ---------------------------------------------------------------------------- */

/*
   ADG DML Redirect 개요

   역할       Standby에서 발생한 DML을 자동으로 Primary로 전달하여 실행
              애플리케이션이 Standby에 연결된 상태에서도 쓰기 작업 처리 가능
   지원 버전  Oracle 19c 이상
   주의       Redirect된 DML은 Primary 네트워크 왕복 지연 포함
              → 대량 DML에는 부적합
   제어 단위  세션 단위 (ALTER SESSION ENABLE ADG_REDIRECT_DML)
*/

-- [VM1 — SYSDBA] ADG_REDIRECT_DML 파라미터 활성화
ALTER SYSTEM SET adg_redirect_dml = TRUE SCOPE=BOTH;

/*
 [결과]
   System altered.
*/

-- [VM3 — Standby, hr 계정 또는 일반 세션] DML Redirect 세션 활성화
ALTER SESSION ENABLE ADG_REDIRECT_DML;

/*
 [결과]
   Session altered.
*/

-- [VM3 — Standby, 일반 세션] Standby에서 INSERT 시도 (실제 실행은 Primary에서 수행됨)
INSERT INTO hr.departments (department_id, department_name)
VALUES (998, 'DML Redirect Test');
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
   -> Standby에서 실행되었지만 실제 DML은 Primary에서 수행됨
   -> Primary 커밋 후 Redo를 통해 Standby에 반영됨
*/

-- [VM3 — Standby] DML Redirect 반영 확인
SELECT department_id, department_name
FROM   hr.departments
WHERE  department_id = 998;

/*
 [결과]
   DEPARTMENT_ID  DEPARTMENT_NAME
   -------------  ------------------
             998  DML Redirect Test
   -> DML Redirect 후 Standby에서 즉시 조회 확인
*/


/* ============================================================================
   7. Logical Standby 개요
   ============================================================================ */

/*
   Physical vs Logical Standby 비교

   구분           Physical Standby              Logical Standby
   -------------  ----------------------------  --------------------------------
   적용 방식      Redo 블록 단위 복사 (MRP)      SQL 재구성 후 적용 (LSP/SQL Apply)
   읽기 접근      READ ONLY 또는 MOUNTED         READ WRITE 가능 (Standby 전용 객체 허용)
   지원 범위      모든 오브젝트 지원             일부 데이터 타입·DDL 제외
   주요 용도      DR, 읽기 분산                  보고서 DB, 추가 인덱스·뷰 운영
   역할 전환      Switchover / Failover          Switchover / Failover

   SQL Apply 처리 단계

   단계               프로세스                    역할
   -----------------  --------------------------  --------------------------------
   1. 읽기 (Reader)   LSP (LogMiner Server Proc)  Primary 아카이브·SRL을 LogMiner로 파싱
   2. 준비 (Preparer) LPnn                        파싱된 변경 내역을 트랜잭션 단위로 정렬
   3. 적용 (Applier)  LSnn                        정렬된 트랜잭션을 SQL로 변환하여 Standby에 적용

   LogMiner: Redo Log를 읽어 원본 SQL을 재구성하는 Oracle 내부 엔진
             DBMS_LOGSTDBY.BUILD로 빌드한 딕셔너리를 참조하여 오브젝트명·컬럼명 해석
             처리 불가 데이터 타입(BFILE, MLSLABEL 등) 및 특정 DDL은 Skip됨
*/

/* ----------------------------------------------------------------------------
   7-1. SQL Apply 프로세스 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] LSP / LPnn / LSnn 프로세스 확인 (Logical Standby 기동 후)
SELECT name, role, action, sequence#
FROM   v$dataguard_process
WHERE  name LIKE 'LS%' OR name LIKE 'LP%';

/*
 [결과 예시]
   NAME   ROLE       ACTION      SEQUENCE#
   -----  ---------  ----------  ---------
   LSP0   SQL APPLY  APPLYING          113
   LPnn   SQL APPLY  IDLE                0
   -> LSP0 ACTION=APPLYING → SQL Apply 정상 동작 중
*/


/* ============================================================================
   8. Logical Standby 구축
   ============================================================================ */

/* ----------------------------------------------------------------------------
   8-1. LogMiner 딕셔너리 빌드 (VM1)
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] Primary에서 LogMiner 메타데이터 빌드
-- Standby가 SQL Apply 시작 시 이 딕셔너리를 참조하여 Redo → SQL 변환 수행
-- 반드시 Physical Standby → Logical 전환 전 Primary에서 먼저 실행
EXECUTE DBMS_LOGSTDBY.BUILD;

/*
 [결과]
   PL/SQL procedure successfully completed.
   -> LogMiner 딕셔너리 빌드 완료
   -> 이 시점 이후의 아카이브 로그부터 SQL Apply에 사용 가능
*/

/* ----------------------------------------------------------------------------
   8-2. 딕셔너리 전송 확인 및 Physical → Logical 전환 (VM1, VM3)
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] 딕셔너리를 Standby로 강제 전송 (확실하게 2번 실행)
-- 빌드 직후 Standby에 전달되지 않아 무한 대기에 걸릴 수 있음
-- → 로그 스위치를 발생시켜 딕셔너리가 담긴 아카이브 로그를 Standby로 밀어냄
ALTER SYSTEM ARCHIVE LOG CURRENT;
ALTER SYSTEM ARCHIVE LOG CURRENT;

/*
 [결과]
   System altered. (각 명령마다)
*/

-- [VM1 — SYSDBA] 딕셔너리가 Standby에 도착했는지 확인
SELECT sequence#, applied, dictionary_begin, dictionary_end
FROM   v$archived_log
WHERE  dictionary_begin = 'YES' OR dictionary_end = 'YES';

/*
 [결과]
   SEQUENCE#  APPLIED  DICTIONARY_BEGIN  DICTIONARY_END
   ---------  -------  ----------------  ---------------
          26  YES      YES               NO
          27  YES      NO                YES
   -> DICTIONARY_BEGIN=YES 와 DICTIONARY_END=YES 쌍이 모두 확인되면 딕셔너리 도착 완료
   -> APPLIED=YES → Standby에 적용됨
*/

-- [VM3 — SYSDBA] MRP 중지 (Physical 적용 중지)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] Physical → Logical Standby 전환
-- 이 명령 실행 후 DB 재기동 필요
ALTER DATABASE RECOVER TO LOGICAL STANDBY orclstby;

/*
 [결과]
   Database altered.
   -> Physical Standby에서 Logical Standby로 전환됨

 [무한 대기 발생 시 해결 방법]
   -> 강제 종료(Ctrl+C) 후 VM1에서 DBMS_LOGSTDBY.BUILD 재실행
   -> ALTER SYSTEM ARCHIVE LOG CURRENT 2회 실행
   -> v$archived_log에서 딕셔너리 도착 확인 후 재시도
*/

/* ----------------------------------------------------------------------------
   8-3. DB 재기동 및 SQL Apply 시작 (VM3)
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA]
SHUTDOWN IMMEDIATE;

/*
 [결과]
   Oracle instance shut down.
*/

STARTUP MOUNT;

/*
 [결과]
   Oracle instance started.
   ...
   Database mounted.
*/

ALTER DATABASE OPEN RESETLOGS;

/*
 [결과]
   Database altered.
   -> RESETLOGS로 새 Incarnation 시작
*/

-- [VM3 — SYSDBA] SQL Apply 기동
-- IMMEDIATE: 현재 Online Redo Log 실시간 적용 (Real-Time Apply와 동일 개념)
ALTER DATABASE START LOGICAL STANDBY APPLY IMMEDIATE;

/*
 [결과]
   Database altered.
   -> SQL Apply 기동 완료
*/

/* ----------------------------------------------------------------------------
   8-4. 전환 후 상태 확인 (VM3)
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] 역할 및 Open 모드 확인
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----  --------------  ---------------  ----------
   ORCL  orclstby        LOGICAL STANDBY  READ WRITE
   -> LOGICAL STANDBY / READ WRITE 전환 확인
*/

-- [VM3 — SYSDBA] SQL Apply 상태 확인
SELECT session_id, realtime_apply, state
FROM   v$logstdby_state;

/*
 [결과]
   SESSION_ID  REALTIME_APPLY  STATE
   ----------  --------------  -----
            1  Y               IDLE
   -> REALTIME_APPLY=Y → Real-Time Apply 활성
   -> STATE=IDLE        → SQL Apply 대기 중 (Redo 수신 없는 정상 대기 상태)
*/


/* ============================================================================
   9. Logical Standby 운영
   ============================================================================ */

/* ----------------------------------------------------------------------------
   9-1. DBA_LOGSTDBY_EVENTS 조회
   ---------------------------------------------------------------------------- */

/*
   dba_logstdby_events 개요
   SQL Apply 중 발생하는 이벤트(오류·Skip·DDL·APPLIED)를 기록하는 뷰
   STATUS=ORA- 오류 발생 시 해당 SQL을 SKIP 처리하거나 원인 조사
*/

-- [VM3 — SYSDBA] 최근 SQL Apply 이벤트 20건 조회
SELECT event_time, status, event
FROM   dba_logstdby_events
ORDER BY event_time DESC
FETCH FIRST 20 ROWS ONLY;

/*
 [결과 예시]
   EVENT_TIME   STATUS   EVENT
   ----------   -------  --------------------------------------------------
   23-APR-26    SKIP     CREATE INDEX ...
   23-APR-26    APPLIED  INSERT INTO hr.employees ...
   -> SKIP    : 지원하지 않는 DDL 또는 Skip 규칙에 해당하는 SQL
   -> APPLIED : 정상 적용된 SQL
*/

/* ----------------------------------------------------------------------------
   9-2. 지원되지 않는 객체 확인
   ---------------------------------------------------------------------------- */

/*
   조회 뷰 구분

   뷰                          설명
   --------------------------  ---------------------------------------------------
   dba_logstdby_unsupported    데이터 타입 자체가 SQL Apply 미지원인 테이블
   dba_logstdby_not_unique     타입은 지원되나 PK/UK가 없어 행 특정 불가능한 테이블

   두 뷰 모두 목록에 포함된 테이블은 Logical Standby에서 동기화 보장되지 않음
*/

-- [VM3 — SYSDBA] SQL Apply 미지원 데이터 타입 테이블 확인
SELECT *
FROM   dba_logstdby_unsupported
ORDER BY owner, table_name;

/*
 [결과]
   -> 없으면 no rows selected (모두 지원)
   -> 있으면 해당 테이블 DML은 Standby에 적용되지 않음
      → 운영 테이블이 포함된 경우 Physical Standby 사용 권장
*/

-- [VM3 — SYSDBA] PK/UK 없어 행 특정 불가능한 테이블 확인 (UPDATE/DELETE 적용 불가)
SELECT owner, table_name
FROM   dba_logstdby_not_unique
ORDER BY owner, table_name;

/*
 [결과]
   -> 없으면 no rows selected (모두 행 특정 가능)
   -> 있으면 UPDATE/DELETE 시 행 특정 불가
      → PK 추가 또는 SUPPLEMENTAL LOG 설정 검토
*/

/* ----------------------------------------------------------------------------
   9-3. Skip 규칙 설정
   ---------------------------------------------------------------------------- */

/*
   Skip 규칙 설정 주의사항
   SQL Apply가 중지된 상태에서만 설정 가능
*/

-- [VM3 — SYSDBA] SQL Apply 중지 (Skip 규칙 변경 전 필수)
ALTER DATABASE STOP LOGICAL STANDBY APPLY;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] 특정 스키마 전체 DDL Skip 설정
EXECUTE DBMS_LOGSTDBY.SKIP(stmt => 'SCHEMA_DDL', schema_name => 'TEST_SCHEMA', object_name => '%');

/*
 [결과]
   PL/SQL procedure successfully completed.
   -> TEST_SCHEMA에 대한 DDL은 이후 적용하지 않음
*/

-- [VM3 — SYSDBA] Skip 규칙 확인
SELECT owner, name, statement_opt, use_like, error
FROM   dba_logstdby_skip
ORDER BY owner, name;

/*
 [결과]
   OWNER        NAME  STATEMENT_OPT  U  ERROR
   -----------  ----  -------------  -  -----
   TEST_SCHEMA  %     SCHEMA_DDL     Y  N
   -> TEST_SCHEMA에 적용된 Skip 규칙 확인
*/

-- [VM3 — SYSDBA] SQL Apply 재기동
ALTER DATABASE START LOGICAL STANDBY APPLY IMMEDIATE;

/*
 [결과]
   Database altered.
*/


/* ============================================================================
   10. Logical Standby에서 읽기·쓰기 테스트
   ============================================================================ */

/* ----------------------------------------------------------------------------
   10-1. 읽기 전용 쿼리 (Primary → Logical Standby 동기화 확인)
   ---------------------------------------------------------------------------- */

-- [VM1 — Primary] 데이터 입력
INSERT INTO hr.employees
  (employee_id, first_name, last_name, email, hire_date, job_id)
VALUES (300, 'Test', 'User', 'TUSER', SYSDATE, 'IT_PROG');
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
*/

-- [VM3 — Logical Standby] SQL Apply를 통한 동기화 확인
SELECT employee_id, first_name, last_name
FROM   hr.employees
WHERE  employee_id = 300;

/*
 [결과]
   EMPLOYEE_ID  FIRST_NAME  LAST_NAME
   -----------  ----------  ---------
           300  Test        User
   -> Primary 입력 데이터가 SQL Apply를 통해 Standby에 반영됨 확인
*/

/* ----------------------------------------------------------------------------
   10-2. Standby 전용 테이블 생성 및 조회
   ---------------------------------------------------------------------------- */

/*
   Logical Standby에서는 Primary와 무관한 독립 테이블 생성 가능 (READ WRITE 특성)
   주의: Physical Standby 복귀 시 Standby 전용 테이블은 전량 소멸됨
*/

-- [VM3 — SYSDBA]
CREATE TABLE logstdby_local_test (
  id    NUMBER,
  memo  VARCHAR2(100)
);

INSERT INTO logstdby_local_test VALUES (1, 'Logical Standby Only');
COMMIT;

SELECT * FROM logstdby_local_test;

/*
 [결과]
    ID  MEMO
   ---  --------------------
     1  Logical Standby Only
   -> Standby 전용 테이블 생성 및 DML 가능 확인
   -> Standby 전용 객체는 Primary 복제 대상이 아니므로 Primary 장애 후에도 보존되지 않음
*/


/* ============================================================================
   11. Physical Standby 복귀
   ============================================================================ */

/* ----------------------------------------------------------------------------
   11-1. SQL Apply 중지 및 NOMOUNT 재기동 (VM3)
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] SQL Apply 중지
ALTER DATABASE STOP LOGICAL STANDBY APPLY;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] db_name을 Primary와 동일한 'orcl'로 원상복구
ALTER SYSTEM SET db_name = 'orcl' SCOPE=SPFILE;

/*
 [결과]
   System altered.
*/

SHUTDOWN IMMEDIATE;

/*
 [결과]
   Oracle instance shut down.
*/

STARTUP NOMOUNT;

/*
 [결과]
   Oracle instance started.
   -> NOMOUNT 상태 — RMAN DUPLICATE 대기 상태
*/

/* ----------------------------------------------------------------------------
   11-2. RMAN DUPLICATE로 Physical Standby 재구축 (VM1)
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — oracle 계정, OS 터미널]
   # Logical Standby에서 Physical로 되돌리는 표준 절차 — RMAN DUPLICATE 재실행

   rman target sys/비밀번호@orcl auxiliary sys/비밀번호@orclstby_static

   RMAN> DUPLICATE TARGET DATABASE
         FOR STANDBY
         FROM ACTIVE DATABASE
         DORECOVER
         NOFILENAMECHECK;

   [결과]
   ...
   Finished Duplicate Db at ...
   -> Physical Standby로 재생성 완료
*/

/* ----------------------------------------------------------------------------
   11-3. MRP 재기동 및 역할 확인 (VM3)
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] MRP 재기동 (Real-Time Apply)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
   -> MRP 기동 및 Real-Time Apply 재개
   (ORA-01153 발생 시 — 이미 MRP가 DUPLICATE 과정에서 자동 기동된 상태, 정상)
*/

-- [VM3 — SYSDBA] 복귀 후 역할 확인
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----  --------------  ---------------  ----------
   ORCL  orclstby        PHYSICAL STANDBY MOUNTED
   -> PHYSICAL STANDBY 복귀 확인
*/

-- [VM3 — SYSDBA] MRP 상태 확인
SELECT process, status, sequence#
FROM   v$managed_standby
WHERE  process = 'MRP0';

/*
 [결과]
   PROCESS  STATUS        SEQUENCE#
   -------  ------------  ---------
   MRP0     APPLYING_LOG        ...
   -> APPLYING_LOG 확인
*/


/* ============================================================================
   12. RMAN Backup from Standby
   ============================================================================ */

/*
   Standby 백업 (Offload) 개요

   구분                  Primary 백업        Standby 백업 (Offload)
   --------------------  ------------------  ----------------------------------------
   백업 I/O 발생 위치    Primary             Standby
   Primary 부하          백업 I/O만큼 증가   거의 없음
   백업 이력 통합 조회   Control File 자동   Recovery Catalog 구성 시에만 자동 가능
   아카이브 로그 백업    Primary 또는 Standby Standby 권장 (Primary 부하 분산)

   주의:
   - 이번 실습은 Recovery Catalog 없이 Control File 기반으로 진행
   - 컨트롤 파일 기반 환경에서는 Standby 백업 이력이 Primary에 자동 동기화되지 않음
   - Primary에서 Standby 백업본 활용 시: 파일 복사 → CATALOG START WITH → 검증 순서
*/

/* ----------------------------------------------------------------------------
   12-1. 아카이브 로그 삭제 정책 설정 (VM3 — RMAN)
   ---------------------------------------------------------------------------- */

/*
   # [VM3 — oracle 계정, OS 터미널]
   rman target sys/비밀번호@orclstby

   RMAN> CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;

   [결과]
   new RMAN configuration parameters are being automatically stored
   -> MRP 지연 상태에서도 미적용 아카이브 로그가 보호됨
   -> 이후 DELETE INPUT 옵션 사용 시 적용된 로그만 삭제됨
*/

/* ----------------------------------------------------------------------------
   12-2. Standby에서 전체 백업 (VM3 — RMAN)
   ---------------------------------------------------------------------------- */

/*
   # [VM3 — RMAN]
   RMAN> BACKUP AS COMPRESSED BACKUPSET DATABASE
           FORMAT '+FRA'
           TAG 'STBY_FULL';

   [결과]
   Starting backup at 23-APR-26
   using channel ORA_DISK_1
   ...
   Finished backup at 23-APR-26
   -> Standby에서 전체 백업 완료 (Primary I/O 영향 없음)

   RMAN> BACKUP ARCHIVELOG ALL
           FORMAT '+FRA'
           DELETE INPUT;

   [결과]
   ...
   -> 아카이브 로그 백업 완료
   -> DELETE INPUT: 삭제 정책(APPLIED ON ALL STANDBY)에 따라 적용된 로그만 삭제
*/

/* ----------------------------------------------------------------------------
   12-3. Primary에서 백업 파일 등록 및 검증 (VM1)
   ---------------------------------------------------------------------------- */

/*
   # [VM3 — grid 계정] ASM에서 OS 경로로 백업 파일 추출 후 Primary로 전송
   # (ASM 환경에서는 FRA가 분리되어 있으므로 파일 직접 복사 필요)

   ASMCMD> cp +FRA/orclstby/backupset/<날짜>/<파일명>.bkp /tmp/STBY_FULL.bkp

   # [VM3 — oracle 계정] Primary로 scp 전송
   scp /tmp/STBY_FULL.bkp oracle@192.168.111.50:/tmp/


   # [VM1 — oracle 계정, OS 터미널]
   rman target /

   RMAN> CATALOG START WITH '/tmp/STBY_FULL.bkp';

   [결과]
   List of Files Unknown to the Database
   File Name: /tmp/STBY_FULL.bkp

   Do you really want to catalog the above files (enter YES or NO)? yes
   cataloging done
   -> Primary Control File에 백업 메타데이터 등록 완료
*/

-- [VM1 — SYSDBA] 컨트롤 파일에 등록된 Backup Piece 확인
SELECT piece#, completion_time, handle
FROM   v$backup_piece
ORDER BY completion_time;

/*
 [결과]
   PIECE#  COMPLETION_TIME  HANDLE
   ------  ---------------  ----------------------------------
        1  23-APR-26        /tmp/STBY_FULL.bkp
   -> 등록된 STBY_FULL.bkp 파일 확인 가능
*/

/*
   # [VM1 — RMAN] 등록된 백업으로 복구 가능 여부 검증
   RMAN> RESTORE DATABASE VALIDATE;

   [결과]
   channel ORA_DISK_1: validation complete, elapsed time: 00:00:25
   -> Standby 백업으로 Primary 복구 가능 여부 검증 완료
*/


/* ============================================================================
   13. 관련 뷰 & 명령어 정리
   ============================================================================ */

/*
   진단 뷰 정리

   뷰                         조회 목적
   -------------------------  -------------------------------------------------
   v$dataguard_stats          Transport Lag / Apply Lag 확인
   v$dataguard_status         Data Guard 이벤트 로그 (오류·경고 포함)
   v$dataguard_process        MRP·RFS·TTnn 프로세스 역할 및 진행 상태
   v$archive_dest             Archive Dest 상태 및 오류 확인
   v$archive_gap              Standby의 아카이브 Gap 확인
   v$standby_log              SRL 그룹 상태 및 할당 여부 확인
   v$managed_standby          MRP / RFS 프로세스 상태 확인
   v$logstdby_state           SQL Apply 상태 확인 (Logical Standby)
   dba_logstdby_events        SQL Apply 이벤트 및 오류 기록
   dba_logstdby_unsupported   SQL Apply 미지원 객체 목록 (데이터 타입)
   dba_logstdby_not_unique    PK/UK 없는 테이블 목록 (행 특정 불가)
   dba_logstdby_skip          Skip 규칙 목록 확인

   ============================================================================ */

/* ============================================================================
   주요 명령어 정리
   ============================================================================

   명령어                                                                설명
   --------------------------------------------------------------------  ---------------------------------
   ALTER SYSTEM SET log_archive_trace = N SCOPE=BOTH                    아카이브 추적 레벨 설정 (0=비활성)
   ALTER DATABASE OPEN READ ONLY                                         ADG 전환을 위한 Standby Open
   ALTER SESSION SET standby_max_data_delay = N                         허용 Apply Lag 상한 (세션 단위)
   ALTER SESSION ENABLE ADG_REDIRECT_DML                                Standby DML Redirect 활성화
   ALTER SYSTEM SET adg_redirect_dml = TRUE SCOPE=BOTH                  DML Redirect 파라미터 활성화
   EXECUTE DBMS_LOGSTDBY.BUILD                                          Primary LogMiner 딕셔너리 빌드
   ALTER SYSTEM ARCHIVE LOG CURRENT                                     로그 스위치 (딕셔너리 전송 유도)
   ALTER DATABASE RECOVER TO LOGICAL STANDBY orclstby                   Physical → Logical 전환
   ALTER DATABASE OPEN RESETLOGS                                        Logical 전환 후 새 Incarnation Open
   ALTER DATABASE START LOGICAL STANDBY APPLY IMMEDIATE                 SQL Apply 기동 (Real-Time)
   ALTER DATABASE STOP LOGICAL STANDBY APPLY                            SQL Apply 중지
   EXECUTE DBMS_LOGSTDBY.SKIP(stmt, schema_name, object_name)           Skip 규칙 설정
   ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL               MRP 중지
   ALTER DATABASE RECOVER MANAGED STANDBY DATABASE                      MRP 재기동 (Real-Time Apply)
     USING CURRENT LOGFILE DISCONNECT FROM SESSION
   CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY       아카이브 로그 삭제 정책 설정
   BACKUP AS COMPRESSED BACKUPSET DATABASE FORMAT '+FRA' TAG '...'      Standby 전체 백업
   BACKUP ARCHIVELOG ALL FORMAT '+FRA' DELETE INPUT                     아카이브 로그 백업 후 삭제
   CATALOG START WITH '/tmp/파일명.bkp'                                  백업 파일 Control File 등록
   RESTORE DATABASE VALIDATE                                            백업 파일 복구 가능 여부 검증

   ============================================================================ */

/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                              핵심 포인트
   --------------------------------  --------------------------------------------------
   Transport Lag / Apply Lag         v$dataguard_stats에서 확인, 0이면 실시간 동기화
   DG 이벤트 로그                    v$dataguard_status에서 확인, SEVERITY 기준 필터링
   DG 프로세스 상태                  v$dataguard_process에서 MRP·RFS·TTnn 역할 확인
   SRL 상태                          v$standby_log에서 확인, UNASSIGNED 없으면 그룹 추가
   LOG_ARCHIVE_TRACE                 트러블슈팅 시 활성화, 완료 후 반드시 0으로 복원
   Archive Gap                       v$archive_gap에서 감지, FAL이 자동 복구 시도
   MRP 상태                          v$managed_standby에서 확인, APPLYING_LOG가 정상
   Alert Log 위치                    $ORACLE_BASE/diag/rdbms/<uname>/<sid>/trace/alert_<sid>.log
   Broker Log 위치                   $ORACLE_BASE/diag/rdbms/<uname>/<sid>/trace/drc<sid>.log
   Active Data Guard                 READ ONLY WITH APPLY 상태, Oracle ADG 라이선스 필요
   STANDBY_MAX_DATA_DELAY            세션 단위 Apply Lag 상한, 초과 시 ORA-03172 반환
   DML Redirect                      Standby DML → Primary 자동 전달, 19c 이상 지원
   Physical vs Logical               Physical: 블록 단위 복사 / Logical: SQL 재구성 후 적용
   LogMiner 딕셔너리 빌드             DBMS_LOGSTDBY.BUILD → ARCHIVE LOG CURRENT 2회로 전송
   Logical Standby 전환              BUILD → RECOVER TO LOGICAL STANDBY → RESETLOGS
   SQL Apply 기동                    START LOGICAL STANDBY APPLY IMMEDIATE
   SQL Apply 아키텍처                LSP(읽기) → LPnn(정렬) → LSnn(적용) 3단계
   Logical Standby 특징              READ WRITE 가능, Standby 전용 객체 생성 가능
   지원 범위 제한                    dba_logstdby_unsupported + dba_logstdby_not_unique 확인
   Skip 규칙                         DBMS_LOGSTDBY.SKIP, SQL Apply 중지 상태에서만 설정 가능
   Physical 복귀 방법                db_name 원상복구 → NOMOUNT → RMAN DUPLICATE 재실행
   Standby 백업                      RMAN으로 Standby에서 백업 수행 → Primary I/O 부하 분산
   Standby 백업 주의                 컨트롤 파일 기반 환경에서 이력 미자동 동기화
                                     → 파일 복사 후 CATALOG START WITH로 수동 등록 필요
   ASM FRA 환경 주의                 FRA가 분리되어 있으므로 복구 시 파일 접근성 확인 필요

   ============================================================================ */
