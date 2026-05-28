/*
================================================================================
  Backup & Recovery 실습 01 — DB 구조 이해 및 아카이브 로그 환경 구성
================================================================================
  Blog  : https://nsylove97.tistory.com/57
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7.9 (VMware Virtual Machine)
  DB          Oracle Database 19c
  SID         orcl
  접속 툴       SQL*Plus, MobaXterm(SSH)
  실습 경로     /home/oracle/backup/
  실행 계정     oracle (OS), SYSDBA (DB)
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. DB 구조 확인 — 백업 대상 파일 조회
  2. 아카이브 로그 모드 현황 확인
  3. 아카이브 관련 파라미터 설정
  4. ARCHIVELOG 모드 전환
  5. 전환 후 검증 및 아카이브 강제 생성
  6. 백업 디렉토리 구성
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. DB 구조 확인 — 백업 대상 파일 조회
   ==========================================================================
   오라클 백업 대상 핵심 파일 3종

   파일 종류                역할
   ---------------------   -------------------------------------------------
   Datafile (.dbf)         실제 데이터(테이블, 인덱스 등)가 저장되는 파일
   Controlfile (.ctl)      DB 구조 정보(파일 목록, SCN, 체크포인트 등) 관리
   Redo Log File (.log)    변경 이력을 순환 기록 — 복구의 핵심 재료

   아카이브 로그 모드에서는 온라인 리두 로그가 꽉 차기 전에
   자동으로 Archived Log 파일로 복사·보관됨
   → 이 파일이 있어야 백업 시점 이후 변경된 데이터까지 복구 가능 (미디어 복구)
*/

-- [SYSDBA] 백업 대상 파일 목록 전체 조회
SELECT name FROM v$datafile
UNION
SELECT name FROM v$controlfile
UNION
SELECT member FROM v$logfile;

/*
 [결과 예시]
   NAME
   ------------------------------------------------------------------
   /u01/app/oracle/oradata/ORCL/control01.ctl
   /u01/app/oracle/oradata/ORCL/control02.ctl
   /u01/app/oracle/oradata/ORCL/redo01.log
   /u01/app/oracle/oradata/ORCL/redo02.log
   /u01/app/oracle/oradata/ORCL/redo03.log
   /u01/app/oracle/oradata/ORCL/sysaux01.dbf
   /u01/app/oracle/oradata/ORCL/system01.dbf
   /u01/app/oracle/oradata/ORCL/undotbs01.dbf
   /u01/app/oracle/oradata/ORCL/users01.dbf
   → 환경마다 파일 경로·개수는 다를 수 있음
*/


/* ==========================================================================
   2. 아카이브 로그 모드 현황 확인
   ==========================================================================
   NOARCHIVELOG vs ARCHIVELOG 비교

   항목              NOARCHIVELOG                    ARCHIVELOG
   --------------    ----------------------------    -------------------------
   아카이브 생성        없음                              온라인 리두 로그 자동 보관
   복구 범위           마지막 Cold Backup 시점까지만          백업 이후 트랜잭션 포함 완전 복구
   운영 중 백업         불가 (DB 종료 필요)                  가능 (Hot Backup)
   적합 환경           개발/테스트 DB                       운영 DB
*/

/* --------------------------------------------------------------------------
   2-1. ARCHIVE LOG LIST 명령어
   --------------------------------------------------------------------------
*/

-- [SYSDBA] 아카이브 모드, 경로, 시퀀스 한 번에 확인
ARCHIVE LOG LIST;

/*
 [결과 예시 — NOARCHIVELOG 상태]
   Database log mode              No Archive Mode
   Automatic archival             Disabled
   Archive destination            USE_DB_RECOVERY_FILE_DEST
   Oldest online log sequence     11
   Current log sequence           13
   → Automatic archival = Disabled → 아카이브 로그 자동 보관 비활성 상태
*/

/* --------------------------------------------------------------------------
   2-2. v$database 조회
   --------------------------------------------------------------------------
*/

-- [SYSDBA] LOG_MODE 컬럼으로 현재 모드 확인
SELECT name, log_mode FROM v$database;

/*
 [결과 예시 — NOARCHIVELOG 상태]
   NAME      LOG_MODE
   --------- ------------
   ORCL      NOARCHIVELOG
   → 전환 후에는 ARCHIVELOG로 변경됨
*/


/* ==========================================================================
   3. 아카이브 관련 파라미터 설정
   ==========================================================================
   ARCHIVELOG 모드 전환 전에 아카이브 경로·파일명 규칙을 먼저 설정
   SCOPE=SPFILE 지정 필수 — 재기동 후에도 설정이 유지됨
*/

/* --------------------------------------------------------------------------
   3-1. 아카이브 저장 경로 이중화 설정
   --------------------------------------------------------------------------
   dest_1, dest_2를 분리하면 한쪽 경로 손상 시 다른 경로로 복구 가능
*/

-- [SYSDBA] 1번 경로 설정
ALTER SYSTEM SET log_archive_dest_1 = 'LOCATION=/home/oracle/arch1' SCOPE=SPFILE;

/*
 [결과 예시]
   System altered.
*/

-- [SYSDBA] 2번 경로 설정 (이중화)
ALTER SYSTEM SET log_archive_dest_2 = 'LOCATION=/home/oracle/arch2' SCOPE=SPFILE;

/*
 [결과 예시]
   System altered.
*/

/* --------------------------------------------------------------------------
   3-2. 아카이브 파일명 규칙 설정
   --------------------------------------------------------------------------
   변수   의미
   ----   ---------------------------------------------------------------
   %t     Thread 번호
   %s     Log Sequence 번호
   %r     Resetlogs ID
*/

-- [SYSDBA] 아카이브 파일명 포맷 설정
ALTER SYSTEM SET log_archive_format = 'arch_%t_%s_%r.arc' SCOPE=SPFILE;

/*
 [결과 예시]
   System altered.
   → 생성된 파일명 예시: arch_1_13_1200525254.arc
*/


/* ==========================================================================
   4. ARCHIVELOG 모드 전환
   ==========================================================================
   전환은 반드시 MOUNT 상태에서만 수행 가능
   절차: SHUTDOWN → STARTUP MOUNT → ALTER DATABASE ARCHIVELOG → OPEN
*/

-- [SYSDBA] 1단계: DB 종료
SHUTDOWN IMMEDIATE;

/*
 [결과 예시]
   Database closed.
   Database dismounted.
   ORACLE instance shut down.
*/

-- [SYSDBA] 2단계: MOUNT 상태로 기동 (OPEN 아님)
STARTUP MOUNT;

/*
 [결과 예시]
   ORACLE instance started.
   ...
   Database mounted.
   → Database opened. 메시지가 없어야 정상 (MOUNT 상태)
*/

-- [SYSDBA] 3단계: ARCHIVELOG 모드 전환
ALTER DATABASE ARCHIVELOG;

/*
 [결과 예시]
   Database altered.
*/

-- [SYSDBA] 4단계: DB 오픈
ALTER DATABASE OPEN;

/*
 [결과 예시]
   Database altered.
*/


/* ==========================================================================
   5. 전환 후 검증 및 아카이브 강제 생성
   ==========================================================================
*/

/* --------------------------------------------------------------------------
   5-1. 전환 결과 확인
   --------------------------------------------------------------------------
*/

-- [SYSDBA] 아카이브 모드 전환 확인
ARCHIVE LOG LIST;

/*
 [결과 예시 — 전환 후 정상 상태]
   Database log mode              Archive Mode
   Automatic archival             Enabled
   Archive destination            /home/oracle/arch2
   Oldest online log sequence     11
   Next log sequence to archive   13
   Current log sequence           13
   → Database log mode = Archive Mode 확인
   → Automatic archival = Enabled 확인
*/

-- [SYSDBA] v$database로 이중 확인
SELECT name, log_mode FROM v$database;

/*
 [결과 예시]
   NAME      LOG_MODE
   --------- ------------
   ORCL      ARCHIVELOG
*/

/* --------------------------------------------------------------------------
   5-2. 로그 스위치로 아카이브 파일 강제 생성
   --------------------------------------------------------------------------
*/

-- [SYSDBA] 로그 스위치 발생 → arch1, arch2 양쪽에 파일 생성 유도
ALTER SYSTEM SWITCH LOGFILE;

/*
 [결과 예시]
   System altered.
*/

-- [SYSDBA] 생성된 아카이브 로그 목록 확인
SELECT sequence#, name, applied
FROM v$archived_log
ORDER BY sequence# DESC;

/*
 [결과 예시]
   SEQUENCE#   NAME                                              APPLIED
   ----------  ------------------------------------------------  ---------
           13  /home/oracle/arch1/arch_1_13_1200525254.arc       NO
           13  /home/oracle/arch2/arch_1_13_1200525254.arc       NO
   → dest_1(arch1), dest_2(arch2) 양쪽에 동일 시퀀스 파일 생성 확인
   → APPLIED = NO : Standby가 없는 환경에서 정상
*/


/* ==========================================================================
   6. 백업 디렉토리 구성
   ==========================================================================
   백업 방식별로 디렉토리를 분리하여 이후 실습 시나리오 구분 기준으로 사용

   디렉토리       용도
   -----------   -----------------------------------------------------------
   noarch        ARCHIVELOG 전환 전 Cold Backup 보관 (NOARCHIVELOG 모드)
   close_bkp     ARCHIVELOG 모드에서 DB 종료 후 수행하는 백업
   open_bkp      운영 중 수행하는 Hot Backup (BEGIN/END BACKUP 방식)
*/

/*
   # [oracle 계정 — Linux OS 터미널]
   mkdir -p /home/oracle/backup/noarch
   mkdir -p /home/oracle/backup/close_bkp
   mkdir -p /home/oracle/backup/open_bkp
*/

/*
   # [oracle 계정 — Linux OS 터미널] 디렉토리 생성 확인
   ls -l /home/oracle/backup/

   [결과 예시]
   drwxrwxr-x. 2 oracle oracle ... close_bkp
   drwxrwxr-x. 2 oracle oracle ... noarch
   drwxrwxr-x. 2 oracle oracle ... open_bkp
*/


/* ==========================================================================
   관련 뷰 및 명령어 정리
   ==========================================================================

   뷰 / 명령어             용도
   --------------------   ---------------------------------------------------
   ARCHIVE LOG LIST        현재 아카이브 모드, 경로, 시퀀스 확인
   v$database              log_mode (ARCHIVELOG / NOARCHIVELOG)
   v$log                   온라인 리두 로그 그룹 상태 (CURRENT / INACTIVE / ACTIVE)
   v$archived_log          생성된 아카이브 로그 목록 및 적용 여부 (APPLIED)
   v$logfile               온라인 리두 로그 파일 경로
   v$datafile              데이터파일 경로 및 상태
   v$controlfile           컨트롤파일 경로


   주요 명령어 정리

   명령어 / 파라미터                             설명
   ------------------------------------------   ----------------------------
   ALTER DATABASE ARCHIVELOG                     아카이브 로그 모드 전환 (MOUNT 상태)
   ALTER DATABASE NOARCHIVELOG                   모드 해제
   ALTER SYSTEM SWITCH LOGFILE                   로그 스위치 강제 발생
   log_archive_dest_1 / _2                       아카이브 저장 경로 이중화 설정
   log_archive_format                            아카이브 파일명 규칙 (%t %s %r)


   실습 핵심 요약

   주제                핵심 포인트
   ----------------   ----------------------------------------------------------
   아카이브 모드 전환   MOUNT 상태에서만 가능 —
                       SHUTDOWN → STARTUP MOUNT → ALTER DATABASE ARCHIVELOG → OPEN
   파라미터 설정 순서   dest_1/2 경로 → format → SCOPE=SPFILE → 재기동 후 전환
   전환 후 확인         ARCHIVE LOG LIST + v$database.log_mode 두 가지로 이중 확인
   백업 디렉토리        noarch / close_bkp / open_bkp 분리 — 이후 시나리오별 구분 기준
*/
