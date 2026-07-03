/*
================================================================================
  Backup & Recovery 실습 08 — Archive Log Mode 데이터파일 손상 복구 시나리오
================================================================================
  Blog  : https://nsylove97.tistory.com/68
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7
  DB          Oracle Database 19c (ARCHIVELOG, orcl)
  접속 툴       SQL*Plus
  아카이브 경로   /home/oracle/arch1, /home/oracle/arch2
  백업 경로     /home/oracle/backup/open_bkp/
  실행 계정     oracle (OS), SYSDBA (DB)
  -------------------------------------------------------------------------

  전제 조건
  -------------------------------------------------------------------------
  - DB가 ARCHIVELOG 모드로 운영 중인 상태에서 시작
  - /home/oracle/backup/open_bkp/ 에 Online Backup이 사전 완료되어 있음
    (system01.dbf, sysaux01.dbf, undotbs01.dbf, users01.dbf 포함)
  - BNR 실습 07 완료 후 환경 기준
  - HR 계정이 활성화되어 있고 employees 테이블이 존재하는 상태
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. 사전 환경 확인
  2. 시나리오 2-1 — 운영(OPEN) 중 데이터파일 손상 복구 (단일 리두 적용)
     2-1. 사전 확인 및 테스트 데이터 생성
     2-2. 장애 발생
     2-3. 손상 파일 offline
     2-4. 백업 파일 restore
     2-5. 리두 적용 및 온라인 전환
  3. 시나리오 2-2 — 운영(OPEN) 중 데이터파일 손상 복구 (AUTO 리두 적용)
     3-1. 백업 파일 restore
     3-2. RECOVER + AUTO 리두 적용
     3-3. 온라인 전환
  4. 시나리오 3 — DB 종료 후 단일 데이터파일 손상 복구
     4-1. 장애 발생
     4-2. 손상 파일 offline 및 OPEN
     4-3. 백업 파일 restore
     4-4. 리두 적용 및 온라인 전환
  5. 시나리오 4-1 — DB 종료 후 다중 데이터파일 손상 복구
     5-1. 사전 데이터 변경
     5-2. 장애 발생
     5-3. 손상 파일 offline 및 OPEN
     5-4. 백업 파일 restore
     5-5. 리두 적용 및 온라인 전환
  6. 시나리오 4-2 — SYSTEM 데이터파일 손상 복구 (MOUNT 상태)
     6-1. 사전 데이터 변경 및 로그 스위치
     6-2. 장애 발생
     6-3. 백업 파일 restore
     6-4. 리두 적용
     6-5. 데이터베이스 오픈
  7. 관련 뷰 정리
  8. 주요 명령어 정리
  9. 실습 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. 사전 환경 확인
   ========================================================================== */

/* --------------------------------------------------------------------------
   1-1. 데이터파일 체크포인트 및 백업 상태 확인
   --------------------------------------------------------------------------
   항목                설명
   -----------------   ---------------------------------------------------
   v$datafile          데이터파일별 SCN, 상태 정보
   v$backup            BEGIN/END BACKUP 여부(ACTIVE/NOT ACTIVE)
   본 실습은 07편에서 받아 둔 Online Backup(open_bkp)이
   /u01/app/oracle/oradata/ORCL/ 원본과 별도로 존재하는 상태를 전제로 한다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 현재 아카이브 로그 강제 생성 후 데이터파일 상태 확인
ALTER SYSTEM ARCHIVE LOG CURRENT;

SELECT a.file#, a.name, a.checkpoint_change#, b.status, b.change#,
       TO_CHAR(b.time, 'yyyy-mm-dd hh24:mi:ss.sssss') time
  FROM v$datafile a, v$backup b
 WHERE a.file# = b.file#;

/*
 [결과 예시]
   FILE#  NAME                                         CHECKPOINT_CHANGE#  STATUS      CHANGE#   TIME
   -----  -------------------------------------------- ------------------  ----------  --------  -------------------------
   1      /u01/app/oracle/oradata/ORCL/system01.dbf     2426581             NOT ACTIVE  2424496   2025-05-09 15:24:18.55458
   3      /u01/app/oracle/oradata/ORCL/sysaux01.dbf     2426581             NOT ACTIVE  2424496   2025-05-09 15:24:18.55458
   4      /u01/app/oracle/oradata/ORCL/undotbs01.dbf    2426581             NOT ACTIVE  2424496   2025-05-09 15:24:18.55458
   7      /u01/app/oracle/oradata/ORCL/users01.dbf      2426581             NOT ACTIVE  2424496   2025-05-09 15:24:18.55458
   -> STATUS=NOT ACTIVE 이므로 BEGIN BACKUP이 걸려 있지 않은 정상 상태
   -> CHECKPOINT_CHANGE#, CHANGE#, TIME 값은 환경에 따라 다를 수 있음
*/


/* ==========================================================================
   2. 시나리오 2-1 — 운영(OPEN) 중 데이터파일 손상 복구 (단일 리두 적용)
   ========================================================================== */

/* --------------------------------------------------------------------------
   2-1. 사전 확인 및 테스트 데이터 생성
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 테스트 테이블 생성 및 데이터 입력
CREATE TABLE hr.emp7(id NUMBER) TABLESPACE users;
INSERT INTO hr.emp7 VALUES(100);
COMMIT;

SELECT * FROM hr.emp7;

/*
 [결과 예시]
   ID
   ----------
   100
*/

-- [SQL*Plus — SYSDBA] 테스트 테이블이 속한 데이터파일 확인
SELECT f.file_name
  FROM dba_extents e, dba_data_files f
 WHERE e.file_id = f.file_id
   AND e.segment_name = 'EMP7'
   AND e.owner = 'HR';

/*
 [결과 예시]
   FILE_NAME
   --------------------------------------------------------------------------------
   /u01/app/oracle/oradata/ORCL/users01.dbf
   -> USERS 테이블스페이스가 이번 장애 실습의 대상이 됨
*/

/* --------------------------------------------------------------------------
   2-2. 장애 발생
   -------------------------------------------------------------------------- */

/*
   # [oracle 계정 — Linux 셸] users01.dbf 강제 삭제로 장애 상황 재현
   rm /u01/app/oracle/oradata/ORCL/users01.dbf
*/

-- [SQL*Plus — SYSDBA] 손상 상태에서 신규 오브젝트 생성 시도 → 즉시 에러 발생
CREATE TABLE hr.emp8 TABLESPACE users AS SELECT * FROM hr.employees;

/*
 [결과 예시]
   ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'
   ORA-01116: error in opening database file 7
   ORA-27041: unable to open file
   Linux-x86_64 Error: 2: No such file or directory
   -> 데이터파일 실체가 없어 파일 오픈 자체가 실패
*/

/* --------------------------------------------------------------------------
   2-3. 손상 파일 offline
   --------------------------------------------------------------------------
   OFFLINE 옵션          설명
   -------------------   ---------------------------------------------------
   NORMAL                체크포인트를 발생시킨 뒤 offline (기본값)
   TEMPORARY             가능하면 체크포인트 발생, 안 되면 그대로 진행
   IMMEDIATE             체크포인트 없이 즉시 offline
   손상된 파일이 이미 깨진 상태이므로 ALTER TABLESPACE ... OFFLINE 시도 시
   세션 연결이 끊길 수 있다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 손상 테이블스페이스 offline 시도
ALTER TABLESPACE users OFFLINE IMMEDIATE;

/*
 [결과 예시 — 세션 단절]
   ERROR:
   ORA-03114: not connected to ORACLE
   ORA-03135: connection lost contact
   -> 데이터파일이 이미 손상된 상태에서 OFFLINE을 시도하면 인스턴스 세션이 끊길 수 있음
*/

-- [SQL*Plus — SYSDBA] 재접속 후 인스턴스 재기동
CONN / AS SYSDBA
STARTUP

/*
 [결과 예시]
   ORA-01157: cannot identify/lock data file 7 - see DBWR trace file
   ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'
   -> STARTUP이 자동으로 OPEN까지 진행되지 못하고 MOUNT 상태에서 정지
*/

-- [SQL*Plus — SYSDBA] 복구 대상 파일 목록 확인
SELECT * FROM v$recover_file;

/*
 [결과 예시]
   FILE#  ONLINE  ONLINE_  ERROR             CHANGE#  TIME
   -----  ------  -------  ----------------  -------  ----
   7      ONLINE  ONLINE   FILE NOT FOUND    0
   -> file#=7(users01.dbf)이 복구 대상으로 표시됨
*/

-- [SQL*Plus — SYSDBA] DB가 MOUNT 상태이므로 ALTER DATABASE로 해당 파일만 offline
ALTER DATABASE DATAFILE 7 OFFLINE;
ALTER DATABASE OPEN;

/*
 [결과 예시]
   Database altered.
   Database altered.
   -> 손상 파일만 OFFLINE 처리하면 나머지 테이블스페이스는 정상 OPEN 가능
*/

-- [SQL*Plus — SYSDBA] 손상 파일 제외 나머지 테이블스페이스 상태 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/ORCL/system01.dbf      3382302             SYSTEM
   2      UNDOTBS1  /u01/app/oracle/oradata/ORCL/undotbs01.dbf     3382302             ONLINE
   3      SYSAUX    /u01/app/oracle/oradata/ORCL/sysaux01.dbf      3382302             ONLINE
   7      USERS     /u01/app/oracle/oradata/ORCL/users01.dbf       3383221             RECOVER
   -> USERS만 STATUS=RECOVER로 표시되어 복구 대상임을 알 수 있음
*/

/* --------------------------------------------------------------------------
   2-4. 백업 파일 restore
   -------------------------------------------------------------------------- */

/*
   # [oracle 계정 — Linux 셸] Online Backup 파일을 원래 경로로 복사
   cp -v /home/oracle/backup/open_bkp/users01.dbf /u01/app/oracle/oradata/ORCL/
*/

/*
 [결과 예시]
   '/home/oracle/backup/open_bkp/users01.dbf' -> '/u01/app/oracle/oradata/ORCL/users01.dbf'
*/

/* --------------------------------------------------------------------------
   2-5. 백업 이후 변경정보(리두) 적용 및 온라인 전환
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 테이블스페이스 단위 미디어 복구 수행
RECOVER TABLESPACE users;

/*
 [결과 예시]
   Media recovery complete.
   -> 백업 이후 발생한 변경분(리두)이 자동 적용되어 복구 완료
*/

-- [SQL*Plus — SYSDBA] 복구 완료된 테이블스페이스 온라인 전환
ALTER TABLESPACE users ONLINE;

/*
 [결과 예시]
   Tablespace altered.
*/

-- [SQL*Plus — SYSDBA] 복구 결과 최종 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/ORCL/system01.dbf      3382302             SYSTEM
   2      UNDOTBS1  /u01/app/oracle/oradata/ORCL/undotbs01.dbf     3382302             ONLINE
   3      SYSAUX    /u01/app/oracle/oradata/ORCL/sysaux01.dbf      3382302             ONLINE
   7      USERS     /u01/app/oracle/oradata/ORCL/users01.dbf       3383221             ONLINE
   -> 모든 테이블스페이스가 ONLINE 상태로 복원됨
*/


/* ==========================================================================
   3. 시나리오 2-2 — 운영(OPEN) 중 데이터파일 손상 복구 (AUTO 리두 적용)
   ========================================================================== */

/* --------------------------------------------------------------------------
   3-1. 백업 파일 restore
   --------------------------------------------------------------------------
   동일한 장애 상황을 재현하되, 이번에는 RECOVER 시 적용해야 할
   아카이브 로그가 다수 발생한 경우를 다룬다.
-------------------------------------------------------------------------- */

/*
   # [oracle 계정 — Linux 셸] Online Backup 파일 재복사
   cp -v /home/oracle/backup/open_bkp/users01.dbf /u01/app/oracle/oradata/ORCL/
*/

/*
 [결과 예시]
   '/home/oracle/backup/open_bkp/users01.dbf' -> '/u01/app/oracle/oradata/ORCL/users01.dbf'
*/

/* --------------------------------------------------------------------------
   3-2. RECOVER + AUTO 리두 적용
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 테이블스페이스 단위 미디어 복구 — 다수 아카이브 로그 적용
RECOVER TABLESPACE users;

/*
 [결과 예시 — 아카이브 로그가 여러 개 필요한 경우]
   ORA-00279: change 2424496 generated at 05/09/2025 15:24:18 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/0001_0000000013_1200585133.arc
   ORA-00280: change 2424496 for thread 1 is in sequence #13
   Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
   auto
   ORA-00279: change 2424875 generated at 05/09/2025 15:30:55 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/0001_0000000014_1200585133.arc
   ORA-00280: change 2424875 for thread 1 is in sequence #14
   ORA-00279: change 2425017 generated at 05/09/2025 15:32:01 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/0001_0000000015_1200585133.arc
   ORA-00280: change 2425017 for thread 1 is in sequence #15
   ORA-00279: change 2425115 generated at 05/09/2025 15:32:01 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/0001_0000000016_1200585133.arc
   ORA-00280: change 2425115 for thread 1 is in sequence #16
   ORA-00279: change 2425216 generated at 05/09/2025 15:32:07 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/0001_0000000017_1200585133.arc
   ORA-00280: change 2425216 for thread 1 is in sequence #17
   ORA-00279: change 2425311 generated at 05/09/2025 15:32:10 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/0001_0000000018_1200585133.arc
   ORA-00280: change 2425311 for thread 1 is in sequence #18
   Log applied.
   Media recovery complete.
   -> 첫 요청에서 auto 입력 시 이후 필요한 아카이브 로그를 순차 자동 적용
   -> 적용할 로그가 한두 개뿐이면 파일명을 직접 입력해도 무방하나,
      다수인 경우 auto가 훨씬 효율적임
*/

/* --------------------------------------------------------------------------
   3-3. 온라인 전환
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 복구된 테이블스페이스 온라인 전환 및 데이터 확인
ALTER TABLESPACE users ONLINE;
SELECT * FROM hr.emp6;

/*
 [결과 예시]
   Tablespace altered.
   -> 이후 SELECT 결과는 실습 시점에 존재하는 데이터에 따라 달라질 수 있음
*/


/* ==========================================================================
   4. 시나리오 3 — DB 종료 후 단일 데이터파일 손상 복구
   ========================================================================== */

/* --------------------------------------------------------------------------
   4-1. 장애 발생
   --------------------------------------------------------------------------
   이번에는 DB가 정상 종료된 상태에서 데이터파일이 삭제된 경우를 다룬다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 인스턴스 정상 종료
SHUTDOWN IMMEDIATE

/*
   # [oracle 계정 — Linux 셸] users01.dbf 삭제로 장애 재현
   ls /u01/app/oracle/oradata/ORCL/users01.dbf
   rm /u01/app/oracle/oradata/ORCL/users01.dbf
   ls /u01/app/oracle/oradata/ORCL/users01.dbf
*/

/*
 [결과 예시]
   ls: cannot access /u01/app/oracle/oradata/orcl/users01.dbf: No such file or directory
*/

-- [SQL*Plus — SYSDBA] 인스턴스 기동 시도 → MOUNT 상태에서 정지
STARTUP

/*
 [결과 예시]
   ORA-01157: cannot identify/lock data file 7 - see DBWR trace file
   ORA-01110: data file 7: '/u01/app/oracle/oradata/orcl/users01.dbf'
*/

-- [SQL*Plus — SYSDBA] 복구 대상 파일 확인
SELECT * FROM v$recover_file;

/*
 [결과 예시]
   FILE#  ONLINE  ONLINE_  ERROR             CHANGE#  TIME
   -----  ------  -------  ----------------  -------  ----
   7      ONLINE  ONLINE   FILE NOT FOUND    0
*/

/* --------------------------------------------------------------------------
   4-2. 손상 파일 offline 및 OPEN
   --------------------------------------------------------------------------
   DB가 MOUNT 상태이므로 ALTER DATABASE DATAFILE로 offline 처리한다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 손상 데이터파일 offline (파일 번호 또는 경로로 지정 가능)
ALTER DATABASE DATAFILE 7 OFFLINE;
-- 또는
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/orcl/users01.dbf' OFFLINE;

/*
 [결과 예시]
   Database altered.
*/

-- [SQL*Plus — SYSDBA] 데이터파일 상태 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/orcl/system01.dbf      3384241             SYSTEM
   2      UNDOTBS1  /u01/app/oracle/oradata/orcl/undotbs01.dbf     3384241             ONLINE
   3      SYSAUX    /u01/app/oracle/oradata/orcl/sysaux01.dbf      3384241             ONLINE
   7      USERS     /u01/app/oracle/oradata/orcl/users01.dbf       3384241             OFFLINE
   -> 손상 파일을 OFFLINE 처리하면 나머지 테이블스페이스는 그대로 OPEN 가능
*/

-- [SQL*Plus — SYSDBA] 나머지 테이블스페이스를 우선 OPEN
ALTER DATABASE OPEN;

/*
 [결과 예시]
   Database altered.
*/

/* --------------------------------------------------------------------------
   4-3. 백업 파일 restore
   -------------------------------------------------------------------------- */

/*
   # [oracle 계정 — Linux 셸] 백업 파일 restore
   cp -v /home/oracle/backup/open_bkp/users01.dbf /u01/app/oracle/oradata/orcl/
*/

/*
 [결과 예시]
   '/home/oracle/backup/open_bkp/users01.dbf' -> '/u01/app/oracle/oradata/orcl/users01.dbf'
*/

/* --------------------------------------------------------------------------
   4-4. 백업 이후 변경정보(리두) 적용 및 온라인 전환
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 데이터파일 단위 미디어 복구 (파일 번호 / 경로 / 테이블스페이스 단위 모두 가능)
RECOVER DATAFILE 7;
-- 또는
RECOVER DATAFILE '/u01/app/oracle/oradata/orcl/users01.dbf';
-- 또는
RECOVER TABLESPACE users;

/*
 [결과 예시]
   Media recovery complete.
*/

-- [SQL*Plus — SYSDBA] 복구된 데이터파일 온라인 전환
ALTER DATABASE DATAFILE 7 ONLINE;
-- 또는
ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/orcl/users01.dbf' ONLINE;
-- 또는
ALTER TABLESPACE users ONLINE;

/*
 [결과 예시]
   Database altered.
*/

-- [SQL*Plus — SYSDBA] 복구 결과 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/orcl/system01.dbf      3384244             SYSTEM
   2      UNDOTBS1  /u01/app/oracle/oradata/orcl/undotbs01.dbf     3384244             ONLINE
   3      SYSAUX    /u01/app/oracle/oradata/orcl/sysaux01.dbf      3384244             ONLINE
   7      USERS     /u01/app/oracle/oradata/orcl/users01.dbf       3385032             ONLINE
*/

-- [SQL*Plus — SYSDBA] 복구 완료 후 아카이브 로그 재생성
ALTER SYSTEM ARCHIVE LOG CURRENT;

/*
 [결과 예시]
   System altered.
*/


/* ==========================================================================
   5. 시나리오 4-1 — DB 종료 후 다중 데이터파일 손상 복구
   ========================================================================== */

/* --------------------------------------------------------------------------
   5-1. 사전 데이터 변경
   --------------------------------------------------------------------------
   USERS, SYSAUX 두 개의 데이터파일이 동시에 손상된 경우를 다룬다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 테스트용 데이터 변경
UPDATE hr.employees SET salary=7777 WHERE employee_id=102;
COMMIT;

SELECT salary FROM hr.employees WHERE employee_id=102;

/*
 [결과 예시]
   SALARY
   ----------
   7777
*/

-- [SQL*Plus — SYSDBA] 대상 테이블의 테이블스페이스 확인
SELECT table_name, tablespace_name
  FROM dba_tables
 WHERE owner='HR' AND table_name='EMPLOYEES';

/*
 [결과 예시]
   TABLE_NAME   TABLESPACE_NAME
   -----------  ---------------
   EMPLOYEES    SYSAUX
   -> 대상 파일: users01.dbf, sysaux01.dbf
*/

/* --------------------------------------------------------------------------
   5-2. 장애 발생
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 인스턴스 정상 종료
SHUTDOWN IMMEDIATE

/*
   # [oracle 계정 — Linux 셸] 데이터파일 두 개 동시 삭제
   rm /u01/app/oracle/oradata/ORCL/users01.dbf
   rm /u01/app/oracle/oradata/ORCL/sysaux01.dbf
*/

-- [SQL*Plus — SYSDBA] 인스턴스 기동 시도 → MOUNT 상태에서 정지
STARTUP

/*
 [결과 예시]
   ORA-01157: cannot identify/lock data file 3 - see DBWR trace file
   ORA-01110: data file 3: '/u01/app/oracle/oradata/orcl/sysaux01.dbf'
   -> Alert 로그에는 손상된 파일(3, 7)이 모두 기록됨
*/

-- [SQL*Plus — SYSDBA] 복구 대상 파일 확인
SELECT * FROM v$recover_file;

/*
 [결과 예시]
   FILE#  ONLINE  ONLINE_  ERROR             CHANGE#  TIME
   -----  ------  -------  ----------------  -------  ----
   3      ONLINE  ONLINE   FILE NOT FOUND    0
   7      ONLINE  ONLINE   FILE NOT FOUND    0
*/

/* --------------------------------------------------------------------------
   5-3. 손상 파일 offline 및 OPEN
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 손상된 데이터파일 모두 offline 처리
ALTER DATABASE DATAFILE 3 OFFLINE;
ALTER DATABASE DATAFILE 7 OFFLINE;

/*
 [결과 예시]
   Database altered.
   Database altered.
*/

-- [SQL*Plus — SYSDBA] 데이터파일 상태 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/ORCL/system01.dbf      2458850             SYSTEM
   3      SYSAUX    /u01/app/oracle/oradata/ORCL/sysaux01.dbf      2458850             OFFLINE
   4      UNDOTBS1  /u01/app/oracle/oradata/ORCL/undotbs01.dbf     2458850             ONLINE
   7      USERS     /u01/app/oracle/oradata/ORCL/users01.dbf       2458850             OFFLINE
*/

-- [SQL*Plus — SYSDBA] 나머지 테이블스페이스를 우선 OPEN
ALTER DATABASE OPEN;

/*
 [결과 예시]
   Database altered.
*/

/* --------------------------------------------------------------------------
   5-4. 백업 파일 restore
   --------------------------------------------------------------------------
   손상 파일 두 개를 한 번에 복사한다.
-------------------------------------------------------------------------- */

/*
   # [oracle 계정 — Linux 셸] 손상 파일 일괄 restore
   cp -v /home/oracle/backup/open_bkp/{sysaux01,users01}.dbf /u01/app/oracle/oradata/ORCL/
*/

/*
 [결과 예시]
   '/home/oracle/backup/open_bkp/sysaux01.dbf' -> '/u01/app/oracle/oradata/ORCL/sysaux01.dbf'
   '/home/oracle/backup/open_bkp/users01.dbf' -> '/u01/app/oracle/oradata/ORCL/users01.dbf'
*/

/* --------------------------------------------------------------------------
   5-5. 백업 이후 변경정보(리두) 적용 및 온라인 전환
   --------------------------------------------------------------------------
   데이터파일별로 RECOVER DATAFILE을 각각 수행한다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] SYSAUX(3번) 데이터파일 복구
RECOVER DATAFILE 3;

/*
 [결과 예시]
   ORA-00279: change 2356080 generated at 05/10/2025 19:36:51 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_31_1200525254.arc
   ORA-00280: change 2356080 for thread 1 is in sequence #31
   Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
   auto
   Log applied.
   Media recovery complete.
*/

-- [SQL*Plus — SYSDBA] USERS(7번) 데이터파일 복구
RECOVER DATAFILE 7;

/*
 [결과 예시]
   ORA-00279: change 2356080 generated at 05/10/2025 19:36:51 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_31_1200525254.arc
   ORA-00280: change 2356080 for thread 1 is in sequence #31
   Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
   auto
   Log applied.
   Media recovery complete.
*/

-- [SQL*Plus — SYSDBA] 복구된 데이터파일 온라인 전환
ALTER DATABASE DATAFILE 3 ONLINE;
ALTER DATABASE DATAFILE 7 ONLINE;

/*
 [결과 예시]
   Database altered.
   Database altered.
*/

-- [SQL*Plus — SYSDBA] 복구 결과 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/ORCL/system01.dbf      2458853             SYSTEM
   3      SYSAUX    /u01/app/oracle/oradata/ORCL/sysaux01.dbf      2459444             ONLINE
   4      UNDOTBS1  /u01/app/oracle/oradata/ORCL/undotbs01.dbf     2458853             ONLINE
   7      USERS     /u01/app/oracle/oradata/ORCL/users01.dbf       2459453             ONLINE
*/

-- [SQL*Plus — SYSDBA] 복구된 데이터가 정상 보존되었는지 확인
SELECT salary FROM hr.employees WHERE employee_id=102;

/*
 [결과 예시]
   SALARY
   ----------
   7777
*/

-- [SQL*Plus — SYSDBA] 복구 완료 후 아카이브 로그 재생성
ALTER SYSTEM ARCHIVE LOG CURRENT;

/*
 [결과 예시]
   System altered.
*/


/* ==========================================================================
   6. 시나리오 4-2 — SYSTEM 데이터파일 손상 복구 (MOUNT 상태)
   ========================================================================== */

/* --------------------------------------------------------------------------
   6-1. 사전 데이터 변경 및 로그 스위치
   --------------------------------------------------------------------------
   SYSTEM 테이블스페이스는 SYSAUX/UNDOTBS1/USERS와 달리 offline 전환이
   불가능하므로, 손상 시 MOUNT 상태에서 곧바로 복구를 진행해야 한다.
-------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 변경 전 값 확인
SELECT salary FROM hr.employees WHERE employee_id=102;

/*
 [결과 예시]
   SALARY
   ----------
   7777
*/

-- [SQL*Plus — SYSDBA] 테스트용 데이터 변경
UPDATE hr.employees SET salary=8888 WHERE employee_id=102;
COMMIT;

SELECT salary FROM hr.employees WHERE employee_id=102;

/*
 [결과 예시]
   SALARY
   ----------
   8888
*/

-- [SQL*Plus — SYSDBA] 로그 스위치를 여러 번 발생시켜 아카이브 로그 추가 생성
ALTER SYSTEM SWITCH LOGFILE;
/
/
/

/*
   # [oracle 계정 — Linux 셸] 생성된 아카이브 로그 확인
   ls -al /home/oracle/arch1 /home/oracle/arch2
*/

/* --------------------------------------------------------------------------
   6-2. 장애 발생
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 인스턴스 정상 종료
SHUTDOWN IMMEDIATE

/*
 [결과 예시]
   Database closed.
   Database dismounted.
   ORACLE instance shut down.
*/

/*
   # [oracle 계정 — Linux 셸] system01.dbf 강제 삭제로 장애 재현
   rm /u01/app/oracle/oradata/ORCL/system01.dbf
*/

-- [SQL*Plus — SYSDBA] 인스턴스 기동 시도 → MOUNT 상태에서 정지
STARTUP

/*
 [결과 예시]
   ORA-01157: cannot identify/lock data file 1 - see DBWR trace file
   ORA-01110: data file 1: '/u01/app/oracle/oradata/ORCL/system01.dbf'

   [Alert 로그 동일 확인]
   ORA-01110: data file 1: '/u01/app/oracle/oradata/ORCL/system01.dbf'
   ORA-01565: error in identifying file '/u01/app/oracle/oradata/ORCL/system01.dbf'
   ORA-27037: unable to obtain file status
   Linux-x86_64 Error: 2: No such file or directory
   Checker run found 1 new persistent data failures
*/

-- [SQL*Plus — SYSDBA] 복구 대상 파일 확인
SELECT * FROM v$recover_file;

/*
 [결과 예시]
   FILE#  ONLINE  ONLINE_  ERROR             CHANGE#  TIME
   -----  ------  -------  ----------------  -------  ----
   1      ONLINE  ONLINE   FILE NOT FOUND    0
*/

-- [SQL*Plus — SYSDBA] 현재 인스턴스 상태 확인
SELECT status FROM v$instance;

/*
 [결과 예시]
   STATUS
   ---------------
   MOUNTED
   -> SYSTEM 데이터파일은 OFFLINE이 불가능하므로 MOUNT 상태에서
      restore -> recover -> OPEN 순서로 바로 진행해야 함
*/

/* --------------------------------------------------------------------------
   6-3. 백업 파일 restore
   -------------------------------------------------------------------------- */

/*
   # [oracle 계정 — Linux 셸] system01.dbf 백업 파일 restore
   cp -v /home/oracle/backup/open_bkp/system01.dbf /u01/app/oracle/oradata/ORCL/
*/

/*
 [결과 예시]
   '/home/oracle/backup/open_bkp/system01.dbf' -> '/u01/app/oracle/oradata/ORCL/system01.dbf'
*/

/* --------------------------------------------------------------------------
   6-4. 백업 이후 변경정보(리두) 적용
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] SYSTEM(1번) 데이터파일 복구 — 다수 아카이브 로그는 auto로 진행
RECOVER DATAFILE 1;

/*
 [결과 예시]
   ORA-00279: change 2356080 generated at 05/10/2025 19:36:51 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_31_1200525254.arc
   ORA-00280: change 2356080 for thread 1 is in sequence #31
   Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
   auto
   ORA-00279: change 2356143 generated at 05/10/2025 19:38:50 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_32_1200525254.arc
   ORA-00280: change 2356143 for thread 1 is in sequence #32
   ORA-00279: change 2456244 generated at 05/10/2025 19:46:43 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_33_1200525254.arc
   ORA-00280: change 2456244 for thread 1 is in sequence #33
   ORA-00279: change 2457117 generated at 05/10/2025 19:49:01 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_34_1200525254.arc
   ORA-00280: change 2457117 for thread 1 is in sequence #34
   ORA-00279: change 2459505 generated at 05/10/2025 20:26:20 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_35_1200525254.arc
   ORA-00280: change 2459505 for thread 1 is in sequence #35
   ORA-00279: change 2463463 generated at 05/10/2025 21:20:30 needed for thread 1
   ORA-00289: suggestion : /home/oracle/arch2/arch_1_36_1200525254.arc
   ORA-00280: change 2463463 for thread 1 is in sequence #36
   Log applied.
   Media recovery complete.
*/

/* --------------------------------------------------------------------------
   6-5. 데이터베이스 오픈
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 복구 완료 후 데이터베이스 오픈
ALTER DATABASE OPEN;

/*
 [결과 예시]
   Database altered.
*/

-- [SQL*Plus — SYSDBA] 인스턴스 상태 확인
SELECT status FROM v$instance;

/*
 [결과 예시]
   STATUS
   ---------------
   OPEN
*/

-- [SQL*Plus — SYSDBA] 전체 데이터파일 상태 최종 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
  FROM v$datafile a, v$tablespace b
 WHERE a.ts# = b.ts#;

/*
 [결과 예시]
   FILE#  TBS_NAME  FILE_NAME                                     CHECKPOINT_CHANGE#  STATUS
   -----  --------  --------------------------------------------  ------------------  --------
   1      SYSTEM    /u01/app/oracle/oradata/ORCL/system01.dbf      2463719             SYSTEM
   3      SYSAUX    /u01/app/oracle/oradata/ORCL/sysaux01.dbf      2463719             ONLINE
   4      UNDOTBS1  /u01/app/oracle/oradata/ORCL/undotbs01.dbf     2463719             ONLINE
   7      USERS     /u01/app/oracle/oradata/ORCL/users01.dbf       2463719             ONLINE
*/

-- [SQL*Plus — SYSDBA] 복구된 데이터가 보존되어 있는지 최종 확인
SELECT salary FROM hr.employees WHERE employee_id=102;

/*
 [결과 예시]
   SALARY
   ----------
   8888
   -> SYSTEM 데이터파일 손상 이전에 커밋된 변경사항이 정상적으로 복구됨
*/


/* ==========================================================================
   7. 관련 뷰 정리
   ==========================================================================

   뷰                   조회 목적
   ------------------   -----------------------------------------------------
   v$datafile           데이터파일별 SCN, 체크포인트, 상태(SYSTEM/ONLINE/OFFLINE/RECOVER) 확인
   v$tablespace          테이블스페이스와 데이터파일 조인용 기준 뷰
   v$backup              BEGIN/END BACKUP 진행 여부(ACTIVE/NOT ACTIVE) 확인
   v$recover_file        복구가 필요한 손상 데이터파일 목록 확인
   v$instance             인스턴스 현재 상태(MOUNTED/OPEN) 확인
   dba_extents            세그먼트(테이블)가 위치한 익스텐트·파일 확인
   dba_data_files         데이터파일과 파일 ID 매핑 정보 확인
   dba_tables             테이블이 속한 테이블스페이스 확인
   ========================================================================== */


/* ==========================================================================
   8. 주요 명령어 정리
   ==========================================================================

   명령어 패턴                                          설명
   ---------------------------------------------------  --------------------------------
   ALTER SYSTEM ARCHIVE LOG CURRENT;                     현재 리두 로그를 강제로 아카이빙
   ALTER TABLESPACE tbs OFFLINE [NORMAL|TEMPORARY|IMMEDIATE];
                                                          OPEN 상태에서 테이블스페이스 offline
   ALTER DATABASE DATAFILE n OFFLINE;                    MOUNT 상태에서 개별 데이터파일 offline
   ALTER DATABASE OPEN;                                  손상 파일 offline 후 나머지로 DB open
   RECOVER TABLESPACE tbs;                               테이블스페이스 단위 미디어 복구
   RECOVER DATAFILE n;                                   데이터파일 단위 미디어 복구
   Specify log: ... auto                                 다수의 아카이브 로그를 순차 자동 적용
   ALTER TABLESPACE tbs ONLINE;                           복구 완료 후 테이블스페이스 online 전환
   ALTER DATABASE DATAFILE n ONLINE;                     복구 완료 후 개별 데이터파일 online 전환
   SHUTDOWN IMMEDIATE / STARTUP                           정상 종료 후 재기동 시나리오 재현
   ========================================================================== */


/* ==========================================================================
   9. 실습 핵심 요약
   ==========================================================================

   시나리오                              핵심 포인트
   ------------------------------------  ---------------------------------------------
   OPEN 중 데이터파일 손상                손상 파일만 OFFLINE 후 OPEN, restore, RECOVER, ONLINE 순으로 처리
   AUTO 리두 적용                        RECOVER 시 auto 입력으로 다수 아카이브 로그를 순차 자동 적용
   DB 종료 후 단일 파일 손상               MOUNT 상태에서 ALTER DATABASE DATAFILE OFFLINE 후 OPEN, 이후 복구
   DB 종료 후 다중 파일 손상               손상 파일 전체를 OFFLINE 처리한 뒤 일괄 restore, 파일별 RECOVER 수행
   SYSTEM 데이터파일 손상                 OFFLINE 불가 — MOUNT 상태에서 restore → recover → OPEN 순으로만 복구 가능
   ========================================================================== */
