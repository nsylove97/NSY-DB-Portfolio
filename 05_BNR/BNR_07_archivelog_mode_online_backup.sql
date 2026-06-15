/*
================================================================================
  Backup & Recovery 실습 07 — 아카이브 로그 모드 전환 및 온라인 백업 기초
================================================================================
  Blog  : https://nsylove97.tistory.com/63
  GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

  실습 환경
  -------------------------------------------------------------------------
  OS          Oracle Linux 7.9 (VMware Virtual Machine)
  DB          Oracle Database 19c
  SID         orcl
  접속 툴       SQL*Plus, MobaXterm(SSH)
  아카이브 경로   /home/oracle/arch1, /home/oracle/arch2
  백업 경로     /home/oracle/backup/open_bkp/
  실행 계정     oracle (OS), SYSDBA (DB)
  -------------------------------------------------------------------------

  전제 조건
  -------------------------------------------------------------------------
  - DB가 NOARCHIVELOG 모드로 운영 중인 상태에서 시작
  - /home/oracle/backup/open_bkp/ 디렉토리가 사전 생성되어 있음
  - BNR 실습 06 완료 후 환경 기준
  -------------------------------------------------------------------------

  목차
  -------------------------------------------------------------------------
  1. 현재 로그 모드 확인
  2. 아카이브 경로 및 파라미터 설정
  3. ARCHIVELOG 모드 전환
  4. ARC 프로세스 및 v$log 상태 확인
  5. 로그 스위치와 아카이브 로그 생성 확인
  6. Online (Hot) Backup 수행
  7. 백업 상태 확인 — v$backup
  8. 관련 뷰 정리
  9. 주요 명령어 정리
  10. 실습 핵심 요약
  -------------------------------------------------------------------------
*/


/* ==========================================================================
   1. 현재 로그 모드 확인
   ==========================================================================
   ARCHIVELOG 모드로 전환하기 전, 현재 DB의 로그 모드와
   온라인 리두 로그 그룹 상태를 먼저 확인한다.
*/

/* --------------------------------------------------------------------------
   1-1. ARCHIVE LOG LIST로 로그 모드 확인
   --------------------------------------------------------------------------
   항목                       설명
   ------------------------   ---------------------------------------------
   Database log mode          현재 ARCHIVELOG / NOARCHIVELOG 모드 표시
   Automatic archival          아카이브 자동 보관 활성 여부
   Archive destination          대표 아카이브 경로 표시
   Oldest online log sequence   현재 보관 중인 가장 오래된 로그 시퀀스
   Current log sequence         현재 사용 중인 로그 시퀀스
*/

-- [SQL*Plus — SYSDBA] 현재 아카이브 모드, 경로, 시퀀스 확인
ARCHIVE LOG LIST;

/*
 [결과 예시 — NOARCHIVELOG 상태]
   Database log mode              No Archive Mode
   Automatic archival             Disabled
   Archive destination            /home/oracle/arch2
   Oldest online log sequence     2
   Current log sequence           4
   -> Automatic archival = Disabled -> 아카이브 로그 자동 보관 비활성 상태
*/

-- [SQL*Plus — SYSDBA] v$database로 LOG_MODE 컬럼 확인
SELECT name, log_mode FROM v$database;

/*
 [결과 예시 — NOARCHIVELOG 상태]
   NAME      LOG_MODE
   --------- ------------
   ORCL      NOARCHIVELOG
   -> 전환 후에는 ARCHIVELOG로 변경됨
*/

/* --------------------------------------------------------------------------
   1-2. 온라인 리두 로그 그룹 상태 확인
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 리두 로그 그룹별 상태(STATUS), 아카이브 여부(ARC) 확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;

/*
 [결과 예시]
       GROUP#  SEQUENCE# MEMBER                                           MB STATUS           ARC FIRST_CHANGE# NEXT_CHANGE#
   ---------- ---------- ---------------------------------------- ---------- ---------------- --- ------------- ------------
            1          4 /u01/app/oracle/oradata/ORCL/redo01.log          50 CURRENT          NO        3383245   1.8447E+19
            2          2 /u01/app/oracle/oradata/ORCL/redo02.log          50 INACTIVE         NO        3383239      3383242
            3          3 /u01/app/oracle/oradata/ORCL/redo03.log          50 INACTIVE         NO        3383242      3383245
   -> NOARCHIVELOG 모드에서는 ARC 컬럼이 모두 NO
   -> 로그 스위치가 발생해도 아카이브 로그가 생성되지 않음
*/


/* ==========================================================================
   2. 아카이브 경로 및 파라미터 설정
   ==========================================================================
   ARCHIVELOG 모드 전환 전에 아카이브 경로·파일명 규칙을 먼저 설정한다.
   SCOPE=SPFILE 지정 필수 — 재기동 후에 실제로 적용됨.
*/

/* --------------------------------------------------------------------------
   2-1. 아카이브 로그 이중화 디렉토리 생성
   --------------------------------------------------------------------------
   항목                        설명
   -------------------------   --------------------------------------------
   log_archive_dest_1           필수 경로 (mandatory) — 쓰기 실패 시
                                 온라인 리두 로그가 재사용되지 않음
   log_archive_dest_2           보조 경로 (optional) — 쓰기 실패해도
                                 아카이브 동작 자체에는 영향 없음
*/

/*
   # [oracle 계정 — Linux] 아카이브 로그 저장 디렉토리 생성
   mkdir -p /home/oracle/arch1 /home/oracle/arch2
   ls /home/oracle/arch1 /home/oracle/arch2
*/

-- [SQL*Plus — SYSDBA] 1번 경로(mandatory) 설정
ALTER SYSTEM SET log_archive_dest_1 = 'location=/home/oracle/arch1 mandatory' SCOPE=SPFILE;

/*
 [결과 예시]
   System altered.
*/

-- [SQL*Plus — SYSDBA] 2번 경로(optional, 이중화) 설정
ALTER SYSTEM SET log_archive_dest_2 = 'location=/home/oracle/arch2 optional' SCOPE=SPFILE;

/*
 [결과 예시]
   System altered.
*/

/* --------------------------------------------------------------------------
   2-2. 아카이브 파일명 형식 지정
   --------------------------------------------------------------------------
   변수   의미
   ----   -----------------------------------------------------------------
   %t     Thread 번호
   %T     Thread 번호 (0으로 채워진 형식)
   %s     Log Sequence 번호
   %S     Log Sequence 번호 (0으로 채워진 형식)
   %r     Resetlogs ID
   %R     Resetlogs ID (0으로 채워진 형식)
*/

-- [SQL*Plus — SYSDBA] 현재 아카이브 파일명 형식 확인
SHOW PARAMETER log_archive_format;

/*
 [결과 예시]
   NAME                  TYPE   VALUE
   --------------------- ------ ------------------------------
   log_archive_format    string arch_%t_%s_%r.arc
*/

-- [SQL*Plus — SYSDBA] 아카이브 파일명 형식 변경
ALTER SYSTEM SET log_archive_format = '%T_%S_%R.arc' SCOPE=SPFILE;

/*
 [결과 예시]
   System altered.
   -> SCOPE=SPFILE로 설정했으므로, DB 재기동 후 실제 적용됨
*/


/* ==========================================================================
   3. ARCHIVELOG 모드 전환
   ==========================================================================
   ARCHIVELOG 모드 전환은 MOUNT 상태에서만 가능하다.
   절차: SHUTDOWN IMMEDIATE -> STARTUP MOUNT -> ALTER DATABASE ARCHIVELOG -> OPEN
*/

/* --------------------------------------------------------------------------
   3-1. ARC 프로세스 미기동 상태 확인 (전환 전)
   --------------------------------------------------------------------------
   NOARCHIVELOG 상태이므로 arc 관련 백그라운드 프로세스는 존재하지 않음
*/

/*
   # [oracle 계정 — Linux] arc 프로세스 존재 여부 확인
   ps -ef | grep arc

   [결과 예시]
   oracle   20372 14688  0 16:51 pts/5    00:00:00 grep --color=auto arc
   -> arc 관련 백그라운드 프로세스가 없음 (NOARCHIVELOG 상태이므로 정상)
*/

/* --------------------------------------------------------------------------
   3-2. DB 종료 후 MOUNT 상태로 재기동
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 1단계: DB 정상 종료
SHUTDOWN IMMEDIATE;

/*
 [결과 예시]
   Database closed.
   Database dismounted.
   ORACLE instance shut down.
*/

-- [SQL*Plus — SYSDBA] 2단계: MOUNT 상태로 기동 (OPEN 아님)
STARTUP MOUNT;

/*
 [결과 예시]
   ORACLE instance started.
   Total System Global Area 1140849904 bytes
   ...
   Database mounted.
*/

-- [SQL*Plus — SYSDBA] 인스턴스 상태가 MOUNTED인지 확인
SELECT status FROM v$instance;

/*
 [결과 예시]
   STATUS
   ------------
   MOUNTED
   -> Database opened. 메시지가 없어야 정상 (MOUNT 상태)
*/

/* --------------------------------------------------------------------------
   3-3. ARCHIVELOG 모드 전환 및 OPEN
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 3단계: ARCHIVELOG 모드 전환
ALTER DATABASE ARCHIVELOG;

/*
 [결과 예시]
   Database altered.
*/

-- [SQL*Plus — SYSDBA] 4단계: DB 오픈
ALTER DATABASE OPEN;

/*
 [결과 예시]
   Database altered.
*/

/* --------------------------------------------------------------------------
   3-4. 전환 결과 검증
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] ARCHIVE LOG LIST로 전환 결과 확인
ARCHIVE LOG LIST;

/*
 [결과 예시 — ARCHIVELOG 전환 후]
   Database log mode              Archive Mode
   Automatic archival             Enabled
   Archive destination            /home/oracle/arch2
   Oldest online log sequence     2
   Next log sequence to archive   4
   Current log sequence           4
   -> Automatic archival = Enabled로 변경됨
*/

-- [SQL*Plus — SYSDBA] v$database로 LOG_MODE 재확인
SELECT name, log_mode FROM v$database;

/*
 [결과 예시]
   NAME      LOG_MODE
   --------- ------------
   ORCL      ARCHIVELOG
   -> ARCHIVE LOG LIST의 Archive destination은 log_archive_dest_n 중
      대표 경로 하나만 표시되지만, 실제 아카이브 로그는
      1번/2번 경로 모두에 생성됨
*/


/* ==========================================================================
   4. ARC 프로세스 및 v$log 상태 확인
   ==========================================================================
   ARCHIVELOG 모드 전환 후, ARC 백그라운드 프로세스 기동 여부와
   온라인 리두 로그 그룹의 ARC(아카이브 여부) 컬럼을 확인한다.
*/

/* --------------------------------------------------------------------------
   4-1. ARC 백그라운드 프로세스 확인
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] ARC 프로세스 최대 개수 파라미터 확인
SHOW PARAMETER log_archive_max_process;

/*
 [결과 예시]
   NAME                       TYPE    VALUE
   -------------------------- ------- ------------------------------
   log_archive_max_processes  integer 4
*/

/*
   # [oracle 계정 — Linux] OS에서 arc 프로세스 확인
   ps -ef | grep arc

   [결과 예시]
   oracle  7507    1  0 00:40 ?       00:00:00 ora_arc0_orcl
   oracle  7512    1  0 00:40 ?       00:00:00 ora_arc1_orcl
   oracle  7514    1  0 00:40 ?       00:00:00 ora_arc2_orcl
   oracle  7516    1  0 00:40 ?       00:00:00 ora_arc3_orcl
   -> log_archive_max_processes 값(4)만큼
      ora_arc0_orcl ~ ora_arc3_orcl 프로세스가 기동됨
*/

/* --------------------------------------------------------------------------
   4-2. 온라인 리두 로그 상태(v$log) 확인
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 온라인 리두 로그 그룹별 ARC 컬럼 확인
SELECT * FROM v$log;

/*
 [결과 예시]
       GROUP#    THREAD#  SEQUENCE#      BYTES  BLOCKSIZE    MEMBERS ARC STATUS           FIRST_CHANGE# FIRST_TIME         NEXT_CHANGE#
   ---------- ---------- ---------- ---------- ---------- ---------- --- ---------------- ------------- ------------------ ------------
            1          1          4   52428800        512          1 NO  CURRENT                3383245 11-JUN-26            1.8447E+19
            2          1          2   52428800        512          1 YES INACTIVE               3383239 11-JUN-26               3383242
            3          1          3   52428800        512          1 YES INACTIVE               3383242 11-JUN-26               3383245
   -> ARCHIVELOG 모드 전환 후에는 ARC 컬럼이 YES로 표시되는 그룹이 존재
      (이미 아카이빙된 INACTIVE 그룹)
   -> CURRENT 상태인 그룹은 아직 아카이빙 대상이 아니므로 ARC = NO로 표시됨
*/


/* ==========================================================================
   5. 로그 스위치와 아카이브 로그 생성 확인
   ==========================================================================
   ALTER SYSTEM SWITCH LOGFILE / ARCHIVE LOG CURRENT로
   아카이브 로그 생성을 유도하고, 디렉토리 및 v$archived_log로 확인한다.
*/

/* --------------------------------------------------------------------------
   5-1. 로그 스위치를 통한 아카이브 로그 생성
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 로그 스위치 발생
ALTER SYSTEM SWITCH LOGFILE;

/*
 [결과 예시]
   System altered.
*/

-- [SQL*Plus — SYSDBA] 로그 스위치 1회 추가 발생 (이전 그룹 아카이빙 유도)
/

/*
 [결과 예시]
   System altered.
*/

/*
   # [oracle 계정 — Linux] 아카이브 로그 파일 생성 확인
   ls /home/oracle/arch1 /home/oracle/arch2

   [결과 예시]
   /home/oracle/arch1:
   0001_0000000004_1235671894.arc  0001_0000000005_1235671894.arc

   /home/oracle/arch2:
   0001_0000000004_1235671894.arc  0001_0000000005_1235671894.arc
   -> 두 경로(arch1, arch2) 모두에 동일한 아카이브 로그 파일이 생성됨
*/

/* --------------------------------------------------------------------------
   5-2. v$archived_log / v$log 상태 재확인
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 생성된 아카이브 로그 목록 확인
SELECT sequence#, name, first_time, next_time, applied
FROM v$archived_log;

/*
 [결과 예시]
   -> sequence#별로 아카이브 로그 파일명과 생성 시각, applied 여부 표시
   -> 환경에 따라 row 수와 시퀀스 값이 다를 수 있음
*/

-- [SQL*Plus — SYSDBA] 리두 로그 그룹별 상태 재확인
SELECT a.group#, b.sequence#, a.member, b.bytes/1024/1024 mb,
       b.status, b.archived, b.first_change#, b.next_change#
FROM v$logfile a, v$log b
WHERE a.group# = b.group#
ORDER BY 1,2;

/*
 [결과 예시]
   -> 로그 스위치로 이동한 그룹의 ARCHIVED 값이 YES로 변경됨을 확인
*/

/* --------------------------------------------------------------------------
   5-3. 현재 리두 로그 강제 아카이빙
   --------------------------------------------------------------------------
   CURRENT 상태인 그룹은 로그 스위치만으로는 아카이빙되지 않으므로
   ARCHIVE LOG CURRENT로 강제 아카이빙
*/

-- [SQL*Plus — SYSDBA] 현재 리두 로그까지 강제 아카이빙
ALTER SYSTEM ARCHIVE LOG CURRENT;

/*
 [결과 예시]
   System altered.
   -> 직전까지 CURRENT였던 그룹이 아카이빙됨
*/


/* ==========================================================================
   6. Online (Hot) Backup 수행
   ==========================================================================
   ARCHIVELOG 모드에서는 DB를 OPEN 상태로 유지한 채
   BEGIN BACKUP / END BACKUP 구간 동안 데이터파일을
   OS 레벨에서 복사할 수 있다.

   항목              설명
   ---------------   ----------------------------------------------------
   BEGIN BACKUP       데이터파일 헤더의 체크포인트 SCN 갱신 중지,
                      백업 시작 시점의 SCN 고정
   END BACKUP         SCN 갱신을 정상 상태로 복구
   -> 이 구간 동안에도 DB는 정상적으로 트랜잭션 처리
   -> 발생한 변경 사항은 리두 로그/아카이브 로그를 통해 복구 시점에 적용
*/

/* --------------------------------------------------------------------------
   6-1. 백업 전 데이터파일 체크포인트 SCN 확인
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 백업 전 데이터파일별 checkpoint_change# 확인
SELECT file#, name, checkpoint_change#, status
FROM v$datafile;

/*
 [결과 예시]
   -> 각 데이터파일의 현재 checkpoint_change#(SCN) 확인
   -> 환경에 따라 file#, checkpoint_change# 값은 다를 수 있음
*/

/* --------------------------------------------------------------------------
   6-2. BEGIN BACKUP → OS 파일 복사 → END BACKUP
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 1단계: 온라인 백업 시작 (SCN 갱신 중지)
ALTER DATABASE BEGIN BACKUP;

/*
 [결과 예시]
   Database altered.
*/

/*
   # [oracle 계정 — Linux] 2단계: 데이터파일 OS 레벨 복사
   cp -v /u01/app/oracle/oradata/ORCL/* /home/oracle/backup/open_bkp/
*/

-- [SQL*Plus — SYSDBA] 3단계: 온라인 백업 종료 (SCN 갱신 정상화)
ALTER DATABASE END BACKUP;

/*
 [결과 예시]
   Database altered.
*/

/* --------------------------------------------------------------------------
   6-3. 컨트롤 파일 별도 백업
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 4단계: 컨트롤 파일을 지정 경로로 백업
ALTER DATABASE BACKUP CONTROLFILE TO '/home/oracle/backup/open_bkp/control_20260615.ctl';

/*
 [결과 예시]
   Database altered.
   -> 파일명의 날짜 부분은 실습 수행 일자로 대체 가능
*/


/* ==========================================================================
   7. 백업 상태 확인 — v$backup
   ==========================================================================
   v$backup 뷰를 통해 각 데이터파일이 현재
   BEGIN BACKUP ~ END BACKUP 구간에 있는지(ACTIVE)
   또는 정상 상태(NOT ACTIVE)인지 확인한다.

   상태          설명
   -----------   ------------------------------------------------------------
   NOT ACTIVE    END BACKUP이 정상적으로 수행되어 백업 모드가 해제된 상태
   ACTIVE        END BACKUP이 아직 수행되지 않은 상태.
                 백업 도중 비정상 종료된 경우 ACTIVE로 남을 수 있음
                 (이 경우 ALTER DATABASE END BACKUP을 다시 수행하여 해제)
*/

/* --------------------------------------------------------------------------
   7-1. v$backup으로 데이터파일별 백업 모드 상태 확인
   --------------------------------------------------------------------------
*/

-- [SQL*Plus — SYSDBA] 데이터파일별 백업 모드 상태(ACTIVE/NOT ACTIVE) 확인
SELECT a.file#, a.name, a.checkpoint_change#, b.status, b.change#,
       TO_CHAR(b.time, 'yyyy-mm-dd hh24:mi:ss.sssss') time
FROM v$datafile a, v$backup b
WHERE a.file# = b.file#;

/*
 [결과 예시]
        FILE# NAME                                               CHECKPOINT_CHANGE# STATUS                CHANGE# TIME
   ---------- -------------------------------------------------- ------------------ ------------------ ---------- -------------------------
            1 /u01/app/oracle/oradata/ORCL/system01.dbf                     3393855 NOT ACTIVE            3393855 2026-06-15 17:21:55.62515
            2 /u01/app/oracle/oradata/ORCL/audit_tbs01.dbf                  3393855 NOT ACTIVE            3393855 2026-06-15 17:21:55.62515
            3 /u01/app/oracle/oradata/ORCL/sysaux01.dbf                     3393855 NOT ACTIVE            3393855 2026-06-15 17:21:55.62515
            4 /u01/app/oracle/oradata/ORCL/undotbs01.dbf                    3393855 NOT ACTIVE            3393855 2026-06-15 17:21:55.62515
            7 /u01/app/oracle/oradata/ORCL/users01.dbf                      3393855 NOT ACTIVE            3393855 2026-06-15 17:21:55.62515
           11 /u01/app/oracle/oradata/ORCL/userdata01.dbf                   3393855 NOT ACTIVE            3393855 2026-06-15 17:21:55.62515
   -> 모든 데이터파일이 NOT ACTIVE -> END BACKUP이 정상 수행되어
      백업 모드가 해제된 상태
   -> 만약 STATUS = ACTIVE인 파일이 남아있다면
      ALTER DATABASE END BACKUP을 다시 수행하여 해제 필요
*/

/* --------------------------------------------------------------------------
   7-2. 백업 구간 동안 생성된 아카이브 로그 확인
   --------------------------------------------------------------------------
*/

/*
   # [oracle 계정 — Linux] 백업 구간 동안 생성된 아카이브 로그 확인
   ls /home/oracle/arch1 /home/oracle/arch2

   [결과 예시]
   /home/oracle/arch1:
   0001_0000000004_1235671894.arc  0001_0000000005_1235671894.arc  0001_0000000006_1235671894.arc

   /home/oracle/arch2:
   0001_0000000004_1235671894.arc  0001_0000000005_1235671894.arc  0001_0000000006_1235671894.arc
   -> 백업 구간 동안 변경 사항이 거의 없었던 경우,
      아카이브 로그 목록에 변화가 없을 수 있음
*/


/* ==========================================================================
   8. 관련 뷰 정리
   ==========================================================================
*/

/*
   뷰 / 명령어            용도
   ---------------------- --------------------------------------------------
   ARCHIVE LOG LIST        현재 로그 모드, 아카이브 경로, 시퀀스 확인
   v$database              log_mode (ARCHIVELOG / NOARCHIVELOG) 확인
   v$log                   온라인 리두 로그 그룹 상태 및 ARC(아카이브 여부)
   v$logfile               리두 로그 그룹의 멤버(파일) 정보
   v$archived_log          생성된 아카이브 로그 목록
   v$datafile              데이터파일별 checkpoint_change# 및 상태
   v$backup                데이터파일별 BEGIN/END BACKUP 상태
                           (ACTIVE/NOT ACTIVE)
   v$instance              인스턴스 현재 상태(STATUS) 확인
*/


/* ==========================================================================
   9. 주요 명령어 정리
   ==========================================================================
*/

/*
   명령어                                          설명
   ----------------------------------------------- ---------------------------
   ARCHIVE LOG LIST                                 현재 아카이브 모드/경로/시퀀스
   ALTER SYSTEM SET log_archive_dest_n=... SCOPE=SPFILE
                                                     아카이브 경로 설정
                                                     (mandatory/optional)
   ALTER SYSTEM SET log_archive_format=... SCOPE=SPFILE
                                                     아카이브 파일명 형식 설정
   SHUTDOWN IMMEDIATE                               DB 정상 종료
   STARTUP MOUNT                                    MOUNT 상태로 기동
   ALTER DATABASE ARCHIVELOG                        ARCHIVELOG 모드 전환
   ALTER DATABASE OPEN                              DB 오픈
   ALTER SYSTEM SWITCH LOGFILE                      로그 스위치 수동 발생
   ALTER SYSTEM ARCHIVE LOG CURRENT                 현재 리두 로그 강제 아카이빙
   ALTER DATABASE BEGIN BACKUP                      온라인 백업 시작 (SCN 고정)
   ALTER DATABASE END BACKUP                        온라인 백업 종료 (SCN 해제)
   ALTER DATABASE BACKUP CONTROLFILE TO '경로'      컨트롤 파일 별도 백업
*/


/* ==========================================================================
   10. 실습 핵심 요약
   ==========================================================================
*/

/*
   주제                  핵심 포인트
   --------------------- ------------------------------------------------------
   ARCHIVELOG 전환        MOUNT 상태에서만 가능 — SHUTDOWN IMMEDIATE ->
                          STARTUP MOUNT -> ALTER DATABASE ARCHIVELOG -> OPEN
   파라미터 설정          log_archive_dest_1(mandatory)/dest_2(optional)
                          이중화 + log_archive_format 설정 ->
                          SCOPE=SPFILE이므로 재기동 후 적용
   전환 후 확인           ARC 프로세스(ora_arc0~3) 기동 여부 +
                          v$log.ARC 컬럼으로 아카이빙 여부 이중 확인
   로그 스위치/아카이빙   ALTER SYSTEM SWITCH LOGFILE,
                          ALTER SYSTEM ARCHIVE LOG CURRENT로
                          아카이브 로그 생성 유도 후
                          디렉토리·v$archived_log로 확인
   Online (Hot) Backup    BEGIN BACKUP ~ END BACKUP 구간에
                          OS 레벨 파일 복사, DB는 계속 OPEN 상태로
                          트랜잭션 처리
   백업 상태 확인         v$backup.STATUS — ACTIVE(백업 모드 진행 중) /
                          NOT ACTIVE(정상), 컨트롤 파일은
                          BACKUP CONTROLFILE TO로 별도 백업
*/
