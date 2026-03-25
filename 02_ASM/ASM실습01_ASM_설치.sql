/*
================================================================================
 ASM 실습 01: ASM 설치 (RAC·DG 대비 포함)
================================================================================
 블로그: https://nsylove97.tistory.com/39
 GitHub: https://github.com/nsylove97/Seongryeol-OracleDB-Portfolio

 실습 환경
   - OS  : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB  : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool: SQL*Plus, MobaXterm(SSH)

 목차
   1.  VMware VM 권장 사양 및 Virtual Machine Settings 설정
       1-1. NIC 2 추가 (RAC Interconnect 전용)
       1-2. ASM용 공유 디스크 11개 추가
       1-3. 디스크 SCSI 컨트롤러 번호 분리
       1-4. VMX 파일 수정
   2.  디스크 그룹 설계
   3.  디스크 파티션
   4.  Oracle ASM Library 설치
   5.  방화벽 비활성화
   6.  Preinstallation RPM 설치
   7.  OS 계정(grid / oracle) 생성 및 그룹 설정 (Role Separation)
   8.  hosts 파일 등록 (RAC 대역 사전 정의)
   9.  시간 동기화 (chrony) 설정
   10. OS Kernel Parameter & Resource Limit 설정
   11. 계정별 환경변수(.bash_profile) 설정
   12. 디렉토리 생성 및 권한 설정
   13. ASM 디스크 설정 (oracleasm)
   14. VM 전원 종료 → 스냅샷 촬영 → VM 복제 (RAC·DG 대비)
   15. Grid Infrastructure 설치 (gridSetup.sh)
   16. DB 소프트웨어 설치 (runInstaller) & DB 생성 (dbca)
================================================================================
*/


/* ============================================================================
   1. VMware VM 권장 사양 및 Virtual Machine Settings 설정
   ============================================================================
   - RAC 구성 시 호스트 PC 1대 위에 최소 2대의 VM을 올려야 하므로 호스트 사양도 고려 필요
   - 아래는 노드 1 기준 권장 사양

   항목          권장 사양
   ---------     ------------------------------------------------
   CPU           4 코어 이상 (Grid + DB 동시 기동, 2 vCPU는 매우 느림)
   RAM           최소 12GB ~ 권장 16GB (Grid 최소 8GB + DB 최소 4GB)
   OS 디스크     80GB 이상
   NIC           최소 2개 필수 (NIC 1: Public / NIC 2: Private Interconnect)
   공유 디스크   총 11개 × 10GB (ASM 디스크 그룹용)
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. NIC 2 추가 (RAC Interconnect 전용)
   --------------------------------------------------------------------------
   - RAC는 노드 간 내부 통신(Interconnect / 캐시 퓨전)을 위한 전용 랜카드가 하나 더 필요
   - 기본 NAT 어댑터(NIC 1) 하나만 있으므로 Host-only 어댑터를 추가해야 함

   NIC 1: NAT 또는 Bridged (기존) → Public Network, 외부 접속·VIP·SCAN 통신
   NIC 2: Host-only (추가)        → Private Network, RAC 노드 간 Interconnect

   [Virtual Machine Settings 순서]
     1) 하단 [Add...] 클릭
     2) Hardware Type: Network Adapter 선택 → [Next]
     3) Network connection:
        ● Host-only: A private network shared with the host  ← 선택
     4) [Finish]
   -------------------------------------------------------------------------- */

/* --------------------------------------------------------------------------
   1-2. ASM용 공유 디스크 11개 추가
   --------------------------------------------------------------------------
   - 반드시 Thick Provision(디스크 미리 할당) 방식으로 생성
     → 미체크 시 RAC 구성 시 I/O 에러 발생
   - 아래 과정을 총 11번 반복

   [Virtual Machine Settings 순서 — 11번 반복]
     1) [Add...] → Hard Disk → SCSI → Create a new virtual disk → [Next]
     2) Disk Capacity:
        - Maximum disk size (GB): 10
        - ☑ Allocate all disk space now   ← 반드시 체크
        - ● Store virtual disk as a single file
     3) Disk File 이름: asm_disk1.vmdk ~ asm_disk11.vmdk → [Finish]
   -------------------------------------------------------------------------- */

/* --------------------------------------------------------------------------
   1-3. 디스크 SCSI 컨트롤러 번호 분리
   --------------------------------------------------------------------------
   - OS 디스크는 SCSI 0:0 사용 → 공유 디스크는 SCSI 1번 컨트롤러에 배치

   asm_disk1.vmdk  → SCSI 1:0  (DATA1 +DATA)
   asm_disk2.vmdk  → SCSI 1:1  (DATA2 +DATA)
   asm_disk3.vmdk  → SCSI 1:2  (DATA3 +DATA)
   asm_disk4.vmdk  → SCSI 1:3  (DATA4 +DATA)
   asm_disk5.vmdk  → SCSI 1:4  (FRA1  +FRA)
   asm_disk6.vmdk  → SCSI 1:5  (FRA2  +FRA)
   asm_disk7.vmdk  → SCSI 1:6  (REDO1 +REDO)
   asm_disk8.vmdk  → SCSI 1:8  (REDO2 +REDO)  ← SCSI 1:7은 예약돼서 skip
   asm_disk9.vmdk  → SCSI 1:9  (OCR1  +OCR)
   asm_disk10.vmdk → SCSI 1:10 (OCR2  +OCR)
   asm_disk11.vmdk → SCSI 1:11 (OCR3  +OCR)

   [Virtual Machine Settings 순서]
     1) 10GB 디스크 클릭 → [Advanced...] → Virtual device node 변경 → [OK]
     2) 11개 모두 순서대로 변경 후 [OK] 저장
   -------------------------------------------------------------------------- */

/* --------------------------------------------------------------------------
   1-4. VMX 파일 수정 (동시 접근 및 고유 식별자 부여)
   --------------------------------------------------------------------------
   - VM 전원을 끈 상태에서 진행
   - ASMLib이 디스크를 고유하게 인식하고 멀티 노드에서 동시 쓰기가 가능하도록 설정

   [Windows 파일 탐색기에서 진행]
     1) VM 저장 경로(예: C:\...\oelsvr1) 이동
     2) oelsvr1.vmx 파일 → 메모장으로 열기
     3) 맨 아래에 아래 두 줄 추가 후 저장

   disk.locking = "FALSE"
   disk.EnableUUID = "TRUE"
   -------------------------------------------------------------------------- */


/* ============================================================================
   2. 디스크 그룹 설계
   ============================================================================
   - 11개의 디스크를 용도별로 4개 그룹으로 분리
   - 현재는 단일 노드로 설치하지만 추후 RAC / Data Guard 확장을 고려한 구성
   - Voting Disk는 쿼럼(Quorum) 알고리즘 사용 → 반드시 홀수(1, 3, 5...)개 필요
     → NORMAL Redundancy: 최소 3개의 Failure Group 필요 → +OCR에 디스크 3개 할당

   디스크 그룹    디스크 수   할당 디스크      미러링   용도
   ----------   --------   -----------     ------  ---------------------------
   +DATA        4개        DATA1 ~ DATA4   NORMAL  데이터파일, 컨트롤파일, 파라미터파일
   +FRA         2개        FRA1 ~ FRA2     NORMAL  아카이브 로그, 백업, Flashback 로그
   +REDO        2개        REDO1 ~ REDO2   NORMAL  온라인 Redo Log (I/O 분리)
   +OCR         3개        OCR1 ~ OCR3     NORMAL  OCR / Voting Disk (RAC 전용, 현재는 예비)

   - Data Guard 확장 시: Standby DB도 동일한 +DATA, +FRA, +REDO 디스크 그룹 구성 필요
   - RAC 확장 시: 모든 노드에서 동일한 공유 디스크에 접근 가능해야 함
   ============================================================================ */


/* ============================================================================
   3. 디스크 파티션
   ============================================================================
   - 10G 공유 디스크 11개에 각각 파티션 생성
   - /dev/sdb ~ /dev/sdl 11개에 동일하게 적용 (root 계정에서 실행)
   ============================================================================ */

-- [root] 현재 디스크 구성 확인
-- lsblk

/*
 [결과]
   NAME        MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
   sdb           8:16   0   10G  0 disk
   sdc           8:32   0   10G  0 disk
   ...
   sdl           8:176  0   10G  0 disk   ← OCR3용 추가 디스크
   sda           8:0    0   80G  0 disk
   ├─sda2        8:2    0   79G  0 part
   └─sda1        8:1    0 1000M  0 part /boot
*/

-- [root] /dev/sdb 파티션 생성 (/dev/sdc ~ /dev/sdl도 동일하게 반복)
-- fdisk /dev/sdb
/*
 [fdisk 입력 순서]
   Command (m for help): n          ← 새 파티션 생성
   Select (default p): p            ← primary 파티션
   Partition number (1-4): [Enter]  ← 기본값 1
   First sector: [Enter]            ← 기본값 사용
   Last sector:  [Enter]            ← 기본값 사용 (전체 10G 사용)
   Command (m for help): w          ← 저장 후 종료
*/

-- [root] 파티션 생성 후 확인
-- lsblk

/*
 [결과]
   sdb ~ sdl 각각 하위에 파티션 생성됨
   sdb1  sdc1  sdd1  sde1  sdf1  sdg1  sdh1  sdi1  sdj1  sdk1  sdl1
   → sdb1 ~ sdl1 파티션 11개 생성 확인
*/


/* ============================================================================
   4. Oracle ASM Library 설치
   ============================================================================
   - ASMLib: 오라클이 디스크를 직접 관리할 수 있도록 해주는 커널 드라이버 라이브러리
   ============================================================================ */

-- [root] 설치 가능한 oracleasm 패키지 목록 확인
-- yum list *oracleasm*

-- [root] ASM 라이브러리 지원 패키지 설치
-- yum -y install oracleasm-support

-- [root] ASM 커널 모듈 설치
-- yum -y install kmod-oracleasm

/*
 [결과]
   Complete!
   → oracleasm-support, kmod-oracleasm 설치 완료
*/


/* ============================================================================
   5. 방화벽 비활성화
   ============================================================================ */

-- [root] 방화벽 즉시 중지
-- systemctl stop firewalld.service

-- [root] 부팅 시 자동 시작 비활성화
-- systemctl disable firewalld.service

/*
 [결과]
   Removed symlink /etc/systemd/system/multi-user.target.wants/firewalld.service.
   Removed symlink /etc/systemd/system/dbus-org.fedoraproject.FirewallD1.service.
*/


/* ============================================================================
   6. Preinstallation RPM 설치
   ============================================================================
   - Oracle DB 설치에 필요한 OS 패키지, 커널 파라미터, 계정 설정을 자동으로 처리해주는 RPM
   - 설치 후 sysctl.conf 및 limits.conf 기본값이 자동 세팅됨
   - 10번 항목(Kernel Parameter) 수동 입력 전 반드시 기존 설정 먼저 확인
   ============================================================================ */

-- [root] Preinstallation RPM 설치
-- yum -y install oracle-database-preinstall-19c

/*
 [결과]
   Complete!
*/

-- [root] Preinstall RPM이 자동 세팅한 커널 파라미터 확인
-- cat /etc/sysctl.conf

-- [root] Resource Limit 자동 세팅 확인
-- cat /etc/security/limits.d/oracle-database-preinstall-19c.conf

/*
 → 이미 세팅된 값은 중복 입력 불필요. 부족한 값만 추가
*/


/* ============================================================================
   7. OS 계정(grid / oracle) 생성 및 그룹 설정 (Role Separation)
   ============================================================================
   - 오라클 공식 권장 방식: Role Separation
     ASM 스토리지 관리 권한과 DB 관리 권한을 분리
   - Preinstallation RPM(6번)이 주요 그룹을 이미 자동 생성
   ============================================================================ */

/* --------------------------------------------------------------------------
   그룹 현황 확인
   -------------------------------------------------------------------------- */

-- [root] 그룹 현황 확인
-- cat /etc/group

/*
 [결과 — Preinstall RPM이 자동 생성한 그룹]
   oinstall:x:54321:    ← grid, oracle 공통 기본 그룹 (설치 디렉토리 소유 그룹)
   dba:x:54322:         ← DB SYSDBA 권한 그룹
   oper:x:54323:        ← DB SYSOPER 권한 그룹
   backupdba:x:54324:   ← SYSBACKUP 권한 그룹 (RMAN 백업/복구 전용)
   dgdba:x:54325:       ← SYSDG 권한 그룹 (Data Guard 관리 전용)
   kmdba:x:54326:       ← SYSKM 권한 그룹 (투명한 데이터 암호화 키 관리 전용)
   racdba:x:54330:      ← SYSRAC 권한 그룹 (RAC 관리 전용)

   ※ asmadmin / asmdba / asmoper 그룹은 자동 생성되지 않음 → 직접 추가 필요
*/


/* --------------------------------------------------------------------------
   ASM 관련 그룹 추가 생성
   -------------------------------------------------------------------------- */

-- [root] ASM 전체 관리 권한 그룹 (SYSASM)
-- groupadd -g 54327 asmadmin

-- [root] ASM 데이터 접근 권한 그룹 (oracle 계정이 ASM 파일에 접근하기 위해 필요)
-- groupadd -g 54328 asmdba

-- [root] ASM 인스턴스 시작/정지 권한 그룹 (SYSOPER for ASM)
-- groupadd -g 54329 asmoper

-- [root] 추가 후 확인
-- grep 'asm' /etc/group

/*
 [결과]
   asmadmin:x:54327:
   asmdba:x:54328:
   asmoper:x:54329:
*/


/* --------------------------------------------------------------------------
   계정 생성 및 그룹 매핑
   -------------------------------------------------------------------------- */

-- [root] grid 계정 생성 — ASM/GI 관리 전용
-- 기본 그룹: oinstall
-- 보조 그룹: asmadmin(SYSASM), asmdba(ASM 접근), asmoper(ASM SYSOPER), racdba(SYSRAC)
-- useradd -u 1001 -g oinstall -G asmadmin,asmdba,asmoper,racdba grid
-- passwd grid

-- [root] oracle 계정은 Preinstall RPM이 이미 생성 → usermod로 그룹 수정
-- 기본 그룹: oinstall로 변경
-- 보조 그룹: dba, oper, backupdba, dgdba, kmdba, racdba, asmdba
-- usermod -g oinstall -G dba,oper,backupdba,dgdba,kmdba,racdba,asmdba oracle
-- passwd oracle

-- [root] 계정 및 그룹 확인
-- id grid

/*
 [결과]
   uid=1001(grid) gid=54321(oinstall)
   groups=54321(oinstall),54327(asmadmin),54328(asmdba),54329(asmoper),54330(racdba)
*/

-- id oracle

/*
 [결과]
   uid=1000(oracle) gid=54321(oinstall)
   groups=54321(oinstall),54322(dba),54323(oper),54324(backupdba),
          54325(dgdba),54326(kmdba),54328(asmdba),54330(racdba)
*/

-- [root] root 계정 umask 설정
-- vi ~/.bash_profile
-- 추가: umask 022


/* ============================================================================
   8. hosts 파일 등록 (RAC 대역 사전 정의)
   ============================================================================
   - 현재는 단일 노드이지만 RAC 확장 시 필요한 IP 대역을 미리 정의해두는 것이 권장됨
   - DNS가 없으므로 SCAN IP는 hosts 파일에 1개만 매핑
     (실무에서는 DNS Round-Robin으로 3개 매핑)
   ============================================================================ */

-- [root] hosts 파일 수정
-- vi /etc/hosts

/*
 [추가할 내용]

   127.0.0.1   localhost localhost.localdomain

   # -----------------------------------------------
   # Public IP (NIC 1 — NAT/Bridged 대역)
   # -----------------------------------------------
   192.168.111.50  oelsvr1 oelsvr1.localdomain    ← 현재 설치 노드 (노드 1)
   192.168.111.51  oelsvr2 oelsvr2.localdomain    ← RAC 노드 2용 (미리 작성)

   # -----------------------------------------------
   # Virtual IP (Public과 같은 대역, 미사용 IP 할당)
   # RAC 구성 시 Clusterware가 VIP를 자동 관리
   # -----------------------------------------------
   192.168.111.52  oelsvr1-vip
   192.168.111.53  oelsvr2-vip

   # -----------------------------------------------
   # Private IP (NIC 2 — Host-Only, 다른 서브넷)
   # RAC 노드 간 Interconnect (캐시 퓨전) 전용
   # -----------------------------------------------
   10.10.10.1      oelsvr1-priv
   10.10.10.2      oelsvr2-priv

   # -----------------------------------------------
   # SCAN IP (DNS 없으므로 hosts에 1개만 매핑)
   # -----------------------------------------------
   192.168.111.55  oelsvr-scan
*/

-- [root] 호스트명 확인
-- hostnamectl status

/*
 [결과]
   Static hostname: oelsvr1.localdomain
   Operating System: Oracle Linux Server 7.9
   Kernel: Linux 5.4.17-2102.201.3.el7uek.x86_64
*/


/* ============================================================================
   9. 시간 동기화 (chrony) 설정
   ============================================================================
   - RAC의 Clusterware는 노드 간 시간이 조금만 틀어져도 노드를 강제 재부팅(Eviction) 시킴
   - OEL 7.9 기본 시간 동기화 도구는 chrony (ntpd 대신 사용)
   - 단일 노드라도 미리 설정해두어야 RAC 확장 시 문제 없음
   ============================================================================ */

-- [root] chrony 설치
-- yum -y install chrony

-- [root] chrony 시작 및 부팅 시 자동 시작 등록
-- systemctl start chronyd
-- systemctl enable chronyd

/*
 [결과]
   Created symlink from /etc/systemd/system/multi-user.target.wants/chronyd.service ...
*/

-- [root] 동기화 상태 확인
-- chronyc tracking

/*
 [결과 예시]
   Reference ID    : ...
   Stratum         : 3
   System time     : 0.000xxxxxx seconds fast of NTP time
   Last offset     : +0.000xxxxxx seconds
*/


/* ============================================================================
   10. OS Kernel Parameter & Resource Limit 설정
   ============================================================================
   - Preinstall RPM이 기본값을 자동 세팅하므로 먼저 현재 값 확인 후 부족한 값만 추가
   ============================================================================ */

-- [root] 메모리 확인 (Grid는 8GB 이상, DB는 1GB 이상 필요)
-- grep MemTotal /proc/meminfo

/*
 [결과]
   MemTotal: 16100892 kB  → 약 16GB
*/

-- [root] Swap 공간 확인 (메모리의 1~1.5배, 16GB 미만)
-- grep SwapTotal /proc/meminfo

/*
 [결과]
   SwapTotal: 24575996 kB  → 약 24GB
*/

-- [root] /tmp 공간 확인 (1GB 이상 필요)
-- df -h /tmp

/*
 [결과]
   /dev/mapper/ol-root  56G  14G  42G  25%  /
*/

/* --------------------------------------------------------------------------
   커널 파라미터 설정
   -------------------------------------------------------------------------- */

-- [root] 현재 자동 세팅된 값 먼저 확인
-- cat /etc/sysctl.conf

-- [root] 부족한 값 추가 (Preinstall RPM이 대부분 자동 세팅 — 없는 항목만 추가)
-- vi /etc/sysctl.conf
/*
   fs.aio-max-nr = 1048576
   fs.file-max = 6815744
   kernel.shmall = 2097152
   kernel.shmmax = 10142509056
   kernel.shmmni = 4096
   kernel.sem = 250 32000 100 128
   net.ipv4.ip_local_port_range = 9000 65500
   net.core.rmem_default = 262144
   net.core.rmem_max = 4194304
   net.core.wmem_default = 262144
   net.core.wmem_max = 1048576
*/

-- [root] 변경값 즉시 적용
-- /sbin/sysctl --system

-- [root] 적용 확인
-- /sbin/sysctl -a


/* --------------------------------------------------------------------------
   Resource Limit 설정 (oracle / grid 계정)
   --------------------------------------------------------------------------
   - Preinstall RPM이 oracle 계정은 자동 세팅하지만 grid 계정은 세팅하지 않음
   → grid 관련 항목만 limits.conf에 추가
   -------------------------------------------------------------------------- */

-- [root] 현재 자동 세팅된 값 먼저 확인
-- cat /etc/security/limits.d/oracle-database-preinstall-19c.conf

-- [root] grid 계정 항목 추가
-- vi /etc/security/limits.conf
/*
   grid         soft     nofile     4096
   grid         hard     nofile     65536
   grid         soft     nproc      16384
   grid         hard     nproc      16384
   grid         soft     stack      10240
   grid         hard     stack      32768
   grid         soft     memlock    3145728
   grid         hard     memlock    3145728
*/

-- [root] 변경 후 서버 재부팅
-- reboot

-- [oracle / grid] 재부팅 후 적용 확인
-- ulimit -Sn   --> 4096    (soft nofile)
-- ulimit -Hn   --> 65536   (hard nofile)
-- ulimit -Su   --> 16384   (soft nproc)
-- ulimit -Hu   --> 16384   (hard nproc)
-- ulimit -Ss   --> 10240   (soft stack)
-- ulimit -Hs   --> 32768   (hard stack)


/* ============================================================================
   11. 계정별 환경변수 설정 (.bash_profile)
   ============================================================================ */

/* --------------------------------------------------------------------------
   grid 계정
   -------------------------------------------------------------------------- */

-- [grid] vi ~/.bash_profile
/*
   export LANG=C
   export ORACLE_BASE=/u01/app/grid
   export ORACLE_HOME=/u01/app/19.3.0/gridhome      ← grid ORACLE_HOME 경로
   export ORACLE_SID=+ASM                            ← ASM 인스턴스 SID
   export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/lib:/usr/lib
   export CLASSPATH=$ORACLE_HOME/JRE:$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib
   export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
   export PATH=$ORACLE_HOME/bin:$PATH:$HOME/bin
   umask 022
*/

/* --------------------------------------------------------------------------
   oracle 계정
   -------------------------------------------------------------------------- */

-- [oracle] vi ~/.bash_profile
/*
   export LANG=C
   export ORACLE_BASE=/u01/app/oracle
   export ORACLE_HOME=/u01/app/oracle/product/19.3.0/dbhome
   export ORACLE_SID=orcl                            ← DB 인스턴스 SID
   export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/lib:/usr/lib
   export CLASSPATH=$ORACLE_HOME/JRE:$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib
   export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
   export PATH=$ORACLE_HOME/bin:$PATH:$HOME/bin
   umask 022
*/

-- [oracle] 환경변수 적용 확인
-- env | grep ORA

/*
 [결과]
   ORACLE_SID=orcl
   ORACLE_BASE=/u01/app/oracle
   ORACLE_HOME=/u01/app/oracle/product/19.3.0/dbhome
*/


/* ============================================================================
   12. 디렉토리 생성 및 권한 설정
   ============================================================================
   - Role Separation 적용으로 소유 그룹이 dba → oinstall로 변경됨
   ============================================================================ */

-- [root] Grid / Oracle / oraInventory 디렉토리 생성
-- mkdir -p /u01/app/oracle
-- mkdir -p /u01/app/oraInventory
-- mkdir -p /u01/app/grid

-- [root] 소유자 및 권한 설정 (oinstall 그룹 기준)
-- chown -R grid:oinstall   /u01/app/grid/
-- chown -R oracle:oinstall /u01/app/oracle/
-- chown -R grid:oinstall   /u01/app/oraInventory/
-- chmod -R 775             /u01/app

-- [root] 데이터파일 저장 디렉토리
-- mkdir -p /u02/oradata
-- chown -R oracle:oinstall /u02/oradata/
-- chmod -R 775             /u02/oradata/

-- [root] Grid / DB ORACLE_HOME 디렉토리 생성
-- mkdir -p /u01/app/oracle/product/19.3.0/dbhome
-- mkdir -p /u01/app/19.3.0/gridhome

-- [root] ORACLE_HOME 소유자 및 권한 설정
-- 소유자가 맞지 않으면 설치 마법사 실행 시 권한 오류 발생
-- chown -R grid:oinstall   /u01/app/19.3.0/gridhome
-- chown -R oracle:oinstall /u01/app/oracle/product/19.3.0/dbhome
-- chmod -R 775             /u01/app/19.3.0/gridhome
-- chmod -R 775             /u01/app/oracle/product/19.3.0/dbhome

/*
 [결과]
   디렉토리 구조 최종 확인
   /u01/app/
   ├── 19.3.0/gridhome/          (grid:oinstall, 775)   ← Grid ORACLE_HOME
   ├── grid/                     (grid:oinstall, 775)   ← Grid ORACLE_BASE
   ├── oraInventory/             (grid:oinstall, 775)
   └── oracle/
       ├── product/19.3.0/dbhome/ (oracle:oinstall, 775) ← DB ORACLE_HOME
       └── ...                    (oracle:oinstall, 775) ← DB ORACLE_BASE
   /u02/oradata/                  (oracle:oinstall, 775)
*/


/* ============================================================================
   13. ASM 디스크 설정 (oracleasm)
   ============================================================================ */

/* --------------------------------------------------------------------------
   ASMLib 드라이버 초기 설정
   -------------------------------------------------------------------------- */

-- [root] ASMLib 드라이버 초기 설정
-- /usr/sbin/oracleasm configure -i

/*
 [대화식 입력]
   Default user to own the driver interface  []: grid
   Default group to own the driver interface []: oinstall   ← Role Separation 적용
   Start Oracle ASM library driver on boot (y/n) [n]: y
   Scan for Oracle ASM disks on boot (y/n) [y]: y

 [결과]
   Writing Oracle ASM library driver configuration: done
*/

-- [root] ASMLib 드라이버 초기화 (마운트 포인트 생성 + 모듈 로드)
-- /usr/sbin/oracleasm init

/*
 [결과]
   Creating /dev/oracleasm mount point: /dev/oracleasm
   Loading module "oracleasm": oracleasm
   Configuring "oracleasm" to use device physical block size
   Mounting ASMlib driver filesystem: /dev/oracleasm
*/


/* --------------------------------------------------------------------------
   Physical Volume 초기화
   -------------------------------------------------------------------------- */

-- [root] LVM Physical Volume으로 초기화 (ASM 디스크 헤더 쓰기 전 준비)
-- pvcreate /dev/sdb1 /dev/sdc1 /dev/sdd1 /dev/sde1 \
--          /dev/sdf1 /dev/sdg1 /dev/sdh1 /dev/sdi1 \
--          /dev/sdj1 /dev/sdk1 /dev/sdl1

/*
 [결과]
   Physical volume "/dev/sdb1" ~ "/dev/sdl1" successfully created. (11개)
*/


/* --------------------------------------------------------------------------
   ASM 디스크 생성 — 용도별 그룹 기준으로 이름 부여
   -------------------------------------------------------------------------- */

-- [root] +DATA 그룹용 (데이터파일 / 컨트롤파일 / 파라미터파일)
-- oracleasm createdisk DATA1 /dev/sdb1
-- oracleasm createdisk DATA2 /dev/sdc1
-- oracleasm createdisk DATA3 /dev/sdd1
-- oracleasm createdisk DATA4 /dev/sde1

-- [root] +FRA 그룹용 (아카이브 로그 / 백업 / Flashback 로그)
-- Data Guard 구성 시 Standby DB의 아카이브 로그도 FRA에 저장됨
-- oracleasm createdisk FRA1 /dev/sdf1
-- oracleasm createdisk FRA2 /dev/sdg1

-- [root] +REDO 그룹용 (온라인 Redo Log 전용 — DATA와 I/O 분리로 성능 향상)
-- oracleasm createdisk REDO1 /dev/sdh1
-- oracleasm createdisk REDO2 /dev/sdi1

-- [root] +OCR 그룹용 (OCR / Voting Disk — RAC 구성 시 사용)
-- Voting Disk는 쿼럼 알고리즘 → 반드시 홀수(3개) 필요
-- NORMAL Redundancy → Failure Group 3개 필수
-- 단일 노드에서는 미사용, RAC 확장 시 바로 활용 가능하도록 예약
-- oracleasm createdisk OCR1 /dev/sdj1
-- oracleasm createdisk OCR2 /dev/sdk1
-- oracleasm createdisk OCR3 /dev/sdl1

/*
 [결과]
   Writing disk header: done
   Instantiating disk: done
   (11개 모두 동일)
*/

-- [root] 등록된 ASM 디스크 목록 확인
-- oracleasm listdisks

/*
 [결과]
   DATA1
   DATA2
   DATA3
   DATA4
   FRA1
   FRA2
   REDO1
   REDO2
   OCR1
   OCR2
   OCR3
*/

-- [root] ASM 디스크 스캔 (부팅 후 재인식이 필요할 때도 사용)
-- oracleasm scandisks

/*
 [결과]
   Reloading disk partitions: done
   Cleaning any stale ASM disks...
   Scanning system for ASM disks...
*/


/* ============================================================================
   14. VM 전원 종료 → 스냅샷 촬영 → VM 복제 (RAC·DG 대비)
   ============================================================================
   - 13번까지 완료한 상태가 골든 이미지(Clean Baseline)
   - 이 시점에서 스냅샷을 찍어두면 RAC / Data Guard 실습마다 깨끗한 상태로 복원 가능
   - Grid 설치(15번) 시작 전에 반드시 진행
   ============================================================================ */

/*
 [VMware에서 진행]
   1) VM1 전원 종료
   2) VM1 우클릭 → Snapshot → Take Snapshot
      Name: "Grid_설치전_골든이미지"
      → [Take Snapshot]
*/


/* --------------------------------------------------------------------------
   14-1. RAC 2번 노드용 복제 (VM2 만들기)
   --------------------------------------------------------------------------
   - OS와 설치 파일은 복제하되 ASM 디스크 11개는 VM1의 것을 공유(연결)
   - 복제 과정에서 딸려온 10GB 디스크 복사본은 모두 제거하고 VM1 원본 파일을 연결해야 함
   -------------------------------------------------------------------------- */

/*
 [VMware에서 진행]
   1. VM1 우클릭 → Manage → Clone
   2. Clone Source: An existing snapshot → 위에서 찍은 스냅샷 선택 → [Next]
   3. Clone Type: Create a full clone → [Next]
   4. Name: oelsvr2 → [Finish]

   5. VM2 → Edit virtual machine settings
      - 복제 시 함께 생성된 10GB 디스크 11개를 모두 클릭 → [Remove]
        (OS가 설치된 80~100GB 디스크 1개만 남김)

   6. [Add...] → Hard Disk → SCSI → Use an existing virtual disk
      → [Browse]로 VM1 폴더의 asm_disk1.vmdk 선택
      → 이 과정을 11번 반복 (asm_disk1.vmdk ~ asm_disk11.vmdk)

   7. 추가한 11개 디스크 각각 [Advanced...] 클릭
      → Virtual device node: SCSI 1:0 ~ SCSI 1:10 순서대로 변경

   8. VM2 폴더의 oelsvr2.vmx 파일을 메모장으로 열고 아래 두 줄 확인(없으면 추가)
      disk.locking = "FALSE"
      disk.EnableUUID = "TRUE"
      → 저장 후 닫기
*/


/* --------------------------------------------------------------------------
   14-2. Data Guard Standby 노드용 복제 (VM3 만들기)
   --------------------------------------------------------------------------
   - OS, 설치 파일, ASM 디스크 11개까지 완전 독립 복제
   - Primary와 동일한 디스크 그룹 환경 구성 가능
   - 복제된 디스크는 VM3 폴더 안에 독립 파일로 새로 생성되므로 제거하지 않고 그대로 사용
   -------------------------------------------------------------------------- */

/*
 [VMware에서 진행]
   1. VM1 우클릭 → Manage → Clone
   2. Clone Source: An existing snapshot → 위에서 찍은 스냅샷 선택 → [Next]
   3. Clone Type: Create a full clone → [Next]
   4. Name: oel-standby → [Finish]

   5. VM3 → Edit virtual machine settings
      - 복제된 11개의 10GB 디스크가 보임 → 이번에는 제거하지 않고 그대로 둠
      - 각 디스크가 SCSI 1:0 ~ SCSI 1:10으로 배치되어 있는지 확인만 진행

   6. VM3 폴더의 oel-standby.vmx 파일을 메모장으로 열고 아래 두 줄 확인(없으면 추가)
      disk.locking = "FALSE"
      disk.EnableUUID = "TRUE"
      → 저장 후 닫기
*/


/* --------------------------------------------------------------------------
   14-3. 향후 실습 순서
   --------------------------------------------------------------------------
   단계     VM 구성                      작업 내용
   ------   --------------------------   -----------------------------------------
   1단계    VM1 단독                     gridSetup.sh (Standalone) → runInstaller
                                         → dbca → 단일 노드 ASM DB 완성
   2단계    VM1(Primary) + VM3(Standby)  VM3 IP/호스트명 변경 → Grid·DB SW 설치
                                         → RMAN DUPLICATE로 Data Guard 구성
   3단계    VM1 + VM2 (RAC)              스냅샷으로 VM1 초기화 → VM2 공유 디스크 연결
                                         → gridSetup.sh (Cluster) → 2 Node RAC 구성
   -------------------------------------------------------------------------- */


/* ============================================================================
   15. Grid Infrastructure 설치 (gridSetup.sh)
   ============================================================================
   - Grid Infrastructure = ASM 인스턴스 + Clusterware 기반 소프트웨어
   - grid 계정에서 설치
   ============================================================================ */

-- [root] 설치 파일 복사
-- cp LINUX.X64_193000_grid_home.zip /u01/app/19.3.0/gridhome/

-- [grid] 압축 해제 및 Grid 설치 마법사 실행
-- su - grid
-- cd /u01/app/19.3.0/gridhome
-- unzip LINUX.X64_193000_grid_home.zip
-- sh gridSetup.sh

/*
 [설치 마법사 주요 설정]
   - Installation Option: Set Up Software Only (단일 노드)
   - OS Groups: 7번에서 설정한 그룹 그대로 확인
   - Oracle Base: /u01/app/grid
   - oraInventory: /u01/app/oraInventory
   - fix&again 단계 → root 계정에서 요구하는 스크립트 실행 후 계속 진행
*/

-- [root] Grid 설치 완료 후 roothas.sh 스크립트 실행
-- /u01/app/19.3.0/gridhome/crs/install/roothas.sh

/*
 [결과]
   CLSRSC-400: A system reboot is required to continue installing.
   or
   CLSRSC-594: Executing installation step 20 of 20: 'StartHA'.
   → HAS(High Availability Services) 기동 완료
*/

-- [grid] ASMCA 그래픽 툴로 디스크 그룹 생성
-- asmca

/*
 [asmca 설정 순서]
   1) Disk Groups 탭 → Create 클릭
   2) 디스크 목록 안 뜨면 Change Disk Discovery Path → '/dev/oracleasm/disks/*' 입력
   3) +DATA 디스크 그룹 생성:
      - Disk Group Name: DATA
      - Redundancy: Normal
      - 디스크 선택: DATA1, DATA2, DATA3, DATA4
      - SYS 및 ASMSNMP 암호 입력 → OK
   4) +FRA, +REDO, +OCR 디스크 그룹도 동일하게 생성
*/

-- [grid] 디스크 그룹 생성 확인 (ORACLE_SID=+ASM 으로 접속)
CONN / AS SYSASM

SELECT name, state, type, total_mb, free_mb
FROM   v$asm_diskgroup;

/*
 [결과]
   NAME   STATE    TYPE    TOTAL_MB  FREE_MB
   -----  -------  ------  --------  -------
   DATA   MOUNTED  NORMAL  ~40960    ~xxxxx   ← 4 × 10G (NORMAL이므로 실사용 약 절반)
   FRA    MOUNTED  NORMAL  ~10240    ~xxxxx   ← 2 × 10G
   REDO   MOUNTED  NORMAL  ~10240    ~xxxxx   ← 2 × 10G
   OCR    MOUNTED  NORMAL  ~15360    ~xxxxx   ← 3 × 10G
*/

-- [grid] crsctl로 HAS 상태 확인
-- crsctl status res -t

/*
 [결과 예시]
   Name           Target  State    Server    State details
   asm            ONLINE  ONLINE   oelsvr1   Started
   ...
*/

-- [grid] netca로 리스너 설정
-- netca


/* ============================================================================
   16. DB 소프트웨어 설치 (runInstaller) & DB 생성 (dbca)
   ============================================================================
   - oracle 계정에서 설치
   ============================================================================ */

-- [root] 설치 파일 복사
-- cp LINUX.X64_193000_db_home.zip /u01/app/oracle/product/19.3.0/dbhome/

-- [oracle] 압축 해제 및 DB 소프트웨어 설치 마법사 실행
-- su - oracle
-- cd /u01/app/oracle/product/19.3.0/dbhome
-- unzip LINUX.X64_193000_db_home.zip
-- ./runInstaller

/*
 [결과]
   Launching Oracle Database Setup Wizard...
*/

-- [oracle] DB 소프트웨어 설치 완료 후 DB 생성 (DBCA)
-- dbca &

/*
 [DBCA GUI 마법사 주요 선택 항목]
   - Database name       : orcl
   - Storage type        : Automatic Storage Management (ASM)
   - Database files      : +DATA     ← 데이터파일 저장 위치
   - Fast Recovery Area  : +FRA      ← 백업/아카이브 저장 위치
   - Redo log 위치       : +REDO (1번), +DATA (2번) 멀티플렉싱 설정
   - Archive Mode        : Enable Archiving 체크   ← Data Guard 대비
*/

-- [oracle] DB 생성 후 접속 확인
CONN / AS SYSDBA

SELECT status FROM v$instance;

/*
 [결과]
   STATUS
   ------
   OPEN    ← DB 정상 오픈 확인
*/

SELECT name, db_unique_name, log_mode
FROM   v$database;

/*
 [결과]
   NAME   DB_UNIQUE_NAME  LOG_MODE
   -----  --------------  ------------
   ORCL   orcl            ARCHIVELOG   ← 아카이브 로그 모드 활성화 확인
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                    핵심 포인트
   -------------------     ---------------------------------------------------
   VM 사양                  CPU 코어 4 이상 / RAM 16GB / NIC 2개
                            (Public NAT + Private Host-only)
   공유 디스크 설정          Thick Provision Eager Zeroed → SCSI 1:0~1:11 배치
                            → .vmx에 disk.locking=FALSE + disk.EnableUUID=TRUE
   디스크 파티션             fdisk로 sdb~sdl 파티션 생성 → sdb1~sdl1 (11개)
   ASMLib 설치              oracleasm-support + kmod-oracleasm
   Role Separation          Preinstall RPM: oinstall/dba/oper/backupdba/dgdba/kmdba/racdba 자동 생성
                            → asmadmin(54327)/asmdba(54328)/asmoper(54329) 직접 추가
   grid 계정                useradd -u 1001 -g oinstall -G asmadmin,asmdba,asmoper,racdba
   oracle 계정              usermod -g oinstall -G dba,oper,backupdba,dgdba,kmdba,racdba,asmdba
   direcotry 소유 그룹       dba → oinstall (Role Separation 적용)
   ORACLE_HOME 경로         grid:   /u01/app/19.3.0/gridhome
                            oracle: /u01/app/oracle/product/19.3.0/dbhome
   hosts 파일               Public(50/51) / VIP(52/53) / Private(10.10.10.x) / SCAN(55) 사전 정의
   chrony                   RAC 노드 간 시간 불일치 시 Eviction 발생 → 반드시 설정
   Resource Limit           Preinstall RPM이 oracle은 자동 세팅 / grid는 limits.conf에 직접 추가
   ASM 디스크 이름           DATA1~4 / FRA1~2 / REDO1~2 / OCR1~3 (용도별 그룹 기준)
   +OCR 3개 이유             Voting Disk 쿼럼 → 홀수 필수 / NORMAL = Failure Group 3개 필수
   oracleasm 소유자          grid / oinstall (Role Separation 적용)
   Grid 설치                 gridSetup.sh → roothas.sh → asmca(디스크 그룹 생성) → netca(리스너)
   DB 설치                   runInstaller → dbca (+DATA / +FRA / +REDO 지정, ARCHIVELOG 활성화)
   시작·종료 순서            시작: ASM(Grid) 먼저 → DB / 종료: DB 먼저 → ASM(Grid)
   스냅샷 타이밍             13번 완료 후 15번 시작 전 → VM 전원 OFF 후 골든 이미지 스냅샷
   VM2 (RAC 노드)            Full Clone → ASM 디스크 11개 Remove → VM1 원본 연결 → SCSI 1:0~1:10
   VM3 (DG Standby)         Full Clone → ASM 디스크 11개 그대로 유지 (독립 파일로 자동 생성)
   향후 실습 순서            1단계: Single Instance → 2단계: Data Guard → 3단계: RAC

   ============================================================================ */
