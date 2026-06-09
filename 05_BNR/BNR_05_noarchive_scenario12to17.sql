/*
================================================================================
  Backup & Recovery 실습 05
  — 노아카이브 모드에서 Redo 없는 복구 & 컨트롤 파일 손상 복구 시나리오 (12~17)
================================================================================
  Blog  : https://nsylove97.tistory.com/61
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7.9 (VMware Virtual Machine)
  DB          Oracle Database 19c
  SID         orcl
  접속 툴       SQL*Plus, MobaXterm(SSH)
  실습 경로     /home/oracle/backup/noarch/
                /home/oracle/backup/noredo/
  실행 계정     oracle (OS), SYSDBA (DB), HR (DB)
  -------------------------------------------------------------------------

  전제 조건
  -------------------------------------------------------------------------
  - DB가 NOARCHIVELOG 모드로 운영 중인 상태에서 시작
  - /home/oracle/backup/noarch/ 에 Cold Backup이 사전 완료되어 있음
    (컨트롤 파일 + 데이터파일 + 리두 로그 파일 포함)
  - BNR 실습 04 완료 후 환경 기준
  - HR 계정이 활성화되어 있고 employees 테이블이 존재하는 상태
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. 시나리오 12 — 백업에 Redo Log 파일이 존재하지 않는 경우
     1-1. noredo 백업 수행 (ctl + dbf 만 백업, redo log 미포함)
     1-2. 백업 이후 데이터 변경 및 log switch
     1-3. 장애 발생 (users01.dbf 삭제)
     1-4. 손상 파일 확인
     1-5. 손상 파일 offline → DB open
     1-6. 완전 복구 시도 → 실패
     1-7. 불완전 복구 수행 (RECOVER UNTIL CANCEL USING BACKUP CONTROLFILE)
     1-8. RESETLOGS 후 로그 상태 확인
     1-9. RESETLOGS 후 즉시 백업

  2. 시나리오 13 — 컨트롤 파일만 손상된 경우 복구 (Binary)
     2-1. 백업 이후 데이터 변경 및 로그 상태 확인
     2-2. 장애 발생 (control01.ctl 삭제)
     2-3. 백업 컨트롤 파일 복원
     2-4. MOUNT 상태에서 리두 로그 상태 재확인
     2-5. 백업 컨트롤 파일을 이용한 복구 (리두 로그 직접 지정)
     2-6. RESETLOGS로 DB open

  3. 시나리오 14 — 컨트롤 파일만 손상된 경우 복구 (Trace)
     3-1. 백업 이후 데이터 변경 및 로그 상태 확인
     3-2. 장애 발생 (control01.ctl 삭제)
     3-3. 백업 컨트롤 파일 복원 및 trace 파일 생성
     3-4. 컨트롤 파일 재생성 파라미터 설명
     3-5. 컨트롤 파일 재생성 (CREATE CONTROLFILE)
     3-6. 복구 및 DB open (RECOVER DATABASE)
     3-7. 리두 로그 상태 확인
     3-8. 컨트롤 파일 재생성 후 temp 파일 재연결
     3-9. 원상복구 (noarch 백업본으로 복원)

  4. 시나리오 15 — 컨트롤 파일만 손상된 경우 복구 (정상 종료)
     4-1. 데이터 변경 및 로그 상태 확인 후 정상 종료
     4-2. 장애 발생 (control01.ctl 삭제)
     4-3. 백업 컨트롤 파일 복원 및 trace 파일 생성
     4-4. 컨트롤 파일 재생성
     4-5. DB open 및 temp 파일 재연결

  5. 시나리오 16 — 컨트롤 파일만 손상된 경우 복구 (비정상 종료)
     5-1. 데이터 변경 및 컨트롤 파일 삭제 (운영 중)
     5-2. 장애 감지 — v$database 조회 오류
     5-3. 백업 컨트롤 파일 복원
     5-4. trace 파일 생성 및 컨트롤 파일 재생성
     5-5. 복구 및 DB open (RECOVER DATABASE 필수)

  6. 시나리오 17 — 데이터파일 + 컨트롤 파일 손상 복구 (정상 종료, 리두 O)
     6-1. 데이터 변경 및 정상 종료
     6-2. 장애 발생 (ctl + dbf 전체 삭제)
     6-3. 백업본에서 컨트롤 파일 + 데이터파일 restore
     6-4. 백업 컨트롤 파일을 이용한 복구 (AUTO 시도 → 실패)
     6-5. 리두 로그 상태 확인
     6-6. 리두 로그 파일 직접 지정하여 복구
     6-7. RESETLOGS로 DB open

  7. 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. 시나리오 12 — 백업에 Redo Log 파일이 존재하지 않는 경우
   --------------------------------------------------------------------------
   조건
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 항목              │ 내용                                                │
   │───────────────────│─────────────────────────────────────────────────────│
   │ 백업 대상          │ 데이터파일(.dbf) + 컨트롤 파일(.ctl) — redo log 제외 │
   │ 백업 이후 변경      │ 데이터 변경 + log switch 반복 → 아카이브 로그 없음    │
   │ 복구 결과          │ 완전 복구 불가 → 불완전 복구 (RESETLOGS)             │
   └─────────────────────────────────────────────────────────────────────────┘
   ========================================================================== */

/* --- 1-1. noredo 백업 수행 (ctl + dbf 만 백업, redo log 미포함) ----------- */

-- [SQL*Plus — SYSDBA] DB 종료
SHUTDOWN IMMEDIATE;

-- [oracle 계정 — Linux]
-- /home/oracle/backup/noredo/ 디렉토리 생성
-- mkdir -p /home/oracle/backup/noredo

-- [oracle 계정 — Linux]
-- redo log 파일 제외하고 ctl + dbf 만 백업
-- cp -v /u01/app/oracle/oradata/ORCL/*.dbf /home/oracle/backup/noredo/
-- cp -v /u01/app/oracle/oradata/ORCL/*.ctl /home/oracle/backup/noredo/

-- 백업 결과 확인
-- ls -l /home/oracle/backup/noredo/


/* --- 1-2. 백업 이후 데이터 변경 및 log switch ----------------------------- */

-- [SQL*Plus — SYSDBA] DB 기동
STARTUP;

-- 현재 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;

-- 백업 이후 데이터 변경
-- [SQL*Plus — HR 또는 SYSDBA]
CREATE TABLE hr.emp1 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

-- 백업 시점의 리두를 모두 덮어쓰기 위해 log switch 반복
-- (CURRENT 그룹이 최소 3회 이상 교체되어야 이전 내용이 사라짐)
ALTER SYSTEM SWITCH LOGFILE;
-- System altered.
ALTER SYSTEM SWITCH LOGFILE;
-- System altered.
ALTER SYSTEM SWITCH LOGFILE;
-- System altered.

-- DB 종료
SHUTDOWN IMMEDIATE;


/* --- 1-3. 장애 발생 (users01.dbf 삭제) ------------------------------------ */

-- [oracle 계정 — Linux]
-- rm -rvf /u01/app/oracle/oradata/ORCL/users01.dbf

-- [SQL*Plus — SYSDBA] DB 기동 시도
STARTUP;
-- ORA-01157: cannot identify/lock data file 7 - see DBWR trace file
-- ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'
-- → MOUNT 단계에서 OPEN 단계로 전환 불가


/* --- 1-4. 손상 파일 확인 --------------------------------------------------- */

-- 복구 필요 파일 확인
SELECT * FROM v$recover_file;
--      FILE# ONLINE  ONLINE_ ERROR                   CHANGE# TIME       CON_ID
-- ---------- ------- ------- -------------------- ---------- ---------- ------
--          7 ONLINE  ONLINE  FILE NOT FOUND                0            0

-- 데이터파일 상태 확인 (파일 번호는 환경에 따라 다름 — 위 결과의 FILE# 참조)
SELECT file#, name, checkpoint_change#, status
FROM   v$datafile;
--      FILE# NAME                                               CHECKPOINT_CHANGE# STATUS
-- ---------- -------------------------------------------------- ------------------ -------
--          1 /u01/app/oracle/oradata/ORCL/system01.dbf               ...          SYSTEM
--          7 /u01/app/oracle/oradata/ORCL/users01.dbf                ...          ONLINE


/* --- 1-5. 손상 파일 offline → DB open ------------------------------------- */

-- 손상 파일 offline drop (파일 번호는 v$recover_file 결과 FILE# 사용)
ALTER DATABASE DATAFILE 7 OFFLINE DROP;
-- Database altered.

ALTER DATABASE OPEN;
-- Database altered.


/* --- 1-6. 완전 복구 시도 (실패) -------------------------------------------- */

-- [oracle 계정 — Linux]
-- noarch 백업본의 users01.dbf 복원 (redo log 미포함 버전 사용)
-- cp -v /home/oracle/backup/noarch/users01.dbf /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
-- 완전 복구 시도
RECOVER TABLESPACE USERS;
-- ORA-00279: change NNNNNN generated at ... needed for thread 1
-- ORA-00289: suggestion : /home/oracle/arch2/arch_1_NN_NNNNNNNNNN.arc
-- ORA-00280: change NNNNNN for thread 1 is in sequence #NN
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
-- cancel
-- Media recovery cancelled.
-- → 아카이브 로그 없어 리두 적용 불가 → 완전 복구 실패

ALTER DATABASE DATAFILE 7 ONLINE;
-- ORA-01113: file 7 needs media recovery
-- ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'
-- → online 불가 확인 → 불완전 복구로 전환 필요


/* --- 1-7. 불완전 복구 수행 ------------------------------------------------- */
/*
  불완전 복구 절차
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ 단계  │ 작업 내용                                                         │
  │───────│──────────────────────────────────────────────────────────────────│
  │  1    │ SHUTDOWN ABORT — 현재 DB 즉시 종료                                │
  │  2    │ noredo 백업본 (ctl + dbf) 전체 복원                               │
  │  3    │ STARTUP MOUNT                                                    │
  │  4    │ RECOVER DATABASE UNTIL CANCEL USING BACKUP CONTROLFILE           │
  │       │   → 아카이브 로그 없으므로 CANCEL 즉시 입력                        │
  │  5    │ ALTER DATABASE OPEN RESETLOGS                                    │
  └──────────────────────────────────────────────────────────────────────────┘
*/

-- [SQL*Plus — SYSDBA] 긴급 종료
SHUTDOWN ABORT;

-- [oracle 계정 — Linux]
-- noredo 백업본 전체(ctl + dbf) 복원
-- cp -v /home/oracle/backup/noredo/*.ctl /u01/app/oracle/oradata/ORCL/
-- cp -v /home/oracle/backup/noredo/*.dbf /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
STARTUP MOUNT;
-- Database mounted.

-- 백업 컨트롤 파일을 이용한 cancel base recovery
RECOVER DATABASE UNTIL CANCEL USING BACKUP CONTROLFILE;
-- ORA-00279: change NNNNNN generated at ... needed for thread 1
-- ORA-00289: suggestion : ...
-- ORA-00280: change NNNNNN for thread 1 is in sequence #NN
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
-- CANCEL ← 반드시 CANCEL 입력 (아카이브 로그 없음)
-- Media recovery cancelled.

ALTER DATABASE OPEN RESETLOGS;
-- Database altered.

SELECT status FROM v$instance;
-- STATUS
-- -------
-- OPEN


/* --- 1-8. RESETLOGS 후 로그 상태 확인 ------------------------------------- */

-- RESETLOGS 후 sequence# 가 1부터 재시작되는 것 확인
SELECT group#, thread#, sequence#, bytes/1024/1024 mb, status, archived
FROM   v$log
ORDER BY group#;
-- GROUP# THREAD# SEQUENCE# MB STATUS   ARC
-- ------ ------- --------- -- -------- ---
--      1       1         1 10 CURRENT  NO
--      2       1         0 10 UNUSED   YES
--      3       1         0 10 UNUSED   YES


/* --- 1-9. RESETLOGS 후 즉시 백업 ----------------------------------------- */
/*
  RESETLOGS 이후 이전 백업본은 사용 불가
  → 즉시 전체 백업(Cold Backup) 수행 필수
*/

-- 백업 전 log switch 반복으로 redo log 파일 status를 전환
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;

SHUTDOWN IMMEDIATE;

-- [oracle 계정 — Linux]
-- 전체 파일 (ctl + dbf + log) cold backup
-- cp -v /u01/app/oracle/oradata/ORCL/*.ctl  /home/oracle/backup/noarch/
-- cp -v /u01/app/oracle/oradata/ORCL/*.dbf  /home/oracle/backup/noarch/
-- cp -v /u01/app/oracle/oradata/ORCL/*.log  /home/oracle/backup/noarch/


/* ==========================================================================
   2. 시나리오 13 — 컨트롤 파일만 손상된 경우 복구 (Binary)
   --------------------------------------------------------------------------
   조건
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 항목              │ 내용                                                │
   │───────────────────│─────────────────────────────────────────────────────│
   │ 손상 대상          │ 컨트롤 파일만 삭제                                   │
   │ 데이터파일/리두     │ 정상                                                │
   │ 복구 방법          │ Binary 백업본 복원 → RECOVER USING BACKUP CONTROLFILE│
   │ 복구 결과          │ RESETLOGS                                           │
   └─────────────────────────────────────────────────────────────────────────┘
   ========================================================================== */

/* --- 2-1. 백업 이후 데이터 변경 및 로그 상태 확인 --------------------------- */

STARTUP;

CREATE TABLE hr.emp3 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

ALTER SYSTEM SWITCH LOGFILE;
-- System altered.

-- 리두 로그 파일 경로 및 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;
--     GROUP#  SEQUENCE# MEMBER                                           MB STATUS           ARC FIRST_CHANGE# NEXT_CHANGE#
-- ---------- ---------- ---------------------------------------- ---------- ---------------- --- ------------- ------------
--          1          4 /u01/.../redo01.log                               50 ACTIVE           NO        NNNNNN   NNNNNN
--          2          5 /u01/.../redo02.log                               50 CURRENT          NO        NNNNNN   1.8447E+19
--          3          3 /u01/.../redo03.log                               50 INACTIVE         NO        NNNNNN   NNNNNN


/* --- 2-2. 장애 발생 (control01.ctl 삭제) ----------------------------------- */

-- [oracle 계정 — Linux]
-- rm -rvf /u01/app/oracle/oradata/ORCL/control01.ctl

-- [SQL*Plus — SYSDBA] 긴급 종료 후 기동
SHUTDOWN ABORT;
STARTUP;
-- ORA-00205: error in identifying control file, check alert log for more info
-- → NOMOUNT 상태에서 MOUNT 단계로 전환 불가

SELECT status FROM v$instance;
-- STATUS
-- -------
-- STARTED   ← NOMOUNT 상태

-- 파라미터에서 컨트롤 파일 경로 확인
SHOW PARAMETER control_files;
-- NAME          TYPE   VALUE
-- ------------- ------ --------------------------------------------------
-- control_files string /u01/app/oracle/oradata/ORCL/control01.ctl


/* --- 2-3. 백업 컨트롤 파일 복원 ------------------------------------------- */

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

-- [oracle 계정 — Linux]
-- 백업 컨트롤 파일(Binary)로 복원
-- cp -v /home/oracle/backup/noarch/control01.ctl /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
STARTUP MOUNT;
-- Database mounted.


/* --- 2-4. MOUNT 상태에서 리두 로그 상태 재확인 ----------------------------- */

-- MOUNT 상태에서 리두 로그 상태 조회
-- (백업 시점과 현재 시점의 sequence# 불일치 여부 확인)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;
-- GROUP# 기준으로 STATUS 와 FIRST_CHANGE# 확인
-- 컨트롤 파일은 백업 시점 기준 → sequence# 가 현재와 다를 수 있음


/* --- 2-5. 백업 컨트롤 파일을 이용한 복구 (리두 로그 직접 지정) -------------- */
/*
  AUTO 입력 시 아카이브 경로에서 파일 탐색 → NOARCHIVELOG 환경에서 실패
  → 리두 로그 파일 경로를 직접 입력해야 함
  → 2-4 단계에서 확인한 CURRENT 또는 ACTIVE 그룹의 member 경로 입력
*/

RECOVER DATABASE USING BACKUP CONTROLFILE;
-- ORA-00279: change NNNNNN generated at ... needed for thread 1
-- ORA-00289: suggestion : /home/oracle/arch2/arch_1_N_NNNNNNNNNN.arc
-- ORA-00280: change NNNNNN for thread 1 is in sequence #N
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
-- /u01/app/oracle/oradata/ORCL/redo02.log  ← CURRENT 그룹 member 경로 직접 입력
-- Log applied.
-- Media recovery complete.


/* --- 2-6. RESETLOGS로 DB open ---------------------------------------------- */

ALTER DATABASE OPEN RESETLOGS;
-- Database altered.

-- 복구 완료 후 과거 백업본은 사용 불가 → 즉시 전체 백업 수행


/* ==========================================================================
   3. 시나리오 14 — 컨트롤 파일만 손상된 경우 복구 (Trace)
   --------------------------------------------------------------------------
   조건
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 항목              │ 내용                                                │
   │───────────────────│─────────────────────────────────────────────────────│
   │ 손상 대상          │ 컨트롤 파일만 삭제                                   │
   │ 데이터파일/리두     │ 정상                                                │
   │ 복구 방법          │ trace로 CREATE CONTROLFILE 재생성 → RECOVER DATABASE│
   │ 복구 결과          │ RESETLOGS 없이 정상 open (리두 적용 완료)             │
   └─────────────────────────────────────────────────────────────────────────┘
   ========================================================================== */

/* --- 3-1. 백업 이후 데이터 변경 및 로그 상태 확인 --------------------------- */

SHUTDOWN IMMEDIATE;
STARTUP;

CREATE TABLE hr.emp4 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

ALTER SYSTEM SWITCH LOGFILE;
-- System altered.

-- 로그 상태 확인 (CURRENT 그룹 sequence# 기록해 둘 것)
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;


/* --- 3-2. 장애 발생 (control01.ctl 삭제) ----------------------------------- */

-- [oracle 계정 — Linux]
-- rm -rvf /u01/app/oracle/oradata/ORCL/control01.ctl

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;
STARTUP;
-- ORA-00205: error in identifying control file, check alert log for more info

-- Alert log 위치: $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/alert_orcl.log
-- 주요 오류:
-- ORA-00202: control file: '/u01/app/oracle/oradata/ORCL/control01.ctl'
-- ORA-27037: unable to obtain file status
-- Linux-x86_64 Error: 2: No such file or directory


/* --- 3-3. 백업 컨트롤 파일 복원 및 trace 파일 생성 -------------------------- */

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

-- [oracle 계정 — Linux]
-- 백업본으로 컨트롤 파일 복원
-- cp -v /home/oracle/backup/noarch/control01.ctl /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
STARTUP MOUNT;
-- Database mounted.

-- 백업 컨트롤 파일을 기반으로 CREATE CONTROLFILE 스크립트 생성
ALTER DATABASE BACKUP CONTROLFILE TO TRACE
AS '/home/oracle/cre_con.sql';
-- Database altered.

-- [oracle 계정 — Linux]
-- 생성된 trace 파일 확인
-- ls -l /home/oracle/cre_con.sql
-- cat /home/oracle/cre_con.sql


/* --- 3-4. 컨트롤 파일 재생성 시 변경 가능한 파라미터 (참고) ----------------- */
/*
  파라미터         │ 의미
  ─────────────────│────────────────────────────────────────────────────────
  MAXLOGFILES      │ DB에서 생성 가능한 리두 로그 파일(그룹) 최대 개수
  MAXLOGMEMBERS    │ 로그 파일 그룹당 파일 최대 개수
  MAXDATAFILES     │ DB에서 생성 가능한 데이터파일 최대 개수
  MAXINSTANCES     │ 인스턴스 최대 개수 (RAC용)
  MAXLOGHISTORY    │ 아카이브 로그 모드일 시 최대 로그 파일 기록 개수
*/


/* --- 3-5. 컨트롤 파일 재생성 (CREATE CONTROLFILE) -------------------------- */

-- [SQL*Plus — SYSDBA] DB 종료 후 NOMOUNT 상태로 기동
SHUTDOWN ABORT;
STARTUP NOMOUNT;

-- trace 파일 내용 기반으로 컨트롤 파일 재생성
-- (실습 환경의 데이터파일 목록은 v$datafile 또는 trace 파일에서 확인)
-- !! 아래 경로 및 목록은 환경에 따라 다름 — trace 파일 내용으로 대체 !!
CREATE CONTROLFILE REUSE DATABASE "ORCL" NORESETLOGS NOARCHIVELOG
  MAXLOGFILES   16
  MAXLOGMEMBERS  3
  MAXDATAFILES 100
  MAXINSTANCES   8
  MAXLOGHISTORY 292
LOGFILE
  GROUP 1 '/u01/app/oracle/oradata/ORCL/redo01.log' SIZE 10M BLOCKSIZE 512,
  GROUP 2 '/u01/app/oracle/oradata/ORCL/redo02.log' SIZE 10M BLOCKSIZE 512,
  GROUP 3 '/u01/app/oracle/oradata/ORCL/redo03.log' SIZE 10M BLOCKSIZE 512
-- STANDBY LOGFILE
DATAFILE
  '/u01/app/oracle/oradata/ORCL/system01.dbf',
  '/u01/app/oracle/oradata/ORCL/sysaux01.dbf',
  '/u01/app/oracle/oradata/ORCL/undotbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/users01.dbf'
CHARACTER SET AL32UTF8
;
-- Control file created.


/* --- 3-6. 복구 및 DB open (RECOVER DATABASE) ------------------------------- */

SELECT status FROM v$instance;
-- STATUS
-- -------
-- MOUNTED

-- 컨트롤 파일 재생성 후 MOUNTED 상태에서 recover 수행
RECOVER DATABASE;
-- Media recovery complete.

ALTER DATABASE OPEN;
-- Database altered.


/* --- 3-7. 리두 로그 상태 확인 ---------------------------------------------- */

-- open 후 리두 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;
-- 리두 로그가 손상되지 않은 경우 → NORESETLOGS 사용 → 백업본 그대로 사용 가능
-- 리두 로그가 손상된 경우에만 RESETLOGS 옵션 사용


/* --- 3-8. 컨트롤 파일 재생성 후 temp 파일 재연결 (필수) --------------------- */
/*
  컨트롤 파일을 재생성하면 TEMP 파일 연결이 해제됨
  → 반드시 재연결 필요
*/

-- temp 파일 연결 여부 확인
SELECT name FROM v$tempfile;
-- no rows selected  ← 연결 해제 상태

-- [oracle 계정 — Linux]
-- OS에 물리적 파일 존재 여부 확인
-- ls -l /u01/app/oracle/oradata/ORCL/temp01.dbf

-- temp 파일 재연결
ALTER TABLESPACE TEMP ADD TEMPFILE
'/u01/app/oracle/oradata/ORCL/temp01.dbf' REUSE;
-- Tablespace altered.

SELECT name FROM v$tempfile;
-- NAME
-- -------------------------------------------------------
-- /u01/app/oracle/oradata/ORCL/temp01.dbf


/* --- 3-9. 원상복구 (noarch 백업본으로 복원) --------------------------------- */

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

-- [oracle 계정 — Linux]
-- noarch 백업본 전체 복원 (다음 시나리오 준비)
-- cp -v /home/oracle/backup/noarch/*.ctl /u01/app/oracle/oradata/ORCL/
-- cp -v /home/oracle/backup/noarch/*.dbf /u01/app/oracle/oradata/ORCL/
-- cp -v /home/oracle/backup/noarch/*.log /u01/app/oracle/oradata/ORCL/


/* ==========================================================================
   4. 시나리오 15 — 컨트롤 파일만 손상된 경우 복구 (정상 종료)
   --------------------------------------------------------------------------
   조건
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 항목              │ 내용                                                │
   │───────────────────│─────────────────────────────────────────────────────│
   │ 손상 대상          │ 컨트롤 파일만 삭제                                   │
   │ 종료 방식          │ 장애 발생 전 정상 종료 (SHUTDOWN IMMEDIATE)           │
   │ 데이터파일/리두     │ 정상                                                │
   │ 복구 특징          │ 정상 종료 → checkpoint 완료 → RECOVER 불필요          │
   └─────────────────────────────────────────────────────────────────────────┘
   ========================================================================== */

/* --- 4-1. 데이터 변경 및 로그 상태 확인 후 정상 종료 ------------------------ */

STARTUP;

CREATE TABLE hr.emp3 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

ALTER SYSTEM SWITCH LOGFILE;
-- System altered.

-- 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;

-- 정상 종료 (모든 변경사항 checkpoint 완료)
SHUTDOWN IMMEDIATE;


/* --- 4-2. 장애 발생 (control01.ctl 삭제) ----------------------------------- */

-- [oracle 계정 — Linux]
-- rm -rvf /u01/app/oracle/oradata/ORCL/control01.ctl

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-00205: error in identifying control file, check alert log for more info
-- → NOMOUNT 상태에서 막힘


/* --- 4-3. 백업 컨트롤 파일 복원 및 trace 파일 생성 -------------------------- */

-- [oracle 계정 — Linux]
-- cp -v /home/oracle/backup/noarch/control01.ctl /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
ALTER DATABASE MOUNT;
-- Database altered.

ALTER DATABASE BACKUP CONTROLFILE TO TRACE
AS '/home/oracle/backup/cre_con2.sql';
-- Database altered.

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;
STARTUP NOMOUNT;


/* --- 4-4. 컨트롤 파일 재생성 ----------------------------------------------- */
/*
  trace 파일 내용 기반으로 재생성
  실습 환경의 데이터파일 목록 — trace 파일에서 확인 후 그대로 사용
  !! 아래 목록은 환경에 따라 다름 !!
*/
CREATE CONTROLFILE REUSE DATABASE "ORCL" NORESETLOGS NOARCHIVELOG
  MAXLOGFILES   16
  MAXLOGMEMBERS  3
  MAXDATAFILES 100
  MAXINSTANCES   8
  MAXLOGHISTORY 292
LOGFILE
  GROUP 1 '/u01/app/oracle/oradata/ORCL/redo01.log' SIZE 50M BLOCKSIZE 512,
  GROUP 2 '/u01/app/oracle/oradata/ORCL/redo02.log' SIZE 50M BLOCKSIZE 512,
  GROUP 3 '/u01/app/oracle/oradata/ORCL/redo03.log' SIZE 50M BLOCKSIZE 512
-- STANDBY LOGFILE
DATAFILE
  '/u01/app/oracle/oradata/ORCL/system01.dbf',
  '/u01/app/oracle/oradata/ORCL/audit_tbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/sysaux01.dbf',
  '/u01/app/oracle/oradata/ORCL/undotbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/users01.dbf',
  '/u01/app/oracle/oradata/ORCL/userdata01.dbf'
CHARACTER SET AL32UTF8
;
-- Control file created.


/* --- 4-5. DB open 및 temp 파일 재연결 --------------------------------------- */

SELECT status FROM v$instance;
-- STATUS
-- -------
-- MOUNTED

-- 정상 종료 후 컨트롤 파일 손상 → 모든 변경 이미 checkpoint 완료
-- → RECOVER DATABASE 불필요 → 바로 open 가능
ALTER DATABASE OPEN;
-- Database altered.

-- temp 파일 재연결 (컨트롤 파일 재생성 시 항상 필요)
ALTER TABLESPACE TEMP ADD TEMPFILE
'/u01/app/oracle/oradata/ORCL/temp01.dbf' REUSE;
-- Tablespace altered.

SELECT name FROM v$tempfile;
-- /u01/app/oracle/oradata/ORCL/temp01.dbf


/* ==========================================================================
   5. 시나리오 16 — 컨트롤 파일만 손상된 경우 복구 (비정상 종료)
   --------------------------------------------------------------------------
   조건
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 항목              │ 내용                                                │
   │───────────────────│─────────────────────────────────────────────────────│
   │ 손상 대상          │ DB 운영 중 컨트롤 파일 삭제                          │
   │ 종료 방식          │ 비정상 종료 (컨트롤 파일 없는 상태에서 abort)          │
   │ 데이터파일/리두     │ 정상                                                │
   │ 복구 특징          │ 비정상 종료 → checkpoint 불완전 → RECOVER 필수        │
   └─────────────────────────────────────────────────────────────────────────┘

   시나리오 15 vs 16 핵심 차이
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 구분                  │ 정상 종료 후 복구       │ 비정상 종료 후 복구      │
   │───────────────────────│─────────────────────────│─────────────────────────│
   │ RECOVER DATABASE      │ 불필요                  │ 필수                    │
   │ ALTER DATABASE OPEN   │ 바로 가능               │ RECOVER 완료 후 가능    │
   └─────────────────────────────────────────────────────────────────────────┘
   ========================================================================== */

/* --- 5-1. 데이터 변경 및 컨트롤 파일 삭제 (운영 중) ------------------------- */

CREATE TABLE hr.emp4 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

-- [oracle 계정 — Linux] DB 운영 중 장애 발생
-- rm -rvf /u01/app/oracle/oradata/ORCL/control01.ctl

-- [SQL*Plus — SYSDBA] DB 운영 중 로그 스위치 발생
ALTER SYSTEM SWITCH LOGFILE;
-- System altered.

-- 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;


/* --- 5-2. 장애 감지 — v$database 조회 오류 --------------------------------- */

-- HR 계정에서 일반 테이블 조회는 여전히 가능
-- CONN hr/hr
SELECT COUNT(*) FROM employees;
-- COUNT(*)
-- --------
--      107  ← 조회 가능

-- SYSDBA에서 컨트롤 파일 의존 뷰 조회 시 오류 발생
CONN / AS SYSDBA
SELECT * FROM v$database;
-- ORA-00210: cannot open the specified control file
-- ORA-00202: control file: '/u01/app/oracle/oradata/ORCL/control01.ctl'
-- ORA-27041: unable to open file

-- Alert log 확인:
-- ORA-00210: cannot open the specified control file
-- ORA-00202: control file: '/u01/app/oracle/oradata/ORCL/control01.ctl'
-- ORA-27041: unable to open file


/* --- 5-3. 백업 컨트롤 파일 복원 ------------------------------------------- */

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

-- [oracle 계정 — Linux]
-- cp -v /home/oracle/backup/noarch/control01.ctl /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-01122: database file 1 failed verification check
-- ORA-01110: data file 1: '/u01/app/oracle/oradata/ORCL/system01.dbf'
-- ORA-01207: file is more recent than control file - old control file
-- → 백업 컨트롤 파일 SCN이 현재 데이터파일 SCN보다 오래됨 → RECOVER 필요

-- MOUNT 상태로 머무름 확인
SELECT status FROM v$instance;
-- STATUS
-- -------
-- MOUNTED


/* --- 5-4. trace 파일 생성 및 컨트롤 파일 재생성 ----------------------------- */

-- MOUNT 상태에서 trace 파일 생성
ALTER DATABASE BACKUP CONTROLFILE TO TRACE
AS '/home/oracle/backup/cons.sql';
-- Database altered.

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;
STARTUP NOMOUNT;

-- trace 파일 기반으로 컨트롤 파일 재생성
-- !! 아래 목록은 환경에 따라 다름 — trace 파일 내용으로 대체 !!
CREATE CONTROLFILE REUSE DATABASE "ORCL" NORESETLOGS NOARCHIVELOG
  MAXLOGFILES   16
  MAXLOGMEMBERS  3
  MAXDATAFILES 100
  MAXINSTANCES   8
  MAXLOGHISTORY 292
LOGFILE
  GROUP 1 '/u01/app/oracle/oradata/ORCL/redo01.log' SIZE 50M BLOCKSIZE 512,
  GROUP 2 '/u01/app/oracle/oradata/ORCL/redo02.log' SIZE 50M BLOCKSIZE 512,
  GROUP 3 '/u01/app/oracle/oradata/ORCL/redo03.log' SIZE 50M BLOCKSIZE 512
-- STANDBY LOGFILE
DATAFILE
  '/u01/app/oracle/oradata/ORCL/system01.dbf',
  '/u01/app/oracle/oradata/ORCL/audit_tbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/sysaux01.dbf',
  '/u01/app/oracle/oradata/ORCL/undotbs01.dbf',
  '/u01/app/oracle/oradata/ORCL/users01.dbf',
  '/u01/app/oracle/oradata/ORCL/userdata01.dbf'
CHARACTER SET AL32UTF8
;
-- Control file created.


/* --- 5-5. 복구 및 DB open (RECOVER DATABASE 필수) -------------------------- */

-- 비정상 종료 → 리두 적용 미완료 → RECOVER 필수
RECOVER DATABASE;
-- Media recovery complete.

ALTER DATABASE OPEN;
-- Database altered.

-- temp 파일 재연결
ALTER TABLESPACE TEMP ADD TEMPFILE
'/u01/app/oracle/oradata/ORCL/temp01.dbf' REUSE;
-- Tablespace altered.


/* ==========================================================================
   6. 시나리오 17 — 데이터파일 + 컨트롤 파일 손상 복구 (정상 종료, 리두 O)
   --------------------------------------------------------------------------
   조건
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ 항목              │ 내용                                                │
   │───────────────────│─────────────────────────────────────────────────────│
   │ 손상 대상          │ 데이터파일(.dbf) + 컨트롤 파일(.ctl) 모두 삭제        │
   │ 종료 방식          │ 정상 종료 후 장애 발생                               │
   │ 리두 상태          │ 리두 로그 파일 정상 (복구 가능)                       │
   │ 복구 방법          │ 전체 restore → RECOVER USING BACKUP CONTROLFILE     │
   │                   │ → 리두 로그 직접 지정                                │
   │ 복구 결과          │ RESETLOGS                                           │
   └─────────────────────────────────────────────────────────────────────────┘
   ========================================================================== */

/* --- 6-1. 데이터 변경 및 정상 종료 ----------------------------------------- */

CREATE TABLE hr.emp5 TABLESPACE users
AS SELECT * FROM hr.employees;
-- Table created.

SHUTDOWN IMMEDIATE;


/* --- 6-2. 장애 발생 (ctl + dbf 전체 삭제) ---------------------------------- */

-- [oracle 계정 — Linux] 현재 파일 목록 확인
-- ls /u01/app/oracle/oradata/ORCL/*.{ctl,dbf}

-- 데이터파일 + 컨트롤 파일 전체 삭제 (리두 로그 파일은 남음)
-- rm -rvf /u01/app/oracle/oradata/ORCL/*.ctl
-- rm -rvf /u01/app/oracle/oradata/ORCL/*.dbf

-- 삭제 후 남은 파일 확인 (initorcl.ora + redo*.log 만 남아야 함)
-- ls /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
STARTUP;
-- ORA-00205: error in identifying control file, check alert log for more info
-- → NOMOUNT 상태에서 막힘

-- Alert log 확인:
-- ORA-00202: control file: '/u01/app/oracle/oradata/ORCL/control01.ctl'
-- ORA-27037: unable to obtain file status
-- Linux-x86_64 Error: 2: No such file or directory


/* --- 6-3. 백업본에서 컨트롤 파일 + 데이터파일 restore ---------------------- */

-- [SQL*Plus — SYSDBA]
SHUTDOWN ABORT;

-- [oracle 계정 — Linux]
-- noarch 백업본에서 ctl + dbf 복원 (redo log는 현재 존재하므로 제외)
-- cp -v /home/oracle/backup/noarch/*.ctl /u01/app/oracle/oradata/ORCL/
-- cp -v /home/oracle/backup/noarch/*.dbf /u01/app/oracle/oradata/ORCL/

-- [SQL*Plus — SYSDBA]
STARTUP MOUNT;
-- Database mounted.


/* --- 6-4. 백업 컨트롤 파일을 이용한 복구 (AUTO 시도 → 실패) ---------------- */

RECOVER DATABASE USING BACKUP CONTROLFILE;
-- ORA-00279: change NNNNNN generated at ... needed for thread 1
-- ORA-00289: suggestion : /home/oracle/arch2/arch_1_N_NNNNNNNNNN.arc
-- ORA-00280: change NNNNNN for thread 1 is in sequence #N
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
-- auto
-- ORA-00308: cannot open archived log '/home/oracle/arch2/...'
-- ORA-27037: unable to obtain file status
-- → NOARCHIVELOG 환경 → AUTO 실패 → 리두 로그 직접 지정 필요


/* --- 6-5. 리두 로그 상태 확인 ---------------------------------------------- */

-- MOUNT 상태에서 리두 로그 상태 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM   v$logfile a, v$log b
WHERE  a.group# = b.group#
ORDER BY 1, 2;
-- CURRENT 상태 그룹의 member 경로를 확인 → 다음 단계에서 직접 입력


/* --- 6-6. 리두 로그 파일 직접 지정하여 복구 --------------------------------- */

RECOVER DATABASE USING BACKUP CONTROLFILE;
-- ORA-00279: change NNNNNN generated at ... needed for thread 1
-- ORA-00289: suggestion : /home/oracle/arch2/arch_1_N_NNNNNNNNNN.arc
-- ORA-00280: change NNNNNN for thread 1 is in sequence #N
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
-- /u01/app/oracle/oradata/ORCL/redo02.log  ← 6-5에서 확인한 CURRENT 그룹 경로
-- Log applied.
-- Media recovery complete.


/* --- 6-7. RESETLOGS로 DB open ---------------------------------------------- */

ALTER DATABASE OPEN RESETLOGS;
-- Database altered.

-- 복구 완료 후 즉시 전체 백업 수행


/* ==========================================================================
   7. 핵심 요약
   --------------------------------------------------------------------------
   시나리오별 복구 방법 및 결과 비교

   ┌──────┬──────────────────────────┬────────────────────────────────────────┬────────────────────┐
   │ 시나리오 │ 손상 대상               │ 복구 방법                               │ 결과               │
   ├──────┼──────────────────────────┼────────────────────────────────────────┼────────────────────┤
   │ 12   │ 데이터파일 (리두 없음)     │ RECOVER UNTIL CANCEL                    │ RESETLOGS          │
   │      │                          │ USING BACKUP CONTROLFILE                │ (불완전 복구)      │
   ├──────┼──────────────────────────┼────────────────────────────────────────┼────────────────────┤
   │ 13   │ 컨트롤 파일               │ Binary Backup 복원                      │ RESETLOGS          │
   │      │                          │ → RECOVER USING BACKUP CONTROLFILE      │                    │
   ├──────┼──────────────────────────┼────────────────────────────────────────┼────────────────────┤
   │ 14   │ 컨트롤 파일               │ Trace 파일로 재생성                     │ OPEN               │
   │      │ (Trace 재생성)           │ → RECOVER DATABASE                      │ (RESETLOGS 불필요) │
   ├──────┼──────────────────────────┼────────────────────────────────────────┼────────────────────┤
   │ 15   │ 컨트롤 파일               │ Trace 파일로 재생성                     │ OPEN               │
   │      │ (정상 종료 상태)         │ → CREATE CONTROLFILE                    │ (복구 불필요)      │
   ├──────┼──────────────────────────┼────────────────────────────────────────┼────────────────────┤
   │ 16   │ 컨트롤 파일               │ Trace 파일로 재생성                     │ RECOVER 후 OPEN    │
   │      │ (비정상 종료 상태)       │ → RECOVER DATABASE 필수                 │                    │
   ├──────┼──────────────────────────┼────────────────────────────────────────┼────────────────────┤
   │ 17   │ 데이터파일 + 컨트롤 파일  │ 전체 Restore                            │ RESETLOGS          │
   │      │ (정상 종료, 리두 존재)   │ → RECOVER USING BACKUP CONTROLFILE      │                    │
   └──────┴──────────────────────────┴────────────────────────────────────────┴────────────────────┘


   공통 주의사항

   ┌────────────────────────────┬──────────────────────────────────────────────────────────────┐
   │ 항목                       │ 내용                                                         │
   ├────────────────────────────┼──────────────────────────────────────────────────────────────┤
   │ TEMP 파일 재연결           │ 컨트롤 파일 재생성 후 항상 수행                             │
   │                            │ ALTER TABLESPACE TEMP ADD TEMPFILE ... REUSE;              │
   ├────────────────────────────┼──────────────────────────────────────────────────────────────┤
   │ RESETLOGS 후 백업          │ RESETLOGS 수행 직후 전체 백업(Cold Backup) 필수            │
   ├────────────────────────────┼──────────────────────────────────────────────────────────────┤
   │ 비정상 종료 후 복구        │ CREATE CONTROLFILE 후 반드시 RECOVER DATABASE 수행         │
   │                            │ (Checkpoint 미완료 상태 복구 필요)                         │
   ├────────────────────────────┼──────────────────────────────────────────────────────────────┤
   │ USING BACKUP CONTROLFILE   │ NOARCHIVELOG 환경에서는 AUTO 복구 실패 가능                │
   │                            │ CURRENT Online Redo Log 파일 경로를 직접 입력해야 함      │
   └────────────────────────────┴──────────────────────────────────────────────────────────────┘
   ========================================================================== */
