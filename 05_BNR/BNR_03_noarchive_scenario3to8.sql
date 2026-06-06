/*
================================================================================
  Backup & Recovery 실습 03
  — 노아카이브 모드에서 백업 없는 TS, System/Undo 데이터파일 손상 복구 시나리오 (3~8)
================================================================================
  Blog  : https://nsylove97.tistory.com/59
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7.9 (VMware Virtual Machine)
  DB          Oracle Database 19c
  SID         orcl
  접속 툴       SQL*Plus, MobaXterm(SSH)
  실습 경로     /home/oracle/backup/
  실행 계정     oracle (OS), SYSDBA (DB), HR (DB)
  -------------------------------------------------------------------------

  전제 조건
  -------------------------------------------------------------------------
  - DB가 NOARCHIVELOG 모드로 운영 중인 상태에서 시작
  - /home/oracle/backup/noarch/ 에 Cold Backup이 사전 완료되어 있음
    (시나리오 5~8 에서 사용)
  - BNR 실습 02 완료 후 환경 기준
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. 시나리오 3 — 백업 없는 데이터파일 손상 (리두 정보 O)
     1-1. 테이블스페이스 및 테이블 생성
     1-2. 장애 발생
     1-3. OFFLINE DROP 처리
     1-4. CREATE DATAFILE → RECOVER → ONLINE
     1-5. 정리

  2. 시나리오 4 — 백업 없는 데이터파일 손상 (리두 정보 X)
     2-1. 테이블스페이스 생성 및 Redo 소거
     2-2. 장애 발생
     2-3. 복구 시도 → 실패 확인
     2-4. DB 재시작 후 DROP

  3. 시나리오 5 — SYSTEM 데이터파일 손상 (리두 정보 O)
     3-1. Cold Backup 수행 (사전 준비)
     3-2. 장애 발생 및 오류 확인
     3-3. MOUNT 상태에서 백업본 복원 및 복구
     3-4. ALTER DATABASE OPEN

  4. 시나리오 6 — SYSTEM 데이터파일 손상 (리두 정보 X)
     4-1. Redo 소거 후 장애 발생
     4-2. 백업본 복원 후 복구 시도 → 실패
     4-3. 불완전 복구 — 전체 Cold Backup 복원

  5. 시나리오 7 — UNDO 데이터파일 손상 (리두 정보 O)
     5-1. 사전 확인 — 롤백 세그먼트 및 활성 트랜잭션
     5-2. 장애 발생
     5-3. MOUNT 상태에서 백업본 복원 및 복구
     5-4. OPEN 후 트랜잭션 롤백 확인

  6. 시나리오 8 — UNDO 데이터파일 손상 (리두 정보 X)
     6-1. Redo 소거 후 장애 발생
     6-2. 복구 시도 → 실패
     6-3. OFFLINE DROP → DB OPEN (임시 서비스 유지)
     6-4. 새 Undo 테이블스페이스 생성 및 전환
     6-5. 손상된 Undo TS 삭제 — 방법 1 (바로 DROP)
     6-6. 손상된 Undo TS 삭제 — 방법 2 (_corrupted_rollback_segments)

  7. 관련 뷰 정리
  8. 주요 명령어 정리
  9. 실습 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. 시나리오 3 — 백업 없는 데이터파일 손상 (리두 정보 O)
   ==========================================================================
   개념
   -----------------------------------------------------------------------
   상황   | Cold Backup 이후 새로 생성한 테이블스페이스의 데이터파일이 손상됨
   원인   | 백업본 없음 → 복원할 파일이 없음
   대응   | ALTER DATABASE CREATE DATAFILE 로 빈 파일을 재생성한 뒤
          | Redo 정보를 적용해 완전 복구
   핵심   | No Archive 모드에서는 OFFLINE DROP 만 허용 (OFFLINE 단독 불가)
   -----------------------------------------------------------------------
*/

/* --- 1-1. 테이블스페이스 및 테이블 생성 ------------------------------------ */

-- [SYSDBA]
-- Cold Backup 이후 생성 → 백업본 없음
CREATE TABLESPACE tbs
  DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf' SIZE 10m;

-- 테이블 생성 및 데이터 입력
CREATE TABLE hr.emp1 (id NUMBER) TABLESPACE tbs;
INSERT INTO hr.emp1 VALUES (1);
COMMIT;

-- 현재 데이터파일 상태 및 checkpoint_change# 확인
-- tbs01.dbf 의 checkpoint_change# 가 다른 파일보다 높으면 정상
-- (데이터 변경이 발생했기 때문)
SELECT name, checkpoint_change#, status FROM v$datafile;

/* --- 1-2. 장애 발생 ------------------------------------------------------- */

-- [oracle — Linux]
-- ! rm /u01/app/oracle/oradata/ORCL/tbs01.dbf

/* --- 1-3. OFFLINE DROP 처리 ----------------------------------------------- */

/*
  No Archive 모드에서 데이터파일 offline 옵션
  -------------------------------------------------------------------------
  옵션               | 설명
  OFFLINE            | Archive 모드 전용 — No Archive 에서 사용 불가
  OFFLINE DROP       | No Archive 모드 전용 — 데이터파일을 offline 으로 전환
                     | 단, 컨트롤 파일에서 해당 파일의 복구 필요 여부만 표시됨
  -------------------------------------------------------------------------
*/

-- [SYSDBA]
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf' OFFLINE DROP;

-- offline 전환 후 STATUS = RECOVER 로 변경됨 확인
SELECT name, checkpoint_change#, status FROM v$datafile;
-- [결과 예시]
-- /u01/app/oracle/oradata/ORCL/tbs01.dbf    2813950    RECOVER

/* --- 1-4. CREATE DATAFILE → RECOVER → ONLINE ------------------------------ */

/*
  ALTER DATABASE CREATE DATAFILE 개념
  -------------------------------------------------------------------------
  - 백업본이 없는 데이터파일을 컨트롤 파일 정보(크기·속성) 기반으로 빈 파일 재생성
  - 이후 RECOVER DATAFILE 로 Redo 를 적용해 완전 복구 수행
  -------------------------------------------------------------------------
*/

-- [SYSDBA]
-- 컨트롤 파일 정보 기반으로 빈 파일 재생성
ALTER DATABASE CREATE DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf';

-- 물리적 파일 생성 확인
-- ! ls -l /u01/app/oracle/oradata/ORCL/tbs01.dbf

-- Redo 정보를 적용하여 복구
ALTER DATABASE RECOVER DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf';
-- [결과] Database altered.

-- 복구 후 STATUS 확인 → OFFLINE 상태
SELECT name, checkpoint_change#, status FROM v$datafile;
-- [결과 예시]
-- /u01/app/oracle/oradata/ORCL/tbs01.dbf    2815293    OFFLINE

-- 복구 완료 → ONLINE 전환 (서비스 복귀)
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf' ONLINE;

-- 데이터 정합성 확인
SELECT * FROM hr.emp1;
-- [결과]
-- ID
-- ----------
-- 1

/* --- 1-5. 정리 ------------------------------------------------------------ */

-- [SYSDBA]
DROP TABLESPACE tbs INCLUDING CONTENTS AND DATAFILES;


/* ==========================================================================
   2. 시나리오 4 — 백업 없는 데이터파일 손상 (리두 정보 X)
   ==========================================================================
   개념
   -----------------------------------------------------------------------
   상황   | 시나리오 3 과 동일하게 백업 없는 데이터파일 손상
   차이   | 로그 스위치를 여러 번 발생시켜 Redo 정보가 덮어쓰인 상태
   결과   | CREATE DATAFILE 로 재생성 후 RECOVER 를 시도해도 실패
          | 복구 불가 → 테이블스페이스 삭제로 정리
   -----------------------------------------------------------------------
*/

/* --- 2-1. 테이블스페이스 생성 및 Redo 소거 ---------------------------------- */

-- [SYSDBA]
CREATE TABLESPACE tbs
  DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf' SIZE 10m;

CREATE TABLE hr.emp1 TABLESPACE tbs
  AS SELECT * FROM hr.employees;

SELECT count(*) FROM hr.emp1;
-- [결과] COUNT(*) = 107

-- 로그 스위치 3회 → tbs01 관련 Redo 가 INACTIVE 그룹으로 덮어쓰임
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;

-- 로그 상태 확인 (tbs01 생성 관련 Redo 가 INACTIVE 상태여야 함)
SELECT group#, sequence#, status FROM v$log;

/* --- 2-2. 장애 발생 ------------------------------------------------------- */

-- [oracle — Linux]
-- ! rm /u01/app/oracle/oradata/ORCL/tbs01.dbf

/* --- 2-3. 복구 시도 → 실패 확인 ------------------------------------------- */

-- [SYSDBA]
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf' OFFLINE DROP;

-- 빈 파일 재생성
ALTER DATABASE CREATE DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf';

-- 복구 시도 → Redo 없어 실패
ALTER DATABASE RECOVER DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf';
-- [결과]
-- ORA-00279: change XXXXXXX generated at ... needed for thread 1
-- ORA-00289: suggestion : ...archivelog...
-- ORA-00280: change XXXXXXX for thread 1 is in sequence #X

-- ONLINE 전환도 불가
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/ORCL/tbs01.dbf' ONLINE;
-- [결과] ORA-01113: file N needs media recovery

-- 운영 중 DROP 도 불가
DROP TABLESPACE tbs INCLUDING CONTENTS AND DATAFILES;
-- [결과] ORA-01156: recovery or flashback in progress may need access to files

/* --- 2-4. DB 재시작 후 DROP ----------------------------------------------- */

-- [SYSDBA]
-- 재시작 후 DROP 가능 상태로 전환
SHUTDOWN IMMEDIATE;
STARTUP;

-- 상태 재확인 → RECOVER 상태 유지
SELECT name, checkpoint_change#, status FROM v$datafile;

-- 복구 불가 → 테이블스페이스 삭제로 마무리
DROP TABLESPACE tbs INCLUDING CONTENTS AND DATAFILES;
-- [결과] Tablespace dropped.


/* ==========================================================================
   3. 시나리오 5 — SYSTEM 데이터파일 손상 (리두 정보 O)
   ==========================================================================
   개념
   -----------------------------------------------------------------------
   상황   | SYSTEM 테이블스페이스 데이터파일 손상, Redo 정보 존재
   특징   | SYSTEM / 현재 사용 중인 UNDO / TEMP 데이터파일은 OFFLINE 변경 불가
          | → DB 가 OPEN 상태에서는 복구 불가
          | → MOUNT 상태에서만 복구 가능
   복구   | MOUNT 상태에서 백업본 복원 → RECOVER → ALTER DATABASE OPEN
   -----------------------------------------------------------------------
*/

/* --- 3-1. Cold Backup 수행 (사전 준비) ------------------------------------- */

-- [SYSDBA]
-- DB 종료
SHUTDOWN IMMEDIATE;

-- [oracle — Linux]
-- Cold Backup 수행
-- ! cd /u01/app/oracle/oradata/ORCL/
-- ! cp -v *.{ctl,log,dbf} /home/oracle/backup/noarch/

-- [SYSDBA]
-- pfile 백업
CREATE PFILE = '/home/oracle/backup/noarch/initorcl.ora' FROM SPFILE;

-- DB 기동
STARTUP;

/* --- 3-2. 장애 발생 및 오류 확인 ------------------------------------------ */

-- [oracle — Linux]
-- ! rm /u01/app/oracle/oradata/ORCL/system01.dbf

-- [SYSDBA]
-- CHECKPOINT 발생으로 즉시 오류 유발
ALTER SYSTEM CHECKPOINT;
-- [결과] ORA-03113: end-of-file on communication channel → 인스턴스 크래시

-- 재접속 후 STARTUP 시도 → MOUNT 에서 오류 발생
CONNECT / AS SYSDBA
STARTUP;
-- [결과]
-- Database mounted.
-- ORA-01157: cannot identify/lock data file 1 - see DBWR trace file
-- ORA-01110: data file 1: '/u01/app/oracle/oradata/ORCL/system01.dbf'

-- 복구 필요 파일 확인
SELECT * FROM v$recover_file;
-- [결과] FILE# = 1, ERROR = FILE NOT FOUND

/* --- 3-3. MOUNT 상태에서 백업본 복원 및 복구 -------------------------------- */

-- [oracle — Linux]
-- ! cp -v /home/oracle/backup/noarch/system01.dbf /u01/app/oracle/oradata/ORCL/

-- [SYSDBA] (MOUNT 상태)
-- Redo 정보를 적용하여 복구
RECOVER TABLESPACE system;
-- [결과] Media recovery complete.

/* --- 3-4. ALTER DATABASE OPEN ---------------------------------------------- */

-- [SYSDBA]
ALTER DATABASE OPEN;
-- [결과] Database altered.


/* ==========================================================================
   4. 시나리오 6 — SYSTEM 데이터파일 손상 (리두 정보 X)
   ==========================================================================
   개념
   -----------------------------------------------------------------------
   상황   | 시나리오 5 와 동일하게 SYSTEM 파일 손상
   차이   | 로그 스위치를 발생시켜 Redo 정보가 소거됨
   결과   | 완전 복구 불가 → Cold Backup 전체 복원 (불완전 복구)
   -----------------------------------------------------------------------
*/

/* --- 4-1. Redo 소거 후 장애 발생 ------------------------------------------ */

-- [SYSDBA]
-- Redo 덮어쓰기
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;

-- [oracle — Linux]
-- ! rm /u01/app/oracle/oradata/ORCL/system01.dbf

-- [SYSDBA]
ALTER SYSTEM CHECKPOINT;
-- [결과] System altered. (SYSTEM 파일 참조 전이라 바로 오류 미발생)

SHUTDOWN ABORT;
STARTUP;
-- [결과]
-- Database mounted.
-- ORA-01157: cannot identify/lock data file 1
-- ORA-01110: data file 1: '/u01/app/oracle/oradata/ORCL/system01.dbf'

/* --- 4-2. 백업본 복원 후 복구 시도 → 실패 ----------------------------------- */

-- [oracle — Linux]
-- ! cp -v /home/oracle/backup/noarch/system01.dbf /u01/app/oracle/oradata/ORCL/

-- [SYSDBA] (MOUNT 상태)
-- Redo 적용 시도
RECOVER DATAFILE 1;
-- [결과]
-- ORA-00279: change XXXXXXX ... needed for thread 1
-- ORA-00308: cannot open archived log '...'
-- → 아카이브 없음 → 완전 복구 실패

/* --- 4-3. 불완전 복구 — 전체 Cold Backup 복원 ------------------------------ */

-- [SYSDBA]
SHUTDOWN ABORT;

-- [oracle — Linux]
-- 전체 Cold Backup 복원
-- ! cp -v /home/oracle/backup/noarch/* /u01/app/oracle/oradata/ORCL/

-- [SYSDBA]
STARTUP;
-- [결과] Database opened.
-- → Cold Backup 시점으로 복원 완료 (이후 변경 내용 소실)


/* ==========================================================================
   5. 시나리오 7 — UNDO 데이터파일 손상 (리두 정보 O)
   ==========================================================================
   개념
   -----------------------------------------------------------------------
   상황   | UNDO 테이블스페이스 데이터파일 손상, Redo 정보 존재
   특징   | UNDO 파일은 OFFLINE 변경 불가 → MOUNT 상태에서 복구
   복구   | MOUNT 상태에서 백업본 복원 → RECOVER DATAFILE → OPEN
   추가   | DB OPEN 시점에 진행 중이던 미커밋 TX 는 자동 롤백됨
   -----------------------------------------------------------------------
*/

/* --- 5-1. 사전 확인 — 롤백 세그먼트 및 활성 트랜잭션 ----------------------- */

-- [SYSDBA]
-- 롤백 세그먼트 상태 확인
SELECT segment_id, segment_name, tablespace_name, status
FROM   dba_rollback_segs;

-- 트랜잭션 활성화 (장애 발생 전 미커밋 상태 유지)
SELECT salary FROM hr.employees WHERE employee_id = 100;
-- [결과] SALARY = 24000

UPDATE hr.employees SET salary = 30000 WHERE employee_id = 100;

SELECT salary FROM hr.employees WHERE employee_id = 100;
-- [결과] SALARY = 30000
-- → COMMIT 하지 않은 채로 유지

-- 활성 트랜잭션 확인 (복구 전 참조 목적)
SELECT s.username, s.sid, s.serial#, r.name,
       t.ubafil, t.xidusn, t.ubablk, t.used_ublk
FROM   v$session s,
       v$transaction t,
       v$rollname r
WHERE  s.taddr = t.addr
AND    t.xidusn = r.usn;

/* --- 5-2. 장애 발생 ------------------------------------------------------- */

-- [oracle — Linux]
-- ! rm /u01/app/oracle/oradata/ORCL/undotbs01.dbf

-- [SYSDBA]
ALTER SYSTEM CHECKPOINT;
-- [결과] ORA-03113: end-of-file on communication channel → 인스턴스 크래시

-- 재접속 후 STARTUP
CONNECT / AS SYSDBA
STARTUP;
-- [결과]
-- Database mounted.
-- ORA-01157: cannot identify/lock data file 4
-- ORA-01110: data file 4: '/u01/app/oracle/oradata/ORCL/undotbs01.dbf'

SELECT * FROM v$recover_file;
-- [결과] FILE# = 4, ERROR = FILE NOT FOUND

/* --- 5-3. MOUNT 상태에서 백업본 복원 및 복구 -------------------------------- */

-- [oracle — Linux]
-- ! cp -v /home/oracle/backup/noarch/undotbs01.dbf /u01/app/oracle/oradata/ORCL/

-- [SYSDBA] (MOUNT 상태)
-- 파일 번호 기준 복구 (undotbs01.dbf 는 FILE# 4)
-- FILE# 는 v$recover_file 에서 확인한 값으로 대체
RECOVER DATAFILE 4;
-- [결과] Media recovery complete.

ALTER DATABASE OPEN;
-- [결과] Database altered.

/* --- 5-4. OPEN 후 트랜잭션 롤백 확인 --------------------------------------- */

-- [SYSDBA]
-- 롤백 세그먼트 복구 확인
SELECT segment_id, segment_name, tablespace_name, status
FROM   dba_rollback_segs;
-- [결과] UNDOTBS1 세그먼트들 모두 ONLINE

-- 복구 시점에 진행 중이던 미커밋 TX 는 자동 롤백됨
SELECT salary FROM hr.employees WHERE employee_id = 100;
-- [결과] SALARY = 24000 (UPDATE 이전 값으로 복귀)


/* ==========================================================================
   6. 시나리오 8 — UNDO 데이터파일 손상 (리두 정보 X)
   ==========================================================================
   개념
   -----------------------------------------------------------------------
   상황   | Redo 정보가 소거된 상태에서 UNDO 파일 손상
   결과   | 완전 복구 불가
   대응   | 손상된 UNDO 파일을 OFFLINE DROP → DB OPEN
          | 새 Undo 테이블스페이스를 생성하여 서비스 유지
          | 손상된 구 Undo TS 를 DROP 으로 정리
   특이점 | NEEDS RECOVERY 세그먼트가 남아 DROP 이 안 되는 경우
          | _corrupted_rollback_segments 히든 파라미터로 강제 처리
   -----------------------------------------------------------------------
*/

/* --- 6-1. Redo 소거 후 장애 발생 ------------------------------------------ */

-- [SYSDBA]
-- 로그 스위치로 Redo 덮어쓰기
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;

-- [oracle — Linux]
-- ! rm /u01/app/oracle/oradata/ORCL/undotbs01.dbf

-- [SYSDBA]
SHUTDOWN ABORT;
STARTUP;
-- [결과]
-- Database mounted.
-- ORA-01157: cannot identify/lock data file 4
-- ORA-01110: data file 4: '/u01/app/oracle/oradata/ORCL/undotbs01.dbf'

/* --- 6-2. 복구 시도 → 실패 ------------------------------------------------ */

-- [oracle — Linux]
-- ! cp -v /home/oracle/backup/noarch/undotbs01.dbf /u01/app/oracle/oradata/ORCL/

-- [SYSDBA] (MOUNT 상태)
RECOVER TABLESPACE undotbs1;
-- [결과]
-- ORA-00279: change XXXXXXX ... needed for thread 1
-- ORA-00308: cannot open archived log '...'
-- → 완전 복구 실패

/* --- 6-3. OFFLINE DROP → DB OPEN (임시 서비스 유지) ----------------------- */

/*
  No Archive 모드 UNDO 파일 처리 흐름
  -------------------------------------------------------------------------
  - 완전 복구 불가 → 손상된 UNDO 파일을 OFFLINE DROP 으로 제거
  - 이후 DB 를 OPEN 해 서비스를 유지하면서 새 Undo TS 구성
  -------------------------------------------------------------------------
*/

-- [SYSDBA] (MOUNT 상태)
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/ORCL/undotbs01.dbf' OFFLINE DROP;

ALTER DATABASE OPEN;
-- [결과] Database altered.

-- 롤백 세그먼트 상태 확인
SELECT segment_id, segment_name, tablespace_name, status
FROM   dba_rollback_segs;
-- [결과] UNDOTBS1 세그먼트들 → NEEDS RECOVERY 또는 OFFLINE 상태

/* --- 6-4. 새 Undo 테이블스페이스 생성 및 전환 ------------------------------ */

-- [SYSDBA]
-- 새 Undo 테이블스페이스 생성
CREATE UNDO TABLESPACE undo1
  DATAFILE '/u01/app/oracle/oradata/ORCL/undo01.dbf' SIZE 100m AUTOEXTEND ON;

-- Undo 테이블스페이스 전환
ALTER SYSTEM SET undo_tablespace = undo1;

-- 전환 확인
SHOW PARAMETER undo_tablespace;
-- [결과]
-- NAME               TYPE    VALUE
-- -----------------  ------  ------
-- undo_tablespace    string  UNDO1

-- 새 롤백 세그먼트 ONLINE 확인
SELECT segment_id, segment_name, tablespace_name, status
FROM   dba_rollback_segs;
-- [결과]
-- UNDO1    세그먼트들 → ONLINE
-- UNDOTBS1 세그먼트들 → OFFLINE / NEEDS RECOVERY

/* --- 6-5. 손상된 Undo TS 삭제 — 방법 1 (바로 DROP) ------------------------ */

/*
  방법 1 적용 조건
  -------------------------------------------------------------------------
  - NEEDS RECOVERY 상태의 롤백 세그먼트가 없는 경우
  - 아래 명령으로 바로 DROP 가능
  -------------------------------------------------------------------------
*/

-- [SYSDBA]
DROP TABLESPACE undotbs1 INCLUDING CONTENTS AND DATAFILES;
-- [결과] Tablespace dropped. (방법 1 성공 시 6-6 생략 가능)

-- ORA-01548 발생 시 → NEEDS RECOVERY 세그먼트가 남아 있음 → 방법 2 로 진행

/* --- 6-6. 손상된 Undo TS 삭제 — 방법 2 (_corrupted_rollback_segments) ------ */

/*
  _corrupted_rollback_segments 개념
  -------------------------------------------------------------------------
  - 지정된 롤백 세그먼트의 복구를 강제로 포기시키는 히든 파라미터
  - 세그먼트 이름은 반드시 작은따옴표로 감싸야 함
  - 데이터 정합성을 깨뜨릴 수 있어 pfile 에만 임시 적용
  - DROP 완료 후 반드시 spfile 로 복귀해야 함
  -------------------------------------------------------------------------
*/

-- [SYSDBA]
-- 1단계: NEEDS RECOVERY 세그먼트 이름 확인
SELECT segment_id, segment_name, tablespace_name, status
FROM   dba_rollback_segs
WHERE  status IN ('NEEDS RECOVERY', 'OFFLINE');

-- 2단계: pfile 생성 후 DB 종료
CREATE PFILE FROM SPFILE;
SHUTDOWN IMMEDIATE;

-- [oracle — Linux]
-- 3단계: pfile 에 히든 파라미터 추가
-- vi $ORACLE_HOME/dbs/initorcl.ora
--
-- 아래 형식으로 추가 (세그먼트 이름은 위 조회 결과로 대체):
-- _corrupted_rollback_segments=('_SYSSMU1_1261223759$','_SYSSMU2_27624015$', ...)
--
-- ※ 세그먼트 이름은 환경마다 다름 → 반드시 실제 조회 결과로 작성

-- [SYSDBA]
-- 4단계: 수정된 pfile 로 DB 재기동
STARTUP PFILE = '/u01/app/oracle/product/19c/dbhome_1/dbs/initorcl.ora';
-- [결과] Database opened.

-- 5단계: DROP 재시도 (오라클이 해당 세그먼트 복구를 포기했으므로 DROP 가능)
DROP TABLESPACE undotbs1 INCLUDING CONTENTS AND DATAFILES;
-- [결과] Tablespace dropped.

-- 6단계: 뒷정리 — spfile 로 정상 기동
-- _corrupted_rollback_segments 는 DROP 달성 후 반드시 제거해야 함
SHUTDOWN IMMEDIATE;
STARTUP;
-- → spfile 기준으로 기동 (_corrupted_rollback_segments 효과 제거)

-- 새 Undo TS 확인
SHOW PARAMETER undo_tablespace;
-- [결과]
-- NAME               TYPE    VALUE
-- -----------------  ------  ------
-- undo_tablespace    string  UNDO1


/* ==========================================================================
   7. 관련 뷰 정리
   ==========================================================================
   뷰 / 객체              | 조회 목적
   -----------------------------------------------------------------------
   v$datafile             | 파일별 checkpoint_change# 및 STATUS 확인
   v$recover_file         | 복구 필요 파일 목록 및 오류 유형 확인
   v$log                  | 리두 로그 그룹별 sequence#, STATUS 확인
   dba_rollback_segs      | 롤백 세그먼트 상태 확인
                          | (ONLINE / OFFLINE / NEEDS RECOVERY)
   v$session              | 활성 세션 확인 (트랜잭션 조회 시 v$transaction 조인)
   v$transaction          | 활성 트랜잭션 정보 확인 (ubafil, xidusn 등)
   v$rollname             | 롤백 세그먼트 이름 확인
   -----------------------------------------------------------------------
*/

-- 데이터파일 상태 확인
SELECT name, checkpoint_change#, status FROM v$datafile;

-- 복구 필요 파일 확인
SELECT * FROM v$recover_file;

-- 리두 로그 상태 확인
SELECT group#, sequence#, status FROM v$log;

-- 롤백 세그먼트 상태 확인
SELECT segment_id, segment_name, tablespace_name, status
FROM   dba_rollback_segs;

-- 활성 트랜잭션 확인
SELECT s.username, s.sid, s.serial#, r.name,
       t.ubafil, t.xidusn, t.ubablk, t.used_ublk
FROM   v$session s,
       v$transaction t,
       v$rollname r
WHERE  s.taddr = t.addr
AND    t.xidusn = r.usn;


/* ==========================================================================
   8. 주요 명령어 정리
   ==========================================================================
   명령어                                           | 설명
   -----------------------------------------------------------------------
   ALTER DATABASE DATAFILE '...' OFFLINE DROP       | No Archive 모드 전용
                                                    | 데이터파일 offline 처리
   ALTER DATABASE CREATE DATAFILE '...'             | 백업 없는 파일을 컨트롤 파일
                                                    | 정보 기반으로 빈 파일 재생성
   ALTER DATABASE RECOVER DATAFILE '...'            | 재생성된 빈 파일에 Redo 적용
   RECOVER DATAFILE n                               | 파일 번호 기준 미디어 복구
   RECOVER TABLESPACE ts_name                       | 테이블스페이스 이름 기준 복구
   ALTER DATABASE DATAFILE '...' ONLINE             | 복구 후 서비스 복귀
   ALTER SYSTEM SWITCH LOGFILE                      | 리두 로그 강제 스위치
   ALTER SYSTEM CHECKPOINT                          | 강제 체크포인트 발생
   CREATE UNDO TABLESPACE undo1 DATAFILE '...'      | 새 Undo 테이블스페이스 생성
   ALTER SYSTEM SET undo_tablespace = undo1         | 활성 Undo TS 전환
   DROP TABLESPACE ts INCLUDING CONTENTS AND DATAFILES
                                                    | 테이블스페이스 및 데이터파일 삭제
   CREATE PFILE FROM SPFILE                         | spfile → pfile 변환
   STARTUP PFILE = '...'                            | 특정 pfile 로 DB 기동
   -----------------------------------------------------------------------
*/


/* ==========================================================================
   9. 실습 핵심 요약
   ==========================================================================
   주제                              | 핵심 포인트
   -----------------------------------------------------------------------
   No Archive 모드 offline           | OFFLINE DROP 사용
                                    | OFFLINE 단독 사용 불가
   SYSTEM / UNDO offline 불가        | OFFLINE 처리 없이 MOUNT 상태에서 직접 복구
   백업 없는 파일 복구 (Redo O)       | CREATE DATAFILE → RECOVER DATAFILE → ONLINE
                                    | 완전 복구 가능
   백업 없는 파일 복구 (Redo X)       | CREATE DATAFILE → RECOVER 실패
                                    | 재시작 후 DROP TABLESPACE 로 정리
   SYSTEM 손상 복구 (Redo O)          | restore → RECOVER TABLESPACE system → OPEN
   SYSTEM 손상 복구 (Redo X)          | restore → RECOVER 실패 → Cold Backup 전체 복원
                                    | (불완전 복구 — 이후 변경 소실)
   UNDO 손상 복구 (Redo O)           | restore → RECOVER DATAFILE n → OPEN
                                    | 미커밋 TX 자동 롤백됨
   UNDO 손상 복구 (Redo X)           | OFFLINE DROP → OPEN → 새 Undo TS 생성
                                    | undo_tablespace 전환 → 구 Undo TS DROP
   _corrupted_rollback_segments      | NEEDS RECOVERY 세그먼트가 남아 DROP 안 될 때 사용
                                    | pfile 임시 설정, 세그먼트 이름 작은따옴표 필수
                                    | DROP 완료 후 반드시 spfile 로 복귀
   -----------------------------------------------------------------------
*/
