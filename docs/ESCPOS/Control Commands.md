**## 2.12 Control Commands**

### ESC p m t1 t2

**[Name]** Generate pulse (open drawer / kick-out connector)

**[Format]**  
ASCII: ESC p m t1 t2  
Hex: 1B 70 m t1 t2  
Decimal: 27 112 m t1 t2

**[Range]**  
m = 0, 1, 48, 49  
0 ≤ t1 ≤ 255  
0 ≤ t2 ≤ 255

**[Description]**  
Outputs a pulse to connector pin m (drawer kick-out) for the specified on/off times.

- **m** selects the drawer connector pin:  
  - 0, 48 → Drawer kick-out connector pin 2  
  - 1, 49 → Drawer kick-out connector pin 5  

- **t1** = on time (pulse width) = t1 × 2 ms  
- **t2** = off time (delay before next pulse) = t2 × 2 ms

**[Notes]**  
- This is the standard command used to open a cash drawer connected to the printer.  
- The pulse is generated immediately upon receiving the command.  
- Minimum recommended values: t1 ≥ 20 (40 ms), t2 ≥ 20 (40 ms) — most cash drawers require at least 20–50 ms pulse.  
- t1 and t2 are limited to 510 ms maximum (t = 255 × 2 ms).  
- If the drawer is already being driven, a new pulse request is ignored until the current one finishes.

**[Default]** — (no default — parameters required)

**[Reference]** — (commonly used with cash drawer systems)

---

### ESC FS & SP V1 do "reset_printer" CR LF

**[Name]** Restart printer (soft reset)

**[Format]**
ASCII: ESC FS & SP V1 do "reset_printer" CR LF
Hex: 1B 1C 26 20 56 31 20 64 6F 20 22 72 65 73 65 74 5F 70 72 69 6E 74 65 72 22 0D 0A
Decimal: 27 28 38 32 86 49 32 100 111 32 34 114 101 115 101 116 95 112 114 105 110 116 101 114 34 13 10

**[Description]**
Performs a soft restart of the printer. This command is required after certain configuration changes to take effect, such as enabling/disabling the speaker or changing volume settings.

**[Notes]**
- This is a Custom-specific V1 protocol command.
- The printer will reinitialize after receiving this command.
- Used in conjunction with parameter zone commands (unlock_para, save_param_zone) when modifying speaker settings.
- The command string "reset_printer" is enclosed in quotes as part of the V1 command syntax.

**[Reference]** Custom printer V1 protocol documentation

---

This is the only command listed under **Section 2.12 Control Commands** in the ESC/POS Programming Manual Rev.1.1.

The ESC p command is one of the most important peripheral control commands in retail/point-of-sale applications, used almost universally for opening cash drawers after a transaction is completed.

If your printer model supports additional control commands not shown in this section, they may appear in manufacturer-specific extensions.

