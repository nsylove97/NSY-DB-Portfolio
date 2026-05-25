/* ==============================================================================
   RAC 02: 2 Node RAC 구축 — VM 환경 준비 & Grid 설치
   Blog  : https://nsylove97.tistory.com/55
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
   +----------+----------------------+-------------------+------------------+
   | 구분       | Hostname             | Public IP         | Private IP       |
   +----------+----------------------+-------------------+------------------+
   | VM1       | oelsvr1.localdomain  | 192.168.111.50    | 10.10.10.1       |
   | VM2       | oelsvr2.localdomain  | 192.168.111.51    | 10.10.10.2       |
   | VIP (VM1) | oelsvr1-vip          | 192.168.111.52    |                  |
   | VIP (VM2) | oelsvr2-vip          | 192.168.111.53    |                  |
   | SCAN 1    | oelsvr-scan          | 192.168.111.55    |                  |
   | SCAN 2    | oelsvr-scan          | 192.168.111.56    |                  |
   | SCAN 3    | oelsvr-scan          | 192.168.111.57    |                  |
   +----------+----------------------+-------------------+------------------+

   디렉토리 정보
   GRID_HOME  : /u01/app/19.3.0/grid
   ORACLE_BASE: /u01/app/oracle
   ORACLE_HOME: /u01/app/oracle/product/19.3.0/dbhome
   INVENTORY  : /u01/app/oraInventory

   ASM 디스크 그룹 설계
   +OCR  : OCR1  / OCR2  / OCR3  — NORMAL Redundancy (Voting Disk · OCR 배치)
   +DATA : DATA1 / DATA2 / DATA3 / DATA4 — NORMAL Redundancy
   +FRA  : FRA1  / FRA2            — NORMAL Redundancy
   +REDO : REDO1 / REDO2           — NORMAL Redundancy
   ------------------------------------------------------------------------------
   목차
   1. 사전 준비 — VM1 스냅샷 복구
   2. VM1 · VM2 호스트명 / IP 설정 확인
     2-1. VM1 호스트명 · IP 확인
     2-2. VM2 호스트명 · IP 수정
   3. /etc/hosts 동기화 확인
   4. Private Interconnect (NIC 2) 활성화 및 통신 확인
     4-1. VM1 Private NIC (ens37) 설정
     4-2. VM2 Private NIC (ens37) 설정
     4-3. 양 노드 간 ping 확인
   5. VMX 설정 확인
     5-1. VMX 파라미터 설정
     5-2. ASM 디스크 Disk Mode 설정 (Independent - Persistent)
   6. ASM 공유 디스크 연결 확인 — VM2에서 oracleasm scandisks
   7. gridSetup.sh (Cluster 모드) — 2 Node RAC Grid Infrastructure 설치
   8. 클러스터 리소스 상태 확인 — crsctl stat res -t
     8-1. 전체 리소스 상태 확인
     8-2. OCR · Voting Disk 배치 확인
   9. ASMCA 실행 — 디스크 그룹 DATA, FRA, REDO 생성
   10. DB 소프트웨어 설치 — runInstaller
     10-1. runInstaller 실행
     10-2. Prerequisite Check 오류 처리
     10-3. SELinux 오류 해결 및 재설치 절차
   11. RAC DB 생성 — dbca
   12. 설치 결과 확인
   13. 주요 명령어 레퍼런스
   14. 실습 핵심 요약
   ==============================================================================
*/


/* ==============================================================================
   1. 사전 준비 — VM1 스냅샷 복구
   ==============================================================================
   RAC 구축은 기존에 구성된 Standalone Grid / Data Guard 환경과 별도로 진행한다.
   VM1을 스냅샷으로 깨끗한 초기 상태로 되돌린 후 시작한다.
   VM2는 ASM 실습 01에서 VM1의 Clone으로 만들어 둔 VM 그대로 사용한다.
   VM3(Data Guard Standby용)는 이번 실습과 무관하므로 종료 상태를 유지한다.
*/

/*
[VMware — 스냅샷 복구 절차]
  VMware Workstation → VM1 → VM → Snapshot → Snapshot Manager
  "ASM 설치 직후" 스냅샷 선택 → [Go To] 클릭 → Yes 선택

[VM1 기동 후 상태 확인 — VM1, OS 터미널]
  $ hostname
  oelsvr1.localdomain

  $ ip addr show ens33 | grep inet
  inet 192.168.111.50/24
  → 호스트명 oelsvr1, Public IP 192.168.111.50 확인
*/


/* ==============================================================================
   2. VM1 · VM2 호스트명 / IP 설정 확인
   ==============================================================================
*/

/* ------------------------------------------------------------------------------
   2-1. VM1 호스트명 · IP 확인
   ※ VM1은 스냅샷 복구 후 이미 정상 상태이므로 확인만 한다.
*/

/*
[VM1 — OS 터미널]
  $ hostname
  oelsvr1.localdomain

  $ ip addr show ens33 | grep inet
  inet 192.168.111.50/24
  → 정상 확인 시 변경 불필요
*/

/* ------------------------------------------------------------------------------
   2-2. VM2 호스트명 · IP 수정
   ※ VM2는 VM1의 Clone이므로 기동 직후 호스트명과 IP가 VM1과 동일하다.
   ※ RAC 설치 전 반드시 VM2의 호스트명을 oelsvr2, IP를 .51로 변경해야 한다.
   ※ 변경 후 재로그인해야 프롬프트에 새 호스트명이 반영된다.
*/

/*
[VM2 — root, OS 터미널]
-- 기동 직후 상태 확인
  $ hostname
  oelsvr1.localdomain    ← VM1과 동일 → 변경 필요

  $ ip addr show ens33 | grep inet
  inet 192.168.111.50/24 ← VM1과 동일 → 변경 필요

-- 호스트명 변경
  $ hostnamectl set-hostname oelsvr2

-- IP 변경 (vi에서 IPADDR 값을 .50 → .51로 수정)
  $ vi /etc/sysconfig/network-scripts/ifcfg-ens33
  IPADDR=192.168.111.51

-- 네트워크 재시작 후 확인
  $ systemctl restart network

  $ hostname
  oelsvr2

  $ ip addr show ens33 | grep inet
  inet 192.168.111.51/24
  → 호스트명 oelsvr2, IP 192.168.111.51 변경 완료
*/


/* ==============================================================================
   3. /etc/hosts 동기화 확인
   ==============================================================================
   ※ 양 노드의 /etc/hosts가 Public · VIP · Private · SCAN 대역 모두 동일해야 한다.
   ※ SCAN IP는 동일한 호스트명(oelsvr-scan)으로 3개 등록한다. (DNS 없는 실습 환경 기준)
   ※ VM1에서 작성 후 scp로 VM2에 복사하면 편리하다.
*/

/*
[VM1 · VM2 공통 — OS 터미널]
  $ cat /etc/hosts

-- [결과 — VM1 · VM2 동일해야 함]
  127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
  ::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

  # Public
  192.168.111.50 oelsvr1 oelsvr1.localdomain
  192.168.111.51 oelsvr2 oelsvr2.localdomain

  # VIP
  192.168.111.52 oelsvr1-vip
  192.168.111.53 oelsvr2-vip

  # Private
  10.10.10.1 oelsvr1-priv
  10.10.10.2 oelsvr2-priv

  # SCAN
  192.168.111.55 oelsvr-scan
  192.168.111.56 oelsvr-scan
  192.168.111.57 oelsvr-scan
  → Public · VIP · Private · SCAN 대역 모두 일치 확인

-- VM2에 동일하게 복사 (VM1에서 실행)
  $ scp /etc/hosts root@oelsvr2:/etc/hosts
*/


/* ==============================================================================
   4. Private Interconnect (NIC 2) 활성화 및 통신 확인
   ==============================================================================
*/

/* ------------------------------------------------------------------------------
   4-1. VM1 Private NIC (ens37) 설정
   ※ Private NIC는 Cache Fusion · GCS/GES 노드 간 통신에 사용한다.
   ※ ifcfg-ens37 파일이 없는 경우 새로 생성한다.
   ※ ONBOOT=yes 누락 시 재부팅 후 NIC가 down 상태가 되므로 반드시 설정한다.
*/

/*
[VM1 — root, OS 터미널]
-- Private NIC 인터페이스 이름 확인
  $ ip link
-- [결과]
  1: lo
  2: ens33
  3: ens37
  → Private NIC 이름: ens37

-- ifcfg-ens37 신규 생성
  $ vi /etc/sysconfig/network-scripts/ifcfg-ens37
  TYPE=Ethernet
  BOOTPROTO=none
  NAME=ens37
  DEVICE=ens37
  IPADDR=10.10.10.1
  PREFIX=24
  ONBOOT=yes

-- 네트워크 재시작 후 확인
  $ systemctl restart network

  $ ip addr show ens37 | grep inet
  inet 10.10.10.1/24
  → VM1 Private IP 10.10.10.1 활성화 확인
*/

/* ------------------------------------------------------------------------------
   4-2. VM2 Private NIC (ens37) 설정
   ※ VM1과 동일한 절차이며 IPADDR만 10.10.10.2로 다르게 설정한다.
*/

/*
[VM2 — root, OS 터미널]
  $ vi /etc/sysconfig/network-scripts/ifcfg-ens37
  TYPE=Ethernet
  BOOTPROTO=none
  NAME=ens37
  DEVICE=ens37
  IPADDR=10.10.10.2
  PREFIX=24
  ONBOOT=yes

  $ systemctl restart network

  $ ip addr show ens37 | grep inet
  inet 10.10.10.2/24
  → VM2 Private IP 10.10.10.2 활성화 확인
*/

/* ------------------------------------------------------------------------------
   4-3. 양 노드 간 ping 확인
   ※ ping 실패 시 VMware 어댑터가 Host-only로 설정되어 있는지 확인한다.
*/

/*
[VM1 — OS 터미널]
  $ ping -c 3 10.10.10.2
-- [결과]
  64 bytes from 10.10.10.2: icmp_seq=1 ttl=64 time=0.412 ms
  64 bytes from 10.10.10.2: icmp_seq=2 ttl=64 time=0.387 ms
  64 bytes from 10.10.10.2: icmp_seq=3 ttl=64 time=0.401 ms
  → VM2 Private IP ping 성공

[VM2 — OS 터미널]
  $ ping -c 3 10.10.10.1
-- [결과]
  64 bytes from 10.10.10.1: icmp_seq=1 ttl=64 time=0.389 ms
  → VM1 Private IP ping 성공
*/


/* ==============================================================================
   5. VMX 설정 확인
   ==============================================================================
*/

/* ------------------------------------------------------------------------------
   5-1. VMX 파라미터 설정
   ※ 공유 ASM 디스크를 양 노드에서 동시에 사용하려면 VMX 파일에 다음 설정이 필요하다.
   ※ VM 전원이 꺼진 상태에서 .vmx 파일을 텍스트 에디터로 직접 열어 확인·수정한다.
   ※ VM1.vmx · VM2.vmx 양쪽 모두 동일하게 설정해야 한다.
   ※ scsi1은 ASM 디스크가 연결된 SCSI 컨트롤러 번호에 맞게 지정한다.
*/

/*
[VMware Host — VM1.vmx · VM2.vmx 파일 직접 편집]

  +--------------------------------------+-----------+-----------------------------------------------+
  | 항목                                  | 값         | 목적                                           |
  +--------------------------------------+-----------+-----------------------------------------------+
  | disk.locking                         | FALSE     | VMware 디스크 잠금 비활성화 → 복수 VM 동시 접근 허용      |
  | disk.EnableUUID                      | TRUE      | 고정 UUID 부여 → oracleasm이 디스크를 안정적으로 인식    |
  | diskLib.dataCacheMaxSize             | 0         | 디스크 캐시 비활성화 → 데이터 동기화 꼬임 방지              |
  | diskLib.dataCacheMaxReadAheadSize    | 0         | 미리 읽기 캐시 비활성화 → 캐시 완전 비활성화 세트 설정        |
  | scsi1.sharedBus                      | virtual   | ASM 디스크 연결 SCSI 컨트롤러를 공유 모드로 설정          |
  +--------------------------------------+-----------+-----------------------------------------------+

  disk.locking = "FALSE"
  disk.EnableUUID = "TRUE"
  diskLib.dataCacheMaxSize = "0"
  diskLib.dataCacheMaxReadAheadSize = "0"
  scsi1.sharedBus = "virtual"
*/

/* ------------------------------------------------------------------------------
   5-2. ASM 디스크 Disk Mode 설정 (Independent - Persistent)
   ※ Independent - Persistent로 설정하면 스냅샷 촬영 시 ASM 디스크가 제외된다.
   ※ 이 설정 생략 시 스냅샷에 ASM 디스크가 포함되어 데이터 불일치 또는
      -000001.vmdk 형태의 파일 분리가 발생할 수 있다.
   ※ VM1 · VM2의 모든 ASM 디스크(OCR1~3 / DATA1~4 / FRA1~2 / REDO1~2)에 적용한다.
*/

/*
[VMware — VM Settings]
  각 VM의 Edit Settings → Hard Disk(ASM 디스크 11개 각각) →
  Disk Mode → Independent → Persistent 선택
*/


/* ==============================================================================
   6. ASM 공유 디스크 연결 확인 — VM2에서 oracleasm scandisks
   ==============================================================================
   ※ VM1에서 oracleasm createdisk로 레이블링한 디스크는 VM2에서 scandisks만
      실행하면 자동으로 인식된다. VM2에서 createdisk를 다시 실행하지 않는다.
   ※ 디스크가 인식되지 않으면 VMware 설정에서 해당 .vmdk가 VM2에 실제로
      연결되어 있는지 확인한다.
*/

/*
[VM2 — root, OS 터미널]
-- ASMLib 서비스 기동 및 자동 시작 등록
  $ systemctl start oracleasm
  $ systemctl enable oracleasm

-- 공유 디스크 스캔
  $ oracleasm scandisks
-- [결과]
  Reloading disk partitions: done
  Cleaning any stale ASM disks...
  Scanning system for ASM disks...

-- 인식된 디스크 목록 확인
  $ oracleasm listdisks
-- [결과]
  DATA1
  DATA2
  DATA3
  DATA4
  FRA1
  FRA2
  OCR1
  OCR2
  OCR3
  REDO1
  REDO2

[VM1 — 비교 확인]
  $ oracleasm listdisks
-- [결과]
  DATA1 DATA2 DATA3 DATA4 FRA1 FRA2 OCR1 OCR2 OCR3 REDO1 REDO2
  → VM1 · VM2 목록이 동일해야 함
*/


/* ==============================================================================
   7. gridSetup.sh (Cluster 모드) — 2 Node RAC Grid Infrastructure 설치
   ==============================================================================
   ※ Grid Infrastructure를 Cluster 모드로 설치한다.
      Standalone(Oracle Restart) 모드와 달리 CRS 데몬 기반으로 동작하며
      Voting Disk · OCR · VIP · SCAN 리소스가 자동 구성된다.
   ※ 설치는 VM1에서만 실행하며 VM2는 SSH를 통해 원격으로 구성된다.
   ※ SSH 등가 설정은 gridSetup.sh 내 SSH Connectivity 단계에서 자동 구성된다.
   ※ Private NIC 선택 화면에서 ens37을 "ASM & Private" 용도로 지정해야 한다.
      ens33(Public)과 혼동하지 않는다.
   ※ Prerequisite Checks에서 DNS 관련 오류(resolv.conf / DNS/NIS)는
      실제 DNS 서버 없는 실습 환경 특성상 해결 불가 — [Ignore All] 선택 후 진행한다.

   gridSetup.sh 주요 선택 항목
   +-------------------------------+--------------------------------------------------------+
   | 단계                           | 선택 값                                                 |
   +-------------------------------+--------------------------------------------------------+
   | Configuration Option          | Configure Oracle Grid Infrastructure for a New Cluster |
   | Cluster Configuration         | Configure an Oracle Standalone Cluster                  |
   | Cluster Name                  | oelsvr-cluster                                          |
   | SCAN Name                     | oelsvr-scan                                             |
   | SCAN Port                     | 1521                                                    |
   | Cluster Nodes 추가             | oelsvr1(local) + oelsvr2 / VIP: oelsvr2-vip 추가         |
   | Network Interface Usage (NIC) | ens37 → ASM & Private 지정                               |
   | Storage Option                | Use Oracle Flex ASM for storage                         |
   | ASM Disk Group 이름            | OCR                                                     |
   | ASM Disk Group Redundancy     | NORMAL                                                  |
   | ASM Disk 선택                  | OCR1 / OCR2 / OCR3 선택                                  |
   | GIMR (Management Repository)  | No (관리용 DB 생성 안 함)                                    |
   | Failure Isolation             | 사용 안 함 (IPMI 미설정)                                      |
   | Management Options            | EM Cloud Control 사용 안 함                                |
   | OS Groups                     | asmadmin / asmdba / asmoper (기본값 유지)                   |
   | Install Location              | $GRID_HOME (/u01/app/19.3.0/grid)                       |
   | root script execution         | Automatically (자동 실행 선택)                               |
   +-------------------------------+--------------------------------------------------------+
*/

/*
[VM1 — grid 계정, OS 터미널]
  $ cd $ORACLE_HOME
  $ ./gridSetup.sh
  → 설치 시작

[설치 완료 후 확인 메시지]
  Successfully configured Oracle Grid Infrastructure for a Cluster
  → Grid Cluster 모드 설치 완료
*/


/* ==============================================================================
   8. 클러스터 리소스 상태 확인 — crsctl stat res -t
   ==============================================================================
*/

/* ------------------------------------------------------------------------------
   8-1. 전체 리소스 상태 확인
   ※ 모든 리소스의 Target과 State가 ONLINE / ONLINE이어야 한다.
   ※ OFFLINE 상태인 리소스는 crsctl start res <리소스명>으로 수동 기동한 후 원인을 확인한다.
   ※ SCAN 리스너 3개, VIP 2개, OCR 디스크 그룹이 자동 등록되어 있는지 확인한다.
*/

/*
[VM1 — grid 또는 root, OS 터미널]
  $ crsctl stat res -t
-- [결과]
  Name                               Target  State   Server    State details
  -----------------------------------------------------------------------
  Local Resources
  -----------------------------------------------------------------------
  ora.LISTENER.lsnr
                 ONLINE  ONLINE  oelsvr1   STABLE
                 ONLINE  ONLINE  oelsvr2   STABLE
  ora.chad
                 ONLINE  ONLINE  oelsvr1   STABLE
                 ONLINE  ONLINE  oelsvr2   STABLE
  ora.net1.network
                 ONLINE  ONLINE  oelsvr1   STABLE
                 ONLINE  ONLINE  oelsvr2   STABLE
  ora.ons
                 ONLINE  ONLINE  oelsvr1   STABLE
                 ONLINE  ONLINE  oelsvr2   STABLE
  -----------------------------------------------------------------------
  Cluster Resources
  -----------------------------------------------------------------------
  ora.ASMNET1LSNR_ASM.lsnr(ora.asmgroup)
        1        ONLINE  ONLINE  oelsvr1   STABLE
        2        ONLINE  ONLINE  oelsvr2   STABLE
  ora.LISTENER_SCAN1.lsnr
        1        ONLINE  ONLINE  oelsvr2   STABLE
  ora.LISTENER_SCAN2.lsnr
        1        ONLINE  ONLINE  oelsvr1   STABLE
  ora.LISTENER_SCAN3.lsnr
        1        ONLINE  ONLINE  oelsvr1   STABLE
  ora.OCR.dg(ora.asmgroup)
        1        ONLINE  ONLINE  oelsvr1   STABLE
        2        ONLINE  ONLINE  oelsvr2   STABLE
  ora.asm(ora.asmgroup)
        1        ONLINE  ONLINE  oelsvr1   Started,STABLE
        2        ONLINE  ONLINE  oelsvr2   Started,STABLE
  ora.oelsvr1.vip
        1        ONLINE  ONLINE  oelsvr1   STABLE
  ora.oelsvr2.vip
        1        ONLINE  ONLINE  oelsvr2   STABLE
  ora.scan1.vip
        1        ONLINE  ONLINE  oelsvr2   STABLE
  ora.scan2.vip
        1        ONLINE  ONLINE  oelsvr1   STABLE
  ora.scan3.vip
        1        ONLINE  ONLINE  oelsvr1   STABLE
  → 모든 Target/State ONLINE/ONLINE 확인
*/

/* ------------------------------------------------------------------------------
   8-2. OCR · Voting Disk 배치 확인
   ※ Voting Disk는 +OCR 디스크 그룹 내에 NORMAL Redundancy 기준으로 3개 자동 배치된다.
   ※ OCR도 동일하게 +OCR 디스크 그룹에 저장된다.
*/

/*
[VM1 — grid 또는 root, OS 터미널]
-- Voting Disk 위치 확인
  $ crsctl query css votedisk
-- [결과]
  ##  STATE    File Universal Id                File Name Disk group
  --  -----    -----------------                --------- ---------
   1. ONLINE   xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (/dev/oracleasm/disks/OCR1) [OCR]
   2. ONLINE   xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (/dev/oracleasm/disks/OCR2) [OCR]
   3. ONLINE   xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (/dev/oracleasm/disks/OCR3) [OCR]
  Located 3 voting disk(s).
  → +OCR 그룹 내 Voting Disk 3개 배치 확인

-- OCR 무결성 확인
  $ ocrcheck
-- [결과]
  Status of Oracle Cluster Registry is as follows :
           Version                  :          4
           Total space (kbytes)     :     491684
           Used space (kbytes)      :      84036
           Available space (kbytes) :     407648
           Device/File Name         :       +OCR
                                      Device/File integrity check succeeded
           Cluster registry integrity check succeeded
  → OCR +OCR 그룹 저장 및 무결성 정상 확인
*/


/* ==============================================================================
   9. ASMCA 실행 — 디스크 그룹 DATA, FRA, REDO 생성
   ==============================================================================
   ※ Grid 설치 시 +OCR 그룹만 생성된다. DB 데이터 · 복구 영역 · Redo 전용 그룹을
      별도로 생성해야 한다.
   ※ 모든 그룹을 NORMAL Redundancy로 생성한다.
   ※ Change Discovery Path에서 /dev/oracleasm/disks/* 를 지정해야
      ASM 레이블 디스크가 목록에 표시된다.

   생성할 디스크 그룹
   +--------+------------------------+-------------+
   | 그룹     | 디스크                   | Redundancy  |
   +--------+------------------------+-------------+
   | +DATA  | DATA1/DATA2/DATA3/DATA4 | NORMAL      |
   | +FRA   | FRA1/FRA2              | NORMAL      |
   | +REDO  | REDO1/REDO2            | NORMAL      |
   +--------+------------------------+-------------+
*/

/*
[VM1 — grid 계정, OS 터미널]
  $ asmca
  → ASMCA GUI 실행
  → Disk Groups 탭 → Create → 그룹명/Redundancy/디스크 선택 후 OK
  → DATA, FRA, REDO 순서로 3개 생성
*/

-- ASM 인스턴스에서 디스크 그룹 생성 확인 (grid 계정 또는 SYSASM 권한)
-- [VM1 — ASM 인스턴스, SYSASM]
SELECT name, state, type, total_mb, free_mb
FROM   v$asm_diskgroup
ORDER BY name;
/* [결과]
   NAME   STATE    TYPE    TOTAL_MB   FREE_MB
   ------ -------- ------- ---------- ----------
   DATA   MOUNTED  NORMAL  ...        ...
   FRA    MOUNTED  NORMAL  ...        ...
   OCR    MOUNTED  NORMAL  ...        ...
   REDO   MOUNTED  NORMAL  ...        ...
   → 4개 디스크 그룹 MOUNTED 확인
*/


/* ==============================================================================
   10. DB 소프트웨어 설치 — runInstaller
   ==============================================================================
*/

/* ------------------------------------------------------------------------------
   10-1. runInstaller 실행
   ※ DB 소프트웨어는 VM1에서 실행하며 VM2에도 동시에 배포된다.
   ※ Set Up Software Only 선택 — DB 생성은 이후 dbca에서 별도 진행한다.
   ※ Database Installation Option은 RAC 선택, Node Selection에서 oelsvr2 추가한다.

   runInstaller 주요 선택 항목
   +--------------------------+------------------------------------------+
   | 단계                      | 선택 값                                    |
   +--------------------------+------------------------------------------+
   | Configuration Option     | Set Up Software Only                     |
   | Database Installation    | Oracle Real Application Clusters database |
   | Node Selection           | oelsvr1 · oelsvr2 모두 체크                 |
   | Database Edition         | Enterprise Edition                       |
   | root script execution    | Automatically (자동 실행 선택)                |
   +--------------------------+------------------------------------------+
*/

/*
[VM1 — oracle 계정, OS 터미널]
  $ cd $ORACLE_HOME
  $ ./runInstaller
  → 설치 완료 메시지 확인 후 종료
*/

/* ------------------------------------------------------------------------------
   10-2. Prerequisite Check 오류 처리
   ※ 설치 전 사전 점검에서 두 가지 오류가 발생할 수 있다.

   [오류 1] PRVG-11932 — oelsvr2에 디렉토리 생성 불가
   ※ VM1의 설치 프로그램이 VM2에 원격으로 디렉토리를 생성할 때 권한 부족으로 실패.
   ※ VM2에서 디렉토리를 사전 생성하고 소유권·쓰기 권한을 부여한 후 [Check Again] 클릭.
*/

/*
[VM2 — root, OS 터미널]
  $ mkdir -p /u01/app/oracle/product/19.3.0/dbhome
  $ chown -R oracle:oinstall /u01/app/oracle
  $ chmod -R 775 /u01/app/oracle
  → [Check Again] 클릭 → 오류 사라짐 확인
*/

/*
   [오류 2] PRVG-13606 — chrony 시간 동기화 실패
   ※ VM1과 VM2의 시간 차이가 기준치를 초과하면 Cluster 설치가 실패한다.
   ※ chronyc sources 출력에서 ^* 기호가 있어야 정상 동기화 완료.
      ^? 만 나오면 수 초 후 재확인한다.
   ※ 조치 후 해결되지 않으면 VM1 · VM2 재부팅으로 해결된다.
*/

/*
[VM1 · VM2 — root, OS 터미널]
  $ systemctl restart chronyd
  $ chronyc makestep
  200 OK

  $ chronyc sources -v
-- [결과]
  ^* 외부NTP서버  ...
  → ^* 표시 확인 → 동기화 완료
  → 해결 안 되면 VM1 · VM2 재부팅 후 재시도

   [오류 3] resolv.conf Integrity, DNS/NIS name service
   ※ 실제 DNS 서버 없이 /etc/hosts에 SCAN IP를 등록한 VM 환경에서는 해결 불가.
   ※ [Ignore All] 선택 후 Next로 진행한다.
*/

/* ------------------------------------------------------------------------------
   10-3. SELinux 오류 해결 및 재설치 절차
   ※ Install Product 단계에서 SELinux 활성화 상태이면 파일 복사 권한 오류로 중단된다.
   ※ SELinux를 disabled로 변경하고 방화벽도 중지한 후 재설치한다.
   ※ 방화벽이 켜져 있으면 Private IP 노드 간 통신이 차단되어 설치가 실패한다.
*/

/*
[VM1 · VM2 — root, OS 터미널]
-- SELinux 영구 비활성화 (재부팅 후에도 유지)
  $ vi /etc/selinux/config
  SELINUX=disabled   ← enforcing 또는 permissive에서 변경

-- 방화벽 중지 및 영구 비활성화
  $ systemctl stop firewalld
  $ systemctl disable firewalld

-- VM1 · VM2 재시작
  $ reboot

   재설치 절차 (설치 도중 오류로 중단된 경우)
   ※ Cancel → Yes로 설치 프로그램을 완전히 종료한 후 아래 순서대로 초기화한다.

[단계 1 — 양 노드 $ORACLE_HOME 초기화]
[VM1 · VM2 — oracle 계정]
  $ cd $ORACLE_HOME
  $ pwd                  ← 경로 반드시 확인 후 진행
  $ rm -rf *
  $ rm -rf .[^.]*
  $ ls -al               ← . 과 .. 만 보여야 함

[단계 2 — Inventory 기록 삭제]
[VM1 — oracle 계정]
  $ vi /u01/app/oraInventory/ContentsXML/inventory.xml
  → DB 경로(/u01/app/oracle/product/19.3.0/dbhome)가 적힌 줄만 dd로 삭제 후 :wq
  → Grid 경로(/u01/app/19.3.0/grid)가 적힌 줄은 절대 건드리지 않음

[단계 3 — VM1 · VM2 재시작]
  $ reboot

[단계 4 — VM1에 설치 파일 압축 해제]
[VM1 — oracle 계정]
  $ cd $ORACLE_HOME
  $ unzip LINUX.X64_193000_db_home.zip

[단계 5 — 재설치 시작]
  $ ./runInstaller
*/


/* ==============================================================================
   11. RAC DB 생성 — dbca
   ==============================================================================
   ※ 양 노드에 DB 소프트웨어 설치가 완료된 후 dbca를 실행한다.
   ※ SID Prefix가 orcl이면 인스턴스명은 자동으로 orcl1, orcl2가 된다.
   ※ Redo Log 다중화를 위해 Multiplex redo logs 옵션을 클릭하고
      1번에 +REDO, 2번에 +FRA를 지정한다.
   ※ CDB(Container Database)는 사용하지 않으므로 체크 해제한다.

   dbca 주요 선택 항목
   +-------------------------------+--------------------------------------------------+
   | 단계                           | 선택 값                                           |
   +-------------------------------+--------------------------------------------------+
   | Database Operation            | Create a Database                                |
   | Creation Mode                 | Advanced Configuration                           |
   | Deployment Type               | Oracle Real Application Clusters (RAC) database  |
   | Template                      | General Purpose                                  |
   | Node Selection                | oelsvr1 · oelsvr2 모두 선택                         |
   | Global DB Name                | orcl                                             |
   | SID Prefix                    | orcl                                             |
   | CDB                           | 체크 해제                                          |
   | Storage Type                  | ASM                                              |
   | DB 파일 위치 (Storage Location) | +DATA (기본값 유지)                                 |
   | Redo Log 다중화                 | +REDO(1번), +FRA(2번)                              |
   | Fast Recovery Area            | +FRA / Archive Log Mode 활성화                     |
   | Memory                        | ASMM 설정 유지                                      |
   | Character Set                 | AL32UTF8 (기본값 유지)                               |
   | Connection Mode               | Dedicated Server Mode                            |
   | Sample Schemas                | HR 체크                                           |
   +-------------------------------+--------------------------------------------------+
*/

/*
[VM1 — oracle 계정, OS 터미널]
  $ dbca
  → DB 생성 완료 후 종료
*/

-- dbca 완료 후 인스턴스 상태 확인
/*
[VM1 — OS 터미널]
  $ srvctl status database -d orcl
-- [결과]
  Instance orcl1 is running on node oelsvr1
  Instance orcl2 is running on node oelsvr2
  → 양 노드 인스턴스 기동 확인
*/


/* ==============================================================================
   12. 설치 결과 확인
   ==============================================================================
   ※ gv$instance에서 양 노드(inst_id 1, 2)가 OPEN 상태이면 2 Node RAC 구축이 완료된 것이다.
*/

-- [VM1 — SYSDBA]
-- 양 노드 인스턴스 상태 확인 (gv$ = Global View, RAC 전 노드 조회)
SELECT inst_id, instance_name, host_name, status, version
FROM   gv$instance
ORDER BY inst_id;
/* [결과]
   INST_ID  INSTANCE_NAME  HOST_NAME  STATUS  VERSION
   -------  -------------  ---------  ------  ----------
         1  orcl1          oelsvr1    OPEN    19.0.0.0.0
         2  orcl2          oelsvr2    OPEN    19.0.0.0.0
   → 양 노드 OPEN 확인
*/

-- ASM 인스턴스 상태 확인
/*
[VM1 — OS 터미널]
  $ srvctl status asm
-- [결과]
  ASM is running on oelsvr1,oelsvr2
  → 양 노드 ASM 기동 확인
*/

-- 노드 리스너 상태 확인
/*
[VM1 — OS 터미널]
  $ srvctl status listener
-- [결과]
  Listener LISTENER is enabled
  Listener LISTENER is running on node(s): oelsvr1,oelsvr2
*/

-- SCAN 리스너 상태 확인
/*
[VM1 — OS 터미널]
  $ srvctl status scan_listener
-- [결과]
  SCAN Listener LISTENER_SCAN1 is enabled
  SCAN listener LISTENER_SCAN1 is running on node oelsvr2
  SCAN Listener LISTENER_SCAN2 is enabled
  SCAN listener LISTENER_SCAN2 is running on node oelsvr1
  SCAN Listener LISTENER_SCAN3 is enabled
  SCAN listener LISTENER_SCAN3 is running on node oelsvr1
*/

-- crsctl 최종 상태 확인
/*
[VM1 — OS 터미널]
  $ crsctl stat res -t
  → 전체 리소스 ONLINE / ONLINE 최종 확인
*/

-- DB 파일 ASM 배치 확인 (gv$datafile로 양 인스턴스 공유 확인)
SELECT name
FROM   v$datafile
ORDER BY name;
/* [결과]
   NAME
   -------------------------------------------
   +DATA/ORCL/DATAFILE/sysaux.xxx.xxx
   +DATA/ORCL/DATAFILE/system.xxx.xxx
   +DATA/ORCL/DATAFILE/undotbs1.xxx.xxx
   +DATA/ORCL/DATAFILE/undotbs2.xxx.xxx
   +DATA/ORCL/DATAFILE/users.xxx.xxx
   → +DATA 디스크 그룹 아래 공유 데이터파일 배치 확인
*/

-- Redo Log 다중화 배치 확인
SELECT l.group#, l.members, l.status, lf.member
FROM   v$log l, v$logfile lf
WHERE  l.group# = lf.group#
ORDER BY l.group#, lf.member;
/* [결과]
   GROUP#  MEMBERS  STATUS  MEMBER
   ------  -------  ------  ------------------------------------------
        1        2  CURRENT +REDO/ORCL/ONLINELOG/group_1.xxx.xxx
        1        2  CURRENT +FRA/ORCL/ONLINELOG/group_1.xxx.xxx
        2        2  INACTIVE +REDO/ORCL/ONLINELOG/group_2.xxx.xxx
        2        2  INACTIVE +FRA/ORCL/ONLINELOG/group_2.xxx.xxx
   → +REDO + +FRA 양쪽에 Redo Log 다중화 배치 확인
*/

-- Archive Log 모드 확인
SELECT log_mode FROM v$database;
/* [결과]
   LOG_MODE
   --------
   ARCHIVELOG
   → ARCHIVELOG 모드 활성화 확인
*/


/* ==============================================================================
   13. 주요 명령어 레퍼런스
   ==============================================================================
*/

-- OS 명령어 레퍼런스
/*
  oracleasm scandisks                        ASM 공유 디스크 재스캔
  oracleasm listdisks                        인식된 ASM 디스크 목록 조회
  crsctl stat res -t                         전체 클러스터 리소스 상태 확인
  crsctl query css votedisk                  Voting Disk 위치 및 상태 확인
  ocrcheck                                   OCR 무결성 확인
  srvctl status database -d <db>             RAC DB 전체 인스턴스 상태 확인
  srvctl status asm                          ASM 인스턴스 상태 확인
  srvctl status listener                     노드 리스너 상태 확인
  srvctl status scan_listener                SCAN 리스너 상태 확인
  crsctl start res <리소스명>                   특정 리소스 수동 기동
  crsctl stop  crs                           CRS 전체 중지 (해당 노드)
  crsctl start crs                           CRS 전체 기동 (해당 노드)
  srvctl start  database -d <db>             RAC DB 전체 기동
  srvctl stop   database -d <db>             RAC DB 전체 중지
*/

-- SQL 조회 레퍼런스

-- 양 노드 인스턴스 상태
SELECT inst_id, instance_name, host_name, status FROM gv$instance ORDER BY inst_id;

-- ASM 디스크 그룹 상태
SELECT name, state, type, total_mb, free_mb FROM v$asm_diskgroup ORDER BY name;

-- ASM 디스크 상태
SELECT group_number, disk_number, name, label, state, total_mb, free_mb
FROM   v$asm_disk
ORDER BY group_number, disk_number;

-- Undo 테이블스페이스 (인스턴스별 별도 Undo)
SELECT inst_id, value
FROM   gv$parameter
WHERE  name = 'undo_tablespace'
ORDER BY inst_id;

-- DB 파일 배치 확인
SELECT file#, name FROM v$datafile ORDER BY file#;

-- Redo Log 배치 및 다중화 확인
SELECT l.group#, l.members, l.status, lf.member
FROM   v$log l, v$logfile lf
WHERE  l.group# = lf.group#
ORDER BY l.group#;

-- Archive Log 모드 확인
SELECT log_mode FROM v$database;


/* ==============================================================================
   14. 실습 핵심 요약
   ==============================================================================

   주제                         핵심 포인트
   ---------------------------  ----------------------------------------------------------
   VM 사전 준비                  VM1 스냅샷 복구(ASM 설치 직후) → VM2 Clone 활용 · VM3 종료 유지
   VM2 호스트명 / IP 변경          hostnamectl + ifcfg-ens33 수정 → systemctl restart network
   /etc/hosts                  Public · VIP · Private · SCAN 양 노드 완전 일치 필수
                                SCAN IP는 동일 호스트명으로 3개 등록
   Private NIC                  ens37(Host-only) 신규 생성 · ONBOOT=yes 필수
                                양 노드 ping으로 통신 검증 후 Grid 설치 진행
   VMX 필수 설정                  disk.locking=FALSE · disk.EnableUUID=TRUE
                                diskLib.dataCacheMaxSize=0 · scsi1.sharedBus=virtual
   ASM Disk Mode               Independent-Persistent → 스냅샷 시 ASM 디스크 제외
   ASM 디스크 인식                VM2에서 scandisks만 실행 — createdisk는 VM1에서만
   Grid 설치 모드                 Standalone(Oracle Restart) 아닌 Cluster 모드 선택
                                Private NIC를 "ASM & Private"으로 지정
   +OCR 디스크 그룹               Grid 설치 시 Voting Disk · OCR 자동 배치 (NORMAL, 3개)
   ASMCA 추가 그룹 생성            +DATA / +FRA / +REDO 는 Grid 설치 후 asmca에서 별도 생성
   runInstaller 오류 처리         PRVG-11932: VM2 디렉토리 사전 생성 · 소유권 부여
                                PRVG-13606: chrony 재동기화 또는 VM 재부팅
                                SELinux: disabled · firewalld 중지 후 재설치
   dbca Redo Log 다중화           Multiplex → 1번: +REDO, 2번: +FRA 지정
   설치 완료 기준                  crsctl stat res -t 전체 ONLINE · gv$instance 양 노드 OPEN

   ==============================================================================
*/
