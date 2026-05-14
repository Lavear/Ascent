# ####################################################################

#  Created by Genus(TM) Synthesis Solution 17.21-s010_1 on Thu May 14 14:37:54 IST 2026

# ####################################################################

set sdc_version 2.0

set_units -capacitance 1000.0fF
set_units -time 1000.0ps

# Set the current design
current_design ascent_top

create_clock -name "clk" -period 2.0 -waveform {0.0 1.0} [get_ports clk]
set_clock_gating_check -setup 0.0 
set_input_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports clk]
set_input_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports rst_n]
set_input_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports uart_rx]
set_output_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports uart_tx]
set_output_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports {pred_leds[3]}]
set_output_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports {pred_leds[2]}]
set_output_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports {pred_leds[1]}]
set_output_delay -clock [get_clocks clk] -add_delay 0.5 [get_ports {pred_leds[0]}]
set_wire_load_mode "enclosed"
set_dont_use [get_lib_cells typical/HOLDX1]
set_clock_uncertainty -setup 0.1 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]
