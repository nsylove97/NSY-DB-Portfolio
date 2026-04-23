# NSY DB Portfolio

오라클 DB 인스턴스 기동 원리부터 스토리지 관리, 수동 DB 생성, 네트워크 구성,
사용자 보안 관리, Lock & Undo & 감사(Audit), 성능 모니터링(AWR),
ASM(Automatic Storage Management) 설치 및 인스턴스 구조까지 CLI 환경에서 직접 실습한 포트폴리오입니다.
현재 데이터 가드를 활용한 고가용성(HA) / 재해 복구(DR) 구성을 완료했습니다.
이후 RAC 구성, RMAN 백업·복구, SQL 튜닝까지 확장 예정입니다.

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

<br/>

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
- 📧 **Email:** nsylove97@gmail.com
