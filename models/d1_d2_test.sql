{{
  config(
    materialized='incremental',
    unique_key='audit_date'
  )
}}

WITH detail_max AS (
    SELECT MAX(TRANSACTION_DATE) AS detail_max_date
    FROM {{ source('sf_prod', 'SF_EXEC_DETAIL_DASHBOARD') }}
    WHERE TRANSACTION_DATE >= DATEADD(day, -7, CURRENT_DATE)
),

total_max AS (
    SELECT MAX(TRANSACTION_DATE) AS total_max_date
    FROM {{ source('sf_prod', 'SF_EXEC_DASHBOARD') }}
    WHERE TRANSACTION_DATE >= DATEADD(day, -7, CURRENT_DATE)
),

reporting_date_check AS (
    SELECT
        DATEADD(day, -1, CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::DATE) AS rpt_date,
        d.detail_max_date,
        t.total_max_date,
        CASE
            WHEN d.detail_max_date = DATEADD(day, -1, CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::DATE)
             AND t.total_max_date = DATEADD(day, -1, CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::DATE)
            THEN 'FRESH'
            ELSE 'STALE'
        END AS freshness_status
    FROM detail_max d
    CROSS JOIN total_max t
),

division_1_sales AS (
    SELECT
        SUM(a11.SALES_NET_AMOUNT) AS d1_sales
    FROM {{ source('sf_prod', 'SF_EXEC_DETAIL_DASHBOARD') }} AS a11
    JOIN {{ source('sf_prod', 'SF_SKU_CATEGORIES') }} AS a12 ON a11.SKU_ID = a12.SKU_ID
    JOIN (
        SELECT DISTINCT
            a11.DIVISION AS DIVISION_NO,
            a11.DEPARTMENT_ID,
            MAX(DEPARTMENT) AS DEPARTMENT
        FROM {{ source('sf_prod', 'SF_SKU_CATEGORIES') }} AS a11
        GROUP BY a11.DIVISION, a11.DEPARTMENT_ID
    ) AS a13 ON a12.DEPARTMENT_ID = a13.DEPARTMENT_ID
    JOIN (
        SELECT DISTINCT
            SSP.STORE_NO,
            UPPER(SSP.CHANNEL) AS CHANNEL
        FROM {{ source('sf_prod', 'SF_STORE_SPACE') }} AS SSP
        LEFT JOIN {{ source('sf_prod', 'STORE_SA') }} AS SA ON SA.STORE_NO = SSP.STORE_NO
        WHERE SSP.Open_Date <= GETDATE() OR SSP.open_date IS NULL
    ) AS a14 ON a11.STORE_NO = a14.STORE_NO
    WHERE
        a13.DIVISION_NO = 1
        AND a14.CHANNEL IN ('RETAIL', 'DIRECT', 'MARKETPLACES', 'WAREHOUSE')
        AND a11.TRANSACTION_DATE = (SELECT rpt_date FROM reporting_date_check)
),

division_2_sales AS (
    SELECT
        SUM(a11.SALES_NET_AMOUNT) AS d2_sales
    FROM {{ source('sf_prod', 'SF_EXEC_DETAIL_DASHBOARD') }} AS a11
    JOIN {{ source('sf_prod', 'SF_SKU_CATEGORIES') }} AS a12 ON a11.SKU_ID = a12.SKU_ID
    JOIN (
        SELECT DISTINCT
            a11.DIVISION AS DIVISION_NO,
            a11.DEPARTMENT_ID,
            MAX(DEPARTMENT) AS DEPARTMENT
        FROM {{ source('sf_prod', 'SF_SKU_CATEGORIES') }} AS a11
        GROUP BY a11.DIVISION, a11.DEPARTMENT_ID
    ) AS a13 ON a12.DEPARTMENT_ID = a13.DEPARTMENT_ID
    JOIN (
        SELECT DISTINCT
            SSP.STORE_NO,
            UPPER(SSP.CHANNEL) AS CHANNEL
        FROM {{ source('sf_prod', 'SF_STORE_SPACE') }} AS SSP
        LEFT JOIN {{ source('sf_prod', 'STORE_SA') }} AS SA ON SA.STORE_NO = SSP.STORE_NO
        WHERE SSP.Open_Date <= GETDATE() OR SSP.open_date IS NULL
    ) AS a14 ON a11.STORE_NO = a14.STORE_NO
    WHERE
        a13.DIVISION_NO = 2
        AND a14.CHANNEL IN ('RETAIL', 'DIRECT', 'MARKETPLACES', 'WAREHOUSE')
        AND a11.TRANSACTION_DATE = (SELECT rpt_date FROM reporting_date_check)
),

total_sales AS (
    SELECT
        SUM(a11.SALES_NET_AMOUNT) AS total_sales
    FROM {{ source('sf_prod', 'SF_EXEC_DASHBOARD') }} AS a11
    JOIN (
        SELECT DISTINCT
            SSP.STORE_NO,
            UPPER(SSP.CHANNEL) AS CHANNEL
        FROM {{ source('sf_prod', 'SF_STORE_SPACE') }} AS SSP
        LEFT JOIN {{ source('sf_prod', 'STORE_SA') }} AS SA ON SA.STORE_NO = SSP.STORE_NO
        WHERE SSP.Open_Date <= GETDATE() OR SSP.open_date IS NULL
    ) AS a12 ON a11.STORE_NO = a12.STORE_NO
    WHERE
        a12.CHANNEL IN ('RETAIL', 'DIRECT', 'MARKETPLACES', 'WAREHOUSE')
        AND a11.TRANSACTION_DATE = (SELECT rpt_date FROM reporting_date_check)
),

final_values AS (
    SELECT
        r.rpt_date                                                                       AS transaction_date,
        r.rpt_date                                                                       AS audit_date,
        r.freshness_status,
        r.detail_max_date,
        r.total_max_date,
        ROUND(d1.d1_sales / 1000000, 1)                                                 AS d1_sales,
        ROUND(d2.d2_sales / 1000000, 1)                                                 AS d2_sales,
        ROUND(t.total_sales / 1000000, 1)                                               AS expected_total,
        CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())                       AS run_timestamp
    FROM reporting_date_check r
    CROSS JOIN division_1_sales d1
    CROSS JOIN division_2_sales d2
    CROSS JOIN total_sales t
)

SELECT
    transaction_date,
    audit_date,
    CASE WHEN freshness_status = 'STALE' THEN NULL ELSE d1_sales END                                        AS d1_sales,
    CASE WHEN freshness_status = 'STALE' THEN NULL ELSE d2_sales END                                        AS d2_sales,
    CASE WHEN freshness_status = 'STALE' THEN NULL ELSE d1_sales + d2_sales END                             AS d1_d2_sum,
    CASE WHEN freshness_status = 'STALE' THEN NULL ELSE expected_total END                                  AS expected_total,
    CASE WHEN freshness_status = 'STALE' THEN NULL ELSE expected_total - (d1_sales + d2_sales) END          AS difference,
    CASE
        WHEN freshness_status = 'STALE' THEN
            'FAIL - LAST AVAILABLE DATE IN DETAIL TABLE: ' || detail_max_date || ' | TOTAL TABLE: ' || total_max_date
        WHEN ABS(expected_total - (d1_sales + d2_sales)) > 0.1 THEN 'FAIL'
        ELSE 'PASS'
    END                                                                                                      AS audit_status,
    run_timestamp
FROM final_values
