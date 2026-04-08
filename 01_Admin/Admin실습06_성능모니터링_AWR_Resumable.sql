/*
================================================================================
 Admin 실습 06: 성능 모니터링 & AWR, Resumable
================================================================================
 블로그: https://nsylove97.tistory.com/35
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1. 데이터베이스 관리 개요
      1-1. 핵심 구성 요소 (AWR / Advisors / Automated Tasks / ADR)
      1-2. 대기 이벤트 확인
   2. 성능 모니터링
      2-1. Top Sessions 조회
      2-2. 메모리 리사이즈 이력 확인
   3. 오라클 메모리 관리 방식
      3-1. Memory Advisor — 메모리 크기 변경 효과 예측
      3-2. statistics_level 파라미터 확인
   4. AWR (Automatic Workload Repository)
      4-1. AWR 스냅샷 현황 확인
      4-2. AWR 스냅샷 수동 생성
      4-3. AWR 보관 기간 및 수집 주기 변경
      4-4. AWR 베이스라인 생성
      4-5. AWR 리포트 생성
      4-6. 특정 SQL AWR 히스토리 조회
   5. ADDM (Automatic Database Diagnostic Monitor)
      5-1. ADDM 분석 결과 목록 확인
      5-2. ADDM 분석 권고 내용 확인
   6. Automated Tasks (자동 유지보수 작업)
      6-1. 자동 유지보수 작업 현황 확인
      6-2. 통계 정보 수동 갱신 (전/후 비교)
   7. ADR (Automatic Diagnostic Repository)
   8. Resumable Space Allocation
================================================================================
*/


/* ============================================================================
   1. 데이터베이스 관리 개요
   ============================================================================
   - response time = 실행 time(CPU 처리 시간) + wait time(대기 시간)
     → 실행 시간을 줄이는 것 : SQL 튜닝
     → 대기 시간을 줄이는 것 : 서버 튜닝

   핵심 구성 요소
     AWR           : 성능 스냅샷 자동 수집(Top SQL, 대기 이벤트 등) → 튜닝 근거 제공
     Advisors      : 메모리 / 세그먼트 / SQL에 대해 개선 권고 제시
     Automated Tasks: 옵티마이저 통계 갱신, 세그먼트 점검 등 정기 자동 작업 수행
     Server Alerts : 공간 부족 같은 임계치 경보 발생 시 알림
     ADR           : 에러 / 크래시 발생 시 로그·트레이스 자동 보관 → 원인 분석 지원
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-2. 대기 이벤트 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- DB가 어떤 이유로 대기하는지 이벤트 목록 확인
SELECT name, wait_class FROM v$event_name;

/*
 [결과]
   NAME                          WAIT_CLASS
   ----------------------------  ----------
   ...                           ...
   → 1920개의 대기 이벤트 정의됨
*/


/* ============================================================================
   2. 성능 모니터링
   ============================================================================
   성능 저하의 주요 원인
     Memory allocation issues : 메모리가 부족하거나 잘못 배분되어 성능 저하
     Resource contention       : 여러 작업이 같은 자원(락, 래치, CPU)을 두고 대기 발생
     Network bottlenecks       : 클라이언트↔DB 간 통신 지연으로 응답 지연
     I/O device contention     : 디스크 읽기/쓰기 속도 한계로 대기 발생
     Application code problems : 비효율 SQL·로직으로 불필요한 처리 증가
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. Top Sessions 조회
   --------------------------------------------------------------------------
   지표 설명
     CPU          : CPU를 가장 많이 사용하는 세션
     PGA Memory   : 작업용 메모리를 많이 사용하는 세션
     Logical Reads: 메모리에서 블록을 많이 읽음 (풀 스캔 의심)
     Physical Reads: 디스크에서 많이 읽음 (I/O 부담 큼)
     Hard Parse   : 매번 실행 계획을 새로 생성 (바인드 변수 미사용 의심)
     Sort         : 정렬 작업이 많아 Temporary 테이블스페이스 사용 가능성 있음
   -------------------------------------------------------------------------- */

-- 현재 DB에서 리소스를 가장 많이 사용하는 세션 조회
SELECT * FROM v$sess_time_model
ORDER  BY value DESC
FETCH FIRST 10 ROWS ONLY;

/*
 [결과]
   SID  STAT_NAME                      VALUE
   ---  ----------------------------   -----
   ...  background elapsed time        ...   ← 백그라운드 프로세스가 가장 많이 리소스 사용
   ...  ...                            ...
*/


/* --------------------------------------------------------------------------
   2-2. 메모리 리사이즈 이력 확인
   -------------------------------------------------------------------------- */

-- 오라클이 자동으로 메모리 크기를 늘리거나 줄인 이력 조회
SELECT component, oper_type, final_size, target_size, start_time
FROM   v$memory_resize_ops
ORDER  BY start_time DESC;

/*
 [결과]
   COMPONENT  OPER_TYPE  FINAL_SIZE  TARGET_SIZE  START_TIME
   ---------  ---------  ----------  -----------  ----------
   (행 없음)
   → 리사이즈 이력 없음 (자동 조정 발생하지 않은 상태)
*/

-- SGA 각 구성 요소의 현재 크기 및 최소/최대 범위 확인
SELECT component, current_size, min_size, max_size, granule_size
FROM   v$memory_dynamic_components;

/*
 [결과]
   COMPONENT              CURRENT_SIZE  MIN_SIZE  MAX_SIZE  GRANULE_SIZE
   ---------------------  ------------  --------  --------  ------------
   shared pool            ...           ...       ...       ...
   buffer cache           ...           ...       ...       ...
   large pool             ...           ...       ...       ...
   ...
*/


/* ============================================================================
   3. 오라클 메모리 관리 방식
   ============================================================================
   AMM  : MEMORY_TARGET 하나로 SGA+PGA 통합 자동 관리. Memory Advisor만 사용 가능
   ASMM : SGA_TARGET으로 SGA만 자동 배분. SGA 관련 Advisor + PGA Advisor 사용 가능
   수동  : Shared Pool, Buffer Cache 등 각 영역을 개별 파라미터로 직접 크기 설정
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. Memory Advisor — 메모리 크기 변경 효과 예측
   -------------------------------------------------------------------------- */

-- MEMORY_TARGET을 늘리거나 줄였을 때 DB 성능 변화를 예상해주는 뷰
SELECT memory_size, memory_size_factor, estd_db_time, estd_db_time_factor
FROM   v$memory_target_advice
ORDER  BY memory_size;

/*
 [결과]
   MEMORY_SIZE  MEMORY_SIZE_FACTOR  ESTD_DB_TIME  ESTD_DB_TIME_FACTOR
   -----------  ------------------  ------------  -------------------
   392          0.5                 ...           1                   ← 메모리 줄여도 DB Time 변화 없음
   784          1.0                 ...           1                   ← 현재 값
   1176         1.5                 ...           1                   ← 메모리 늘려도 DB Time 변화 없음
   ...
   → 현재 실습 환경에서는 메모리를 늘리거나 줄여도 DB Time 변화 없음
*/


/* --------------------------------------------------------------------------
   3-2. statistics_level 파라미터 확인
   --------------------------------------------------------------------------
   - AWR 정상 작동을 위한 전제 조건
   - TYPICAL : AWR 정상 작동 (권장값)
   - BASIC   : AWR 미수집 (성능 통계 수집 최소화)
   - ALL     : 세밀한 SQL 튜닝 상황에서만 사용
   -------------------------------------------------------------------------- */

SHOW PARAMETER statistics_level

/*
 [결과]
   NAME               TYPE    VALUE
   -----------------  ------  -------
   statistics_level   string  TYPICAL  ← TYPICAL이어야 AWR 정상 작동
*/


/* ============================================================================
   4. AWR (Automatic Workload Repository)
   ============================================================================
   - DB 성능 스냅샷(ASH, Top SQL, 대기 이벤트 등)을 주기적으로 자동 수집·보관하는 저장소
   - 데이터는 SYSAUX 테이블스페이스에 저장됨
   - 과거 시점 성능 원인 분석 및 기간 비교 리포트 생성에 활용
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. AWR 스냅샷 현황 확인
   -------------------------------------------------------------------------- */

-- 날짜 포맷 설정 (시·분·초까지 보기 편하게)
ALTER SESSION SET nls_date_format = 'YYYY-MM-DD HH24:MI:SS';

-- AWR 스냅샷 목록 확인
SELECT snap_id, begin_interval_time, end_interval_time
FROM   dba_hist_snapshot
ORDER  BY snap_id DESC
FETCH FIRST 10 ROWS ONLY;

/*
 [결과]
   SNAP_ID  BEGIN_INTERVAL_TIME     END_INTERVAL_TIME
   -------  ----------------------  ----------------------
   32       2026-03-09 22:00:00     2026-03-09 22:14:11
   31       2026-03-09 21:00:00     2026-03-09 22:00:00
   ...
*/


/* --------------------------------------------------------------------------
   4-2. AWR 스냅샷 수동 생성
   -------------------------------------------------------------------------- */

-- AWR 스냅샷 즉시 한 번 더 수집
EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT();

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- 생성 확인 — 가장 큰 SNAP_ID가 하나 증가한 것을 확인
SELECT snap_id, begin_interval_time
FROM   dba_hist_snapshot
ORDER  BY snap_id DESC
FETCH FIRST 3 ROWS ONLY;

/*
 [결과]
   SNAP_ID  BEGIN_INTERVAL_TIME
   -------  ----------------------
   33       2026-03-09 22:14:11     ← 방금 수동 생성된 스냅샷
   32       2026-03-09 22:00:00
   31       2026-03-09 21:00:00
*/


/* --------------------------------------------------------------------------
   4-3. AWR 보관 기간 및 수집 주기 변경
   -------------------------------------------------------------------------- */

-- 현재 AWR 설정 확인 (보관 기간, 스냅샷 주기)
SELECT snap_interval, retention
FROM   dba_hist_wr_control;

/*
 [결과]
   SNAP_INTERVAL     RETENTION
   ----------------  ----------------
   +00000 01:00:00   +00008 00:00:00   ← 1시간 주기, 8일 보관
*/

-- AWR 보관 기간 변경 (단위: 분)
-- 스냅샷 주기 60분, 보관 기간 14일(20160분)으로 변경
EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(
    interval  => 60,
    retention => 20160
);

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- 변경 확인
SELECT snap_interval, retention
FROM   dba_hist_wr_control;

/*
 [결과]
   SNAP_INTERVAL     RETENTION
   ----------------  ----------------
   +00000 01:00:00   +00014 00:00:00   ← 보관 기간 14일로 변경 확인
*/


/* --------------------------------------------------------------------------
   4-4. AWR 베이스라인 생성
   --------------------------------------------------------------------------
   - 정상 운영 구간을 이름 붙여 저장
   - 이후 특정 구간과 비교할 때 기준으로 활용
   - 꼭 생성할 필요는 없지만, 성능 비교 분석 시 유용
   -------------------------------------------------------------------------- */

-- AWR 스냅샷 목록 확인 (베이스라인으로 쓸 구간 파악)
SELECT snap_id, begin_interval_time
FROM   dba_hist_snapshot
ORDER  BY snap_id DESC;

-- 정상 운영 구간(예: 3월 7일)을 베이스라인으로 생성
EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_BASELINE(
    start_snap_id => 20,
    end_snap_id   => 25,
    baseline_name => 'NORMAL_PERIOD'
);

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- 베이스라인 목록 확인
SELECT baseline_name, start_snap_id, end_snap_id
FROM   dba_hist_baseline;

/*
 [결과]
   BASELINE_NAME         START_SNAP_ID  END_SNAP_ID
   --------------------  -------------  -----------
   NORMAL_PERIOD         20             25            ← 방금 생성한 베이스라인
   SYSTEM_MOVING_WINDOW  ...            ...           ← 기본 이동 베이스라인 (자동 생성)
*/


/* --------------------------------------------------------------------------
   4-5. AWR 리포트 생성
   --------------------------------------------------------------------------
   - awrrpt.sql 스크립트를 실행하면 대화식으로 리포트 파일을 생성
   - SQL*Plus에서 실행
   -------------------------------------------------------------------------- */

-- @?/rdbms/admin/awrrpt.sql

/*
 [실행 순서]
   1) 리포트 유형 입력: html 또는 text
   2) 며칠치 스냅샷 보여줄지 입력: 숫자 (또는 Enter → 기본값)
   3) 시작 SNAP_ID 입력: 31
   4) 종료 SNAP_ID 입력: 32
   5) 파일명 입력: (Enter → 자동 생성 awrrpt_1_31_32.txt)

 [결과]
   awrrpt_1_31_32.txt 파일이 현재 경로에 생성됨
   → DB 전체 성능 요약, Top SQL, 주요 대기 이벤트 원인 포함
   주의: 너무 오래된 구간의 SNAP_ID를 입력하면 보관 기간 초과로 리포트 생성 실패 가능
*/


/* --------------------------------------------------------------------------
   4-6. 특정 SQL AWR 히스토리 조회
   -------------------------------------------------------------------------- */

-- 테스트용 — hr 계정에서 같은 쿼리 20번 반복 실행 (SNAP_ID에 기록 남기기 위해)
CONN hr/hr

BEGIN
    FOR i IN 1..20 LOOP
        EXECUTE IMMEDIATE
            'SELECT * FROM employees WHERE department_id = 50';
    END LOOP;
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- sql_text로 sql_id 확인
SELECT sql_id, sql_text
FROM   v$sql
WHERE  sql_text LIKE '%employees%'
AND    sql_text NOT LIKE '%v$sql%'
AND    rownum <= 5;

/*
 [결과]
   SQL_ID         SQL_TEXT
   -------------  --------------------------------------------------
   3q2k7...       SELECT * FROM employees WHERE department_id = 50
*/

-- sql_id로 AWR 히스토리 조회
CONN / AS SYSDBA

SELECT snap_id, sql_id, executions_delta, elapsed_time_delta, cpu_time_delta
FROM   dba_hist_sqlstat
WHERE  sql_id = '&sql_id'
ORDER  BY snap_id;

/*
 [결과 예시]
   SNAP_ID  SQL_ID        EXECUTIONS_DELTA  ELAPSED_TIME_DELTA  CPU_TIME_DELTA
   -------  ------------  ----------------  ------------------  --------------
   32       3q2k7...      20                11500               ...
   → 20번 실행되었고 총 약 11.5ms 걸린 것을 확인
*/


/* ============================================================================
   5. ADDM (Automatic Database Diagnostic Monitor)
   ============================================================================
   - AWR 스냅샷 구간을 자동 분석하여 전체 성능을 늦춘 가장 큰 지연 원인을 찾고
     해결책까지 제시해주는 도구
   - AWR 스냅샷이 찍힐 때마다 백그라운드에서 자동으로 실행됨
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. ADDM 분석 결과 목록 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- ADDM 분석 결과 목록 확인
SELECT task_name, status, execution_start, execution_end
FROM   dba_advisor_log
WHERE  task_name LIKE 'ADDM%'
ORDER  BY task_id DESC;

/*
 [결과]
   TASK_NAME                  STATUS     EXECUTION_START      EXECUTION_END
   -------------------------  ---------  -------------------  -------------------
   ADDM:1752501865_1_2        COMPLETED  2026-03-09 22:00:00  2026-03-09 22:00:01
   ADDM:1752501865_1_1        COMPLETED  2026-03-09 21:00:00  2026-03-09 21:00:01
   ...
*/


/* --------------------------------------------------------------------------
   5-2. ADDM 분석 권고 내용 확인
   -------------------------------------------------------------------------- */

-- ADDM 분석 권고 내용 확인 (task_name은 위 조회 결과에서 복사)
SELECT finding_name, type, message
FROM   dba_advisor_findings
WHERE  task_name = 'ADDM:1752501865_1_2';

/*
 [결과]
   FINDING_NAME     TYPE            MESSAGE
   ---------------  --------------  -------------------------------------------
   ...              INFORMATION     Database time was not consuming significant...
   → 현재 실습 환경에서는 성능 문제가 없어 별다른 권고 없음
*/


/* ============================================================================
   6. Automated Tasks (자동 유지보수 작업)
   ============================================================================
   오라클은 매일 정해진 시간에 아래 작업을 자동으로 실행함
     옵티마이저 통계 수집 : 실행 계획 최적화를 위해 테이블/인덱스 통계 갱신
     세그먼트 점검        : 공간 낭비(Segment Advisor)를 찾아 권고
     문제 SQL 진단        : SQL Tuning Advisor로 비효율 SQL 자동 분석
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. 자동 유지보수 작업 현황 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- 자동 유지보수 작업 현황 확인
SELECT client_name, status
FROM   dba_autotask_client;

/*
 [결과]
   CLIENT_NAME                    STATUS
   -----------------------------  -------
   auto optimizer stats collection ENABLED
   auto space advisor             ENABLED
   sql tuning advisor             ENABLED
*/


/* --------------------------------------------------------------------------
   6-2. 통계 정보 수동 갱신 실습 (전/후 비교)
   --------------------------------------------------------------------------
   - 통계 정보가 없으면 옵티마이저가 Rows/Cost를 추정하지 못해 비효율적인 실행 계획 수립
   - DBMS_STATS.GATHER_TABLE_STATS로 통계를 수동 갱신하면 정확한 실행 계획 수립 가능
   -------------------------------------------------------------------------- */

-- STEP 1: 현재 통계 정보 확인 (갱신 전)
SELECT table_name, num_rows, blocks, last_analyzed
FROM   dba_tables
WHERE  owner = 'HR'
AND    table_name = 'EMPLOYEES';

/*
 [결과 — 갱신 전]
   TABLE_NAME   NUM_ROWS  BLOCKS  LAST_ANALYZED
   -----------  --------  ------  -------------
   EMPLOYEES    107       5       09-MAR-26     ← 이전 통계 반영 상태
   (또는 null일 수도 있음 — 한 번도 통계를 수집하지 않은 경우)
*/

-- STEP 2: 통계를 강제로 삭제하여 '통계 없음' 상태 재현
EXEC DBMS_STATS.DELETE_TABLE_STATS('HR', 'EMPLOYEES');

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- STEP 3: 통계 삭제 후 확인
SELECT table_name, num_rows, blocks, last_analyzed
FROM   dba_tables
WHERE  owner = 'HR'
AND    table_name = 'EMPLOYEES';

/*
 [결과 — 통계 없음]
   TABLE_NAME   NUM_ROWS  BLOCKS  LAST_ANALYZED
   -----------  --------  ------  -------------
   EMPLOYEES    (null)    (null)  (null)          ← 통계 없음 (옵티마이저가 실행 계획 잡기 어려운 상태)
*/

-- STEP 4: 통계 갱신 전 실행 계획 확인 — Rows/Cost 추정 불가
CONN hr/hr
SET AUTOTRACE TRACEONLY EXPLAIN

SELECT * FROM employees WHERE department_id = 50;

/*
 [결과 — 갱신 전 실행 계획]
   PLAN_TABLE_OUTPUT
   -----------------------------------------------------------
   | Id | Operation         | Name      | Rows | Bytes | Cost |
   -----------------------------------------------------------
   |  0 | SELECT STATEMENT  |           |      |       |      |  ← Rows·Cost 공백 (통계 없음)
   |  1 |  TABLE ACCESS FULL| EMPLOYEES |      |       |      |
   -----------------------------------------------------------
   → 통계가 없어 옵티마이저가 Rows/Cost 추정 불가
*/

SET AUTOTRACE OFF

-- STEP 5: 통계 수동 갱신
CONN / AS SYSDBA
EXEC DBMS_STATS.GATHER_TABLE_STATS('HR', 'EMPLOYEES');

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- STEP 6: 통계 정보 확인 (갱신 후)
SELECT table_name, num_rows, blocks, last_analyzed
FROM   dba_tables
WHERE  owner = 'HR'
AND    table_name = 'EMPLOYEES';

/*
 [결과 — 갱신 후]
   TABLE_NAME   NUM_ROWS  BLOCKS  LAST_ANALYZED
   -----------  --------  ------  -------------------
   EMPLOYEES    107       5       09-MAR-26           ← 통계 반영 완료
*/

-- STEP 7: 통계 갱신 후 실행 계획 확인 — Rows/Cost 추정 가능
CONN hr/hr
SET AUTOTRACE TRACEONLY EXPLAIN

SELECT * FROM employees WHERE department_id = 50;

/*
 [결과 — 갱신 후 실행 계획]
   PLAN_TABLE_OUTPUT
   -----------------------------------------------------------
   | Id | Operation         | Name      | Rows | Bytes | Cost |
   -----------------------------------------------------------
   |  0 | SELECT STATEMENT  |           |   45 |  3645 |    3 |  ← 정확한 추정값 생성됨
   |  1 |  TABLE ACCESS FULL| EMPLOYEES |   45 |  3645 |    3 |
   -----------------------------------------------------------
   → 통계 반영 후 옵티마이저가 Rows/Cost 추정 가능 → 더 나은 실행 계획 수립
*/

SET AUTOTRACE OFF


/* ============================================================================
   7. ADR (Automatic Diagnostic Repository)
   ============================================================================
   - 오라클이 에러·충돌 발생 시 로그와 트레이스 파일을 자동 보관하는 통합 저장소
   - Alert Log, Trace File, Incident 정보가 모두 여기에 저장됨
   ============================================================================ */

CONN / AS SYSDBA

-- ADR 기본 경로 확인
SHOW PARAMETER diagnostic_dest

/*
 [결과]
   NAME             TYPE    VALUE
   ---------------  ------  -------------------
   diagnostic_dest  string  /u01/app/oracle
*/

/*
 [Alert Log 실시간 확인] — 터미널에서 실행
   tail -f /u01/app/oracle/diag/rdbms/orcl/orcl/trace/alert_orcl.log

 [결과]
   ...
   Mon Mar 09 22:00:00 2026
   Starting background process MMON
   ...
   → DB 내부 이벤트, 에러, 스냅샷 기록 등이 실시간으로 출력됨
*/


/* ============================================================================
   8. Resumable Space Allocation
   ============================================================================
   - 공간 부족(테이블스페이스 / Quota 초과 / Undo 부족)으로 SQL이 실패하지 않고
     일시 정지된 후, DBA가 공간을 늘리면 자동으로 재개되는 기능
   ============================================================================ */

/* --------------------------------------------------------------------------
   STEP 1: [SYS] 실습용 소용량 테이블스페이스 생성
   --------------------------------------------------------------------------
   - 5MB로 생성 + AUTOEXTEND OFF → 금방 가득 차도록 설정
   - 공간 부족 상황을 인위적으로 재현하기 위함
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

CREATE TABLESPACE small_tbs
    DATAFILE '/u01/app/oracle/oradata/ORCL/small_tbs01.dbf'
    SIZE 5M
    AUTOEXTEND OFF;

/*
 [결과]
   Tablespace created.
*/

-- hr에게 small_tbs 사용 권한 부여 (무제한 쿼터)
ALTER USER hr QUOTA UNLIMITED ON small_tbs;

/*
 [결과]
   User altered.
*/


/* --------------------------------------------------------------------------
   STEP 2: [hr] 실습용 대용량 테이블 생성
   -------------------------------------------------------------------------- */

CONN hr/hr

CREATE TABLE big_data (
    id   NUMBER,
    pad  VARCHAR2(2000)
) TABLESPACE small_tbs;

/*
 [결과]
   Table created.
*/


/* --------------------------------------------------------------------------
   STEP 3: [hr] Resumable 모드 OFF 상태에서 대용량 INSERT → 에러 확인
   -------------------------------------------------------------------------- */

-- 반복 INSERT 프로시저로 공간 부족 유도
BEGIN
    FOR i IN 1..10000 LOOP
        INSERT INTO big_data VALUES (i, RPAD('X', 2000, 'X'));
    END LOOP;
    COMMIT;
END;
/

/*
 [결과 — Resumable OFF]
   ERROR at line 1:
   ORA-01653: unable to extend table HR.BIG_DATA by 128 in tablespace SMALL_TBS
   → 즉시 에러 발생 후 자동 롤백됨 (데이터 없음)
*/

-- 테이블 초기화 (다음 실습을 위해)
TRUNCATE TABLE big_data;

/*
 [결과]
   Table truncated.
*/


/* --------------------------------------------------------------------------
   STEP 4: [hr] Resumable 모드 ON 상태에서 동일 작업 → 일시 정지 확인
   --------------------------------------------------------------------------
   ※ 이 세션(세션 1)은 INSERT 실행 중 일시 정지 상태로 멈춤
   ※ 세션 2(SYS)를 별도로 열어 STEP 5 조회 진행
   -------------------------------------------------------------------------- */

-- [SYS] hr에게 RESUMABLE 권한 부여
CONN / AS SYSDBA
GRANT RESUMABLE TO hr;

/*
 [결과]
   Grant succeeded.
*/

-- [hr — 세션 1] Resumable 모드 활성화
-- TIMEOUT: 공간 문제가 해결되길 기다리는 최대 시간(초)
CONN hr/hr
ALTER SESSION ENABLE RESUMABLE TIMEOUT 3600 NAME 'my_insert_job';

/*
 [결과]
   Session altered.
*/

-- 동일한 대용량 INSERT 재실행
-- → 공간 부족 시 에러 대신 일시 정지됨 (세션이 멈춰 있는 상태)
BEGIN
    FOR i IN 1..10000 LOOP
        INSERT INTO big_data VALUES (i, RPAD('X', 2000, 'X'));
    END LOOP;
    COMMIT;
END;
/
-- ↑ 이 세션은 공간 부족 시점에서 일시 정지 상태로 멈춰 있음


/* --------------------------------------------------------------------------
   STEP 5: [SYS — 세션 2] 일시 정지된 작업 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

SELECT session_id, name, status, error_msg
FROM   dba_resumable
WHERE  status = 'SUSPENDED';

/*
 [결과]
   SESSION_ID  NAME            STATUS     ERROR_MSG
   ----------  --------------  ---------  ------------------------------------------
   128         my_insert_job   SUSPENDED  ORA-01653: unable to extend table HR.BIG_DATA...
   → Resumable 덕분에 에러 대신 일시 정지 상태로 대기 중
*/

/*
 [alert log에서도 확인 가능] — 터미널에서 실행
   tail -f /u01/app/oracle/diag/rdbms/orcl/orcl/trace/alert_orcl.log

 [결과]
   Statement suspended, wait error to be cleared
   ORA-01653: unable to extend table HR.BIG_DATA by 128 in tablespace SMALL_TBS
*/


/* --------------------------------------------------------------------------
   STEP 6: [SYS] 데이터파일 추가로 공간 해결 → 세션 1 자동 재개
   -------------------------------------------------------------------------- */

ALTER TABLESPACE small_tbs
    ADD DATAFILE '/u01/app/oracle/oradata/ORCL/small_tbs02.dbf'
    SIZE 50M;

/*
 [결과]
   Tablespace altered.
   → 세션 1의 일시 정지가 풀리며 INSERT 작업 자동 재개됨
*/


/* --------------------------------------------------------------------------
   STEP 7: [hr — 세션 1] INSERT 완료 확인
   -------------------------------------------------------------------------- */

CONN hr/hr

SELECT COUNT(*) FROM big_data;

/*
 [결과]
   COUNT(*)
   --------
   10000    ← 일시 정지 후 재개되어 모든 데이터 정상 입력됨
*/

-- Resumable 모드 비활성화
ALTER SESSION DISABLE RESUMABLE;

/*
 [결과]
   Session altered.
*/


/* --------------------------------------------------------------------------
   STEP 8: 실습 후 정리
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

DROP TABLE hr.big_data PURGE;

/*
 [결과]
   Table dropped.
*/

DROP TABLESPACE small_tbs INCLUDING CONTENTS AND DATAFILES;

/*
 [결과]
   Tablespace dropped.
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                   핵심 포인트
   ---------------------- ---------------------------------------------------
   데이터베이스 관리      AWR / Advisors / Automated Tasks / ADR이 핵심 4요소
   성능 모니터링          v$sess_time_model, v$memory_dynamic_components로
                          병목 세션·메모리 확인
   AMM / ASMM / 수동      MEMORY_TARGET → AMM, SGA_TARGET → ASMM, 개별 파라미터 → 수동
   Memory Advisor         v$memory_target_advice로 메모리 크기 변경 전 효과 예측
   AWR 스냅샷             DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT()으로 수동 생성
   AWR 베이스라인         정상 구간을 이름 붙여 저장 → 이후 비교 분석의 기준으로 활용
   AWR 보관 기간          MODIFY_SNAPSHOT_SETTINGS으로 주기·보관 기간 변경
   AWR 리포트             @?/rdbms/admin/awrrpt.sql → 시작/종료 SNAP_ID 지정 후 파일로 생성
   ADDM                   AWR 스냅샷마다 자동 분석 → dba_advisor_findings에서 권고 내용 확인
   Automated Tasks        통계 수집 / 세그먼트 점검 / SQL 진단 자동 수행
                          → dba_autotask_client에서 현황 확인
   통계 수동 갱신         DBMS_STATS.GATHER_TABLE_STATS → 통계 없으면 실행 계획 추정 불가
                          → 갱신 후 Rows/Cost 정확히 계산되어 더 나은 실행 계획 수립 가능
   ADR                    diagnostic_dest 경로에 Alert Log / Trace File 자동 보관
   Resumable              GRANT RESUMABLE → ALTER SESSION ENABLE RESUMABLE
                          → 공간 부족 시 에러 대신 일시 정지 → 공간 추가 시 자동 재개

   ============================================================================ */
