/*
================================================================================
 Admin 실습 05: Lock & Undo & 감사(Audit)
================================================================================
 블로그: https://nsylove97.tistory.com/34
 GitHub: https://github.com/nsylove97/Seongryeol-OracleDB-Portfolio

 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1. Lock
      1-1. Lock 상태 확인 & Kill Session 실습
      1-2. Deadlock 실습
   2. Undo Data
      2-1. Undo 관련 파라미터 확인
      2-2. Retention Guarantee 설정
      2-3. Undo 테이블스페이스 추가 & 전환
   3. 감사 (Audit)
      3-1. Audit Trail 저장 위치 설정
      3-2. Standard Audit (표준 감사)
      3-3. Value-Based Auditing (값 기반 감사)
      3-4. Fine-Grained Auditing (FGA)
      3-5. SYSDBA Auditing
      3-6. AUD$ / FGA_LOG$ 테이블스페이스 이동
================================================================================
*/


/* ============================================================================
   1. Lock
   ============================================================================
   - 여러 세션이 동시에 같은 데이터를 변경하지 못하도록 막는 것
   - DML 실행 시 수정 중인 row 단위로 잠금 (Do Not Escalate)
   - 수정 중인 행은 EXCLUSIVE LOCK, 테이블은 RX(Row Exclusive) LOCK
     → 다른 세션의 DDL만 차단
   - COMMIT 또는 ROLLBACK 시 락 자동 해제
   - SELECT는 락과 무관하게 항상 가능 (MVCC)
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. Lock 상태 확인 & Kill Session 실습
   -------------------------------------------------------------------------- */

-- hr 계정으로 접속
CONN hr/hr

-- 실습용 emp 테이블 생성 (CTAS)
CREATE TABLE emp AS SELECT * FROM employees;

/*
 [결과]
   Table created.
*/

-- [세션 1] 100번 사원 UPDATE → 락 발생
UPDATE emp SET salary = 10000 WHERE employee_id = 100;
-- COMMIT 하지 않은 상태로 유지

-- [세션 2] 동일한 행을 UPDATE 시도 → 세션 1이 COMMIT할 때까지 대기(블로킹)
UPDATE emp SET salary = 20000 WHERE employee_id = 100;

/*
 [결과]
   세션 2는 아무 응답 없이 대기 상태에 빠짐 (블로킹 발생)
*/

-- [SYS] 블로킹된 세션 조회
CONN / AS SYSDBA

SELECT s.sid,
       s.serial#,
       s.username,
       s.blocking_session,
       s.status
FROM   v$session s
WHERE  s.blocking_session IS NOT NULL;

/*
 [결과]
   SID   SERIAL#  USERNAME  BLOCKING_SESSION  STATUS
   ----  -------  --------  ----------------  ------
   25    60560    HR        366               ACTIVE   ← 세션 366이 세션 25를 블로킹 중
*/

-- 블로킹 유발한 세션 정보 조회
SELECT sid, serial#, username, status
FROM   v$session
WHERE  sid = 366;

/*
 [결과]
   SID   SERIAL#  USERNAME  STATUS
   ----  -------  --------  --------
   366   49668    HR        INACTIVE
*/

-- [SYS] Kill Session — 블로킹 유발한 세션 강제 종료
-- Kill Session은 비정상 종료이므로 해당 세션의 커밋되지 않은 트랜잭션은 자동 롤백
-- 형식: ALTER SYSTEM KILL SESSION 'sid,serial#' IMMEDIATE;
ALTER SYSTEM KILL SESSION '366,49668' IMMEDIATE;

/*
 [결과]
   System altered.
   → 세션 366 강제 종료 → 자동 ROLLBACK 발생 (비정상 종료이므로)
   → 세션 25의 대기 풀림, 세션 25의 UPDATE 실행 가능해짐
*/


/* --------------------------------------------------------------------------
   1-2. Deadlock 실습
   --------------------------------------------------------------------------
   - Deadlock: 두 트랜잭션이 서로의 락을 기다리며 무한 대기하는 상태
   - 오라클이 한쪽 트랜잭션을 자동 ROLLBACK하여 해결
   -------------------------------------------------------------------------- */

CONN hr/hr

-- [세션 1] 100번 사원 UPDATE → 100번 행에 락 걸림
UPDATE emp SET salary = 10000 WHERE employee_id = 100;

-- [세션 2] 101번 사원 UPDATE → 101번 행에 락 걸림
UPDATE emp SET salary = 20000 WHERE employee_id = 101;

-- [세션 1] 101번 사원 UPDATE 시도 → 세션 2가 잡고 있어서 대기
UPDATE emp SET salary = 30000 WHERE employee_id = 101;

-- [세션 2] 100번 사원 UPDATE 시도 → 세션 1이 잡고 있어서 대기
UPDATE emp SET salary = 40000 WHERE employee_id = 100;

/*
 [결과]
   ORA-00060: deadlock detected while waiting for resource
   → 오라클이 세션 중 하나를 자동 ROLLBACK하여 데드락 해제
   → ROLLBACK된 세션에서 에러 발생, 나머지 세션은 계속 진행 가능
*/


/* ============================================================================
   2. Undo Data
   ============================================================================
   - DML(INSERT, UPDATE, DELETE) 실행 시 변경 전 데이터(Before Image)를 저장한 것
   - 용도: 트랜잭션 롤백 / 읽기 일관성(Read Consistency) / Flashback 지원
   - 최소한 트랜잭션이 끝날 때까지 보관되며, 커밋 후에도 일정 시간 유지

   Undo 데이터 상태
     Active   : 현재 진행 중인 트랜잭션의 Undo. 덮어쓸 수 없음
     Unexpired: 트랜잭션은 끝났지만 undo_retention 시간이 아직 남은 것.
                공간 부족 시 덮어쓸 수 있음
     Expired  : undo_retention 시간이 지나 만료된 것. 가장 먼저 재사용됨
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. Undo 관련 파라미터 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- Undo 관련 파라미터 확인
SHOW PARAMETER undo

/*
 [결과]
   NAME                   TYPE    VALUE
   ---------------------  ------  --------
   undo_management        string  AUTO        ← 오라클이 자동 관리
   undo_retention         integer 900         ← 커밋 후 최소 900초(15분) 유지 노력
   undo_tablespace        string  UNDOTBS1    ← 현재 사용 중인 Undo 테이블스페이스
*/

-- Undo 세그먼트 상태 확인
SELECT segment_name, status, tablespace_name
FROM   dba_rollback_segs;

/*
 [결과]
   SEGMENT_NAME    STATUS  TABLESPACE_NAME
   --------------  ------  ---------------
   SYSTEM          ONLINE  SYSTEM
   _SYSSMU1_...    ONLINE  UNDOTBS1
   _SYSSMU2_...    ONLINE  UNDOTBS1
   _SYSSMU3_...    ONLINE  UNDOTBS1
   ...
*/


/* --------------------------------------------------------------------------
   2-2. Retention Guarantee 설정
   --------------------------------------------------------------------------
   - UNDO_RETENTION 시간 동안 Undo 데이터를 절대 덮어쓰지 않도록 보장
   - 공간이 부족해도 Unexpired Undo를 덮어쓰지 않음
   - ORA-01555(Snapshot Too Old) 방지 목적
   -------------------------------------------------------------------------- */

-- Retention Guarantee 설정
ALTER TABLESPACE undotbs1 RETENTION GUARANTEE;

-- 설정 확인
SELECT tablespace_name, retention
FROM   dba_tablespaces
WHERE  tablespace_name = 'UNDOTBS1';

/*
 [결과]
   TABLESPACE_NAME  RETENTION
   ---------------  ---------
   UNDOTBS1         GUARANTEE   ← Retention Guarantee 적용 확인
*/

-- Retention Guarantee 해제
ALTER TABLESPACE undotbs1 RETENTION NOGUARANTEE;

-- 해제 확인
SELECT tablespace_name, retention
FROM   dba_tablespaces
WHERE  tablespace_name = 'UNDOTBS1';

/*
 [결과]
   TABLESPACE_NAME  RETENTION
   ---------------  ---------
   UNDOTBS1         NOGUARANTEE   ← NOGUARANTEE로 전환 확인
*/


/* --------------------------------------------------------------------------
   2-3. Undo 테이블스페이스 추가 & 전환
   --------------------------------------------------------------------------
   - 인스턴스 하나는 Undo 테이블스페이스 하나만 ONLINE 상태에서 사용
   - Undo 테이블스페이스에는 일반 테이블 생성 불가 (트랜잭션 복구 전용 공간)
   -------------------------------------------------------------------------- */

-- 새 Undo 테이블스페이스 생성
CREATE UNDO TABLESPACE undotbs2
DATAFILE '/u01/app/oracle/oradata/ORCL/undotbs02.dbf' SIZE 200M
AUTOEXTEND ON NEXT 50M MAXSIZE UNLIMITED;

/*
 [결과]
   Tablespace created.
*/

-- 사용 중인 Undo 테이블스페이스 전환
ALTER SYSTEM SET undo_tablespace = undotbs2;

/*
 [결과]
   System altered.
*/

-- 전환 확인
SHOW PARAMETER undo_tablespace;

/*
 [결과]
   NAME             TYPE    VALUE
   ---------------  ------  --------
   undo_tablespace  string  UNDOTBS2   ← undotbs2로 전환 확인
*/


/* ============================================================================
   3. 감사 (Audit)
   ============================================================================
   - 누가, 언제, 어떤 작업을 했는지 기록하는 기능
   - 의심스러운 활동 탐지, 보안 규정 준수(Compliance) 목적으로 사용
   - 감사 로그는 테이블에 저장되므로 디스크 공간이 불어날 수 있음
     → SYSTEM/SYSAUX 보호를 위해 감사 전용 테이블스페이스를 따로 두는 것이 권장됨

   감사 동작 순서
     DBA가 감사 활성화
       → AUDIT 명령으로 감사 대상 지정
         → 사용자가 명령 실행
           → 감사 로그 생성
             → DBA가 로그 확인 (DBA_AUDIT_TRAIL / OS 파일 / XML 파일)
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. Audit Trail 저장 위치 설정
   --------------------------------------------------------------------------
   저장 위치 종류
     DB : AUD$ 테이블에 저장. SQL문까지 상세히 기록. 관리하기 가장 좋음 (기본값)
     OS : 운영체제 파일로 저장
     XML: XML 파일로 저장, V$XML_AUDIT_TRAIL 뷰로 조회
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- 현재 audit_trail 파라미터 확인 (정적 파라미터 → 변경 시 재시작 필요)
SHOW PARAMETER audit_trail

/*
 [결과]
   NAME         TYPE    VALUE
   -----------  ------  -----
   audit_trail  string  DB    ← DB 내 AUD$ 테이블에 저장 (기본값)
*/

-- OS 파일로 변경 (재시작 필요)
ALTER SYSTEM SET audit_trail = OS SCOPE = SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;

-- 변경 확인
SHOW PARAMETER audit_trail

/*
 [결과]
   NAME         TYPE    VALUE
   -----------  ------  -----
   audit_trail  string  OS    ← OS 파일로 변경 확인
*/

-- 실습을 위해 다시 DB로 되돌림 (재시작 필요)
ALTER SYSTEM SET audit_trail = DB SCOPE = SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;


/* --------------------------------------------------------------------------
   3-2. Standard Audit (표준 감사)
   --------------------------------------------------------------------------
   - '누가 언제 어떤 테이블에 무슨 작업을 했다'는 사실만 기록
   - 변경된 값(Before/After)은 알 수 없음
   - 반드시 NOAUDIT으로 해제해야 함 (해제 안 하면 로그가 계속 쌓임)
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- SYSDBA 감사 로그 파일 경로 확인
SHOW PARAMETER audit_file_dest

/*
 [결과]
   NAME             TYPE    VALUE
   ---------------  ------  ------------------------------------------
   audit_file_dest  string  /u01/app/oracle/admin/orcl/adump
*/

-- hr.employees 테이블에 대한 모든 DML 감사 활성화
AUDIT INSERT, UPDATE, DELETE ON hr.employees BY ACCESS;

/*
 [결과]
   Audit succeeded.
*/

-- 특정 계정의 테이블 접근 감사
AUDIT TABLE BY hr BY ACCESS;

/*
 [결과]
   Audit succeeded.
*/

-- 테스트 — hr 계정에서 UPDATE
CONN hr/hr
UPDATE employees SET salary = 10000 WHERE employee_id = 100;
COMMIT;
ROLLBACK;

-- 감사 로그 확인
CONN / AS SYSDBA
SELECT os_username, username, action_name, obj_name, timestamp
FROM   dba_audit_trail
ORDER  BY timestamp DESC;

/*
 [결과]
   OS_USERNAME  USERNAME  ACTION_NAME  OBJ_NAME   TIMESTAMP
   -----------  --------  -----------  ---------  ---------
   oracle       HR        UPDATE       EMPLOYEES  ...
   oracle       HR        INSERT       EMPLOYEES  ...
   → Standard Audit는 '누가 와서 뭐했다'는 사실만 기록 (변경된 값은 알 수 없음)
*/

-- 감사 해제 (반드시 해제해야 함 — 해제 안 하면 로그가 계속 쌓임)
NOAUDIT INSERT, UPDATE, DELETE ON hr.employees;
NOAUDIT TABLE BY hr;

/*
 [결과]
   Noaudit succeeded.
*/


/* --------------------------------------------------------------------------
   3-3. Value-Based Auditing (값 기반 감사)
   --------------------------------------------------------------------------
   - Standard Audit은 '누가 뭐했다'만 기록하지만,
     값 기반 감사는 변경 전/후 값까지 기록
   - 트리거(Trigger)를 이용해 구현
   -------------------------------------------------------------------------- */

-- STEP 1: 감사 로그를 저장할 테이블 생성
CONN / AS SYSDBA

CREATE TABLE sys.audit_emp_log (
    log_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    changed_by  VARCHAR2(50),
    change_time DATE,
    emp_id      NUMBER,
    old_salary  NUMBER,
    new_salary  NUMBER
);

/*
 [결과]
   Table created.
*/

-- STEP 2: hr 계정에 감사 전용 테이블 INSERT 권한 부여
GRANT INSERT ON sys.audit_emp_log TO hr;

/*
 [결과]
   Grant succeeded.
*/

-- STEP 3: hr.emp 변경 시 로그를 기록하는 트리거 생성
CREATE OR REPLACE TRIGGER hr.trg_audit_salary
AFTER UPDATE OF salary ON hr.emp
FOR EACH ROW
BEGIN
    INSERT INTO sys.audit_emp_log
        (changed_by, change_time, emp_id, old_salary, new_salary)
    VALUES
        (SYS_CONTEXT('USERENV','SESSION_USER'),
         SYSDATE,
         :OLD.employee_id,
         :OLD.salary,
         :NEW.salary);
END;
/

/*
 [결과]
   Trigger created.
*/

-- STEP 4: 테스트 — hr 계정에서 salary 변경
CONN hr/hr
UPDATE emp SET salary = 99999 WHERE employee_id = 100;
COMMIT;

/*
 [결과]
   1 row updated.
   Commit complete.
*/

-- STEP 5: 감사 로그 확인 (변경 전/후 값 확인 가능)
CONN / AS SYSDBA
SELECT * FROM sys.audit_emp_log;

/*
 [결과]
   LOG_ID  CHANGED_BY  CHANGE_TIME  EMP_ID  OLD_SALARY  NEW_SALARY
   ------  ----------  -----------  ------  ----------  ----------
   1       HR          ...          100     24000       99999       ← 변경 전/후 값 확인
*/


/* --------------------------------------------------------------------------
   3-4. Fine-Grained Auditing (FGA, 세분화 감사)
   --------------------------------------------------------------------------
   - 특정 조건에 맞는 데이터에 접근했을 때만 감사 로그를 남기는 방식
   - DBMS_FGA 패키지를 사용
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- FGA 정책 생성 — 부서번호 50번 사원 데이터에 접근할 때만 감사
BEGIN
    DBMS_FGA.ADD_POLICY(
        object_schema   => 'HR',
        object_name     => 'EMP',
        policy_name     => 'EMP_FGA',
        audit_condition => 'DEPARTMENT_ID = 50',   -- 조건: 부서 50번
        audit_column    => 'SALARY'                -- 감사 대상 컬럼
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- 정책 생성 확인
SELECT policy_name, object_schema, object_name, enabled
FROM   dba_audit_policies
WHERE  object_schema = 'HR'
AND    object_name   = 'EMP';

/*
 [결과]
   POLICY_NAME  OBJECT_SCHEMA  OBJECT_NAME  ENABLED
   -----------  -------------  -----------  -------
   EMP_FGA      HR             EMP          YES     ← 정책 생성 및 활성화 확인
*/

-- 테스트 — 부서 50번 사원 조회
CONN hr/hr
SELECT employee_id, salary FROM emp WHERE department_id = 50;

/*
 [결과]
   EMPLOYEE_ID  SALARY
   -----------  ------
   ...          ...    (부서 50번 사원 목록 출력)
*/

-- FGA 감사 로그 확인
CONN / AS SYSDBA
SELECT db_user, object_name, sql_text, timestamp
FROM   dba_fga_audit_trail
WHERE  policy_name = 'EMP_FGA';

/*
 [결과]
   DB_USER  OBJECT_NAME  SQL_TEXT                                               TIMESTAMP
   -------  -----------  -----------------------------------------------------  ---------
   HR       EMP          SELECT employee_id, salary FROM emp WHERE ...          ...
   → 부서 50번 데이터(SALARY 컬럼)에 접근한 쿼리만 기록됨
*/

-- FGA 정책 비활성화
BEGIN
    DBMS_FGA.DISABLE_POLICY(
        object_schema => 'HR',
        object_name   => 'EMP',
        policy_name   => 'EMP_FGA'
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- FGA 정책 활성화
BEGIN
    DBMS_FGA.ENABLE_POLICY(
        object_schema => 'HR',
        object_name   => 'EMP',
        policy_name   => 'EMP_FGA'
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- FGA 정책 삭제
BEGIN
    DBMS_FGA.DROP_POLICY(
        object_schema => 'HR',
        object_name   => 'EMP',
        policy_name   => 'EMP_FGA'
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/


/* --------------------------------------------------------------------------
   3-5. SYSDBA Auditing
   --------------------------------------------------------------------------
   - SYS 계정 접속은 일반 audit_trail이 아닌 OS 파일에 별도 기록
   - DB가 내려가 있어도 기록 가능
   - audit_sys_operations 파라미터로 제어 (정적 파라미터 → 재시작 필요)
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- audit_sys_operations 파라미터 확인
SHOW PARAMETER audit_sys_operations

/*
 [결과]
   NAME                   TYPE     VALUE
   ---------------------  -------  -----
   audit_sys_operations   boolean  TRUE   ← SYS 권한으로 실행된 모든 SQL을 OS 감사 로그에 기록
*/

-- FALSE인 경우 SYSDBA 감사 활성화 (재시작 필요)
ALTER SYSTEM SET audit_sys_operations = TRUE SCOPE = SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;

/*
 [SYS 로그인 감사 파일 확인] — 터미널에서 실행
   # audit_file_dest 경로에 파일 자동 생성됨
   ls -l /u01/app/oracle/admin/orcl/adump/

   # 최신 감사 파일 내용 확인
   tail -f /u01/app/oracle/admin/orcl/adump/<최신파일명>.aud

   [결과]
     ...
     ACTION : 'CONNECT'
     DATABASE USER: '/ AS SYSDBA'
     PRIVILEGE : SYSDBA
     CLIENT USER: oracle
     CLIENT TERMINAL: pts/0
     STATUS: 0
     ...
     → SYS 접속 기록이 OS 파일에 저장됨
*/

-- 사용 후 해제 (재시작 필요)
ALTER SYSTEM SET audit_sys_operations = FALSE SCOPE = SPFILE;


/* --------------------------------------------------------------------------
   3-6. AUD$ / FGA_LOG$ 테이블스페이스 이동
   --------------------------------------------------------------------------
   - 감사 로그 테이블이 SYSTEM 테이블스페이스에 저장되면 공간을 압박할 수 있음
   - 별도의 감사 전용 테이블스페이스로 이동하는 것이 권장됨
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- AUD$, FGA_LOG$ 테이블의 현재 위치 확인
SELECT table_name, tablespace_name
FROM   dba_tables
WHERE  table_name IN ('AUD$', 'FGA_LOG$')
AND    owner = 'SYS';

/*
 [결과]
   TABLE_NAME  TABLESPACE_NAME
   ----------  ---------------
   AUD$        SYSTEM          ← 기본 저장 위치
   FGA_LOG$    SYSTEM          ← 기본 저장 위치
*/

-- 감사 전용 테이블스페이스 생성
CREATE TABLESPACE audit_tbs
DATAFILE '/u01/app/oracle/oradata/ORCL/audit_tbs01.dbf' SIZE 200M
AUTOEXTEND ON NEXT 50M MAXSIZE UNLIMITED;

/*
 [결과]
   Tablespace created.
*/

-- AUD$ 테이블스페이스 이동
BEGIN
    DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,
        audit_trail_location_value => 'AUDIT_TBS'
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- FGA_LOG$ 테이블스페이스 이동
BEGIN
    DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
        audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_FGA_STD,
        audit_trail_location_value => 'AUDIT_TBS'
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- 이동 확인
SELECT table_name, tablespace_name
FROM   dba_tables
WHERE  table_name IN ('AUD$', 'FGA_LOG$')
AND    owner = 'SYS';

/*
 [결과]
   TABLE_NAME  TABLESPACE_NAME
   ----------  ---------------
   AUD$        AUDIT_TBS       ← AUDIT_TBS로 이동 완료
   FGA_LOG$    AUDIT_TBS       ← AUDIT_TBS로 이동 완료
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                   핵심 포인트
   ---------------------- ---------------------------------------------------
   Lock                   행 단위 잠금. COMMIT/ROLLBACK 시 해제
   Kill Session           ALTER SYSTEM KILL SESSION 'sid,serial#' IMMEDIATE
                          → 비정상 종료이므로 미커밋 트랜잭션 자동 ROLLBACK
   Deadlock               두 세션이 서로의 락을 기다리는 상태
                          → 오라클이 한쪽 트랜잭션 자동 ROLLBACK으로 해결
   Undo Data              변경 전 데이터(Before Image) 보관
                          → 롤백 / 읽기 일관성 / Flashback 지원
   undo_retention         커밋 후 Undo 유지 시간(초, 기본 900)
   Retention Guarantee    ALTER TABLESPACE ... RETENTION GUARANTEE
                          → Unexpired Undo 덮어쓰기 방지, ORA-01555 예방
   Standard Audit         AUDIT 명령. '누가 뭐했다' 사실만 기록
                          → 반드시 NOAUDIT으로 해제
   Value-Based Audit      트리거 기반. 변경 전/후 값까지 기록 가능
   FGA                    DBMS_FGA 패키지. 조건에 맞는 데이터 접근 시에만 감사
   SYSDBA Auditing        audit_sys_operations = TRUE. OS 파일에 별도 기록
   AUD$/FGA_LOG$ 이동     DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION
                          → 감사 전용 테이블스페이스로 이동 권장

   감사 뷰 정리
   뷰 이름                  설명
   ----------------------  --------------------------------------------------
   DBA_AUDIT_TRAIL         로그인, DDL, DML 등 표준 감사 로그
   DBA_FGA_AUDIT_TRAIL     Fine-Grained Auditing 로그
   DBA_COMMON_AUDIT_TRAIL  표준 + FGA 로그 통합 조회
   AUD$                    표준 감사 로그 원본 테이블
   FGA_LOG$                FGA 로그 원본 테이블

   ============================================================================ */
