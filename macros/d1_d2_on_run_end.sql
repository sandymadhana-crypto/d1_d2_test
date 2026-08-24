{% macro d1_d2_on_run_end() %}
    {% do run_query("EXECUTE ALERT DBT_BI_DEV.D1_D2_TEST.D1_D2_TEST_AUDIT_ALERT") %}
    {{ log("d1_d2_test_audit_alert triggered", info=true) }}
{% endmacro %}
