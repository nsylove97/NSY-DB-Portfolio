/* ==============================================================================
   RAC 04: RAC 파라미터 · SPFILE · Redo · UNDO 관리
   Blog  : https://nsylove97.tistory.com/65
   GitHub: https://github.com/nsylove97/NSY-DB-Portfolio
   ------------------------------------------------------------------------------
   실습 환경
   OS           : Oracle Linux 7.9 (VMware Virtual Machine)
   DB           : Oracle Database 19c
   Grid         : Oracle Grid Infrastructure 19c
   구성           : 2 Node RAC (VM1 · VM2)
   공유 스토리지    : ASM (+DATA / +FRA / +REDO / +OCR)
   네트워크         : Public (NAT) · Private (Host-only) · VIP · SCAN

   노드 정보
   +----------+----------------------+------------------------------------------+
   | 구분       | Hostname             | 비고                                       |
   +----------+----------------------+------------------------------------------+
   | Node1     | oelsvr1.localdomain  | orcl1 인스턴스, +ASM1                      |
   | Node2     | oelsvr2.localdomain  | orcl2 인스턴스, +ASM2                      |
   +----------+----------------------+------------------------------------------+

   디렉토리 정보
   ORACLE_BASE: /u01/app/oracle
   ORACLE_HOME: /u01/app/oracle/product/19.3.0/dbhome
   DB_NAME    : orcl (orcl1 / orcl2 인스턴스)
   ------------------------------------------------------------------------------
   목차
   1.   RAC SPFILE 구조 — 공용 SPFILE을 노드가 공유하는 방식
   1-1. spfile 파라미터 확인
   1-2. 로컬 포인터 파일 유실 확인
   1-3. 포인터 파일 재생성
   2.   ALTER SYSTEM SET … SID 범위 제어
   2-1. 전체 인스턴스 공통 적용
   2-2. 인스턴스별 개별 적용
   3.   ALTER SYSTEM RESET — 파라미터 삭제
   3-1. SID='*' 공통 항목 삭제
   3-2. pfile 덤프로 삭제 여부 확인
   4.   RAC 전용 파라미터 — CLUSTER_DATABASE · INSTANCE_NUMBER · THREAD
   5.   compatible 파라미터 — 양 노드 값 일치 필요성
   6.   ASM_PREFERRED_READ_FAILURE_GROUPS
   6-1. ASM1 인스턴스 지정
   6-2. ASM2 인스턴스 지정
   6-3. 적용 결과 확인
   7.   Redo Log Thread 구조
   8.   Thread 3 추가 및 활성화
   8-1. Thread 3용 Redo Log Group 추가
   8-2. Thread 활성화
   8-3. 원상 복구 — Thread 3 비활성화 및 삭제
   9.   UNDO 관리 — 인스턴스별 전용 UNDO TABLESPACE
   9-1. 인스턴스별 undo_tablespace 확인
   9-2. 신규 UNDO TABLESPACE 생성
   10.  UNDO_TABLESPACE 변경
   10-1. orcl2 인스턴스 UNDO 전환
   10-2. 이전 UNDO TABLESPACE OFFLINE
   10-3. 원상 복구
   11.  Quiesce RAC Database
   12.  Cross-instance Session Kill
   13.  ASM Instance Recovery vs Crash Recovery
   14.  주요 명령어 정리
   ============================================================================== */


/* ==============================================================================
   1. RAC SPFILE 구조 — 공용 SPFILE을 노드가 공유하는 방식
   ------------------------------------------------------------------------------
   단일 인스턴스는 로컬 디스크에 SPFILE을 두지만,
   RAC는 모든 인스턴스가 ASM 위의 공용 SPFILE 하나를 공유한다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   1-1. spfile 파라미터 확인
   ※ 양 노드가 동일한 ASM 경로의 SPFILE을 가리키는지 먼저 확인하고 시작한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
-- 현재 인스턴스가 참조 중인 SPFILE 경로 확인
SHOW PARAMETER spfile;

/* [결과]
NAME                                 TYPE        VALUE
------------------------------------ ----------- ------------------------------
spfile                               string      +DATA/ORCL/PARAMETERFILE/spfil
                                                  e.263.1233770977
*/

/* ------------------------------------------------------------------------------
   1-2. 로컬 포인터 파일 유실 확인
   ※ 로컬 $ORACLE_HOME/dbs/spfile<SID>.ora는 실제 SPFILE이 아니라 ASM 내
     공용 SPFILE 위치를 가리키는 포인터 파일이다. 이 파일이 유실되어도
     인스턴스 기동에는 영향이 없다 — 인스턴스는 이미 ASM 경로를 통해 정상 동작 중이며,
     포인터 파일은 차후 STARTUP 시 SID 매핑을 위해서만 필요하다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — oracle, OS 명령]
-- 로컬 포인터 파일 존재 여부 확인
$ cat $ORACLE_HOME/dbs/spfileorcl1.ora

/* [결과]
cat: /u01/app/oracle/product/19.3.0/dbhome/dbs/spfileorcl1.ora: No such file or directory
*/

/* ------------------------------------------------------------------------------
   1-3. 포인터 파일 재생성
   ※ ASM 내 실제 SPFILE 경로는 SHOW PARAMETER spfile 또는 ASMCMD find 명령으로
     확인 후, 아래 형식 그대로 재생성한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — oracle, OS 명령]
-- 포인터 파일 재생성
$ echo "SPFILE='+DATA/ORCL/PARAMETERFILE/spfile.263.1233770977'" > $ORACLE_HOME/dbs/spfileorcl1.ora

-- [확인]
$ cat $ORACLE_HOME/dbs/spfileorcl1.ora

/* [결과]
SPFILE='+DATA/ORCL/PARAMETERFILE/spfile.263.1233770977'
*/

/* 두 노드 모두 이 포인터를 통해 동일한 SPFILE을 참조하므로,
   한 노드에서 변경한 파라미터가 양 노드에 함께 반영된다. */


/* ==============================================================================
   2. ALTER SYSTEM SET … SID 범위 제어
   ------------------------------------------------------------------------------
   RAC에서 파라미터는 전체 적용 / 특정 인스턴스 적용을 구분해서 설정할 수 있다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   2-1. 전체 인스턴스 공통 적용
   ※ SID='*'는 SPFILE 내에 공통 항목으로 기록되어 모든 인스턴스에 적용된다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
-- 전체 인스턴스 공통 적용
ALTER SYSTEM SET open_cursors=500 SID='*';

/* [결과]
System altered.
*/

/* ------------------------------------------------------------------------------
   2-2. 인스턴스별 개별 적용
   ※ UNDO_TABLESPACE, INSTANCE_NUMBER, THREAD처럼 인스턴스마다 값이 달라야 하는
     파라미터는 반드시 SID를 지정해야 한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
-- orcl1 인스턴스에만 적용
ALTER SYSTEM SET undo_tablespace='UNDOTBS1' SID='orcl1';

-- orcl2 인스턴스에만 적용
ALTER SYSTEM SET undo_tablespace='UNDOTBS2' SID='orcl2';

/* [결과]
System altered.
System altered.
*/

-- [확인]
SELECT inst_id, value
FROM gv$parameter
WHERE name = 'undo_tablespace';

/* [결과]
   INST_ID VALUE
---------- ------------------------------
         1 UNDOTBS1
         2 UNDOTBS2
*/


/* ==============================================================================
   3. ALTER SYSTEM RESET — 파라미터 삭제
   ------------------------------------------------------------------------------
   SID 단위로 설정한 파라미터를 잘못 지정했거나 더 이상 필요 없을 때는
   RESET으로 제거한다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   3-1. SID='*' 공통 항목 삭제
   ※ ALTER SYSTEM SET은 값을 바꾸지만, ALTER SYSTEM RESET은 SPFILE에서 해당
     SID 항목 라인 자체를 삭제한다. RESET 대상이 SID='*' 공통 항목이면
     전체 인스턴스 설정이 사라지므로, 어떤 SID 범위를 지우는지 반드시 확인 후
     실행한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
ALTER SYSTEM RESET open_cursors SID='*' SCOPE=SPFILE;

/* [결과]
System altered.
*/

/* ------------------------------------------------------------------------------
   3-2. pfile 덤프로 삭제 여부 확인
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
-- pfile로 덤프해서 라인 제거 여부 확인
CREATE PFILE='/tmp/check.ora' FROM SPFILE;

-- [oelsvr1 — oracle, OS 명령]
$ grep open_cursors /tmp/check.ora

/* [결과]
(결과 없음)
*/


/* ==============================================================================
   4. RAC 전용 파라미터 — CLUSTER_DATABASE · INSTANCE_NUMBER · THREAD
   ============================================================================== */

-- [oelsvr1 — SQL*Plus, orcl1]
SHOW PARAMETER cluster_database;

/* [결과]
NAME                                 TYPE        VALUE
------------------------------------ ----------- ------------------------------
cluster_database                     boolean     TRUE
cluster_database_instances           integer     2
*/

-- 인스턴스 고유 번호 및 리두 로그 스레드 번호 조회
SELECT inst_id, instance_number, thread#
FROM gv$instance;

/* [결과]
   INST_ID INSTANCE_NUMBER     THREAD#
---------- --------------- -----------
         1               1           1
         2               2           2
*/

/* +-------------------+----------------------------------------------------+
   | 파라미터            | 의미                                                 |
   +-------------------+----------------------------------------------------+
   | CLUSTER_DATABASE   | TRUE 설정 시 RAC 모드로 기동 (모든 인스턴스 공통)            |
   | INSTANCE_NUMBER    | 인스턴스를 식별하는 고유 번호 (노드별 상이)                   |
   | THREAD             | 인스턴스가 사용하는 Redo Log Thread 번호                  |
   |                    | (INSTANCE_NUMBER와 동일하게 매핑하는 것이 일반적)            |
   +-------------------+----------------------------------------------------+

   CLUSTER_DATABASE=FALSE로 변경하면 해당 인스턴스를 단일 인스턴스 모드로
   기동할 수 있다 — 트러블슈팅이나 maintenance 작업 시 사용.
   INSTANCE_NUMBER와 THREAD는 인스턴스마다 고유해야 하며, 두 인스턴스가
   같은 번호를 가지면 기동이 실패한다. */


/* ==============================================================================
   5. compatible 파라미터 — 양 노드 값 일치 필요성
   ============================================================================== */

-- [oelsvr1 — SQL*Plus, orcl1]
SELECT inst_id, value
FROM gv$parameter
WHERE name = 'compatible';

/* [결과]
   INST_ID VALUE
---------- ------------------------------
         1 19.0.0
         2 19.0.0
*/

/* compatible은 디스크 포맷 구조와 직결되는 파라미터로, 공용 SPFILE을
   쓰더라도 SID 단위 변경이 의미가 없다 — 두 인스턴스는 동일한
   데이터파일·컨트롤파일을 공유하므로 값이 다르면 한쪽 인스턴스가
   기동조차 되지 않는다.
   따라서 compatible은 항상 SID='*'로만 설정하며, 운영 중 임의로 올리는
   작업은 되돌릴 수 없는 단방향 변경이라는 점을 인지하고 진행해야 한다. */


/* ==============================================================================
   6. ASM_PREFERRED_READ_FAILURE_GROUPS
   ------------------------------------------------------------------------------
   NORMAL/HIGH 미러링 디스크 그룹에서 각 노드가 자신과 물리적으로 가까운
   Failure Group을 우선 읽도록 지정하는 파라미터다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   6-1. ASM1 인스턴스 지정
   ※ 노드마다 다른 값을 지정해야 하므로 SID를 인스턴스별로 명시한다 —
     미지정 시 ASM은 라운드로빈 방식으로 모든 Failure Group을 동일하게 읽는다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — ASM 인스턴스, +ASM1]
ALTER SYSTEM SET asm_preferred_read_failure_groups='DATA.DATA_FG1' SID='+ASM1' SCOPE=BOTH;

/* [결과]
System altered.
*/

/* ------------------------------------------------------------------------------
   6-2. ASM2 인스턴스 지정
   ------------------------------------------------------------------------------ */

-- [oelsvr2 — ASM 인스턴스, +ASM2]
ALTER SYSTEM SET asm_preferred_read_failure_groups='DATA.DATA_FG2' SID='+ASM2' SCOPE=BOTH;

/* [결과]
System altered.
*/

/* ------------------------------------------------------------------------------
   6-3. 적용 결과 확인
   ------------------------------------------------------------------------------ */

-- [확인]
SELECT inst_id, value
FROM gv$parameter
WHERE name = 'asm_preferred_read_failure_groups';

/* [결과]
   INST_ID VALUE
---------- ------------------------------
         1 DATA.DATA_FG1
         2 DATA.DATA_FG2
*/


/* ==============================================================================
   7. Redo Log Thread 구조
   ============================================================================== */

-- [oelsvr1 — SQL*Plus, orcl1]
SELECT thread#, group#, status, bytes/1024/1024 MB
FROM v$log
ORDER BY thread#, group#;

/* [결과]
   THREAD#     GROUP# STATUS                   MB
---------- ---------- ---------------- ----------
         1          1 INACTIVE                200
         1          2 CURRENT                 200
         2          3 INACTIVE                200
         2          4 CURRENT                 200
*/

/* 단일 인스턴스는 Thread 1개만 사용하지만, RAC는 인스턴스마다 독립된
   Thread를 가진다 — 동시에 여러 인스턴스가 Redo를 기록해도 충돌이 없다.
   각 Thread는 최소 2개 이상의 Redo Log Group을 가져야 하며, 그룹 수가
   부족하면 LGWR이 대기 상태에 빠질 수 있다.
   Recovery 시에는 모든 Thread의 Redo가 함께 적용되어야 데이터 일관성이
   보장된다. */


/* ==============================================================================
   8. Thread 3 추가 및 활성화
   ------------------------------------------------------------------------------
   신규 인스턴스를 추가하거나 Thread가 비활성 상태인 경우의 절차다.
   기존 RAC 구성에는 Thread 1(orcl1) · Thread 2(orcl2)가 이미 존재하며,
   3번째 인스턴스 확장을 가정해 Thread 3을 신규로 추가한다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   8-1. Thread 3용 Redo Log Group 추가
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
ALTER DATABASE ADD LOGFILE THREAD 3 GROUP 7 SIZE 200M;
ALTER DATABASE ADD LOGFILE THREAD 3 GROUP 8 SIZE 200M;
ALTER DATABASE ADD LOGFILE THREAD 3 GROUP 9 SIZE 200M;

/* [결과]
Database altered.
*/

/* ------------------------------------------------------------------------------
   8-2. Thread 활성화
   ※ Thread는 ASM 그룹 추가만으로는 사용할 수 없고, ENABLE PUBLIC THREAD로
     명시적으로 활성화해야 한다. ENABLED 컬럼이 PUBLIC이어야 어떤 인스턴스든
     해당 Thread를 사용할 수 있다 — PRIVATE은 지정된 인스턴스 전용이다.
     활성화 직후에는 실제로 그 Thread를 사용하는 인스턴스가 없으므로
     STATUS는 CLOSED로 남는다 — 인스턴스가 해당 Thread 번호로 기동해야
     OPEN으로 전환된다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
ALTER DATABASE ENABLE PUBLIC THREAD 3;

/* [결과]
Database altered.
*/

-- [확인]
SELECT thread#, status, enabled
FROM v$thread;

/* [결과]
   THREAD# STATUS  ENABLED
---------- ------- ----------
         1 OPEN    PUBLIC
         2 OPEN    PUBLIC
         3 CLOSED  PUBLIC
*/

/* ------------------------------------------------------------------------------
   8-3. 원상 복구 — Thread 3 비활성화 및 삭제
   ※ 실습 후 기존 2 Node 구성으로 되돌리려면, 반드시 비활성화 → 로그 그룹
     삭제 순서로 진행한다. 순서를 바꾸면 ORA 에러가 발생한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
-- 1) Thread 3을 사용 중인 인스턴스가 없는지 확인
SELECT thread#, status, enabled
FROM v$thread;

/* [결과]
   THREAD# STATUS  ENABLED
---------- ------- ----------
         1 OPEN    PUBLIC
         2 OPEN    PUBLIC
         3 CLOSED  PUBLIC
*/

-- STATUS가 CLOSED여야 안전하게 진행 가능. OPEN이면 해당 Thread를 쓰는
-- 인스턴스를 먼저 SHUTDOWN 해야 한다.

-- 2) Thread 비활성화
ALTER DATABASE DISABLE THREAD 3;

/* [결과]
Database altered.
*/

-- 3) Thread 3에 속한 각 Redo Log Group 삭제
ALTER DATABASE DROP LOGFILE GROUP 7;
ALTER DATABASE DROP LOGFILE GROUP 8;
ALTER DATABASE DROP LOGFILE GROUP 9;

/* [결과]
Database altered.
*/

-- [확인 — Thread 3 흔적이 완전히 사라졌는지 확인]
SELECT thread#, status, enabled
FROM v$thread;

/* [결과]
   THREAD# STATUS  ENABLED
---------- ------- ----------
         1 OPEN    PUBLIC
         2 OPEN    PUBLIC
*/

SELECT group#, thread#, status
FROM v$log
WHERE thread# = 3;

/* [결과]
no rows selected
*/

/* DISABLE THREAD는 그 Thread에 속한 로그 그룹이 아직 존재해도 실행
   가능하지만, 인스턴스가 해당 Thread로 기동 중(OPEN 상태)이면 실패한다 —
   먼저 인스턴스를 내려야 한다.
   DROP LOGFILE GROUP은 해당 그룹의 STATUS가 CURRENT나 ACTIVE면 실패한다 —
   비활성화 직후라면 보통 INACTIVE 또는 UNUSED 상태이므로 바로 삭제 가능하다.
   ASM 상에 그룹 삭제 후에도 OMF 파일이 일부 남아 있다면, ASMCMD로 +REDO
   디스크 그룹 내 잔여 파일을 확인하고 정리한다. */


/* ==============================================================================
   9. UNDO 관리 — 인스턴스별 전용 UNDO TABLESPACE
   ============================================================================== */

/* ------------------------------------------------------------------------------
   9-1. 인스턴스별 undo_tablespace 확인
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
SELECT inst_id, name, value
FROM gv$parameter
WHERE name = 'undo_tablespace';

/* [결과]
   INST_ID NAME             VALUE
---------- ---------------- ------------------------------
         1 undo_tablespace  UNDOTBS1
         2 undo_tablespace  UNDOTBS2
*/

/* ------------------------------------------------------------------------------
   9-2. 신규 UNDO TABLESPACE 생성
   ※ RAC는 인스턴스마다 독립된 UNDO TABLESPACE를 가져야 한다 — 인스턴스 간
     트랜잭션 충돌을 막기 위함이다. 같은 UNDO TABLESPACE를 두 인스턴스가
     동시에 사용하도록 설정하면 기동 시 오류가 발생한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
CREATE UNDO TABLESPACE undotbs3
    DATAFILE '+DATA' SIZE 500M AUTOEXTEND ON;

/* [결과]
Tablespace created.
*/


/* ==============================================================================
   10. UNDO_TABLESPACE 변경
   ============================================================================== */

/* ------------------------------------------------------------------------------
   10-1. orcl2 인스턴스 UNDO 전환
   ※ ALTER SYSTEM SET undo_tablespace는 즉시 적용되지만, 이전 UNDO
     테이블스페이스에 진행 중인 트랜잭션이 남아 있으면 해당 트랜잭션이
     끝날 때까지 PENDING OFFLINE 상태로 유지된다.
   ------------------------------------------------------------------------------ */

-- [oelsvr2 — SQL*Plus, orcl2]
-- orcl2 인스턴스의 UNDO를 신규 테이블스페이스로 전환
ALTER SYSTEM SET undo_tablespace='UNDOTBS3' SID='orcl2';

/* [결과]
System altered.
*/

-- [확인 — 전환 직후 OFFLINE 가능 여부]
SELECT tablespace_name, status
FROM dba_tablespaces
WHERE tablespace_name LIKE 'UNDOTBS%';

/* [결과]
TABLESPACE_NAME      STATUS
-------------------- ---------
UNDOTBS1             ONLINE
UNDOTBS2             ONLINE
UNDOTBS3             ONLINE
*/

SELECT inst_id, name, value
FROM gv$parameter
WHERE name = 'undo_tablespace';

/* [결과]
   INST_ID NAME             VALUE
---------- ---------------- ------------------------------
         1 undo_tablespace  UNDOTBS1
         2 undo_tablespace  UNDOTBS3
*/

/* ------------------------------------------------------------------------------
   10-2. 이전 UNDO TABLESPACE OFFLINE
   ※ 이전 UNDO를 DROP하려면 모든 세션의 트랜잭션이 종료된 뒤 OFFLINE
     상태를 확인하고 진행해야 한다.
   ------------------------------------------------------------------------------ */

-- [oelsvr2 — SQL*Plus, orcl2]
-- 이전 UNDO TABLESPACE는 트랜잭션 종료 후 OFFLINE
ALTER TABLESPACE undotbs2 OFFLINE;

/* [결과]
Tablespace altered.
*/

/* ------------------------------------------------------------------------------
   10-3. 원상 복구
   ※ undo_tablespace를 원래 값으로 재지정하면 즉시 적용된다. UNDOTBS3에
     남아 있던 트랜잭션이 모두 종료되어야 완전히 OFFLINE 처리할 수 있다.
   ------------------------------------------------------------------------------ */

-- [oelsvr2 — SQL*Plus, orcl2]
-- undotbs2 다시 online으로 전환
ALTER TABLESPACE undotbs2 ONLINE;

/* [결과]
Tablespace altered.
*/

-- orcl2 인스턴스의 UNDO를 다시 UNDOTBS2로 원상복구
ALTER SYSTEM SET undo_tablespace='UNDOTBS2' SID='orcl2';

/* [결과]
System altered.
*/

-- [확인]
SELECT inst_id, value
FROM gv$parameter
WHERE name = 'undo_tablespace';

/* [결과]
   INST_ID VALUE
---------- ------------------------------
         1 UNDOTBS1
         2 UNDOTBS2
*/

-- UNDOTBS3는 더 이상 사용되지 않으므로 트랜잭션 종료 후 OFFLINE
ALTER TABLESPACE undotbs3 OFFLINE;

/* [결과]
Tablespace altered.
*/

-- UNDOTBS3가 더 이상 필요 없다면 OFFLINE 확인 후 DROP 대상으로 정리한다.
-- DROP TABLESPACE undotbs3 INCLUDING CONTENTS AND DATAFILES;


/* ==============================================================================
   11. Quiesce RAC Database
   ============================================================================== */

-- [oelsvr1 — SQL*Plus, orcl1 — SYSDBA]
ALTER SYSTEM QUIESCE RESTRICTED;

/* [결과]
System altered.
*/

-- (oelsvr2에서 hr 세션으로 접속 시도 — 일반 세션은 무한 대기 상태가 된다)

-- [확인]
SELECT inst_id, status
FROM gv$instance;

/* [결과]
   INST_ID STATUS
---------- ------------
         1 OPEN
         2 OPEN
*/

SELECT inst_id, active_state
FROM gv$instance;

/* [결과]
   INST_ID ACTIVE_STATE
---------- ----------------
         1 QUIESCED
         2 QUIESCED
*/

-- STATUS는 인스턴스 기동 단계를 나타내므로 OPEN을 유지하고,
-- Quiesce 적용 여부는 ACTIVE_STATE로 확인한다.

-- 해제
ALTER SYSTEM UNQUIESCE;

/* [결과]
System altered.
*/

-- (해제 후 대기 중이던 hr 세션이 정상 접속됨)

/* Quiesce는 인스턴스를 내리지 않고 일반 세션의 신규 작업만 차단하는
   기능이다 — DBA 세션(RESTRICTED SESSION 권한)은 계속 작업할 수 있다.
   통계 수집, 일부 유지보수 작업처럼 다른 세션의 간섭 없이 진행해야 하는
   작업 직전에 사용한다.
   Quiesce 상태는 모든 인스턴스에 동시에 적용되며, 한 인스턴스만 부분
   적용할 수 없다. */


/* ==============================================================================
   12. Cross-instance Session Kill
   ------------------------------------------------------------------------------
   다른 노드에서 실행 중인 세션을 현재 노드에서 종료하는 절차다.
   ============================================================================== */

-- [oelsvr1 — SQL*Plus, orcl1]
-- (oelsvr2에서 hr로 접속한 상태)
SELECT inst_id, sid, serial#, username, status
FROM gv$session
WHERE username = 'HR';

/* [결과]
   INST_ID        SID    SERIAL# USERNAME             STATUS
---------- ---------- ---------- -------------------- --------
         2        128      41944 HR                   INACTIVE
*/

-- INST_ID를 포함해 종료
ALTER SYSTEM KILL SESSION '128,41944,@2' IMMEDIATE;

/* [결과]
System altered.
*/

-- [확인]
SELECT inst_id, sid, serial#, status
FROM gv$session
WHERE sid = 128 AND inst_id = 2;

/* [결과]
no rows selected
*/

/* 단일 인스턴스의 KILL SESSION 'sid,serial#' 문법에 @inst_id를 추가하면
   다른 노드의 세션도 현재 노드 접속만으로 종료할 수 있다.
   gv$session으로 SID·SERIAL#과 함께 INST_ID를 반드시 확인한 뒤 지정해야
   한다 — INST_ID 누락 시 로컬 인스턴스 기준으로 해석되어 엉뚱한 세션이
   종료되거나 오류가 발생한다. */


/* ==============================================================================
   13. ASM Instance Recovery vs Crash Recovery
   ------------------------------------------------------------------------------
   +-----------------+-------------------------------+----------------------------+
   | 구분              | Instance Recovery              | Crash Recovery             |
   +-----------------+-------------------------------+----------------------------+
   | 발생 상황          | RAC에서 한 인스턴스만 비정상 종료      | 모든 인스턴스가 동시에 비정상 종료     |
   | 수행 주체          | 생존한 다른 인스턴스의 SMON         | 재기동되는 인스턴스 자신의 SMON      |
   | Redo 적용 범위    | 장애 인스턴스의 Thread Redo만 적용  | 전체 인스턴스 Thread Redo 적용     |
   | 서비스 영향        | 생존 노드는 서비스 계속, 장애 노드분만 복구 | 클러스터 전체 서비스 중단 후 복구      |
   +-----------------+-------------------------------+----------------------------+
   ============================================================================== */

-- [oelsvr1 — orcl1 생존, orcl2가 비정상 종료된 상황을 가정 — OS 명령]
-- orcl1의 alert log에서 복구 진행 확인
$ tail -50 $ORACLE_BASE/diag/rdbms/orcl/orcl1/trace/alert_orcl1.log

/* [결과 예시]
Reconfiguration started (old inc 4, new inc 6)
...
SMON: Parallel transaction recovery slaves...
Instance recovery: looking for dead threads
Beginning instance recovery of 1 threads
*/

/* RAC에서 한 노드가 죽으면 남은 노드의 SMON이 죽은 노드의 Thread Redo를
   대신 적용해서 복구한다 — 이 과정에서 서비스 전체가 멈추지 않는다.
   ASM 인스턴스도 동일한 원리로, 한 노드의 ASM 인스턴스 장애 시 다른 노드
   ASM이 해당 디스크 그룹 메타데이터를 복구한다.
   srvctl로 등록된 인스턴스는 장애 후 Clusterware의 정책(AUTOMATIC)에
   따라 자동 재기동되며, 재기동된 인스턴스 자신은 Crash Recovery가 아닌
   일반 기동 절차를 따른다. */


/* ==============================================================================
   14. 주요 명령어 정리
   ============================================================================== */

-- 파라미터 SID 범위 지정
ALTER SYSTEM SET <파라미터>=<값> SID='*' | 'orcl1' | 'orcl2';

-- 파라미터 삭제
ALTER SYSTEM RESET <파라미터> SID='<SID>' SCOPE=SPFILE;

-- 전역 파라미터 조회
SELECT inst_id, name, value FROM gv$parameter WHERE name LIKE '%키워드%';

-- Thread 상태 조회
SELECT thread#, status, enabled FROM v$thread;

-- Thread 추가 및 활성화
ALTER DATABASE ADD LOGFILE THREAD <n> GROUP <m> SIZE <크기>;
ALTER DATABASE ENABLE PUBLIC THREAD <n>;

-- Thread 비활성화 및 삭제
ALTER DATABASE DISABLE THREAD <n>;
ALTER DATABASE DROP LOGFILE GROUP <m>;

-- UNDO 전환
ALTER SYSTEM SET undo_tablespace='<TS명>' SID='<SID>';

-- Quiesce
ALTER SYSTEM QUIESCE RESTRICTED;
ALTER SYSTEM UNQUIESCE;

-- 타 노드 세션 종료
ALTER SYSTEM KILL SESSION 'sid,serial#,@inst_id' IMMEDIATE;


/* ==============================================================================
   실습 핵심 요약
   ------------------------------------------------------------------------------
   주제                                  핵심 포인트
   ------------------------------------------------------------------------------
   SPFILE                              ASM 공용 파일 1개를 전 노드가 공유,
                                        로컬 파일은 위치 포인터
   SID 범위                             *는 전체 적용, 특정 SID는 해당 인스턴스 전용
   RESET                               값 변경이 아닌 SPFILE 라인 삭제
   CLUSTER_DATABASE /                  RAC 식별 및 노드별 고유값 필수
   INSTANCE_NUMBER / THREAD
   compatible                          디스크 구조 연동 — 항상 전체 공통값, 단방향 변경
   ASM_PREFERRED_READ_FAILURE_GROUPS   노드별 가까운 Failure Group 우선 읽기
   Redo Thread                         인스턴스마다 독립 Thread, 최소 2개 그룹 필요
   Thread 활성화                        ADD LOGFILE 후 ENABLE PUBLIC THREAD 필수
   Thread 원상복구                       반드시 DISABLE THREAD → DROP LOGFILE GROUP 순서
   UNDO                                인스턴스별 전용 테이블스페이스, 공유 시 기동 오류
   UNDO 전환                            즉시 적용되나 잔여 트랜잭션 종료까지 OFFLINE 보류
   Quiesce                             인스턴스 유지한 채 일반 세션 신규 작업만 차단,
                                        ACTIVE_STATE 컬럼으로 적용 여부 확인
   Cross-instance Kill                 KILL SESSION 'sid,serial#,@inst_id'로 타 노드 세션 종료
   Instance Recovery                   생존 노드가 장애 노드 Thread만 복구, 서비스 유지
   Crash Recovery                      전체 인스턴스 동시 장애 시 재기동 인스턴스가 전체 복구
   ============================================================================== */
