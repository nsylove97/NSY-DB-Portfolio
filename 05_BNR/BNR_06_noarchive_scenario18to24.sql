/*
================================================================================
  Backup & Recovery 실습 06
  — 노아카이브 모드에서 컨트롤 파일·리두 로그 파일 손상 복구 시나리오 (18~24)
================================================================================
  Blog  : https://nsylove97.tistory.com/62
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7.9 (VMware Virtual Machine)
  DB          Oracle Database 19c
  SID         orcl
  접속 툴       SQL*Plus, MobaXterm(SSH)
  실습 경로     /home/oracle/backup/, /home/oracle/backup/noredo/
  실행 계정     oracle (OS), SYSDBA (DB), HR (DB)
  -------------------------------------------------------------------------

  전제 조건
  -------------------------------------------------------------------------
  - DB가 NOARCHIVELOG 모드로 운영 중인 상태에서 시작
  - /home/oracle/backup/noarch/ 에 Cold Backup이 사전 완료되어 있음
    (컨트롤 파일 + 데이터파일 + 리두 로그 파일 포함)
  - BNR 실습 05 완료 후 환경 기준
  - HR 계정이 활성화되어 있고 employees 테이블이 존재하는 상태
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. 시나리오 18 — 컨트롤 파일·데이터파일 전체 유실, 백업 이후 리두 없음, 비정상 종료
     1-1. 사전 상태 확인
     1-2. 데이터 변경 및 로그 스위치
     1-3. 장애 발생 — 컨트롤 파일·데이터파일 전체 삭제
     1-4. 다른 세션에서 장애 확인
     1-5. 복구 절차 — 인스턴스 강제 종료 → 백업 복원 → 불완전 복구
     1-6. 결과 확인

  2. 시나리오 19 — DB 정상 종료 후 리두 로그 파일·컨트롤 파일 손상 복구
     2-1. 사전 데이터 삽입 및 정상 종료
     2-2. 장애 발생 — 컨트롤 파일·리두 로그 파일 삭제
     2-3. 기동 실패 확인
     2-4. 복구 절차 — CREATE CONTROLFILE 재생성 스크립트
     2-5. 백업 갱신

  3. 시나리오 20 — 리두 로그 파일·컨트롤 파일 손상으로 DB 비정상 종료 복구
     3-1. 사전 상태 확인
     3-2. 데이터 변경 후 장애 발생 — 컨트롤 파일·리두 로그 삭제
     3-3. 다른 세션에서 장애 확인
     3-4. 복구 방법 1 — 컨트롤 파일·데이터파일만 복원 후 RESETLOGS
     3-5. 복구 방법 2 — 컨트롤 파일·데이터파일·리두 로그 전체 복원 후 STARTUP

  4. 시나리오 21 — 백업 컨트롤 파일과 현재 데이터파일 정보 불일치 복구
     4-1. SAMPLE 테이블스페이스 추가 후 정상 종료
     4-2. 장애 발생 — control01.ctl 삭제
     4-3. 백업 컨트롤 파일 복원 후 OPEN 시도 → 불일치 확인
     4-4. 리두 적용 시도 → UNNAMED 파일로 복구 중단
     4-5. 컨트롤 파일 재생성(NORESETLOGS) → OPEN
     4-6. TEMP 재연결 및 SAMPLE TS 삭제
     4-7. 원상 복구

  5. 시나리오 22 — DB 정상 종료 후 inactive 리두 로그 파일 삭제 복구
     5-1. 사전 상태 확인
     5-2. 장애 발생 — 정상 종료 후 INACTIVE redo02.log 삭제
     5-3. 기동 실패 확인
     5-4. 복구 절차 — MOUNT → CLEAR LOGFILE → OPEN
     5-5. 정리 — DROP 후 새 그룹 추가 (선택 사항)
     5-6. 원상 복구

  6. 시나리오 23 — inactive 리두 로그 파일 삭제 후 DB 비정상 종료 복구
     6-1. 사전 상태 확인
     6-2. 장애 발생 — INACTIVE redo02.log 삭제 후 SHUTDOWN ABORT
     6-3. 기동 실패 확인
     6-4. 복구 절차 — MOUNT → CLEAR LOGFILE → OPEN
     6-5. 원상 복구

  7. 시나리오 24 — current 리두 로그 파일 삭제 복구
     7-1. 사전 상태 확인
     7-2. 장애 발생 — CURRENT 그룹(group 1) 삭제
     7-3. 상태 재확인 — 삭제 후에도 STATUS는 CURRENT 유지
     7-4. CLEAR LOGFILE 시도 실패 (OPEN 상태)
     7-5. SHUTDOWN IMMEDIATE 후 STARTUP 실패
     7-6. 복구 절차 — STARTUP MOUNT 후 CLEAR LOGFILE
     7-7. 복구 결과 확인

  8. 주요 명령어 정리
  9. 실습 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. 시나리오 18 — 컨트롤 파일·데이터파일 전체 유실, 백업 이후 리두 없음, 비정상 종료
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 1-1. 사전 상태 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 리두 로그 상태 확인 (current 그룹 확인)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;

-- 데이터파일 및 테이블스페이스 상태 확인
SELECT a.file#, b.name tbs_name, a.name file_name,
       a.checkpoint_change#, a.status
FROM v$datafile a, v$tablespace b
WHERE a.ts# = b.ts#;

-- DB 상태 확인
SELECT name dbname, open_mode, log_mode, checkpoint_change#
FROM v$database;


-- --------------------------------------------------------------------------
-- 1-2. 데이터 변경 및 로그 스위치
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 백업 이후 신규 테이블 생성 및 데이터 변경
CREATE TABLE hr.emp6 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

UPDATE hr.emp6 SET salary = 10000;
-- 107 rows updated.
COMMIT;
-- Commit complete.

-- 로그 스위치 반복 (리두 정보를 백업 시점 이후로 이동)
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;


-- --------------------------------------------------------------------------
-- 1-3. 장애 발생 — 컨트롤 파일·데이터파일 전체 삭제
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 컨트롤 파일 및 데이터파일 전체 삭제
rm -rvf /u01/app/oracle/oradata/ORCL/*.{ctl,dbf}

-- 삭제 확인
ls /u01/app/oracle/oradata/ORCL/*.{ctl,dbf}
-- ls: cannot access ... *.ctl: No such file or directory
-- ls: cannot access ... *.dbf: No such file or directory
*/

-- [SQL*Plus — SYSDBA]
-- 현재 세션에서는 체크포인트 명령이 정상 수행됨
ALTER SYSTEM CHECKPOINT;
-- System altered.


-- --------------------------------------------------------------------------
-- 1-4. 다른 세션에서 장애 확인
-- --------------------------------------------------------------------------

-- [다른 세션, SQL*Plus — SYSDBA]
-- 컨트롤 파일이 열리지 않아 장애 확인 가능
SELECT * FROM v$database;
-- ORA-00210: cannot open the specified control file
-- ORA-00202: control file: '/u01/app/oracle/oradata/ORCL/control01.ctl'
-- ORA-27041: unable to open file

SELECT COUNT(*) FROM hr.employees;
-- ORA-01116: error in opening database file 3
-- ORA-01110: data file 3: '/u01/app/oracle/oradata/ORCL/sysaux01.dbf'


-- --------------------------------------------------------------------------
-- 1-5. 복구 절차 — 인스턴스 강제 종료 → 백업 복원 → 불완전 복구
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 인스턴스 강제 종료
SHUTDOWN ABORT;
-- ORACLE instance shut down.

/*
# [oracle 계정 — Linux]
-- 백업본으로 컨트롤 파일 + 데이터파일 복원 (리두 로그는 복원하지 않음)
cp -v /home/oracle/backup/noarch/*.{ctl,dbf} /u01/app/oracle/oradata/ORCL/
*/

-- [SQL*Plus — SYSDBA]
-- MOUNT 상태로 기동 후 불완전 복구 시도
STARTUP MOUNT;

RECOVER DATABASE USING BACKUP CONTROLFILE UNTIL CANCEL;
-- ORA-00279: change ... generated at ... needed for thread 1
-- ORA-00289: suggestion : /home/oracle/arch2/arch_1_5_xxxxxxxxxx.arc
-- ORA-00280: change ... for thread 1 is in sequence #5
--
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
CANCEL
-- Media recovery cancelled.

-- RESETLOGS 옵션으로 DB OPEN (불완전 복구 확정)
ALTER DATABASE OPEN RESETLOGS;
-- Database altered.


-- --------------------------------------------------------------------------
-- 1-6. 결과 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 백업 이후 생성한 테이블은 백업 시점으로 복구되어 존재하지 않음
SELECT * FROM hr.emp6;
-- ORA-00942: table or view does not exist

/*
  정리
  - 백업 이후 리두 정보가 없으므로 백업 시점으로 불완전 복구됨
  - hr.emp6 테이블은 백업 이후 생성되었으므로 복구 후 존재하지 않음
*/



/* ==========================================================================
   2. 시나리오 19 — DB 정상 종료 후 리두 로그 파일·컨트롤 파일 손상 복구
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 2-1. 사전 데이터 삽입 및 정상 종료
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
CREATE TABLE hr.emp7(id NUMBER) TABLESPACE users;
-- Table created.

INSERT INTO hr.emp7(id) VALUES(1);
COMMIT;
-- Commit complete.

-- DB 정상 종료 (체크포인트 완료, 리두에 미기록 변경분 없음)
SHUTDOWN IMMEDIATE;


-- --------------------------------------------------------------------------
-- 2-2. 장애 발생 — 컨트롤 파일·리두 로그 파일 삭제
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 삭제 전 파일 목록 확인
ls -l /u01/app/oracle/oradata/ORCL/*.{ctl,log}
-- control01.ctl
-- control02.ctl
-- redo01.log
-- redo02.log
-- redo03.log

-- 컨트롤 파일 및 리두 로그 파일 전체 삭제
rm -rvf /u01/app/oracle/oradata/ORCL/*.{ctl,log}
*/


-- --------------------------------------------------------------------------
-- 2-3. 기동 실패 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-00205: error in identifying control file, check alert log for more info

-- NOMOUNT 단계에서 막혀 인스턴스 긴급 종료
SHUTDOWN ABORT;


-- --------------------------------------------------------------------------
-- 2-4. 복구 절차 — CREATE CONTROLFILE 재생성 스크립트(cre.sql) 실행
-- --------------------------------------------------------------------------

/*
-- cre.sql 파일 작성 (vi /home/oracle/cre.sql)
-- ------------------------------------------------------------------------
STARTUP NOMOUNT
CREATE CONTROLFILE REUSE DATABASE "ORCL" RESETLOGS NOARCHIVELOG
    MAXLOGFILES 16
    MAXLOGMEMBERS 3
    MAXDATAFILES 100
    MAXINSTANCES 8
    MAXLOGHISTORY 292
LOGFILE
  GROUP 1 '/u01/app/oracle/oradata/ORCL/redo01.log' SIZE 50M BLOCKSIZE 512,
  GROUP 2 '/u01/app/oracle/oradata/ORCL/redo02.log' SIZE 50M BLOCKSIZE 512,
  GROUP 3 '/u01/app/oracle/oradata/ORCL/redo03.log' SIZE 50M BLOCKSIZE 512
DATAFILE
  '/u01/app/oracle/oradata/ORCL/system01.dbf',
  '/u01/app/oracle/oradata/ORCL/audit_tbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/sysaux01.dbf',
  '/u01/app/oracle/oradata/ORCL/undotbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/users01.dbf',
  '/u01/app/oracle/oradata/ORCL/userdata01.dbf'
CHARACTER SET AL32UTF8
;
-- ------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA]
-- cre.sql 실행 (NOMOUNT 기동 + 컨트롤 파일 재생성)
@cre
-- ORACLE instance started.
-- Control file created.

-- RESETLOGS 옵션으로 DB OPEN
ALTER DATABASE OPEN RESETLOGS;
-- Database altered.

-- TEMP 파일 재연결 (컨트롤 파일 재생성 시 TEMP는 자동 포함되지 않음)
ALTER TABLESPACE TEMP ADD TEMPFILE '/u01/app/oracle/oradata/ORCL/temp01.dbf' REUSE;
-- Tablespace altered.


-- --------------------------------------------------------------------------
-- 2-5. 백업 갱신
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
SHUTDOWN IMMEDIATE;

/*
# [oracle 계정 — Linux]
-- 재생성된 컨트롤 파일·리두 로그 포함하여 백업 갱신
cp -v /u01/app/oracle/oradata/ORCL/* /home/oracle/backup/noarch/
*/

/*
  정리
  - CREATE CONTROLFILE 로 컨트롤 파일을 처음부터 재생성
  - RESETLOGS 옵션으로 리두 로그 그룹도 새로 초기화
  - TEMP 테이블스페이스는 ADD TEMPFILE 로 재연결 필요
*/



/* ==========================================================================
   3. 시나리오 20 — 리두 로그 파일·컨트롤 파일 손상으로 DB 비정상 종료 복구
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 3-1. 사전 상태 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 리두 로그 상태 확인 (1번 그룹이 current)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 3-2. 데이터 변경 후 장애 발생 — 컨트롤 파일·리두 로그 삭제
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
CREATE TABLE hr.emp8 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

/*
# [oracle 계정 — Linux]
-- 컨트롤 파일 및 리두 로그 파일 전체 삭제
rm -rvf /u01/app/oracle/oradata/ORCL/*.{ctl,log}
*/

-- [SQL*Plus — SYSDBA]
-- 로그 스위치 시도 → 컨트롤 파일이 없어 비정상 종료 유발
ALTER SYSTEM SWITCH LOGFILE;
-- System altered.


-- --------------------------------------------------------------------------
-- 3-3. 다른 세션에서 장애 확인
-- --------------------------------------------------------------------------

/*
# [다른 세션, oracle 계정 — Linux]
sqlplus / as sysdba
-- Connected to an idle instance.
*/


-- --------------------------------------------------------------------------
-- 3-4. 복구 방법 1 — 컨트롤 파일·데이터파일만 복원 후 RESETLOGS
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 백업본에서 컨트롤 파일 + 데이터파일만 복원 (리두 로그 제외)
cp -v /home/oracle/backup/noarch/*.{ctl,dbf} /u01/app/oracle/oradata/ORCL/
*/

-- [SQL*Plus — SYSDBA]
STARTUP MOUNT;

RECOVER DATABASE USING BACKUP CONTROLFILE UNTIL CANCEL;
-- ORA-00279: change ... needed for thread 1, in sequence #19
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
CANCEL
-- Media recovery cancelled.

ALTER DATABASE OPEN RESETLOGS;
-- Database altered.

-- RESETLOGS 이후 리두 로그 상태 재확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 3-5. 복구 방법 2 — 컨트롤 파일·데이터파일·리두 로그 전체 복원 후 STARTUP
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 백업본에서 컨트롤 파일 + 데이터파일 + 리두 로그 전체 복원
cp -v /home/oracle/backup/noarch/*.{ctl,dbf,log} /u01/app/oracle/oradata/ORCL/
*/

-- [SQL*Plus — SYSDBA]
-- 리두 로그까지 백업 시점 상태이므로 일반 STARTUP으로 일관된 기동 가능
STARTUP;

/*
  정리
  - 복구 방법 1: RESETLOGS로 리두 로그를 초기화하는 불완전 복구
  - 복구 방법 2: 백업된 리두 로그까지 통째로 복원하는 방식
                  → 백업 시점으로의 일관된 복원 가능
*/



/* ==========================================================================
   4. 시나리오 21 — 백업 컨트롤 파일과 현재 데이터파일 정보 불일치 복구
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 4-1. SAMPLE 테이블스페이스 추가 후 정상 종료
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- SAMPLE 추가 전 데이터파일·테이블스페이스 상태 확인
SELECT a.file#, b.name tbs_name, a.name file_name,
       a.checkpoint_change#, a.status
FROM v$datafile a, v$tablespace b
WHERE a.ts# = b.ts#;

-- 새 테이블스페이스 생성 (백업 컨트롤 파일에는 없는 파일이 됨)
CREATE TABLESPACE sample
DATAFILE '/u01/app/oracle/oradata/ORCL/sample01.dbf' SIZE 50M;
-- Tablespace created.

-- SAMPLE 추가 후 데이터파일 상태 재확인
SELECT a.file#, b.name tbs_name, a.name file_name,
       a.checkpoint_change#, a.status
FROM v$datafile a, v$tablespace b
WHERE a.ts# = b.ts#;

-- DB 정상 종료
SHUTDOWN IMMEDIATE;


-- --------------------------------------------------------------------------
-- 4-2. 장애 발생 — control01.ctl 삭제
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
rm -rvf /u01/app/oracle/oradata/ORCL/control01.ctl
*/

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-00205: error in identifying control file, check alert log for more info

-- NOMOUNT 단계에서 막혀 인스턴스 긴급 종료
SHUTDOWN ABORT;


-- --------------------------------------------------------------------------
-- 4-3. 백업 컨트롤 파일 복원 후 OPEN 시도 → 불일치 확인
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 백업 컨트롤 파일만 복원 (SAMPLE 생성 이전 시점)
cp -v /home/oracle/backup/noarch/*.ctl /u01/app/oracle/oradata/ORCL/
*/

-- [SQL*Plus — SYSDBA]
-- MOUNT 기동 후 OPEN 시도
STARTUP MOUNT;

ALTER DATABASE OPEN;
-- ORA-01122: database file 1 failed verification check
-- ORA-01110: data file 1: '/u01/app/oracle/oradata/ORCL/system01.dbf'
-- ORA-01207: file is more recent than control file - old control file

-- 정리: 백업 컨트롤 파일에는 sample01.dbf 정보가 없어 불일치 발생


-- --------------------------------------------------------------------------
-- 4-4. 리두 적용 시도 → UNNAMED 파일로 복구 중단
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
RECOVER DATABASE USING BACKUP CONTROLFILE;
-- ORA-00279: change ... needed for thread 1
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
/u01/app/oracle/oradata/ORCL/redo01.log
-- ORA-01244: unnamed datafile(s) added to control file by media recovery
-- ORA-01110: data file 5: '/u01/app/oracle/oradata/ORCL/sample01.dbf'  ===> 새로 만든 TS
-- ORA-01112: media recovery not started

-- 정리: 백업 컨트롤파일이 모르는 파일(sample01.dbf)이 UNNAMED 파일로 등록되어 복구 중단


-- --------------------------------------------------------------------------
-- 4-5. 컨트롤 파일 재생성(NORESETLOGS) → OPEN
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

STARTUP NOMOUNT;

-- 기존 리두 로그를 그대로 유지(NORESETLOGS)하면서 컨트롤 파일 재생성
-- UNNAMED00005 위치에는 sample01.dbf 경로를 실제 경로로 수정하거나 생략 가능
CREATE CONTROLFILE REUSE DATABASE "ORCL" NORESETLOGS NOARCHIVELOG
    MAXLOGFILES 16
    MAXLOGMEMBERS 3
    MAXDATAFILES 100
    MAXINSTANCES 8
    MAXLOGHISTORY 292
LOGFILE
  GROUP 1 '/u01/app/oracle/oradata/ORCL/redo01.log' SIZE 50M BLOCKSIZE 512,
  GROUP 2 '/u01/app/oracle/oradata/ORCL/redo02.log' SIZE 50M BLOCKSIZE 512,
  GROUP 3 '/u01/app/oracle/oradata/ORCL/redo03.log' SIZE 50M BLOCKSIZE 512
DATAFILE
  '/u01/app/oracle/oradata/ORCL/system01.dbf',
  '/u01/app/oracle/oradata/ORCL/audit_tbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/sysaux01.dbf',
  '/u01/app/oracle/oradata/ORCL/undotbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/users01.dbf',
  '/u01/app/oracle/oradata/ORCL/userdata01.dbf',
  '/u01/app/oracle/product/19.3.0/dbhome_1/dbs/UNNAMED00005'
CHARACTER SET AL32UTF8
;


-- --------------------------------------------------------------------------
-- 4-6. TEMP 재연결 및 SAMPLE TS 삭제
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
ALTER DATABASE OPEN;

ALTER TABLESPACE TEMP ADD TEMPFILE '/u01/app/oracle/oradata/ORCL/temp01.dbf' REUSE;
-- Tablespace altered.

DROP TABLESPACE sample INCLUDING CONTENTS AND DATAFILES;
-- Tablespace dropped.


-- --------------------------------------------------------------------------
-- 4-7. 원상 복구
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 컨트롤 파일·데이터파일·리두 로그 전체를 백업본으로 원상 복구
cp -v /home/oracle/backup/noarch/*.{ctl,dbf,log} /u01/app/oracle/oradata/ORCL/
*/



/* ==========================================================================
   5. 시나리오 22 — DB 정상 종료 후 inactive 리두 로그 파일 삭제 복구
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 5-1. 사전 상태 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 리두 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 5-2. 장애 발생 — 정상 종료 후 INACTIVE redo02.log 삭제
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
SHUTDOWN IMMEDIATE;

/*
# [oracle 계정 — Linux]
-- INACTIVE 상태의 redo02.log 삭제
rm -rvf /u01/app/oracle/oradata/ORCL/redo02.log
*/


-- --------------------------------------------------------------------------
-- 5-3. 기동 실패 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-03113: end-of-file on communication channel
-- Process ID: nnnnn


-- --------------------------------------------------------------------------
-- 5-4. 복구 절차 — MOUNT → CLEAR LOGFILE → OPEN
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
CONN / AS SYSDBA
-- Connected to an idle instance.

STARTUP MOUNT;
-- Database mounted.

-- MOUNT 상태에서 리두 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;

-- 파일이 없는 그룹을 빈 파일로 재초기화
ALTER DATABASE CLEAR LOGFILE GROUP 2;
-- Database altered.

ALTER DATABASE OPEN;
-- Database altered.


-- --------------------------------------------------------------------------
-- 5-5. 정리 — DROP 후 새 그룹 추가 (선택 사항)
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
ALTER DATABASE DROP LOGFILE GROUP 2;
-- Database altered.

ALTER DATABASE ADD LOGFILE GROUP 4
'/u01/app/oracle/oradata/ORCL/redo04.log' SIZE 50M;
-- Database altered.

-- 최종 리두 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 5-6. 원상 복구
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- 변경된 구성을 백업본 기준으로 원상 복구
cp -v /home/oracle/backup/noarch/* /u01/app/oracle/oradata/ORCL/
*/

/*
  정리
  - CLEAR LOGFILE: 파일이 없는 리두 로그 그룹을 내용 없이 재초기화(빈 파일 재생성)
  - INACTIVE 상태 그룹은 CLEAR LOGFILE로 정리 후 DROP → ADD로 재구성 가능 (필수 X, 선택 사항)
*/



/* ==========================================================================
   6. 시나리오 23 — inactive 리두 로그 파일 삭제 후 DB 비정상 종료 복구
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 6-1. 사전 상태 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 리두 로그 상태 확인 (1번 그룹이 current)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 6-2. 장애 발생 — INACTIVE redo02.log 삭제 후 SHUTDOWN ABORT
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
rm -rvf /u01/app/oracle/oradata/ORCL/redo02.log
*/

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;
-- ORACLE instance shut down.


-- --------------------------------------------------------------------------
-- 6-3. 기동 실패 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-00313: open failed for members of log group 2 of thread 1
-- ORA-00312: online log 2 thread 1: '/u01/app/oracle/oradata/ORCL/redo02.log'
-- ORA-27037: unable to obtain file status


-- --------------------------------------------------------------------------
-- 6-4. 복구 절차 — MOUNT → CLEAR LOGFILE → OPEN
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- MOUNT 상태에서는 crash recovery가 불필요하여 CLEAR LOGFILE 허용
STARTUP MOUNT;

ALTER DATABASE CLEAR LOGFILE GROUP 2;
-- Database altered.

ALTER DATABASE OPEN;
-- Database altered.

-- 복구 후 리두 로그 상태 확인 (그룹 2가 current로 전환)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 6-5. 원상 복구
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

/*
# [oracle 계정 — Linux]
rm -rvf /u01/app/oracle/oradata/ORCL/*.*
cp -v /home/oracle/backup/noarch/* /u01/app/oracle/oradata/ORCL/
*/

/*
  정리
  - 비정상 종료(SHUTDOWN ABORT)가 발생하여 인스턴스 복구가 필요한 상황
  - 삭제된 리두 로그가 INACTIVE 상태라면 복구에 사용되지 않아서
    CLEAR LOGFILE 명령으로 복구 가능
*/



/* ==========================================================================
   7. 시나리오 24 — current 리두 로그 파일 삭제 복구
   ========================================================================== */

-- --------------------------------------------------------------------------
-- 7-1. 사전 상태 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 리두 로그 상태 확인 (1번 그룹이 current)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;


-- --------------------------------------------------------------------------
-- 7-2. 장애 발생 — CURRENT 그룹(group 1) 삭제
-- --------------------------------------------------------------------------

/*
# [oracle 계정 — Linux]
-- current 상태인 리두 로그 그룹 1 삭제
rm -rvf /u01/app/oracle/oradata/ORCL/redo01.log
*/


-- --------------------------------------------------------------------------
-- 7-3. 상태 재확인 — 삭제 후에도 STATUS는 CURRENT 유지
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;
-- 파일 삭제 후에도 1번 그룹 status는 CURRENT 유지


-- --------------------------------------------------------------------------
-- 7-4. CLEAR LOGFILE 시도 실패 (OPEN 상태)
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
ALTER DATABASE CLEAR LOGFILE GROUP 1;
-- ORA-01624: log 1 needed for crash recovery of instance orcl (thread 1)


-- --------------------------------------------------------------------------
-- 7-5. SHUTDOWN IMMEDIATE 후 STARTUP 실패
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
SHUTDOWN IMMEDIATE;
-- Database closed.
-- Database dismounted.
-- ORACLE instance shut down.

STARTUP;
-- ORA-03113: end-of-file on communication channel
-- Process ID: nnnnn


-- --------------------------------------------------------------------------
-- 7-6. 복구 절차 — STARTUP MOUNT 후 CLEAR LOGFILE
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
CONN / AS SYSDBA
-- Connected to an idle instance.

STARTUP MOUNT;
-- Database mounted.

ALTER DATABASE CLEAR LOGFILE GROUP 1;
-- Database altered.

ALTER DATABASE OPEN;
-- Database altered.


-- --------------------------------------------------------------------------
-- 7-7. 복구 결과 확인
-- --------------------------------------------------------------------------

-- [SQL*Plus — SYSDBA]
-- 리두 로그 그룹 1번이 UNUSED 상태로 전환, 그룹 2번이 current로 확인됨
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;

/*
  정리
  - SHUTDOWN IMMEDIATE는 체크포인트 완료 후 종료하므로 리두 로그에 미기록 변경분 없음
  - STARTUP MOUNT 상태에서는 crash recovery가 불필요하여 CLEAR LOGFILE 허용
  - CLEAR 이후 group 1은 UNUSED 상태로 재생성됨
*/



/* ==========================================================================
   8. 주요 명령어 정리
   --------------------------------------------------------------------------
   ALTER DATABASE CLEAR LOGFILE GROUP n               리두 로그 파일 없는 그룹을
                                                        빈 파일로 재초기화
   RECOVER DATABASE UNTIL CANCEL                       아카이브 없이 CANCEL 시점까지
                                                        불완전 복구
   RECOVER DATABASE USING BACKUP CONTROLFILE           백업 컨트롤 파일 기준으로 복구
   ALTER DATABASE OPEN RESETLOGS                       불완전 복구 후 리두 로그 시퀀스
                                                        초기화하여 오픈
   CREATE CONTROLFILE REUSE DATABASE ... RESETLOGS     컨트롤 파일 처음부터 재생성
                                                        (리두 로그 초기화 포함)
   CREATE CONTROLFILE REUSE DATABASE ... NORESETLOGS   컨트롤 파일 재생성
                                                        (기존 리두 로그 유지)
   ========================================================================== */



/* ==========================================================================
   9. 실습 핵심 요약
   --------------------------------------------------------------------------
   시나리오 18 — 컨트롤 파일·데이터파일 전체 유실, 리두 없음
     → Cold Backup 복원 → RECOVER ... UNTIL CANCEL → RESETLOGS  (불완전 복구)

   시나리오 19 — 정상 종료 후 컨트롤 파일·리두 로그 삭제
     → CREATE CONTROLFILE RESETLOGS → OPEN RESETLOGS → TEMP 추가  (완전 복구, 백업 시점)

   시나리오 20 — 컨트롤 파일·리두 로그 삭제 후 비정상 종료
     → 방법 1: Cold Backup 복원 → RESETLOGS
     → 방법 2: 리두 로그까지 복원  (불완전 복구)

   시나리오 21 — 백업 컨트롤 파일과 현재 데이터파일 불일치
     → CREATE CONTROLFILE NORESETLOGS (모든 파일 명시) → OPEN  (완전 복구)

   시나리오 22 — 정상 종료 후 inactive 리두 로그 삭제
     → MOUNT → CLEAR LOGFILE → OPEN → (DROP → ADD)  (완전 복구)

   시나리오 23 — inactive 리두 로그 삭제 후 SHUTDOWN ABORT
     → MOUNT → CLEAR LOGFILE → OPEN  (완전 복구)

   시나리오 24 — current 리두 로그 삭제 (SHUTDOWN IMMEDIATE)
     → MOUNT → CLEAR LOGFILE → OPEN  (완전 복구)
   ========================================================================== */
