/*
================================================================================
  Backup & Recovery 실습 04
  — 노아카이브 모드에서 TX 중 Undo 손상, Temp 파일 손상, 전체 디스크 손상 복구 (9~11)
================================================================================
  Blog  : https://nsylove97.tistory.com/60
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
  - /home/oracle/backup/noarch/ 에 Cold Backup이 사전 완료되어 있음
    (시나리오 11 에서 사용)
  - BNR 실습 03 완료 후 환경 기준
  - HR 계정이 활성화되어 있고 employees 테이블이 존재하는 상태
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. 시나리오 9  — TX 진행 중 Undo 데이터파일 손상 (리두 정보 X)
     1-1. 사전 확인 — 데이터파일 / Undo 세그먼트 상태
     1-2. TX 발생 (HR 세션)
     1-3. TX 사용 중인 Undo 세그먼트 확인 (SYS 세션)
     1-4. 리두 정보 덮어쓰기 (로그 스위치 반복)
     1-5. 장애 발생 — Undo 파일 삭제
     1-6. 장애 확인
     1-7. 복구 — Undo 파일 offline drop → DB OPEN
     1-8. NEEDS RECOVERY 세그먼트 DROP 시도 → 실패
     1-9. _offline_rollback_segments 파라미터로 강제 offline 후 DROP
     1-10. 결과 확인

  2. 시나리오 10 — Temp 파일 손상
     2-1. 사전 확인 — Temp 파일 / 테이블스페이스 상태
     2-2. 장애 발생 — Temp 파일 삭제
     2-3. 장애 확인 — 정렬 쿼리 오류
     2-4. 복구 — 새 Temp 파일 추가 후 손상 파일 제거
     2-5. Temp 파일 자동 재생성 확인
     2-6. 새 Temp Tablespace 생성 및 Default 전환 방법

  3. 시나리오 11 — 모든 데이터파일 / 컨트롤파일 / 리두로그파일이 있는 디스크 손상
     3-1. 사전 확인 및 pfile 생성
     3-2. 복구 경로 준비 — pfile에서 컨트롤파일 경로 수정
     3-3. 장애 발생 — 원본 경로 파일 전체 삭제
     3-4. 장애 확인 — 컨트롤파일 인식 불가
     3-5. 복구 — 새 경로로 백업본 복원
     3-6. pfile로 MOUNT까지 기동
     3-7. RENAME — 데이터파일 / 리두로그 / Temp 파일 경로 변경
     3-8. ALTER DATABASE OPEN 및 결과 확인

  4. 관련 뷰 정리
  5. 주요 명령어 정리
  6. 실습 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. 시나리오 9 — TX 진행 중 Undo 데이터파일 손상 (리두 정보 X)
   ==========================================================================
   시나리오 8과 동일하게 Undo 데이터파일이 손상되지만,
   이번에는 트랜잭션(TX)이 진행 중인 상태에서 장애가 발생한다는 점이 다름

   핵심 차이 포인트
   -------------------------------------------------------------------------
   항목               | 시나리오 8                 | 시나리오 9
   -------------------|---------------------------|---------------------------
   TX 상태             | TX 없음 (idle 상태)        | TX 진행 중 (commit 전)
   리두 정보           | 없음                       | 없음 (로그 스위치로 덮어씀)
   NEEDS RECOVERY      | 발생                       | 발생
   DROP 가능 여부       | _corrupted_rollback_segments | _offline_rollback_segments
   -------------------------------------------------------------------------
   ※ 시나리오 8: _corrupted_rollback_segments (히든 파라미터명 차이에 주의)
   ※ 시나리오 9: _offline_rollback_segments
   -------------------------------------------------------------------------
*/

/* --------------------------------------------------------------------------
   1-1. 사전 확인 — 데이터파일 / Undo 세그먼트 상태
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 데이터파일 목록 및 상태 확인
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change# AS ck, a.status
FROM v$datafile a, v$tablespace b
WHERE a.ts# = b.ts#;

/*
  [예상 결과]
  FILE# TBS_NAME   FILE_NAME                                              CK       STATUS
  ----- ---------- ------------------------------------------------------ -------- -------
      1 SYSTEM     /u01/app/oracle/oradata/ORCL/system01.dbf              2922128  SYSTEM
      3 SYSAUX     /u01/app/oracle/oradata/ORCL/sysaux01.dbf              2922128  ONLINE
      4 UNDOTBS1   /u01/app/oracle/oradata/ORCL/undotbs01.dbf             2922128  ONLINE
      7 USERS      /u01/app/oracle/oradata/ORCL/users01.dbf               2922128  ONLINE
*/

-- [SQL*Plus — SYSDBA] Undo 세그먼트 상태 확인
SELECT segment_id, segment_name, owner, tablespace_name, status
FROM dba_rollback_segs;

/*
  [예상 결과]
  SEGMENT_ID SEGMENT_NAME             OWNER  TABLESPACE_NAME STATUS
  ---------- ------------------------ ------ --------------- -------
           0 SYSTEM                   SYS    SYSTEM          ONLINE
           1 _SYSSMU1_1261223759$     PUBLIC UNDOTBS1        ONLINE
           ...
          10 _SYSSMU10_930580995$     PUBLIC UNDOTBS1        ONLINE
*/

-- [SQL*Plus — SYSDBA] 현재 진행 중인 TX 확인 (초기 — 없음)
SELECT s.username, s.sid, s.serial#, t.xidusn undo_seg_num, r.name undo_seg_name,
       t.ubafil undo_datafile_num, t.ubablk undo_block, t.used_ublk
FROM v$session s, v$transaction t, v$rollname r
WHERE s.taddr = t.addr AND t.xidusn = r.usn;
-- no rows selected


/* --------------------------------------------------------------------------
   1-2. TX 발생 (HR 세션)
   --------------------------------------------------------------------------
   아래 명령은 HR 계정으로 접속된 별도 세션에서 실행
   commit 하지 않고 TX를 유지 상태로 남겨둠
   -------------------------------------------------------------------------- */

-- [SQL*Plus — HR 계정] 변경 전 급여 확인
SELECT salary FROM employees WHERE employee_id = 102;
/*
  SALARY
  ------
   17000
*/

-- [SQL*Plus — HR 계정] 급여 업데이트 후 커밋하지 않음 — TX 유지
UPDATE employees SET salary = salary * 1.1 WHERE employee_id = 102;
-- 1 row updated.
-- ※ commit 하지 않음 — TX 유지 상태


/* --------------------------------------------------------------------------
   1-3. TX 사용 중인 Undo 세그먼트 확인 (SYS 세션)
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 진행 중인 TX 및 사용 Undo 세그먼트 조회
SELECT s.username, s.sid, s.serial#, t.xidusn undo_seg_num, r.name undo_seg_name,
       t.ubafil undo_datafile_num, t.ubablk undo_block, t.used_ublk
FROM v$session s, v$transaction t, v$rollname r
WHERE s.taddr = t.addr AND t.xidusn = r.usn;

/*
  [예상 결과]
  USERNAME SID  SERIAL# UNDO_SEG_NUM UNDO_SEG_NAME           UNDO_DATAFILE_NUM UNDO_BLOCK USED_UBLK
  -------- ---- ------- ------------ ----------------------- ----------------- ---------- ---------
  HR         36   32073            9 _SYSSMU9_2100413762$                    2        468         1

  ※ UNDO_DATAFILE_NUM: 2 → file# 4 (UNDOTBS1) 를 사용 중임을 의미
  ※ 이 세그먼트 번호를 기록해 둘 것 — 이후 _offline_rollback_segments 작성 시 사용
*/


/* --------------------------------------------------------------------------
   1-4. 리두 정보 덮어쓰기 (로그 스위치 반복)
   --------------------------------------------------------------------------
   로그 스위치를 반복하여 TX 관련 리두 정보를 덮어씀
   → 이후 복구 시 RECOVER 불가 상태를 재현
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA]
ALTER SYSTEM SWITCH LOGFILE;
/
/


/* --------------------------------------------------------------------------
   1-5. 장애 발생 — Undo 파일 삭제
   --------------------------------------------------------------------------
   아래 명령은 SQL*Plus 밖 Linux 셸에서 실행
   -------------------------------------------------------------------------- */

-- # [oracle 계정 — Linux 셸]
-- rm /u01/app/oracle/oradata/ORCL/undotbs01.dbf


/* --------------------------------------------------------------------------
   1-6. 장애 확인
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 체크포인트 시도 → DB 비정상 종료 유발
ALTER SYSTEM CHECKPOINT;
-- ORA-03113: end-of-file on communication channel

-- [SQL*Plus — SYSDBA] 재접속 후 기동 시도
CONN / AS SYSDBA
-- Connected to an idle instance.

STARTUP;
/*
  ORA-01157: cannot identify/lock data file 4
  ORA-01110: data file 4: '/u01/app/oracle/oradata/ORCL/undotbs01.dbf'
  → MOUNT 단계에서 Undo 파일을 찾지 못해 OPEN 실패
*/

-- [SQL*Plus — SYSDBA] 복구 대상 파일 확인
SELECT * FROM v$recover_file;
/*
  [예상 결과]
  FILE# ONLINE  ONLINE_ ERROR          CHANGE# TIME  CON_ID
  ----- ------- ------- -------------- ------- ----- ------
      4 ONLINE  ONLINE  FILE NOT FOUND       0             0
*/


/* --------------------------------------------------------------------------
   1-7. 복구 — Undo 파일 offline drop → DB OPEN
   --------------------------------------------------------------------------
   No Archive 모드에서는 RECOVER 없이 offline drop 후 OPEN
   → NEEDS RECOVERY 상태로 UNDO 세그먼트가 남게 됨
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA]
ALTER DATABASE DATAFILE 4 OFFLINE DROP;
-- 또는: ALTER DATABASE DATAFILE '/u01/app/oracle/oradata/ORCL/undotbs01.dbf' OFFLINE DROP;

ALTER DATABASE OPEN;
-- Database altered.

-- [SQL*Plus — SYSDBA] Undo 세그먼트 상태 확인 — NEEDS RECOVERY 확인
SELECT segment_id, segment_name, owner, tablespace_name, status
FROM dba_rollback_segs;

/*
  [예상 결과]
  SEGMENT_ID SEGMENT_NAME             OWNER  TABLESPACE_NAME STATUS
  ---------- ------------------------ ------ --------------- ----------------
           0 SYSTEM                   SYS    SYSTEM          ONLINE
           1 _SYSSMU1_1261223759$     PUBLIC UNDOTBS1        NEEDS RECOVERY
           ...
          10 _SYSSMU10_930580995$     PUBLIC UNDOTBS1        NEEDS RECOVERY

  ※ 시나리오 8(TX 없음)과 달리 TX가 진행 중이었기 때문에
    오라클이 해당 TX를 자동으로 롤백하지 못한 채 NEEDS RECOVERY 상태 유지
*/

-- [SQL*Plus — SYSDBA] TX 해소 확인 (위 TX 조회 쿼리 재실행)
SELECT s.username, s.sid, s.serial#, t.xidusn undo_seg_num, r.name undo_seg_name,
       t.ubafil undo_datafile_num, t.ubablk undo_block, t.used_ublk
FROM v$session s, v$transaction t, v$rollname r
WHERE s.taddr = t.addr AND t.xidusn = r.usn;
-- no rows selected
-- ※ TX는 DB OPEN 과정에서 강제 해소됨


/* --------------------------------------------------------------------------
   1-8. 새 Undo 테이블스페이스 생성 및 전환
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 새 Undo 테이블스페이스 생성
CREATE UNDO TABLESPACE undo1
DATAFILE '/u01/app/oracle/oradata/ORCL/undo01.dbf' SIZE 100M AUTOEXTEND ON;
-- Tablespace created.

-- [SQL*Plus — SYSDBA] Undo 테이블스페이스 전환
ALTER SYSTEM SET undo_tablespace = undo1;
-- System altered.

-- [SQL*Plus — SYSDBA] 전환 후 Undo 세그먼트 확인
SELECT segment_id, segment_name, owner, tablespace_name, status
FROM dba_rollback_segs;
/*
  [예상 결과]
  SEGMENT_ID SEGMENT_NAME             OWNER  TABLESPACE_NAME STATUS
  ---------- ------------------------ ------ --------------- ----------------
           0 SYSTEM                   SYS    SYSTEM          ONLINE
           1 _SYSSMU1_1261223759$     PUBLIC UNDOTBS1        NEEDS RECOVERY
           ...
          10 _SYSSMU10_930580995$     PUBLIC UNDOTBS1        NEEDS RECOVERY
          11 _SYSSMU11_2468800258$    PUBLIC UNDO1           ONLINE
           ...
          20 _SYSSMU20_861131726$     PUBLIC UNDO1           ONLINE

  ※ UNDO1 세그먼트가 ONLINE 상태로 신규 TX에 정상 사용됨
*/


/* --------------------------------------------------------------------------
   1-9. NEEDS RECOVERY 세그먼트 DROP 시도 → 실패
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 기존 UNDOTBS1 DROP 시도
DROP TABLESPACE undotbs1 INCLUDING CONTENTS AND DATAFILES;
/*
  ORA-01548: active rollback segment '_SYSSMU1_1261223759$' found,
             terminate dropping tablespace
  → NEEDS RECOVERY 상태의 롤백 세그먼트가 있으면 DROP 불가
*/


/* --------------------------------------------------------------------------
   1-10. _offline_rollback_segments 파라미터로 강제 offline 후 DROP
   --------------------------------------------------------------------------
   절차
   ① NEEDS RECOVERY 세그먼트 목록 조회
   ② pfile 생성 후 DB 종료
   ③ pfile에 _offline_rollback_segments 히든 파라미터 추가
   ④ pfile로 DB 기동
   ⑤ DROP TABLESPACE 수행
   ⑥ spfile 재생성 후 정상 기동

   ※ _offline_rollback_segments: TX가 활성 중이었던 세그먼트에 사용
   ※ _corrupted_rollback_segments(시나리오 8): TX가 없던 세그먼트에 사용
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] NEEDS RECOVERY 세그먼트 목록 조회
-- 아래 결과를 복사하여 pfile의 _offline_rollback_segments 값에 붙여넣을 것
SELECT segment_name || ',' FROM dba_rollback_segs WHERE status = 'NEEDS RECOVERY';
/*
  [예상 결과]
  _SYSSMU1_1261223759$,
  _SYSSMU2_27624015$,
  ...
  _SYSSMU10_930580995$,
*/

-- [SQL*Plus — SYSDBA] pfile 생성 후 DB 종료
CREATE PFILE FROM SPFILE;
-- File created.

SHUTDOWN IMMEDIATE;


/*
  ---- Linux 셸 작업 ----
  # [oracle 계정 — Linux 셸]
  # pfile에 _offline_rollback_segments 파라미터 추가
  # vi $ORACLE_HOME/dbs/initorcl.ora
  #
  # 파일 하단에 아래 내용 추가 (세그먼트 이름은 위 조회 결과 기준)
  # _offline_rollback_segments=(
  # '_SYSSMU1_1261223759$',
  # '_SYSSMU2_27624015$',
  # '_SYSSMU3_2421748942$',
  # '_SYSSMU4_625702278$',
  # '_SYSSMU5_2101348960$',
  # '_SYSSMU6_813816332$',
  # '_SYSSMU7_2329891355$',
  # '_SYSSMU8_399776867$',
  # '_SYSSMU9_1692468413$',
  # '_SYSSMU10_930580995$')
  ----------------------
*/

-- [SQL*Plus — SYSDBA] pfile로 기동
STARTUP PFILE='$ORACLE_HOME/dbs/initorcl.ora';
-- ORACLE instance started.
-- Database mounted.
-- Database opened.

-- [SQL*Plus — SYSDBA] pfile 기동 확인 (SPFILE VALUE 가 공백이면 pfile 기동 중)
SHOW PARAMETER SPFILE;
/*
  NAME   TYPE   VALUE
  ------ ------ -----
  spfile string        -- (빈값 확인)
*/

-- [SQL*Plus — SYSDBA] 기존 UNDOTBS1 DROP
DROP TABLESPACE undotbs1 INCLUDING CONTENTS AND DATAFILES;
-- Tablespace dropped.

-- [SQL*Plus — SYSDBA] 결과 확인 — UNDOTBS1 제거 / UNDO1 정상 운영
SELECT a.file#, b.name tbs_name, a.name file_name, a.checkpoint_change#, a.status
FROM v$datafile a, v$tablespace b
WHERE a.ts# = b.ts#;
/*
  [예상 결과]
  FILE# TBS_NAME   FILE_NAME                                              CHECKPOINT_CHANGE# STATUS
  ----- ---------- ------------------------------------------------------ ------------------ -------
      1 SYSTEM     /u01/app/oracle/oradata/ORCL/system01.dbf                         3025022 SYSTEM
      3 SYSAUX     /u01/app/oracle/oradata/ORCL/sysaux01.dbf                         3025022 ONLINE
      5 UNDO1      /u01/app/oracle/oradata/ORCL/undo01.dbf                           3025022 ONLINE
      7 USERS      /u01/app/oracle/oradata/ORCL/users01.dbf                          3025022 ONLINE
  ※ UNDOTBS1 제거 완료, UNDO1으로 정상 운영 중
*/

-- [SQL*Plus — SYSDBA] pfile에서 _offline_rollback_segments 제거 후 spfile 재생성
CREATE SPFILE FROM PFILE;
-- File created.

/*
  ---- Linux 셸 작업 ----
  # [oracle 계정 — Linux 셸]
  # pfile에서 추가했던 _offline_rollback_segments 항목 삭제 후 저장
  # vi $ORACLE_HOME/dbs/initorcl.ora
  ----------------------
*/

-- [SQL*Plus — SYSDBA] 정상 spfile로 재기동
SHUTDOWN IMMEDIATE;
STARTUP;


/* ==========================================================================
   2. 시나리오 10 — Temp 파일 손상
   ==========================================================================
   Temp 파일은 정렬, 해시 조인 등 임시 작업에 사용됨
   손상 시 정렬이 필요한 쿼리에서 오류가 발생하며, DB를 내리지 않고 복구 가능

   복구 원칙
   -------------------------------------------------------------------------
   항목           | 내용
   ---------------|-------------------------------------------------------
   DB 중단 여부    | 불필요 — Open 상태에서 복구 가능
   복구 방법       | 새 Temp 파일 추가 → 손상 파일 DROP
   자동 재생성     | 정상 종료(SHUTDOWN IMMEDIATE) 후 재기동 시 자동 재생성
   백업 필요 여부   | 불필요 — Temp 파일은 재생성 가능
   -------------------------------------------------------------------------
*/

/* --------------------------------------------------------------------------
   2-1. 사전 확인 — Temp 파일 / 테이블스페이스 상태
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] Temp 파일 경로 확인
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /u01/app/oracle/oradata/ORCL/temp01.dbf
*/

-- [SQL*Plus — SYSDBA] 테이블스페이스 유형 확인
SELECT tablespace_name, contents FROM dba_tablespaces;
/*
  TABLESPACE_NAME                CONTENTS
  ------------------------------ ---------------------
  SYSTEM                         PERMANENT
  SYSAUX                         PERMANENT
  UNDOTBS1                       UNDO
  TEMP                           TEMPORARY
  USERS                          PERMANENT
*/

-- [SQL*Plus — SYSDBA] Default Temp Tablespace 확인
SELECT property_value FROM database_properties
WHERE property_name = 'DEFAULT_TEMP_TABLESPACE';
/*
  PROPERTY_VALUE
  --------------
  TEMP
*/


/* --------------------------------------------------------------------------
   2-2. 장애 발생 — Temp 파일 삭제
   -------------------------------------------------------------------------- */

-- # [oracle 계정 — Linux 셸]
-- rm /u01/app/oracle/oradata/ORCL/temp01.dbf


/* --------------------------------------------------------------------------
   2-3. 장애 확인 — 정렬 쿼리 실행 시 오류
   -------------------------------------------------------------------------- */

-- [SQL*Plus — HR 계정] 정렬 쿼리 실행 → 오류 확인
SELECT s.*, b.* FROM all_objects s, all_objects b ORDER BY 1, 2, 3, 4;
/*
  ORA-01565: error in identifying file '/u01/app/oracle/oradata/ORCL/temp01.dbf'
  ORA-27037: unable to obtain file status
  Linux-x86_64 Error: 2: No such file or directory
  → Temp 파일이 없어 정렬 불가
*/


/* --------------------------------------------------------------------------
   2-4. 복구 — 새 Temp 파일 추가 후 손상 파일 제거
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 새 Temp 파일 추가
ALTER TABLESPACE temp ADD TEMPFILE '/u01/app/oracle/oradata/ORCL/temp02.dbf'
SIZE 10M AUTOEXTEND ON;
-- Tablespace altered.

-- [SQL*Plus — SYSDBA] 현재 Temp 파일 목록 확인 (추가 후 2개)
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /u01/app/oracle/oradata/ORCL/temp01.dbf
  /u01/app/oracle/oradata/ORCL/temp02.dbf
*/

-- [SQL*Plus — SYSDBA] 손상된 기존 Temp 파일 제거
ALTER TABLESPACE temp DROP TEMPFILE '/u01/app/oracle/oradata/ORCL/temp01.dbf';
-- Tablespace altered.

-- [SQL*Plus — SYSDBA] Temp 파일 목록 확인 (temp02만 남은 것 확인)
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /u01/app/oracle/oradata/ORCL/temp02.dbf
*/


/* --------------------------------------------------------------------------
   2-5. Temp 파일 자동 재생성 확인
   --------------------------------------------------------------------------
   Temp 파일은 정상 종료(SHUTDOWN IMMEDIATE) 후 재기동 시 자동 재생성됨
   -------------------------------------------------------------------------- */

-- # [oracle 계정 — Linux 셸]
-- rm /u01/app/oracle/oradata/ORCL/temp02.dbf

-- [SQL*Plus — SYSDBA] DB 정상 종료 후 재기동
SHUTDOWN IMMEDIATE;
STARTUP;

-- # [oracle 계정 — Linux 셸] Temp 파일 자동 재생성 확인
-- ls -l /u01/app/oracle/oradata/ORCL/temp02.dbf
/*
  -rw-r-----. 1 oracle dba 10493952 Jun  6 17:31 /u01/app/oracle/oradata/ORCL/temp02.dbf
  ※ SHUTDOWN IMMEDIATE로 정상 종료한 경우에만 자동 재생성됨
  ※ SHUTDOWN ABORT 후 재기동 시에는 자동 재생성되지 않을 수 있음
*/

-- [SQL*Plus — SYSDBA] Temp 파일 경로 확인
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /u01/app/oracle/oradata/ORCL/temp02.dbf
*/


/* --------------------------------------------------------------------------
   2-6. 새 Temp Tablespace 생성 및 Default 전환 방법
   --------------------------------------------------------------------------
   현재 Default Temp Tablespace를 DROP하려면 먼저 다른 TS를 Default로 지정해야 함
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 새 Temp Tablespace 생성
CREATE TEMPORARY TABLESPACE newtemp
TEMPFILE '/u01/app/oracle/oradata/ORCL/newtemp01.dbf' SIZE 10M AUTOEXTEND ON;
-- Tablespace created.

-- [SQL*Plus — SYSDBA] DB Default Temp Tablespace 변경
ALTER DATABASE DEFAULT TEMPORARY TABLESPACE newtemp;
-- Database altered.

-- [SQL*Plus — SYSDBA] 전환 확인
SELECT property_value FROM database_properties
WHERE property_name = 'DEFAULT_TEMP_TABLESPACE';
/*
  PROPERTY_VALUE
  --------------
  NEWTEMP
*/

-- [SQL*Plus — SYSDBA] 기존 TEMP 삭제 후 원상복구
DROP TABLESPACE temp INCLUDING CONTENTS AND DATAFILES;
-- Tablespace dropped.

CREATE TEMPORARY TABLESPACE temp
TEMPFILE '/u01/app/oracle/oradata/ORCL/temp01.dbf' SIZE 10M AUTOEXTEND ON;
-- Tablespace created.

ALTER DATABASE DEFAULT TEMPORARY TABLESPACE temp;
-- Database altered.

DROP TABLESPACE newtemp INCLUDING CONTENTS AND DATAFILES;
-- Tablespace dropped.

-- [SQL*Plus — SYSDBA] 최종 확인
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /u01/app/oracle/oradata/ORCL/temp01.dbf
*/

SELECT property_value FROM database_properties
WHERE property_name = 'DEFAULT_TEMP_TABLESPACE';
/*
  PROPERTY_VALUE
  --------------
  TEMP
*/


/* ==========================================================================
   3. 시나리오 11 — 모든 데이터파일 / 컨트롤파일 / 리두로그파일이 있는 디스크 손상
   ==========================================================================
   DB 파일 전체가 위치한 디스크가 손상되는 시나리오
   백업본을 새로운 경로로 복원한 뒤, 컨트롤파일과 DB 파일 경로를 재지정하여 기동

   복구 절차 요약
   -------------------------------------------------------------------------
   단계 | 내용
   -----|---------------------------------------------------------------------
     1  | pfile 생성 및 컨트롤파일 경로를 신규 경로로 수정
     2  | 장애 발생 (원본 경로 전체 파일 삭제)
     3  | 백업본을 신규 경로에 복원
     4  | pfile로 MOUNT까지 기동 (컨트롤파일을 신규 경로에서 읽음)
     5  | RENAME으로 데이터파일 / 리두로그 / Temp 경로를 신규 경로로 변경
     6  | ALTER DATABASE OPEN
   -------------------------------------------------------------------------
*/

/* --------------------------------------------------------------------------
   3-1. 사전 확인 및 pfile 생성
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] spfile 위치 확인
SHOW PARAMETER SPFILE;
/*
  NAME   TYPE   VALUE
  ------ ------ -------------------------------------------------------
  spfile string /u01/app/oracle/product/19.3.0/dbhome_1/dbs/spfileorcl.ora
*/

-- [SQL*Plus — SYSDBA] pfile 생성
CREATE PFILE FROM SPFILE;
-- File created.

-- [SQL*Plus — SYSDBA] 전체 DB 파일 경로 통합 조회
SELECT name FROM v$datafile
UNION
SELECT name FROM v$controlfile
UNION
SELECT member FROM v$logfile
UNION
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /u01/app/oracle/oradata/ORCL/control01.ctl
  /u01/app/oracle/oradata/ORCL/redo01.log
  /u01/app/oracle/oradata/ORCL/redo02.log
  /u01/app/oracle/oradata/ORCL/redo03.log
  /u01/app/oracle/oradata/ORCL/sysaux01.dbf
  /u01/app/oracle/oradata/ORCL/system01.dbf
  /u01/app/oracle/oradata/ORCL/temp01.dbf
  /u01/app/oracle/oradata/ORCL/undotbs01.dbf
  /u01/app/oracle/oradata/ORCL/users01.dbf
  ※ 이 목록을 기준으로 이후 RENAME 명령 작성
*/


/* --------------------------------------------------------------------------
   3-2. 복구 경로 준비 — pfile에서 컨트롤파일 경로 수정
   --------------------------------------------------------------------------
   ★ 반드시 장애 발생 전에 수행해야 함
   ★ pfile에서 control_files 경로를 신규 경로로 변경해야
     백업본 복원 후 MOUNT 단계 진입 가능
   -------------------------------------------------------------------------- */

/*
  ---- Linux 셸 작업 ----
  # [oracle 계정 — Linux 셸]
  # 신규 복구 경로 생성
  mkdir -p /home/oracle/oradata

  # pfile 수정 — control_files 경로 변경
  vi $ORACLE_HOME/dbs/initorcl.ora
  # 수정 전: *.control_files='/u01/app/oracle/oradata/ORCL/control01.ctl'
  # 수정 후: *.control_files='/home/oracle/oradata/control01.ctl'
  ----------------------
*/


/* --------------------------------------------------------------------------
   3-3. 장애 발생 — 원본 경로 파일 전체 삭제
   -------------------------------------------------------------------------- */

-- # [oracle 계정 — Linux 셸]
-- rm /u01/app/oracle/oradata/ORCL/*


/* --------------------------------------------------------------------------
   3-4. 장애 확인 — 컨트롤파일 인식 불가
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 체크포인트 시도 → DB 비정상 종료
ALTER SYSTEM CHECKPOINT;
-- ORA-03113: end-of-file on communication channel

-- [SQL*Plus — SYSDBA] 재접속 후 기동 시도
CONN / AS SYSDBA
-- Connected to an idle instance.

STARTUP;
-- ORA-00205: error in identifying control file
-- ※ pfile에서 지정한 신규 경로에 컨트롤파일이 없으므로 MOUNT 실패

-- [SQL*Plus — SYSDBA] 인스턴스 상태 확인 (NOMOUNT 단계에서 멈춤)
SELECT status FROM v$instance;
/*
  STATUS
  -------
  STARTED
*/


/* --------------------------------------------------------------------------
   3-5. 복구 — 새 경로로 백업본 복원
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] DB 즉시 종료
SHUTDOWN ABORT;

/*
  ---- Linux 셸 작업 ----
  # [oracle 계정 — Linux 셸]
  # 백업본을 신규 경로에 복원
  cp -v /home/oracle/backup/noarch/* /home/oracle/oradata/

  # 복원 결과 예시:
  # '/home/oracle/backup/noarch/control01.ctl' -> '/home/oracle/oradata/control01.ctl'
  # '/home/oracle/backup/noarch/redo01.log'    -> '/home/oracle/oradata/redo01.log'
  # '/home/oracle/backup/noarch/sysaux01.dbf'  -> '/home/oracle/oradata/sysaux01.dbf'
  # '/home/oracle/backup/noarch/system01.dbf'  -> '/home/oracle/oradata/system01.dbf'
  # '/home/oracle/backup/noarch/temp01.dbf'    -> '/home/oracle/oradata/temp01.dbf'
  # '/home/oracle/backup/noarch/undotbs01.dbf' -> '/home/oracle/oradata/undotbs01.dbf'
  # '/home/oracle/backup/noarch/users01.dbf'   -> '/home/oracle/oradata/users01.dbf'
  ----------------------
*/


/* --------------------------------------------------------------------------
   3-6. pfile로 MOUNT까지 기동
   --------------------------------------------------------------------------
   ★ pfile에서 control_files를 신규 경로로 수정했으므로
     신규 경로의 컨트롤파일을 읽어 MOUNT 단계까지 진입 가능
   ★ 컨트롤파일 내부에는 기존 경로 정보가 기록되어 있으므로
     OPEN 전에 RENAME으로 경로를 변경해야 함
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] pfile로 MOUNT까지만 기동
STARTUP PFILE='$ORACLE_HOME/dbs/initorcl.ora' MOUNT;
-- ORACLE instance started.
-- Database mounted.

-- [SQL*Plus — SYSDBA] 현재 등록된 파일 경로 확인
-- ※ 컨트롤파일: 신규 경로 / 데이터파일 · 리두로그 · Temp: 기존 경로
SELECT name FROM v$datafile
UNION
SELECT name FROM v$controlfile
UNION
SELECT member FROM v$logfile
UNION
SELECT name FROM v$tempfile;
/*
  NAME
  ----------------------------------------------------
  /home/oracle/oradata/control01.ctl            -- 컨트롤파일: 신규 경로 ✓
  /u01/app/oracle/oradata/ORCL/redo01.log      -- 리두로그: 기존 경로 → RENAME 필요
  /u01/app/oracle/oradata/ORCL/redo02.log
  /u01/app/oracle/oradata/ORCL/redo03.log
  /u01/app/oracle/oradata/ORCL/sysaux01.dbf    -- 데이터파일: 기존 경로 → RENAME 필요
  /u01/app/oracle/oradata/ORCL/system01.dbf
  /u01/app/oracle/oradata/ORCL/temp01.dbf      -- Temp: 기존 경로 → RENAME 필요
  /u01/app/oracle/oradata/ORCL/undotbs01.dbf
  /u01/app/oracle/oradata/ORCL/users01.dbf
*/


/* --------------------------------------------------------------------------
   3-7. RENAME — 데이터파일 / 리두로그 / Temp 파일 경로 변경
   --------------------------------------------------------------------------
   ★ MOUNT 상태에서만 실행 가능
   ★ 환경에 따라 파일 목록이 다를 수 있으므로 3-6에서 조회한 결과 기준으로 수행
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] 데이터파일 경로 변경
ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/system01.dbf'
TO '/home/oracle/oradata/system01.dbf';

ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/sysaux01.dbf'
TO '/home/oracle/oradata/sysaux01.dbf';

ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/undotbs01.dbf'
TO '/home/oracle/oradata/undotbs01.dbf';

ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/users01.dbf'
TO '/home/oracle/oradata/users01.dbf';

-- ※ 환경에 따라 추가 데이터파일이 있으면 동일한 방식으로 RENAME
-- ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/userdata01.dbf'
-- TO '/home/oracle/oradata/userdata01.dbf';

-- ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/audit_tbs01.dbf'
-- TO '/home/oracle/oradata/audit_tbs01.dbf';

-- [SQL*Plus — SYSDBA] Temp 파일 경로 변경
ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/temp01.dbf'
TO '/home/oracle/oradata/temp01.dbf';

-- [SQL*Plus — SYSDBA] 리두로그 경로 변경
ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/redo01.log'
TO '/home/oracle/oradata/redo01.log';

ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/redo02.log'
TO '/home/oracle/oradata/redo02.log';

ALTER DATABASE RENAME FILE '/u01/app/oracle/oradata/ORCL/redo03.log'
TO '/home/oracle/oradata/redo03.log';


/* --------------------------------------------------------------------------
   3-8. ALTER DATABASE OPEN 및 결과 확인
   -------------------------------------------------------------------------- */

-- [SQL*Plus — SYSDBA] DB OPEN
ALTER DATABASE OPEN;
-- Database altered.

-- [SQL*Plus — SYSDBA] 모든 파일 경로 변경 확인 (신규 경로 전체 확인)
SELECT name FROM v$datafile
UNION
SELECT name FROM v$controlfile
UNION
SELECT member FROM v$logfile
UNION
SELECT name FROM v$tempfile;
/*
  [예상 결과]
  NAME
  --------------------------------------------------
  /home/oracle/oradata/control01.ctl
  /home/oracle/oradata/redo01.log
  /home/oracle/oradata/redo02.log
  /home/oracle/oradata/redo03.log
  /home/oracle/oradata/sysaux01.dbf
  /home/oracle/oradata/system01.dbf
  /home/oracle/oradata/temp01.dbf
  /home/oracle/oradata/undotbs01.dbf
  /home/oracle/oradata/users01.dbf
  ※ 모든 파일이 신규 경로(/home/oracle/oradata/)로 정상 기동
*/

-- [SQL*Plus — SYSDBA] spfile 재생성 (신규 경로 기준으로 운영 지속 시)
CREATE SPFILE FROM PFILE;
-- File created.

SHUTDOWN IMMEDIATE;
STARTUP;


/* ==========================================================================
   4. 관련 뷰 정리
   ==========================================================================
   뷰 / 객체명                        | 조회 목적
   ----------------------------------|------------------------------------------
   v$datafile                        | 데이터파일 경로, SCN(checkpoint_change#), 상태
   v$tempfile                        | Temp 파일 경로 확인
   v$controlfile                     | 컨트롤파일 경로 확인
   v$logfile                         | 리두로그 파일 경로 및 상태 확인
   v$recover_file                    | 복구가 필요한 데이터파일 목록
   v$instance                        | 인스턴스 기동 단계 확인 (STARTED/MOUNTED/OPEN)
   v$session                         | 진행 중인 세션 정보
   v$transaction                     | 진행 중인 TX 정보 (xidusn, ubafil, ubablk 등)
   v$rollname                        | 롤백 세그먼트 번호 → 이름 매핑
   v$sort_usage                      | Temp 파일 사용 세션 확인
   dba_rollback_segs                 | Undo 세그먼트 전체 상태 (ONLINE/NEEDS RECOVERY)
   dba_tablespaces                   | 테이블스페이스 유형 (PERMANENT/UNDO/TEMPORARY)
   database_properties               | Default Temp Tablespace 등 DB 속성 확인
   ==========================================================================
*/


/* ==========================================================================
   5. 주요 명령어 정리
   ==========================================================================
   명령어 패턴                                               | 설명
   ----------------------------------------------------------|------------------
   ALTER DATABASE DATAFILE N OFFLINE DROP                    | No Archive 모드에서 데이터파일 offline (복구 포기)
   ALTER DATABASE OPEN                                       | MOUNT 상태에서 DB OPEN
   ALTER DATABASE RENAME FILE '구경로' TO '신경로'            | 데이터파일/리두로그/Temp 파일 경로 변경 (MOUNT 상태)
   ALTER DATABASE DEFAULT TEMPORARY TABLESPACE ts_name       | DB Default Temp Tablespace 변경
   ALTER TABLESPACE ts ADD TEMPFILE '경로' SIZE n            | Temp 테이블스페이스에 파일 추가
   ALTER TABLESPACE ts DROP TEMPFILE '경로'                  | Temp 파일 제거 (물리 파일도 함께 삭제)
   CREATE UNDO TABLESPACE ts DATAFILE '경로' SIZE n          | 새 Undo 테이블스페이스 생성
   ALTER SYSTEM SET undo_tablespace = ts_name                | 운영 Undo 테이블스페이스 전환
   DROP TABLESPACE ts INCLUDING CONTENTS AND DATAFILES       | 테이블스페이스 + 물리 파일 동시 삭제
   CREATE PFILE FROM SPFILE                                  | spfile → pfile 생성
   CREATE SPFILE FROM PFILE                                  | pfile → spfile 생성
   STARTUP PFILE='경로' MOUNT                                | pfile로 MOUNT 단계까지만 기동
   _offline_rollback_segments (히든 파라미터, pfile)         | TX 진행 중 NEEDS RECOVERY 세그먼트 강제 offline
   _corrupted_rollback_segments (히든 파라미터, pfile)       | TX 없는 NEEDS RECOVERY 세그먼트 강제 offline
   ==========================================================================
*/


/* ==========================================================================
   6. 실습 핵심 요약
   ==========================================================================
   시나리오                     | 핵심 포인트
   -----------------------------|----------------------------------------------
   시나리오 9                   | TX 진행 중 Undo 손상 → offline drop → OPEN →
   (TX 중 Undo 손상, Redo X)   | 새 Undo TS 생성 → undo_tablespace 전환 →
                                | _offline_rollback_segments로 NEEDS RECOVERY 세그먼트 offline → DROP
                                | ※ TX가 있어도 DB OPEN 과정에서 강제 해소됨
                                | ※ _offline_rollback_segments (시나리오 9)
                                |   vs _corrupted_rollback_segments (시나리오 8) 구분
   -----------------------------|----------------------------------------------
   시나리오 10                  | DB 유지 상태에서 복구 가능 (Down 불필요)
   (Temp 파일 손상)             | 새 Tempfile 추가 → 손상 파일 DROP
                                | ※ SHUTDOWN IMMEDIATE 후 재기동 시 자동 재생성
                                | ※ SHUTDOWN ABORT 후에는 자동 재생성 보장 안 됨
   -----------------------------|----------------------------------------------
   시나리오 11                  | 장애 전 pfile에서 control_files 신규 경로로 수정
   (전체 디스크 손상)           | → 백업본을 신규 경로에 복원
                                | → pfile로 MOUNT 기동
                                | → RENAME으로 데이터파일/리두로그/Temp 경로 재지정
                                | → ALTER DATABASE OPEN
   ==========================================================================
*/
