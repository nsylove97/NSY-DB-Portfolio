/* ==============================================================================
   RAC 07: RAC 성능 튜닝 — Cache Fusion · Wait Event · Hot Block 분석
   Blog  : https://nsylove97.tistory.com/132
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
   | Node1     | oelsvr1.localdomain  | orcl1 인스턴스, VIP=oelsvr1-vip           |
   | Node2     | oelsvr2.localdomain  | orcl2 인스턴스, VIP=oelsvr2-vip           |
   +----------+----------------------+----------------------------------------+

   디렉토리 정보
   ORACLE_BASE : /u01/app/oracle
   ORACLE_HOME : /u01/app/oracle/product/19.3.0/dbhome
   DB_NAME     : orcl (orcl1 / orcl2 인스턴스)
   ------------------------------------------------------------------------------
   목차
   1.    RAC 튜닝 원칙 — 단일 인스턴스 튜닝 선행
   2.    CPU Time vs Wait Time — 튜닝 방향 판단 기준
   2-1.  DB CPU vs DB time 조회
   3.    RAC 추가 병목 요인 4가지
   4.    RAC 전용 진단 도구 — AWR · ADDM · GV$ · EM RAC Pages
   5.    Cache Fusion 블록 전송 비용과 정상 응답 시간 기준
   5-1.  gc cr block receive time / gc cr blocks received 조회
   6.    Cluster Wait Class — 주요 Wait Event 목록
   6-1.  Cluster Wait Class 상위 5개 이벤트 조회
   7.    Placeholder Event → 실제 GC 이벤트 전환
   8.    2-way / 3-way Block Request 흐름 비교
   9.    GC Buffer Busy · GC Current Grant Busy · GC Block Congested
   10.   Enqueue(Lock) 병목 — GES · TX · TM
   10-1. TX/TM Enqueue 대기 통계 조회
   11.   Index Block Contention — 순차 증가 인덱스와 Sequence 설계
   11-1. 인스턴스 직접 접속용 tnsnames.ora 항목 추가
   11-2. 테스트 테이블·시퀀스 생성 (CACHE 20 ORDER)
   11-3. 병렬 INSERT 스크립트 준비 (insert_loop.sql)
   11-4. 노드1·노드2 병렬 세션 4개 동시 실행
   11-5. CACHE 20 ORDER 상태 경합 확인
   11-6. 오브젝트 재생성 및 Sequence 재설계 (CACHE 1000 NOORDER)
   11-7. 동일 조건 재실행
   11-8. CACHE 1000 NOORDER 상태 경합 확인 및 변경 전후 비교
   12.   UNDO 블록 인터커넥트 이동과 짧은 트랜잭션
   13.   HWM 병목과 ASSM
   13-1. MANUAL/AUTO 비교용 테이블스페이스·테이블 생성
   13-2. 병렬 INSERT 스크립트 준비 (MANUAL/AUTO)
   13-3. MANUAL 테이블스페이스 대상 병렬 세션 실행
   13-4. MANUAL 테이블스페이스 HW 경합 확인
   13-5. 누적 통계 초기화 — DB 전체 재기동
   13-6. AUTO 테이블스페이스 대상 병렬 세션 실행
   13-7. AUTO 테이블스페이스 HW 경합 확인 및 MANUAL 대비 비교
   14.   실습 핵심 요약
   15.   관련 뷰 & 명령어 정리
   ============================================================================== */


/* ==============================================================================
   1. RAC 튜닝 원칙 — 단일 인스턴스 튜닝 선행
   ==============================================================================
   RAC 성능 문제를 진단할 때 가장 먼저 저지르는 실수는 모든 지연을
   Interconnect 탓으로 돌리는 것이다. 실제로는 SQL 자체의 비효율이
   원인인 경우가 훨씬 많다.

   +-------+----------------+--------------------------------+
   | 순서   | 점검 대상        | 판단 기준                          |
   +-------+----------------+--------------------------------+
   | 1단계  | 단일 인스턴스 튜닝 | 실행 계획 · 인덱스 · 통계 정보가 정상인가       |
   | 2단계  | RAC 전용 튜닝    | 1단계가 정상인데도 노드 간 지연이 발생하는가      |
   +-------+----------------+--------------------------------+

   단일 인스턴스에서도 느린 SQL은 RAC로 옮긴다고 빨라지지 않는다.
   RAC 튜닝은 단일 인스턴스 튜닝이 끝난 뒤에 시작하는 것이 원칙이며,
   이 순서를 지키지 않으면 Interconnect 설정을 아무리 손봐도
   근본 원인은 그대로 남는다.
   ============================================================================== */


/* ==============================================================================
   2. CPU Time vs Wait Time — 튜닝 방향 판단 기준
   ============================================================================== */

/* ------------------------------------------------------------------------------
   2-1. DB CPU vs DB time 조회
   ※ DB time 대비 DB CPU 비중이 낮을수록, 세션이 CPU 연산보다
     '무언가를 기다리는 시간'에 더 많은 시간을 쓰고 있다는 뜻이다.
     이 비중이 RAC 튜닝 방향(SQL 튜닝 vs 리소스 튜닝)을 가르는 첫 분기점이다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1]
SELECT sid, stat_name, value
FROM   v$sess_time_model
WHERE  stat_name IN ('DB CPU', 'DB time')
ORDER  BY sid DESC;

/* [결과]
    SID STAT_NAME                 VALUE
---------- -------------------- ----------
       411 DB CPU                   274312
       411 DB time                 1782267
-> DB CPU가 DB time 대비 약 15% 수준에 불과 — 나머지 85%는 CPU 연산이 아닌
   대기 시간으로 소모되고 있음. CPU time이 지배적이면 SQL 튜닝, Wait time이
   지배적이면 리소스 튜닝(락·I/O·인터커넥트) 대상으로 방향을 잡는다.
*/


/* ==============================================================================
   3. RAC 추가 병목 요인 4가지
   ==============================================================================
   +----------------------+---------------------------------------------+
   | 병목 요인              | 설명                                        |
   +----------------------+---------------------------------------------+
   | Interconnect 트래픽    | 노드 간 블록 전송량 증가 시 네트워크 자체가 병목이 됨       |
   | Instance Recovery    | 장애 인스턴스의 락 정리 동안 생존 노드 세션이 대기          |
   | Hot Block             | 동일 블록에 여러 노드가 동시에 접근해 반복적으로 전송됨       |
   | 직렬화(Serialization)  | Sequence · Enqueue 등 단일 자원 경합으로 처리가 순차화됨 |
   +----------------------+---------------------------------------------+

   단일 인스턴스에는 없던 이 네 가지가 RAC 환경에서 추가로 발생하는
   성능 저하 요인이며, 이번 실습은 이 네 가지를 진단·완화하는 데 초점을 맞춘다.
   ============================================================================== */


/* ==============================================================================
   4. RAC 전용 진단 도구 — AWR · ADDM · GV$ · EM RAC Pages
   ==============================================================================
   +--------------------------------------+-----------------------------------------+
   | 도구                                    | 용도                                       |
   +--------------------------------------+-----------------------------------------+
   | AWR (Automatic Workload Repository)  | 스냅샷 구간별 Top Wait Event · SQL 통계 수집      |
   | ADDM                                  | AWR 데이터를 기반으로 병목 원인과 권고안을 자동 분석         |
   | GV$ 뷰                                 | 노드별(inst_id) 실시간 성능 지표 조회               |
   | EM (Enterprise Manager) RAC Pages    | Cluster Cache Coherency · Interconnect 통계 시각화 |
   +--------------------------------------+-----------------------------------------+

   RAC 05편에서 다룬 AWR 리포트 생성 방식(awrrpt.sql)을 그대로 활용하되,
   이번 실습에서는 Cluster 섹션에 집중해서 읽는다.
   ============================================================================== */


/* ==============================================================================
   5. Cache Fusion 블록 전송 비용과 정상 응답 시간 기준
   ============================================================================== */

/* ------------------------------------------------------------------------------
   5-1. gc cr block receive time / gc cr blocks received 조회
   ※ 평균 응답 시간(ms) = gc cr block receive time / gc cr blocks received × 10 으로
     환산한다. 10ms를 초과하면 인터커넥트 설정이나 부하 분산 상태를 먼저 점검한다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1]
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name IN ('gc cr block receive time', 'gc cr blocks received')
ORDER  BY inst_id;

/* [결과]
    INST_ID NAME                                VALUE
---------- ------------------------------ ----------
         1 gc cr blocks received                1844
         1 gc cr block receive time              168
         2 gc cr blocks received                 199
         2 gc cr block receive time               29
-> 인스턴스 1은 약 0.9ms(168/1844×10), 인스턴스 2는 약 1.5ms(29/199×10) 수준으로
   정상 기준선인 10ms를 밑도는 안정적인 상태. Cache Fusion은 디스크 I/O 없이
   메모리 간 블록을 주고받는 구조지만, Private Interconnect 대역폭·지연 상태에
   따라 이 비용도 눈에 띄게 늘어날 수 있다.
*/


/* ==============================================================================
   6. Cluster Wait Class — 주요 Wait Event 목록
   ============================================================================== */

/* ------------------------------------------------------------------------------
   6-1. Cluster Wait Class 상위 5개 이벤트 조회
   ※ wait_class = 'Cluster'로 필터링하면 RAC 고유의 대기 이벤트만 추려볼 수 있다.
     Time Waited 상위 이벤트가 곧 현재 클러스터 성능을 가장 많이 갉아먹는 지점이다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1]
SELECT inst_id, event, total_waits, time_waited
FROM   gv$system_event
WHERE  wait_class = 'Cluster'
ORDER  BY time_waited DESC
FETCH FIRST 5 ROWS ONLY;

/* [결과]
    INST_ID EVENT                          TOTAL_WAITS TIME_WAITED
---------- ------------------------------ ----------- -----------
         2 gc current block 2-way                3410        7702
         1 gc cr block 2-way                       75        1132
         2 gc cr grant 2-way                      273         962
         2 gc cr multi block mixed                169         862
         1 gc cr grant 2-way                     2397         503
-> 상위 이벤트가 모두 2-way 계열 — Master 노드를 경유하지 않고 요청 노드와
   보유 노드 간에 직접 처리되는 정상 패턴. gc buffer busy · gc block congested
   같은 경합·적체성 이벤트가 상위에 없다는 점에서 현재 클러스터는 안정적이다.
*/


/* ==============================================================================
   7. Placeholder Event → 실제 GC 이벤트 전환
   ==============================================================================
   세션이 블록을 요청하는 순간 오라클은 우선 gc cr request, gc current request
   같은 Placeholder Event로 대기를 기록한다.

   실제 요청이 처리되어 원인이 확정되면, 이 Placeholder는 gc cr block busy,
   gc current block 2-way 등 구체적인 GC 이벤트로 재기록된다.

   AWR이나 실시간 조회 시점에 Placeholder Event 비중이 높다면, 아직 세부 원인이
   확정되지 않은 대기가 많다는 뜻이므로 관찰 주기를 좁혀 재조회하는 것이
   정확한 진단에 유리하다.
   ============================================================================== */


/* ==============================================================================
   8. 2-way / 3-way Block Request 흐름 비교
   ==============================================================================
   +--------+---------------------------------------+---------------------------------------+
   | 구분    | 흐름                                    | 특징                                     |
   +--------+---------------------------------------+---------------------------------------+
   | 2-way  | 요청 노드 → 보유 노드 → 요청 노드            | 보유 노드가 Master 역할 겸함, 홉 수 적어 빠름       |
   | 3-way  | 요청 노드 → Master 노드 → 보유 노드 → 요청 노드 | 요청·보유 노드가 다른 Master 경유, 홉 수 늘어 지연 증가 |
   +--------+---------------------------------------+---------------------------------------+

   2 Node RAC에서는 대부분 2-way로 처리되지만, 3 Node 이상에서는 GRD가 관리하는
   Master 노드가 요청 노드·보유 노드와 모두 다를 수 있어 3-way가 발생한다.
   3-way 비중이 높다면 Object Affinity(특정 객체를 특정 노드에 편중 배치)를
   검토할 신호다.
   ============================================================================== */


/* ==============================================================================
   9. GC Buffer Busy · GC Current Grant Busy · GC Block Congested
   ==============================================================================
   +------------------------+------------------------------------------+---------------------------+
   | Wait Event              | 의미                                       | 주요 원인                     |
   +------------------------+------------------------------------------+---------------------------+
   | gc buffer busy          | 로컬에서 다른 세션이 이미 해당 블록을 처리 중이라 대기       | Hot Block, 동일 블록 반복 접근  |
   | gc current grant busy   | Current 블록의 소유권(Grant) 처리가 지연됨          | LMS 프로세스 부하, 인터커넥트 지연   |
   | gc block congested      | LMS 큐에 처리 대기 요청이 쌓여 지연됨                | LMS 프로세스 수 부족, CPU 자원 부족 |
   +------------------------+------------------------------------------+---------------------------+

   세 이벤트 모두 "블록을 못 받아서 기다린다"는 표면 현상은 같지만 원인이
   완전히 다르다 — 버퍼 자체의 경합인지, 소유권 이전 지연인지, LMS 큐 적체인지를
   구분해야 정확한 대응이 가능하다. gc block congested가 두드러지면 LMS
   프로세스 수(gcs_server_processes) 증설을 검토하고, gc buffer busy가
   두드러지면 애플리케이션 레벨의 Hot Block 설계를 먼저 의심한다.
   ============================================================================== */


/* ==============================================================================
   10. Enqueue(Lock) 병목 — GES · TX · TM
   ============================================================================== */

/* ------------------------------------------------------------------------------
   10-1. TX/TM Enqueue 대기 통계 조회
   ※ RAC에서 Enqueue(Lock)는 GES(Global Enqueue Service)가 노드 간 소유권을
     조율한다. 단일 인스턴스보다 락 해소에 노드 간 통신 비용이 추가된다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1]
SELECT inst_id, eq_type, total_req#, total_wait#, cum_wait_time
FROM   gv$enqueue_statistics
WHERE  eq_type IN ('TX', 'TM')
ORDER  BY cum_wait_time DESC;

/* [결과]
    INST_ID EQ TOTAL_REQ# TOTAL_WAIT# CUM_WAIT_TIME
---------- -- ---------- ----------- -------------
         2 TM        559          54           448
         2 TX        407          22           411
         1 TM       1132          71           381
         1 TX        519          31           123
         2 TX          0           0             0
-> TM 대기가 두 노드 모두에서 cum_wait_time 상위를 차지 — DML 도중 DDL이
   끼어드는 상황이 주요 원인으로 보인다. TX 대기는 트랜잭션 락(행 잠금·
   인덱스 분할 등) 경합에서 발생한다. cum_wait_time이 큰 유형부터
   원인 세션(gv$session, gv$lock)을 추적한다.
*/


/* ==============================================================================
   11. Index Block Contention — 순차 증가 인덱스와 Sequence 설계
   ============================================================================== */

/* ------------------------------------------------------------------------------
   11-1. 인스턴스 직접 접속용 tnsnames.ora 항목 추가
   ※ SCAN이나 기본 서비스 접속은 로드밸런싱 대상이라 원하는 인스턴스로
     붙는다는 보장이 없다. HOST를 각 노드 VIP로 직접 지정하고 INSTANCE_NAME을
     명시해야 노드1 세션은 반드시 orcl1로, 노드2 세션은 반드시 orcl2로
     접속하도록 고정할 수 있다.
   ------------------------------------------------------------------------------ */
/* [oelsvr1 · oelsvr2 — tnsnames.ora에 인스턴스 직접 접속 항목 추가]
ORCL1_DIRECT =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oelsvr1-vip)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = orcl)
      (INSTANCE_NAME = orcl1)
    )
  )

ORCL2_DIRECT =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oelsvr2-vip)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = orcl)
      (INSTANCE_NAME = orcl2)
    )
  )
*/

/* [결과]
-> tnsping ORCL1_DIRECT / tnsping ORCL2_DIRECT로 각 인스턴스에 직접
   연결되는지 확인. 이후 모든 부하 테스트 세션은 이 두 항목으로만 접속한다.
*/

/* ------------------------------------------------------------------------------
   11-2. 테스트 테이블·시퀀스 생성 (CACHE 20 ORDER)
   ※ 순차 증가 PK 경합을 재현하기 위해 기본 CACHE 20 ORDER 옵션의 시퀀스를
     생성한다. ORDER는 인스턴스 간 시퀀스 값을 순서대로 발급하도록 강제해,
     신규 행이 인덱스 리프 블록 오른쪽 끝에 집중되게 만드는 조건이다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 테스트용 테이블 생성]
CREATE TABLE orders_test (
    order_id   NUMBER PRIMARY KEY,
    order_date DATE DEFAULT SYSDATE,
    amount     NUMBER
);

-- [oelsvr1 — SQL*Plus, orcl1. CACHE 20 ORDER 시퀀스 생성]
CREATE SEQUENCE orders_test_seq START WITH 1 INCREMENT BY 1 CACHE 20 ORDER;

/* [결과]
Table created.
Sequence created.
-> orders_test PK 인덱스가 자동 생성되고, 시퀀스는 ORDER 옵션으로
   노드 간 순차 발급되는 상태에서 실습을 시작한다.
*/

/* ------------------------------------------------------------------------------
   11-3. 병렬 INSERT 스크립트 준비 (insert_loop.sql)
   ※ 건수보다 동시 세션 수를 늘리는 쪽이 실제 경합 재현에 더 효과적이다.
   ------------------------------------------------------------------------------ */
/* [insert_loop.sql — 접속 인스턴스 확인 후 반복 INSERT] */
SELECT instance_name, host_name FROM v$instance;

BEGIN
  FOR i IN 1..5000 LOOP
    INSERT INTO orders_test (order_id, amount)
    VALUES (orders_test_seq.NEXTVAL, ROUND(DBMS_RANDOM.VALUE(1,1000)));
    COMMIT;
  END LOOP;
END;
/
EXIT;

/* [결과]
-> insert_loop.sql 저장 완료. 각 노드에서 인스턴스를 직접 지정해
   접속을 고정한 뒤, 두 노드가 거의 같은 시각에 4개 세션씩 동시에
   INSERT 루프를 실행하도록 구성한다.
*/

/* ------------------------------------------------------------------------------
   11-4. 노드1·노드2 병렬 세션 4개 동시 실행
   ------------------------------------------------------------------------------ */
/* [oelsvr1 — oracle 계정, OS 터미널. 노드1(orcl1)에서 병렬 세션 4개 동시 실행]
$ for i in 1 2 3 4
  do
    sqlplus -s sys/<password>@ORCL1_DIRECT as sysdba @insert_loop.sql &
  done
  wait
*/

/* [oelsvr2 — oracle 계정, OS 터미널. 노드2(orcl2)에서 같은 시각에 병렬 세션 4개 실행]
$ for i in 1 2 3 4
  do
    sqlplus -s sys/<password>@ORCL2_DIRECT as sysdba @insert_loop.sql &
  done
  wait
*/

/* [결과]
-> 두 노드 모두 4개 백그라운드 세션이 종료(wait)될 때까지 대기.
   총 40,000건(양 노드 8세션 × 5,000건)이 orders_test에 삽입된다.
*/

/* ------------------------------------------------------------------------------
   11-5. CACHE 20 ORDER 상태 경합 확인
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. PK 인덱스명 조회]
SELECT index_name FROM user_indexes WHERE table_name = 'ORDERS_TEST';

/* [결과]
INDEX_NAME
------------------------------
SYS_C007583
-> 자동 생성된 PK 인덱스명 확인. 이후 gc% 통계 조회에 이 이름을 사용한다.
*/

-- [oelsvr1 — SQL*Plus, orcl1. CACHE 20 ORDER 상태 경합 확인]
SELECT inst_id, statistic_name, value
FROM   gv$segment_statistics
WHERE  object_name = 'SYS_C007583'
AND    statistic_name LIKE 'gc%'
ORDER  BY value DESC;

/* [결과]
    INST_ID STATISTIC_NAME                      VALUE
---------- ------------------------------ ----------
         1 gc buffer busy                       9237
         2 gc buffer busy                       8382
         1 gc current blocks received           3394
         2 gc current blocks received           3385
         2 gc remote grants                       74
         1 gc remote grants                       66
         2 gc cr blocks received                  18
         1 gc cr blocks received                  17
-> gc buffer busy가 두 노드 모두 8천~9천 건대로 뚜렷하게 나타남. ORDER_ID가
   순차 증가하는 PK 인덱스 구조상 신규 행이 항상 리프 블록 오른쪽 끝에
   몰려 삽입되면서, 여러 세션이 같은 순간에 같은 리프 블록을 요구해 경합이
   발생하고 있음을 확인.
*/

/* ------------------------------------------------------------------------------
   11-6. 오브젝트 재생성 및 Sequence 재설계 (CACHE 1000 NOORDER)
   ※ 앞선 측정과 동일한 조건에서 시퀀스 옵션만 바꿔 비교하기 위해, 테이블과
     인덱스를 새로 생성하여 gv$segment_statistics 누적치를 0부터 다시 시작한다.
     NOORDER는 인스턴스별로 시퀀스 캐시 블록을 독립적으로 할당해 노드마다
     서로 다른 값 범위를 사용하게 만든다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 기존 테이블·시퀀스 제거]
DROP TABLE orders_test PURGE;
DROP SEQUENCE orders_test_seq;

-- [oelsvr1 — SQL*Plus, orcl1. 테이블 재생성]
CREATE TABLE orders_test (
    order_id   NUMBER PRIMARY KEY,
    order_date DATE DEFAULT SYSDATE,
    amount     NUMBER
);

-- [oelsvr1 — SQL*Plus, orcl1. CACHE 1000 NOORDER 시퀀스 생성]
CREATE SEQUENCE orders_test_seq START WITH 1 INCREMENT BY 1 CACHE 1000 NOORDER;

/* [결과]
Table dropped.
Sequence dropped.
Table created.
Sequence created.
-> PK 인덱스도 새로 생성되어 gv$segment_statistics 누적 통계가 0부터
   다시 집계된다.
*/

/* ------------------------------------------------------------------------------
   11-7. 동일 조건 재실행
   ------------------------------------------------------------------------------ */
/* [oelsvr1 · oelsvr2 — oracle 계정, OS 터미널. 동일한 방식으로 병렬 세션 4개씩 재실행]
   (11-3 insert_loop.sql, 11-4 병렬 실행 스크립트 재사용)
*/

/* [결과]
-> CACHE 20 ORDER 상태와 동일한 부하 패턴(양 노드 4세션 × 5,000건)으로
   재실행 완료.
*/

/* ------------------------------------------------------------------------------
   11-8. CACHE 1000 NOORDER 상태 경합 확인 및 변경 전후 비교
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. 재생성된 PK 인덱스명 조회]
SELECT index_name FROM user_indexes WHERE table_name = 'ORDERS_TEST';

/* [결과]
INDEX_NAME
------------------------------
SYS_C0067890
-- 이전 실습에서 재생성된 인덱스명이 새로 부여된 경우
-> 재생성된 PK 인덱스명 확인 후 gc% 통계 조회에 사용.
*/

-- [oelsvr1 — SQL*Plus, orcl1. CACHE 1000 NOORDER 상태 경합 확인]
SELECT inst_id, statistic_name, value
FROM   gv$segment_statistics
WHERE  object_name = 'SYS_C0067890'
AND    statistic_name LIKE 'gc%'
ORDER  BY value DESC;

/* [결과]
    INST_ID STATISTIC_NAME                      VALUE
---------- ------------------------------ ----------
         2 gc buffer busy                       1850
         1 gc buffer busy                       1743
         1 gc current blocks received            663
         2 gc current blocks received            657
         2 gc remote grants                       57
         1 gc remote grants                       55
         2 gc cr blocks received                  16
         1 gc cr blocks received                  15
-> gc buffer busy가 CACHE 20 ORDER 상태(9237/8382)에서 CACHE 1000 NOORDER
   상태(1743/1850)로 두 노드 모두 약 75~78% 감소. gc current blocks received
   역시 3394/3385에서 663/657 수준으로 함께 줄어, 리프 블록을 둘러싼 전송량
   자체가 크게 감소했음을 확인. gc remote grants는 소폭 증가했는데, 이는
   시퀀스 캐시가 커지면서 더 넓은 범위의 값을 미리 확보하는 통신이 일정
   수준 유지되기 때문이다. NOORDER + CACHE 확대는 인덱스 리프 블록에서의
   직접적인 버퍼 경합과 블록 전송량을 확실히 줄이는 효과가 있다.
*/


/* ==============================================================================
   12. UNDO 블록 인터커넥트 이동과 짧은 트랜잭션
   ==============================================================================
   인스턴스마다 전용 UNDO 테이블스페이스를 사용하지만, 다른 인스턴스가 커밋 전
   데이터를 읽으려면 UNDO 블록 자체를 인터커넥트로 가져와야 한다.

   트랜잭션이 길어질수록 UNDO 블록이 오래 점유되고, 그만큼 다른 노드의
   Consistent Read 요청이 대기하는 시간도 늘어난다.

   이 병목의 근본 대응은 튜닝 파라미터가 아니라 애플리케이션 설계다 — 트랜잭션을
   짧게 유지하고 불필요한 대량 UPDATE를 배치 단위로 쪼개는 것이 인터커넥트
   부하를 줄이는 가장 확실한 방법이다.
   ============================================================================== */


/* ==============================================================================
   13. HWM 병목과 ASSM
   ============================================================================== */

/* ------------------------------------------------------------------------------
   13-1. MANUAL/AUTO 비교용 테이블스페이스·테이블 생성
   ※ PK나 시퀀스 없이 순수하게 새 블록 확보(HWM 이동) 경합만 보기 위해,
     MANUAL과 AUTO(ASSM) 세그먼트 관리 방식의 테이블스페이스를 각각 준비하고
     동일 구조의 테스트 테이블을 하나씩 생성한다.
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. MANUAL 세그먼트 관리 테이블스페이스 생성]
CREATE TABLESPACE ts_manual DATAFILE '+DATA' SIZE 500M
SEGMENT SPACE MANAGEMENT MANUAL;

-- [oelsvr1 — SQL*Plus, orcl1. AUTO(ASSM) 세그먼트 관리 테이블스페이스 생성]
CREATE TABLESPACE ts_auto DATAFILE '+DATA' SIZE 500M
SEGMENT SPACE MANAGEMENT AUTO;

-- [oelsvr1 — SQL*Plus, orcl1. MANUAL 대상 테스트 테이블 생성]
CREATE TABLE hwm_test_manual (id NUMBER, val VARCHAR2(100))
TABLESPACE ts_manual;

-- [oelsvr1 — SQL*Plus, orcl1. AUTO 대상 테스트 테이블 생성]
CREATE TABLE hwm_test_auto (id NUMBER, val VARCHAR2(100))
TABLESPACE ts_auto;

/* [결과]
Tablespace created.
Tablespace created.
Table created.
Table created.
-> MANUAL(Freelist 기반)과 AUTO(Bitmap 기반, ASSM) 두 방식의 테이블스페이스와
   동일 구조 테이블이 준비 완료.
*/

/* ------------------------------------------------------------------------------
   13-2. 병렬 INSERT 스크립트 준비 (MANUAL/AUTO)
   ※ 11번 테스트와 달리 PK·시퀀스를 두지 않고 DBMS_RANDOM으로 임의의 id를
     추출한다. 순차 증가 인덱스로 인한 리프 블록 경합을 배제하고, 순수하게
     새 블록 확보(HWM 이동) 경합만 보기 위함이다.
   ------------------------------------------------------------------------------ */
/* [insert_loop_manual.sql — MANUAL 테이블스페이스 대상] */
SELECT instance_name, host_name FROM v$instance;

DECLARE
  v_id NUMBER;
BEGIN
  FOR i IN 1..5000 LOOP
    v_id := DBMS_RANDOM.VALUE(1, 999999999);
    INSERT INTO hwm_test_manual (id, val)
    VALUES (v_id, DBMS_RANDOM.STRING('A', 50));
    COMMIT;
  END LOOP;
END;
/
EXIT;

/* [insert_loop_auto.sql — AUTO(ASSM) 테이블스페이스 대상] */
SELECT instance_name, host_name FROM v$instance;

DECLARE
  v_id NUMBER;
BEGIN
  FOR i IN 1..5000 LOOP
    v_id := DBMS_RANDOM.VALUE(1, 999999999);
    INSERT INTO hwm_test_auto (id, val)
    VALUES (v_id, DBMS_RANDOM.STRING('A', 50));
    COMMIT;
  END LOOP;
END;
/
EXIT;

/* [결과]
-> 두 스크립트 모두 저장 완료. DBMS_RANDOM.STRING('A', 50)으로 값 길이를
   확보해 블록당 저장 가능 행 수를 늘려, 여러 세션이 새 블록을 요구하는
   빈도를 높인다.
*/

/* ------------------------------------------------------------------------------
   13-3. MANUAL 테이블스페이스 대상 병렬 세션 실행
   ------------------------------------------------------------------------------ */
/* [oelsvr1 — oracle 계정, OS 터미널. 노드1(orcl1)에서 병렬 세션 4개 동시 실행]
$ for i in 1 2 3 4
  do
    sqlplus -s sys/<password>@ORCL1_DIRECT as sysdba @insert_loop_manual.sql &
  done
  wait
*/

/* [oelsvr2 — oracle 계정, OS 터미널. 노드2(orcl2)에서 같은 시각에 병렬 세션 4개 실행]
$ for i in 1 2 3 4
  do
    sqlplus -s sys/<password>@ORCL2_DIRECT as sysdba @insert_loop_manual.sql &
  done
  wait
*/

/* [결과]
-> 양 노드에서 병렬 세션 4개씩 실행 완료.
*/

/* ------------------------------------------------------------------------------
   13-4. MANUAL 테이블스페이스 HW 경합 확인
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. MANUAL 테이블스페이스 HW 경합 확인]
SELECT inst_id, eq_type, total_req#, total_wait#, cum_wait_time
FROM   gv$enqueue_statistics
WHERE  eq_type = 'HW'
ORDER  BY inst_id;

/* [결과]
    INST_ID EQ TOTAL_REQ# TOTAL_WAIT# CUM_WAIT_TIME
---------- -- ---------- ----------- -------------
         1 HW       1288         607          3894
         2 HW        919         445          3963
-> MANUAL 세그먼트 관리 방식에서는 두 노드 모두 HW 요청의 절반 가까이
   (1번 노드 약 47%, 2번 노드 약 48%)가 대기로 이어짐. Freelist 기반으로
   새 블록을 확보하다 보니, 여러 세션이 동시에 HWM을 이동시키려 할 때
   경합이 그대로 드러난다.
*/

/* ------------------------------------------------------------------------------
   13-5. 누적 통계 초기화 — DB 전체 재기동
   ※ gv$enqueue_statistics는 인스턴스 단위 누적이므로, MANUAL 테스트의
     누적치를 배제하고 AUTO 테스트만의 순수 구간 값을 측정하려면 DB 전체를
     재기동해야 한다.
   ------------------------------------------------------------------------------ */
/* [oelsvr1 — oracle 계정, OS 터미널. srvctl로 DB 전체(양 인스턴스) 정지/기동]
$ srvctl stop database -d orcl
$ srvctl start database -d orcl
*/

-- [oelsvr1 — SQL*Plus, orcl1. 재기동 확인]
SELECT inst_id, instance_name, status FROM gv$instance;

/* [결과]
   INST_ID INSTANCE_NAME    STATUS
---------- ---------------- ------------
         1 orcl1            OPEN
         2 orcl2            OPEN
-> 양 노드 모두 OPEN 상태 확인.
*/

-- [oelsvr1 — SQL*Plus, orcl1. 재기동 직후 HW 누적치 확인]
SELECT inst_id, eq_type, total_req#, total_wait#, cum_wait_time
FROM   gv$enqueue_statistics
WHERE  eq_type = 'HW'
ORDER  BY inst_id;

/* [결과]
    INST_ID EQ TOTAL_REQ# TOTAL_WAIT# CUM_WAIT_TIME
---------- -- ---------- ----------- -------------
         1 HW         36          10            12
         2 HW         39           4             9
-> srvctl stop/start database로 DB 전체를 재기동한 직후에도 TOTAL_REQ#가
   완전히 0은 아님(인스턴스 OPEN 과정과 백그라운드 프로세스 초기화 과정에서도
   소량의 HW 요청이 자연 발생하기 때문). MANUAL 테스트 결과(1288/919)에
   비하면 매우 적은 수준이므로 이 값을 기준선으로 삼아 AUTO 테스트 결과와
   비교한다.
*/

/* ------------------------------------------------------------------------------
   13-6. AUTO 테이블스페이스 대상 병렬 세션 실행
   ------------------------------------------------------------------------------ */
/* [oelsvr1 — oracle 계정, OS 터미널. 노드1(orcl1)에서 병렬 세션 4개 동시 실행]
$ for i in 1 2 3 4
  do
    sqlplus -s sys/<password>@ORCL1_DIRECT as sysdba @insert_loop_auto.sql &
  done
  wait
*/

/* [oelsvr2 — oracle 계정, OS 터미널. 노드2(orcl2)에서 같은 시각에 병렬 세션 4개 실행]
$ for i in 1 2 3 4
  do
    sqlplus -s sys/<password>@ORCL2_DIRECT as sysdba @insert_loop_auto.sql &
  done
  wait
*/

/* [결과]
-> 양 노드에서 병렬 세션 4개씩 실행 완료.
*/

/* ------------------------------------------------------------------------------
   13-7. AUTO 테이블스페이스 HW 경합 확인 및 MANUAL 대비 비교
   ------------------------------------------------------------------------------ */
-- [oelsvr1 — SQL*Plus, orcl1. AUTO 테이블스페이스 HW 경합 확인]
SELECT inst_id, eq_type, total_req#, total_wait#, cum_wait_time
FROM   gv$enqueue_statistics
WHERE  eq_type = 'HW'
ORDER  BY inst_id;

/* [결과]
    INST_ID EQ TOTAL_REQ# TOTAL_WAIT# CUM_WAIT_TIME
---------- -- ---------- ----------- -------------
         1 HW         77          39           461
         2 HW         46          10           135
-> 재기동 직후 기준선(1번 36/10/12, 2번 39/4/9)을 제외한 순수 테스트 구간 값은
   1번 노드 TOTAL_REQ# 41 / TOTAL_WAIT# 29 / CUM_WAIT_TIME 449,
   2번 노드 TOTAL_REQ# 7 / TOTAL_WAIT# 6 / CUM_WAIT_TIME 126.
   MANUAL 테스트에서는 HW 요청의 절반 가까이가 대기로 이어졌던 반면
   (1번 약 47%, 2번 약 48%), AUTO에서는 대기 비율이 1번 약 71%, 2번 약 86%로
   오히려 더 높게 나왔지만, 절대적인 요청·대기·시간 수치 자체는 MANUAL의
   10분의 1 수준으로 크게 감소. ASSM 환경에서는 애초에 HWM 관련 enq: HW
   요청 자체가 거의 발생하지 않아, Freelist 기반의 MANUAL과 비교했을 때
   근본적인 경합 발생량이 현저히 낮다. AUTO(ASSM)는 Bitmap 기반으로 여유
   블록을 관리해 여러 프로세스가 동시에 블록을 할당받을 수 있으므로, RAC
   환경에서는 사실상 필수에 가깝다.
*/


/* ==============================================================================
   14. 실습 핵심 요약
   ==============================================================================
   주제              핵심 포인트
   ----------------  --------------------------------------------------------------
   튜닝 순서           단일 인스턴스 튜닝 완료 후 RAC 전용 튜닝으로 넘어간다
   CPU vs Wait       DB time 대비 DB CPU 비중으로 SQL 튜닝 vs 리소스 튜닝 방향을 가른다
   RAC 추가 병목       Interconnect · Instance Recovery · Hot Block · 직렬화 4가지
   Cache Fusion 기준  블록당 평균 응답 시간 10ms 초과 시 인터커넥트 상태 점검
   Wait Event        Placeholder Event가 실제 GC 이벤트로 전환되며 원인이 확정된다
   GC 이벤트 구분      buffer busy(경합) · current grant busy(소유권 지연) ·
                     block congested(LMS 큐 적체)
   Enqueue(TX/TM)    실측에서 TM 대기가 두 노드 모두 cum_wait_time 상위 차지 —
                     DML 도중 DDL 개입 가능성을 시사
   인덱스 경합         순차 증가 인덱스는 Sequence CACHE 확대 + NOORDER로 분산
                     (gc buffer busy 약 75~78% 감소 실측 확인)
   누적 통계 주의      gv$segment_statistics는 오브젝트 재생성으로 리셋되고,
                     gv$enqueue_statistics는 인스턴스 단위 누적이라 인스턴스를
                     재기동해야 순수 구간 값을 측정할 수 있다
   UNDO 병목          인터커넥트 이동 비용은 결국 짧은 트랜잭션 설계로 해결한다
   HWM               ASSM으로 블록 할당 경합을 완화한다 (MANUAL 대비 요청·대기
                     시간이 약 10분의 1 수준으로 감소 실측 확인)
   ============================================================================== */


/* ==============================================================================
   15. 관련 뷰 & 명령어 정리
   ============================================================================== */

-- CPU time vs Wait time 판단
SELECT sid, stat_name, value
FROM   v$sess_time_model
WHERE  stat_name IN ('DB CPU','DB time');

-- Cache Fusion 응답 시간 확인
SELECT inst_id, name, value
FROM   gv$sysstat
WHERE  name IN ('gc cr block receive time','gc cr blocks received');

-- Cluster Wait Class 상위 이벤트
SELECT inst_id, event, total_waits, time_waited
FROM   gv$system_event
WHERE  wait_class = 'Cluster'
ORDER  BY time_waited DESC;

-- 노드 간 블록 이동 유형별 통계
SELECT * FROM gv$instance_cache_transfer;

-- 세그먼트별 Cache Fusion 통계
SELECT * FROM gv$segment_statistics
WHERE  statistic_name LIKE 'gc%'
ORDER  BY value DESC;

-- Enqueue 대기 통계 (TX/TM — 트랜잭션·DML 락 경합)
SELECT inst_id, eq_type, total_req#, total_wait#, cum_wait_time
FROM   gv$enqueue_statistics
WHERE  eq_type IN ('TX','TM');

-- Enqueue 대기 통계 (HW — HWM 경합)
SELECT inst_id, eq_type, total_req#, total_wait#, cum_wait_time
FROM   gv$enqueue_statistics
WHERE  eq_type = 'HW';

-- 테이블스페이스 세그먼트 관리 방식 확인
SELECT tablespace_name, segment_space_management
FROM   dba_tablespaces
WHERE  tablespace_name = '<TS명>';

-- Sequence 설계 변경 (인덱스 리프 블록 경합 완화)
ALTER SEQUENCE <시퀀스명> CACHE <값> NOORDER;

/* OS/Clusterware 명령 — DB 전체(양 인스턴스) 재기동, 누적 통계 리셋 용도
$ srvctl stop database -d orcl
$ srvctl start database -d orcl
*/

-- AWR 리포트 생성 (Cluster 섹션 중심으로 확인)
@?/rdbms/admin/awrrpt.sql
