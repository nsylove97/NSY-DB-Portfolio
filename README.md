# Oracle DB Portfolio
DBA/DBE로서의 역량을 키우기 위한 실무 중심의 실습 포트폴리오입니다.
기동 단계별 동작 원리부터 스토리지 구조 관리, 네트워크 구성 및 DB 수동 생성까지 단계별로 실습한 스크립트와 과정을 기록했습니다.
<br/>

## Tech Stack
- **RDBMS:** Oracle Database 19c
- **OS:** Oracle Linux 7.9 (VMware Virtual Machine)
- **Languages:** SQL, Shell Script
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
<br/>

## 🔗 Links
- 📝 **기술 블로그:** https://nsylove97.tistory.com/
  - [Admin 실습 01: 인스턴스 기동 & 파라미터 파일](https://nsylove97.tistory.com/13)
  - [Admin 실습 02: 테이블스페이스](https://nsylove97.tistory.com/14)
  - [Admin 실습 03: DB 수동 생성 & 네트워크 구성, DB 링크](https://nsylove97.tistory.com/32)
- 📧 **Email:** nsylove97@gmail.com
