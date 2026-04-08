/*
================================================================================
 Admin 실습 02: 테이블스페이스
================================================================================
 블로그: https://nsylove97.tistory.com/14
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1. 딕셔너리 뷰 조회
   2. Permanent Tablespace 생성
      2-1. 기본 생성 (LMT / AUTOALLOCATE)
      2-2. 익스텐트 할당 방식 비교 (UNIFORM vs AUTOALLOCATE)
      2-3. AUTOEXTEND 옵션
   3. 용량 부족 상황 재현 & 데이터파일 추가
   4. Default Tablespace 생성 & 유저 배정
   5. Tablespace OFFLINE / READ ONLY 전환
   6. Tablespace DROP
      6-1. 테이블스페이스만 삭제 (데이터파일 OS에 남음)
      6-2. 테이블스페이스 + 데이터파일 완전 삭제
      6-3. 데이터파일만 따로 삭제
   7. Temporary Tablespace 생성
      7-1. 기본 생성
      7-2. Temporary Tablespace Group
   8. OMF (Oracle-Managed Files)
================================================================================
*/



-- 1. 딕셔너리 뷰 조회


-- DB에 존재하는 모든 데이터파일 경로 조회
SELECT NAME FROM V$DATAFILE;

/*
 [결과]
   NAME
   -----------------------------------------------
   /u01/app/oracle/oradata/ORCL/system01.dbf
   /u01/app/oracle/oradata/ORCL/sysaux01.dbf
   /u01/app/oracle/oradata/ORCL/undotbs01.dbf
   /u01/app/oracle/oradata/ORCL/users01.dbf
*/

-- 테이블스페이스 목록 조회
SELECT TABLESPACE_NAME, STATUS, CONTENTS
FROM DBA_TABLESPACES;

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

-- 테이블스페이스별 데이터파일 조회
SELECT TABLESPACE_NAME, FILE_NAME, BYTES/1024/1024 AS SIZE_MB
FROM DBA_DATA_FILES;

/*
 [결과]
   TABLESPACE_NAME    FILE_NAME                                      SIZE_MB
   ------------------ ---------------------------------------------- -------
   SYSTEM             /u01/app/oracle/oradata/ORCL/system01.dbf      870
   SYSAUX             /u01/app/oracle/oradata/ORCL/sysaux01.dbf      560
   UNDOTBS1           /u01/app/oracle/oradata/ORCL/undotbs01.dbf     225
   USERS              /u01/app/oracle/oradata/ORCL/users01.dbf       5
*/



-- 2-1. Permanent Tablespace 기본 생성 (LMT / AUTOALLOCATE)


-- Locally Managed Tablespace (LMT) 방식으로 생성 (Default)
CREATE TABLESPACE inventory
DATAFILE '/u01/app/oracle/oradata/ORCL/inventory01.dbf' SIZE 100M
EXTENT MANAGEMENT LOCAL     -- LMT 방식 (Default)
AUTOALLOCATE;               -- 오라클이 자동으로 익스텐트 크기 결정

/*
 [결과]
   Tablespace created.
*/

-- LMT 방식으로 생성된 것 확인
SELECT TABLESPACE_NAME, EXTENT_MANAGEMENT, ALLOCATION_TYPE
FROM DBA_TABLESPACES
WHERE TABLESPACE_NAME = 'INVENTORY';

/*
 [결과]
   TABLESPACE_NAME    EXTENT_MANAGEMENT    ALLOCATION_TYPE
   ------------------ -------------------- ---------------
   INVENTORY          LOCAL                SYSTEM           ← LMT + AUTOALLOCATE

 [LMT vs DMT 비교]
   DMT: 데이터 딕셔너리가 공간 관리 → 느림 (구버전)
   LMT: 테이블스페이스 자체 비트맵으로 관리 → 빠름 
*/

-- 2-2. 익스텐트 할당 방식 비교 (UNIFORM vs AUTOALLOCATE)


-- UNIFORM: 익스텐트를 항상 동일한 크기로 할당
CREATE TABLESPACE sample_uniform
DATAFILE '/u01/app/oracle/oradata/ORCL/sample_uni01.dbf' SIZE 100M
UNIFORM SIZE 1M;            -- 1MB씩 동일하게 할당

/*
 [결과]
   Tablespace created.
*/

-- AUTOALLOCATE: Oracle이 자동으로 적절한 크기 결정 (default)
CREATE TABLESPACE sample_auto
DATAFILE '/u01/app/oracle/oradata/ORCL/sample_auto01.dbf' SIZE 100M
AUTOALLOCATE;

/*
 [결과]
   Tablespace created.
*/

-- 두 방식 비교 확인
SELECT TABLESPACE_NAME, ALLOCATION_TYPE, NEXT_EXTENT/1024/1024 AS NEXT_EXTENT_MB
FROM DBA_TABLESPACES
WHERE TABLESPACE_NAME IN ('SAMPLE_UNIFORM', 'SAMPLE_AUTO');

/*
 [결과]
   TABLESPACE_NAME    ALLOCATION_TYPE    NEXT_EXTENT_MB
   ------------------ ------------------ --------------
   SAMPLE_UNIFORM     UNIFORM            1              ← 항상 1MB 고정
   SAMPLE_AUTO        SYSTEM             (null)         ← Oracle이 자동 결정

 [UNIFORM vs AUTOALLOCATE 비교]
   UNIFORM      : 항상 동일한 크기 → 공간 낭비 없음, 예측 가능
   AUTOALLOCATE : 오라클이 자동 결정 → 처음엔 작게, 점차 크게 할당
*/



-- 2-3. AUTOEXTEND 옵션 — 데이터파일 자동 크기 확장


-- 데이터파일이 꽉 차면 자동으로 늘어나도록 설정
CREATE TABLESPACE inventory2
DATAFILE '/u01/app/oracle/oradata/ORCL/inventory02.dbf' SIZE 100M
AUTOEXTEND ON               -- 자동 확장 켜기
NEXT 50M                    -- 한 번에 50MB씩 늘어남
MAXSIZE 500M;               -- 최대 500MB까지만

/*
 [결과]
   Tablespace created.
*/

-- AUTOEXTEND 설정 확인
SELECT
    TABLESPACE_NAME,
    FILE_NAME,
    BYTES/1024/1024                    AS CURRENT_SIZE_MB,
    AUTOEXTENSIBLE,
    INCREMENT_BY * 8192/1024/1024      AS NEXT_MB,
    MAXBYTES/1024/1024                 AS MAX_SIZE_MB
FROM DBA_DATA_FILES
WHERE TABLESPACE_NAME = 'INVENTORY2';

/*
 [결과]
   TABLESPACE_NAME    FILE_NAME               CURRENT_SIZE_MB  AUTOEXTENSIBLE  NEXT_MB  MAX_SIZE_MB
   ------------------ ----------------------- ---------------  --------------  -------  -----------
   INVENTORY2         .../inventory02.dbf     100              YES             50       500

 OS에서 실제 파일 크기 확인:
   !ls -lh /u01/app/oracle/oradata/ORCL/inventory02.dbf
   → -rw-r----- 1 oracle oinstall 101M ... inventory02.dbf
*/


-- 3. 용량 부족 상황 재현 & 데이터파일 추가


-- HR의 employees 테이블을 inventory 테이블스페이스에 복사
CREATE TABLE emp3
    TABLESPACE inventory
    AS SELECT * FROM hr.employees;

/*
 [결과]
   Table created.
*/

-- 용량이 찰 때까지 반복 INSERT
INSERT INTO emp3 SELECT * FROM emp3;
INSERT INTO emp3 SELECT * FROM emp3;
INSERT INTO emp3 SELECT * FROM emp3;
INSERT INTO emp3 SELECT * FROM emp3;
INSERT INTO emp3 SELECT * FROM emp3;
INSERT INTO emp3 SELECT * FROM emp3;
INSERT INTO emp3 SELECT * FROM emp3;

/*
 [결과] 반복하다 보면 아래 에러 발생
   ERROR at line 1:
   ORA-01653: unable to extend table SYS.EMP3 by 128 in tablespace INVENTORY
   → 100MB 다 찼음
*/

-- 기존 테이블스페이스에 새 데이터파일 추가로 용량 확장
ALTER TABLESPACE inventory
ADD DATAFILE '/u01/app/oracle/oradata/ORCL/inventory01_1.dbf' SIZE 100M;

/*
 [결과]
   Tablespace altered.
*/

-- 추가된 데이터파일 확인
SELECT TABLESPACE_NAME, FILE_NAME, BYTES/1024/1024 AS SIZE_MB
FROM DBA_DATA_FILES
WHERE TABLESPACE_NAME = 'INVENTORY';

/*
 [결과]
   TABLESPACE_NAME    FILE_NAME                    SIZE_MB
   ------------------ ---------------------------- -------
   INVENTORY          .../inventory01.dbf          100
   INVENTORY          .../inventory01_1.dbf        100     ← 새로 추가됨
*/

-- 용량 확장 후 INSERT 재시도
INSERT INTO emp3 SELECT * FROM emp3;
COMMIT;

/*
 [결과]
   xxx rows created.   ← 정상 INSERT 성공
*/



-- 4. Default Tablespace 생성 & 유저 배정


-- 1. 새 테이블스페이스 생성
CREATE TABLESPACE userdata
DATAFILE '/u01/app/oracle/oradata/ORCL/userdata01.dbf' SIZE 200M;

/*
 [결과]
   Tablespace created.
*/

-- 2. DB 전체의 기본 테이블스페이스로 지정
ALTER DATABASE DEFAULT TABLESPACE userdata;

/*
 [결과]
   Database altered.
*/

-- 3. 해당 테이블스페이스에 새 유저 생성
CREATE USER uduser
IDENTIFIED BY uduser
DEFAULT TABLESPACE userdata        -- 기본 저장 공간
TEMPORARY TABLESPACE temp;         -- 임시 작업 공간

/*
 [결과]
   User created.
*/

-- 4. 유저와 테이블스페이스 배정 확인
SELECT USERNAME, DEFAULT_TABLESPACE, TEMPORARY_TABLESPACE
FROM DBA_USERS
WHERE USERNAME = 'UDUSER';

/*
 [결과]
   USERNAME    DEFAULT_TABLESPACE    TEMPORARY_TABLESPACE
   ----------- --------------------- --------------------
   UDUSER      USERDATA              TEMP
*/


-- 5. Tablespace OFFLINE / READ ONLY 전환


-- [OFFLINE 실습]

-- 테이블스페이스 OFFLINE (백업/유지보수 시 사용)
ALTER TABLESPACE inventory OFFLINE;

/*
 [결과]
   Tablespace altered.
*/

-- OFFLINE 상태 확인
SELECT TABLESPACE_NAME, STATUS
FROM DBA_TABLESPACES
WHERE TABLESPACE_NAME = 'INVENTORY';

/*
 [결과]
   TABLESPACE_NAME    STATUS
   ------------------ -------
   INVENTORY          OFFLINE
*/

-- OFFLINE 상태에서 접근 시도 → 에러 확인
SELECT * FROM emp3;

/*
 [결과]
   ERROR at line 1:
   ORA-00376: file 5 cannot be read at this time
   ORA-01110: data file 5: '/u01/app/oracle/oradata/ORCL/inventory01.dbf'
*/

-- 다시 ONLINE으로 복구
ALTER TABLESPACE inventory ONLINE;

/*
 [결과]
   Tablespace altered.
*/

-- ONLINE 확인 후 조회 가능한지 확인
SELECT TABLESPACE_NAME, STATUS
FROM DBA_TABLESPACES
WHERE TABLESPACE_NAME = 'INVENTORY';

/*
 [결과]
   TABLESPACE_NAME    STATUS
   ------------------ ------
   INVENTORY          ONLINE
*/

SELECT COUNT(*) FROM emp3;   -- 정상 조회 확인

/*
 [결과]
   COUNT(*)
   --------
   xxxxxxxx   ← 정상 조회됨
*/

-- -----------------------------------------------------------------------

-- [READ ONLY 전환 실습]

-- READ ONLY 전환 (SELECT만 가능, DML/DDL 불가)
ALTER TABLESPACE inventory READ ONLY;

/*
 [결과]
   Tablespace altered.
*/

-- READ ONLY 상태 확인
SELECT TABLESPACE_NAME, STATUS
FROM DBA_TABLESPACES
WHERE TABLESPACE_NAME = 'INVENTORY';

/*
 [결과]
   TABLESPACE_NAME    STATUS
   ------------------ ----------
   INVENTORY          READ ONLY
*/

-- SELECT는 가능한지 확인
SELECT COUNT(*) FROM emp3;

/*
 [결과]
   COUNT(*)
   --------
   xxxxxxxx   ← SELECT는 정상 가능
*/

-- DML 시도 → 에러 확인
INSERT INTO emp3 SELECT * FROM hr.employees;

/*
 [결과]
   ERROR at line 1:
   ORA-00372: file 5 cannot be modified at this time
   ORA-01110: data file 5: '/u01/app/oracle/oradata/ORCL/inventory01.dbf'
*/

-- READ WRITE로 복구
ALTER TABLESPACE inventory READ WRITE;

/*
 [결과]
   Tablespace altered.
*/

-- -----------------------------------------------------------------------

-- [SYSTEM 테이블스페이스는 OFFLINE, READ ONLY 전환 불가]

ALTER TABLESPACE system OFFLINE;

/*
 [결과]
   ERROR at line 1:
   ORA-01544: cannot offline system tablespace
*/

ALTER TABLESPACE system READ ONLY;

/*
 [결과]
   ERROR at line 1:
   ORA-01643: system tablespace can not be made read only

 SYSTEM 테이블스페이스:
   - 데이터 딕셔너리와 핵심 오브젝트 보관
   - OFFLINE, DROP, READ ONLY 전환 모두 불가
*/


-- 6-1. Tablespace DROP — 테이블스페이스만 삭제 (데이터파일 OS에 남음)

DROP TABLESPACE sample_uniform;

/*
 [결과]
   Tablespace dropped.
*/

-- OS에서 데이터파일이 남아있는지 확인
-- !ls -l /u01/app/oracle/oradata/ORCL/sample_uni01.dbf

/*
 [결과]
   -rw-r----- 1 oracle oinstall 104857600 ... sample_uni01.dbf
   → 파일은 여전히 존재 (Oracle DB에서만 제거됨)
   → 수동으로 별도 삭제 필요: rm /u01/app/oracle/oradata/ORCL/sample_uni01.dbf
*/


-- 6-2. Tablespace DROP — 테이블스페이스 + 데이터파일 완전 삭제 (권장)


DROP TABLESPACE sample_auto
INCLUDING CONTENTS AND DATAFILES;
-- INCLUDING CONTENTS : 안에 있는 오브젝트(테이블 등)도 함께 삭제
-- AND DATAFILES      : OS상의 실제 파일도 함께 삭제

/*
 [결과]
   Tablespace dropped.
*/

-- 삭제됐는지 확인
SELECT TABLESPACE_NAME FROM DBA_TABLESPACES
WHERE TABLESPACE_NAME = 'SAMPLE_AUTO';

/*
 [결과]
   no rows selected   ← 정상 삭제됨
*/

-- OS에서도 파일 사라졌는지 확인
-- !ls -l /u01/app/oracle/oradata/ORCL/sample_auto01.dbf

/*
 [결과]
   ls: cannot access .../sample_auto01.dbf: No such file or directory
   → 파일도 완전히 삭제됨
*/



-- 6-3. 데이터파일만 따로 삭제


-- inventory 테이블스페이스에 추가했던 두 번째 데이터파일만 삭제
ALTER TABLESPACE inventory
DROP DATAFILE '/u01/app/oracle/oradata/ORCL/inventory01_1.dbf';

/*
 [결과]
   Tablespace altered.
*/

-- 삭제 후 데이터파일 목록 확인
SELECT TABLESPACE_NAME, FILE_NAME, BYTES/1024/1024 AS SIZE_MB
FROM DBA_DATA_FILES
WHERE TABLESPACE_NAME = 'INVENTORY';

/*
 [결과]
   TABLESPACE_NAME    FILE_NAME                SIZE_MB
   ------------------ ------------------------ -------
   INVENTORY          .../inventory01.dbf      100     ← 첫 번째 파일만 남음

   주의사항:
   - 데이터가 들어있는 파일은 DROP DATAFILE 불가
   - 비어있는 데이터파일만 삭제 가능
   - 테이블스페이스에 데이터파일이 1개만 남은 경우에도 DROP 불가
*/


-- 7-1. Temporary Tablespace 생성

-- Temporary Tablespace 생성
-- 데이터파일이 아닌 tempfile을 사용한다는 점이 Permanent Tablespace와 다름
CREATE TEMPORARY TABLESPACE mytemp
TEMPFILE '/u01/app/oracle/oradata/ORCL/mytemp01.dbf' SIZE 100M
AUTOEXTEND ON NEXT 50M MAXSIZE 500M
UNIFORM SIZE 1M;

/*
 [결과]
   Tablespace created.

 Temporary Tablespace가 자동으로 사용되는 경우:
   ORDER BY, GROUP BY, DISTINCT, JOIN, CREATE INDEX 등
   정렬 작업이 메모리(PGA)를 초과할 때 디스크를 임시 저장소로 사용
*/

-- 생성 확인 (tempfile은 DBA_DATA_FILES가 아닌 별도 뷰에서 조회)
SELECT TABLESPACE_NAME, FILE_NAME, BYTES/1024/1024 AS SIZE_MB
FROM DBA_TEMP_FILES
WHERE TABLESPACE_NAME = 'MYTEMP';

/*
 [결과]
   TABLESPACE_NAME    FILE_NAME                SIZE_MB
   ------------------ ------------------------ -------
   MYTEMP             .../mytemp01.dbf         100
*/

-- 또는 V$TEMPFILE 뷰로 확인
SELECT NAME FROM V$TEMPFILE;

/*
 [결과]
   NAME
   -----------------------------------------
   /u01/app/oracle/oradata/ORCL/mytemp01.dbf
*/

-- Temporary Tablespace에는 영구 오브젝트 생성 불가 확인
CREATE TABLE test_table (id NUMBER) TABLESPACE mytemp;

/*
 [결과]
   ERROR at line 1:
   ORA-02195: Attempt to create PERMANENT object in a TEMPORARY tablespace
*/


/* ============================================================================
   7-2. Temporary Tablespace Group
   ============================================================================ */

-- mytemp2를 새로 만들면서 tempgroup 그룹에 추가
CREATE TEMPORARY TABLESPACE mytemp2
TEMPFILE '/u01/app/oracle/oradata/ORCL/mytemp02.dbf' SIZE 100M
TABLESPACE GROUP tempgroup;

/*
 [결과]
   Tablespace created.
*/

-- 기존 mytemp도 같은 그룹에 추가
ALTER TABLESPACE mytemp
TABLESPACE GROUP tempgroup;

/*
 [결과]
   Tablespace altered.
*/

-- 그룹 확인
SELECT * FROM DBA_TABLESPACE_GROUPS;

/*
 [결과]
   GROUP_NAME    TABLESPACE_NAME
   ------------- ---------------
   TEMPGROUP     MYTEMP
   TEMPGROUP     MYTEMP2
*/

-- 그룹을 DB 기본 Temporary Tablespace로 지정
ALTER DATABASE DEFAULT TEMPORARY TABLESPACE tempgroup;

/*
 [결과]
   Database altered.
*/

-- DB 기본 Temporary Tablespace 확인
SELECT PROPERTY_NAME, PROPERTY_VALUE
FROM DATABASE_PROPERTIES
WHERE PROPERTY_NAME = 'DEFAULT_TEMP_TABLESPACE';

/*
 [결과]
   PROPERTY_NAME              PROPERTY_VALUE
   -------------------------- ---------------
   DEFAULT_TEMP_TABLESPACE    TEMPGROUP       ← 그룹으로 변경됨

 Temporary Tablespace Group 장점:
   - 여러 Temp Tablespace를 하나의 그룹으로 묶어 부하 분산
   - 한 Temp Tablespace가 꽉 차도 같은 그룹 내 다른 Temp로 자동 분배
*/



-- 8. OMF (Oracle-Managed Files) 실습

-- OMF 현재 설정 확인
SHOW PARAMETER db_create_file_dest;

/*
 [결과] 설정 전
   NAME                   TYPE        VALUE
   ---------------------- ----------- -----
   db_create_file_dest    string           ← 비어있음 (OMF 미설정 상태)
*/

-- 데이터파일 자동 생성 경로 설정
ALTER SYSTEM SET db_create_file_dest = '/u01/app/oracle/oradata/ORCL' SCOPE=BOTH;

/*
 [결과]
   System altered.
*/

-- 설정 확인
SHOW PARAMETER db_create_file_dest;

/*
 [결과]
   NAME                   TYPE        VALUE
   ---------------------- ----------- ----------------------------------
   db_create_file_dest    string      /u01/app/oracle/oradata/ORCL
*/

-- OMF 적용 확인 — 파일 경로/이름 없이 크기만 지정해서 테이블스페이스 생성
CREATE TABLESPACE omf_test
DATAFILE SIZE 100M;         -- 경로/이름 없이 크기만 지정

/*
 [결과]
   Tablespace created.
*/

-- Oracle이 자동 생성한 파일 경로 확인
SELECT TABLESPACE_NAME, FILE_NAME
FROM DBA_DATA_FILES
WHERE TABLESPACE_NAME = 'OMF_TEST';

/*
 [결과]
   TABLESPACE_NAME    FILE_NAME
   ------------------ -----------------------------------------------------------
   OMF_TEST           /u01/app/oracle/oradata/ORCL/ORCL/datafile/o1_mf_omf_test_xxxxxxxx_.dbf
   → Oracle이 자동으로 경로와 파일명 생성 (o1_mf_<ts_name>_<랜덤ID>_.dbf 형태)
*/

-- OS에서 실제 파일 생성 확인
-- !ls -la /u01/app/oracle/oradata/ORCL/ORCL/datafile/

/*
 [결과]
   -rw-r----- oracle oinstall 104857600 ... o1_mf_omf_test_xxxxxxxx_.dbf
   → 파일이 자동 생성됨
*/

-- OMF DROP — INCLUDING CONTENTS AND DATAFILES 시 파일도 자동 삭제
DROP TABLESPACE omf_test INCLUDING CONTENTS AND DATAFILES;

/*
 [결과]
   Tablespace dropped.
*/

-- 파일이 자동으로 삭제됐는지 확인
-- !ls -la /u01/app/oracle/oradata/ORCL/ORCL/datafile/

/*
 [결과]
   (해당 파일 없음)   ← OMF는 DROP 시 파일도 자동 삭제됨

 [OMF 장점]
   - 파일 경로/이름을 직접 지정하지 않아도 됨 → 관리 편의성 향상
   - DROP 시 OS 파일도 자동 삭제 → 파일 잔재 없음
   - 파일명 충돌 위험 없음 (Oracle이 고유 이름 자동 부여)

 [OMF 관련 파라미터]
   db_create_file_dest          : 데이터파일/임시파일 기본 저장 위치
   db_create_online_log_dest_n  : redo log file, control file 생성 위치
   db_recovery_file_dest        : fast recovery area (RMAN 백업 등) 저장 위치
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                   핵심 명령어
   ---------------------- ---------------------------------------------------
   테이블스페이스 생성    CREATE TABLESPACE ... DATAFILE ...
   데이터파일 추가        ALTER TABLESPACE ... ADD DATAFILE ...
   데이터파일 삭제        ALTER TABLESPACE ... DROP DATAFILE ...
   OFFLINE/ONLINE         ALTER TABLESPACE ... OFFLINE/ONLINE
   READ ONLY/WRITE        ALTER TABLESPACE ... READ ONLY/WRITE
   완전 삭제              DROP TABLESPACE ... INCLUDING CONTENTS AND DATAFILES
   Temp Tablespace        CREATE TEMPORARY TABLESPACE ... TEMPFILE ...
   Temp 확인 뷰           DBA_TEMP_FILES, V$TEMPFILE
   OMF 설정               ALTER SYSTEM SET db_create_file_dest = '경로'

   ============================================================================ */