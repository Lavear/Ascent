## PYNQ-Z2 Constraints for your project

## Clock signal (125 MHz)
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { clk_125 }];
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { clk_125 }];

## LEDs (pred_leds[3:0])
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { pred_leds[0] }];
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { pred_leds[1] }];
set_property -dict { PACKAGE_PIN N16   IOSTANDARD LVCMOS33 } [get_ports { pred_leds[2] }];
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { pred_leds[3] }];

## Reset Button (btn_rst_n) - Mapping to the "BTN0" button
set_property -dict { PACKAGE_PIN D19   IOSTANDARD LVCMOS33 } [get_ports { btn_rst_n }];

## UART (uart_rx and uart_tx) - Mapping to the RPi or PMOD header? 
## Note: PYNQ-Z2 typically uses the USB-UART through the Zynq PS. 
## If you are using physical pins on the Raspberry Pi Header (RX=Pin 10, TX=Pin 8):
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports { uart_rx }]; # RPi UART RX
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports { uart_tx }]; # RPi UART TX