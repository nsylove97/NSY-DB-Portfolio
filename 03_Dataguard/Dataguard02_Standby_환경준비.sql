/*
================================================================================
 Data Guard 02: Standby 환경 준비
================================================================================
 블로그: https://nsylove97.tistory.com/46
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome
   - Primary (VM1) : IP 192.168.111.50 / hostname oelsvr1    / db_unique_name orcl
   - Standby (VM3) : IP 192.168.111.60 / hostname oel-standby / db_unique_name orclstby

 목차
   1. IP & 호스트명 변경 (VM3)
      1-1. IP 변경
      1-2. 호스트명 변경
   2. /etc/hosts 양방향 등록
      2-1. VM3 hosts 파일 수정
      2-2. VM1 hosts 파일 수정
      2-3. ping 테스트
   3. Grid Infrastructure Standalone 설치 (VM3)
      3-1. 설치 파일 압축 해제 및 gridSetup.sh 실행
      3-2. 나머지 디스크 그룹 생성 (asmca)
      3-3. 디스크 그룹 생성 확인
   4. DB 소프트웨어 설치 (VM3)
      4-1. 설치 파일 압축 해제 및 runInstaller 실행
      4-2. ORACLE_SID 환경변수 변경
   5. Oracle Net 설정
      5-1. tnsnames.ora — VM1, VM3 동일하게 적용
      5-2. listener.ora — Static Entry 추가 (VM1)
      5-3. listener.ora — Static Entry 추가 (VM3)
      5-4. 리스너 재시작 및 상태 확인
      5-5. tnsping 테스트
   6. Primary 사전 준비
      6-1. 아카이브 로그 모드 확인
      6-2. 패스워드 파일 Standby로 복사
   7. Standby pfile 작성 & STARTUP NOMOUNT
      7-1. pfile 작성
      7-2. STARTUP NOMOUNT
      7-3. 리스너 기동 확인
================================================================================
*/


/* ============================================================================
   1. IP & 호스트명 변경 (VM3)
   ============================================================================
   - Clone이기 때문에 VM1과 IP·호스트명이 동일한 상태로 기동됨
   - 네트워크 충돌 방지를 위해 VM1 전원을 끄고 VM3만 켠 상태에서 진행
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. IP 변경
   -------------------------------------------------------------------------- */

-- [VM3 — root 계정] 네트워크 설정 파일 수정
-- vi /etc/sysconfig/network-scripts/ifcfg-ens33

/*
 [수정할 항목]
   IPADDR=192.168.111.60    ← VM1(192.168.111.50)과 다르게 설정
   NETMASK=255.255.255.0
   GATEWAY=192.168.111.2
   DNS1=8.8.8.8
*/

-- 네트워크 서비스 재시작
-- systemctl restart network

-- IP 변경 확인
-- ip addr show ens33

/*
 [결과]
   ...
   inet 192.168.111.60/24 brd 192.168.111.255 scope global ens33
   → 192.168.111.60으로 변경됨 확인
*/


/* --------------------------------------------------------------------------
   1-2. 호스트명 변경
   -------------------------------------------------------------------------- */

-- [VM3 — root 계정] 호스트명 변경
-- hostnamectl set-hostname oel-standby

-- 변경 확인
-- hostnamectl status

/*
 [결과]
      Static hostname: oel-standby
            Icon name: computer-vm
              Chassis: vm
   → 호스트명 변경 확인
*/


/* ============================================================================
   2. /etc/hosts 양방향 등록
   ============================================================================
   - Primary ↔ Standby 간 hostname으로 통신하려면 양쪽 VM 모두의
     hosts 파일에 상대방 정보를 등록해야 함
   - hosts 파일은 OS 레벨 설정이므로 ORACLE_HOME 생성 전에 진행 가능
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. VM3 hosts 파일 수정
   -------------------------------------------------------------------------- */

-- [VM3 — root 계정]
-- vi /etc/hosts

/*
 [추가할 항목]
   # Standby (VM3) — 자기 자신
   192.168.111.60  oel-standby oel-standby.localdomain

 ※ Clone으로 복사된 기존 VM1 항목(oelsvr1)은 그대로 유지
*/


/* --------------------------------------------------------------------------
   2-2. VM1 hosts 파일 수정
   -------------------------------------------------------------------------- */

-- [VM1 — root 계정]
-- vi /etc/hosts

/*
 [추가할 항목]
   # Standby (VM3)
   192.168.111.60  oel-standby oel-standby.localdomain
*/


/* --------------------------------------------------------------------------
   2-3. ping 테스트
   -------------------------------------------------------------------------- */

-- [VM1 — root 계정] Standby hostname으로 ping 테스트
-- ping -c 3 oel-standby

/*
 [결과]
   PING oel-standby (192.168.111.60) 56(84) bytes of data.
   64 bytes from oel-standby (192.168.111.60): icmp_seq=1 ttl=64 time=0.xxx ms
   → hostname으로 통신 가능 확인
*/

-- [VM3 — root 계정] Primary hostname으로 ping 테스트
-- ping -c 3 oelsvr1

/*
 [결과]
   PING oelsvr1 (192.168.111.50) 56(84) bytes of data.
   64 bytes from oelsvr1 (192.168.111.50): icmp_seq=1 ttl=64 time=0.xxx ms
   → hostname으로 통신 가능 확인
*/


/* ============================================================================
   3. Grid Infrastructure Standalone 설치 (VM3)
   ============================================================================
   - VM3에는 ASM 인스턴스와 디스크 그룹 필요
   - Grid Infrastructure(Standalone — HAS 구성)를 설치해서 구성
   - VM1 설치 때와 선택 항목 동일 (Standalone 모드 선택이라는 점만 다름)
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. 설치 파일 압축 해제 및 gridSetup.sh 실행
   -------------------------------------------------------------------------- */

-- [VM3 — grid 계정]
-- su - grid
-- cd /u01/app/19.3.0/gridhome
-- unzip LINUX.X64_193000_grid_home.zip
-- sh gridSetup.sh

/*
 [gridSetup.sh 주요 선택 항목]

   [설치 옵션]
     → Configure Oracle Grid Infrastructure for a Standalone Server (Oracle Restart)
       ← Standalone(단일 노드) 선택. Cluster(RAC)가 아님에 주의

   [ASM 디스크 그룹 구성]
     Disk Group Name : DATA
     Redundancy      : Normal
     디스크 선택     : /dev/oracleasm/disks/DATA1 ~ DATA4
     → 목록이 안 뜨면 Disk Discovery Path를 /dev/oracleasm/disks/* 로 변경

   [ASM 비밀번호]
     SYS / ASMSNMP 비밀번호 입력 (VM1과 동일하게 맞추면 관리 편리)

   [OS 그룹]
     OSDBA for ASM : asmadmin
     OSOPER for ASM: asmoper
     OSASM         : asmadmin

   [설치 경로]
     Oracle Base      : /u01/app/grid
     Software Location: /u01/app/19.3.0/gridhome

   [Root Script 실행]
     → Automatically run configuration scripts 선택 후 root 비밀번호 입력
       (또는 설치 완료 후 root 계정에서 수동 실행)
*/


/* --------------------------------------------------------------------------
   3-2. 나머지 디스크 그룹 생성 (asmca)
   --------------------------------------------------------------------------
   ※ Grid 설치 중 DATA 그룹만 생성됨
   ※ FRA / REDO / OCR 그룹은 asmca로 추가 생성
   -------------------------------------------------------------------------- */

-- [VM3 — grid 계정]
-- su - grid
-- asmca

/*
 [asmca 순서]
   Disk Groups 탭 → Create 클릭

   +FRA  : Normal / FRA1, FRA2
   +REDO : Normal / REDO1, REDO2
   +OCR  : Normal / OCR1, OCR2, OCR3
*/


/* --------------------------------------------------------------------------
   3-3. 디스크 그룹 생성 확인
   -------------------------------------------------------------------------- */

-- [VM3 — grid 계정]
CONN / AS SYSASM

SELECT name, state, total_mb, free_mb
FROM   v$asm_diskgroup;

/*
 [결과]
   NAME   STATE     TOTAL_MB  FREE_MB
   -----  --------  --------  -------
   DATA   MOUNTED    40944    ...
   FRA    MOUNTED    20472    ...
   REDO   MOUNTED    20472    ...
   OCR    MOUNTED    30708    ...
   → 4개 디스크 그룹 모두 MOUNTED 확인
*/


/* ============================================================================
   4. DB 소프트웨어 설치 (VM3)
   ============================================================================
   - Standby DB는 RMAN DUPLICATE로 Primary 데이터를 복제해서 만들기 때문에
     DB 생성(dbca)은 하지 않음
   - DB 소프트웨어만 설치
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. 설치 파일 압축 해제 및 runInstaller 실행
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정]
-- su - oracle
-- cd /u01/app/oracle/product/19.3.0/dbhome
-- unzip LINUX.X64_193000_db_home.zip
-- ./runInstaller

/*
 [runInstaller 주요 선택 항목]

   [설치 유형]
     → Set Up Software Only    ← 반드시 이걸 선택. DB 생성하지 않음

   [DB 설치 유형]
     → Single instance database installation

   [버전]
     → Enterprise Edition

   [경로]
     Oracle Base      : /u01/app/oracle
     Software Location: /u01/app/oracle/product/19.3.0/dbhome

   [OS 그룹]
     OSDBA  (dba) / OSOPER (oper) / OSBACKUPDBA (backupdba)
     OSDGDBA (dgdba) / OSKMDBA (kmdba) / OSRACDBA (racdba)

   [Root Script 실행]
     → Automatically run configuration scripts 선택 후 root 비밀번호 입력
       (또는 설치 완료 후 root 계정에서 수동 실행)
*/


/* --------------------------------------------------------------------------
   4-2. ORACLE_SID 환경변수 변경
   --------------------------------------------------------------------------
   ※ Clone으로 복사된 .bash_profile의 ORACLE_SID가 VM1 SID(orcl)로 되어 있음
   ※ Standby SID(orclstby)로 변경 필요
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정] .bash_profile 수정
-- vi ~/.bash_profile

/*
 [수정할 항목]
   export ORACLE_SID=orclstby    ← orcl → orclstby 로 변경
*/

-- 적용 및 확인
-- source ~/.bash_profile
-- echo $ORACLE_SID

/*
 [결과]
   orclstby
   → ORACLE_SID 변경 확인
*/


/* ============================================================================
   5. Oracle Net 설정
   ============================================================================
   - Data Guard는 Redo 전송, RMAN DUPLICATE, Broker 통신 모두에 Oracle Net 사용
   - Primary·Standby 양쪽 모두 설정 필요
   - 현재 양쪽 VM 모두 리스너는 grid 계정 ORACLE_HOME 소속으로 기동 중
     → listener.ora 수정 및 lsnrctl 실행은 grid 계정에서 진행
     → tnsnames.ora는 oracle 계정 ORACLE_HOME 아래에 작성

   리스너 소속 확인
     ps -ef | grep tnslsnr
     [결과]
     grid  ...  /u01/app/19.3.0/gridhome/bin/tnslsnr LISTENER -inherit
     → grid ORACLE_HOME 소속 리스너 확인

   파일 위치 정리
     tnsnames.ora : oracle 계정 / /u01/app/oracle/product/19.3.0/dbhome/network/admin/
     listener.ora : grid 계정   / /u01/app/19.3.0/gridhome/network/admin/
     lsnrctl      : grid 계정에서 실행
     tnsping      : oracle 계정에서 실행
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. tnsnames.ora — VM1, VM3 동일하게 적용
   --------------------------------------------------------------------------
   ※ VM1·VM3 모두 oracle 계정 ORACLE_HOME 아래에 동일한 내용으로 작성
   -------------------------------------------------------------------------- */

-- [VM1, VM3 — oracle 계정]
-- vi $ORACLE_HOME/network/admin/tnsnames.ora

/*
 [tnsnames.ora 내용]

   # Primary — VM1
   ORCL =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = oelsvr1.localdomain)(PORT = 1521))
       (CONNECT_DATA =
         (SERVER = DEDICATED)
         (SERVICE_NAME = orcl)
       )
     )

   # Standby — VM3
   ORCLSTBY =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = oel-standby.localdomain)(PORT = 1521))
       (CONNECT_DATA =
         (SERVER = DEDICATED)
         (SERVICE_NAME = orclstby)
       )
     )

 ※ VM1 기존 tnsnames.ora에 LISTENER_ORCL 항목이 있으면 삭제
    (SERVICE_NAME이 없어 Data Guard 통신에 사용 불가)
*/


/* --------------------------------------------------------------------------
   5-2. listener.ora — Static Entry 추가 (VM1)
   --------------------------------------------------------------------------
   ※ Data Guard Broker는 DB가 다운된 상태에서도 리스너를 통해 접속해야 함
   ※ 동적 등록만으로는 DB 다운 시 접속 불가 → Static Entry 반드시 추가
   ※ ORACLE_HOME은 grid가 아닌 DB ORACLE_HOME 경로 입력
      (SID_NAME이 DB 인스턴스이기 때문)
   -------------------------------------------------------------------------- */

-- [VM1 — grid 계정]
-- su - grid
-- vi $ORACLE_HOME/network/admin/listener.ora
-- → /u01/app/19.3.0/gridhome/network/admin/listener.ora

/*
 [listener.ora 내용]

   LISTENER =
     (DESCRIPTION_LIST =
       (DESCRIPTION =
         (ADDRESS = (PROTOCOL = TCP)(HOST = oelsvr1.localdomain)(PORT = 1521))
       )
     )

   # Static Entry — Broker가 DB 다운 시에도 접속할 수 있도록
   SID_LIST_LISTENER =
     (SID_LIST =
       (SID_DESC =
         (GLOBAL_DBNAME = orcl_DGMGRL.localdomain)
         (ORACLE_HOME   = /u01/app/oracle/product/19.3.0/dbhome)
         (SID_NAME      = orcl)
       )
     )

   ADR_BASE_LISTENER = /u01/app/grid

 ※ GLOBAL_DBNAME 형식: db_unique_name_DGMGRL.db_domain
*/


/* --------------------------------------------------------------------------
   5-3. listener.ora — Static Entry 추가 (VM3)
   -------------------------------------------------------------------------- */

-- [VM3 — grid 계정]
-- su - grid
-- vi $ORACLE_HOME/network/admin/listener.ora
-- → /u01/app/19.3.0/gridhome/network/admin/listener.ora

/*
 [listener.ora 내용]

   LISTENER =
     (DESCRIPTION_LIST =
       (DESCRIPTION =
         (ADDRESS = (PROTOCOL = TCP)(HOST = oel-standby.localdomain)(PORT = 1521))
       )
     )

   # Static Entry
   SID_LIST_LISTENER =
     (SID_LIST =
       (SID_DESC =
         (GLOBAL_DBNAME = orclstby_DGMGRL.localdomain)
         (ORACLE_HOME   = /u01/app/oracle/product/19.3.0/dbhome)
         (SID_NAME      = orclstby)
       )
     )

   ADR_BASE_LISTENER = /u01/app/grid
*/


/* --------------------------------------------------------------------------
   5-4. 리스너 재시작 및 상태 확인
   -------------------------------------------------------------------------- */

-- [VM1, VM3 — grid 계정] 리스너 재시작
-- su - grid
-- lsnrctl stop
-- lsnrctl start

-- 리스너 상태 확인 — Static Entry 등록 여부 체크
-- lsnrctl status

/*
 [VM1 결과에서 확인할 항목]
   Service "orcl_DGMGRL.localdomain" has 1 instance(s).
     Instance "orcl", status UNKNOWN, ...    ← UNKNOWN이어도 정상
                                               (Static Entry는 DB 상태와 무관하게 접속 가능)
   Service "orcl" has 1 instance(s).
     Instance "orcl", status READY, ...      ← 동적 등록 확인

 [VM3 결과에서 확인할 항목]
   Service "orclstby_DGMGRL.localdomain" has 1 instance(s).
     Instance "orclstby", status UNKNOWN, ...  ← Static Entry 확인
   → DB가 없어도 Static Entry는 UNKNOWN으로 등록됨
*/


/* --------------------------------------------------------------------------
   5-5. tnsping 테스트
   -------------------------------------------------------------------------- */

-- [VM1 또는 VM3 — oracle 계정] 양방향 접속 확인
-- tnsping orcl
-- tnsping orclstby

/*
 [결과]
   OK (xx msec)
   → 양쪽 모두 응답 확인
*/


/* ============================================================================
   6. Primary 사전 준비
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. 아카이브 로그 모드 확인
   --------------------------------------------------------------------------
   ※ Data Guard는 Redo 기반으로 동기화하기 때문에
     Primary가 반드시 ARCHIVELOG 모드여야 함
   ※ ASM 실습 01(dbca)에서 이미 활성화했으므로 확인만 진행
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정]
CONN / AS SYSDBA

SELECT log_mode FROM v$database;

/*
 [결과]
   LOG_MODE
   ------------
   ARCHIVELOG
   → ARCHIVELOG 모드 확인
*/


/* --------------------------------------------------------------------------
   6-2. 패스워드 파일 Standby로 복사
   --------------------------------------------------------------------------
   ※ RMAN DUPLICATE 시 Primary에 SYSDBA로 원격 접속해야 함
   ※ VM1의 패스워드 파일은 OS 파일 시스템에 있으므로 scp로 직접 전송
   ※ 패스워드 파일 이름 형식: orapw<ORACLE_SID>
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정] 패스워드 파일 확인
-- ls -l $ORACLE_HOME/dbs/orapw*

/*
 [결과]
   -rw-r-----. 1 oracle oinstall 2048 Mar 25 16:52
   /u01/app/oracle/product/19.3.0/dbhome/dbs/orapworcl
*/

-- VM3로 전송
-- scp $ORACLE_HOME/dbs/orapworcl oracle@oel-standby:/tmp/orapworcl

/*
 [결과]
   orapworcl  100% 2048   xxx KB/s   00:00
   → 전송 완료
*/

-- [VM3 — oracle 계정] DB Home으로 복사 후 이름 변경
-- cp /tmp/orapworcl $ORACLE_HOME/dbs/orapworclstby

-- 확인
-- ls -l $ORACLE_HOME/dbs/orapw*

/*
 [결과]
   -rw-r----- 1 oracle oinstall 2048 ...
   /u01/app/oracle/product/19.3.0/dbhome/dbs/orapworclstby
   → ORACLE_SID(orclstby)에 맞는 이름으로 저장됨 확인
*/


/* ============================================================================
   7. Standby pfile 작성 & STARTUP NOMOUNT
   ============================================================================
   - RMAN DUPLICATE를 실행하려면 Standby 인스턴스가 NOMOUNT 상태로 기동되어 있어야 함
   - DB는 없고 인스턴스만 메모리에 올린 상태
   ============================================================================ */

/* --------------------------------------------------------------------------
   7-1. pfile 작성
   --------------------------------------------------------------------------
   ※ DB_NAME은 Primary와 반드시 동일 — RMAN DUPLICATE 시 컨트롤파일 호환성 필요
   ※ DB_UNIQUE_NAME은 반드시 달라야 함 — ASM 경로, Broker 식별에 사용
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정]
-- vi $ORACLE_HOME/dbs/initorclstby.ora

/*
 [initorclstby.ora 내용]

   DB_NAME=orcl                  -- Primary와 동일해야 함
   DB_UNIQUE_NAME=orclstby       -- Standby 고유 이름 — Primary(orcl)와 달라야 함

   -- ASM 스토리지
   DB_CREATE_FILE_DEST=+DATA
   DB_RECOVERY_FILE_DEST=+FRA
   DB_RECOVERY_FILE_DEST_SIZE=10136M

   -- SGA / PGA (Primary와 동일하거나 크게)
   SGA_TARGET=4720M
   PGA_AGGREGATE_TARGET=1573M

   -- Data Guard 기본 파라미터
   LOG_ARCHIVE_CONFIG='DG_CONFIG=(orcl,orclstby)'
   LOG_ARCHIVE_DEST_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=orclstby'
   LOG_ARCHIVE_DEST_2='SERVICE=orcl ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=orcl'
   FAL_SERVER=orcl
   FAL_CLIENT=orclstby
   STANDBY_FILE_MANAGEMENT=AUTO

   INSTANCE_TYPE=RDBMS
*/


/* --------------------------------------------------------------------------
   7-2. STARTUP NOMOUNT
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정]
CONN / AS SYSDBA

STARTUP NOMOUNT PFILE='$ORACLE_HOME/dbs/initorclstby.ora';

/*
 [결과]
   ORACLE instance started.

   Total System Global Area  4946354688 bytes
   Fixed Size                   8906424 bytes
   Variable Size              922746880 bytes
   Database Buffers          4009754624 bytes
   Redo Buffers                 4947456 bytes
   → 인스턴스만 메모리에 올라온 상태 (DB·컨트롤파일 없음)
*/

-- 인스턴스 상태 확인
SELECT status FROM v$instance;

/*
 [결과]
   STATUS
   ------------
   STARTED
   → STARTED = NOMOUNT 상태 확인
*/


/* --------------------------------------------------------------------------
   7-3. 리스너 기동 확인
   --------------------------------------------------------------------------
   ※ RMAN DUPLICATE 시 Primary가 Standby의 리스너로 접속하므로 기동 상태 확인
   -------------------------------------------------------------------------- */

-- [VM3 — grid 계정]
-- lsnrctl status

/*
 [결과에서 확인할 항목]
   Service "orclstby_DGMGRL.localdomain" has 1 instance(s).   ← Static Entry 확인
   Service "orclstby" has 1 instance(s).                      ← 동적 등록 확인
   → 두 서비스 모두 확인되면 RMAN DUPLICATE 준비 완료

 [이 시점에서의 상태 정리]
   항목               VM1 (Primary)              VM3 (Standby)
   ---------------    -----------------------    -----------------------
   Grid / ASM         기동 중                    기동 중
   디스크 그룹        +DATA/+FRA/+REDO/+OCR      +DATA/+FRA/+REDO/+OCR
   DB 인스턴스        OPEN                        NOMOUNT (DB 없음)
   리스너             기동 중 (Static Entry 포함) 기동 중 (Static Entry 포함)
   tnsnames           ORCL + ORCLSTBY 등록        ORCL + ORCLSTBY 등록
   Password File      dbs/orapworcl               dbs/orapworclstby
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                         핵심 포인트
   -------------------------    ---------------------------------------------------
   VM3 Clone 특징               VM1 Full Clone → OS 사전 설정 전부 복사됨
                                IP·호스트명만 새로 바꾸면 됨
   ASM 디스크                   Clone 시 VM3 폴더에 독립 파일로 새로 복사됨
                                VM1과 공유 아님
   IP 변경                      /etc/sysconfig/network-scripts/ifcfg-ens33 수정 후 network 재시작
   호스트명 변경                 hostnamectl set-hostname 명령 사용
   /etc/hosts                   양쪽 VM 모두 수정 — Primary·Standby 항목 상호 등록 필수
   Oracle Net 설정 타이밍       tnsnames/listener는 DB ORACLE_HOME 생성 이후에 진행
   tnsnames.ora                 oracle 계정 ORACLE_HOME 아래에 작성
                                VM1·VM3 양쪽 모두에 ORCL + ORCLSTBY 두 항목 등록
   listener.ora                 grid 계정 ORACLE_HOME 아래에 작성
                                lsnrctl도 grid 계정에서 실행
   Static Entry                 DB 다운 시에도 Broker가 접속할 수 있도록 반드시 추가
   GLOBAL_DBNAME 형식           db_unique_name_DGMGRL.db_domain
   Static Entry 상태            lsnrctl status에서 UNKNOWN이어도 정상
                                DB 상태와 무관하게 접속 가능
   gridSetup.sh                 Standalone(Oracle Restart) 선택 — Cluster(RAC)가 아님
   runInstaller                 Set Up Software Only 선택 — DB 생성(dbca) 하지 않음
   ORACLE_SID                   Clone 복사된 orcl → orclstby 로 .bash_profile에서 변경
   Password File                orapw<ORACLE_SID> 형식
                                OS 파일 시스템에 orapworcl로 존재 → scp로 전송 후 orapworclstby로 이름 변경
   DB_NAME                      Primary와 동일하게 orcl — RMAN DUPLICATE 컨트롤파일 호환 필요
   DB_UNIQUE_NAME               orclstby — Primary(orcl)와 반드시 달라야 함
                                ASM 경로(+DATA/ORCLSTBY/...)·Broker 식별에 사용
   STARTUP NOMOUNT              DB 없이 인스턴스만 메모리에 올린 상태
                                RMAN DUPLICATE의 전제 조건
   NOMOUNT 확인                 SELECT status FROM v$instance → STARTED

   ============================================================================ */
