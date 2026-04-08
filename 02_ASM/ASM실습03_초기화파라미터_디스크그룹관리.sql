/*
================================================================================
 ASM 실습 03: 초기화 파라미터 & 디스크 그룹 관리
================================================================================
 블로그: https://nsylove97.tistory.com/41
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome

 목차
   1. ASM 초기화 파라미터
      1-1. 핵심 파라미터 확인 (ASM_DISKGROUPS / ASM_DISKSTRING / ASM_POWER_LIMIT)
      1-2. ASM_DISKSTRING 동적 변경
   2. DB 인스턴스 vs ASM 인스턴스 SPFILE 비교
      2-1. ASM 인스턴스 SPFILE 위치 확인
      2-2. DB 인스턴스 SPFILE 위치 확인
      2-3. INSTANCE_TYPE으로 인스턴스 종류 구분
   3. 디스크 그룹 생성 & 디스크 추가 — 명령어 레퍼런스
      3-1. CREATE DISKGROUP — 디스크 그룹 생성
      3-2. ALTER DISKGROUP ADD DISK — 디스크 추가
      3-3. 미사용 디스크 확인
   4. 디스크 그룹 간 데이터파일 이동 3가지 방법
      4-1. 사전 준비 — 실습용 테이블스페이스 3개 생성
      4-2. [방법 1] RMAN COPY + ALTER DATABASE RENAME (TBS_MOVE1)
      4-3. [방법 2] ALTER DATABASE MOVE DATAFILE, 온라인 이동 (TBS_MOVE2)
      4-4. [방법 3] ASMCMD cp + ALTER DATABASE RENAME (TBS_MOVE3)
      4-5. 실습 후 정리
   5. 디스크 DROP & UNDROP — 명령어 레퍼런스
      5-1. 디스크 상태 종류
      5-2. 디스크 DROP
      5-3. UNDROP — DROP 취소
   6. OMF와 ASM 연동 — 개념 & 현재 환경 확인
      6-1. 현재 설정 확인
      6-2. OMF 적용 전후 비교
   7. 디스크 그룹 속성
      7-1. 속성 조회
      7-2. COMPATIBLE.RDBMS 속성 변경
   8. ASMCMD lsdsk 상세 옵션
================================================================================
*/


/* ============================================================================
   1. ASM 초기화 파라미터
   ============================================================================
   ASM 인스턴스는 일반 DB 인스턴스와 달리 스토리지 전용 파라미터를 가짐

   ASM_DISKGROUPS  : ASM 인스턴스 기동 시 자동으로 MOUNT할 디스크 그룹 목록
   ASM_DISKSTRING  : ASM이 디스크를 스캔할 경로 패턴 — 후보 목록을 제한
                     비어 있으면 OS 전체 디스크 스캔 → 오인식 및 기동 지연 위험
   ASM_POWER_LIMIT : 리밸런스 작업의 기본 속도·강도 (0~1024)
                     0=중단 / 1=기본(서비스 영향 최소) / 11=최대 / 19c이상 최대 1024
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. 핵심 파라미터 확인
   -------------------------------------------------------------------------- */

-- [grid 계정] SYSASM으로 접속
CONN / AS SYSASM

-- ASM 핵심 파라미터 한 번에 확인
SHOW PARAMETER ASM_

/*
 [결과]
   NAME              TYPE    VALUE
   ----------------  ------  ---------------------------------
   asm_diskgroups    string  DATA,FRA,OCR,REDO
   asm_diskstring    string  /dev/oracleasm/disks/*
   asm_power_limit   integer 1
   → 기동 시 4개 디스크 그룹 자동 MOUNT
   → 해당 경로 패턴의 디스크만 ASM 후보로 인식
   → 리밸런스 기본 강도 1 (낮을수록 서비스 영향 적음)
*/


/* --------------------------------------------------------------------------
   1-2. ASM_DISKSTRING 동적 변경
   --------------------------------------------------------------------------
   - 값이 비어 있다면 경로 패턴 지정 (재시작 없이 적용 가능)
   -------------------------------------------------------------------------- */

-- 값이 비어 있다면, ASM_DISKSTRING 동적 변경 (재시작 없이 적용)
-- ALTER SYSTEM SET ASM_DISKSTRING = '/dev/oracleasm/disks/*' SCOPE=BOTH;

/*
 [결과]
   System altered.
*/


/* ============================================================================
   2. DB 인스턴스 vs ASM 인스턴스 SPFILE 비교
   ============================================================================
   - ASM 환경에서는 ASM 인스턴스와 DB 인스턴스가
     각자 자신의 SPFILE을 ASM 디스크 그룹 안에서 독립적으로 관리

   구분              ASM 인스턴스                          DB 인스턴스
   ---------------   ------------------------------------  -------------------------
   SPFILE 저장 위치  +DATA/+ASM/PARAMETERFILE/spfile.xxx   +DATA/ORCL/PARAMETERFILE/spfile.xxx
   접속 권한         SYSASM                                SYSDBA
   INSTANCE_TYPE     ASM                                   RDBMS
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. ASM 인스턴스 SPFILE 위치 확인
   -------------------------------------------------------------------------- */

-- [grid 계정] SYSASM으로 접속
CONN / AS SYSASM

SHOW PARAMETER SPFILE

/*
 [결과]
   NAME    TYPE    VALUE
   ------  ------  ----------------------------------------
   spfile  string  +DATA/+ASM/PARAMETERFILE/spfile.xxx.xxx
   → ASM 인스턴스 전용 SPFILE이 +DATA 그룹 안에 저장됨
*/


/* --------------------------------------------------------------------------
   2-2. DB 인스턴스 SPFILE 위치 확인
   -------------------------------------------------------------------------- */

-- [oracle 계정] SYSDBA로 접속
CONN / AS SYSDBA

SHOW PARAMETER SPFILE

/*
 [결과]
   NAME    TYPE    VALUE
   ------  ------  ------------------------------------------
   spfile  string  +DATA/ORCL/PARAMETERFILE/spfile.orcl.xxx
   → DB 인스턴스 SPFILE도 +DATA 그룹 안에 별도로 저장됨
*/


/* --------------------------------------------------------------------------
   2-3. INSTANCE_TYPE으로 인스턴스 종류 구분
   -------------------------------------------------------------------------- */

-- INSTANCE_TYPE으로 현재 접속한 인스턴스 종류 구분
SHOW PARAMETER INSTANCE_TYPE

/*
 [결과 — ASM 인스턴스 (grid 계정 SYSASM 접속 시)]
   NAME           TYPE    VALUE
   -------------  ------  -----
   instance_type  string  ASM

 [결과 — DB 인스턴스 (oracle 계정 SYSDBA 접속 시)]
   NAME           TYPE    VALUE
   -------------  ------  ------
   instance_type  string  RDBMS

 → ASM 인스턴스 파라미터를 변경할 때는 반드시 grid 계정(SYSASM)으로 접속해야 함
 → oracle 계정(SYSDBA)으로 접속하면 DB 인스턴스의 파라미터가 변경됨
*/


/* ============================================================================
   3. 디스크 그룹 생성 & 디스크 추가 — 명령어 레퍼런스
   ============================================================================
   - 현재 실습 환경은 11개 디스크가 4개 그룹(+DATA/+FRA/+REDO/+OCR)에 모두 할당됨
   - 여유 디스크 없음 → 명령어 구조와 동작 원리만 정리
   - RAC·Data Guard 확장 시 새 디스크 투입 시점에 아래 명령어를 그대로 활용 가능
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. CREATE DISKGROUP — 디스크 그룹 생성
   --------------------------------------------------------------------------
   NORMAL REDUNDANCY   : 2중 미러링 — Failure Group 2개 이상 필요
   HIGH REDUNDANCY     : 3중 미러링 — Failure Group 3개 이상 필요
   EXTERNAL REDUNDANCY : 미러링 없음 — 외부 스토리지(RAID)에 보호 위임
   FAILGROUP           : 미러 복사본이 같은 장애 도메인에 놓이지 않도록 지정
   -------------------------------------------------------------------------- */

-- 기본 구조 (미실행 — 여유 디스크 없음)
-- CREATE DISKGROUP <그룹명> NORMAL REDUNDANCY
--     FAILGROUP <FG명1> DISK '<디스크 경로1>'
--     FAILGROUP <FG명2> DISK '<디스크 경로2>';

-- 실제 예시 (새 디스크 투입 시)
-- CREATE DISKGROUP DG_NEW NORMAL REDUNDANCY
--     FAILGROUP FG1 DISK '/dev/oracleasm/disks/DISK01'
--     FAILGROUP FG2 DISK '/dev/oracleasm/disks/DISK02';

/*
 [결과]
   Diskgroup created.
*/


/* --------------------------------------------------------------------------
   3-2. ALTER DISKGROUP ADD DISK — 기존 디스크 그룹에 디스크 추가
   -------------------------------------------------------------------------- */

-- 기본 구조 (미실행 — 여유 디스크 없음)
-- ALTER DISKGROUP <그룹명>
--     ADD DISK '<디스크 경로>'
--     REBALANCE POWER <0~1024>;

-- 실제 예시 — +FRA 그룹에 디스크 1개 추가, POWER 4로 리밸런스
-- ALTER DISKGROUP FRA
--     ADD DISK '/dev/oracleasm/disks/FRA3'
--     REBALANCE POWER 4;

/*
 [결과]
   Diskgroup altered.
   → 디스크 추가와 동시에 POWER 4 강도로 리밸런스 시작

 REBALANCE POWER 값 선택 기준
   업무 시간 중: 낮은 값(1~2)으로 서비스 영향을 줄임
   야간 유지보수: 높은 값(8~11)으로 빠르게 완료
   POWER 0: 구성 변경만 등록, 데이터 이동 없음
*/


/* --------------------------------------------------------------------------
   3-3. 미사용 디스크 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSASM

-- GROUP_NUMBER = 0 이면 어떤 그룹에도 속하지 않은 디스크
SELECT name, path, state, total_mb, group_number
FROM   v$asm_disk
ORDER  BY group_number, name;

/*
 [결과]
   NAME   PATH                          STATE   TOTAL_MB  GROUP_NUMBER
   -----  ----------------------------  ------  --------  ------------
   DATA1  /dev/oracleasm/disks/DATA1    NORMAL  10238     1
   DATA2  /dev/oracleasm/disks/DATA2    NORMAL  10238     1
   DATA3  /dev/oracleasm/disks/DATA3    NORMAL  10238     1
   DATA4  /dev/oracleasm/disks/DATA4    NORMAL  10238     1
   FRA1   /dev/oracleasm/disks/FRA1     NORMAL  10238     2
   FRA2   /dev/oracleasm/disks/FRA2     NORMAL  10238     2
   OCR1   /dev/oracleasm/disks/OCR1     NORMAL  10238     3
   OCR2   /dev/oracleasm/disks/OCR2     NORMAL  10238     3
   OCR3   /dev/oracleasm/disks/OCR3     NORMAL  10238     3
   REDO1  /dev/oracleasm/disks/REDO1    NORMAL  10238     4
   REDO2  /dev/oracleasm/disks/REDO2    NORMAL  10238     4
   → GROUP_NUMBER=0인 행 없음 — 미사용 디스크 없음 확인

 STATE 종류
   CANDIDATE : ASM이 인식했으나 그룹 미할당
   NORMAL    : 그룹 MEMBER로 정상 사용 중
   FORMER    : 이전에 그룹 멤버였으나 현재 제거된 상태
*/


/* ============================================================================
   4. 디스크 그룹 간 데이터파일 이동 3가지 방법
   ============================================================================
   방법 1: RMAN COPY + ALTER DATABASE RENAME
           — OFFLINE 필요, 복사 후 컨트롤파일 경로 수정, 원본 수동 삭제 필요
   방법 2: ALTER DATABASE MOVE DATAFILE (12c 이상)
           — OFFLINE 불필요, 서비스 중단 없이 온라인 이동, 원본 자동 삭제
   방법 3: ASMCMD cp + ALTER DATABASE RENAME
           — OFFLINE 필요, OS 레벨 직접 복사, 원본 수동 삭제 필요
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. 사전 준비 — 실습용 테이블스페이스 3개 생성 (+DATA)
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- 방법별로 하나씩 사용할 실습용 테이블스페이스 생성
CREATE TABLESPACE tbs_move1
    DATAFILE '+DATA' SIZE 10M AUTOEXTEND OFF;

CREATE TABLESPACE tbs_move2
    DATAFILE '+DATA' SIZE 10M AUTOEXTEND OFF;

CREATE TABLESPACE tbs_move3
    DATAFILE '+DATA' SIZE 10M AUTOEXTEND OFF;

/*
 [결과]
   Tablespace created.
   Tablespace created.
   Tablespace created.
*/

-- 생성된 데이터파일 경로 확인 (이후 실습에서 경로 그대로 사용)
-- v$datafile에는 tablespace_name 컬럼이 없으므로 dba_data_files 사용
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name LIKE '%TBS_MOVE%'
ORDER  BY file_id;

/*
 [결과]
   FILE_ID  FILE_NAME                                     TABLESPACE_NAME
   -------  --------------------------------------------  ---------------
   5        +DATA/ORCL/DATAFILE/tbs_move1.267.1228856885  TBS_MOVE1
   6        +DATA/ORCL/DATAFILE/tbs_move2.268.1228856897  TBS_MOVE2
   7        +DATA/ORCL/DATAFILE/tbs_move3.269.1228856913  TBS_MOVE3
   → 3개 모두 +DATA에 생성됨 — 이 경로를 아래 각 방법에서 그대로 사용
*/


/* --------------------------------------------------------------------------
   4-2. [방법 1] RMAN COPY + ALTER DATABASE RENAME — TBS_MOVE1
   --------------------------------------------------------------------------
   - RMAN으로 파일을 물리적으로 복사한 뒤 컨트롤파일에 새 경로를 등록하는 방식
   - OMF 환경에서는 TO 절에 디스크 그룹명만 지정해야 함
     (OMF 형식 이름을 그대로 쓰면 ORA-01276 발생)
   -------------------------------------------------------------------------- */

-- STEP 1: TBS_MOVE1 OFFLINE
ALTER TABLESPACE tbs_move1 OFFLINE;

/*
 [결과]
   Tablespace altered.
*/

-- STEP 2: RMAN으로 +DATA → +FRA 복사 (OS 터미널에서 실행)
-- rman target /

/*
   RMAN> COPY DATAFILE '+DATA/ORCL/DATAFILE/tbs_move1.267.1228856885'
   2>          TO      '+FRA';

 [결과]
   Starting backup at 25-MAR-26
   using target database control file instead of recovery catalog
   allocated channel: ORA_DISK_1
   channel ORA_DISK_1: SID=21 device type=DISK
   channel ORA_DISK_1: starting datafile copy
   input datafile file number=00005 name=+DATA/ORCL/DATAFILE/tbs_move1.267.1228856885
   output file name=+FRA/ORCL/DATAFILE/tbs_move1.271.1228858649
   channel ORA_DISK_1: datafile copy complete
   Finished backup at 25-MAR-26
   → +FRA로 물리적 복사 완료
   → 출력된 새 경로(+FRA/ORCL/DATAFILE/tbs_move1.271.xxx)를 STEP 3에서 사용
*/

-- STEP 3: 컨트롤파일에 새 경로 등록
ALTER DATABASE RENAME FILE
    '+DATA/ORCL/DATAFILE/tbs_move1.267.1228856885'
    TO '+FRA/ORCL/DATAFILE/tbs_move1.271.1228858649';

/*
 [결과]
   Database altered.
*/

-- STEP 4: TBS_MOVE1 ONLINE
ALTER TABLESPACE tbs_move1 ONLINE;

/*
 [결과]
   Tablespace altered.
*/

-- STEP 5: 이동 결과 확인
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name = 'TBS_MOVE1';

/*
 [결과]
   FILE_ID  FILE_NAME                                      TABLESPACE_NAME
   -------  ---------------------------------------------  ---------------
   5        +FRA/ORCL/DATAFILE/tbs_move1.271.1228858649   TBS_MOVE1
   → 컨트롤파일 경로가 +FRA로 변경됨 확인
   ※ +DATA 원본 파일(tbs_move1.267.xxx)은 ASMCMD rm으로 수동 삭제 필요
*/


/* --------------------------------------------------------------------------
   4-3. [방법 2] ALTER DATABASE MOVE DATAFILE (온라인 이동, 12c 이상) — TBS_MOVE2
   --------------------------------------------------------------------------
   - DB OPEN 상태에서 OFFLINE 없이 바로 이동
   - 이동 중에도 해당 데이터파일에 읽기·쓰기 허용
   - 이동 완료 후 원본 파일 자동 삭제까지 처리
   -------------------------------------------------------------------------- */

-- 한 줄로 이동 완료 (OFFLINE 불필요)
ALTER DATABASE MOVE DATAFILE
    '+DATA/ORCL/DATAFILE/tbs_move2.268.1228856897'
    TO '+FRA';

/*
 [결과]
   Database altered.
   → 이동 완료 후 컨트롤파일 경로 자동 갱신, 원본 파일 자동 삭제
*/

-- 이동 결과 확인
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name = 'TBS_MOVE2';

/*
 [결과]
   FILE_ID  FILE_NAME                                      TABLESPACE_NAME
   -------  ---------------------------------------------  ---------------
   6        +FRA/ORCL/DATAFILE/tbs_move2.272.1228858701   TBS_MOVE2
   → +FRA로 이동 완료

 방법 1 vs 방법 2 비교
   RMAN COPY  : 원본이 +DATA에 남아 있어 수동 삭제 필요
   MOVE DATAFILE: 원본까지 자동 정리 + 서비스 중단 없음
   → 12c 이상 환경에서는 방법 2(MOVE DATAFILE)가 가장 권장됨
*/


/* --------------------------------------------------------------------------
   4-4. [방법 3] ASMCMD cp + ALTER DATABASE RENAME — TBS_MOVE3
   --------------------------------------------------------------------------
   - OS 레벨에서 ASMCMD cp로 직접 파일을 복사하는 전통적 방법
   - OMF 환경에서는 목적지에 디스크 그룹명 + 슬래시(/) 또는 일반 파일명 사용
     (OMF 형식 이름 그대로 사용 시 ASMCMD-8016/ORA-15046 발생)
   -------------------------------------------------------------------------- */

-- STEP 1: TBS_MOVE3 OFFLINE
ALTER TABLESPACE tbs_move3 OFFLINE;

/*
 [결과]
   Tablespace altered.
*/

-- STEP 2: ASMCMD로 파일 복사 (OS 터미널 — grid 계정)
-- ASMCMD> cp +DATA/ORCL/DATAFILE/tbs_move3.269.1228856913 +FRA/tbs_move3.dbf

/*
 [결과]
   copying +DATA/ORCL/DATAFILE/tbs_move3.269.1228856913
        -> +FRA/tbs_move3.dbf
   → ASMCMD가 ASM 내부에서 직접 파일 복사 수행
*/

-- STEP 3: 컨트롤파일 경로 갱신
ALTER DATABASE RENAME FILE
    '+DATA/ORCL/DATAFILE/tbs_move3.269.1228856913'
    TO '+FRA/tbs_move3.dbf';

/*
 [결과]
   Database altered.
*/

-- STEP 4: TBS_MOVE3 ONLINE
ALTER TABLESPACE tbs_move3 ONLINE;

/*
 [결과]
   Tablespace altered.
*/

-- STEP 5: 이동 결과 확인
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name = 'TBS_MOVE3';

/*
 [결과]
   FILE_ID  FILE_NAME           TABLESPACE_NAME
   -------  ------------------  ---------------
   7        +FRA/tbs_move3.dbf  TBS_MOVE3
   → +FRA로 이동 완료
   ※ +DATA 원본 파일(tbs_move3.269.xxx)은 ASMCMD rm으로 수동 삭제 필요
*/


/* --------------------------------------------------------------------------
   4-5. 실습 후 정리
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- 실습용 테이블스페이스 3개 삭제 (데이터파일 포함)
DROP TABLESPACE tbs_move1 INCLUDING CONTENTS AND DATAFILES;
DROP TABLESPACE tbs_move2 INCLUDING CONTENTS AND DATAFILES;
DROP TABLESPACE tbs_move3 INCLUDING CONTENTS AND DATAFILES;

/*
 [결과]
   Tablespace dropped.
   Tablespace dropped.
   Tablespace dropped.
*/

-- 정리 후 확인
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name LIKE '%TBS_MOVE%';

/*
 [결과]
   no rows selected
   → 실습용 테이블스페이스 3개 모두 삭제 완료
*/


/* ============================================================================
   5. 디스크 DROP & UNDROP — 명령어 레퍼런스
   ============================================================================
   - DROP은 디스크에서 Extent를 다른 디스크로 이동(리밸런스)한 뒤 그룹에서 제거
   - 현재 실습 환경에는 여유 디스크가 없어 운영 디스크를 건드리기 어려움
   - 명령어 구조와 동작 원리만 정리

   디스크 상태 종류
     NORMAL    : 정상 사용 중 (그룹 MEMBER)
     CANDIDATE : 어떤 그룹에도 속하지 않은 미사용 디스크
     PROVISIONED: ASM이 인식했으나 아직 그룹에 미할당
     DROPPING  : DROP 명령 후 리밸런스 진행 중
     FORMER    : 이전에 그룹 멤버였으나 현재는 제거된 상태
     OFFLINE   : 장애 등으로 접근 불가 상태
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. 디스크 DROP
   -------------------------------------------------------------------------- */

-- [기본 구조] (미실행 — 여유 디스크 없음)
-- CONN / AS SYSASM
--
-- -- 특정 디스크를 그룹에서 제거
-- -- DROP 직후 리밸런스가 시작되며 Extent 이동이 완료되면 그룹에서 제거됨
-- ALTER DISKGROUP <디스크그룹_이름> DROP DISK <디스크_이름>;
--
-- -- DROP 진행 상태 확인 — DROPPING 상태가 사라지면 완료
-- SELECT name, state FROM v$asm_disk
-- WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup
--                        WHERE  name = '<디스크그룹_이름>');

/*
 [결과 — DROP 진행 중]
   NAME  STATE
   ----  --------
   FRA1  NORMAL
   FRA2  NORMAL
   FRA3  DROPPING  ← 리밸런스가 끝나면 그룹에서 자동 제거됨

 주의: 남은 디스크에 공간이 부족하면 ORA-15042 오류 발생
       DROP 전에 반드시 v$asm_diskgroup의 USABLE_FILE_MB로 여유 공간 확인 필요
*/


/* --------------------------------------------------------------------------
   5-2. UNDROP — DROP 취소
   -------------------------------------------------------------------------- */

-- [기본 구조] (미실행)
-- -- 리밸런스 완료 전(DROPPING 상태)에서만 취소 가능
-- -- FORMER 상태가 된 이후에는 UNDROP 불가
-- ALTER DISKGROUP <디스크그룹_이름> UNDROP DISKS;

/*
 [DROP과 UNDROP 흐름]
   DROP 명령
     → 리밸런스 시작
     → DROPPING 상태  ← UNDROP 가능 구간
     → 리밸런스 완료
     → FORMER 상태
     → 그룹에서 완전 제거
*/


/* ============================================================================
   6. OMF와 ASM 연동 — 개념 & 현재 환경 확인
   ============================================================================
   - OMF(Oracle-Managed Files): 데이터파일·로그파일 이름을 DB가 자동으로 생성·관리
   - db_create_file_dest 파라미터에 저장 위치를 지정하면 활성화됨
   - 현재 실습 환경은 dbca로 DB 생성 시 ASM 스토리지를 선택했기 때문에
     OMF가 이미 적용된 상태 (별도 설정 없이 경로 생략 가능)

   OMF 미적용 vs OMF 적용 비교
     파일 이름   : 직접 지정 필요          vs 시스템이 자동 부여
     경로 지정   : 필수                    vs 생략 가능
     파일 삭제   : DROP 후 OS에서 수동삭제  vs DROP 시 자동 삭제
     설정 파라미터: —                      vs db_create_file_dest=+DATA
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. 현재 설정 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

SHOW PARAMETER db_create_file_dest

/*
 [결과]
   NAME                 TYPE    VALUE
   -------------------  ------  ------
   db_create_file_dest  string  +DATA
   → dbca 생성 시 자동으로 +DATA로 세팅된 상태 확인
*/


/* --------------------------------------------------------------------------
   6-2. OMF 적용 전후 비교
   -------------------------------------------------------------------------- */

-- OMF 미적용: 데이터파일 경로를 직접 지정해야 함
CREATE TABLESPACE tbs_manual
    DATAFILE '+DATA/ORCL/DATAFILE/tbs_manual01.dbf' SIZE 10M;

/*
 [결과]
   Tablespace created.
*/

-- OMF 적용 상태 (현재 환경): 경로 생략 가능 → 시스템이 이름 자동 부여
CREATE TABLESPACE tbs_omf;

/*
 [결과]
   Tablespace created.
*/

-- 기존 데이터파일들이 OMF 방식(자동 이름)으로 생성되어 있는지 확인
-- → tbs_manual은 직접 지정한 이름, tbs_omf는 번호+타임스탬프 자동 부여된 이름
SELECT file#, name FROM v$datafile ORDER BY file#;

/*
 [결과]
   FILE#  NAME
   -----  --------------------------------------------------
   1      +DATA/ORCL/DATAFILE/system.257.xxxxxxxxxx
   2      +DATA/ORCL/DATAFILE/sysaux.258.xxxxxxxxxx
   3      +DATA/ORCL/DATAFILE/undotbs1.259.xxxxxxxxxx
   4      +DATA/ORCL/DATAFILE/users.260.xxxxxxxxxx
   5      +DATA/ORCL/DATAFILE/tbs_manual01.dbf            ← 직접 지정한 이름
   6      +DATA/ORCL/DATAFILE/tbs_omf.xxx.xxxxxxxxxx      ← OMF 자동 부여 이름
   → tbs_manual: 직접 지정한 파일명 그대로 생성
   → tbs_omf: 파일 번호 + 타임스탬프가 포함된 OMF 형식으로 자동 생성
*/

-- 실습 후 정리
DROP TABLESPACE tbs_manual INCLUDING CONTENTS AND DATAFILES;
DROP TABLESPACE tbs_omf    INCLUDING CONTENTS AND DATAFILES;

/*
 [결과]
   Tablespace dropped.
   Tablespace dropped.
*/


/* ============================================================================
   7. 디스크 그룹 속성
   ============================================================================
   디스크 그룹 생성 시 또는 이후 ALTER DISKGROUP ... SET ATTRIBUTE로 세부 동작 제어

   주요 속성
     AU_SIZE          : Allocation Unit 크기 (MB) — 그룹 생성 시에만 지정 가능
     DISK_REPAIR_TIME : 디스크 OFFLINE 후 복구를 기다리는 최대 시간 (기본 3.6H)
     COMPATIBLE.RDBMS : 이 그룹을 사용할 수 있는 DB 최소 버전 (기본 10.1)
     COMPATIBLE.ASM   : 이 그룹을 MOUNT할 수 있는 ASM 최소 버전 (기본 10.1)

   AU_SIZE 선택 기준
     소규모 랜덤 I/O (OLTP) → 기본값 1MB 권장
     대용량 순차 I/O (DW)   → 4MB ~ 64MB로 늘리면 성능 향상 가능
   ============================================================================ */

/* --------------------------------------------------------------------------
   7-1. 속성 조회
   -------------------------------------------------------------------------- */

CONN / AS SYSASM

-- v$asm_attribute로 현재 디스크 그룹 속성 확인
SELECT dg.name AS diskgroup, attr.name, attr.value
FROM   v$asm_diskgroup dg
       JOIN v$asm_attribute attr ON dg.group_number = attr.group_number
WHERE  dg.name = 'DATA'
ORDER  BY attr.name;

/*
 [결과]
   DISKGROUP  NAME                  VALUE
   ---------  --------------------  ----------
   DATA       au_size               1048576
   DATA       compatible.asm        19.0.0.0.0
   DATA       compatible.rdbms      10.1.0.0.0
   DATA       disk_repair_time      3.6H
   DATA       sector_size           512
   → AU_SIZE = 1048576 bytes = 1MB (기본값 확인)
*/


/* --------------------------------------------------------------------------
   7-2. COMPATIBLE.RDBMS 속성 변경
   -------------------------------------------------------------------------- */

-- rdbms 호환성 최소 버전 확인
SELECT dg.name AS diskgroup, attr.name, attr.value
FROM   v$asm_diskgroup dg
       JOIN v$asm_attribute attr ON dg.group_number = attr.group_number
WHERE  dg.name = 'DATA'
AND    attr.name = 'compatible.rdbms';

/*
 [결과]
   DISKGROUP  NAME              VALUE
   ---------  ----------------  ----------
   DATA       compatible.rdbms  10.1.0.0.0
*/

-- rdbms 호환성 최소 버전을 11.1로 변경
ALTER DISKGROUP data SET ATTRIBUTE 'compatible.rdbms' = '11.1.0.0.0';

/*
 [결과]
   Diskgroup altered.
*/

-- 변경 후 확인
SELECT dg.name AS diskgroup, attr.name, attr.value
FROM   v$asm_diskgroup dg
       JOIN v$asm_attribute attr ON dg.group_number = attr.group_number
WHERE  dg.name = 'DATA'
AND    attr.name = 'compatible.rdbms';

/*
 [결과]
   DISKGROUP  NAME              VALUE
   ---------  ----------------  ----------
   DATA       compatible.rdbms  11.1.0.0.0
   → 11.1.0.0.0으로 변경 완료
*/


/* ============================================================================
   8. ASMCMD lsdsk 상세 옵션
   ============================================================================
   - lsdsk: ASM에 등록된 개별 디스크 정보를 조회하는 ASMCMD 명령어
   - grid 계정 (ORACLE_SID=+ASM) 에서 실행

   옵션 정리
     (기본) : 경로만 출력
     -k     : Failure Group, Redundancy, 크기 포함 상세 출력
     -t     : 생성 시점, 마지막 마운트 시점 포함
     -p     : 헤더 상태, 온라인 여부, 그룹 번호 포함
     -G <그룹명> : 특정 디스크 그룹만 필터링
   ============================================================================ */

/*
 [기본 조회]
   ASMCMD> lsdsk

 [결과]
   Path
   /dev/oracleasm/disks/DATA1
   /dev/oracleasm/disks/DATA2
   /dev/oracleasm/disks/DATA3
   /dev/oracleasm/disks/DATA4
   /dev/oracleasm/disks/FRA1
   /dev/oracleasm/disks/FRA2
   /dev/oracleasm/disks/OCR1
   /dev/oracleasm/disks/OCR2
   /dev/oracleasm/disks/OCR3
   /dev/oracleasm/disks/REDO1
   /dev/oracleasm/disks/REDO2
   → 경로 목록만 출력
*/

/*
 [-k 옵션 — Failure Group 및 상세 정보 포함]
   ASMCMD> lsdsk -k

 [결과]
   Inst_Num  Incarnation  Failgroup  Label  Product  Redund  Offset  Size         Path
   1         1069574913   DATA_0000  DATA1  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA1
   1         1069574914   DATA_0001  DATA2  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA2
   1         1069574915   DATA_0000  DATA3  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA3
   1         1069574916   DATA_0001  DATA4  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA4
   ...
   → Failgroup 컬럼으로 장애 격리 구성 확인 가능
*/

/*
 [-t 옵션 — 시간 정보 포함 (생성 시점, 마지막 마운트 시점)]
   ASMCMD> lsdsk -t

 [결과]
   Create_Date              Mount_Date               Path
   -----------------------  -----------------------  ----------------------------
   2026-03-25 17:00:00      2026-03-25 17:05:00      /dev/oracleasm/disks/DATA1
   2026-03-25 17:00:00      2026-03-25 17:05:00      /dev/oracleasm/disks/DATA2
   ...
   → 디스크 생성 시점과 마지막 마운트 시점 확인 가능
*/

/*
 [-G 옵션 — 특정 디스크 그룹만 필터링]
   ASMCMD> lsdsk -k -G DATA

 [결과]
   Inst_Num  Incarnation  Failgroup  Label  Product  Redund  Offset  Size         Path
   1         1069574913   DATA_0000  DATA1  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA1
   1         1069574914   DATA_0001  DATA2  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA2
   1         1069574915   DATA_0000  DATA3  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA3
   1         1069574916   DATA_0001  DATA4  ORACLE   MIRROR  0       10736352256  /dev/oracleasm/disks/DATA4
   → +DATA 그룹 소속 디스크 4개만 출력
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                     핵심 포인트
   ----------------------   ---------------------------------------------------
   ASM_DISKGROUPS           기동 시 자동 MOUNT할 디스크 그룹 목록
   ASM_DISKSTRING           ASM이 스캔할 디스크 경로 패턴
                            좁힐수록 기동 빠르고 오인식 방지
   ASM_POWER_LIMIT          리밸런스 기본 강도 (0=중단 / 1=기본 / 최대 1024)
   SPFILE 위치              ASM·DB 인스턴스 각각 +DATA 그룹 내 별도 SPFILE 보유
   INSTANCE_TYPE            ASM 인스턴스=ASM / DB 인스턴스=RDBMS
   디스크 그룹 생성         CREATE DISKGROUP … NORMAL REDUNDANCY FAILGROUP … DISK
   디스크 추가              ALTER DISKGROUP … ADD DISK … REBALANCE POWER n
   데이터파일 이동 방법 1   RMAN COPY + RENAME
                            → OFFLINE 필요, 원본 수동 삭제 필요
                            → OMF 환경에서 TO 절에 그룹명만 지정해야 함 (ORA-01276 주의)
   데이터파일 이동 방법 2   ALTER DATABASE MOVE DATAFILE (12c 이상)
                            → OFFLINE 불필요, 원본 자동 삭제, 가장 권장
   데이터파일 이동 방법 3   ASMCMD cp + RENAME
                            → OFFLINE 필요, 원본 수동 삭제 필요
                            → OMF 환경에서 목적지에 일반 파일명 사용 (ASMCMD-8016 주의)
   DROP DISK                리밸런스로 Extent 이동 후 제거
                            공간 부족 시 ORA-15042 발생
   UNDROP DISKS             리밸런스 완료 전(DROPPING 상태)에서만 취소 가능
   OMF + ASM                dbca 생성 시 db_create_file_dest=+DATA 자동 세팅
                            경로 생략 가능, DROP 시 파일 자동 삭제
   DISK_REPAIR_TIME         디스크 OFFLINE 후 복구 대기 시간 (기본 3.6H)
   AU_SIZE                  그룹 생성 시에만 지정 가능
                            OLTP=1M, DW=4M~64M
   COMPATIBLE.RDBMS         이 그룹을 사용할 수 있는 DB 최소 버전
                            ALTER DISKGROUP … SET ATTRIBUTE로 변경 가능
   lsdsk -k                 Failure Group·Redundancy 포함 상세 조회
   lsdsk -t                 디스크 생성 시점·마지막 마운트 시점 조회
   lsdsk -G                 특정 디스크 그룹만 필터링

   ============================================================================ */
