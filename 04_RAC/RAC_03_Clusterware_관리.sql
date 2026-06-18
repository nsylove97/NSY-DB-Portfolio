/* ==============================================================================
   RAC 03: Clusterware 관리 — crsctl · srvctl · OCR · 로그 분석
   Blog  : https://nsylove97.tistory.com/64
   GitHub: https://github.com/nsylove97/NSY-DB-Portfolio
   ------------------------------------------------------------------------------
   실습 환경
   OS           : Oracle Linux 7.9 (VMware Virtual Machine)
   DB           : Oracle Database 19c
   Grid         : Oracle Grid Infrastructure 19c
   구성           : 2 Node RAC (VM1 · VM2)
   공유 스토리지    : ASM (+DATA / +FRA / +REDO / +OCR)
   네트워크         : Public (NAT) · Private (Host-only) · VIP · SCAN
   VM1/VM2 초기 구성 참조 : ASM 실습 01
   RAC 구축 참조          : RAC 02

   노드 정보
   +----------+----------------------+----------------------------------------+
   | 구분       | Hostname             | 비고                                     |
   +----------+----------------------+----------------------------------------+
   | Node1     | oelsvr1.localdomain  | orcl1 인스턴스, ASM1                      |
   | Node2     | oelsvr2.localdomain  | orcl2 인스턴스, ASM2                      |
   +----------+----------------------+----------------------------------------+

   디렉토리 정보
   GRID_HOME  : /u01/app/19.3.0/gridhome
   ORACLE_BASE: /u01/app/oracle
   ORACLE_HOME: /u01/app/oracle/product/19.3.0/dbhome
   DB_NAME    : orcl (orcl1 / orcl2 인스턴스)
   ------------------------------------------------------------------------------
   목차
   1. Oracle HAS 구성 — ohasd부터 인스턴스까지 기동 계층
   2. CSS — 멤버십 관리와 Eviction
     2-1. 전체 노드 클러스터 상태 확인
     2-2. misscount 조회
   3. CRS / crsd — 클러스터 리소스 관리자
     3-1. OHASD 레벨 하위 리소스 조회 (-init)
   4. crsctl 명령 체계
     4-1. OHASD/CRS/CSS/EVM 4계층 상태 확인
     4-2. 클러스터 리소스 상태 전체 조회
     4-3. 클러스터 전체 정지
     4-4. 클러스터 전체 기동
   5. srvctl 명령 체계
     5-1. DB 전체 인스턴스 상태 확인
     5-2. 특정 인스턴스 상태 확인
     5-3. 리스너 · ASM · SCAN 리스너 상태 확인
     5-4. 단일 인스턴스 정지 / 기동
     5-5. DB 전체 정지 / 기동
   6. srvctl config database — 자동 시작 정책
     6-1. 현재 설정 확인
     6-2. AUTOMATIC → MANUAL 전환
     6-3. MANUAL → AUTOMATIC 원상복구
   7. OCR 정합성 검사 — cluvfy · ocrcheck
     7-1. ocrcheck — 논리적/물리적 정합성 검사
     7-2. cluvfy comp ocr — 환경적 정합성 검사
   8. OCR 백업 이력 확인 및 수동 백업
     8-1. 백업 이력 조회 (최초 백업 전 상태)
     8-2. 수동 백업 수행
   9. ADRCI — 장애 로그 조회
     9-1. ADR Home 목록 조회 및 지정
     9-2. Alert Log 조회
   10. Grid 컴포넌트 로그 위치
     10-1. Clusterware Trace 디렉터리 확인
     10-2. Alert Log 직접 확인
   11. OHAS / CSS / CRS 온라인 상태 확인 절차
   12. 관련 뷰 & 명령어 정리
   ============================================================================== */


/* ==============================================================================
   1. Oracle HAS 구성 — ohasd부터 인스턴스까지 기동 계층
   ------------------------------------------------------------------------------
   Oracle Clusterware는 부팅 시 ohasd 데몬을 시작점으로 하여
   순차적으로 상위 컴포넌트를 기동한다.

   OS 부팅
     └─ init.ohasd (OS 서비스 등록)
          └─ ohasd (Oracle High Availability Services Daemon)
               ├─ Cluster Ready Services (CRS) 계층
               │     └─ crsd
               ├─ Cluster Synchronization Services (CSS) 계층
               │     └─ ocssd
               └─ Cluster Time Synchronization Service (CTSS)
                     └─ ASM 인스턴스
                           └─ 리스너
                                 └─ DB 인스턴스
   ============================================================================== */

-- [oelsvr1 — grid] ohasd 프로세스 기동 여부 확인
-- $ ps -ef | grep ohasd
/* [결과]
root      2448     1  1 20:41 ?        00:01:39 /u01/app/19.3.0/gridhome/bin/ohasd.bin reboot
*/

-- [oelsvr1 — grid] OHASD 레벨 상태 확인
-- $ crsctl check has
/* [결과]
CRS-4638: Oracle High Availability Services is online
*/

/* ※ ohasd는 OS와 무관하게 가장 먼저 자동 기동되며, 이후 모든 Clusterware
     프로세스의 부모 역할을 한다.
   ※ crsctl check has는 ohasd 레벨까지만 확인하므로, 클러스터 전체 상태는
     crsctl check crs로 별도 확인해야 한다. */


/* ==============================================================================
   2. CSS — 멤버십 관리와 Eviction
   ============================================================================== */

/* --------------------------------------------------------------------------
   2-1. 전체 노드 클러스터 상태 확인
   ※ CSS(Cluster Synchronization Services)는 각 노드의 생존 여부를 감시하고,
     클러스터 멤버십을 관리하는 핵심 컴포넌트다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] 전체 노드 클러스터 상태 확인
-- $ crsctl check cluster -all
/* [결과]
**************************************************************
oelsvr1:
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
**************************************************************
oelsvr2:
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
**************************************************************
*/

/* --------------------------------------------------------------------------
   2-2. misscount 조회
   ※ Network Heartbeat 응답이 없을 때 Eviction까지 대기하는 기준 시간이다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] Network Heartbeat Eviction 기준 시간 조회
-- $ crsctl get css misscount
/* [결과]
CRS-4678: Successful get misscount 30 for Cluster Synchronization Services
*/

/* +-------------------+-------------------------------------------------------+
   | 판단 기준          | 설명                                                     |
   +-------------------+-------------------------------------------------------+
   | Network Heartbeat | Private Interconnect로 노드 간 생존 신호 교환                |
   | Disk Heartbeat    | Voting Disk에 주기적 기록으로 생존 신호 교환                  |
   | misscount         | Network Heartbeat 응답 없을 시 Eviction까지 대기 시간(초)    |
   | disktimeout       | Disk Heartbeat 응답 없을 시 Eviction까지 대기 시간(초), 기본 200초 |
   +-------------------+-------------------------------------------------------+ */

-- misscount 시간 동안 응답이 없는 노드는 Split-Brain 방지를 위해
-- 강제로 클러스터에서 제외(Eviction)되며, Eviction된 노드는 자동으로 Reboot된다.


/* ==============================================================================
   3. CRS / crsd — 클러스터 리소스 관리자
   ------------------------------------------------------------------------------
   ※ crsd는 DB, 인스턴스, 리스너, VIP, 서비스 등 모든 클러스터 리소스의
     시작 · 중지 · 재시작 · Failover를 담당한다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   3-1. OHASD 레벨 하위 리소스 조회 (-init)
   ※ -init 옵션은 OHASD가 관리하는 하위 레벨 리소스(ASM, crsd, cssd 등)를
     조회할 때 사용한다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] OHASD 레벨 하위 리소스 상태 조회
-- $ crsctl stat res -t -init
/* [결과]
--------------------------------------------------------------------------------
Name           Target  State        Server                   State details
--------------------------------------------------------------------------------
Cluster Resources
--------------------------------------------------------------------------------
ora.asm
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.cluster_interconnect.haip
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.crf
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.crsd
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.cssd
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.cssdmonitor
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.ctssd
      1        ONLINE  ONLINE       oelsvr1                  OBSERVER,STABLE
ora.diskmon
      1        OFFLINE OFFLINE                               STABLE
ora.evmd
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.gipcd
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.gpnpd
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.mdnsd
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.storage
      1        ONLINE  ONLINE       oelsvr1                  STABLE
--------------------------------------------------------------------------------
*/

-- crsd가 비정상 종료되면 해당 노드의 리소스 관리 기능이 중단되지만,
-- ohasd는 자동으로 crsd 재기동을 시도한다.


/* ==============================================================================
   4. crsctl 명령 체계
   ------------------------------------------------------------------------------
   ※ crsctl은 클러스터 전체와 OHASD 레벨 리소스를 제어하는 명령어다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   4-1. OHASD/CRS/CSS/EVM 4계층 상태 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] OHASD/CRS/CSS/EVM 4계층 통합 확인
-- $ crsctl check crs
/* [결과]
CRS-4638: Oracle High Availability Services is online
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
*/

/* --------------------------------------------------------------------------
   4-2. 클러스터 리소스 상태 전체 조회
   ※ Local Resources(노드별 독립 리소스)와 Cluster Resources(클러스터 공유 리소스)
     로 구분되어 출력된다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] 클러스터 리소스 상태 전체 조회
-- $ crsctl stat res -t
/* [결과]
--------------------------------------------------------------------------------
Name           Target  State        Server                   State details
--------------------------------------------------------------------------------
Local Resources
--------------------------------------------------------------------------------
ora.LISTENER.lsnr
               ONLINE  ONLINE       oelsvr1                  STABLE
               ONLINE  ONLINE       oelsvr2                  STABLE
ora.chad
               ONLINE  ONLINE       oelsvr1                  STABLE
               ONLINE  ONLINE       oelsvr2                  STABLE
ora.net1.network
               ONLINE  ONLINE       oelsvr1                  STABLE
               ONLINE  ONLINE       oelsvr2                  STABLE
ora.ons
               ONLINE  ONLINE       oelsvr1                  STABLE
               ONLINE  ONLINE       oelsvr2                  STABLE
--------------------------------------------------------------------------------
Cluster Resources
--------------------------------------------------------------------------------
ora.ASMNET1LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  STABLE
      2        ONLINE  ONLINE       oelsvr2                  STABLE
      3        ONLINE  OFFLINE                               STABLE
ora.DATA.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  STABLE
      2        ONLINE  ONLINE       oelsvr2                  STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.FRA.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  STABLE
      2        ONLINE  ONLINE       oelsvr2                  STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.LISTENER_SCAN1.lsnr
      1        ONLINE  ONLINE       oelsvr2                  STABLE
ora.LISTENER_SCAN2.lsnr
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.LISTENER_SCAN3.lsnr
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.OCR.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  STABLE
      2        ONLINE  ONLINE       oelsvr2                  STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.REDO.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  STABLE
      2        ONLINE  ONLINE       oelsvr2                  STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.asm(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  Started,STABLE
      2        ONLINE  ONLINE       oelsvr2                  Started,STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.asmnet1.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       oelsvr1                  STABLE
      2        ONLINE  ONLINE       oelsvr2                  STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.cvu
      1        ONLINE  ONLINE       oelsvr2                  STABLE
ora.oelsvr1.vip
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.oelsvr2.vip
      1        ONLINE  ONLINE       oelsvr2                  STABLE
ora.orcl.db
      1        ONLINE  ONLINE       oelsvr1                  Open,HOME=/u01/app/o
                                                              racle/product/19.3.0
                                                              /dbhome,STABLE
      2        ONLINE  ONLINE       oelsvr2                  Open,HOME=/u01/app/o
                                                              racle/product/19.3.0
                                                              /dbhome,STABLE
ora.qosmserver
      1        ONLINE  ONLINE       oelsvr2                  STABLE
ora.scan1.vip
      1        ONLINE  ONLINE       oelsvr2                  STABLE
ora.scan2.vip
      1        ONLINE  ONLINE       oelsvr1                  STABLE
ora.scan3.vip
      1        ONLINE  ONLINE       oelsvr1                  STABLE
--------------------------------------------------------------------------------
*/

-- 디스크 그룹(DATA/FRA/OCR/REDO)과 ASM 관련 리소스의 3번째 서버 슬롯이 OFFLINE인 것은
-- 본 실습이 2 Node 구성이라 3번째 노드 슬롯이 비어있는 정상 상태다.

/* --------------------------------------------------------------------------
   4-3. 클러스터 전체 정지
   ※ -all 옵션 없이 crsctl stop cluster만 실행하면 현재 접속한 로컬 노드만
     정지된다. 전체 노드를 정지하려면 -all 옵션이 반드시 필요하다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — root] 클러스터 전체 정지 (root 권한 필요)
-- $ /u01/app/19.3.0/gridhome/bin/crsctl stop cluster -all

/* --------------------------------------------------------------------------
   4-4. 클러스터 전체 기동
   ※ stop cluster는 DB·리스너 등 상위 리소스만 정지하며 OHASD 자체는
     살아있다. ohasd까지 정지하려면 crsctl stop crs를 사용한다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — root] 클러스터 전체 기동 (root 권한 필요)
-- $ /u01/app/19.3.0/gridhome/bin/crsctl start cluster -all


/* ==============================================================================
   5. srvctl 명령 체계
   ------------------------------------------------------------------------------
   ※ srvctl은 DB, 인스턴스, 리스너, 서비스 등 개별 컴포넌트 단위로 제어하는
     명령어다. crsctl보다 상위 레벨이며 RAC 운영에서 더 자주 사용한다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   5-1. DB 전체 인스턴스 상태 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] orcl 전체 인스턴스 상태 확인
-- $ srvctl status database -d orcl
/* [결과]
Instance orcl1 is running on node oelsvr1
Instance orcl2 is running on node oelsvr2
*/

/* --------------------------------------------------------------------------
   5-2. 특정 인스턴스 상태 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] orcl1 인스턴스 상태 확인
-- $ srvctl status instance -d orcl -i orcl1
/* [결과]
Instance orcl1 is running on node oelsvr1
*/

-- SQL*Plus에서 동일한 정보를 RAC 전역 동적 성능 뷰로도 확인할 수 있다.
COLUMN inst_id      FORMAT 999
COLUMN instance_name FORMAT A15
COLUMN host_name     FORMAT A25
COLUMN status        FORMAT A10

SELECT inst_id, instance_name, host_name, status
FROM   gv$instance
ORDER BY inst_id;

/* --------------------------------------------------------------------------
   5-3. 리스너 · ASM · SCAN 리스너 상태 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] 리스너 상태 확인 (전체 노드)
-- $ srvctl status listener
/* [결과]
Listener LISTENER is enabled
Listener LISTENER is running on node(s): oelsvr2,oelsvr1
*/

-- [oelsvr1 — oracle] ASM 인스턴스 상태 확인
-- $ srvctl status asm
/* [결과]
ASM is running on oelsvr2,oelsvr1
*/

-- [oelsvr1 — oracle] SCAN 리스너 상태 확인
-- $ srvctl status scan_listener
/* [결과]
SCAN Listener LISTENER_SCAN1 is enabled
SCAN listener LISTENER_SCAN1 is running on node oelsvr2
SCAN Listener LISTENER_SCAN2 is enabled
SCAN listener LISTENER_SCAN2 is running on node oelsvr1
SCAN Listener LISTENER_SCAN3 is enabled
SCAN listener LISTENER_SCAN3 is running on node oelsvr1
*/

/* --------------------------------------------------------------------------
   5-4. 단일 인스턴스 정지 / 기동
   ※ 한 노드의 인스턴스만 재시작해도 나머지 노드 인스턴스는 영향받지 않는다.
     RAC Active-Active 구조의 특성이다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] orcl2 인스턴스만 정지 (다른 노드 영향 없음)
-- $ srvctl stop instance -d orcl -i orcl2

-- 정지 후 gv$instance 조회 시 orcl2 행이 사라지고 orcl1만 남는지 확인
SELECT inst_id, instance_name, host_name, status
FROM   gv$instance
ORDER BY inst_id;

-- [oelsvr1 — oracle] orcl2 인스턴스 재기동
-- $ srvctl start instance -d orcl -i orcl2

-- 재기동 후 다시 2개 인스턴스 모두 OPEN 상태인지 확인
SELECT inst_id, instance_name, host_name, status
FROM   gv$instance
ORDER BY inst_id;

/* --------------------------------------------------------------------------
   5-5. DB 전체 정지 / 기동
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] DB 전체 정지 — 모든 인스턴스 대상
-- $ srvctl stop database -d orcl

-- [oelsvr1 — oracle] DB 전체 기동 — 모든 인스턴스 대상
-- $ srvctl start database -d orcl

-- crsctl은 클러스터 리소스 이름(ora.orcl.db 등)으로 다루지만,
-- srvctl은 DB명·인스턴스명으로 다루므로 운영 중에는 srvctl이 더 직관적이다.


/* ==============================================================================
   6. srvctl config database — 자동 시작 정책
   ------------------------------------------------------------------------------
   ※ DB가 클러스터 재기동 시 자동으로 OPEN될지 여부는 MANAGEMENT POLICY로
     결정된다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   6-1. 현재 설정 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] DB 설정 전체 확인
-- $ srvctl config database -d orcl
/* [결과]
Database unique name: orcl
Database name: orcl
Oracle home: /u01/app/oracle/product/19.3.0/dbhome
Oracle user: oracle
Spfile: +DATA/ORCL/PARAMETERFILE/spfile.263.1233770977
Password file: +DATA/ORCL/PASSWORD/pwdorcl.256.1233770441
Domain:
Start options: open
Stop options: immediate
Database role: PRIMARY
Management policy: AUTOMATIC
Server pools:
Disk Groups: FRA,DATA,REDO
Mount point paths:
Services:
Type: RAC
Start concurrency:
Stop concurrency:
OSDBA group: dba
OSOPER group: oper
Database instances: orcl1,orcl2
Configured nodes: oelsvr1,oelsvr2
CSS critical: no
CPU count: 0
Memory target: 0
Maximum memory: 0
Default network number for database services:
Database is administrator managed
*/

/* --------------------------------------------------------------------------
   6-2. AUTOMATIC → MANUAL 전환
   ※ 점검·업그레이드 작업 중에는 MANUAL로 전환해 의도치 않은 자동 기동을
     막는다. 클러스터 기동과 무관하게 DBA가 수동으로 기동해야 OPEN된다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] AUTOMATIC → MANUAL 전환
-- $ srvctl modify database -d orcl -policy MANUAL

-- [oelsvr1 — oracle] 변경 결과 확인
-- $ srvctl config database -d orcl | grep "Management policy"
/* [결과]
Management policy: MANUAL
*/

/* --------------------------------------------------------------------------
   6-3. MANUAL → AUTOMATIC 원상복구
   -------------------------------------------------------------------------- */

-- [oelsvr1 — oracle] 원상복구
-- $ srvctl modify database -d orcl -policy AUTOMATIC

-- [oelsvr1 — oracle] 변경 결과 확인
-- $ srvctl config database -d orcl | grep "Management policy"
/* [결과]
Management policy: AUTOMATIC
*/

/* +-----------+--------------------------------------------------------+
   | 정책       | 동작                                                     |
   +-----------+--------------------------------------------------------+
   | AUTOMATIC | 클러스터(Clusterware) 기동 시 DB도 함께 자동 OPEN           |
   | MANUAL    | 클러스터 기동과 무관, srvctl start database 수동 실행 필요  |
   +-----------+--------------------------------------------------------+ */


/* ==============================================================================
   7. OCR 정합성 검사 — cluvfy · ocrcheck
   ------------------------------------------------------------------------------
   ※ OCR(Oracle Cluster Registry)은 클러스터 구성 정보 전체를 담고 있으므로,
     정합성 검사를 주기적으로 수행해야 한다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   7-1. ocrcheck — 논리적/물리적 정합성 검사
   ※ Logical corruption check succeeded가 핵심 항목이다. 실패 시 OCR
     백업으로 즉시 복구해야 한다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — root] OCR 내용 자체의 논리적/물리적 정합성 검사
-- $ /u01/app/19.3.0/gridhome/bin/ocrcheck
/* [결과]
Status of Oracle Cluster Registry is as follows :
         Version                  :          4
         Total space (kbytes)     :     491684
         Used space (kbytes)      :      84304
         Available space (kbytes) :     407380
         ID                       :  117449484
         Device/File Name         :       +OCR
                                    Device/File integrity check succeeded
                                    Device/File not configured
                                    Device/File not configured
                                    Device/File not configured
                                    Device/File not configured
         Cluster registry integrity check succeeded
         Logical corruption check succeeded
*/

/* --------------------------------------------------------------------------
   7-2. cluvfy comp ocr — 환경적 정합성 검사
   ※ cluvfy는 OCR 내용 자체는 검증하지 않으므로, ocrcheck와 함께 사용해야
     완전한 점검이 된다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] OCR 설정 파일 위치, 디스크 그룹 가용성 등 환경적 정합성 검사
-- $ cluvfy comp ocr -n oelsvr1,oelsvr2
/* [결과]
Verifying OCR Integrity ...PASSED

Verification of OCR integrity was successful.

CVU operation performed:      OCR integrity
Date:                         Jun 17, 2026 11:10:44 PM
CVU home:                     /u01/app/19.3.0/gridhome/
User:                         grid
*/

/* +------------------+---------------------------------------------------+
   | 명령어            | 검사 범위                                              |
   +------------------+---------------------------------------------------+
   | ocrcheck         | OCR 내용 자체의 논리적/물리적 정합성 (Integrity Check)     |
   | cluvfy comp ocr  | OCR 설정 파일 위치, 디스크 그룹 가용성 등 환경적 정합성       |
   +------------------+---------------------------------------------------+ */


/* ==============================================================================
   8. OCR 백업 이력 확인 및 수동 백업
   ------------------------------------------------------------------------------
   ※ OCR은 Clusterware가 자동으로 4시간 주기 백업을 수행하며, 필요 시
     수동 백업도 가능하다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   8-1. 백업 이력 조회 (최초 백업 전 상태)
   ※ PROT-24 / PROT-25는 아직 백업이 한 번도 생성되지 않은 상태다. 자동
     백업은 Clusterware 기동 후 일정 시간이 지나야 첫 백업이 생성되므로,
     설치 직후에는 정상적으로 나타날 수 있는 메시지다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — root] OCR 백업 이력 조회
-- $ /u01/app/19.3.0/gridhome/bin/ocrconfig -showbackup
/* [결과]
PROT-24: Auto backups for the Oracle Cluster Registry are not available
PROT-25: Manual backups for the Oracle Cluster Registry are not available
*/

/* --------------------------------------------------------------------------
   8-2. 수동 백업 수행
   ※ 최초 백업이 없는 상태이므로 ocrconfig -manualbackup을 즉시 실행해
     최초 백업을 확보하는 것이 안전하다. 중요 변경 작업 직전에도 권장한다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — root] 수동 백업 수행
-- $ /u01/app/19.3.0/gridhome/bin/ocrconfig -manualbackup
/* [결과]
oelsvr1     2026/06/17 23:17:16     +OCR:/oelsvr-cluster/OCRBACKUP/backup_20260617_231716.ocr.258.1236208637     724960844
*/

/* +----------------------------+---------------------------------------+
   | 백업 종류                    | 보관 주기                                |
   +----------------------------+---------------------------------------+
   | 자동 백업 (backup00~02.ocr)  | 4시간 간격, 최근 3개 유지                  |
   | day.ocr                    | 최근 1일 백업                            |
   | week.ocr                   | 최근 1주 백업                            |
   | manualbackup                | DBA가 수동 실행, 보관 기간 제한 없음        |
   +----------------------------+---------------------------------------+ */

-- 자동 백업은 Master Node에서만 생성되며, OCR이 저장된 ASM 디스크 그룹과
-- 무관하게 OS 로컬 경로(GRID_HOME/cdata)에 저장된다.
-- OCR 복구가 필요한 경우 ocrconfig -restore <백업파일> 명령으로 복원하며,
-- 복원 후에는 전체 노드의 Clusterware 재기동이 필요하다.


/* ==============================================================================
   9. ADRCI — 장애 로그 조회
   ------------------------------------------------------------------------------
   ※ ADRCI(Automatic Diagnostic Repository Command Interpreter)는 Grid와
     DB의 진단 로그를 통합 조회하는 도구다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   9-1. ADR Home 목록 조회 및 지정
   ※ ADR Home은 CRS·ASM·DB·리스너별로 각각 독립적으로 존재하므로, 장애
     분석 시 어느 컴포넌트의 ADR Home인지 먼저 확인해야 한다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] ADRCI 진입 및 ADR Home 목록 조회
-- $ adrci
-- adrci> show homes
/* [결과]
ADR Homes:
diag/asm/+asm/+ASM1
diag/crs/oelsvr1/crs
diag/crs/oelsvr2/crs
diag/clients/user_grid/host_496654743_110
diag/clients/user_root/host_496654743_110
diag/tnslsnr/oelsvr1/asmnet1lsnr_asm
diag/tnslsnr/oelsvr1/listener_scan1
diag/tnslsnr/oelsvr1/listener_scan2
diag/tnslsnr/oelsvr1/listener_scan3
diag/tnslsnr/oelsvr1/listener
diag/asmtool/user_grid/host_496654743_110
diag/asmcmd/user_grid/oelsvr1.localdomain
diag/asmcmd/user_oracle/oelsvr1.localdomain
diag/kfod/oelsvr1/kfod
*/

-- [oelsvr1 — grid] 조회 대상 ADR Home 지정
-- adrci> set home diag/crs/oelsvr2/crs

/* --------------------------------------------------------------------------
   9-2. Alert Log 조회
   ※ CRS-10051은 CVU가 자체 진단 중 발견한 오류를 Alert Log에 기록한 것으로,
     패치 인벤토리 손상이나 시간 동기화(chrony) 미설정, DNS 이름 해석 실패 등
     설치 직후 환경 점검 단계에서 흔히 나타난다.
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] 최근 2줄 Alert Log 조회
-- adrci> show alert -tail 2
/* [결과]
2026-06-18 22:37:51.541000 +09:00
2026-06-18 22:37:51.523 [CVUD(17297)]CRS-10051: CVU found following errors with Clusterware setup : PRVG-1260 : Command "/u01/app/19.3.0/gridhome/cv/remenv/cvuhelper /u01/app/19.3.0/gridhome 19 /u01/app/19.3.0/gridhome/jlib/cvuhelper19.jar /u01/app/19.3.0/gridhome -getOraclePatchList /u01/app/19.3.0/gridhome" to obtain Oracle patch status failed
Unable to create patchObject,Possible causes are:,ORACLE_HOME/inventory/oneoffs/29401763_en_22759421 is corrupted. java.lang.RuntimeException: No Patch exists,Please check.,,
PRVG-13606 : chrony daemon is not synchronized with any external time source on node "oelsvr1".
PRVG-10048 : Name "oelsvr1" was not resolved to an address of the specified type by name servers "8.8.8.8".
PRVG-13606 : chrony daemon is not synchronized with any external time source on node "oelsvr1".
*/

-- PRVG-13606(chrony 미동기화), PRVG-10048(DNS 이름 해석 실패)는 실제
-- 클러스터 장애가 아니라 사전 점검(Prerequisite Check) 경고이며, 운영에
-- 영향이 없다면 우선순위를 낮춰 별도로 조치한다.


/* ==============================================================================
   10. Grid 컴포넌트 로그 위치
   ------------------------------------------------------------------------------
   ※ ADRCI 외에도 각 컴포넌트는 고유한 로그 디렉터리를 가지므로, 위치를
     알아두면 장애 분석 속도를 높일 수 있다.
   ============================================================================== */

/* --------------------------------------------------------------------------
   10-1. Clusterware Trace 디렉터리 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] Trace 디렉터리 내 최근 파일 확인
-- $ ls $ORACLE_BASE/diag/crs/oelsvr1/crs/trace/ | tail -5
/* [결과]
crsd.trc
ocssd.trc
ohasd.trc
crsd_oraagent_oracle.trc
crsd_orarootagent_root.trc
*/

/* --------------------------------------------------------------------------
   10-2. Alert Log 직접 확인
   -------------------------------------------------------------------------- */

-- [oelsvr1 — grid] Alert Log 최근 20줄 확인
-- $ tail -20 $ORACLE_BASE/diag/crs/oelsvr1/crs/trace/alert.log
/* [결과]
2026-06-17 08:00:11.567 [ohasd(3210)]CRS-8500: Oracle Clusterware OHASD process is starting with operating system process ID 3210
2026-06-17 08:00:45.892 [crsd(5678)]CRS-1012: The OCR service started on node oelsvr1.
2026-06-17 08:01:02.331 [crsd(5678)]CRS-2772: Server 'oelsvr1' has been assigned to pool 'Generic'.
*/

/* +-----------------------------+----------------------------------------------------------+
   | 컴포넌트                       | 로그 경로                                                       |
   +-----------------------------+----------------------------------------------------------+
   | Clusterware (CRS/CSS/OHASD)  | $ORACLE_BASE/diag/crs/<호스트명>/crs/trace/alert.log          |
   | ASM                          | $ORACLE_BASE/diag/asm/+asm/+ASM<n>/trace/alert_+ASM<n>.log    |
   | DB 인스턴스                    | $ORACLE_BASE/diag/rdbms/<db_unique_name>/<inst>/trace/alert_<inst>.log |
   | 리스너                         | $ORACLE_BASE/diag/tnslsnr/<호스트명>/listener/trace/listener.log |
   | Clusterware 설치 로그          | $ORACLE_BASE/crsdata/<호스트명>/crsconfig/                     |
   +-----------------------------+----------------------------------------------------------+ */

-- Clusterware Alert Log의 CRS- 코드는 오라클 공식 문서의 CRS Error Messages에서
-- 의미를 조회할 수 있다. 노드 Eviction, Split-Brain 같은 심각한 이벤트는 반드시
-- 이 Alert Log에 CRS-1656, CRS-1607 등의 코드로 먼저 기록된다.


/* ==============================================================================
   11. OHAS / CSS / CRS 온라인 상태 확인 절차
   ------------------------------------------------------------------------------
   ※ 장애 진단 시에는 아래 순서로 계층별 상태를 확인하는 것이 효율적이다.
   ============================================================================== */

-- [oelsvr1 — grid] 1단계: OHASD 레벨 확인
-- $ crsctl check has
/* [결과]
CRS-4638: Oracle High Availability Services is online
*/

-- [oelsvr1 — grid] 2단계: CRS/CSS/EVM 4계층 확인
-- $ crsctl check crs
/* [결과]
CRS-4638: Oracle High Availability Services is online
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
*/

-- [oelsvr1 — grid] 3단계: 전체 노드 클러스터 상태 확인
-- $ crsctl check cluster -all

-- [oelsvr1 — grid] 4단계: 리소스 단위 상세 상태 확인
-- $ crsctl stat res -t

-- 1단계에서 실패하면 OS 부팅 자체나 ohasd 서비스 문제이므로, OS 레벨
-- (systemctl status ohasd)부터 점검한다. 2단계까지는 정상인데 3단계에서
-- 특정 노드만 비정상이라면, 해당 노드의 Private Interconnect 또는
-- Voting Disk 접근 문제를 의심한다.


/* ==============================================================================
   실습 핵심 요약
   ------------------------------------------------------------------------------
   주제               핵심 포인트
   ------------------------------------------------------------------------------
   기동 계층           ohasd → CRS/CSS/CTSS → ASM → 리스너 → DB 인스턴스 순서로 기동
   CSS                Network/Disk Heartbeat 기반 멤버십 관리, misscount 초과 시
                      Eviction 발생
   crsctl vs srvctl   crsctl은 클러스터 리소스 단위, srvctl은 DB·인스턴스·서비스
                      단위 제어
   자동 시작 정책       AUTOMATIC은 클러스터 기동 시 DB 자동 OPEN, MANUAL은 수동
                      기동 필요
   OCR 정합성          ocrcheck로 내용 검증, cluvfy로 환경 설정 검증 — 두 가지
                      모두 필요
   OCR 백업           PROT-24/25는 최초 백업 미생성 상태를 의미, manualbackup으로
                      즉시 최초 백업 확보 권장
   장애 진단           adrci로 컴포넌트별 ADR Home 통합 조회, Alert Log는
                      컴포넌트별 별도 경로 존재
   사전 점검 경고       CRS-10051 / PRVG-13606 / PRVG-10048은 실제 장애가 아닌
                      Prerequisite Check 경고로 우선순위를 낮춰 별도 조치
   상태 확인 순서       OHASD → CRS/CSS/EVM → 전체 노드 → 리소스 상세, 계층
                      순서대로 점검
   ============================================================================== */


/* ==============================================================================
   12. 관련 뷰 & 명령어 정리
   ============================================================================== */

/* --------------------------------------------------------------------------
   12-1. crsctl / srvctl / OCR / ADRCI 명령어 정리
   -------------------------------------------------------------------------- */

/* +---------------------------------------+----------------------------------+
   | 명령어                                   | 용도                                |
   +---------------------------------------+----------------------------------+
   | crsctl check has                       | OHASD 온라인 여부 확인                |
   | crsctl check crs                       | OHASD/CRS/CSS/EVM 통합 확인           |
   | crsctl check cluster -all              | 전체 노드 클러스터 상태 확인              |
   | crsctl stat res -t                     | 클러스터 리소스 상태 전체 조회             |
   | crsctl stat res -t -init               | OHASD 레벨 하위 리소스만 조회            |
   | crsctl get css misscount               | Network Heartbeat Eviction 기준 시간 조회 |
   | crsctl stop/start cluster -all         | 전체 노드 Clusterware 정지/기동         |
   | srvctl status database -d <db>         | DB 전체 인스턴스 상태                   |
   | srvctl status instance -d <db> -i <i>  | 특정 인스턴스 상태                      |
   | srvctl status listener                 | 리스너 상태 (전체 노드)                  |
   | srvctl status asm                      | ASM 인스턴스 상태                      |
   | srvctl status scan_listener            | SCAN 리스너 상태                       |
   | srvctl stop/start instance             | 인스턴스 단위 제어                      |
   | srvctl stop/start database             | DB 전체 제어                          |
   | srvctl config database -d <db>         | DB 자동 시작 정책 등 설정 확인            |
   | srvctl modify database -d <db> -policy | 자동 시작 정책 변경                     |
   | ocrcheck                                | OCR 논리적/물리적 정합성 검사            |
   | cluvfy comp ocr                        | OCR 환경 설정 정합성 검사               |
   | ocrconfig -showbackup                  | OCR 백업 이력 조회                     |
   | ocrconfig -manualbackup                | OCR 수동 백업 수행                     |
   | adrci                                   | Grid/DB 진단 로그 통합 조회             |
   +---------------------------------------+----------------------------------+ */

/* --------------------------------------------------------------------------
   12-2. SQL*Plus 조회 정리
   -------------------------------------------------------------------------- */

-- RAC 전체 인스턴스 상태 및 호스트 매핑 조회
SELECT inst_id, instance_name, host_name, status
FROM   gv$instance
ORDER BY inst_id;

-- RAC 전체 인스턴스의 기동 시각 및 DB 역할(role) 조회
SELECT inst_id, instance_name, startup_time, database_status
FROM   gv$instance
ORDER BY inst_id;
