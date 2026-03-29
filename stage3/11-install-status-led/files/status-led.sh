#!/bin/bash -e
#
# status-led.sh - Control the RGB status LED
# Usage: status-led.sh {red|green|blue|flash-blue|off}
#
# LED hat (common anode): LOW = ON, HIGH = OFF
# Uses pinctrl (compatible with firmware-claimed GPIOs from config.txt)
#

RED_PIN=9
BLUE_PIN=10
GREEN_PIN=11

gpio_set() {
    local pin=$1 value=$2
    if [ "$value" -eq 1 ]; then
        pinctrl set "$pin" op dl
    else
        pinctrl set "$pin" op dh
    fi
}

case "${1}" in
    red)
        gpio_set $RED_PIN 1
        gpio_set $BLUE_PIN 0
        gpio_set $GREEN_PIN 0
        ;;
    green)
        gpio_set $RED_PIN 0
        gpio_set $BLUE_PIN 0
        gpio_set $GREEN_PIN 1
        ;;
    blue)
        gpio_set $RED_PIN 0
        gpio_set $BLUE_PIN 1
        gpio_set $GREEN_PIN 0
        ;;
    flash-blue)
        gpio_set $RED_PIN 0
        gpio_set $GREEN_PIN 0
        while true; do
            pinctrl set $BLUE_PIN op dl
            sleep 0.5
            pinctrl set $BLUE_PIN op dh
            sleep 0.5
        done
        ;;
    off)
        gpio_set $RED_PIN 0
        gpio_set $BLUE_PIN 0
        gpio_set $GREEN_PIN 0
        ;;
    *)
        echo "Usage: $0 {red|green|blue|flash-blue|off}" >&2
        exit 1
        ;;
esac
