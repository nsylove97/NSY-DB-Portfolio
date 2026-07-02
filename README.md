# NSY DB Portfolio

오라클 DB 인스턴스 기동 원리부터 스토리지 관리, 수동 DB 생성, 네트워크 구성,
사용자 보안 관리, Lock & Undo & 감사(Audit), 성능 모니터링(AWR),
ASM 설치 및 인스턴스 구조, 데이터 가드를 활용한 고가용성(HA) / 재해 복구(DR) 구성까지 CLI 환경에서 직접 실습한 포트폴리오입니다.
현재 RAC는 아키텍처부터 2 Node 구축을 완료하고 Clusterware 관리, RMAN 백업,
서비스 분산 설계, Cache Fusion 기반 성능 튜닝까지 단계별로 정리해 나가고 있습니다.
Backup & Recovery 실습도 함께 진행 중이며, 이후 SQL 튜닝까지 확장 예정입니다.

<br/>

## Tech Stack
- **RDBMS:** Oracle Database 19c
- **OS:** Oracle Linux 7.9 (VMware Virtual Machine)
- **Languages:** SQL, PL/SQL, Shell Script
- **Tools:** SQL*Plus, MobaXterm(SSH)

<br/>

## 학습 및 실습 주제

(./01_Admin)

**Admin 실습 01: 인스턴스 기동 & 파라미터 파일**
- SQL*Plus 로컬/클라이언트 접속 방식 비교
- Alert Log 실시간 모니터링
- 인스턴스 기동 4단계 (SHUTDOWN → NOMOUNT → MOUNT → OPEN) 실습
- pfile / spfile 상호 변환 및 SCOPE 옵션 파라미터 제어
- SHUTDOWN ABORT 후 Instance Recovery 확인
- 백그라운드 프로세스 강제 종료 및 크래시 복구

**Admin 실습 02: 테이블스페이스**
- Permanent / Temporary Tablespace 생성 및 관리
- 데이터파일 추가/삭제, 용량 부족 상황 재현 및 확장
- Tablespace OFFLINE / READ ONLY 전환 실습
- OMF (Oracle-Managed Files) 설정 및 자동 파일 관리

**Admin 실습 03: DB 수동 생성 & 네트워크 구성, DB 링크**
- 새 OS 계정(produser) 생성 및 환경변수 분리 구성
- DB 수동 생성 (pfile 작성 → STARTUP NOMOUNT → CREATE DATABASE)
- 데이터 딕셔너리 및 SQL*Plus 환경 초기화 (catalog / catproc / pupbld)
- tnsnames.ora / listener.ora 직접 편집
- 다중 리스너 구성 및 non-default 리스너 수동 등록
- Easy Connect vs Local Naming 비교 실습
- Database Link 생성 및 원격 테이블 조회
- Synonym을 활용한 원격 객체 접근 단순화

**Admin 실습 04: 사용자 관리 & 권한 / 롤 / 프로파일**
- Predefined 계정 구조 및 Administrator Authentication (OS 인증 / 패스워드 파일 인증)
- External Authentication (OPS$ 방식, OS 계정으로 DB 접속)
- 계정 잠금 해제 및 비밀번호 초기화 (LOCKED / EXPIRED & LOCKED 상태 처리)
- 시스템 권한 부여/회수 및 ADMIN OPTION (연쇄 회수 없음)
- 오브젝트 권한 부여/회수 및 GRANT OPTION (연쇄 회수 발생)
- 롤(Role) 생성 및 권한 묶음 관리 (롤 중첩, 활성화 규칙)
- 프로파일(Profile) 생성 및 비밀번호 정책 적용 (잠금 횟수, 만료, 재사용 제한)
- 쿼타(Quota) 설정 및 테이블스페이스 사용 한도 관리

**Admin 실습 05: Lock & Undo & 감사(Audit)**
- Lock 구조 이해 및 블로킹 세션 조회 & Kill Session 실습
- Deadlock 재현 및 오라클 자동 해제 확인
- Undo Data 개념 (Active / Unexpired / Expired 상태)
- Retention Guarantee 설정 및 Undo 테이블스페이스 추가/전환
- Standard Audit (AUDIT / NOAUDIT 명령, DBA_AUDIT_TRAIL 조회)
- Value-Based Auditing (트리거 기반, 변경 전/후 값 기록)
- Fine-Grained Auditing — FGA (DBMS_FGA 패키지, 조건부 감사)
- SYSDBA Auditing (audit_sys_operations, OS 파일 별도 기록)
- AUD$ / FGA_LOG$ 감사 전용 테이블스페이스 이동 (DBMS_AUDIT_MGMT)

**Admin 실습 06: 성능 모니터링 & AWR, Resumable**
- Database Maintenance 개요 (AWR / Advisors / Automated Tasks / ADR)
- 성능 저하 원인 분류 및 Top Sessions 조회 (v$sess_time_model)
- 오라클 메모리 관리 방식 비교 (AMM / ASMM / 수동)
- Memory Advisor로 메모리 크기 변경 효과 사전 예측 (v$memory_target_advice)
- AWR 스냅샷 수동 생성, 보관 기간 변경, 베이스라인 생성 (DBMS_WORKLOAD_REPOSITORY)
- AWR 리포트 생성 (awrrpt.sql) 및 특정 SQL AWR 히스토리 조회 (dba_hist_sqlstat)
- ADDM 분석 결과 및 권고 내용 조회 (dba_advisor_findings)
- 통계 정보 수동 갱신 전/후 실행 계획 비교 (DBMS_STATS)
- Resumable Space Allocation — 소용량 테이블스페이스에서 공간 부족 재현, 일시 정지 및 자동 재개

<br/>

(./02_ASM)

**ASM 실습 01: ASM 설치 (RAC·DG 대비 포함)**
- VMware VM 사양 설정 및 공유 디스크 11개 추가 (Thick Provision, SCSI 컨트롤러 분리)
- 디스크 그룹 설계 — +DATA(4개) / +FRA(2개) / +REDO(2개) / +OCR(3개)
- 디스크 파티션 생성 및 Oracle ASM Library(ASMLib) 설치
- OS 계정(grid / oracle) 생성 및 Role Separation 적용 (asmadmin / asmdba / asmoper 그룹)
- hosts 파일 등록 (Public / VIP / Private / SCAN 대역 사전 정의)
- OS Kernel Parameter & Resource Limit 설정
- ASM 디스크 설정 (oracleasm configure / init / createdisk)
- VM 스냅샷 촬영 및 RAC·Data Guard 대비 VM 복제 전략 (VM2 공유 디스크 연결 / VM3 독립 복제)
- Grid Infrastructure 설치 (gridSetup.sh → roothas.sh → asmca → netca)
- DB 소프트웨어 설치 (runInstaller) 및 DB 생성 (dbca — ASM 스토리지, ARCHIVELOG 활성화)

**ASM 실습 02: 인스턴스 구조 & 동적 성능 뷰**
- ASM 인스턴스 구조 — SGA/PGA 차이, 데이터 접근 흐름, 백그라운드 프로세스(RBAL/ARBn/GMON/MARK)
- ASM 권한 종류 — SYSASM / SYSDBA / SYSOPER
- 시작·종료 순서 실습 — crsctl(CRS 데몬 레벨) / srvctl(서비스 단위)
- 동적 성능 뷰 실습 — v$asm_diskgroup / v$asm_disk / v$asm_file
- ASMCMD 실습 — lsdg / lsdsk(-k) / du / ls -l
- 스트라이핑 & 미러링(EXTERNAL/NORMAL/HIGH) & Failure Group 개념 및 구성 확인

**ASM 실습 03: 초기화 파라미터 & 디스크 그룹 관리**
- ASM 초기화 파라미터 확인 및 동적 변경 (ASM_DISKGROUPS / ASM_DISKSTRING / ASM_POWER_LIMIT)
- DB 인스턴스 vs ASM 인스턴스 SPFILE 위치 비교 및 INSTANCE_TYPE 구분
- 디스크 그룹 생성 & 디스크 추가 — 명령어 레퍼런스 (CREATE DISKGROUP / ALTER DISKGROUP ADD DISK)
- 디스크 그룹 간 데이터파일 이동 3가지 방법 (RMAN COPY + RENAME / MOVE DATAFILE / ASMCMD cp + RENAME)
- 디스크 DROP & UNDROP — 명령어 레퍼런스 (DROPPING 상태 / UNDROP 가능 구간)
- OMF와 ASM 연동 — 현재 환경 확인 및 적용 전후 비교 (db_create_file_dest)
- 디스크 그룹 속성 조회 및 변경 (AU_SIZE / DISK_REPAIR_TIME / COMPATIBLE.RDBMS)
- ASMCMD lsdsk 상세 옵션 (-k / -t / -p / -G)

**ASM 실습 04: 파일 관리 & 템플릿 & 고급 기능**
- ASM 파일 이름 형식 — Fully Qualified Name / Alias / Incomplete Name 구조 및 db_unique_name 사용 이유
- Alias 생성 실습 (ALTER DISKGROUP ADD ALIAS / v$asm_alias / ASMCMD ls)
- Template 실습 — 기본 Template 조회, 사용자 정의 생성·수정·삭제 (v$asm_template / lstmpl)
- 단일 파일 생성 실습 — 기본 Template 자동 적용 vs 커스텀 Template 명시 지정 (`+DATA(템플릿명)`)
- DBMS\_FILE\_TRANSFER.COPY\_FILE — Directory 객체 생성 후 OS ↔ ASM 파일 복사
- ASMCMD cp 실습 — ASM↔ASM / OS→ASM / ASM→OS 3방향 복사
- ASM Fast Mirror Resync — DISK\_REPAIR\_TIME 기반 변경분 재동기화 개념 및 설정
- Preferred Read Failure Groups (PRFG) — RAC 환경 로컬 Failure Group 우선 읽기 개념
- ASM IDP (Intelligent Data Placement) — Hot/Cold 데이터 자동 배치 개념
- RMAN을 활용한 ASM 데이터파일 백업 (전체 DB / 테이블스페이스 단위)
- 관련 뷰 정리 — v$asm_template / v$asm_alias / v$asm_file

<br/>

(./03_DataGuard)

**Data Guard 01: 개념 & 아키텍처**
- Data Guard 구조 — Primary / Standby / Redo Transport / Role Transition
- Standby DB 3가지 타입 비교 — Physical / Logical / Snapshot Standby
- Redo 전송 흐름 — LGWR → TTnn/NSSn → RFS → MRP/LSP 프로세스 역할
- Standby Redo Log(SRL) 구성 및 Real-Time Apply 개념
- 데이터 보호 모드 3가지 — Maximum Protection / Availability / Performance
- Switchover vs Failover vs Fast-Start Failover(FSFO) 개념 비교
- Data Guard Broker — DMON 프로세스 / Configuration File / DGMGRL
- Oracle Net Services — listener.ora Static Entry 필요 이유 및 GLOBAL_DBNAME 형식
- Redo 전송 핵심 파라미터 레퍼런스 — LOG_ARCHIVE_CONFIG / LOG_ARCHIVE_DEST_n / FAL_SERVER / VALID_FOR

**Data Guard 02: Standby 환경 준비 — VM3 초기 설정, Grid Standalone 설치, DB 소프트웨어 설치**
- VM3 Clone 구성 확인 — OS 사전 설정 복사 항목 vs 새로 해야 할 항목 정리
- IP & 호스트명 변경 (ifcfg-ens33 / hostnamectl)
- /etc/hosts 양방향 등록 및 ping 테스트
- Grid Infrastructure Standalone 설치 (gridSetup.sh — Oracle Restart 모드)
- asmca로 나머지 디스크 그룹 생성 (+FRA / +REDO / +OCR)
- DB 소프트웨어 설치 (runInstaller — Set Up Software Only)
- Oracle Net 설정 — tnsnames.ora(oracle 계정) / listener.ora Static Entry(grid 계정) 양쪽 구성
- 리스너 소속 확인 (grid ORACLE_HOME 소속) 및 lsnrctl / tnsping 테스트
- Primary 패스워드 파일 scp 전송 및 orapw\<ORACLE_SID\> 형식으로 이름 변경
- Standby pfile 작성 (DB_NAME / DB_UNIQUE_NAME / DG 파라미터) 및 STARTUP NOMOUNT

**Data Guard 03: Physical Standby 구축 — RMAN DUPLICATE & Redo Apply 확인**
- FORCE LOGGING 활성화 및 Standby Redo Log(SRL) 생성 (Online Redo Log 그룹 수 + 1)
- Primary spfile DG 파라미터 설정 (LOG_ARCHIVE_CONFIG / LOG_ARCHIVE_DEST_n / FAL_SERVER / STANDBY_FILE_MANAGEMENT)
- tnsnames.ora ORCLSTBY_STATIC 항목 추가 — NOMOUNT 상태 접속을 위한 Static Entry 서비스 + UR=A
- RMAN DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE (DORECOVER / NOFILENAMECHECK)
- 복제 결과 확인 — DATABASE_ROLE / ASM 경로 내 db_unique_name 자동 반영
- MRP 기동 (USING CURRENT LOGFILE DISCONNECT FROM SESSION — Real-Time Apply)
- 동기화 상태 확인 — v$managed_standby / v$dataguard_stats (transport lag / apply lag)
- 동기화 검증 — Primary INSERT → SWITCH LOGFILE → Standby READ ONLY 전환 후 반영 확인
- 관련 뷰 정리 — v$database / v$managed_standby / v$dataguard_stats / v$archive_dest / v$standby_log

**Data Guard 04: Data Guard Broker 구성 — DGMGRL & Configuration 관리**
- Broker 사전 준비 — SPFILE 확인 / LOG_ARCHIVE_DEST_2 비우기 (VM1·VM3)
- DG_BROKER_START=TRUE 설정 및 DMON 프로세스 기동 확인
- DGMGRL 접속 및 Configuration 생성 (CREATE CONFIGURATION / ADD DATABASE / ENABLE CONFIGURATION)
- Broker Configuration File 생성 확인 (dr1/dr2<db_unique_name>.dat — $ORACLE_HOME/dbs 이중화)
- 구성 상태 확인 — SHOW CONFIGURATION / SHOW DATABASE / SHOW DATABASE VERBOSE
- Protection Mode 확인 (기본값 MaxPerformance) 및 변경 방법 (LogXptMode → Protection Mode 순서)
- Redo 전송 방식 & 라우팅 — LogXptMode / RedoRoutes / SET STATE
- VALIDATE DATABASE — Switchover/Failover 준비 여부 및 Flashback 상태 확인
- StaticConnectIdentifier 수정 — ORA-12514 해결 (.localdomain 도메인 불일치)
- VALIDATE STATIC CONNECT IDENTIFIER / VALIDATE NETWORK CONFIGURATION
- 관련 뷰 정리 — v$dataguard_config / v$dg_broker_config / Broker Log 파일 위치

**Data Guard 05: Switchover & Failover**
- Switchover 개념 — 계획된 역할 전환, 데이터 손실 없음
- Failover 개념 — 비계획적 역할 전환, Primary 장애 시 Standby 승격
- DGMGRL Switchover 실행 (SWITCHOVER TO orclstby)
- Switchover 후 역할 전환 확인 — SHOW CONFIGURATION / v$database
- 역할 재전환 — Switchover back to original Primary
- DGMGRL Failover 실행 (FAILOVER TO orclstby)
- Failover 후 구 Primary 재통합 (Reinstate)
- VALIDATE DATABASE — Switchover/Failover 준비 여부 사전 점검
- 관련 뷰 정리 — v$database / v$dataguard_stats

**Data Guard 06: Fast-Start Failover(FSFO) & Snapshot Standby**
- FSFO 개념 — Manual Failover vs Fast-Start Failover 비교
- Protection Mode 변경 (MaxPerformance → MaxAvailability, LogXptMode SYNC 선행)
- Flashback Database 활성화 — Primary·Standby 양쪽 필수
- Observer 개념 및 역할 — VM3에 배치, Failover 판단 심판
- Observer 서버 구성 — tnsping 테스트
- Observer 기동 (START OBSERVER — 포그라운드 / 백그라운드 옵션)
- FSFO 활성화 (ENABLE FAST_START)
- SHOW FAST_START FAILOVER — Threshold / Auto-reinstate / Active Target 확인
- Primary 강제 종료(SHUTDOWN ABORT)로 자동 Failover 시뮬레이션
- Observer 터미널에서 Failover 진행 로그 확인
- Failover 완료 후 새 Primary(orclstby) 역할 전환 확인
- Reinstate 절차 — 구 Primary MOUNT 기동 → REINSTATE DATABASE orcl
- Auto-reinstate 동작 원리 (Flashback → Redo 재적용 → Standby 자동 등록)
- Switchover로 원래 구성 복귀
- Snapshot Standby 개요 — Physical Standby와 역할·Redo 적용 방식 비교
- Physical → Snapshot Standby 전환 (CONVERT DATABASE TO SNAPSHOT STANDBY)
- Snapshot Standby에서 읽기·쓰기 테스트 (CREATE TABLE / INSERT)
- Snapshot → Physical 복귀 (CONVERT DATABASE TO PHYSICAL STANDBY)
- 복귀 후 테스트 데이터 소멸 확인 및 MRP 재기동
- 명령어 레퍼런스 정리

**Data Guard 07: 운영 진단 & Active Data Guard & Logical Standby**
- Redo Transport 상태 진단 — Transport Lag / Apply Lag / Archive Dest / Gap 감지 (v$dataguard_stats / v$archive_dest / v$archive_gap)
- MRP 프로세스 진단 — 상태 확인 및 재기동 (v$managed_standby — APPLYING_LOG / WAIT_FOR_LOG / WAIT_FOR_GAP)
- Data Guard 진단 뷰 심화 — v$dataguard_status(이벤트 로그) / v$dataguard_process(프로세스 역할) / v$standby_log(SRL 상태) / LOG_ARCHIVE_TRACE 옵션
- Alert Log & Broker Log 확인 — Primary / Standby / Broker 로그 위치 및 주요 키워드
- Active Data Guard(ADG) 개요 — Physical Standby vs ADG 비교 (Open 모드 / Redo Apply / 라이선스)
- Real-Time Query 활성화 및 확인 (READ ONLY WITH APPLY / Primary 입력 → Standby 즉시 조회)
- STANDBY_MAX_DATA_DELAY — 세션 단위 Apply Lag 상한 설정, 초과 시 ORA-03172 반환
- Session Sequence vs Global Sequence — ADG 환경 시퀀스 동기화 모드 비교 및 실습
- ADG DML Redirect — Standby DML 자동 Primary 전달 (ADG_REDIRECT_DML / 19c 이상)
- Physical vs Logical Standby 비교 — 블록 단위 복사(MRP) vs SQL 재구성 적용(LSP/SQL Apply)
- SQL Apply 아키텍처 — LSP(읽기) → LPnn(정렬) → LSnn(적용) 3단계 / LogMiner 딕셔너리 역할
- Logical Standby 구축 — DBMS_LOGSTDBY.BUILD → ARCHIVE LOG CURRENT 2회(딕셔너리 전송) → RECOVER TO LOGICAL STANDBY → RESETLOGS
- SQL Apply 기동 (START LOGICAL STANDBY APPLY IMMEDIATE) 및 상태 확인 (v$logstdby_state)
- Logical Standby 운영 — DBA_LOGSTDBY_EVENTS / dba_logstdby_unsupported / dba_logstdby_not_unique / Skip 규칙 (DBMS_LOGSTDBY.SKIP)
- Logical Standby 읽기·쓰기 테스트 — Primary 동기화 확인 / Standby 전용 테이블 생성 및 DML
- Physical Standby 복귀 — db_name 원상복구 → NOMOUNT → RMAN DUPLICATE FROM ACTIVE DATABASE 재구축
- RMAN Backup from Standby — Standby 전체 백업 / 아카이브 로그 백업 후 DELETE INPUT / 컨트롤 파일 기반 환경에서 CATALOG START WITH 수동 등록
- 관련 뷰 정리

**Data Guard 08: 심화 주제 정리편**
- Lost Write 개념 — I/O 서브시스템이 쓰기 완료 응답을 반환했지만 실제 디스크에 기록되지 않은 상태
- DBMS_DBCOMP.DBCOMP — Primary–Standby 데이터파일 블록 SCN 단위 비교 / 파일 번호 또는 ALL 인자 사용
- Lost Write 감지 실습 — 테이블스페이스 생성 → 블록 백업 → 업데이트 → 블록 덮어쓰기(dd) → DBCOMP로 탐지
- ALTER SESSION SYNC WITH PRIMARY — ADG 세션에서 Primary 최신 SCN까지 Apply 대기 강제 (일회성)
- STANDBY_MAX_DATA_DELAY vs SYNC WITH PRIMARY — 세션 전체 Lag 상한 vs 단발성 동기화 강제
- GTT(Global Temporary Table) / PTT(Private Temporary Table) — Standby에서 데이터 비동기화 특성 및 ADG 활용
- ON COMMIT DELETE ROWS vs ON COMMIT PRESERVE ROWS — 커밋 시점 삭제 vs 세션 종료 시점 삭제
- In-Memory Column Store(IMCS) 개요 — Buffer Cache(행 단위) vs IMCS(컬럼 단위) / inmemory_size 파라미터
- Standby에서 IMCS 독립 설정 — inmemory_size SPFILE 반영 후 재기동 / v$inmemory_area 사용 현황 확인
- Broker Configuration Export — EXPORT CONFIGURATION TO '파일명' / 경로는 ADR trace 디렉토리
- Broker Configuration Import — REMOVE CONFIGURATION 선행 → IMPORT → ENABLE CONFIGURATION
- Far Sync 아키텍처 — Primary(SYNC) → Far Sync → Standby(ASYNC) / 데이터파일 없는 중간 인스턴스
- Real-Time Cascade — Far Sync 수신 Redo를 Standby로 실시간 전달 / RedoRoutes로 경로 명시
- FASTSYNC 모드 — SYNC + NOAFFIRM 조합 / 수신 확인 후 커밋, 디스크 기록은 비동기
- VALIDATE DATABASE DATAFILE — 데이터파일 단위 Lost Write 탐지 (OUTPUT 옵션으로 결과 파일 지정)
- VALIDATE DATABASE SPFILE — Primary–Standby SPFILE 파라미터 비교 / MISMATCH 항목 사전 수정
- STANDBY_DB_PRESERVE_STATES — Oracle 18c+ / ALL 설정 시 Switchover·Failover 후 Buffer Cache 유지
- Physical → Logical Standby 전환 복습
- PK 없는 테이블의 SQL Apply 문제 — UPDATE / DELETE 행 특정 불가 / dba_logstdby_not_unique 조회
- RELY DISABLE NOVALIDATE PRIMARY KEY — SQL Apply에 논리적 PK 기준 제공 / 실제 제약 미적용 / 임시 방편
- 관련 뷰 정리 — DBMS_DBCOMP.DBCOMP / v$inmemory_area / dba_logstdby_not_unique / dba_constraints

<br/>

(./04_RAC)

**RAC 실습 01: 개념 & 아키텍처 — Cluster · GCS/GES · Cache Fusion**
- RAC 개념 — Active-Active 구성, 단일 인스턴스 vs RAC 비교
- RAC 네트워크 구성 — Public · Private (Interconnect) · VIP · SCAN 역할 및 구조
- 공유 스토리지 구성 — ASM 기반 멀티 인스턴스 동시 접근 원리
- Clusterware 구성 요소 — OCR(Oracle Cluster Registry) · Voting Disk 역할 및 배치
- 전역 자원 관리 — GRD(Global Resource Directory) · GCS(Global Cache Service) · GES(Global Enqueue Service)
- Cache Fusion — 노드 간 블록 전송 흐름, 디스크 I/O 없이 메모리 직접 전달
- RAC 전용 백그라운드 프로세스 — LMS / LMD / LMON / LCK0 역할
- 메모리 요구사항 — RAC 추가 SGA 구성 요소

**RAC 실습 02: 2 Node RAC 구축 — VM 환경 준비 & Grid 설치**
- 사전 준비 — VM1 스냅샷 복구, VM2 Clone 활용, VM3 종료 유지
- VM1 · VM2 호스트명 / IP 설정 확인 — hostnamectl / ifcfg-ens33
- /etc/hosts 동기화 — Public · VIP · Private · SCAN 양 노드 완전 일치
- Private Interconnect (ens34, Host-only) 활성화 및 양 노드 ping 검증
- VMX 설정 확인
- ASM 공유 디스크 확인 — VM2에서 oracleasm scandisks / listdisks
- gridSetup.sh (Cluster 모드) — SCAN · Private NIC · +OCR 디스크 그룹 설정
- root.sh / rootcrs.sh — VM1 완료 후 VM2 순서 실행
- 클러스터 리소스 상태 확인 — crsctl stat res -t, Voting Disk · OCR 배치 확인
- RAC DB 생성 — dbca (Oracle Real Application Clusters database 선택, +DATA / +FRA)
- 설치 결과 확인 — gv$instance 양 노드 OPEN · srvctl status database/asm/listener/scan_listener

**RAC 실습 03: Clusterware 관리 — crsctl · srvctl · OCR · 로그 분석**
- Oracle HAS 구성 — ohasd부터 인스턴스까지 기동 계층
- CSS — Network/Disk Heartbeat 기반 멤버십 관리와 Eviction (misscount/disktimeout)
- CRS / crsd — 클러스터 리소스 관리자, OHASD 하위 리소스 조회(-init)
- crsctl 명령 체계 — check has/crs/cluster, stat res -t, stop/start cluster
- srvctl 명령 체계 — status database/instance/listener/asm/scan_listener, stop/start instance·database
- srvctl config database — AUTOMATIC / MANUAL 자동 시작 정책 비교 및 전환
- OCR 정합성 검사 — ocrcheck(내용 검증) · cluvfy comp ocr(환경 설정 검증)
- OCR 백업 이력 확인 및 수동 백업 — ocrconfig -showbackup / -manualbackup, 자동 백업 주기
- ADRCI — show homes / set home / show alert로 Grid·DB 진단 로그 통합 조회
- Grid 컴포넌트별 로그 위치 — Clusterware / ASM / DB / 리스너 / 설치 로그 경로 정리
- OHAS / CSS / CRS 온라인 상태 확인 절차 — 계층별 단계적 점검 순서

**RAC 실습 04: RAC 파라미터 · SPFILE · Redo · UNDO 관리**
- RAC SPFILE 구조 — 공용 SPFILE을 노드가 공유하는 방식
- ALTER SYSTEM SET … SID 범위 제어 (전체 적용 / 특정 인스턴스 적용)
- ALTER SYSTEM RESET — 파라미터 삭제
- RAC 전용 파라미터 — CLUSTER_DATABASE · INSTANCE_NUMBER · THREAD
- compatible 파라미터 — 양 노드 값 일치 필요성 및 단방향 변경
- ASM_PREFERRED_READ_FAILURE_GROUPS — 노드별 가까운 Failure Group 우선 읽기
- Redo Log Thread 구조 — 인스턴스마다 독립 Thread, 최소 2개 그룹
- Thread 2 추가 및 활성화 (ADD LOGFILE THREAD → ENABLE PUBLIC THREAD)
- UNDO 관리 — 인스턴스별 전용 UNDO TABLESPACE
- UNDO_TABLESPACE 변경 및 이전 테이블스페이스 OFFLINE 전환
- Quiesce RAC Database (ALTER SYSTEM QUIESCE RESTRICTED / UNQUIESCE)
- Cross-instance Session Kill — KILL SESSION 'sid,serial#,@inst_id'
- ASM Instance Recovery vs Crash Recovery 비교

**RAC 실습 05: RMAN 백업 & Recovery — Catalog 서버 구축 · 인스턴스 장애 복구**
- Recovery Catalog 서버 구축 — 별도 DB(2daydba)에 전용 테이블스페이스·사용자 생성 및 권한 부여
- hosts 등록 및 Catalog TNS(RCATDB) 구성, tnsping 연결 확인
- RMAN Catalog 연결 — CREATE CATALOG TABLESPACE로 카탈로그 스키마 생성
- REGISTER DATABASE — DBID 기준 1회 등록 및 LIST INCARNATION 확인
- RAC에서 RMAN 백업 실행 — 한 노드 백업이 공유 컨트롤파일·카탈로그로 타 노드에 즉시 반영
- 멀티 채널 병렬 백업 — CONFIGURE DEVICE TYPE DISK PARALLELISM으로 노드별 채널 분산
- Snapshot Controlfile 위치 확인(SHOW SNAPSHOT CONTROLFILE NAME) 및 공유 스토리지(+DATA) 경로로 변경
- RMAN 백업 채널 — +FRA 경로 지정 및 db_recovery_file_dest_size 용량 상한 관리
- 인스턴스 장애 시뮬레이션 — pmon 프로세스 kill -9로 장애 재현 및 생존 노드 서비스 지속 확인
- srvctl status database로 Clusterware AUTOMATIC 정책 기반 자동 재기동 확인
- RAC Instance Recovery 흐름 — GES(LMON) → GCS(LMS) → Lock 정리 → SMON Redo 적용
- Alert Log 기반 Reconfiguration ~ Instance Recovery Complete 단계 분석
- FAST_START_MTTR_TARGET — 기본값 0(비활성) 및 설정 후 v$instance_recovery / v$mttr_target_advice 예측 조회
- RECOVERY_PARALLELISM — 병렬 복구 슬레이브 프로세스 수 설정 및 alert log SMON 메시지 확인
- Asynchronous I/O(disk_asynch_io) 및 Buffer Cache 크기와 복구 속도의 트레이드오프

(./05_BNR)

**BNR 실습 01: DB 구조 이해 및 아카이브 로그 환경 구성**
- Oracle DB 파일 구조 개요 — Datafile / Controlfile / Redo Log File / Archived Log 역할
- NOARCHIVELOG vs ARCHIVELOG 모드 차이 및 선택 기준
- archive log list / v$database 조회로 현재 로그 모드 확인
- log_archive_dest_1/2 이중화 경로 설정 및 log_archive_format 파일명 규칙 지정
- ARCHIVELOG 모드 전환 절차 — shutdown → MOUNT → ALTER DATABASE ARCHIVELOG → OPEN
- 백업 디렉토리 구성 전략 — noarch / open_bkp / close_bkp 분리

**BNR 실습 02: 노아카이브모드 Cold Backup & 복구 시나리오**
- Consistent Backup(Cold Backup) 개념 및 수행 조건
- v$datafile / v$controlfile / v$logfile 조회로 백업 대상 파일 확인
- checkpoint_change# (SCN) 개념 및 scn_to_timestamp 변환
- 컨트롤 파일 단일화 — control_files 파라미터 scope=spfile 수정
- shutdown immediate → cp -v 전체 백업 수행
- 시나리오 1 — 데이터파일 손상 후 Cold Backup 복원 & 아카이브 로그 적용 완전 복구
- 시나리오 2 — 아카이브 로그 없는 데이터파일 손상 → RESETLOGS 불완전 복구

**BNR 실습 03: 노아카이브 모드에서 백업 없는 TS, System/Undo 데이터파일 손상 복구 시나리오 (3~8)**
- 시나리오 3 — 백업 없는 데이터파일 손상 (Redo O) → ALTER DATABASE CREATE DATAFILE + RECOVER DATAFILE + ONLINE
- 시나리오 4 — 백업 없는 데이터파일 손상 (Redo X) → CREATE DATAFILE 후 복구 실패 → 재시작 후 DROP TABLESPACE
- SYSTEM / UNDO / TEMP 데이터파일 offline 변경 불가 특성 및 MOUNT 상태 복구 원칙
- 시나리오 5 — SYSTEM 데이터파일 손상 (Redo O) → MOUNT에서 RECOVER TABLESPACE system → OPEN
- 시나리오 6 — SYSTEM 데이터파일 손상 (Redo X) → 복구 실패 → 전체 Cold Backup 복원 (불완전 복구)
- 시나리오 7 — UNDO 데이터파일 손상 (Redo O) → MOUNT에서 RECOVER DATAFILE 4 → OPEN
- 시나리오 8 — UNDO 데이터파일 손상 (Redo X) → OFFLINE DROP → OPEN → 새 Undo TS 생성 → undo_tablespace 전환 → 구 Undo TS DROP
- _corrupted_rollback_segments 히든 파라미터로 NEEDS RECOVERY 세그먼트 강제 offline 처리

**BNR 실습 04: 노아카이브 모드에서 TX 중 Undo 손상, Temp 파일 손상, 전체 디스크 손상 복구 (9~11)**
- 시나리오 9 — TX 진행 중 Undo 데이터파일 손상 (Redo X) → OFFLINE DROP → OPEN → 새 Undo TS 생성 → undo_tablespace 전환 → _offline_rollback_segments로 NEEDS RECOVERY 세그먼트 강제 offline → 구 Undo TS DROP
- v$session / v$transaction / v$rollname 조회로 TX 사용 Undo 세그먼트 확인
- 시나리오 10 — Temp 파일 손상 → ALTER TABLESPACE temp ADD TEMPFILE → 손상 파일 DROP / 정상 종료 시 자동 재생성 특성
- 시나리오 11 — 모든 데이터파일·컨트롤파일·리두로그파일 디스크 전체 손상 → 새 경로에 Cold Backup 복원 → pfile control_files 경로 수정 → STARTUP PFILE= MOUNT → ALTER DATABASE RENAME FILE로 전체 파일 경로 재지정 → OPEN

**BNR 실습 05: 노아카이브 모드에서 Redo 없는 복구 & 컨트롤 파일 손상 복구 시나리오 (12~17)**
- 시나리오 12 — 백업에 Redo Log 없음 → RECOVER UNTIL CANCEL USING BACKUP CONTROLFILE → RESETLOGS 불완전 복구
- 시나리오 13 — 컨트롤 파일 손상 (Binary 복원) → backup controlfile 복원 → RECOVER USING BACKUP CONTROLFILE → RESETLOGS
- 시나리오 14 — 컨트롤 파일 손상 (Trace 재생성, 비정상 종료) → CREATE CONTROLFILE REUSE … NORESETLOGS → RECOVER DATABASE → 정상 OPEN
- 시나리오 15 — 컨트롤 파일 손상 (Trace 재생성, 정상 종료) → CREATE CONTROLFILE REUSE … NORESETLOGS → RECOVER 없이 정상 OPEN
- 시나리오 16 — 컨트롤 파일 손상 (Trace 재생성, 비정상 종료) → CREATE CONTROLFILE REUSE … NORESETLOGS → RECOVER DATABASE → Redo 수동 지정 → 정상 OPEN
- 시나리오 17 — 데이터파일 + 컨트롤 파일 동시 손상 (Redo O) → 전체 복원 → RECOVER USING BACKUP CONTROLFILE → RESETLOGS
- ALTER DATABASE BACKUP CONTROLFILE TO TRACE 로 trace 파일 생성 및 CREATE CONTROLFILE 재작성
- RESETLOGS 이후 즉시 Whole Database Backup 수행 원칙
- 복구 후 TEMP 파일 재연결 — ALTER TABLESPACE TEMP ADD TEMPFILE … REUSE

**BNR 실습 06: 노아카이브 모드에서 컨트롤 파일·리두 로그 파일 손상 복구 시나리오 (18~24)**
- v$log / v$logfile 조회로 그룹별 STATUS(CURRENT/ACTIVE/INACTIVE) 및 ARCHIVED 여부 확인
- 시나리오 18 — 컨트롤 파일·데이터파일 전체 유실 (Redo X, 비정상 종료) → Cold Backup 복원 → RECOVER DATABASE UNTIL CANCEL USING BACKUP CONTROLFILE → RESETLOGS 불완전 복구
- 시나리오 19 — 정상 종료 후 컨트롤 파일·리두 로그 파일 전체 유실 → CREATE CONTROLFILE REUSE … RESETLOGS NOARCHIVELOG → OPEN RESETLOGS → TEMP 파일 재연결
- 시나리오 20 — 리두 로그 파일·컨트롤 파일 손상 + 비정상 종료 → Cold Backup 복원 → RECOVER DATABASE UNTIL CANCEL USING BACKUP CONTROLFILE → RESETLOGS
- 시나리오 21 — 백업 컨트롤 파일과 현재 데이터파일 정보 불일치 (신규 테이블스페이스 추가 후 컨트롤 파일 손상) → CREATE CONTROLFILE REUSE … NORESETLOGS → UNNAMED 데이터파일 수동 지정 → OPEN → 추가 테이블스페이스 DROP
- 시나리오 22 — 정상 종료 후 INACTIVE redo log file 삭제 → 재기동 시 CURRENT 전환 → ALTER DATABASE CLEAR LOGFILE GROUP → OPEN → (로그 그룹 DROP/ADD로 재구성, 선택사항)
- 시나리오 23 — INACTIVE 로그파일 삭제 후 DB 비정상 종료 → ALTER DATABASE CLEAR LOGFILE GROUP → OPEN
- 시나리오 24 — CURRENT redo log file 삭제 → ORA-01624로 즉시 CLEAR 불가 → shutdown/startup으로 로그 그룹 전환 후 ALTER DATABASE CLEAR LOGFILE GROUP → OPEN
- ALTER DATABASE CLEAR LOGFILE GROUP — 로그 파일 재생성, RESETLOGS 없이 정상 OPEN 가능 (단, 손상 로그가 CURRENT/NEEDED인 경우 제한)

**BNR 실습 07: 아카이브 로그 모드 전환 및 온라인 백업 기초**
- archive log list / v$database 조회로 NOARCHIVELOG 모드 확인
- log_archive_dest_1/2 이중화 경로 재설정 및 log_archive_format 변경
- ARCHIVELOG 모드 전환 — shutdown immediate → MOUNT → ALTER DATABASE ARCHIVELOG → OPEN
- ALTER SYSTEM SWITCH LOGFILE / ARCHIVE LOG CURRENT으로 아카이브 로그 생성 확인
- Online Backup — ALTER DATABASE BEGIN BACKUP → cp 전체 백업 → END BACKUP → BACKUP CONTROLFILE TO
- v$datafile / v$backup 조회로 백업 중 STATUS(NOT ACTIVE) 확인

## 🔗 Links
- 📝 **기술 블로그:** https://nsylove97.tistory.com/
  - [Admin 실습 01: 인스턴스 기동 & 파라미터 파일](https://nsylove97.tistory.com/13)
  - [Admin 실습 02: 테이블스페이스](https://nsylove97.tistory.com/14)
  - [Admin 실습 03: DB 수동 생성 & 네트워크 구성, DB 링크](https://nsylove97.tistory.com/32)
  - [Admin 실습 04: 사용자 관리 & 권한 / 롤 / 프로파일](https://nsylove97.tistory.com/33)
  - [Admin 실습 05: Lock & Undo & 감사(Audit)](https://nsylove97.tistory.com/34)
  - [Admin 실습 06: 성능 모니터링 & AWR, Resumable](https://nsylove97.tistory.com/35)
  - [ASM 실습 01: ASM 설치 (RAC·DG 대비 포함)](https://nsylove97.tistory.com/39)
  - [ASM 실습 02: 인스턴스 구조 & 동적 성능 뷰](https://nsylove97.tistory.com/40)
  - [ASM 실습 03: 초기화 파라미터 & 디스크 그룹 관리](https://nsylove97.tistory.com/41)
  - [ASM 실습 04: 파일 관리 & 템플릿 & 고급 기능](https://nsylove97.tistory.com/44)
  - [Data Guard 01: 개념 & 아키텍처](https://nsylove97.tistory.com/45)
  - [Data Guard 02: Standby 환경 준비](https://nsylove97.tistory.com/46)
  - [Data Guard 03: Physical Standby 구축](https://nsylove97.tistory.com/48)
  - [Data Guard 04: Data Guard Broker 구성](https://nsylove97.tistory.com/49)
  - [Data Guard 05: Switchover & Failover](https://nsylove97.tistory.com/50)
  - [Data Guard 06: Fast-Start Failover(FSFO) & Snapshot Standby](https://nsylove97.tistory.com/51)
  - [Data Guard 07: 운영 진단 & Active Data Guard & Logical Standby](https://nsylove97.tistory.com/52)
  - [Data Guard 08: 심화 주제 정리편](https://nsylove97.tistory.com/53)
  - [RAC 실습 01: 개념 & 아키텍처 — Cluster · GCS/GES · Cache Fusion](https://nsylove97.tistory.com/54)
  - [RAC 실습 02: 2 Node RAC 구축 — VM 환경 준비 & Grid 설치](https://nsylove97.tistory.com/55)
  - [RAC 실습 03: Clusterware 관리 — crsctl · srvctl · OCR · 로그 분석](https://nsylove97.tistory.com/64)
  - [RAC 실습 04: RAC 파라미터 · SPFILE · Redo · UNDO 관리](https://nsylove97.tistory.com/65)
  - [RAC 실습 05: RMAN 백업 & Recovery — Catalog 서버 구축 · 인스턴스 장애 복구](https://nsylove97.tistory.com/67)
  - [BNR 실습 01: DB 구조 이해 및 아카이브 로그 환경 구성](https://nsylove97.tistory.com/57)
  - [BNR 실습 02: 노아카이브모드 Cold Backup & 복구 시나리오](https://nsylove97.tistory.com/58)
  - [BNR 실습 03: 노아카이브 모드에서 백업 없는 TS, System/Undo 데이터파일 손상 복구 시나리오 (3~8)](https://nsylove97.tistory.com/59)
  - [BNR 실습 04: 노아카이브 모드에서 TX 중 Undo 손상, Temp 파일 손상, 전체 디스크 손상 복구 (9~11)](https://nsylove97.tistory.com/60)
  - [BNR 실습 05: 노아카이브 모드에서 Redo 없는 복구 & 컨트롤 파일 손상 복구 시나리오 (12~17)](https://nsylove97.tistory.com/61)
  - [BNR 실습 06: 노아카이브 모드에서 컨트롤 파일·리두 로그 파일 손상 복구 시나리오 (18~24)](https://nsylove97.tistory.com/62)
  - [BNR 실습 07: 아카이브 로그 모드 전환 및 온라인 백업 기초](https://nsylove97.tistory.com/63)

- 📧 **Email:** nsylove97@gmail.com
