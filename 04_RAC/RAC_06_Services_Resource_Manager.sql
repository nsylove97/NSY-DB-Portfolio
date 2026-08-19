/* ==============================================================================
   RAC 06: Services & Resource Manager — 부하 분산 · HA · 자원 제어
   Blog  : https://nsylove97.tistory.com/129
   GitHub: https://github.com/nsylove97/NSY-DB-Portfolio
   ------------------------------------------------------------------------------
   실습 환경
   OS           : Oracle Linux 7.9 (VMware Virtual Machine)
   DB           : Oracle Database 19c
   Grid         : Oracle Grid Infrastructure 19c
   구성           : 2 Node RAC (VM1 · VM2)
   공유 스토리지    : ASM (+DATA / +FRA / +REDO / +OCR)
   네트워크         : Public (NAT) · Private (Host-only) · VIP · SCAN
   Catalog DB   : rcatdb (단일 인스턴스, 2daydba VM)
   VM1/VM2 초기 구성 참조 : ASM 실습 01
   RAC 구축 참조          : RAC 02

   노드 정보
   +----------+----------------------+----------------------------------------+
   | 구분       | Hostname             | 비고                                     |
   +----------+----------------------+----------------------------------------+
   | Node1     | oelsvr1.localdomain  | orcl1 인스턴스                            |
   | Node2     | oelsvr2.localdomain  | orcl2 인스턴스                            |
   | SCAN      | oelsvr-scan          | 클라이언트 접속용 SCAN 이름                    |
   +----------+----------------------+----------------------------------------+

   디렉토리 정보
   ORACLE_BASE : /u01/app/oracle
   ORACLE_HOME : /u01/app/oracle/product/19.3.0/dbhome
   DB_NAME     : orcl (orcl1 / orcl2 인스턴스)
   ------------------------------------------------------------------------------
   목차
   1.    Traditional vs Grid Workload Dispatching 비교
   2.    RAC Service 개념 — 세션 묶음 · 자동 분배 · 자동 이동
   2-1.  app_svc 서비스 생성 및 기동
   2-2.  서비스 상태 확인
   3.    Preferred / Available 인스턴스 역할 구분
   3-1.  batch_svc 서비스 생성 (Preferred/Available 지정)
   4.    Service 구성 방식 3가지 — Active/Spare · Active/Symmetric · Active/Asymmetric
   5.    Service Attributes — Network Name · Load Balancing Goal · Failover
   5-1.  app_svc/batch_svc 속성 조회
   6.    Failover Type — NONE · SHORT · LONG
   7.    CTF 실습 — 인스턴스 중단 후 자동 재연결 확인
   7-1.  장시간 SELECT 테스트용 테이블 생성
   7-2.  클라이언트 tnsnames.ora 설정 (app_svc)
   7-3.  app_svc로 접속 확인 (orcl2)
   7-4.  orcl2 강제 종료
   7-5.  재접속 후 자동 전환 확인 (orcl1)
   8.    TAF 실습 — 쿼리 중단 없는 인스턴스 인계
   8-1.  tnsnames.ora TAF 설정 추가
   8-2.  장시간 SELECT 실행 중 orcl2 강제 종료
   8-3.  TAF 이벤트 확인
   9.    TAC 실습 — 트랜잭션 연속성 확인
   9-1.  Application Continuity 대상 속성 확인
   9-2.  Service를 TAC 대상 속성으로 재설정
   9-3.  변경 결과 재확인
   9-4.  트랜잭션 진행 중 장애 발생 시나리오
   9-5.  재접속 후 커밋 결과 확인
   10.   srvctl relocate service 명령 활용
   10-1. batch_svc 수동 부하 이동
   11.   Service Goodness — MMNL과 gv$servicemetric
   11-1. gv$servicemetric 조회
   12.   Resource Manager — Consumer Group과 CPU 할당
   12-1. 기존 Consumer Group 존재 확인
   12-2. 활성화된 Pending Area 초기화
   12-3. Resource Plan 생성 및 CPU 비율 지정
   13.   Pending Area — 설정 적용 절차
   13-1. 검증 및 반영
   13-2. Plan 활성화 — SID 전체 적용
   13-3. 적용 확인
   14.   원상 복구 — 생성한 Service 및 Resource Manager Plan
   14-1. Service 중지 및 삭제
   14-2. Resource Manager Plan 비활성화
   14-3. BATCH_GROUP을 참조하는 모든 Plan 확인
   14-4. Pending Area 초기화
   14-5. Plan Directive 개별 삭제 후 DAYTIME_PLAN 삭제
   15.   주요 명령어 정리
============================================================================== */


/* ==============================================================================
   1. Traditional vs Grid Workload Dispatching 비교
   ------------------------------------------------------------------------------
   RAC 02~05편까지는 orcl1 / orcl2 두 인스턴스에 직접 접속해 실습했다.
   실무에서는 애플리케이션이 인스턴스를 직접 지정하지 않고, Service 단위로
   접속해 부하 분산과 장애 조치를 오라클에 위임한다.

   +---------------+------------------------------------+---------------------------------------------+
   | 구분          | Traditional (Instance 직접 접속)      | Grid Workload Dispatching (Service 기반)      |
   +---------------+------------------------------------+---------------------------------------------+
   | 접속 대상       | SID 또는 특정 인스턴스                  | Service Name (논리적 그룹)                       |
   | 부하 분산       | 클라이언트가 tnsnames LOAD_BALANCE로 처리  | 오라클이 인스턴스 부하(Goodness) 기준으로 분배            |
   | 장애 시 동작    | 접속 끊김, 애플리케이션이 재접속 로직 직접 구현    | Service가 생존 인스턴스로 자동 Relocate              |
   | 업무 분리       | 불가능 (인스턴스 단위로만 구분)             | 가능 (OLTP/Batch 등 업무별 Service 분리)           |
   +---------------+------------------------------------+---------------------------------------------+

   Service는 하나 이상의 인스턴스에 매핑되는 논리적 워크로드 단위다.
   애플리케이션은 SID가 아니라 Service Name으로만 접속하므로, 인스턴스
   추가·제거·장애가 발생해도 접속 문자열을 바꿀 필요가 없다.
   RAC 03편의 srvctl status database가 인스턴스 단위 상태였다면, 이번 편의
   srvctl status service는 업무 단위 상태를 보여준다.
============================================================================== */


/* ==============================================================================
   2. RAC Service 개념 — 세션 묶음 · 자동 분배 · 자동 이동
   ============================================================================== */

/* ------------------------------------------------------------------------------
   2-1. app_svc 서비스 생성 및 기동
   ※ Preferred 인스턴스 2개(orcl1,orcl2) 모두 지정해 양 노드에서 동시에
      서비스를 제공하는 Active/Symmetric 구성으로 만든다.
   ※ -policy AUTOMATIC이면 Preferred 인스턴스 중 장애가 발생한 인스턴스를
      Clusterware가 자동으로 다른 Preferred/Available 인스턴스로 전환한다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — oracle, app_svc 서비스 생성]
/*
[oracle@oelsvr1]$ srvctl add service -db orcl -service app_svc \
  -preferred orcl1,orcl2 \
  -policy AUTOMATIC
*/

-- [oelsvr1 — oracle, app_svc 서비스 기동]
/*
[oracle@oelsvr1]$ srvctl start service -db orcl -service app_svc
*/

/* ------------------------------------------------------------------------------
   2-2. 서비스 상태 확인
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — oracle, 상태 확인]
/*
[oracle@oelsvr1]$ srvctl status service -db orcl -service app_svc

[결과]
Service app_svc is running on instance(s) orcl1,orcl2
-> app_svc가 orcl1 · orcl2 양쪽 인스턴스에서 동시에 기동됨을 확인
*/


/* ==============================================================================
   3. Preferred / Available 인스턴스 역할 구분
   ------------------------------------------------------------------------------
   +-------------+---------------------------------------+--------------------------+
   | 역할        | 정의                                    | 동작                       |
   +-------------+---------------------------------------+--------------------------+
   | Preferred   | Service가 평상시 실행되어야 할 인스턴스        | 정상 상태에서 항상 Active   |
   | Available   | Preferred 장애 시 대체로 투입되는 인스턴스     | 평상시 미실행, 장애 시에만 기동 |
   +-------------+---------------------------------------+--------------------------+

   Preferred와 Available을 구분하는 이유는 업무 성격에 따라 평상시 자원을
   어느 인스턴스에 집중할지 명시적으로 통제하기 위함이다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   3-1. batch_svc 서비스 생성 (Preferred/Available 지정)
   ※ batch_svc는 평소 orcl1에서만 실행되며, orcl1이 다운되면 orcl2가
      대신 서비스를 이어받는 Active/Spare 구성이다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — oracle, Preferred/Available 지정 예시]
/*
[oracle@oelsvr1]$ srvctl add service -db orcl -service batch_svc \
  -preferred orcl1 \
  -available orcl2 \
  -policy AUTOMATIC
*/


/* ==============================================================================
   4. Service 구성 방식 3가지 — Active/Spare · Active/Symmetric · Active/Asymmetric
   ------------------------------------------------------------------------------
   +------------------------+-----------------------------------------------+----------------------------------------------+
   | 구성 방식              | 정의                                            | 예시                                            |
   +------------------------+-----------------------------------------------+----------------------------------------------+
   | Active/Spare           | 한 인스턴스만 Preferred, 나머지는 Available(대기)  | batch_svc — Preferred orcl1, Available orcl2  |
   | Active/Symmetric       | 모든 인스턴스가 동일하게 Preferred                | app_svc — Preferred orcl1,orcl2 (동등 분산)     |
   | Active/Asymmetric      | 인스턴스별 Preferred/Available 비중이 다름         | 3-Node 이상에서 특정 노드에 가중치 부여              |
   +------------------------+-----------------------------------------------+----------------------------------------------+

   2 Node RAC 환경에서는 Active/Spare(batch_svc)와 Active/Symmetric(app_svc)
   두 방식이 가장 흔하다. Active/Asymmetric은 노드 수가 늘어날 때 업무 중요도에
   따라 인스턴스를 차등 배정하는 방식이며, 본 실습 환경(2 Node)에서는 개념만 확인한다.
   ============================================================================== */


/* ==============================================================================
   5. Service Attributes — Network Name · Load Balancing Goal · Failover
   ============================================================================== */

/* ------------------------------------------------------------------------------
   5-1. app_svc/batch_svc 속성 조회
   ※ 앞서 옵션을 명시하지 않고 생성했으므로, GOAL/FAILOVER_TYPE 등은
      모두 기본값(NONE/LONG)으로 조회된다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1]
SELECT name, network_name, goal, clb_goal, failover_type, failover_method
FROM dba_services
WHERE name IN ('app_svc','batch_svc');

/* [결과]
NAME                 NETWORK_NAME         GOAL         CLB_G FAILOVER_TYPE        FAILOVER_METHOD
-------------------- -------------------- ------------ ----- -------------------- --------------------
app_svc              app_svc              NONE         LONG
batch_svc            batch_svc            NONE         LONG
-> 두 서비스 모두 Load Balancing Goal과 Failover Type이 기본값(NONE)으로 설정되어 있음
*/

/* [참고] 각 속성의 의미
   +----------------------+---------------------------------------------------+
   | 속성                 | 의미                                                |
   +----------------------+---------------------------------------------------+
   | Network Name         | 클라이언트가 tnsnames에서 접속하는 서비스 이름           |
   | Load Balancing Goal  | SERVICE_TIME(응답 시간 기준) 또는 THROUGHPUT(처리량 기준) 분배 |
   | Failover Type        | 장애 시 세션·쿼리 인계 범위 (NONE/SESSION/SELECT)      |
   | Failover Method      | BASIC(재연결) 또는 PRECONNECT(예비 연결 유지)          |
   +----------------------+---------------------------------------------------+
   OLTP 성격의 app_svc는 SERVICE_TIME 기준으로 응답 속도가 빠른 인스턴스에
   우선 배분하고, 배치성 batch_svc는 Goal을 지정하지 않아 단일 인스턴스
   집중 처리를 유지한다.
*/


/* ==============================================================================
   6. Failover Type — NONE · SHORT · LONG
   ------------------------------------------------------------------------------
   +-----------------+---------------------------------------+--------------------------+
   | Failover Type   | 의미                                    | 적용 시나리오              |
   +-----------------+---------------------------------------+--------------------------+
   | NONE            | 장애 시 세션 인계 없음, 애플리케이션이 재접속  | 배치 작업 — 재실행 비용이 낮은 경우 |
   | SESSION         | 세션만 재연결, 진행 중이던 커서는 유지되지 않음 | 단순 조회 위주 OLTP        |
   | SELECT          | 진행 중이던 SELECT 커서까지 재개          | 장시간 조회가 많은 리포팅성 업무 |
   +-----------------+---------------------------------------+--------------------------+

   SHORT/LONG은 CTF(Connection Time Failover)에서 재접속 재시도 간격을 구분하는
   개념으로, SHORT는 빠른 재시도(수 초 이내), LONG은 여유 있는 재시도 주기를 의미한다.
   값이 클수록 인계 범위는 넓어지지만 오라클이 유지해야 하는 상태 정보도 늘어나므로,
   업무 성격에 맞는 최소한의 Failover Type을 선택하는 것이 원칙이다.
   ============================================================================== */


/* ==============================================================================
   7. CTF 실습 — 인스턴스 중단 후 자동 재연결 확인
   ------------------------------------------------------------------------------
   ※ CTF(Connection Time Failover)는 접속 시점에 장애를 감지해 살아있는
      인스턴스로 자동 재연결해주는 기능이다. 진행 중이던 세션이나 쿼리를
      이어주지는 않으며, 새로 접속을 시도할 때만 동작한다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   7-1. 장시간 SELECT 테스트용 테이블 생성
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 장시간 SELECT 테스트용 테이블 생성]
CREATE TABLE large_tab AS
SELECT * FROM all_objects, (SELECT LEVEL FROM dual CONNECT BY LEVEL <= 20);

SELECT COUNT(*) FROM large_tab;

/* [결과]
  COUNT(*)
----------
   1426720
-> large_tab에 약 142만 건의 행이 생성됨
*/

/* ------------------------------------------------------------------------------
   7-2. 클라이언트 tnsnames.ora 설정 (app_svc)
   ※ SCAN 이름(oelsvr-scan)으로 접속해야 CTF가 인스턴스 장애 시
      살아있는 노드로 자동 라우팅할 수 있다.
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — tnsnames.ora, app_svc 접속 설정]
/*
APP_SVC =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oelsvr-scan)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = app_svc)))
*/

/* ------------------------------------------------------------------------------
   7-3. app_svc로 접속 확인 (orcl2)
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — SQL*Plus, app_svc로 접속]
SELECT instance_name FROM v$instance;

/* [결과]
INSTANCE_NAME
----------------
orcl2
-> Goodness 기준으로 orcl2 인스턴스가 세션을 처리 중
*/

/* ------------------------------------------------------------------------------
   7-4. orcl2 강제 종료
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — orcl2를 강제 종료해 CTF 유도]
SHUTDOWN ABORT;

/* ------------------------------------------------------------------------------
   7-5. 재접속 후 자동 전환 확인 (orcl1)
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — 재접속 시도]
SELECT instance_name FROM v$instance;

/* [결과]
INSTANCE_NAME
----------------
orcl1
-> app_svc 경유 접속이므로 별도 로직 없이 orcl1로 자동 전환됨
-> CTF는 접속 시점에만 동작하며, 진행 중이던 쿼리 자체를 이어주지는 않음
*/


/* ==============================================================================
   8. TAF 실습 — 쿼리 중단 없는 인스턴스 인계
   ------------------------------------------------------------------------------
   ※ TAF(Transparent Application Failover)는 장애 발생 시점에 진행 중이던
      SELECT 커서를 다른 인스턴스에서 재개해주는 기능이다. 클라이언트
      애플리케이션 코드 수정 없이 tnsnames의 FAILOVER_MODE 설정만으로
      동작하며, DML 트랜잭션은 대상이 아니다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   8-1. tnsnames.ora TAF 설정 추가
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — tnsnames.ora, TAF 설정 추가]
/*
APP_SVC =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oelsvr-scan)(PORT = 1521))
    (CONNECT_DATA =
      (SERVICE_NAME = app_svc)
      (FAILOVER_MODE =
        (TYPE = SELECT)
        (METHOD = BASIC)
        (RETRIES = 20)
        (DELAY = 3))))
*/

/* ------------------------------------------------------------------------------
   8-2. 장시간 SELECT 실행 중 orcl2 강제 종료
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — 장시간 SELECT 실행 중 orcl2 강제 종료]
SELECT /*+ NO_INDEX */ COUNT(*) FROM large_tab;
-- 실행 도중 oelsvr2에서 orcl2 SHUTDOWN ABORT

/* [결과] TAF 동작 후 결과 정상 반환
  COUNT(*)
----------
   1426720
-> 인스턴스 전환이 발생했음에도 세션이 끊기지 않고 COUNT 결과가 정상 반환됨
*/

/* ------------------------------------------------------------------------------
   8-3. TAF 이벤트 확인
   ------------------------------------------------------------------------------ */
-- [TAF 이벤트 확인]
SELECT failover_type, failover_method, failed_over
FROM v$session
WHERE username = 'SYS';

/* [결과]
FAILOVER_TYPE  FAILOVER_METHOD  FAILED_OVER
-------------- ---------------- -----------
SELECT         BASIC            YES
-> FAILED_OVER = YES는 세션이 실제로 인스턴스 전환을 겪었음을 의미
-> DML(INSERT/UPDATE/DELETE) 중이던 트랜잭션은 TAF로 인계되지 않으며,
   커밋되지 않은 변경분은 롤백된다 — 이 한계를 넘는 것이 다음 TAC의 목적
*/


/* ==============================================================================
   9. TAC 실습 — 트랜잭션 연속성 확인
   ------------------------------------------------------------------------------
   ※ TAC(Transparent Application Continuity)는 DML/트랜잭션 구간의 장애까지
      처리하는 기능이다. 오라클 드라이버가 요청을 기록해두었다가 장애 발생 시
      커밋 성공 여부를 판단해 중복 실행 없이 재현(Replay)한다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   9-1. Application Continuity 대상 속성 확인
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. Application Continuity 대상 Service 확인]
SELECT name, aq_ha_notifications, failover_type,
       failover_restore, drain_timeout
FROM dba_services
WHERE name = 'app_svc';

/* [결과]
NAME                 AQ_ FAILOVER_TYPE        FAILOV DRAIN_TIMEOUT
-------------------- --- -------------------- ------ -------------
app_svc              NO                       NONE               0
-> 현재 app_svc는 FAILOVER_TYPE이 NONE이므로 TAC를 실습하려면
   Service 속성을 먼저 변경해야 함
*/

/* ------------------------------------------------------------------------------
   9-2. Service를 TAC 대상 속성으로 재설정
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — oracle, TAC 대상 속성으로 Service 재설정]
/*
[oracle@oelsvr1]$ srvctl modify service -d orcl -s app_svc \
  -failovertype transaction \
  -commit_outcome true \
  -drain_timeout 180
*/

/* ------------------------------------------------------------------------------
   9-3. 변경 결과 재확인
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 변경 결과 재확인]
SELECT name, aq_ha_notifications, failover_type,
       failover_restore, drain_timeout
FROM dba_services
WHERE name = 'app_svc';

/* [결과]
NAME                 AQ_ FAILOVER_TYPE        FAILOV DRAIN_TIMEOUT
-------------------- --- -------------------- ------ -------------
app_svc              NO  TRANSACTION                 180
-> FAILOVER_TYPE이 TRANSACTION으로, DRAIN_TIMEOUT이 180으로 변경됨
*/

/* ------------------------------------------------------------------------------
   9-4. 트랜잭션 진행 중 장애 발생 시나리오
   ------------------------------------------------------------------------------ */
-- [oelsvr2 — SQL*Plus, sys@app_svc. large_tab을 이용한 트랜잭션 진행 중 COMMIT 직전 orcl2 장애 발생]
UPDATE large_tab SET "LEVEL" = "LEVEL" + 1 WHERE ROWNUM = 1;
COMMIT;
-- COMMIT 응답 도착 전 oelsvr2에서 orcl2 SHUTDOWN ABORT 발생 가정

/* ------------------------------------------------------------------------------
   9-5. 재접속 후 커밋 결과 확인
   ------------------------------------------------------------------------------ */
-- [재접속 후 재조회]
SELECT "LEVEL" FROM large_tab WHERE ROWNUM = 1;

/* [결과]
     LEVEL
----------
         2
-> COMMIT이 정상 수행되어 LEVEL 값이 2로 반영됨을 확인
-> FAILOVER_TYPE = TRANSACTION으로 설정된 Service만 TAC 대상이 되며,
   JDBC Replay Driver 또는 UCP(Universal Connection Pool) 조합에서 동작이 보장됨
-> TAF가 "쿼리를 이어준다"면 TAC는 "커밋 여부를 기억해 트랜잭션 정합성을
   보장한다"는 점에서 목적이 다름
*/


/* ==============================================================================
   10. srvctl relocate service 명령 활용
   ============================================================================== */

/* ------------------------------------------------------------------------------
   10-1. batch_svc 수동 부하 이동
   ※ relocate service는 장애가 아닌 계획된 부하 이동에 사용한다. 야간 배치
      전 특정 인스턴스로 Service를 몰아주는 등 운영 스케줄에 맞춰 수동
      조정할 때 활용한다.
   ------------------------------------------------------------------------------ */
-- [수동 부하 이동 — orcl1 → orcl2]
/*
[oracle@oelsvr1]$ srvctl relocate service -db orcl -service batch_svc \
  -oldinst orcl1 -newinst orcl2

[oracle@oelsvr1]$ srvctl status service -db orcl -service batch_svc

[결과]
Service batch_svc is running on instance(s) orcl2
-> batch_svc가 orcl1에서 orcl2로 정상 이동됨
*/

-- Service 삭제는 stop service로 먼저 중지한 뒤 remove service로 처리한다
-- srvctl remove service -db <DB명> -service <서비스명>


/* ==============================================================================
   11. Service Goodness — MMNL과 gv$servicemetric
   ============================================================================== */

/* ------------------------------------------------------------------------------
   11-1. gv$servicemetric 조회
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1]
SELECT inst_id, service_name, elapsedpercall, cpupercall, callspersec
FROM gv$servicemetric
WHERE service_name = 'app_svc'
ORDER BY inst_id;

/* [결과]
   INST_ID SERVICE_NAME          ELAPSEDPERCALL  CPUPERCALL  CALLSPERSEC
---------- -------------------- --------------- ----------- ------------
         1 app_svc                            0           0            0
         1 app_svc                            0           0            0
         2 app_svc                            0           0            0
         2 app_svc                            0           0            0
-> 인스턴스별로 두 행씩 조회되는 것은 gv$servicemetric이 짧은 주기와 긴
   주기 두 종류의 측정 구간(Short/Long Window)을 동시에 유지하기 때문
-> 결과가 모두 0인 것은 app_svc를 경유한 유의미한 트래픽이 아직 누적되지
   않았기 때문 — Goodness는 실제 부하가 발생한 이후에야 인스턴스 간
   차이가 반영됨
*/

/* [참고]
   Goodness는 각 인스턴스가 해당 Service를 얼마나 잘 처리하고 있는지를
   나타내는 내부 점수이며, MMNL(Metric-based Method for Node Load) 알고리즘이
   응답 시간·CPU 사용률 등을 종합해 산출한다. 신규 접속 요청은 Goodness가
   높은(부하가 적은) 인스턴스로 우선 라우팅된다.
   gv$servicemetric은 일정 주기(기본 60초)로 갱신되는 스냅샷이므로,
   순간적인 부하 변화보다는 추세 판단용으로 활용한다.
*/


/* ==============================================================================
   12. Resource Manager — Consumer Group과 CPU 할당
   ============================================================================== */

/* ------------------------------------------------------------------------------
   12-1. 기존 Consumer Group 존재 확인
   ※ APP_GROUP, BATCH_GROUP이 이미 생성되어 있으므로 CREATE_CONSUMER_GROUP
      단계는 건너뛰고 바로 Resource Plan 생성 단계로 진행한다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 기존 Consumer Group 존재 확인]
SELECT consumer_group FROM dba_rsrc_consumer_groups
WHERE consumer_group IN ('APP_GROUP','BATCH_GROUP');

/* [결과]
CONSUMER_GROUP
--------------------------------------------------------------------------------
BATCH_GROUP
APP_GROUP
-> 두 Consumer Group이 이미 존재함을 확인, 신규 생성 불필요
*/

/* ------------------------------------------------------------------------------
   12-2. 활성화된 Pending Area 초기화
   ※ 이전에 열려 있던 Pending Area가 남아있으면 새 CREATE_PENDING_AREA 호출
      시 오류가 발생하므로, 먼저 CLEAR로 비워둔다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 활성화된 Pending Area 초기화]
EXEC DBMS_RESOURCE_MANAGER.CLEAR_PENDING_AREA();

/* ------------------------------------------------------------------------------
   12-3. Resource Plan 생성 및 CPU 비율 지정
   ※ OTHER_GROUPS는 Oracle이 요구하는 필수 지시자로, 명시적으로 그룹이
      지정되지 않은 세션을 처리한다 — 반드시 하나의 Plan 안에 포함되어야 한다.
   ------------------------------------------------------------------------------ */
-- [Resource Plan 생성 및 CPU 비율 지정 — APP : Batch = 75% : 25%]
BEGIN
  DBMS_RESOURCE_MANAGER.CREATE_PENDING_AREA();

  DBMS_RESOURCE_MANAGER.CREATE_PLAN(
    plan    => 'DAYTIME_PLAN',
    comment => 'Business hours CPU allocation plan');

  DBMS_RESOURCE_MANAGER.CREATE_PLAN_DIRECTIVE(
    plan             => 'DAYTIME_PLAN',
    group_or_subplan => 'APP_GROUP',
    comment          => 'OLTP priority allocation',
    mgmt_p1          => 75);

  DBMS_RESOURCE_MANAGER.CREATE_PLAN_DIRECTIVE(
    plan             => 'DAYTIME_PLAN',
    group_or_subplan => 'BATCH_GROUP',
    comment          => 'Batch remaining allocation',
    mgmt_p1          => 25);

  DBMS_RESOURCE_MANAGER.CREATE_PLAN_DIRECTIVE(
    plan             => 'DAYTIME_PLAN',
    group_or_subplan => 'OTHER_GROUPS',
    comment          => 'Other sessions',
    mgmt_p1          => 0);
END;
/

/* [참고]
   Consumer Group은 세션을 업무 성격별로 분류하는 단위이며, Plan Directive가
   그룹별 CPU 비율(mgmt_p1)을 지정한다.
   Service와 Consumer Group을 매핑하면(DBMS_RESOURCE_MANAGER.SET_CONSUMER_GROUP_MAPPING),
   app_svc로 접속한 세션은 자동으로 APP_GROUP에, batch_svc로 접속한 세션은
   BATCH_GROUP에 편입되어 CPU가 75:25로 분배된다.
*/


/* ==============================================================================
   13. Pending Area — 설정 적용 절차
   ------------------------------------------------------------------------------
   ※ Resource Manager 설정은 CREATE_PENDING_AREA로 시작해 임시 작업 영역에서
      구성한 뒤, VALIDATE_PENDING_AREA로 구조적 오류(순환 참조, 비율 합계
      초과 등)를 점검하고, SUBMIT_PENDING_AREA로 실제 반영하는 3단계
      절차를 따른다. 검증 없이 바로 SUBMIT하면 잘못된 Plan이 그대로
      활성화될 위험이 있으므로 VALIDATE 단계를 생략하지 않는다.
   ============================================================================== */

/* ------------------------------------------------------------------------------
   13-1. 검증 및 반영
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 검증 및 실제 반영]
BEGIN
  DBMS_RESOURCE_MANAGER.VALIDATE_PENDING_AREA();
END;
/

BEGIN
  DBMS_RESOURCE_MANAGER.SUBMIT_PENDING_AREA();
END;
/

/* ------------------------------------------------------------------------------
   13-2. Plan 활성화 — SID 전체 적용
   ※ RAC 04편에서 ALTER SYSTEM SET ... SID='*'로 파라미터를 전 노드에
      적용했던 방식과 동일하게, Resource Manager Plan도 양 노드에 동일하게
      적용해야 인스턴스 간 CPU 배분 정책이 일관되게 유지된다.
   ------------------------------------------------------------------------------ */
-- [Plan 활성화 — SID 전체 적용]
ALTER SYSTEM SET RESOURCE_MANAGER_PLAN = 'DAYTIME_PLAN' SID='*';

/* ------------------------------------------------------------------------------
   13-3. 적용 확인
   ------------------------------------------------------------------------------ */
-- [적용 확인]
SHOW PARAMETER resource_manager_plan;

/* [결과]
NAME                    TYPE    VALUE
----------------------- ------- -------------
resource_manager_plan   string  DAYTIME_PLAN
-> DAYTIME_PLAN이 양 노드에 정상 반영됨
*/


/* ==============================================================================
   14. 원상 복구 — 생성한 Service 및 Resource Manager Plan
   ============================================================================== */

/* ------------------------------------------------------------------------------
   14-1. Service 중지 및 삭제
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — oracle, Service 중지 및 삭제]
/*
[oracle@oelsvr1]$ srvctl stop service -db orcl -service app_svc
[oracle@oelsvr1]$ srvctl remove service -db orcl -service app_svc

[oracle@oelsvr1]$ srvctl stop service -db orcl -service batch_svc
[oracle@oelsvr1]$ srvctl remove service -db orcl -service batch_svc
*/

-- [삭제 확인]
/*
[oracle@oelsvr1]$ srvctl status service -db orcl

[결과]
-> app_svc, batch_svc 모두 조회 결과에서 사라짐 (crsctl stat res -t 로도 확인 가능)
*/

/* ------------------------------------------------------------------------------
   14-2. Resource Manager Plan 비활성화
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. Resource Manager Plan 비활성화]
ALTER SYSTEM SET RESOURCE_MANAGER_PLAN = '' SID='*';

-- [적용 확인]
SHOW PARAMETER resource_manager_plan;

/* [결과]
NAME                    TYPE    VALUE
----------------------- ------- -------------
resource_manager_plan   string
-> Plan이 비활성화되어 값이 공백으로 조회됨
*/

/* ------------------------------------------------------------------------------
   14-3. BATCH_GROUP을 참조하는 모든 Plan 확인
   ※ BATCH_GROUP은 DAYTIME_PLAN 외에 다른 Plan에서도 함께 참조되고 있으므로,
      Consumer Group까지 삭제하면 다른 Plan에 영향을 줄 수 있다 — 이번
      편에서 생성한 DAYTIME_PLAN만 삭제한다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. BATCH_GROUP을 참조하는 모든 Plan 확인]
SELECT plan, group_or_subplan
FROM dba_rsrc_plan_directives
WHERE group_or_subplan = 'BATCH_GROUP';

/* [결과]
PLAN                           GROUP_OR_SUBPLAN
------------------------------ ------------------------------
DSS_PLAN                       BATCH_GROUP
DAYTIME_PLAN                   BATCH_GROUP
MIXED_WORKLOAD_PLAN            BATCH_GROUP
ETL_CRITICAL_PLAN              BATCH_GROUP
ETL_CRITICAL_PLAN              BATCH_GROUP
MIXED_WORKLOAD_PLAN            BATCH_GROUP
DSS_PLAN                       BATCH_GROUP
DAYTIME_PLAN                   BATCH_GROUP
-> DAYTIME_PLAN 외에도 여러 Plan이 BATCH_GROUP을 참조 중임을 확인
   → Consumer Group은 유지하고 DAYTIME_PLAN만 제거
*/

/* ------------------------------------------------------------------------------
   14-4. Pending Area 초기화
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. Pending Area 초기화]
EXEC DBMS_RESOURCE_MANAGER.CLEAR_PENDING_AREA();

/* ------------------------------------------------------------------------------
   14-5. Plan Directive 개별 삭제 후 DAYTIME_PLAN 삭제
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. Plan Directive 개별 삭제 후 DAYTIME_PLAN만 삭제]
BEGIN
  DBMS_RESOURCE_MANAGER.CREATE_PENDING_AREA();

  DBMS_RESOURCE_MANAGER.DELETE_PLAN_DIRECTIVE(
    plan             => 'DAYTIME_PLAN',
    group_or_subplan => 'APP_GROUP');

  DBMS_RESOURCE_MANAGER.DELETE_PLAN_DIRECTIVE(
    plan             => 'DAYTIME_PLAN',
    group_or_subplan => 'BATCH_GROUP');

  DBMS_RESOURCE_MANAGER.DELETE_PLAN_DIRECTIVE(
    plan             => 'DAYTIME_PLAN',
    group_or_subplan => 'OTHER_GROUPS');

  DBMS_RESOURCE_MANAGER.DELETE_PLAN(
    plan => 'DAYTIME_PLAN');

  DBMS_RESOURCE_MANAGER.VALIDATE_PENDING_AREA();
  DBMS_RESOURCE_MANAGER.SUBMIT_PENDING_AREA();
END;
/

-- 다른 Plan이 여전히 참조 중인 APP_GROUP, BATCH_GROUP은 삭제하지 않고 유지한다


/* ==============================================================================
   15. 주요 명령어 정리
   ============================================================================== */

-- Service 생성 및 기동
-- srvctl add service -db orcl -service <서비스명> -preferred <인스턴스> -available <인스턴스> -policy AUTOMATIC
-- srvctl start service -db orcl -service <서비스명>
-- srvctl status service -db orcl -service <서비스명>

-- Service 속성 변경 (TAC 대상 설정)
-- srvctl modify service -d orcl -s <서비스명> -failovertype transaction -commit_outcome true -drain_timeout <초>

-- Service 수동 이동
-- srvctl relocate service -db orcl -service <서비스명> -oldinst <인스턴스> -newinst <인스턴스>

-- Service 중지 및 삭제
-- srvctl stop service -db orcl -service <서비스명>
-- srvctl remove service -db orcl -service <서비스명>

-- Service Goodness 확인 (service_name은 등록된 실제 대소문자 그대로)
SELECT inst_id, service_name, elapsedpercall, cpupercall, callspersec
FROM gv$servicemetric
WHERE service_name = '<서비스명>';

-- Service별 세션 확인
SELECT * FROM gv$session WHERE service_name = '<서비스명>';

-- Resource Manager 설정
-- DBMS_RESOURCE_MANAGER.CLEAR_PENDING_AREA;
-- DBMS_RESOURCE_MANAGER.CREATE_PENDING_AREA;
-- DBMS_RESOURCE_MANAGER.CREATE_CONSUMER_GROUP;
-- DBMS_RESOURCE_MANAGER.CREATE_PLAN;
-- DBMS_RESOURCE_MANAGER.CREATE_PLAN_DIRECTIVE;
-- DBMS_RESOURCE_MANAGER.VALIDATE_PENDING_AREA;
-- DBMS_RESOURCE_MANAGER.SUBMIT_PENDING_AREA;

-- Resource Manager 정리 (다른 Plan에서 공유 중인 Consumer Group은 유지)
-- DBMS_RESOURCE_MANAGER.DELETE_PLAN_DIRECTIVE;
-- DBMS_RESOURCE_MANAGER.DELETE_PLAN;
-- DBMS_RESOURCE_MANAGER.DELETE_PLAN_CASCADE;
-- DBMS_RESOURCE_MANAGER.DELETE_CONSUMER_GROUP;

-- Plan 활성화 / 비활성화
ALTER SYSTEM SET RESOURCE_MANAGER_PLAN = '<플랜명>' SID='*';
ALTER SYSTEM SET RESOURCE_MANAGER_PLAN = '' SID='*';


/* ==============================================================================
   실습 핵심 요약
   ------------------------------------------------------------------------------
   주제                          핵심 포인트
   ------------------------------------------------------------------------------
   Grid Workload Dispatching    Service Name 기반 접속으로 인스턴스 직접
                                 지정 없이 부하 분산·장애 조치를 오라클에 위임
   Preferred / Available        Preferred는 평상시 처리, Available은 장애 시
                                 대체 투입
   Service 구성 방식             Active/Spare · Active/Symmetric ·
                                 Active/Asymmetric
   Failover Type                 NONE(재접속만) · SESSION · SELECT — 업무
                                 특성에 맞는 최소 범위 선택
   CTF                           접속 시점 자동 재연결, 진행 중 쿼리는
                                 인계 안 됨
   TAF                           진행 중이던 SELECT 커서까지 재개, DML
                                 트랜잭션은 대상 아님
   TAC                           commit_outcome=true 선행 설정 필요, COMMIT
                                 성공 여부를 기억해 DML/트랜잭션 구간까지 Replay
   Service Goodness               MMNL 기반 점수, gv$servicemetric으로 인스턴스별
                                 부하 확인 (트래픽 발생 전에는 0으로 조회)
   Resource Manager               Consumer Group + Plan Directive로 서비스별
                                 CPU 비율 통제
   Pending Area                   CREATE → VALIDATE → SUBMIT 3단계로 안전하게
                                 설정 반영, 에러로 중단 시 CLEAR로 초기화
   실습 정리                      다른 Plan이 공유 중인 Consumer Group은
                                 DELETE_PLAN_DIRECTIVE + DELETE_PLAN으로
                                 Plan만 제거
   ============================================================================== */
