create_clock -name clk -period 2.0 [get_ports clk]; set_clock_uncertainty 0.1 [get_clocks clk]; set_input_delay 0.5 -clock clk [all_inputs]; set_output_delay 0.5 -clock clk [all_outputs]
