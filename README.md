# Oracle DBA Portfolio

Oracle DB 인스턴스 기동 원리부터 스토리지 관리, 수동 DB 생성, 네트워크 구성,
사용자 보안 관리, Lock & Undo & 감사(Audit)까지 CLI 환경에서 직접 실습한 포트폴리오입니다.
이후 성능 모니터링, 백업/복구, SQL 튜닝, RAC 및 Data Guard를 활용한 고가용성(HA) 구성까지 확장 예정입니다.

<br/>

## Tech Stack
- **RDBMS:** Oracle Database 19c
- **OS:** Oracle Linux 7.9 (VMware Virtual Machine)
- **Languages:** SQL, PL/SQL, Shell Script
- **Tools:** SQL*Plus, MobaXterm(SSH)

<br/>

## 학습 및 실습 주제

(./01_Admin)
- SQL*Plus 로컬/클라이언트 접속 방식 비교
- Alert Log 실시간 모니터링
- 인스턴스 기동 4단계 (SHUTDOWN → NOMOUNT → MOUNT → OPEN) 실습
- pfile / spfile 상호 변환 및 SCOPE 옵션 파라미터 제어
- SHUTDOWN ABORT 후 Instance Recovery 확인
- 백그라운드 프로세스 강제 종료 및 크래시 복구
- Permanent / Temporary Tablespace 생성 및 관리
- 데이터파일 추가/삭제, 용량 부족 상황 재현 및 확장
- Tablespace OFFLINE / READ ONLY 전환 실습
- OMF (Oracle-Managed Files) 설정 및 자동 파일 관리
- 새 OS 계정(produser) 생성 및 환경변수 분리 구성
- DB 수동 생성 (pfile 작성 → STARTUP NOMOUNT → CREATE DATABASE)
- 데이터 딕셔너리 및 SQL*Plus 환경 초기화 (catalog / catproc / pupbld)
- tnsnames.ora / listener.ora 직접 편집
- 다중 리스너 구성 및 non-default 리스너 수동 등록
- Easy Connect vs Local Naming 비교 실습
- Database Link 생성 및 원격 테이블 조회
- Synonym을 활용한 원격 객체 접근 단순화
- Predefined 계정 구조 및 Administrator Authentication (OS 인증 / 패스워드 파일 인증)
- External Authentication (OPS$ 방식, OS 계정으로 DB 접속)
- 계정 잠금 해제 및 비밀번호 초기화 (LOCKED / EXPIRED & LOCKED 상태 처리)
- 시스템 권한 부여/회수 및 ADMIN OPTION (연쇄 회수 없음)
- 오브젝트 권한 부여/회수 및 GRANT OPTION (연쇄 회수 발생)
- 롤(Role) 생성 및 권한 묶음 관리 (롤 중첩, 활성화 규칙)
- 프로파일(Profile) 생성 및 비밀번호 정책 적용 (잠금 횟수, 만료, 재사용 제한)
- 쿼타(Quota) 설정 및 테이블스페이스 사용 한도 관리
- Lock 구조 이해 및 블로킹 세션 조회 & Kill Session 실습
- Deadlock 재현 및 오라클 자동 해제 확인
- Undo Data 개념 (Active / Unexpired / Expired 상태)
- Retention Guarantee 설정 및 Undo 테이블스페이스 추가/전환
- Standard Audit (AUDIT / NOAUDIT 명령, DBA_AUDIT_TRAIL 조회)
- Value-Based Auditing (트리거 기반, 변경 전/후 값 기록)
- Fine-Grained Auditing — FGA (DBMS_FGA 패키지, 조건부 감사)
- SYSDBA Auditing (audit_sys_operations, OS 파일 별도 기록)
- AUD$ / FGA_LOG$ 감사 전용 테이블스페이스 이동 (DBMS_AUDIT_MGMT)

<br/>

## 🔗 Links
- 📝 **기술 블로그:** https://nsylove97.tistory.com/
  - [Admin 실습 01: 인스턴스 기동 & 파라미터 파일](https://nsylove97.tistory.com/13)
  - [Admin 실습 02: 테이블스페이스](https://nsylove97.tistory.com/14)
  - [Admin 실습 03: DB 수동 생성 & 네트워크 구성, DB 링크](https://nsylove97.tistory.com/32)
  - [Admin 실습 04: 사용자 관리 & 권한 / 롤 / 프로파일](https://nsylove97.tistory.com/33)
  - [Admin 실습 05: Lock & Undo & 감사(Audit)](https://nsylove97.tistory.com/34)
- 📧 **Email:** nsylove97@gmail.com
