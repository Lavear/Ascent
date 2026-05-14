#!/bin/bash
echo "===================================================================================="
echo "                      ASCENT FULL PPA ABLATION SUMMARY                              "
echo "===================================================================================="
printf "%-15s | %-12s | %-15s | %-15s\n" "Design Stage" "Area (Cells)" "Power (mW)" "Delay/Slack"
echo "------------------------------------------------------------------------------------"

# Function to safely extract and calculate
get_data() {
    LABEL=$1
    FILE_A=$2
    FILE_P=$3
    FILE_T=$4
    PATTERN=$5

    AREA=$(grep "$PATTERN" "$FILE_A" | tail -1 | awk '{print $2}')
    PWR_RAW=$(grep "$PATTERN" "$FILE_P" | tail -1 | awk '{print $NF}')
    
    # Check if we are looking for Slack (Full Sys) or Data Path (Baselines)
    if [[ "$LABEL" == *"Full Sys"* ]]; then
        TIME=$(grep "Slack:=" "$FILE_T" | awk '{print $NF}')
        TIME_LABEL="Slack: $TIME"
    else
        TIME=$(grep "Data Path:-" "$FILE_T" | awk '{print $NF}')
        TIME_LABEL="$TIME ps"
    fi

    PWR_MW=$(echo "scale=3; $PWR_RAW / 1000000" | bc -l)
    printf "%-15s | %-12s | %-15.3f | %-15s\n" "$LABEL" "$AREA" "$PWR_MW" "$TIME_LABEL"
}

get_data "0/3 (Standard)" "reports/area_0_3_baseline.rpt" "reports/power_0_3_baseline.rpt" "reports/timing_0_3_baseline.rpt" "std_mult"
get_data "1/3 (LOA Mult)" "reports/area_1_3_loa.rpt" "reports/power_1_3_loa.rpt" "reports/timing_1_3_loa.rpt" "loa_mult"
get_data "2/3 (CIM Array)" "reports/area_2_3_cim.rpt" "reports/power_2_3_cim.rpt" "reports/timing_2_3_cim.rpt" "cim_array"
get_data "3/3 (Full Sys)" "reports/area_report.rpt" "reports/power_report.rpt" "reports/timing_report.rpt" "ascent_top"

echo "===================================================================================="
