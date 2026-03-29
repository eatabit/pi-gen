# RPi Zero 2 W Boot Status LED

## Hardware
- LED hat PCB with RGB LED (**common anode**), see schematic: `docs/LED hat/image.png`
- Common anode tied to +3.3V, GPIO pins sink current through resistors
- GPIO logic: LOW = ON, HIGH = OFF (active low)

## Wiring
- +3.3V → Common anode (J1 Pin 1)
- GPIO 10 → Blue (J1 Pin 2), R2 = 220Ω
- GPIO 9 → Red (J1 Pin 3), R3 = 10Ω
- GPIO 11 → Green (J1 Pin 4), R1 = 10Ω

## Boot Behavior
- Solid blue on early boot (config.txt gpio directive, before kernel)
- Flashing blue on successful OS boot (systemd service at multi-user.target)
- Green when connected to AWS IoT (mqtt-client.service)
- Red on boot failure (systemd emergency/rescue target)
