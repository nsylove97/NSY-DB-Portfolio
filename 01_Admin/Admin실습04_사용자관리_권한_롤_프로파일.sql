/*
================================================================================
 Admin 실습 04: 사용자 관리 & 권한 / 롤 / 프로파일
================================================================================
 블로그: https://nsylove97.tistory.com/33
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1. 사용자 계정 구조 & Predefined 운영 계정
   2. Administrator Authentication (관리자 인증)
   3. External Authentication (외부 인증, OS 계정으로 DB 접속)
   4. 계정 잠금 해제 & 비밀번호 초기화
   5. 시스템 권한 (System Privilege)
   6. 오브젝트 권한 (Object Privilege)
   7. 롤 (Role)
   8. 프로파일 (Profile)
   9. 쿼타 (Quota)
================================================================================
*/


/* ============================================================================
   1. 사용자 계정 구조 & Predefined 운영 계정
   ============================================================================ */

/*
 오라클 DB 계정 구성 요소
 -----------------------------------------------------------------------
   Username            : 계정 이름
   Authentication      : 인증 방식 (비밀번호 / OS / External)
   Default Tablespace  : 객체를 저장할 기본 공간
   Temporary Tablespace: 정렬 등 임시 작업 공간
   Quota               : 테이블스페이스 사용 한도
   Profile             : 비밀번호 정책 & 리소스 제한
   Initial Consumer Group: 로그인 시 배정될 리소스 우선순위 그룹

 주요 Predefined 계정
 -----------------------------------------------------------------------
   SYS    : 최고 관리자. SYSDBA/SYSOPER 권한 포함. DB 핵심 작업 전용
   SYSTEM : SYS 다음 수준의 관리 계정. 일반 유지보수용
   DBSNMP : 모니터링 에이전트 전용 계정

   ※ 이 계정들은 일상 업무(개발, 쿼리 등)에 사용하지 않음
      실수나 해킹 시 피해가 너무 크므로 별도 계정을 만들어 사용하는 것이 원칙
*/

-- 현재 DB의 모든 사용자 목록 확인
SELECT USERNAME, ACCOUNT_STATUS, DEFAULT_TABLESPACE, CREATED
FROM DBA_USERS
ORDER BY CREATED;

/*
 [결과 일부]
   USERNAME    ACCOUNT_STATUS  DEFAULT_TABLESPACE  CREATED
   ----------  --------------  ------------------  -------
   SYS         OPEN            SYSTEM              ...
   SYSTEM      OPEN            SYSTEM              ...
   HR          OPEN            USERS               ...
   ...
*/


/* ============================================================================
   2. Administrator Authentication (관리자 인증)
   ============================================================================
   ※ OS 명령어는 터미널(MobaXterm)에서 실행
   ============================================================================ */

/*
 인증 방식 우선순위: OS 인증 → 패스워드 파일 인증
 -----------------------------------------------------------------------
   OS 인증         : OS 계정이 dba 그룹에 속하면 비밀번호 없이 SYSDBA 접속 가능
   Password File 인증: orapwd로 생성한 파일 기반 인증. 원격 SYSDBA 접속 시 필수

   # OS 인증 방식: 비밀번호 없이 바로 접속
   sqlplus / as sysdba

   [결과]
     Connected to:
     Oracle Database 19c ...
     SQL> show user
     USER is "SYS"   ← OS 인증으로 SYS 접속 성공

   # 기존 패스워드 파일 확인
   ls -l $ORACLE_HOME/dbs/orapw<ORACLE_SID>

   [결과]
     -rw-r----- 1 oracle dba ... orapworcl   ← 기존 패스워드 파일 존재

   # 홈 디렉토리에 새로운 패스워드 파일 생성 (19c 기준)
   orapwd file=/home/oracle/orapworcl \
           password=oracle \
           entries=10 \
           format=12 \
           force=y

   [결과]
     ls -l /home/oracle/orapworcl
     -rw-r----- 1 oracle dba ... orapworcl   ← 패스워드 파일 생성 완료
*/

-- 패스워드 파일로 인증된 사용자 목록 확인
-- ※ 패스워드 파일은 대소문자를 구분한다
SELECT * FROM V$PWFILE_USERS;

/*
 [결과]
   USERNAME    SYSDB  SYSOP  SYSAS
   ----------  -----  -----  -----
   SYS         TRUE   TRUE   FALSE   ← SYS 계정 하나만 존재
*/


/* ============================================================================
   3. External Authentication (외부 인증, OS 계정으로 DB 접속)
   ============================================================================
   ※ OS 명령어는 터미널(MobaXterm)에서 실행
   ============================================================================ */

/*
 [STEP 1] OS 계정 생성 — root 계정으로 실행
 -----------------------------------------------------------------------
   # OS 계정 stud 생성
   useradd stud
   passwd stud
   (비밀번호 입력)

   [결과]
     Changing password for user stud.
     passwd: all authentication tokens updated successfully.

   # oracle 계정 환경변수 파일을 stud 홈으로 복사 후 소유권 변경
   cp /home/oracle/.bash_profile /home/stud/.bash_profile
   chown stud:stud /home/stud/.bash_profile

   [결과]
     ls -l /home/stud/.bash_profile
     -rw-r--r-- 1 stud stud ... .bash_profile   ← 소유자 변경 확인
*/

-- [STEP 2] SYS 계정에서 Oracle DB 계정 생성
CONN / AS SYSDBA

-- OS 계정과 연결하려면 계정명 앞에 OPS$ 붙이기
-- ops$stud: OS 계정 stud가 DB에 접속하면 자동으로 이 계정으로 매핑됨
CREATE USER ops$stud IDENTIFIED EXTERNALLY;

-- 접속 및 객체 생성 권한 부여
GRANT CONNECT, RESOURCE TO ops$stud;

-- 생성 확인
SELECT USERNAME, AUTHENTICATION_TYPE
FROM DBA_USERS
WHERE USERNAME = 'OPS$STUD';

/*
 [결과]
   USERNAME    AUTHENTICATION_TYPE
   ----------  -------------------
   OPS$STUD    EXTERNAL            ← External 인증 방식으로 생성 확인
*/

/*
 [STEP 3] OS stud 계정으로 전환 후 비밀번호 없이 접속 확인 — 터미널에서 실행
 -----------------------------------------------------------------------
   # stud 계정으로 전환
   su - stud

   # 비밀번호 입력 없이 접속
   sqlplus /

   [결과]
     Connected to:
     Oracle Database 19c ...
     SQL> show user
     USER is "OPS$STUD"   ← OS 계정으로 비밀번호 없이 접속 성공
*/

-- 번외: OS 관련 인증 파라미터 확인
SHOW PARAMETER os_

/*
 [결과]
   NAME                  TYPE    VALUE
   --------------------  ------  -----
   os_authent_prefix     string  OPS$    ← OS 인증 사용자 접두어 (기본값)
   os_roles              boolean FALSE   ← OS 역할을 DB 역할로 사용할 수 있는지 여부
*/


/* ============================================================================
   4. 계정 잠금 해제 & 비밀번호 초기화
   ============================================================================ */

CONN / AS SYSDBA

-- 잠긴 계정 목록 확인
SELECT USERNAME, ACCOUNT_STATUS
FROM DBA_USERS
WHERE ACCOUNT_STATUS != 'OPEN'
ORDER BY ACCOUNT_STATUS;

/*
 [결과 일부]
   USERNAME          ACCOUNT_STATUS
   ----------------  ----------------
   DBSNMP            LOCKED
   XDB               LOCKED
   ...
   CTXSYS            EXPIRED & LOCKED
   ANONYMOUS         EXPIRED & LOCKED
   ...
*/

-- LOCKED 상태 계정 잠금 해제 (DBSNMP)
ALTER USER dbsnmp ACCOUNT UNLOCK;

/*
 [결과]
   User altered.
*/

-- EXPIRED & LOCKED 상태 계정: 비밀번호 초기화 + 잠금 해제 동시에 (CTXSYS)
-- EXPIRED 상태는 UNLOCK만으로는 안 됨 → 비밀번호도 같이 설정해야 함
ALTER USER ctxsys
    IDENTIFIED BY ctxsys
    ACCOUNT UNLOCK;

/*
 [결과]
   User altered.
*/

-- 적용 확인
SELECT USERNAME, ACCOUNT_STATUS
FROM DBA_USERS
WHERE USERNAME IN ('DBSNMP', 'CTXSYS');

/*
 [결과]
   USERNAME   ACCOUNT_STATUS
   ---------  --------------
   DBSNMP     OPEN            ← 잠금 해제 확인
   CTXSYS     OPEN            ← 비밀번호 초기화 + 잠금 해제 확인
*/

-- 실습 후 다시 잠금 처리 (시스템 계정은 평소에 잠가두는 것이 보안상 이로움)
ALTER USER dbsnmp ACCOUNT LOCK;
ALTER USER ctxsys ACCOUNT LOCK;

/*
 [결과]
   User altered.
   User altered.

   USERNAME   ACCOUNT_STATUS
   ---------  --------------
   DBSNMP     LOCKED          ← 원상 복구 확인
   CTXSYS     LOCKED          ← 원상 복구 확인
*/


/* ============================================================================
   5. 시스템 권한 (System Privilege)
   ============================================================================ */

CONN / AS SYSDBA

-- 시스템 권한은 DB 전체 차원에서 특정 작업을 할 수 있는 권한 (주로 DDL 관련)
-- ANY가 붙으면 모든 스키마에 영향 → 주의 필요

-- 권한 부여할 유저 생성
CREATE USER spuser IDENTIFIED BY spuser;

/*
 [결과]
   User created.
*/

-- 시스템 권한 부여
GRANT CREATE SESSION TO spuser;
GRANT CREATE TABLE   TO spuser;

-- ANY 권한: 다른 스키마에도 테이블 생성 가능 (주의)
GRANT CREATE ANY TABLE TO spuser;

-- ADMIN OPTION: 받은 권한을 다른 사용자에게 줄 수 있는 능력
-- ※ ADMIN OPTION으로 부여한 권한을 회수해도
--    spuser가 다른 사람에게 전파한 권한은 함께 회수되지 않음 (연쇄 회수 없음)
GRANT CREATE TABLE TO spuser WITH ADMIN OPTION;

/*
 [결과]
   Grant succeeded.
*/

-- 시스템 권한 회수
REVOKE CREATE ANY TABLE FROM spuser;

/*
 [결과]
   Revoke succeeded.
*/

-- 사용자에게 부여된 시스템 권한 확인
SELECT PRIVILEGE, ADMIN_OPTION
FROM DBA_SYS_PRIVS
WHERE GRANTEE = 'SPUSER';

/*
 [결과]
   PRIVILEGE       ADMIN_OPTION
   --------------  ------------
   CREATE SESSION  NO
   CREATE TABLE    YES          ← ADMIN OPTION으로 부여됨
*/

-- spuser 계정에서 본인 권한 확인
CONN spuser/spuser
SELECT * FROM USER_SYS_PRIVS;

/*
 [결과]
   USERNAME  PRIVILEGE       ADMIN_OPTION
   --------  --------------  ------------
   SPUSER    CREATE SESSION  NO
   SPUSER    CREATE TABLE    YES
*/


/* ============================================================================
   6. 오브젝트 권한 (Object Privilege)
   ============================================================================ */

CONN / AS SYSDBA

-- 오브젝트 권한: 특정 오브젝트에 대해 접근·조작할 수 있는 권한
-- (SELECT, INSERT, UPDATE, DELETE 등)

-- spuser가 hr의 employees 테이블을 SELECT할 수 있도록 권한 부여
GRANT SELECT ON hr.employees TO spuser;

/*
 [결과]
   Grant succeeded.
*/

-- spuser에서 hr.employees 조회 테스트
CONN spuser/spuser
SELECT COUNT(*) FROM hr.employees;

/*
 [결과]
   COUNT(*)
   --------
   107       ← 권한 부여 후 조회 성공
*/

-- GRANT OPTION: 받은 권한을 다른 사용자에게 줄 수 있는 능력
-- ※ GRANT OPTION으로 부여한 권한을 회수하면 연쇄 회수 발생
--   (ADMIN OPTION과 달리, 전파된 권한도 함께 회수됨)
CONN / AS SYSDBA
GRANT SELECT ON hr.employees TO spuser WITH GRANT OPTION;

/*
 [결과]
   Grant succeeded.
*/

-- 사용자가 받은 오브젝트 권한 확인 (SYS에서)
SELECT TABLE_NAME, PRIVILEGE, GRANTABLE
FROM DBA_TAB_PRIVS
WHERE GRANTEE = 'SPUSER';

/*
 [결과]
   TABLE_NAME   PRIVILEGE  GRANTABLE
   -----------  ---------  ---------
   EMPLOYEES    SELECT     YES        ← GRANT OPTION으로 부여됨
*/

-- spuser에서 본인 오브젝트 권한 확인
CONN spuser/spuser
SELECT * FROM USER_TAB_PRIVS;

/*
 [결과]
   GRANTEE  OWNER  TABLE_NAME   GRANTOR  PRIVILEGE  GRANTABLE
   -------  -----  -----------  -------  ---------  ---------
   SPUSER   HR     EMPLOYEES    SYS      SELECT     YES
*/

-- 오브젝트 권한 회수
CONN / AS SYSDBA
REVOKE SELECT ON hr.employees FROM spuser;

/*
 [결과]
   Revoke succeeded.
*/

-- 회수 확인
CONN spuser/spuser
SELECT * FROM USER_TAB_PRIVS;

/*
 [결과]
   선택된 행 없음   ← 오브젝트 권한 회수 확인
*/

/*
 ADMIN OPTION vs GRANT OPTION 비교
 -----------------------------------------------------------------------
                     ADMIN OPTION (시스템 권한)   GRANT OPTION (오브젝트 권한)
   전파              받은 권한을 타인에게 줄 수 있음  받은 권한을 타인에게 줄 수 있음
   회수 시 연쇄      연쇄 회수 없음                  연쇄 회수 발생
*/


/* ============================================================================
   7. 롤 (Role)
   ============================================================================ */

CONN / AS SYSDBA

-- 롤: 여러 권한을 묶은 권한 그룹
-- 개별 사용자에게 일일이 권한을 주는 대신 롤 하나를 부여해서 효율적으로 권한 관리 가능

-- 주요 기본 제공 롤
--   CONNECT           : CREATE SESSION (DB 로그인)
--   RESOURCE          : CREATE TABLE, CREATE PROCEDURE 등 + UNLIMITED TABLESPACE ※주의
--   DBA               : 대부분의 시스템 권한
--   SELECT_CATALOG_ROLE: 데이터 딕셔너리 조회 권한 (DBA_TABLES 등)

-- 롤 생성
CREATE ROLE r1;
CREATE ROLE r2;

/*
 [결과]
   Role created.
   Role created.
*/

-- 롤에 시스템 권한 부여
GRANT CREATE SESSION TO r1;
GRANT CREATE TABLE   TO r1;
GRANT SELECT ANY TABLE TO r2;

-- 롤에 다른 롤 부여 (롤 중첩: r2가 r1의 권한도 포함하게 됨)
GRANT r1 TO r2;

-- 롤 부여할 사용자 생성
CREATE USER ruser IDENTIFIED BY ruser;

-- 사용자에게 롤 부여
GRANT r2 TO ruser;

/*
 [결과]
   Grant succeeded.
*/

-- ruser에게 부여된 롤 확인
SELECT GRANTED_ROLE, ADMIN_OPTION, DEFAULT_ROLE
FROM DBA_ROLE_PRIVS
WHERE GRANTEE = 'RUSER';

/*
 [결과]
   GRANTED_ROLE  ADMIN_OPTION  DEFAULT_ROLE
   ------------  ------------  ------------
   R2            NO            YES
*/

-- r2에 포함된 권한 확인 (중첩된 r1 포함)
SELECT ROLE, PRIVILEGE FROM ROLE_SYS_PRIVS
WHERE ROLE IN ('R1', 'R2')
ORDER BY ROLE;

/*
 [결과]
   ROLE  PRIVILEGE
   ----  ----------------
   R1    CREATE SESSION
   R1    CREATE TABLE
   R2    SELECT ANY TABLE
*/

-- 롤 회수
REVOKE r2 FROM ruser;

/*
 [결과]
   Revoke succeeded.
*/

-- 회수 확인
SELECT GRANTED_ROLE FROM DBA_ROLE_PRIVS
WHERE GRANTEE = 'RUSER';

/*
 [결과]
   선택된 행 없음   ← 롤 회수 확인
*/

-- 롤 삭제
DROP ROLE r2;

/*
 [결과]
   Role dropped.
*/

-- ※ 롤은 로그인 후에야 활성화됨 (단, CONNECT 롤은 예외)
-- 특정 롤만 활성화하려면 SET ROLE 사용
-- SET ROLE r1;

-- 현재 세션에서 활성화된 롤 확인
-- SELECT * FROM SESSION_ROLES;


/* ============================================================================
   8. 프로파일 (Profile)
   ============================================================================ */

CONN / AS SYSDBA

-- 프로파일: 사용자의 비밀번호 정책과 리소스 사용량을 관리하는 설정
-- 기본 규칙
--   - 한 사용자에게 동시에 하나의 프로파일만 지정 가능
--   - 변경 시 다음 로그인부터 적용
--   - 모든 사용자는 기본적으로 DEFAULT 프로파일을 가짐
--   - 리소스 제한이 실제로 동작하려면 RESOURCE_LIMIT = TRUE 설정 필수
--     (비밀번호 정책은 이 설정과 무관하게 항상 적용)

-- 리소스 제한 활성화 (필수)
ALTER SYSTEM SET RESOURCE_LIMIT = TRUE;

/*
 [결과]
   System altered.
*/

-- 프로파일 생성 (비밀번호 3번 틀리면 계정 잠금)
CREATE PROFILE secure_profile LIMIT
    FAILED_LOGIN_ATTEMPTS   3          -- 3번 틀리면 잠금
    PASSWORD_LOCK_TIME      1/24       -- 1시간 잠금 (일 단위이므로 1/24)
    PASSWORD_LIFE_TIME      60         -- 60일마다 만료
    PASSWORD_GRACE_TIME     7          -- 만료 후 7일 유예
    PASSWORD_REUSE_TIME     365        -- 365일 후 재사용 가능
    PASSWORD_REUSE_MAX      10;        -- 10번 바꾼 후 재사용 가능

/*
 [결과]
   Profile created.
*/

-- 프로파일 적용할 유저 생성
CREATE USER puser IDENTIFIED BY puser;

-- 사용자에게 프로파일 적용
ALTER USER puser PROFILE secure_profile;
GRANT CREATE SESSION TO puser;

/*
 [결과]
   User altered.
*/

-- 적용 확인
SELECT USERNAME, PROFILE
FROM DBA_USERS
WHERE USERNAME = 'PUSER';

/*
 [결과]
   USERNAME  PROFILE
   --------  --------------
   PUSER     SECURE_PROFILE  ← 프로파일 적용 확인
*/

-- 프로파일 상세 확인
SELECT RESOURCE_NAME, LIMIT
FROM DBA_PROFILES
WHERE PROFILE = 'SECURE_PROFILE';

/*
 [결과]
   RESOURCE_NAME           LIMIT
   ----------------------  -----
   FAILED_LOGIN_ATTEMPTS   3
   PASSWORD_LOCK_TIME      .04167   (= 1/24)
   PASSWORD_LIFE_TIME      60
   PASSWORD_GRACE_TIME     7
   PASSWORD_REUSE_TIME     365
   PASSWORD_REUSE_MAX      10
   ...
*/

-- 비밀번호를 일부러 3번 틀려서 계정 잠금 재현
-- sqlplus puser/wrongpw   → 1회 실패
-- sqlplus puser/wrongpw   → 2회 실패
-- sqlplus puser/wrongpw   → 3회 실패 → 계정 잠김

-- 잠금 확인
SELECT USERNAME, ACCOUNT_STATUS
FROM DBA_USERS
WHERE USERNAME = 'PUSER';

/*
 [결과]
   USERNAME  ACCOUNT_STATUS
   --------  --------------
   PUSER     LOCKED          ← 3회 실패로 계정 잠김
*/

-- 잠금 해제
ALTER USER puser ACCOUNT UNLOCK;

-- 또는 잠금 해제 + 비밀번호 초기화 동시에
ALTER USER puser IDENTIFIED BY puser1 ACCOUNT UNLOCK;

/*
 [결과]
   User altered.
*/

-- 잠금 해제 확인
SELECT USERNAME, ACCOUNT_STATUS
FROM DBA_USERS
WHERE USERNAME = 'PUSER';

/*
 [결과]
   USERNAME  ACCOUNT_STATUS
   --------  --------------
   PUSER     OPEN            ← 잠금 해제 확인
*/


/* ============================================================================
   9. 쿼타 (Quota)
   ============================================================================ */

CONN / AS SYSDBA

-- 쿼타: 사용자가 특정 테이블스페이스 안에서 사용할 수 있는 공간의 양
-- ※ 기본적으로 유저는 쿼타가 없으면 객체를 생성할 수 없음
-- ※ UNLIMITED TABLESPACE 시스템 권한을 가지면 쿼타 제한 없이 사용 가능
--   → 단, UNLIMITED TABLESPACE 권한이 있으면 쿼타 설정이 무의미해짐

-- 쿼타 부여 (100M)
ALTER USER puser QUOTA 100M ON users;

/*
 [결과]
   User altered.
*/

-- 쿼타 확인
SELECT TABLESPACE_NAME, BYTES, MAX_BYTES
FROM DBA_TS_QUOTAS
WHERE USERNAME = 'PUSER';

/*
 [결과]
   TABLESPACE_NAME  BYTES  MAX_BYTES
   ---------------  -----  ---------
   USERS            0      104857600   (= 100MB)
*/

-- 쿼타 무제한으로 변경
ALTER USER puser QUOTA UNLIMITED ON users;

/*
 [결과]
   User altered.
*/

-- 쿼타 확인 (MAX_BYTES = -1 이면 무제한)
SELECT TABLESPACE_NAME, BYTES, MAX_BYTES
FROM DBA_TS_QUOTAS
WHERE USERNAME = 'PUSER';

/*
 [결과]
   TABLESPACE_NAME  BYTES  MAX_BYTES
   ---------------  -----  ---------
   USERS            0      -1          ← -1 = 무제한
*/

-- 쿼타 회수 (0으로 설정)
ALTER USER puser QUOTA 0 ON users;

/*
 [결과]
   User altered.
*/

-- 쿼타 회수 확인 (조회 불가)
SELECT TABLESPACE_NAME, BYTES, MAX_BYTES
FROM DBA_TS_QUOTAS
WHERE USERNAME = 'PUSER';

/*
 [결과]
   선택된 행 없음   ← 쿼타 회수 확인
*/

-- 실습 후 정리
DROP USER spuser CASCADE;
DROP USER ruser  CASCADE;
DROP USER puser  CASCADE;
DROP ROLE r1;
DROP PROFILE secure_profile;

/*
 [결과]
   User dropped.
   User dropped.
   User dropped.
   Role dropped.
   Profile dropped.
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                 핵심 포인트
   -------------------- ----------------------------------------------------------
   Predefined 계정      SYS / SYSTEM은 일상 업무에 사용 금지
   Admin 인증           OS 인증 → 패스워드 파일 인증 순으로 적용
   External 인증        OPS$계정명으로 생성, OS 로그인으로 DB 접속
   계정 잠금 해제       ALTER USER ... ACCOUNT UNLOCK
                        EXPIRED & LOCKED는 IDENTIFIED BY 비밀번호도 함께 필요
   시스템 권한          GRANT ... WITH ADMIN OPTION (연쇄 회수 없음)
   오브젝트 권한        GRANT ... WITH GRANT OPTION (연쇄 회수 발생)
   롤                   권한 묶음. 로그인 후 활성화 (CONNECT 제외)
   프로파일             비밀번호 정책 + 리소스 제한. RESOURCE_LIMIT=TRUE 필수
   쿼타                 ALTER USER ... QUOTA. UNLIMITED TABLESPACE 권한 있으면 쿼타 무의미

   ============================================================================ */
