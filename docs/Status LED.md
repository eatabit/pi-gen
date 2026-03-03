# RPi Zero 2 W Boot Status LED

## Hardware
- LED: WP154A4SUREQBFZGC (Kingbright T-1 3/4 RGB, **common cathode**)
- Pin 1: Red anode, Pin 2: Common cathode, Pin 3: Blue anode, Pin 4: Green anode
- Vf: Red 1.9V typ, Blue 3.3V typ, Green 3.3V typ
- Max IF: Red 30mA, Blue 30mA, Green 25mA
- GPIO logic: HIGH = ON, LOW = OFF

## Wiring
- GPIO 17 → 150Ω → Red (Pin 1)
- GPIO 22 → 33Ω → Green (Pin 4)
- GPIO 27 → 33Ω → Blue (Pin 3)
- GND → Cathode (Pin 2)

## Boot Behavior
- Solid blue on early boot (config.txt gpio directive, before kernel)
- Flashing blue on successful OS boot (systemd service at multi-user.target)
- Green when connected to AWS IoT (mqtt-client.service)
- Red on boot failure (systemd emergency/rescue target)