/*
================================================================================
  Backup & Recovery 실습 02 — 노아카이브모드 Cold Backup & 복구 시나리오
================================================================================
  Blog  : https://nsylove97.tistory.com/58
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7.9 (VMware Virtual Machine)
  DB          Oracle Database 19c
  SID         orcl
  접속 툴       SQL*Plus, MobaXterm(SSH)
  실습 경로     /home/oracle/backup/noarch/
  실행 계정     oracle (OS), SYSDBA (DB), HR (DB)
  -------------------------------------------------------------------------

  전제 조건
  -------------------------------------------------------------------------
  - DB가 NOARCHIVELOG 모드로 운영 중인 상태에서 시작
  - /home/oracle/backup/noarch/ 디렉토리가 사전 생성되어 있음
  - BNR 실습 01 완료 후 환경 기준
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. Cold Backup 개념 및 수행 조건
  2. 백업 전 사전 확인
     2-1. 컨트롤 파일 단일화 (필요 시)
     2-2. 현재 SCN 및 파일별 체크포인트 확인
     2-3. pfile 백업
  3. Cold Backup 수행
  4. DB 기동 후 SCN 변화 확인
  5. 시나리오 1 — 특정 데이터파일 손상 (리두 정보 있음, 완전 복구)
     5-1. 데이터 생성 및 장애 발생
     5-2. 장애 확인
     5-3. 복구 수행
     5-4. 복구 후 백업 갱신
  6. 시나리오 2 — 특정 데이터파일 손상 (리두 정보 없음, 불완전 복구)
     6-1. 데이터 변경 및 리두 강제 덮어쓰기
     6-2. 장애 발생 및 확인
     6-3. 복구 시도 → 완전 복구 실패
     6-4. 불완전 복구 — 마지막 백업 시점으로 전체 복원
  7. 관련 뷰 정리
  8. 주요 명령어 정리
  9. 실습 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. Cold Backup 개념 및 수행 조건
   ==========================================================================
   Cold Backup : DB를 정상 종료한 상태에서 수행하는 물리적 백업

   항목             | 내용
   -----------------+-------------------------------------------------------
   별칭             | Consistent Backup / Offline Backup / Close Backup
   수행 조건         | DB 정상 종료 후
                    | (shutdown normal / transactional / immediate)
   백업 대상         | Datafile + Controlfile + Redo Log File 전체
   적용 모드         | NOARCHIVELOG 환경에서 유일한 백업 수단
   복구 한계         | 마지막 백업 시점까지만 복구 가능
                    | (백업 이후 변경 데이터는 복구 불가)
   -----------------+-------------------------------------------------------

   ※ shutdown abort 사용 금지
     일관성 없는 상태로 종료되어 백업 자체가 무효가 됨
*/


/* ==========================================================================
   2. 백업 전 사전 확인
   ==========================================================================
*/

/* --------------------------------------------------------------------------
   2-1. 컨트롤 파일 단일화 (필요 시)
   --------------------------------------------------------------------------
   컨트롤 파일이 여러 경로에 다중화된 경우, 백업 부담을 줄이기 위해
   단일화 가능. scope=spfile 이므로 재기동 후 적용됨.

   ※ 다중화가 필요 없는 환경에서만 수행. 운영 환경에서는 권장하지 않음.
*/

-- [SYSDBA] 현재 컨트롤 파일 경로 확인
SHOW PARAMETER control_files;
-- NAME          TYPE   VALUE
-- ------------- ------ --------------------------------------------------
-- control_files string /u01/app/oracle/oradata/ORCL/control01.ctl,
--                      /u01/app/oracle/oradata/ORCL/control02.ctl

-- [SYSDBA] 컨트롤 파일 경로 단일화 (scope=spfile → 재기동 후 적용)
ALTER SYSTEM SET control_files = '/u01/app/oracle/oradata/ORCL/control01.ctl' SCOPE = SPFILE;

-- [SYSDBA] DB 재기동 후 단일화 적용 확인
SHUTDOWN IMMEDIATE;
STARTUP;

SHOW PARAMETER control_files;
-- NAME          TYPE   VALUE
-- ------------- ------ --------------------------------------------------
-- control_files string /u01/app/oracle/oradata/ORCL/control01.ctl


/* --------------------------------------------------------------------------
   2-2. 현재 SCN 및 파일별 체크포인트 확인
   --------------------------------------------------------------------------
   Cold Backup 수행 전에 현재 SCN(체크포인트 번호)과 파일 상태를 기록.
   이 값은 백업 시점의 기준점이 됨.

   checkpoint_change# : DB 마지막 체크포인트 시점의 SCN
   scn_to_timestamp() : SCN을 실제 시각으로 변환 (백업 기록용)
*/

-- [SYSDBA] DB 전체 체크포인트 SCN 확인
SELECT checkpoint_change# FROM v$database;
-- CHECKPOINT_CHANGE#
-- ------------------
--           2782733

-- [SYSDBA] SCN을 타임스탬프로 변환 (백업 기록용으로 보관 권장)
SELECT scn_to_timestamp(checkpoint_change#) FROM v$database;
-- SCN_TO_TIMESTAMP(CHECKPOINT_CHANGE#)
-- -----------------------------------------
-- 29-MAY-26 09.09.42.000000000 PM

-- [SYSDBA] 데이터파일별 체크포인트 SCN 확인
SELECT name, checkpoint_change#
FROM   v$datafile;
-- NAME                                               CHECKPOINT_CHANGE#
-- -------------------------------------------------- ------------------
-- /u01/app/oracle/oradata/ORCL/system01.dbf                     2782733
-- /u01/app/oracle/oradata/ORCL/audit_tbs01.dbf                  2782733
-- /u01/app/oracle/oradata/ORCL/sysaux01.dbf                     2782733
-- /u01/app/oracle/oradata/ORCL/undotbs01.dbf                    2782733
-- /u01/app/oracle/oradata/ORCL/users01.dbf                      2782733
-- /u01/app/oracle/oradata/ORCL/userdata01.dbf                   2782733
-- → 모든 파일의 SCN이 동일 → DB가 일관된 상태(Consistent)임을 의미

-- [SYSDBA] 리두 로그 그룹 상태 확인
SELECT group#, sequence#, status, archived
FROM   v$log;
-- GROUP#  SEQUENCE#  STATUS    ARC
-- ------  ---------  --------  ---
--      1         13  INACTIVE  YES
--      2         14  CURRENT   NO
--      3         12  INACTIVE  YES


/* --------------------------------------------------------------------------
   2-3. pfile 백업
   --------------------------------------------------------------------------
   spfile 기반으로 pfile을 생성하여 백업 디렉토리에 보관.
   복구 시 DB 기동을 위해 파라미터 정보를 별도 보존하는 용도.
*/

-- [SYSDBA] 현재 spfile 기반으로 pfile 생성 및 백업 디렉토리에 보관
CREATE PFILE = '/home/oracle/backup/noarch/initorcl.ora' FROM SPFILE;
-- File created.


/* ==========================================================================
   3. Cold Backup 수행
   ==========================================================================
   DB 정상 종료 후 OS 명령어로 데이터파일, 컨트롤파일, 리두로그 파일 전체 복사.

   ※ DB 종료 상태에서 cp 명령 실행 → 파일 일관성 보장
   ※ OS 명령어(!, cp)는 SQL*Plus 셸 이스케이프로 실행
*/

-- [SYSDBA] DB 정상 종료
SHUTDOWN IMMEDIATE;
-- Database closed.
-- Database dismounted.
-- ORACLE instance shut down.

-- [SYSDBA → Linux 셸] 데이터파일 경로로 이동 후 파일 목록 확인
! cd /u01/app/oracle/oradata/ORCL/ && ls
-- audit_tbs01.dbf  control01.ctl  redo01.log  redo02.log  redo03.log
-- sample_uni01.dbf  sysaux01.dbf  system01.dbf  temp01.dbf
-- undotbs01.dbf  userdata01.dbf  users01.dbf

-- [Linux 셸] 전체 파일 백업 (dbf + log + ctl)
! cp -v /u01/app/oracle/oradata/ORCL/*.{dbf,log,ctl} /home/oracle/backup/noarch/

-- [Linux 셸] 백업 결과 확인
! ls /home/oracle/backup/noarch/
-- audit_tbs01.dbf  control01.ctl  initorcl.ora  redo01.log  redo02.log  redo03.log
-- sample_uni01.dbf  sysaux01.dbf  system01.dbf  temp01.dbf
-- undotbs01.dbf  userdata01.dbf  users01.dbf


/* ==========================================================================
   4. DB 기동 후 SCN 변화 확인
   ==========================================================================
   백업 후 DB를 기동하면 인스턴스 리커버리가 수행되어 체크포인트 SCN이 증가.
   백업본의 SCN과 현재 SCN의 차이만큼 리두 정보가 쌓여 있는 상태가 됨.
*/

-- [SYSDBA] DB 기동
STARTUP;
-- ORACLE instance started.
-- Database mounted.
-- Database opened.

-- [SYSDBA] 기동 후 SCN 확인 (백업 시점 2782733보다 증가)
SELECT checkpoint_change# FROM v$database;
-- CHECKPOINT_CHANGE#
-- ------------------
--           2783948

-- [SYSDBA] 데이터파일별 SCN도 함께 증가 확인
SELECT name, checkpoint_change#
FROM   v$datafile;
-- NAME                                               CHECKPOINT_CHANGE#
-- -------------------------------------------------- ------------------
-- /u01/app/oracle/oradata/ORCL/system01.dbf                     2783948
-- /u01/app/oracle/oradata/ORCL/audit_tbs01.dbf                  2783948
-- /u01/app/oracle/oradata/ORCL/sysaux01.dbf                     2783948
-- /u01/app/oracle/oradata/ORCL/undotbs01.dbf                    2783948
-- /u01/app/oracle/oradata/ORCL/users01.dbf                      2783948
-- /u01/app/oracle/oradata/ORCL/userdata01.dbf                   2783948
-- → 백업본(2782733)과 현재(2783948) 간 리두 정보가 온라인 리두 로그에 존재
-- → 이 범위 내 장애 발생 시 → 완전 복구 가능 (시나리오 1)
-- → 로그 스위치 후 리두 overwrite 시  → 완전 복구 불가 (시나리오 2)


/* ==========================================================================
   5. 시나리오 1 — 특정 데이터파일 손상 (리두 정보 있음, 완전 복구)
   ==========================================================================
   조건 : 백업 이후 변경 데이터에 대한 리두 정보가
          현재 온라인 리두 로그 내에 아직 남아있는 상태

   복구 흐름
   -------------------------------------------------------------------------
   ① 장애 발생 (데이터파일 삭제)
   ② STARTUP → ORA-01157 발생 → MOUNTED 상태로 대기
   ③ OFFLINE DROP → OPEN
   ④ OS에서 백업본 복사 (restore)
   ⑤ RECOVER DATAFILE → 온라인 리두 로그 적용
   ⑥ ONLINE 전환 → 데이터 확인
   ⑦ 복구 완료 후 백업 갱신
   -------------------------------------------------------------------------
*/

/* --------------------------------------------------------------------------
   5-1. 데이터 생성 및 장애 발생
*/

-- [HR 계정] 테스트 테이블 및 데이터 생성
CONN hr/hr

CREATE TABLE emp_temp (id NUMBER) TABLESPACE users;

INSERT INTO emp_temp (id) VALUES (1);
COMMIT;

SELECT * FROM emp_temp;
-- ID
-- ----------
--  1

-- [SYSDBA] DB 종료 후 users01.dbf 삭제 (장애 재현)
CONN / AS SYSDBA

SHUTDOWN IMMEDIATE;
-- Database closed.
-- Database dismounted.
-- ORACLE instance shut down.

-- [Linux 셸] 데이터파일 강제 삭제
! rm /u01/app/oracle/oradata/ORCL/users01.dbf


/* --------------------------------------------------------------------------
   5-2. 장애 확인
   --------------------------------------------------------------------------
   파일 없이 STARTUP 시도 → ORA-01157 발생 → MOUNTED 상태에서 중단.
   v$recover_file : 복구 필요 파일 목록 확인.

   ORA-01157 : cannot identify/lock data file N
   → N번 파일을 찾을 수 없거나 잠글 수 없는 상태
*/

-- [SYSDBA] 기동 시도 → ORA-01157 발생
STARTUP;
-- Database mounted.
-- ORA-01157: cannot identify/lock data file 7 - see DBWR trace file
-- ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'

-- [Linux 셸] 파일 없음 확인
! ls /u01/app/oracle/oradata/ORCL/users01.dbf
-- ls: cannot access /u01/app/oracle/oradata/ORCL/users01.dbf: No such file or directory

-- [SYSDBA] 인스턴스 현재 상태 확인 → MOUNTED
SELECT status FROM v$instance;
-- STATUS
-- ------------
-- MOUNTED

-- [SYSDBA] 복구 필요 파일 조회
SELECT * FROM v$recover_file;
-- FILE#  ONLINE  ERROR           CHANGE#
-- -----  ------  --------------- -------
--     7  ONLINE  FILE NOT FOUND        0


/* --------------------------------------------------------------------------
   5-3. 복구 수행
   --------------------------------------------------------------------------
   NOARCHIVELOG 모드에서 데이터파일을 오프라인 처리할 때 반드시
   OFFLINE DROP 사용. OFFLINE만 사용하면 이후 ONLINE 복귀 불가.

   복구 순서
   ① OFFLINE DROP → OPEN (DB를 일단 열어 서비스 재개)
   ② OS에서 백업본 파일 복사 (restore)
   ③ RECOVER DATAFILE (온라인 리두 로그의 변경분 적용)
   ④ ONLINE 전환
*/

-- [SYSDBA] 손상 파일 OFFLINE DROP 후 DB OPEN
ALTER DATABASE DATAFILE 7 OFFLINE DROP;
-- Database altered.

ALTER DATABASE OPEN;
-- Database altered.

-- [Linux 셸] 백업본에서 해당 파일 복사 (restore)
! cp -v /home/oracle/backup/noarch/users01.dbf /u01/app/oracle/oradata/ORCL/users01.dbf
-- '/home/oracle/backup/noarch/users01.dbf' -> '/u01/app/oracle/oradata/ORCL/users01.dbf'

-- [SYSDBA] 백업 이후 변경된 리두 정보 적용 (온라인 리두 로그 범위 내)
RECOVER DATAFILE 7;
-- Media recovery complete.

-- [SYSDBA] 파일 상태 확인 → 복구 완료 파일은 OFFLINE 상태
SELECT file#, name, status
FROM   v$datafile;
-- FILE#  NAME                                               STATUS
-- -----  -------------------------------------------------- -------
--     1  /u01/app/oracle/oradata/ORCL/system01.dbf          SYSTEM
--     2  /u01/app/oracle/oradata/ORCL/audit_tbs01.dbf       ONLINE
--     3  /u01/app/oracle/oradata/ORCL/sysaux01.dbf          ONLINE
--     4  /u01/app/oracle/oradata/ORCL/undotbs01.dbf         ONLINE
--     7  /u01/app/oracle/oradata/ORCL/users01.dbf           OFFLINE  ← 복구 후에도 OFFLINE
--    11  /u01/app/oracle/oradata/ORCL/userdata01.dbf        ONLINE

-- [SYSDBA] 파일 ONLINE 전환
ALTER DATABASE DATAFILE 7 ONLINE;
-- Database altered.

-- [SYSDBA] 복구 검증 — 데이터 정상 조회 확인
SELECT * FROM hr.emp_temp;
-- ID
-- ----------
--  1


/* --------------------------------------------------------------------------
   5-4. 복구 후 백업 갱신
   --------------------------------------------------------------------------
   복구 완료 후 즉시 새 Cold Backup 수행.
   이전 백업본은 복구가 적용된 상태가 아니므로 반드시 교체해야 함.
*/

-- [SYSDBA] DB 종료
SHUTDOWN IMMEDIATE;
-- Database closed.
-- Database dismounted.
-- ORACLE instance shut down.

-- [Linux 셸] 기존 백업 전체 삭제
! rm -rf /home/oracle/backup/noarch/*

-- [Linux 셸] 최신 상태로 새 백업 수행
! cp -v /u01/app/oracle/oradata/ORCL/*.{dbf,log,ctl} /home/oracle/backup/noarch/
! ls /home/oracle/backup/noarch/
-- audit_tbs01.dbf  control01.ctl  redo01.log  redo02.log  redo03.log
-- sample_uni01.dbf  sysaux01.dbf  system01.dbf  temp01.dbf
-- undotbs01.dbf  userdata01.dbf  users01.dbf

-- [SYSDBA] pfile도 새로 생성
STARTUP;

CREATE PFILE = '/home/oracle/backup/noarch/initorcl.ora' FROM SPFILE;
-- File created.


/* ==========================================================================
   6. 시나리오 2 — 특정 데이터파일 손상 (리두 정보 없음, 불완전 복구)
   ==========================================================================
   조건 : 백업 이후 로그 스위치가 여러 번 발생하여
          백업 당시의 리두 정보가 온라인 로그에서 이미 overwrite된 상태

   NOARCHIVELOG 모드에서는 아카이브 로그가 없으므로 완전 복구 불가.
   마지막 백업 시점으로 DB 전체를 되돌리는 것만 가능.
   백업 이후의 모든 변경 데이터는 손실됨.

   복구 흐름
   -------------------------------------------------------------------------
   ① 장애 발생 (데이터파일 삭제)
   ② STARTUP → ORA-01157 발생
   ③ OFFLINE DROP → OPEN
   ④ 백업본 복사 후 RECOVER DATAFILE 시도
      → ORA-00308: 아카이브 로그 없음 → 완전 복구 실패
   ⑤ SHUTDOWN → 백업본 전체 복원 (불완전 복구)
   ⑥ STARTUP → 백업 시점 데이터만 복원됨
   -------------------------------------------------------------------------
*/

/* --------------------------------------------------------------------------
   6-1. 데이터 변경 및 리두 강제 덮어쓰기
   --------------------------------------------------------------------------
   추가 데이터를 입력 후 ALTER SYSTEM SWITCH LOGFILE을 반복 실행하여
   기존 리두 정보를 overwrite.
   리두 로그는 3개 그룹이 순환하므로 3회 이상 스위치 시 이전 시퀀스 덮어쓰임.
*/

-- [SYSDBA] 현재 SCN 확인 (시나리오 2 시작 기준점)
SELECT checkpoint_change# FROM v$database;
-- CHECKPOINT_CHANGE#
-- ------------------
--           2789549

-- [SYSDBA → HR 권한 부여 후 HR 계정으로 데이터 추가]
CONN hr/hr

INSERT INTO emp_temp (id) VALUES (2);
COMMIT;

SELECT * FROM emp_temp;
-- ID
-- ----------
--  1
--  2

-- [HR 계정] 해당 데이터가 어느 파일에 저장되는지 확인
SELECT f.file_name
FROM   dba_extents e, dba_data_files f
WHERE  e.file_id    = f.file_id
AND    e.segment_name = 'EMP_TEMP';
-- FILE_NAME
-- ------------------------------------------------
-- /u01/app/oracle/oradata/ORCL/users01.dbf

-- [SYSDBA] 로그 스위치 반복 → 기존 리두 정보 overwrite
CONN / AS SYSDBA

ALTER SYSTEM SWITCH LOGFILE;
/
/
/

-- [SYSDBA] 시퀀스 번호 변화 확인 (기존 리두 로그가 새 시퀀스로 교체됨)
SELECT group#, sequence#, status
FROM   v$log;
-- GROUP#  SEQUENCE#  STATUS
-- ------  ---------  --------
--      1         19  INACTIVE
--      2         20  CURRENT
--      3         18  INACTIVE
-- → 백업 직후 시퀀스(14 등)는 이미 덮어쓰인 상태


/* --------------------------------------------------------------------------
   6-2. 장애 발생 및 확인
*/

-- [SYSDBA] DB 종료 후 users01.dbf 삭제
SHUTDOWN IMMEDIATE;

-- [Linux 셸] 데이터파일 강제 삭제
! rm /u01/app/oracle/oradata/ORCL/users01.dbf
! ls -l /u01/app/oracle/oradata/ORCL/users01.dbf
-- ls: cannot access /u01/app/oracle/oradata/ORCL/users01.dbf: No such file or directory

-- [SYSDBA] 기동 시도 → 동일하게 ORA-01157 발생
STARTUP;
-- Database mounted.
-- ORA-01157: cannot identify/lock data file 7 - see DBWR trace file
-- ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'

-- [SYSDBA] 복구 필요 파일 확인
SELECT * FROM v$recover_file;
-- FILE#  ONLINE  ERROR           CHANGE#
-- -----  ------  --------------- -------
--     7  ONLINE  FILE NOT FOUND        0


/* --------------------------------------------------------------------------
   6-3. 복구 시도 → 완전 복구 실패
   --------------------------------------------------------------------------
   OFFLINE DROP 후 OPEN, 백업본 복사까지는 시나리오 1과 동일.
   그러나 RECOVER DATAFILE 시도 시 아카이브 로그 파일을 찾지 못해 실패.
   NOARCHIVELOG 모드에서 로그 overwrite 이후의 변경분은 복구 불가.
*/

-- [SYSDBA] OFFLINE DROP 후 DB OPEN
ALTER DATABASE DATAFILE 7 OFFLINE DROP;
ALTER DATABASE OPEN;

-- [SYSDBA] 다른 테이블스페이스의 데이터는 정상 조회 가능
SELECT COUNT(*) FROM hr.employees;
--  COUNT(*)
-- ----------
--        107

-- [SYSDBA] 손상 파일에 속한 테이블은 접근 불가
SELECT * FROM hr.emp_temp;
-- ERROR at line 1:
-- ORA-00376: file 7 cannot be read at this time
-- ORA-01110: data file 7: '/u01/app/oracle/oradata/ORCL/users01.dbf'

-- [Linux 셸] 백업본 파일 복사 (restore)
! cp -v /home/oracle/backup/noarch/users01.dbf /u01/app/oracle/oradata/ORCL/users01.dbf

-- [SYSDBA] RECOVER DATAFILE 시도 → 아카이브 로그 없음으로 실패
RECOVER DATAFILE 7;
-- ORA-00279: change 2789546 generated at 05/29/2026 21:58:57 needed for thread 1
-- ORA-00289: suggestion : /home/oracle/arch2/arch_1_14_1225825003.arc
-- ORA-00280: change 2789546 for thread 1 is in sequence #14
-- Specify log: {<RET>=suggested | filename | AUTO | CANCEL}
-- auto
-- ORA-00308: cannot open archived log '/home/oracle/arch2/arch_1_14_1225825003.arc'
-- ORA-27037: unable to obtain file status
-- Linux-x86_64 Error: 2: No such file or directory
-- → 완전 복구 실패
-- → NOARCHIVELOG 모드에서 로그 스위치로 리두가 overwrite되면 미디어 복구 불가


/* --------------------------------------------------------------------------
   6-4. 불완전 복구 — 마지막 백업 시점으로 전체 복원
   --------------------------------------------------------------------------
   완전 복구가 불가능하면 컨트롤파일, 데이터파일, 리두로그 파일 전부를
   백업본으로 교체하여 마지막 백업 시점 상태로 복원.
   백업 이후에 입력된 모든 변경 데이터는 영구 손실됨.

   ※ 단일 파일만 복원하면 컨트롤파일 SCN과 불일치가 발생할 수 있음
     → 반드시 전체 파일을 일괄 교체해야 함
*/

-- [SYSDBA] DB 종료
SHUTDOWN IMMEDIATE;
-- Database closed.
-- Database dismounted.
-- ORACLE instance shut down.

-- [Linux 셸] 백업본 전체를 현재 경로로 복사 (모든 파일 교체)
! cp -v /home/oracle/backup/noarch/*.{dbf,log,ctl} /u01/app/oracle/oradata/ORCL/

-- [SYSDBA] DB 기동
STARTUP;
-- ORACLE instance started.
-- Database mounted.
-- Database opened.

-- [SYSDBA] 복원 결과 확인 — 백업 시점(id=1)만 복원, id=2는 손실
SELECT * FROM hr.emp_temp;
-- ID
-- ----------
--  1
-- → id=2 : 백업 이후 입력된 데이터이므로 복원되지 않음 (NOARCHIVELOG 복구 한계)

-- [SYSDBA] 복원 후 SCN 확인 (백업 시점 SCN으로 돌아옴)
SELECT checkpoint_change# FROM v$database;
-- CHECKPOINT_CHANGE#
-- ------------------
--           2783948   ← 시나리오 2 시작 전(2789549)보다 낮은 값으로 복원


/* ==========================================================================
   7. 관련 뷰 정리
   ==========================================================================

   뷰 / 함수                              | 조회 목적
   ---------------------------------------+------------------------------------
   v$database                            | checkpoint_change# — DB 전체 체크포인트 SCN
   v$datafile                            | 파일별 checkpoint_change#, status 확인
   v$log                                 | 리두 로그 그룹 상태
                                         | (CURRENT / INACTIVE / ACTIVE)
   v$recover_file                        | 복구 필요 파일 목록 및 에러 정보
   v$instance                            | 현재 인스턴스 상태 (MOUNTED / OPEN 등)
   dba_extents                           | 세그먼트 저장 위치 (file_id 기준)
   dba_data_files                        | 데이터파일 목록 및 경로
   scn_to_timestamp(scn)                 | SCN → 타임스탬프 변환
   ---------------------------------------+------------------------------------
*/


/* ==========================================================================
   8. 주요 명령어 정리
   ==========================================================================

   명령어 / 구문                                   | 설명
   -----------------------------------------------+-----------------------------
   SHUTDOWN IMMEDIATE                             | DB 정상 종료 (Cold Backup 전제)
   SHUTDOWN ABORT                                 | 비정상 종료 — Cold Backup 시 사용 금지
   CREATE PFILE='경로' FROM SPFILE                 | spfile → pfile 변환 및 백업
   ALTER SYSTEM SET control_files='..' SCOPE=SPFILE| 컨트롤 파일 경로 변경 (재기동 후 적용)
   ALTER DATABASE DATAFILE n OFFLINE DROP         | 손상 파일 오프라인 (NOARCHIVELOG 전용)
   ALTER DATABASE DATAFILE n OFFLINE              | 손상 파일 오프라인 (ARCHIVELOG 전용)
   ALTER DATABASE OPEN                            | 파일 오프라인 후 DB 오픈
   RECOVER DATAFILE n                             | 특정 데이터파일 미디어 복구
   ALTER DATABASE DATAFILE n ONLINE               | 복구 완료 파일 온라인 전환
   ALTER SYSTEM SWITCH LOGFILE                    | 수동 로그 스위치
   -----------------------------------------------+-----------------------------

   OS 명령어
   -----------------------------------------------+-----------------------------
   cp -v *.{dbf,log,ctl} /백업경로/               | Cold Backup 수행
   rm -rf /백업경로/*                             | 기존 백업 삭제
   -----------------------------------------------+-----------------------------
*/


/* ==========================================================================
   9. 실습 핵심 요약
   ==========================================================================

   주제                  | 핵심 포인트
   ----------------------+---------------------------------------------------
   Cold Backup 조건       | shutdown abort 제외한 정상 종료 후 수행
                         | DB 일관성(Consistent) 보장이 필수
   ----------------------+---------------------------------------------------
   OFFLINE DROP          | NOARCHIVELOG 모드에서 파일 offline 처리 시
                         | 반드시 OFFLINE DROP 사용 (OFFLINE만이면 복귀 불가)
   ----------------------+---------------------------------------------------
   시나리오 1 (완전 복구)  | 리두가 온라인 로그에 남아있으면
                         | RECOVER DATAFILE → ONLINE 순서로 완전 복구 가능
   ----------------------+---------------------------------------------------
   시나리오 2 (불완전 복구) | 로그 스위치로 리두 overwrite 시 완전 복구 불가
                         | 전체 파일 백업본으로 교체 → 백업 시점으로만 복원
   ----------------------+---------------------------------------------------
   복구 후 처리           | 복구 완료 즉시 새 Cold Backup 수행
                         | 백업 갱신 없이 운영 재개하면 다음 장애 복구 불가
   ----------------------+---------------------------------------------------
*/
