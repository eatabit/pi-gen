**## 2.1 Basic Setting Commands**

### ESC @

**[Name]** Initialize printer

**[Format]**  
ASCII: ESC @  
Hex: 1B 40  
Decimal: 27 64

**[Range]** — (no parameters)

**[Description]**  
Initializes the printer to the following default settings:

- Clears the print buffer  
- Returns to standard mode (not page mode)  
- Clears all downloaded characters and bit images  
- Resets print modes (character size, bold, double-strike, underline, etc.) to defaults  
- Resets line spacing to default (ESC 2)  
- Resets print position to the beginning of the line  
- Clears any error conditions (where possible)

**[Notes]**  
This is the recommended command to send at the beginning of every print job.

**[Default]** — (command has no parameters)

### GS P x y

**[Name]** Set horizontal and vertical motion units

**[Format]**  
ASCII: GS P x y  
Hex: 1D 50 x y  
Decimal: 29 80 x y

**[Range]**  
0 ≤ x ≤ 255  
0 ≤ y ≤ 255  
x ≠ 0, y ≠ 0 (when x=0 or y=0 the setting is ignored)

**[Default]**  
x = 180, y = 180 (typically 1/180 inch for both directions)

**[Description]**  
Sets the horizontal and vertical motion units to approximately 25.4/x mm and 25.4/y mm respectively.

These units are used by the following commands:  
- ESC SP (right-side character spacing)  
- ESC 3 (line spacing)  
- ESC J (paper feed)  
- GS L / GS W (left margin / print area width)  
- and several others

**[Notes]**  
The actual resolution depends on the printer's DPI (usually 203 dpi).  
The minimum motion unit is normally about 0.125 mm (≈ 1/203 inch).

### ESC 2

**[Name]** Select default line spacing

**[Format]**  
ASCII: ESC 2  
Hex: 1B 32  
Decimal: 27 50

**[Range]** — (no parameters)

**[Description]**  
Selects the line spacing to 1/6 inch (≈ 4.23 mm) — the printer's default line spacing.

**[Notes]**  
This is equivalent to approximately 36/180 or 36/203 dots depending on printer resolution.  
Most thermal printers use ESC 2 as the standard single line feed spacing.

**[Default]** This is the power-on default line spacing.

**[Reference]** ESC 3 n

### ESC 3 n

**[Name]** Set line spacing

**[Format]**  
ASCII: ESC 3 n  
Hex: 1B 33 n  
Decimal: 27 51 n

**[Range]**  
0 ≤ n ≤ 255

**[Default]**  
n = 64 (≈ 1/6 inch or 36/180 units)

**[Description]**  
Sets the line spacing to n × (vertical motion unit) inches.

The vertical motion unit is usually set by GS P x y (default 1/180 inch).

**[Notes]**  
Common values:  
- n = 32 → ≈ 1/9 inch (very tight)  
- n = 64 → ≈ 1/6 inch (standard single line)  
- n = 96 → ≈ 1/4 inch (double spacing)

**[Reference]** GS P x y, ESC 2

### ESC S

**[Name]** Select standard mode

**[Format]**  
ASCII: ESC S  
Hex: 1B 53  
Decimal: 27 83

**[Description]**  
Switches the printer to **standard mode** (also called line mode).

In standard mode, the printer prints and feeds paper immediately when:  
- the line buffer is full, or  
- a print command (LF, CR, FF, etc.) is received.

**[Notes]**  
This is the power-on default mode.  
Page mode (ESC L) is used for more complex layouts.

**[Reference]** ESC L

### ESC L

**[Name]** Select page mode

**[Format]**  
ASCII: ESC L  
Hex: 1B 4C  
Decimal: 27 76

**[Description]**  
Switches the printer to **page mode**.

In page mode:  
- All data is stored in memory as a virtual page  
- Nothing is printed until FF or ESC FF is received  
- Allows absolute positioning and complex layouts

**[Notes]**  
Page mode is useful for printing forms, tables, or receipts with precise positioning.  
To return to standard mode, use ESC S or ESC @ (initialize).

**[Reference]** ESC S, ESC @, FF, ESC FF

### CAN

**[Name]** Cancel current print data

**[Format]**  
ASCII: CAN  
Hex: 18  
Decimal: 24

**[Range]** — (no parameters)

**[Description]**  
Clears all data in the current print buffer (print buffer and line buffer).

**[Notes]**  
This command is useful when the host wants to abort the current receipt/line.  
It does **not** reset printer settings (unlike ESC @).  
It does **not** cut paper or feed paper.

**[Reference]** ESC @ (for full reset)

---

These are the **Basic Setting Commands** found in Section 2.1 of the manual.  
They are typically used at the beginning of a print job or to configure fundamental printer behavior.