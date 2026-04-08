/*
================================================================================
 Admin 실습 03: DB 수동 생성 & 네트워크 구성, DB 링크
================================================================================
 블로그: https://nsylove97.tistory.com/32
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio
 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1. 환경변수 설정 & 사전 준비 (새 OS 계정 produser 생성)
   2. DB 수동 생성 (PROD)
      STEP 1. 데이터파일 저장 디렉토리 생성
      STEP 2. 패스워드 파일 생성
      STEP 3. pfile (initPROD.ora) 작성
      STEP 4. NOMOUNT 단계 진입
      STEP 5. CREATE DATABASE 실행
      STEP 6. 데이터 딕셔너리 & SQL*Plus 환경 초기화
      STEP 7. 생성 결과 확인
      STEP 8. 클라이언트 방식으로 접속
   3. Oracle Net 설정 파일 직접 편집 (tnsnames.ora)
   4. 리스너 기본 관리
   5. 다중 리스너 구성
      5-1. listener.ora 직접 편집
      5-2. non-default 리스너에 인스턴스 수동 등록
      5-3. 포트별 접속 테스트
   6. Naming Methods 비교 (Easy Connect vs Local Naming)
   7. Database Link 실습
================================================================================
*/


/* ============================================================================
   1. 환경변수 설정 & 사전 준비
   ============================================================================
   ※ 이 섹션은 OS 명령어이므로 SQL*Plus 밖 터미널(MobaXterm)에서 실행
   ============================================================================ */

/*
 [STEP 1] 새 OS 계정 생성 — root 계정으로 실행
 -----------------------------------------------------------------------
   # 새 OS 유저 생성 및 dba 그룹에 추가
   useradd -G dba produser
   passwd produser
   (비밀번호 입력)

   [결과]
     Changing password for user produser.
     passwd: all authentication tokens updated successfully.

   # oracle 계정의 환경변수 파일을 produser 홈으로 복사
   cp /home/oracle/.bash_profile /home/produser/.bash_profile
   chown produser:produser /home/produser/.bash_profile

   [결과]
     ls -l /home/produser/.bash_profile
     -rw-r--r-- 1 produser produser ... .bash_profile  ← 소유자 변경 확인
*/

/*
 [STEP 2] produser 계정으로 전환 후 환경변수 설정
 -----------------------------------------------------------------------
   # produser 계정으로 전환
   su - produser

   # .bash_profile 편집
   vi ~/.bash_profile

   ── .bash_profile 내용 ──────────────────────────────────────────────
   export ORACLE_BASE=/u01/app/oracle
   export ORACLE_HOME=$ORACLE_BASE/product/19.3.0/dbhome
   export ORACLE_SID=PROD                     # 새로 만들 DB 이름
   export PATH=$ORACLE_HOME/bin:$PATH

   # tnsnames.ora 경로 자동 인식 설정
   export TNS_ADMIN=$ORACLE_HOME/network/admin
   alias tns='cd $ORACLE_HOME/network/admin'  # tns 입력만으로 해당 경로로 이동
   ────────────────────────────────────────────────────────────────────

   # 환경변수 즉시 반영
   . ~/.bash_profile

   # 반영 확인
   echo $ORACLE_SID    → PROD
   echo $ORACLE_HOME   → /u01/app/oracle/product/19.3.0/dbhome
   whoami              → produser

   # 현재 서버에 등록된 SID 목록 확인
   cat /etc/oratab

   [결과 예시]
     orcl:/u01/app/oracle/product/19.3.0/dbhome:Y
     → PROD는 아직 없음 (수동 생성 후 추가됨)
*/


/* ============================================================================
   2. DB 수동 생성 (PROD)
   ============================================================================ */

/* --------------------------------------------------------------------------
   STEP 1. 데이터파일 저장 디렉토리 생성
   --------------------------------------------------------------------------
   ※ 터미널에서 실행 (oracle 또는 root 계정)
   --------------------------------------------------------------------------

   # PROD DB 데이터파일 저장 디렉토리 생성
   mkdir -p /u02/oradata/PROD

   # 소유자 및 권한 설정
   # oracle:dba 소유, 775 권한 → DB 파일 생성·수정·삭제 가능
   chown -R oracle:dba /u02/oradata/PROD
   chmod -R 775 /u02/oradata/PROD

   # 생성 확인
   ls -l /u02/oradata/

   [결과]
     drwxrwxr-x 2 oracle dba 6 ... PROD   ← 디렉토리 생성 및 권한 설정 완료
*/

/* --------------------------------------------------------------------------
   STEP 2. 패스워드 파일 생성
   --------------------------------------------------------------------------
   ※ 터미널에서 실행 (oracle 계정)
   --------------------------------------------------------------------------

   # SYSDBA 인증을 위한 패스워드 파일 생성
   # 19c에서는 format=12, force=y 추가 필수
   orapwd file=$ORACLE_HOME/dbs/orapwPROD \
           password=oracle \
           entries=10 \
           format=12 \
           force=y

   # 생성 확인
   ls -l $ORACLE_HOME/dbs/orapwPROD

   [결과]
     -rw-r----- 1 oracle dba ... orapwPROD   ← 패스워드 파일 생성 완료
*/

/* --------------------------------------------------------------------------
   STEP 3. pfile (initPROD.ora) 작성
   --------------------------------------------------------------------------
   ※ 터미널에서 실행 — DB가 없는 상태에서는 spfile 사용 불가,
     텍스트 기반 pfile 필수 (vi로 직접 수정 가능)
   --------------------------------------------------------------------------

   vi $ORACLE_HOME/dbs/initPROD.ora

   ── initPROD.ora 내용 ────────────────────────────────────────────────
   db_name          = PROD           # 필수 01: DB 이름
   db_block_size    = 8192           # 필수 02: 블록 크기 (기본 8KB)
   memory_target    = 800M           # 자동 메모리 관리 (SGA+PGA 합산)
   processes        = 150            # 최대 프로세스 수
   undo_management  = AUTO           # Undo 자동 관리
   undo_tablespace  = UNDOTBS1
   control_files    = ('/u02/oradata/PROD/control01.ctl',
                       '/u02/oradata/PROD/control02.ctl')  # 필수 03: 다중화
   db_recovery_file_dest      = '/u01/app/oracle/fast_recovery_area'
   db_recovery_file_dest_size = 5G
   diagnostic_dest  = /u01/app/oracle
   ─────────────────────────────────────────────────────────────────────

   # 생성 확인
   ls -l $ORACLE_HOME/dbs/initPROD.ora
   cat  $ORACLE_HOME/dbs/initPROD.ora

   [결과]
     -rw-r--r-- 1 produser produser ... initPROD.ora   ← pfile 생성 완료
*/

/* --------------------------------------------------------------------------
   STEP 4. NOMOUNT 단계 진입
   --------------------------------------------------------------------------
   ※ produser 계정으로 SQL*Plus 실행
   -------------------------------------------------------------------------- */

-- SYSDBA로 접속 (패스워드 파일로 인증)
-- sqlplus / as sysdba

-- pfile로 NOMOUNT 단계 진입 (DB 파일 없이 인스턴스만 기동)
STARTUP NOMOUNT PFILE='$ORACLE_HOME/dbs/initPROD.ora';

/*
 [결과]
   ORACLE instance started.

   Total System Global Area  838860800 bytes
   Fixed Size                  8793304 bytes
   Variable Size             499122176 bytes
   Database Buffers          322961408 bytes
   Redo Buffers                7983104 bytes

   → 인스턴스(메모리 + 백그라운드 프로세스)만 기동된 상태
   → 컨트롤 파일, 데이터파일은 아직 없음
*/

/* --------------------------------------------------------------------------
   STEP 5. CREATE DATABASE 실행
   --------------------------------------------------------------------------
   ※ 실행 전 OS에서 createPROD.sql 파일을 작성해두고 @로 실행하는 방식 권장
      vi createPROD.sql → 아래 내용 저장 → SQL*Plus에서 @createPROD.sql
   -------------------------------------------------------------------------- */

CREATE DATABASE PROD
    USER SYS    IDENTIFIED BY oracle
    USER SYSTEM IDENTIFIED BY oracle
    LOGFILE
        GROUP 1 ('/u02/oradata/PROD/redo01a.log') SIZE 50M,
        GROUP 2 ('/u02/oradata/PROD/redo02a.log') SIZE 50M
    CHARACTER SET     AL32UTF8       -- 한글 포함 유니코드
    NATIONAL CHARACTER SET AL16UTF16
    DATAFILE        '/u02/oradata/PROD/system01.dbf'  SIZE 700M REUSE
    SYSAUX DATAFILE '/u02/oradata/PROD/sysaux01.dbf'  SIZE 600M REUSE
    DEFAULT TABLESPACE users
        DATAFILE '/u02/oradata/PROD/users01.dbf' SIZE 200M REUSE
        AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED
    DEFAULT TEMPORARY TABLESPACE temp
        TEMPFILE '/u02/oradata/PROD/temp01.dbf' SIZE 100M REUSE
    UNDO TABLESPACE UNDOTBS1
        DATAFILE '/u02/oradata/PROD/undotbs01.dbf' SIZE 200M REUSE
        AUTOEXTEND ON NEXT 50M MAXSIZE UNLIMITED;

/*
 [결과]
   Database created.

   → 생성된 파일 목록:
     /u02/oradata/PROD/control01.ctl    ← 컨트롤 파일 (pfile에서 지정)
     /u02/oradata/PROD/control02.ctl    ← 컨트롤 파일 다중화
     /u02/oradata/PROD/redo01a.log      ← Redo Log Group 1
     /u02/oradata/PROD/redo02a.log      ← Redo Log Group 2
     /u02/oradata/PROD/system01.dbf     ← SYSTEM 테이블스페이스
     /u02/oradata/PROD/sysaux01.dbf     ← SYSAUX 테이블스페이스
     /u02/oradata/PROD/users01.dbf      ← USERS 테이블스페이스
     /u02/oradata/PROD/temp01.dbf       ← TEMP 테이블스페이스 (tempfile)
     /u02/oradata/PROD/undotbs01.dbf    ← UNDO 테이블스페이스
*/

/* --------------------------------------------------------------------------
   STEP 6. 데이터 딕셔너리 & SQL*Plus 환경 초기화
   -------------------------------------------------------------------------- */

-- 데이터 딕셔너리 뷰 생성
-- DBA_TABLES, V$SESSION 등 관리용 뷰를 사용하려면 반드시 실행
-- (? 는 $ORACLE_HOME 환경변수를 의미)
@?/rdbms/admin/catalog.sql

/*
 [결과]
   수백 줄의 생성 메시지 출력
   → DBA_*, ALL_*, USER_* 딕셔너리 뷰 생성 완료
*/

-- PL/SQL 패키지 및 내장 함수 생성
-- DBMS_OUTPUT, UTL_FILE 등 기본 패키지를 사용하려면 반드시 실행
@?/rdbms/admin/catproc.sql

/*
 [결과]
   수백 줄의 생성 메시지 출력
   → 기본 PL/SQL 패키지 생성 완료
*/

-- SQL*Plus 전용 환경 초기화 (PRODUCT_USER_PROFILE 테이블 생성)
-- 반드시 SYSTEM 계정으로 실행해야 함
CONN system/oracle
@?/sqlplus/admin/pupbld.sql

/*
 [결과]
   여러 줄의 생성 메시지 출력
   → SQL*Plus 환경 초기화 완료
   (메시지가 출력돼도 에러가 없으면 정상)
*/

/* --------------------------------------------------------------------------
   STEP 7. 생성 결과 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- DB 이름 및 상태 확인
SELECT NAME, OPEN_MODE, DB_UNIQUE_NAME FROM V$DATABASE;

/*
 [결과]
   NAME    OPEN_MODE    DB_UNIQUE_NAME
   ------- ------------ --------------
   PROD    READ WRITE   PROD
*/

-- 테이블스페이스 생성 확인
SELECT TABLESPACE_NAME, STATUS, CONTENTS FROM DBA_TABLESPACES;

/*
 [결과]
   TABLESPACE_NAME    STATUS    CONTENTS
   ------------------ --------- ---------
   SYSTEM             ONLINE    PERMANENT
   SYSAUX             ONLINE    PERMANENT
   UNDOTBS1           ONLINE    UNDO
   TEMP               ONLINE    TEMPORARY
   USERS              ONLINE    PERMANENT
*/

-- 데이터파일 생성 확인
SELECT NAME FROM V$DATAFILE;

/*
 [결과]
   NAME
   --------------------------------------------
   /u02/oradata/PROD/system01.dbf
   /u02/oradata/PROD/sysaux01.dbf
   /u02/oradata/PROD/undotbs01.dbf
   /u02/oradata/PROD/users01.dbf
*/

/*
 [리스너에서 PROD 서비스 등록 확인] — 터미널에서 실행
   lsnrctl services

   [결과]
     Service "PROD" has 1 instance(s).
       Instance "PROD", status READY, has 1 handler(s) for this service...
     → PROD 서비스가 기본 리스너에 자동 등록됨
*/

/* --------------------------------------------------------------------------
   STEP 8. 클라이언트 방식으로 접속 확인
   --------------------------------------------------------------------------
   ※ 터미널에서 실행
   --------------------------------------------------------------------------

   # hostname 방식으로 PROD DB에 직접 접속
   sqlplus hr/hr@oel7vr:1521/PROD

   [결과]
     Connected to:
     Oracle Database 19c ...
     SQL> show user
     USER is "HR"    ← PROD DB의 hr 계정으로 접속 성공
*/


/* ============================================================================
   3. Oracle Net 설정 파일 직접 편집 (tnsnames.ora)
   ============================================================================
   ※ 파일 편집은 터미널에서, 접속 테스트는 터미널 또는 SQL*Plus에서 실행
   ============================================================================

   # 설정 파일 디렉토리로 이동 (.bash_profile에 alias 등록 시 tns 명령어로 이동)
   cd $ORACLE_HOME/network/admin

   # tnsnames.ora 신규 생성 (없는 경우)
   vi tnsnames.ora

   ── tnsnames.ora 내용 ────────────────────────────────────────────────
   ORCL =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = oel7vr)(PORT = 1521))
       (CONNECT_DATA =
         (SERVER = DEDICATED)
         (SERVICE_NAME = orcl)
       )
     )

   PROD =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = oel7vr)(PORT = 1521))
       (CONNECT_DATA =
         (SERVER = DEDICATED)
         (SERVICE_NAME = PROD)
       )
     )
   ─────────────────────────────────────────────────────────────────────
*/

/*
 [별칭 접속 테스트] — 터미널에서 실행

   # tnsping으로 연결 가능 여부 사전 확인
   tnsping ORCL

   [결과]
     OK (10 msec)   ← 연결 가능

   tnsping PROD

   [결과]
     OK (10 msec)   ← 연결 가능

   # 별칭으로 DB 접속
   sqlplus hr/hr@ORCL   → orcl DB 접속 성공
   sqlplus hr/hr@PROD   → PROD DB 접속 성공
*/


/* ============================================================================
   4. 리스너 기본 관리
   ============================================================================
   ※ 모두 터미널에서 실행
   ============================================================================

   # 리스너 상태 확인
   lsnrctl status

   [결과]
     LSNRCTL for Linux: Version 19.0.0.0.0 ...
     Connecting to (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oel7vr)(PORT=1521)))
     STATUS of the LISTENER
     ------------------------
     Alias                     LISTENER
     Version                   TNSLSNR for Linux: Version 19.0.0.0.0
     Start Date                ...
     Uptime                    0 days 0 hr. xx min. xx sec
     Trace Level               off
     Security                  ON: Local OS Authentication
     SNMP                      OFF
     Listener Parameter File   .../listener.ora
     Services Summary...
     Service "orcl" has 1 instance(s).
     Service "PROD" has 1 instance(s).
     The command completed successfully

   # 리스너가 관리 중인 서비스 목록 확인
   lsnrctl services

   # 사용 가능한 명령어 목록 확인
   lsnrctl help

   # Trace 레벨 설정 (실시간 적용 가능)
   lsnrctl set trc_level off      # 기록 안 함 (기본값)
   lsnrctl set trc_level user     # 일반 수준
   lsnrctl set trc_level admin    # 관리자 수준
   lsnrctl set trc_level support  # 가장 상세 (Oracle 지원팀용, 용량 주의)

   # 현재 Trace 레벨 확인
   lsnrctl show trc_level

   [결과]
     LSNRCTL for Linux ...
     Connecting to ...
     trc_level = off              ← 현재 off 상태 확인
     The command completed successfully
*/


/* ============================================================================
   5-1. 다중 리스너 구성 — listener.ora 직접 편집
   ============================================================================
   ※ 터미널에서 실행
   ============================================================================

   vi $ORACLE_HOME/network/admin/listener.ora

   ── listener.ora 내용 ────────────────────────────────────────────────
   # 기본 리스너 (1521 포트)
   LISTENER =
     (DESCRIPTION_LIST =
       (DESCRIPTION =
         (ADDRESS = (PROTOCOL = TCP)(HOST = oel7vr)(PORT = 1521))
       )
     )

   # 추가 리스너 lsnr1 (1522 포트)
   LSNR1 =
     (DESCRIPTION_LIST =
       (DESCRIPTION =
         (ADDRESS = (PROTOCOL = TCP)(HOST = oel7vr)(PORT = 1522))
       )
     )
   ─────────────────────────────────────────────────────────────────────

   # 추가 리스너 기동 (기본 리스너는 이미 실행 중)
   lsnrctl start lsnr1

   [결과]
     LSNRCTL for Linux ...
     Starting /u01/app/oracle/.../tnslsnr: please wait...
     TNSLSNR for Linux: Version 19.0.0.0.0
     Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=oel7vr)(PORT=1522)))
     ...
     The command completed successfully

   # 각 리스너 상태 확인
   lsnrctl status
   lsnrctl status lsnr1

   # lsnr1에 등록된 서비스 확인 (처음엔 없음 → 수동 등록 필요)
   lsnrctl services lsnr1

   [결과]
     (아무 서비스도 없음)   ← 아직 수동 등록 전
*/


/* ============================================================================
   5-2. non-default 리스너에 인스턴스 수동 등록
   ============================================================================ */

-- orcl DB에서 lsnr1(1522 포트)에 수동 등록
CONN / AS SYSDBA

ALTER SYSTEM SET local_listener =
    '(ADDRESS=(PROTOCOL=TCP)(HOST=oel7vr)(PORT=1522))'
    SCOPE=BOTH;

/*
 [결과]
   System altered.
*/

-- 인스턴스를 리스너에 즉시 등록 요청
ALTER SYSTEM REGISTER;

/*
 [결과]
   System altered.
*/

/*
 [등록 확인] — 터미널에서 실행
   lsnrctl services lsnr1

   [결과]
     Service "orcl" has 1 instance(s).
       Instance "orcl", status READY, has 1 handler(s) for this service...
     → orcl 서비스가 lsnr1에 등록됨
*/


/* ============================================================================
   5-3. 포트별 접속 테스트
   ============================================================================
   ※ 터미널에서 실행
   ============================================================================

   # 기본 리스너 정지
   lsnrctl stop

   # 1521 포트로 접속 시도 → 에러 확인
   sqlplus hr/hr@oel7vr:1521/orcl

   [결과]
     ERROR:
     ORA-12541: TNS:no listener   ← 기본 리스너 없으면 접속 불가

   # 1522 포트로 접속 시도 → 성공 확인
   sqlplus hr/hr@oel7vr:1522/orcl

   [결과]
     Connected to:
     Oracle Database 19c ...
     SQL> show user
     USER is "HR"   ← lsnr1(1522)을 통해 접속 성공

   # 기본 리스너 복구
   lsnrctl start
*/


/* ============================================================================
   6. Naming Methods 비교 실습
   ============================================================================
   ※ 터미널에서 실행
   ============================================================================

   [① Easy Connect — 설정 파일 없이 바로 접속]
   형식: sqlplus 계정/패스워드@호스트:포트/서비스명

   sqlplus hr/hr@oel7vr:1521/orcl   → orcl DB 접속 성공
   sqlplus hr/hr@oel7vr:1521/PROD   → PROD DB 접속 성공

   [② Local Naming — tnsnames.ora 별칭 사용]

   # tnsping으로 연결 가능 여부 사전 확인
   tnsping orcl   → OK (xx msec)
   tnsping PROD   → OK (xx msec)

   # 별칭으로 접속
   sqlplus hr/hr@orcl   → orcl DB 접속 성공
   sqlplus hr/hr@PROD   → PROD DB 접속 성공

   [Easy Connect vs Local Naming 비교]
   항목              Easy Connect          Local Naming
   ─────────────     ──────────────────    ─────────────────────
   설정 파일         불필요                tnsnames.ora 필요
   접속 형식         @호스트:포트/서비스    @별칭
   Failover/LB       미지원                지원
   보안성            낮음                  높음
   실무 사용         빠른 테스트용          운영 환경 표준
*/


/* ============================================================================
   7. Database Link 실습
   ============================================================================ */

-- PROD DB의 SYS 계정에서 hr에게 DB Link 생성 권한 부여
CONN / AS SYSDBA
GRANT CREATE DATABASE LINK TO hr;

/*
 [결과]
   Grant succeeded.
*/

-- hr 계정으로 접속
CONN hr/hr

-- DB Link 생성
-- 형식: CREATE DATABASE LINK 링크명
--         CONNECT TO 계정 IDENTIFIED BY 비번
--         USING 'tnsnames.ora에 등록된 서비스명';
CREATE DATABASE LINK remote_orcl
    CONNECT TO hr IDENTIFIED BY hr
    USING 'ORCL';

/*
 [결과]
   Database link created.
*/

-- DB Link를 통한 원격 테이블 조회 (테이블명@링크명)
-- PROD DB에서 orcl DB의 employees 테이블 조회
SELECT COUNT(*) FROM employees@remote_orcl;

/*
 [결과]
   COUNT(*)
   --------
   107       ← orcl DB의 employees 테이블 조회 성공
*/

-- 원격 테이블과 로컬 테이블 JOIN
SELECT l.employee_id, l.last_name, r.department_name
FROM   employees    l,
       departments@remote_orcl r
WHERE  l.department_id = r.department_id;

/*
 [결과]
   EMPLOYEE_ID  LAST_NAME    DEPARTMENT_NAME
   -----------  ------------ ----------------
   200          Whalen       Administration
   201          Hartstein    Marketing
   ...
*/

-- Synonym 생성 — @remote_orcl 없이 바로 테이블명으로 접근 가능하도록
CREATE SYNONYM remote_emp FOR employees@remote_orcl;

-- Synonym으로 간단하게 조회
SELECT COUNT(*) FROM remote_emp;

/*
 [결과]
   COUNT(*)
   --------
   107
*/

-- DB Link 목록 확인
SELECT DB_LINK, USERNAME, HOST FROM USER_DB_LINKS;

/*
 [결과]
   DB_LINK        USERNAME    HOST
   -------------- ----------- ----
   REMOTE_ORCL    HR          ORCL
*/

-- 실습 후 정리
DROP SYNONYM   remote_emp;
DROP DATABASE LINK remote_orcl;

/*
 [결과]
   Synonym dropped.
   Database link dropped.
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                   핵심 포인트
   ---------------------- ---------------------------------------------------
   DB 수동 생성           pfile 작성 → STARTUP NOMOUNT → CREATE DATABASE
   패스워드 파일          orapwd로 생성 (19c: format=12, force=y 필수)
   딕셔너리 초기화        catalog.sql → catproc.sql → pupbld.sql 순서 실행
   tnsnames.ora           별칭 등록 → @별칭으로 접속, tnsping으로 연결 테스트
   다중 리스너            listener.ora에 포트 추가 → lsnrctl start 리스너명
   non-default 리스너     ALTER SYSTEM SET local_listener + ALTER SYSTEM REGISTER
   DB Link                CREATE DATABASE LINK → 테이블@링크명으로 원격 조회
   Synonym                @링크명 없이 접근 가능하도록 별칭 생성

   ============================================================================ */
