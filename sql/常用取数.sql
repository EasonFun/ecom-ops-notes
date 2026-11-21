-- ============================================================
-- 电商运营常用取数 SQL
--
-- 表结构是「示例」，按自己库里的实际字段改。约定：
--   orders        订单主表  (order_id, buyer_id, pay_time, pay_amount, freight, status)
--   order_items   订单明细  (order_id, product_id, qty, amount)
--   products      商品表    (product_id, title, category)
--   refunds       退款表    (order_id, refund_time, refund_amount)
--   traffic_daily 流量日表  (stat_date, visitors, pv)
--   ad_cost_daily 推广日表  (stat_date, scene, cost, gmv)
--
-- 所有查询默认：只算「已支付」订单，按 pay_time 归日，只算商品金额不含运费。
-- ============================================================


-- ------------------------------------------------------------
-- 1. 日粒度经营：GMV / 买家数 / 客单价 / UV 价值
-- ------------------------------------------------------------
SELECT
    DATE(o.pay_time)                                   AS stat_date,
    SUM(o.pay_amount)                                  AS gmv,
    COUNT(DISTINCT o.buyer_id)                         AS buyers,
    COUNT(DISTINCT o.order_id)                         AS orders,
    ROUND(SUM(o.pay_amount) / NULLIF(COUNT(DISTINCT o.buyer_id), 0), 2) AS aov,
    ROUND(SUM(o.pay_amount) / NULLIF(t.visitors, 0), 2)                 AS uv_value,
    ROUND(COUNT(DISTINCT o.buyer_id) * 1.0 / NULLIF(t.visitors, 0), 4)  AS pay_cvr
FROM orders o
LEFT JOIN traffic_daily t
       ON t.stat_date = DATE(o.pay_time)
WHERE o.status IN ('paid', 'shipped', 'finished')
  AND o.pay_time >= :start_date
  AND o.pay_time <  :end_date
GROUP BY DATE(o.pay_time), t.visitors
ORDER BY stat_date;


-- ------------------------------------------------------------
-- 2. 转化漏斗：访客 -> 加购 -> 下单 -> 支付
--    （加购/下单表按实际情况替换，很多平台需要从埋点表取）
-- ------------------------------------------------------------
SELECT
    t.stat_date,
    t.visitors                                        AS uv_stage1,
    c.add_cart_uv                                     AS uv_stage2,
    o.order_uv                                        AS uv_stage3,
    p.pay_uv                                          AS uv_stage4,
    ROUND(c.add_cart_uv * 1.0 / NULLIF(t.visitors, 0), 4) AS add_cart_rate,
    ROUND(p.pay_uv     * 1.0 / NULLIF(o.order_uv, 0), 4)  AS order_to_pay_rate
FROM traffic_daily t
LEFT JOIN (SELECT DATE(event_time) d, COUNT(DISTINCT buyer_id) add_cart_uv
             FROM events WHERE event_name = 'add_cart' GROUP BY 1) c ON c.d = t.stat_date
LEFT JOIN (SELECT DATE(order_time) d, COUNT(DISTINCT buyer_id) order_uv
             FROM orders WHERE status <> 'cancelled' GROUP BY 1) o ON o.d = t.stat_date
LEFT JOIN (SELECT DATE(pay_time) d, COUNT(DISTINCT buyer_id) pay_uv
             FROM orders WHERE status IN ('paid','shipped','finished') GROUP BY 1) p ON p.d = t.stat_date
WHERE t.stat_date >= :start_date AND t.stat_date < :end_date
ORDER BY t.stat_date;


-- ------------------------------------------------------------
-- 3. 退款率：金额口径 + 笔数口径（关键：退款归到哪天）
--    mode A 按退款发生日；mode B 回溯原订单支付日
-- ------------------------------------------------------------
-- A. 按退款发生日（当日实收视角）
SELECT
    DATE(r.refund_time)                                AS stat_date,
    SUM(r.refund_amount)                               AS refund_amt,
    COUNT(DISTINCT r.order_id)                         AS refund_orders
FROM refunds r
WHERE r.refund_time >= :start_date AND r.refund_time < :end_date
GROUP BY DATE(r.refund_time);

-- B. 回溯到原订单支付日（财务/净 GMV 视角）
SELECT
    DATE(o.pay_time)                                   AS stat_date,
    SUM(o.pay_amount)                                  AS gmv,
    COALESCE(SUM(r.refund_amount), 0)                  AS refund_amt,
    ROUND(COALESCE(SUM(r.refund_amount), 0) / NULLIF(SUM(o.pay_amount), 0), 4) AS refund_rate
FROM orders o
LEFT JOIN (SELECT order_id, SUM(refund_amount) refund_amount
             FROM refunds GROUP BY order_id) r ON r.order_id = o.order_id
WHERE o.status IN ('paid','shipped','finished')
  AND o.pay_time >= :start_date AND o.pay_time < :end_date
GROUP BY DATE(o.pay_time)
ORDER BY stat_date;


-- ------------------------------------------------------------
-- 4. 商品 Top 50（按支付金额，含件数、买家数、退款率）
-- ------------------------------------------------------------
SELECT
    i.product_id,
    MAX(p.title)                                       AS title,
    SUM(i.amount)                                      AS gmv,
    SUM(i.qty)                                         AS qty,
    COUNT(DISTINCT o.buyer_id)                         AS buyers,
    ROUND(SUM(i.amount) / NULLIF(SUM(i.qty), 0), 2)    AS avg_price,
    ROUND(COALESCE(SUM(r.refund_amount), 0) / NULLIF(SUM(i.amount), 0), 4) AS refund_rate
FROM order_items i
JOIN orders    o ON o.order_id = i.order_id
LEFT JOIN products p ON p.product_id = i.product_id
LEFT JOIN (SELECT order_id, product_id, SUM(refund_amount) refund_amount
             FROM refunds GROUP BY order_id, product_id) r
       ON r.order_id = i.order_id AND r.product_id = i.product_id
WHERE o.status IN ('paid','shipped','finished')
  AND o.pay_time >= :start_date AND o.pay_time < :end_date
GROUP BY i.product_id
ORDER BY gmv DESC
LIMIT 50;


-- ------------------------------------------------------------
-- 5. 新老客拆分（首单口径：历史首次支付即为新客）
-- ------------------------------------------------------------
WITH first_pay AS (
    SELECT buyer_id, MIN(DATE(pay_time)) AS first_date
    FROM orders
    WHERE status IN ('paid','shipped','finished')
    GROUP BY buyer_id
)
SELECT
    DATE(o.pay_time)                                   AS stat_date,
    CASE WHEN f.first_date = DATE(o.pay_time) THEN 'new' ELSE 'old' END AS buyer_type,
    COUNT(DISTINCT o.buyer_id)                         AS buyers,
    SUM(o.pay_amount)                                  AS gmv,
    ROUND(SUM(o.pay_amount) / NULLIF(COUNT(DISTINCT o.buyer_id), 0), 2) AS aov
FROM orders o
JOIN first_pay f ON f.buyer_id = o.buyer_id
WHERE o.status IN ('paid','shipped','finished')
  AND o.pay_time >= :start_date AND o.pay_time < :end_date
GROUP BY DATE(o.pay_time), buyer_type
ORDER BY stat_date, buyer_type;


-- ------------------------------------------------------------
-- 6. 同比 / 环比（窗口函数）
--    注意：比对「昨天」不如比对「上周同一天」，周一必跌不是问题
-- ------------------------------------------------------------
WITH daily AS (
    SELECT DATE(pay_time) AS stat_date, SUM(pay_amount) AS gmv
    FROM orders
    WHERE status IN ('paid','shipped','finished')
    GROUP BY DATE(pay_time)
)
SELECT
    stat_date,
    gmv,
    LAG(gmv, 1)  OVER (ORDER BY stat_date)             AS gmv_prev_day,
    LAG(gmv, 7)  OVER (ORDER BY stat_date)             AS gmv_prev_week,
    ROUND(gmv / NULLIF(LAG(gmv, 7) OVER (ORDER BY stat_date), 0) - 1, 4) AS wow,
    ROUND(gmv / NULLIF(LAG(gmv, 364) OVER (ORDER BY stat_date), 0) - 1, 4) AS yoy
FROM daily
ORDER BY stat_date;


-- ------------------------------------------------------------
-- 7. 近 30 天滚动均值（做异常检测的基线，压住单日噪声）
-- ------------------------------------------------------------
SELECT
    stat_date,
    gmv,
    ROUND(AVG(gmv) OVER (ORDER BY stat_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING), 2) AS ma30,
    ROUND(gmv - AVG(gmv) OVER (ORDER BY stat_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING), 2) AS diff_vs_ma30,
    ROUND(gmv / NULLIF(AVG(gmv) OVER (ORDER BY stat_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING), 0) - 1, 4) AS pct_vs_ma30
FROM (SELECT DATE(pay_time) stat_date, SUM(pay_amount) gmv
      FROM orders
      WHERE status IN ('paid','shipped','finished')
      GROUP BY DATE(pay_time)) d
ORDER BY stat_date;


-- ------------------------------------------------------------
-- 8. 推广有效 ROI（剔除退款后才是真实回报）
--    很多计划账面 ROI 3.0，退款率 40% 后只有 1.8
-- ------------------------------------------------------------
SELECT
    a.stat_date,
    a.scene,
    SUM(a.cost)                                        AS cost,
    SUM(a.gmv)                                         AS gmv,
    ROUND(SUM(a.gmv) / NULLIF(SUM(a.cost), 0), 2)      AS roi,
    ROUND(SUM(a.gmv * (1 - COALESCE(rr.refund_rate, 0))) / NULLIF(SUM(a.cost), 0), 2) AS valid_roi
FROM ad_cost_daily a
LEFT JOIN (
    SELECT DATE(o.pay_time) d,
           CASE WHEN SUM(r.refund_amount) > 0
                THEN SUM(r.refund_amount) / NULLIF(SUM(o.pay_amount), 0) ELSE 0 END AS refund_rate
    FROM orders o
    LEFT JOIN (SELECT order_id, SUM(refund_amount) refund_amount FROM refunds GROUP BY order_id) r
           ON r.order_id = o.order_id
    WHERE o.status IN ('paid','shipped','finished')
    GROUP BY DATE(o.pay_time)
) rr ON rr.d = a.stat_date
WHERE a.stat_date >= :start_date AND a.stat_date < :end_date
GROUP BY a.stat_date, a.scene
ORDER BY a.stat_date, cost DESC;


-- ------------------------------------------------------------
-- 9. 异常日定位：和「前 7 天均值」比，偏离超过 30% 的日子
-- ------------------------------------------------------------
WITH daily AS (
    SELECT DATE(pay_time) AS stat_date, SUM(pay_amount) AS gmv
    FROM orders
    WHERE status IN ('paid','shipped','finished')
    GROUP BY DATE(pay_time)
), base AS (
    SELECT stat_date, gmv,
           AVG(gmv) OVER (ORDER BY stat_date ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING) AS ma7
    FROM daily
)
SELECT stat_date, gmv, ROUND(ma7, 2) AS ma7,
       ROUND(gmv / NULLIF(ma7, 0) - 1, 4) AS pct_vs_ma7
FROM base
WHERE ma7 IS NOT NULL
  AND ABS(gmv / NULLIF(ma7, 0) - 1) >= 0.3
ORDER BY ABS(gmv / NULLIF(ma7, 0) - 1) DESC;
