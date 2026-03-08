/*
 Admin 실습 01: 인스턴스 기동 & 파라미터 파일
 블로그: https://nsylove97.tistory.com/13
 GitHub: https://github.com/nsylove97/Seongryeol-OracleDB-Portfolio

 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1. SQL*Plus 접속 방식 — 로컬 vs 클라이언트
   2. Alert Log 모니터링
   3. 인스턴스 기동 4단계 (SHUTDOWN → NOMOUNT → MOUNT → OPEN)
      3-1. SHUTDOWN 단계
      3-2. NOMOUNT 단계 — 파라미터 파일 / pfile & spfile 변환
      3-3. NOMOUNT 단계 전용 작업 — 컨트롤 파일 재생성 / DB 신규 생성
      3-4. MOUNT 단계 — 아카이브 로그 모드 전환
      3-5. MOUNT 단계 — 데이터파일 경로 변경
      3-6. OPEN 단계
   4. SHUTDOWN ABORT & Instance Recovery
   5. 백그라운드 프로세스 강제 종료 & 크래시 복구
   6. SCOPE 옵션 파라미터 제어
*/


--1. SQL*Plus 접속 방식 — 로컬 vs 클라이언트


-- [로컬 접속] 서버 내부에서 Oracle Net(리스너) 없이 직접 접속
-- sqlplus hr/hr

-- [클라이언트 접속] 네트워크를 통해 리스너를 경유하는 원격 접속 (@가 붙음)
-- 형식: sqlplus 계정/비번@호스트:포트/서비스명
-- sqlplus hr/hr@oel7vr:1521/orcl

/*
 [결과] 리스너가 없는 상태에서 클라이언트 접속 시도 시 에러 발생:
   ERROR:
   ORA-12541: TNS:no listener

 [조치] 리스너 기동 후 재접속
   $ lsnrctl start
   $ sqlplus hr/hr@oel7vr:1521/orcl  → 접속 성공

 [포인트]
   - @ 기호가 붙으면 리스너를 경유하는 클라이언트 접속
   - 인스턴스 1개는 반드시 DB 1개와만 연결됨
*/


--2. Alert Log 모니터링


-- Alert Log 저장 경로 확인
SHOW PARAMETER diagnostic_dest;

/*
 [결과]
   NAME                TYPE        VALUE
   ------------------- ----------- ----------------------------
   diagnostic_dest     string      /u01/app/oracle

 Alert Log 기본 경로:
   <diagnostic_dest>/diag/rdbms/<db_name>/<db_unique_name>/trace/alert_<SID>.log

 실습 환경 경로:
   /u01/app/oracle/diag/rdbms/orcl/orcl/trace/alert_orcl.log
*/

-- [리눅스 명령어] SQL*Plus 안에서 !를 붙이면 OS 명령어 실행 가능
-- 전체 출력
-- !cat alert_orcl.log

-- 실시간 모니터링 (Ctrl+C로 종료)
-- !tail -f alert_orcl.log

/*
 Alert Log에 기록되는 정보:
   - 인스턴스 시작/종료 상태 변화
   - DDL 관련 구조적 변경
   - 에러 및 경고 (예: ORA-600 internal error)
   - Deadlock 발생 이력 등
*/


-- 3-1. SHUTDOWN 단계


-- DB 정상 종료 (현재 접속 세션 처리 완료 후 종료)
SHUTDOWN IMMEDIATE;

/*
 [결과]
   Database closed.
   Database dismounted.
   ORACLE instance shut down.

 SHUTDOWN 상태에서 OS 레벨 작업 가능 (SQL*Plus 밖, 터미널에서 실행):

   $ cp /u01/app/oracle/oradata/ORCL/users01.dbf /home/oracle/     -- 파일 복사
   $ chown oracle:oinstall users01.dbf                             -- 소유자 변경
   $ chmod 640 users01.dbf                                         -- 권한 변경
*/


-- 3-2. NOMOUNT 단계 — 파라미터 파일 / pfile & spfile 변환 

-- NOMOUNT 단계로 진입 (파라미터 파일을 읽어 인스턴스만 기동)
STARTUP NOMOUNT;

/*
 [결과]
   ORACLE instance started.

   Total System Global Area 1610612736 bytes
   Fixed Size                  8793304 bytes
   Variable Size             989855016 bytes
   Database Buffers          603979776 bytes
   Redo Buffers                7983104 bytes

 Alert Log에서 확인 가능한 내용:
   - nomount 진입 시 읽은 non-default 파라미터 값 출력
   - background process 동작 시작 기록

 파라미터 파일 우선순위:
   spfileorcl.ora (spfile) → initorcl.ora (pfile) 순으로 탐색
   → spfile이 있으면 spfile 우선 적용

 파일 위치: $ORACLE_HOME/dbs/
*/

-- spfile → pfile 생성 (텍스트 기반 백업용)
CREATE PFILE FROM SPFILE;

-- 특정 경로로 생성 (복구용 백업)
CREATE PFILE='/home/oracle/init_backup.ora' FROM SPFILE;

-- pfile → spfile 생성 (pfile 수정 후 spfile에 반영)
CREATE SPFILE FROM PFILE;

/*
 [결과] pfile 생성 후 OS에서 확인:
   $ ls -lh $ORACLE_HOME/dbs/
   -rw-r----- oracle oinstall  initorcl.ora    ← pfile 생성됨
   -rw-r----- oracle oinstall  spfileorcl.ora  ← 기존 spfile

 [pfile vs spfile 비교]
   구분          pfile (initorcl.ora)     spfile (spfileorcl.ora)
   형식          텍스트 파일              바이너리 파일
   수정 방법     vi 편집기 직접 수정      ALTER SYSTEM 명령으로만 수정
   반영 시점     DB 재시작 후             동적 파라미터는 즉시, 정적은 재시작 필요
   우선순위      spfile 없을 때 사용      spfile이 있으면 우선 적용
*/

-- 3-3. NOMOUNT 단계 전용 작업 — 컨트롤 파일 재생성 / DB 신규 생성

-- [OPEN 상태에서] 컨트롤 파일 재생성 스크립트 추출 (장애 대비)
ALTER DATABASE BACKUP CONTROLFILE TO TRACE AS '/home/oracle/ctltrace.sql';

/*
 [결과] /home/oracle/ctltrace.sql 파일 생성됨
   $ cat /home/oracle/ctltrace.sql 으로 내용 확인 가능

 추출된 스크립트 안에 CREATE CONTROLFILE 구문이 자동 생성됨
 → 컨트롤 파일 손상 시 NOMOUNT 단계에서 아래 스크립트로 재생성
*/

-- [NOMOUNT 단계에서] 컨트롤 파일 재생성
-- STARTUP NOMOUNT; 후 아래 실행

CREATE CONTROLFILE REUSE DATABASE "ORCL" NORESETLOGS NOARCHIVELOG
    MAXLOGFILES 16
    MAXLOGMEMBERS 3
    MAXDATAFILES 100
    MAXINSTANCES 8
    MAXLOGHISTORY 292
LOGFILE
    GROUP 1 '/u01/app/oracle/oradata/ORCL/redo01.log'  SIZE 50M BLOCKSIZE 512,
    GROUP 2 '/u01/app/oracle/oradata/ORCL/redo02.log'  SIZE 50M BLOCKSIZE 512,
    GROUP 3 '/u01/app/oracle/oradata/ORCL/redo03.log'  SIZE 50M BLOCKSIZE 512
DATAFILE
    '/u01/app/oracle/oradata/ORCL/system01.dbf',
    '/u01/app/oracle/oradata/ORCL/sysaux01.dbf',
    '/u01/app/oracle/oradata/ORCL/undotbs01.dbf',
    '/u01/app/oracle/oradata/ORCL/users01.dbf'
CHARACTER SET AL32UTF8;

/*
 [결과]
   Control file created.

 재생성 후 오픈:
   일반 OPEN이 아닌 RESETLOGS로 열어야 함
   → ALTER DATABASE OPEN RESETLOGS;

 [왜 NOMOUNT에서만 가능한가?]
   컨트롤 파일을 새로 만드는 작업이므로,
   기존 컨트롤 파일을 열기 전인 NOMOUNT 단계에서만 실행 가능
*/

-- [NOMOUNT 단계에서] 데이터베이스 신규 생성 (CREATE DATABASE는 NOMOUNT에서만 가능)
CREATE DATABASE newdb
    USER SYS    IDENTIFIED BY oracle
    USER SYSTEM IDENTIFIED BY oracle
    LOGFILE
        GROUP 1 ('/u01/app/oracle/oradata/ORCL/redo01.log') SIZE 50M,
        GROUP 2 ('/u01/app/oracle/oradata/ORCL/redo02.log') SIZE 50M,
        GROUP 3 ('/u01/app/oracle/oradata/ORCL/redo03.log') SIZE 50M
    MAXLOGFILES    5
    MAXLOGMEMBERS  5
    MAXDATAFILES   100
    MAXINSTANCES   1
    DATAFILE        '/u01/app/oracle/oradata/ORCL/system01.dbf'  SIZE 500M REUSE
    SYSAUX DATAFILE '/u01/app/oracle/oradata/ORCL/sysaux01.dbf'  SIZE 500M REUSE
    DEFAULT TABLESPACE users
        DATAFILE    '/u01/app/oracle/oradata/ORCL/users01.dbf'   SIZE 200M REUSE
    DEFAULT TEMPORARY TABLESPACE temp
        TEMPFILE    '/u01/app/oracle/oradata/ORCL/temp01.dbf'    SIZE 100M REUSE
    UNDO TABLESPACE undotbs1
        DATAFILE    '/u01/app/oracle/oradata/ORCL/undotbs01.dbf' SIZE 200M REUSE
    CHARACTER SET AL32UTF8
    NATIONAL CHARACTER SET AL16UTF16;

/*
 [왜 NOMOUNT에서만 가능한가?]
   DB 자체가 아직 존재하지 않으므로
   컨트롤 파일이 없는 NOMOUNT 상태에서 실행해야 함
   MOUNT 단계부터는 이미 컨트롤 파일이 열려 있는 상태이므로 실행 불가
*/

-- 3-4. MOUNT 단계 — 아카이브 로그 모드 전환

-- [OPEN 상태에서] 현재 아카이브 모드 확인
ARCHIVE LOG LIST;

/*
 [결과] 전환 전
   Database log mode              No Archive Mode   ← 현재 비활성화 상태
   Automatic archival             Disabled
   Archive destination            USE_DB_RECOVERY_FILE_DEST
   Oldest online log sequence     3
   Current log sequence           5
*/

-- MOUNT 단계로 내려가기
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;

-- 아카이브 로그 모드 전환 (MOUNT 단계에서만 가능)
ALTER DATABASE ARCHIVELOG;

-- 다시 OPEN
ALTER DATABASE OPEN;

-- 전환 후 확인
ARCHIVE LOG LIST;

/*
 [결과] 전환 후
   Database log mode              Archive Mode      ← 활성화 완료
   Automatic archival             Enabled
   Archive destination            USE_DB_RECOVERY_FILE_DEST
   Oldest online log sequence     3
   Next log sequence to archive   5
   Current log sequence           5
*/

-- 아카이브 로그 저장 경로 확인
SHOW PARAMETER db_recovery_file_dest;

/*
 [결과]
   NAME                     TYPE        VALUE
   ------------------------ ----------- ----------------------------------
   db_recovery_file_dest    string      /u01/app/oracle/fast_recovery_area

 log_archive_dest 파라미터를 별도로 설정하지 않으면
 db_recovery_file_dest 경로에 아카이브 로그 파일이 저장됨
*/

-- 아카이브 로그 파일명 형식 확인
SHOW PARAMETER log_archive_format;

/*
 [결과]
   NAME                TYPE        VALUE
   ------------------- ----------- --------------------
   log_archive_format  string      %t_%s_%r.dbf

   %t : redo thread number
   %s : log sequence number
   %r : resetlogs ID
*/

-- log switch 발생시켜 아카이브 로그 파일 생성 테스트
ALTER SYSTEM SWITCH LOGFILE;

-- 생성된 아카이브 로그 파일 OS에서 확인
-- !ls -l /u01/app/oracle/fast_recovery_area/ORCL/archivelog/

/*
 [결과]
   1_5_xxxxxxxxx.dbf 형태의 파일 생성 확인
*/


-- 3-5. MOUNT 단계 — 데이터파일 경로 변경

-- [OPEN 상태에서] 변경 전 데이터파일 경로 확인
SELECT FILE#, NAME FROM V$DATAFILE;

/*
 [결과]
   FILE#  NAME
   -----  -----------------------------------------------
   1      /u01/app/oracle/oradata/ORCL/system01.dbf
   2      /u01/app/oracle/oradata/ORCL/sysaux01.dbf
   3      /u01/app/oracle/oradata/ORCL/undotbs01.dbf
   4      /u01/app/oracle/oradata/ORCL/users01.dbf
*/

-- 순서 중요: OS에서 파일 먼저 이동 → Oracle에 새 경로 등록

-- STEP 1: DB 종료 후 MOUNT 단계로 진입
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;

-- STEP 2: OS에서 실제 파일 복사 (SQL*Plus 안에서 ! 사용)
-- !cp /u01/app/oracle/oradata/ORCL/users01.dbf /home/oracle/users01.dbf

-- STEP 3: Oracle 컨트롤 파일에 새 경로 등록 (MOUNT 단계에서만 가능)
ALTER DATABASE RENAME FILE
    '/u01/app/oracle/oradata/ORCL/users01.dbf'
    TO '/home/oracle/users01.dbf';

/*
 [결과]
   Database altered.
*/

-- STEP 4: DB OPEN
ALTER DATABASE OPEN;

-- STEP 5: 변경된 경로 확인
SELECT FILE#, NAME FROM V$DATAFILE WHERE NAME LIKE '%users%';

/*
 [결과]
   FILE#  NAME
   -----  --------------------------------
   4      /home/oracle/users01.dbf         ← 경로 변경 완료

 [왜 MOUNT에서만 가능한가?]
   컨트롤 파일에 파일 경로를 기록하는 작업이기 때문에
   컨트롤 파일이 열린 MOUNT 단계에서만 가능
   OPEN 상태에서는 파일이 사용 중이므로 변경 불가
*/

-- 3-6. OPEN 단계
-- 처음부터 한 번에 OPEN까지
STARTUP;

/*
 [결과]
   ORACLE instance started.
   Database mounted.
   Database opened.

 OPEN 시 내부 동작:
   1. Control File에서 데이터파일과 Redo Log 파일 경로 확인
   2. SMON 프로세스가 데이터 일관성 검사
   3. 비정상 종료 이력이 있으면 Instance Recovery(Crash Recovery) 자동 수행
      - Roll Forward : Redo Log를 읽어 미반영 변경사항을 데이터 파일에 적용
      - Roll Back    : 미완료 트랜잭션을 Undo로 취소
*/

-- OPEN 후 인스턴스 상태 확인
SELECT INSTANCE_NAME, STATUS FROM V$INSTANCE;

/*
 [결과]
   INSTANCE_NAME    STATUS
   ---------------- ------------
   orcl             OPEN
*/


-- 4. SHUTDOWN ABORT & Instance Recovery 실습

-- STEP 1: 미완료 트랜잭션 만들기 (장애 상황 재현)
-- test 계정으로 접속 후 UPDATE 후 COMMIT 하지 않음
-- CONN test/test1234;
-- UPDATE test_table SET col1 = 'changed' WHERE id = 1;
-- (COMMIT 하지 않고 세션 유지)

-- STEP 2: 다른 세션에서 강제 종료
CONN / AS SYSDBA
SHUTDOWN ABORT;

/*
 [결과]
   ORACLE instance shut down.

 SHUTDOWN ABORT:
   - 체크포인트, 정리 없이 즉시 종료
   - 실제 전원 차단 / 서버 다운과 동일한 효과
   - 재시작 시 반드시 Instance Recovery 수행됨
*/

-- STEP 3: 재시작 → Instance Recovery 자동 수행 확인
STARTUP;

/*
 [결과] 기동 로그 (Alert Log에서도 확인 가능)
   Beginning crash recovery of 1 threads
    parallel recovery started with 1 processes
   Started redo scan
   Completed redo scan
    read 3 KB redo, 1 data blocks need recovery
   Started redo application at
    Thread 1: logseq 5, block 3
   Recovery of Online Redo Log: Thread 1 Group 1 ...
   Completed redo application of 0.00MB
   Completed crash recovery at
    Thread 1: logseq 5, block 20
    1 data blocks read, 1 data blocks written, 3 redo k-bytes read
   LGWR: STARTING ARCH PROCESSES

 → SMON이 자동으로 Roll Forward + Roll Back 수행 완료
*/

-- STEP 4: 미완료 트랜잭션이 롤백됐는지 확인
-- CONN test/test1234;
-- SELECT col1 FROM test_table WHERE id = 1;
-- → COMMIT 안 했던 'changed' 값이 사라진 것 확인 (Roll Back 완료)

-- Alert Log에서 Recovery 과정 확인
SHOW PARAMETER diagnostic_dest;
-- !tail -100 /u01/app/oracle/diag/rdbms/orcl/orcl/trace/alert_orcl.log


-- 5. 백그라운드 프로세스 강제 종료 & 크래시 복구

-- 인스턴스 상태 확인
SELECT INSTANCE_NAME, STATUS FROM V$INSTANCE;

-- [리눅스 터미널] orcl 인스턴스 백그라운드 프로세스 목록 확인
-- $ ps -ef | grep orcl

/*
 [결과 예시]
   oracle  29938   1  0 19:54 ?  00:00:00 ora_pmon_orcl
   oracle  29940   1  0 19:54 ?  00:00:00 ora_clmn_orcl
   oracle  29942   1  0 19:54 ?  00:00:00 ora_psp0_orcl
   oracle  29946   1  0 19:54 ?  00:00:00 ora_vktm_orcl
   oracle  29952   1  0 19:54 ?  00:00:00 ora_gen0_orcl
   oracle  29956   1  0 19:54 ?  00:00:00 ora_mman_orcl
   oracle  29960   1  0 19:54 ?  00:00:00 ora_dbw0_orcl
   oracle  29962   1  0 19:54 ?  00:00:00 ora_lgwr_orcl  ← 이 PID 사용
   oracle  29964   1  0 19:54 ?  00:00:00 ora_ckpt_orcl
   oracle  29966   1  0 19:54 ?  00:00:00 ora_smon_orcl

 주요 백그라운드 프로세스 역할:
   ora_pmon : 비정상 종료된 프로세스 정리, 리스너에 인스턴스 등록
   ora_smon : Instance Recovery 수행, 임시 세그먼트 정리
   ora_dbw0 : Dirty Buffer를 데이터파일에 기록 (Database Writer)
   ora_lgwr : Redo Log Buffer를 Redo Log 파일에 기록 (Log Writer)
   ora_ckpt : 체크포인트 발생 시 컨트롤 파일/데이터파일 헤더 업데이트
*/

-- [리눅스 터미널] LGWR 강제 종료 → 인스턴스 전체 크래시 재현
-- $ ps -ef | grep ora_lgwr_orcl   ← LGWR PID 확인
-- $ kill -9 29962                 ← LGWR 강제 종료

/*
 [결과] LGWR 종료 시 인스턴스 전체 크래시
   - 모든 백그라운드 프로세스가 연쇄적으로 종료됨
   - Alert Log에 에러 기록됨:
       ORA-00600: internal error code ...
       or
       LGWR (ospid: 29962): terminating the instance due to error 473

   - 잠시 후 ps -ef | grep orcl 에서 프로세스 모두 사라진 것 확인
*/

-- [재접속 후] DB 재시작
STARTUP;

/*
 [결과]
   Beginning crash recovery of 1 threads  ← Instance Recovery 자동 수행
   Completed crash recovery at ...
   Database opened.

 Alert Log에서도 crash recovery 진행 기록 확인 가능
*/

-- 인스턴스 정상 복구 확인
SELECT INSTANCE_NAME, STATUS FROM V$INSTANCE;

/*
 [결과]
   INSTANCE_NAME    STATUS
   ---------------- ------
   orcl             OPEN
*/


-- 6. SCOPE 옵션 파라미터 제어

-- 실습 전 파라미터 현재 값 확인
SHOW PARAMETER job_queue_processes;   -- 동적 파라미터 (실습용)
SHOW PARAMETER processes;             -- 정적 파라미터 (실습용)

/*
 [결과]
   NAME                  TYPE     VALUE
   --------------------- -------- -----
   job_queue_processes   integer  80
   processes             integer  320
*/

-- ① SCOPE=MEMORY — 메모리에만 즉시 적용, 재시작하면 원복 (동적 파라미터만 가능)
ALTER SYSTEM SET job_queue_processes = 5 SCOPE=MEMORY;

SHOW PARAMETER job_queue_processes;

/*
 [결과] 즉시 반영
   NAME                  TYPE     VALUE
   --------------------- -------- -----
   job_queue_processes   integer  5     ← 5로 변경됨
*/

SHUTDOWN IMMEDIATE;
STARTUP;

SHOW PARAMETER job_queue_processes;

/*
 [결과] 재시작 후 원복
   NAME                  TYPE     VALUE
   --------------------- -------- -----
   job_queue_processes   integer  80    ← 원래 값 80으로 복구됨
*/

-- ② SCOPE=SPFILE — spfile에만 기록, 재시작 후 적용 (정적 파라미터 수정 시 필수)
ALTER SYSTEM SET processes = 200 SCOPE=SPFILE;

SHOW PARAMETER processes;

/*
 [결과] 아직 메모리는 바뀌지 않음
   NAME       TYPE     VALUE
   ---------- -------- -----
   processes  integer  320   ← 아직 원래 값 유지
*/

SHUTDOWN IMMEDIATE;
STARTUP;

SHOW PARAMETER processes;

/*
 [결과] 재시작 후 적용
   NAME       TYPE     VALUE
   ---------- -------- -----
   processes  integer  200   ← 변경된 값 200으로 적용됨
*/

-- ③ SCOPE=BOTH — 즉시 반영 + spfile에도 기록, 재시작해도 유지 (동적 파라미터만 가능)
ALTER SYSTEM SET job_queue_processes = 10 SCOPE=BOTH;

SHOW PARAMETER job_queue_processes;

/*
 [결과] 즉시 반영
   NAME                  TYPE     VALUE
   --------------------- -------- -----
   job_queue_processes   integer  10    ← 즉시 10으로 변경됨
*/

SHUTDOWN IMMEDIATE;
STARTUP;

SHOW PARAMETER job_queue_processes;

/*
 [결과] 재시작 후에도 유지
   NAME                  TYPE     VALUE
   --------------------- -------- -----
   job_queue_processes   integer  10    ← 재시작해도 10으로 유지됨
*/

-- ④ 에러 케이스 — 정적 파라미터에 SCOPE=BOTH 또는 SCOPE=MEMORY 시도
ALTER SYSTEM SET processes = 300 SCOPE=BOTH;

/*
 [결과] 에러 발생
   ERROR at line 1:
   ORA-02095: specified initialization parameter cannot be modified
   → 정적 파라미터는 SCOPE=SPFILE만 가능
*/

ALTER SYSTEM SET processes = 300 SCOPE=MEMORY;

/*
 [결과] 에러 발생
   ERROR at line 1:
   ORA-02095: specified initialization parameter cannot be modified
*/

-- 정적 파라미터는 반드시 SCOPE=SPFILE 사용
ALTER SYSTEM SET processes = 320 SCOPE=SPFILE;   -- 원래 값으로 복구
SHUTDOWN IMMEDIATE;
STARTUP;

SHOW PARAMETER processes;

/*
 [결과]
   NAME       TYPE     VALUE
   ---------- -------- -----
   processes  integer  320   ← 원래 값으로 복구 완료

 [SCOPE 옵션 정리]
   SCOPE     파라미터 종류      즉시 반영   재시작 후 유지
   --------- ------------------ ----------- --------------
   MEMORY    동적만 가능        O           X
   SPFILE    동적 + 정적 가능   X           O
   BOTH      동적만 가능        O           O
*/