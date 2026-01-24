## 2.13 Beeper Commands

### ESC ( A pL pH fn n c t1 t2  <Function 97>

**[Name]**  
Control beeper (sound a beep pattern)

**[Format]**  
ASCII: ESC ( A pL pH fn n c t1 t2  
Hex:    1B 28 41 pL pH 61 n c t1 t2  
Decimal: 27 40 65 pL pH 97 n c t1 t2

**[Range]**  
(pL + pH × 256) = 4 (fixed)  
fn = 97 (fixed for beeper control)  
0 ≤ n ≤ 255  
1 ≤ c ≤ 20  (number of beep cycles)  
1 ≤ t1 ≤ 255  (beep ON time, unit: 10 ms)  
1 ≤ t2 ≤ 255  (beep OFF time, unit: 10 ms)

**[Description]**  
Sounds the internal/external beeper according to the specified pattern.

- **n**: Selects the beeper tone (frequency)  
  - n = 0 → 3.0 kHz  
  - n = 1 → 3.3 kHz  
  - n = 2 → 3.6 kHz  
  - n = 3 → 4.0 kHz  
  - Other values may be ignored or use default tone (usually 3.0 kHz)

- **c**: Number of beep cycles (repetitions)  
- **t1 × 10 ms**: Duration the beeper is ON  
- **t2 × 10 ms**: Duration the beeper is OFF between cycles

**[Example]**  
To emit 3 short beeps (100 ms on, 100 ms off, 3 kHz tone):  
`ESC ( A 04 00 61 00 03 0A 0A`  
→ pL=4, pH=0, fn=97, n=0, c=3, t1=10 (100 ms), t2=10 (100 ms)

**[Notes]**  
- This is the standard ESC/POS beeper command supported by most HPRT, Epson-compatible, and many other thermal receipt printers that have a built-in beeper.  
- The command is executed immediately when received (real-time behavior on many models).  
- Not all printers have a beeper; on models without one, the command is ignored.  
- Maximum beep duration per cycle is 255 × 10 ms = 2.55 seconds.  
- The beeper continues even if the printer goes offline or runs out of paper (useful for error alerts).

**[Default]**  
None (parameters must be specified)

This is the only command listed under **Section 2.13 Beeper Commands** in the HPRT ESC/POS Programming Manual Rev.1.1.  
It is widely used in retail environments to give audible feedback (e.g., order ready, error, drawer opened, etc.).