/* ==============================================================================
   RAC 05: RMAN 백업 & Recovery — Catalog 서버 구축 · 인스턴스 장애 복구
   Blog  : https://nsylove97.tistory.com/67
   GitHub: https://github.com/nsylove97/NSY-DB-Portfolio
   ------------------------------------------------------------------------------
   실습 환경
   OS           : Oracle Linux 7.9 (VMware Virtual Machine)
   DB           : Oracle Database 19c
   Grid         : Oracle Grid Infrastructure 19c
   구성           : 2 Node RAC (VM1 · VM2)
   공유 스토리지    : ASM (+DATA / +FRA / +REDO / +OCR)
   네트워크         : Public (NAT) · Private (Host-only) · VIP · SCAN
   Catalog DB   : rcatdb (단일 인스턴스, 2daydba VM)
   VM1/VM2 초기 구성 참조 : ASM 실습 01
   RAC 구축 참조          : RAC 02

   노드 정보
   +----------+----------------------+----------------------------------------+
   | 구분       | Hostname             | 비고                                     |
   +----------+----------------------+----------------------------------------+
   | Node1     | oelsvr1.localdomain  | orcl1 인스턴스, RAC Target DB              |
   | Node2     | oelsvr2.localdomain  | orcl2 인스턴스, RAC Target DB              |
   | Catalog   | 2daydba              | rcatdb 단일 인스턴스, Recovery Catalog 전용   |
   +----------+----------------------+----------------------------------------+

   디렉토리 정보
   ORACLE_BASE : /u01/app/oracle
   ORACLE_HOME : /u01/app/oracle/product/19.3.0/dbhome
   DB_NAME     : orcl (orcl1 / orcl2 인스턴스)
   CATALOG_DB  : rcatdb (2daydba)
   ------------------------------------------------------------------------------
   목차
   1.    RMAN Catalog 서버 구축 — tnsnames · 테이블스페이스 · 사용자 생성
   1-1.  Catalog 전용 테이블스페이스 · 사용자 생성
   1-2.  hosts 파일 등록
   1-3.  tnsnames.ora 등록
   1-4.  tnsping 접속 확인
   2.    RMAN Catalog 연결 및 RAC 대상 DB 등록
   2-1.  RMAN에서 Target · Catalog 동시 연결
   2-2.  카탈로그 스키마 생성
   2-3.  DB 등록
   2-4.  Incarnation 확인
   3.    RAC에서 RMAN 백업 실행 — 노드 간 인식 구조
   3-1.  Node1(orcl1)에서 백업 수행
   3-2.  Node2(orcl2)에서 백업 이력 확인
   4.    Snapshot Controlfile 위치 확인 및 공유 스토리지 변경
   4-1.  현재 위치 확인
   4-2.  공유 스토리지로 변경
   4-3.  변경 결과 확인
   5.    RMAN 백업 채널 — +FRA 경로 지정
   5-1.  현재 채널 설정 확인
   5-2.  백업 채널을 +FRA로 변경
   5-3.  FRA 용량 상한 확인
   6.    인스턴스 장애 시뮬레이션 — 강제 종료 및 자동 인계 확인
   6-1.  pmon 프로세스 강제 종료
   6-2.  양 노드 상태 확인
   6-3.  생존 노드 세션 정상 처리 확인
   6-4.  Clusterware 자동 재기동 확인
   7.    RAC Instance Recovery 흐름 — GES → GCS → LMS → SMON
   8.    FAST_START_MTTR_TARGET — 단일 인스턴스 vs RAC
   8-1.  현재 상태 확인
   8-2.  복구 목표 시간 설정
   8-3.  설정 후 예측 조회
   8-4.  Advisor 예측 조회
   9.    RECOVERY_PARALLELISM — 병렬 복구 프로세스 수
   9-1.  현재 값 확인
   9-2.  값 변경
   10.   Asynchronous I/O · Buffer Cache와 복구 속도
   10-1. disk_asynch_io 확인
   10-2. Buffer Cache 크기 확인
   11.   실습 핵심 요약
   12.   관련 뷰 & 명령어 정리
   ============================================================================== */


/* ==============================================================================
   1. RMAN Catalog 서버 구축 — tnsnames · 테이블스페이스 · 사용자 생성
   ==============================================================================
   ※ RAC는 인스턴스가 여러 개이므로 백업 이력을 각 노드 컨트롤파일에만 의존하면
      관리가 번거롭다. 별도 서버(2daydba)에 Recovery Catalog를 구축해
      모든 백업 메타데이터를 중앙에서 관리한다.
   ※ Recovery Catalog는 RAC 대상 DB와 분리된 별도의 단일 인스턴스 DB에 두는 것이
      일반적이다 — Target DB 손상 시 백업 메타데이터까지 함께 소실되는 것을 막기 위함.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   1-1. Catalog 전용 테이블스페이스 · 사용자 생성
   ※ Catalog 전용 테이블스페이스와 계정을 분리해 두면 여러 Target DB를
      하나의 Catalog로 통합 관리할 수 있다.
   ------------------------------------------------------------------------------ */

-- [2daydba — SQL*Plus]
CREATE TABLESPACE rcat_ts
DATAFILE '/u01/app/oracle/oradata/rcatdb/rcat_ts01.dbf' SIZE 500M
AUTOEXTEND ON;
/* [결과]
   Tablespace created.
   -> rcat_ts 테이블스페이스 생성 확인
*/

-- Catalog 전용 사용자 생성
CREATE USER rman_catalog IDENTIFIED BY rman_catalog
DEFAULT TABLESPACE rcat_ts
QUOTA UNLIMITED ON rcat_ts;
/* [결과]
   User created.
   -> rman_catalog 사용자 생성 확인
*/

-- Recovery Catalog Owner 롤 부여
GRANT recovery_catalog_owner TO rman_catalog;
/* [결과]
   Grant succeeded.
   -> rman_catalog 계정에 카탈로그 소유 권한 부여 확인
*/

/* ------------------------------------------------------------------------------
   1-2. hosts 파일 등록
   ※ oelsvr1과 2daydba 양쪽 모두 서로의 IP를 알아야 tnsping·rman 접속이 가능하다.
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 · 2daydba — root, OS 터미널, 양쪽 모두 동일하게 등록]
  $ vi /etc/hosts

  192.168.111.20  2daydba
  192.168.111.50  oelsvr1
*/

/* ------------------------------------------------------------------------------
   1-3. tnsnames.ora 등록
   ※ Catalog DB 접속을 위한 서비스 엔트리를 2daydba · oelsvr1 양쪽에 등록한다.
   ------------------------------------------------------------------------------ */

/*
[2daydba, oelsvr1 — oracle 계정, OS 터미널]
  $ vi $ORACLE_HOME/network/admin/tnsnames.ora

  RCATDB =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = 2daydba)(PORT = 1521))
      (CONNECT_DATA = (SERVICE_NAME = orcl)))
*/

/* ------------------------------------------------------------------------------
   1-4. tnsping 접속 확인
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — oracle 계정, OS 터미널]
  $ tnsping RCATDB
-- [결과]
  OK (10 msec)
  -> Node1에서 Catalog DB 서비스명 정상 응답 확인
*/


/* ==============================================================================
   2. RMAN Catalog 연결 및 RAC 대상 DB 등록
   ==============================================================================
   ※ REGISTER DATABASE는 DBID 기준으로 1회만 수행하면 되며, 어느 노드에서
      접속해 등록하든 카탈로그에는 동일하게 반영된다.
   ※ RAC는 양 인스턴스가 같은 컨트롤파일을 공유하므로, 카탈로그 등록도
      단일 인스턴스와 동일한 절차로 진행한다 — 인스턴스별 별도 등록은 불필요하다.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   2-1. RMAN에서 Target · Catalog 동시 연결
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — oracle 계정, RAC Target DB, OS 터미널]
  $ rman target / catalog rman_catalog/rman_catalog@RCATDB
-- [결과]
  connected to target database: ORCL (DBID=1761551299)
  connected to recovery catalog database
  -> Target DB · Catalog DB 동시 연결 확인
*/

/* ------------------------------------------------------------------------------
   2-2. 카탈로그 스키마 생성
   ------------------------------------------------------------------------------ */

/*
[RMAN]
  RMAN> CREATE CATALOG TABLESPACE rcat_ts;
-- [결과]
  recovery catalog created
  -> rcat_ts 테이블스페이스에 카탈로그 스키마 생성 확인
*/

/* ------------------------------------------------------------------------------
   2-3. DB 등록
   ------------------------------------------------------------------------------ */

/*
[RMAN]
  RMAN> REGISTER DATABASE;
-- [결과]
  database registered in recovery catalog
  starting full resync of recovery catalog
  full resync complete
  -> ORCL DB가 카탈로그에 등록 및 리싱크 완료 확인
*/

/* ------------------------------------------------------------------------------
   2-4. Incarnation 확인
   ------------------------------------------------------------------------------ */

/*
[RMAN]
  RMAN> LIST INCARNATION;
-- [결과]
  List of Database Incarnations
  DB Key  Inc Key DB Name  DB ID            STATUS  Reset SCN  Reset Time
  ------- ------- -------- ---------------- ------- ---------- ----------
  1       18      ORCL     1761551299       PARENT  1          17-APR-19
  1       2       ORCL     1761551299       CURRENT 1920977    20-MAY-26
  -> CURRENT Incarnation 등록 확인
*/


/* ==============================================================================
   3. RAC에서 RMAN 백업 실행 — 노드 간 인식 구조
   ==============================================================================
   ※ 백업 파일 자체는 +FRA(공유 ASM)에 기록되므로, 어느 노드의 채널이 백업을
      수행했는지와 무관하게 모든 노드가 해당 백업셋에 접근할 수 있다.
   ※ 멀티 채널로 양 노드에 백업 부하를 분산할 수도 있다 —
      CONFIGURE DEVICE TYPE DISK PARALLELISM 2로 채널 수를 늘려 노드별 채널 할당 가능.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   3-1. Node1(orcl1)에서 백업 수행
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — RMAN, orcl1에서 백업 수행]
  RMAN> BACKUP DATABASE PLUS ARCHIVELOG;
-- [결과]
  allocated channel: ORA_DISK_1
  channel ORA_DISK_1: SID=29 instance=orcl1 device type=DISK
  channel ORA_DISK_1: starting archived log backup set
  channel ORA_DISK_1: specifying archived log(s) in backup set
  ...
  channel ORA_DISK_1: backup set complete, elapsed time: 00:00:03
  -> orcl1 채널로 전체 백업 + 아카이브 로그 백업 완료 확인
*/

/* ------------------------------------------------------------------------------
   3-2. Node2(orcl2)에서 백업 이력 확인
   ※ 한 노드에서 수행한 백업이 다른 노드에서도 즉시 동일하게 조회된다 —
      양 인스턴스가 같은 컨트롤파일과 카탈로그를 공유하기 때문이다.
   ------------------------------------------------------------------------------ */

/*
[oelsvr2 — RMAN, orcl2에서 확인]
  RMAN> LIST BACKUP SUMMARY;
-- [결과]
  List of Backups
  ===============
  Key     TY LV S Device Type Completion Time #Pieces #Copies Compressed Tag
  ------- -- -- - ----------- --------------- ------- ------- ---------- ---
  12      B  F  A DISK        ...             1       1       NO         TAG...
  -> orcl1에서 수행한 백업이 orcl2 RMAN 세션에서도 동일하게 조회됨 확인
*/


/* ==============================================================================
   4. Snapshot Controlfile 위치 확인 및 공유 스토리지 변경
   ==============================================================================
   ※ Snapshot Controlfile은 백업 시점의 컨트롤파일 정보를 읽기 일관성 있게
      고정하는 임시 파일이다 — RMAN이 백업·복구 명령을 실행하는 동안만 생성·사용된다.
   ※ RAC에서는 어느 노드에서 RMAN을 실행하든 동일한 파일에 접근해야 하므로,
      반드시 모든 노드가 공유하는 위치(ASM +DATA 등)에 두어야 한다 — 로컬 디스크
      경로로 두면 다른 노드에서 실행 시 파일을 찾지 못해 오류가 발생한다.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   4-1. 현재 위치 확인
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — RMAN]
  RMAN> SHOW SNAPSHOT CONTROLFILE NAME;
-- [결과]
  RMAN configuration parameters for database with db_unique_name ORCL are:
  CONFIGURE SNAPSHOT CONTROLFILE NAME TO
    '/u01/app/oracle/product/19.3.0/dbhome/dbs/snapcf_orcl1.f';
  -> 현재 위치가 로컬 디스크(ORACLE_HOME/dbs)임을 확인
*/

/* ------------------------------------------------------------------------------
   4-2. 공유 스토리지로 변경
   ------------------------------------------------------------------------------ */

/*
[RMAN]
  RMAN> CONFIGURE SNAPSHOT CONTROLFILE NAME TO '+DATA/snapcf_orcl1.f';
-- [결과]
  new RMAN configuration parameters:
  CONFIGURE SNAPSHOT CONTROLFILE NAME TO '+DATA/snapcf_orcl1.f';
  new RMAN configuration parameters are successfully stored
  starting full resync of recovery catalog
  full resync complete
  -> +DATA 공유 스토리지 경로로 변경 및 카탈로그 리싱크 완료 확인
*/

/* ------------------------------------------------------------------------------
   4-3. 변경 결과 확인
   ------------------------------------------------------------------------------ */

/*
[RMAN]
  RMAN> SHOW SNAPSHOT CONTROLFILE NAME;
-- [결과]
  RMAN configuration parameters for database with db_unique_name ORCL are:
  CONFIGURE SNAPSHOT CONTROLFILE NAME TO '+DATA/snapcf_orcl1.f';
  -> +DATA 경로로 정상 변경 확인
*/


/* ==============================================================================
   5. RMAN 백업 채널 — +FRA 경로 지정
   ==============================================================================
   ※ 실습 환경에서 디스크 여분이 없는 경우, 기존 +FRA를 백업 대상으로
      함께 사용하는 것이 무난한 선택이다.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   5-1. 현재 채널 설정 확인
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — RMAN]
  RMAN> SHOW CHANNEL;
-- [결과]
  RMAN configuration parameters for database with db_unique_name ORCL are:
  RMAN configuration has no stored or default parameters
  -> 채널 설정이 아직 없는 기본 상태 확인
*/

/* ------------------------------------------------------------------------------
   5-2. 백업 채널을 +FRA로 변경
   ------------------------------------------------------------------------------ */

/*
[RMAN]
  RMAN> CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '+FRA/%U';
-- [결과]
  new RMAN configuration parameters:
  CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '+FRA/%U';
  new RMAN configuration parameters are successfully stored
  starting full resync of recovery catalog
  full resync complete
  -> 백업 채널 대상이 +FRA로 지정 및 리싱크 완료 확인
*/

/* ------------------------------------------------------------------------------
   5-3. FRA 용량 상한 확인
   ※ 아카이브 로그와 백업이 +FRA를 공유하므로 db_recovery_file_dest_size로
      전체 상한을 잡아 공간을 확보해야 한다. 용량이 부족해지면 RMAN의
      obsolete 정책(CONFIGURE RETENTION POLICY)에 따라 오래된 백업이 정리된다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus]
-- FRA 용량 상한 확인
SHOW PARAMETER db_recovery_file_dest_size;
/* [결과]
   NAME                         TYPE        VALUE
   ---------------------------- ----------- -----
   db_recovery_file_dest_size   big integer 10088M
   -> +FRA 전체 용량 상한 10088M 확인
*/


/* ==============================================================================
   6. 인스턴스 장애 시뮬레이션 — 강제 종료 및 자동 인계 확인
   ==============================================================================
   ※ pmon 프로세스를 강제 종료하면 ORA-00474 에러와 함께 해당 인스턴스가
      즉시 비정상 종료된다 — Clusterware 장애 감지·복구 흐름을 확인하기 위한 시뮬레이션.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   6-1. pmon 프로세스 강제 종료
   ------------------------------------------------------------------------------ */

/*
[oelsvr2 — oracle 계정, OS 터미널]
-- pmon 프로세스 pid 확인
  $ ps -ef | grep pmon_orcl2
-- [결과]
  oracle   25836     1  0 09:13 ?        00:00:00 ora_pmon_orcl2
  -> orcl2 pmon 프로세스 pid 25836 확인

-- 강제 종료로 장애 발생
  $ kill -9 25836
*/

/* ------------------------------------------------------------------------------
   6-2. 양 노드 상태 확인
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — oracle 계정, OS 터미널, 양 노드 상태 확인]
  $ srvctl status database -d orcl
-- [결과]
  Instance orcl1 is running on node oelsvr1
  Instance orcl2 is not running on node oelsvr2
  -> orcl2만 중지된 상태 확인
*/

/* ------------------------------------------------------------------------------
   6-3. 생존 노드 세션 정상 처리 확인
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1, 생존 노드 세션 정상 처리 확인]
SELECT inst_id, status FROM gv$instance;
/* [결과]
   INST_ID STATUS
   ------- ------------
         1 OPEN
   -> orcl1만 OPEN 상태로 서비스 지속 확인
*/

/* ------------------------------------------------------------------------------
   6-4. Clusterware 자동 재기동 확인
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — oracle 계정, OS 터미널, 잠시 후 재확인]
  $ srvctl status database -d orcl
-- [결과]
  Instance orcl1 is running on node oelsvr1
  Instance orcl2 is running on node oelsvr2
  -> AUTOMATIC 정책에 따라 orcl2가 자동 재기동됨 확인
*/


/* ==============================================================================
   7. RAC Instance Recovery 흐름 — GES → GCS → LMS → SMON
   ==============================================================================
   ※ 장애 노드의 Thread Redo만 적용하면 되므로, 인스턴스별 독립 Thread 구조가
      이 복구 범위를 좁히는 핵심 전제가 된다.
   ※ Reconfiguration ~ Instance recovery complete까지가 GES/GCS 레벨에서
      SMON 레벨로 넘어가는 전체 흐름이며, 이 과정에서 생존 노드의 서비스는
      중단되지 않는다.

   단계별 담당 및 역할
   +----------------------------+------------+---------------------------------+
   | 단계                        | 담당       | 역할                              |
   +----------------------------+------------+---------------------------------+
   | GES (Reconfiguration)      | LMON       | 죽은 인스턴스 감지, 재구성 시작, GRD 동결   |
   | GCS (Resource Remastering) | LMS        | 죽은 노드 마스터링 리소스를 생존 노드로 재할당 |
   | Lock 정리                   | LCK0/LMD   | 죽은 인스턴스가 보유하던 Enqueue·Lock 해제 |
   | Redo 복구                   | SMON       | 죽은 인스턴스의 Thread Redo 재적용        |
   +----------------------------+------------+---------------------------------+
   ------------------------------------------------------------------------------ */

/*
[oelsvr1 — orcl1 alert log에서 복구 단계 확인, OS 터미널]
  $ tail -80 $ORACLE_BASE/diag/rdbms/orcl/orcl1/trace/alert_orcl1.log
-- [결과]
  * dead instance detected - domain 0 invalid = TRUE
  Communication channels reestablished
  Master broadcasted resource hash value bitmaps
  Non-local Process blocks cleaned out
  LMS 0: 0 GCS shadows cancelled, 0 closed, 0 Xw survived, skipped 0
  LMS 1: 0 GCS shadows cancelled, 0 closed, 0 Xw survived, skipped 0
  Set master node info
  Dwn-cvts replayed, VALBLKs dubious
  All grantable enqueues granted
  Post SMON to start 1st pass IR
  Reconfiguration complete (total time 0.1 secs)
  Instance recovery: looking for dead threads
  Beginning instance recovery of 1 threads
  parallel recovery started with 3 processes
  Thread 2: Recovery starting at checkpoint rba (logseq 16 block 10928), scn 0
  Started redo scan
  Completed redo scan
  read 326 KB redo, 38 data blocks need recovery
  Started redo application at
  Thread 2: logseq 16, block 10928, offset 0
  Recovery of Online Redo Log: Thread 2 Group 4 Seq 16 Reading mem 0
    Mem# 0: +REDO/ORCL/ONLINELOG/group_4.260.1233770977
    Mem# 1: +FRA/ORCL/ONLINELOG/group_4.260.1233770977
  Completed redo application of 0.14MB
  Completed instance recovery at
  Thread 2: RBA 16.11581.16, nab 11581, scn 0x00000000002cc4cf
  32 data blocks read, 38 data blocks written, 326 redo k-bytes read
  -> GES 재구성 → GCS 리소스 재할당 → SMON Redo 복구까지 전체 흐름 확인
*/


/* ==============================================================================
   8. FAST_START_MTTR_TARGET — 단일 인스턴스 vs RAC
   ==============================================================================
   ※ 인스턴스 장애 후 복구 완료까지 걸리는 목표 시간(초)을 오라클에 지정하는
      파라미터다. 이 값을 기준으로 오라클이 체크포인트 빈도를 자동 조절해
      Redo 적용량을 목표 시간 안에 처리할 수 있도록 유지한다.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   8-1. 현재 상태 확인
   ※ 기본값 0은 비활성 상태 — 오라클이 체크포인트 빈도를 자체적으로 결정하며
      복구 목표 시간을 별도로 제어하지 않는다.
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
-- 현재 fast_start_mttr_target 상태 확인
SHOW PARAMETER fast_start_mttr_target;
/* [결과]
   NAME                       TYPE    VALUE
   -------------------------- ------- ------
   fast_start_mttr_target     integer 0
   -> 기본값 0, 비활성 상태 확인
*/

/* ------------------------------------------------------------------------------
   8-2. 복구 목표 시간 설정
   ------------------------------------------------------------------------------ */

-- 복구 목표 시간 설정 — 양 노드 적용
ALTER SYSTEM SET fast_start_mttr_target=300 SID='*';
/* [결과]
   System altered.
   -> orcl1, orcl2 양 인스턴스 모두 300초로 설정 완료
*/

/* ------------------------------------------------------------------------------
   8-3. 설정 후 예측 조회
   ------------------------------------------------------------------------------ */

-- 설정 후 복구 목표 시간 예측 조회
SELECT target_mttr, estimated_mttr, ckpt_block_writes
FROM   v$instance_recovery;
/* [결과]
   TARGET_MTTR ESTIMATED_MTTR CKPT_BLOCK_WRITES
   ----------- -------------- -----------------
            30              0              1456
   -> 목표 MTTR 및 현재 체크포인트 기록량 확인
*/

/* ------------------------------------------------------------------------------
   8-4. Advisor 예측 조회
   ------------------------------------------------------------------------------ */

-- 예측 조회 — Advisor
SELECT mttr_target_for_estimate, advice_status,
       estd_total_writes, estd_total_write_factor
FROM   v$mttr_target_advice
ORDER BY mttr_target_for_estimate;
/* [결과]
   MTTR_TARGET_FOR_ESTIMATE ADVIC ESTD_TOTAL_WRITES ESTD_TOTAL_WRITE_FACTOR
   ------------------------ ----- ----------------- -----------------------
                          3 ON                   71                       1
                          9 ON                   71                       1
                         16 ON                   71                       1
                         23 ON                   71                       1
                         30 ON                   71                       1
   -> MTTR 목표값별 예상 총 쓰기량 및 배율 확인
*/


/* ==============================================================================
   9. RECOVERY_PARALLELISM — 병렬 복구 프로세스 수
   ==============================================================================
   ※ 기본값 0은 CPU 코어 수 기준으로 오라클이 자동 결정한다는 의미이며,
      명시적으로 값을 지정하면 해당 개수의 병렬 복구 슬레이브가 기동된다.
   ※ alert log의 'SMON: Parallel transaction recovery slaves' 메시지가
      이 파라미터에 의해 기동된 프로세스 수와 직결된다.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   9-1. 현재 값 확인
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
SHOW PARAMETER recovery_parallelism;
/* [결과]
   NAME                    TYPE    VALUE
   ----------------------- ------- ------
   recovery_parallelism    integer 0
   -> 기본값 0, 오라클 자동 결정 상태 확인
*/

/* ------------------------------------------------------------------------------
   9-2. 값 변경
   ------------------------------------------------------------------------------ */

-- 변경 — 병렬 복구 슬레이브 프로세스 수 지정
ALTER SYSTEM SET recovery_parallelism=4 SID='*';
/* [결과]
   System altered.
   -> 병렬 복구 슬레이브 프로세스 수 4로 지정 완료
*/


/* ==============================================================================
   10. Asynchronous I/O · Buffer Cache와 복구 속도
   ==============================================================================
   ※ disk_asynch_io=TRUE이면 체크포인트 기록과 Redo 적용 시 I/O 요청을
      비동기로 처리해 복구 중 디스크 대기 시간이 줄어든다 — 기본값을
      임의로 FALSE로 바꾸지 않는다.
   ※ Buffer Cache가 클수록 Dirty Block이 메모리에 더 오래 머무를 수 있어
      체크포인트 빈도는 감소하지만, 장애 발생 시 적용해야 할 변경분(복구 대상)이
      늘어난다 — MTTR 목표와 Buffer Cache 크기는 함께 고려해야 하는 트레이드오프다.
   ------------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------------
   10-1. disk_asynch_io 확인
   ------------------------------------------------------------------------------ */

-- [oelsvr1 — SQL*Plus, orcl1]
SHOW PARAMETER disk_asynch_io;
/* [결과]
   NAME              TYPE     VALUE
   ----------------- -------- -----
   disk_asynch_io    boolean  TRUE
   -> 비동기 I/O 활성화 상태 확인
*/

/* ------------------------------------------------------------------------------
   10-2. Buffer Cache 크기 확인
   ------------------------------------------------------------------------------ */

-- db_cache_size 파라미터 확인
SHOW PARAMETER db_cache_size;
/* [결과]
   NAME             TYPE         VALUE
   ---------------- ------------ -------
   db_cache_size    big integer  0
   -> db_cache_size=0, AMM/ASMM 방식으로 자동 조절 중임을 의미
*/

-- 실제 DEFAULT buffer cache 크기 조회
SELECT component, current_size/1024/1024 MB
FROM   v$sga_dynamic_components
WHERE  component = 'DEFAULT buffer cache';
/* [결과]
   COMPONENT                MB
   ------------------------ ----
   DEFAULT buffer cache     3664
   -> 자동 조절된 실제 Buffer Cache 크기 3664MB 확인
*/


/* ==============================================================================
   11. 실습 핵심 요약
   ==============================================================================

   주제                        핵심 포인트
   -------------------------  --------------------------------------------------
   Recovery Catalog           RAC와 분리된 별도 DB(2daydba)에 구축,
                               테이블스페이스·계정 생성 -> CREATE CATALOG
                               TABLESPACE -> REGISTER DATABASE 순서 필수
   RAC 백업 인식               한 노드 백업이 공유 컨트롤파일·카탈로그로
                               전 노드에 즉시 반영
   Snapshot Controlfile       SHOW SNAPSHOT CONTROLFILE NAME으로 확인,
                               RAC에서는 반드시 공유 스토리지(+DATA) 경로로 지정
   백업 채널 경로               디스크 여분이 없는 경우 +FRA 통합 운용,
                               db_recovery_file_dest_size로 용량 상한 관리
   인스턴스 장애 시뮬레이션      pmon 강제 종료로 장애 재현, 생존 노드 서비스 지속 및
                               Clusterware 자동 재기동 확인
   Instance Recovery 흐름     GES(LMON) -> GCS(LMS) -> Lock 정리 ->
                               SMON Redo 적용 순서
   FAST_START_MTTR_TARGET     인스턴스 장애 후 복구 목표 시간(초) 지정,
                               기본값 0은 비활성, RAC에서는 인스턴스별 개별 설정
   RECOVERY_PARALLELISM       0은 자동 결정, 명시 설정 시 병렬 복구 슬레이브 수 고정
   Async I/O / Buffer Cache   비동기 I/O는 복구 지연 감소,
                               db_cache_size=0이면 AMM/ASMM이 크기 자동 조절
   ============================================================================== */


/* ==============================================================================
   12. 관련 뷰 & 명령어 정리
   ==============================================================================

   [RMAN 명령]
   명령어                                                            설명
   ---------------------------------------------------------------  ----------------------------
   rman target / catalog <user>/<password>@<CATALOG_TNS>            Target·Catalog 동시 연결
   CREATE CATALOG TABLESPACE <ts>;                                  카탈로그 스키마 생성 (1회)
   REGISTER DATABASE;                                                DB 등록 (1회)
   LIST BACKUP SUMMARY;                                              백업 이력 조회
   LIST INCARNATION;                                                 Incarnation 조회
   SHOW SNAPSHOT CONTROLFILE NAME;                                   Snapshot Controlfile 위치 확인
   CONFIGURE SNAPSHOT CONTROLFILE NAME TO '<공유경로>';               Snapshot Controlfile 위치 변경
   SHOW CHANNEL;                                                     백업 채널 설정 확인
   CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '<디스크그룹>/%U';       백업 채널 디스크 그룹 지정
   BACKUP DATABASE PLUS ARCHIVELOG;                                  전체 백업 + 아카이브 로그 백업

   [OS 명령]
   명령어                                          설명
   ----------------------------------------------  ----------------------------
   srvctl status database -d <db_unique_name>       RAC DB 전체 상태 확인
   ps -ef | grep pmon_<SID>                         pmon 프로세스 pid 확인
   kill -9 <pid>                                    프로세스 강제 종료 (장애 시뮬레이션)
   tail -80 <alert_log_path>                        Alert Log 복구 단계 확인
   tnsping <TNS_ALIAS>                               TNS 접속 확인

   [SQL*Plus 조회 정리]
   -- RAC 전체 인스턴스 상태 조회
   SELECT inst_id, status FROM gv$instance;

   -- 복구 목표 시간 파라미터 확인
   SHOW PARAMETER fast_start_mttr_target;

   -- 복구 목표 시간 예측 조회
   SELECT target_mttr, estimated_mttr, ckpt_block_writes
   FROM   v$instance_recovery;

   -- MTTR Advisor 예측 조회
   SELECT mttr_target_for_estimate, advice_status,
          estd_total_writes, estd_total_write_factor
   FROM   v$mttr_target_advice
   ORDER BY mttr_target_for_estimate;

   -- 병렬 복구 프로세스 수 확인
   SHOW PARAMETER recovery_parallelism;

   -- 비동기 I/O 여부 확인
   SHOW PARAMETER disk_asynch_io;

   -- Buffer Cache 실제 크기 조회
   SELECT component, current_size/1024/1024 MB
   FROM   v$sga_dynamic_components
   WHERE  component = 'DEFAULT buffer cache';
   ============================================================================== */
