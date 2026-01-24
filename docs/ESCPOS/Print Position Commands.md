**## 2.3 Print Position Commands**

### HT

**[Name]** Horizontal tab

**[Format]**  
ASCII: HT  
Hex: 09  
Decimal: 9

**[Range]** — (no parameters)

**[Description]**  
Moves the print position to the next horizontal tab position.

**[Notes]**  
- Horizontal tab positions are set by the command **ESC D**.  
- If no tab positions are set, HT moves to the beginning of the next line (like LF).  
- If the current position is already at or past the last tab position, the printer moves to the beginning of the next line.

**[Reference]** ESC D

### ESC D n1 ... nk NUL

**[Name]** Set horizontal tab positions

**[Format]**  
ASCII: ESC D n1 n2 ... nk NUL  
Hex: 1B 44 n1 n2 ... nk 00  
Decimal: 27 68 n1 n2 ... nk 0

**[Range]**  
1 ≤ n ≤ 255  
k ≤ 32 (maximum 32 tab positions)

**[Description]**  
Sets the positions of the horizontal tabs.  
The tab positions are specified as the number of characters from the left margin (in current character width).

**[Notes]**  
- Tab positions must be specified in ascending order.  
- The command is terminated by **NUL** (00h).  
- Setting n = 0 clears all previously set tab positions.  
- Default tab positions (after printer initialization): every 8 characters (positions 9, 17, 25, ...).

**[Reference]** HT

### ESC $ nL nH

**[Name]** Set absolute print position

**[Format]**  
ASCII: ESC $ nL nH  
Hex: 1B 24 nL nH  
Decimal: 27 36 nL nH

**[Range]**  
0 ≤ nL ≤ 255  
0 ≤ nH ≤ 255  
0 ≤ (nH × 256 + nL) ≤ 65535

**[Description]**  
Moves the print position to the specified absolute horizontal position (in dots) from the left margin.  
Position = (nH × 256 + nL) dots

**[Notes]**  
- The horizontal motion unit is normally 1/203 inch (≈ 0.125 mm) or set by **GS P**.  
- This command is very useful for precise column alignment in receipts.  
- Works in both standard mode and page mode.  
- If the specified position exceeds the printable area, it is usually ignored or wrapped (depending on printer).

**[Reference]** GS P, ESC \ 

### ESC \ nL nH

**[Name]** Set relative print position

**[Format]**  
ASCII: ESC \ nL nH  
Hex: 1B 5C nL nH  
Decimal: 27 92 nL nH

**[Range]**  
-32768 ≤ (nH × 256 + nL) ≤ 32767  
(Two's complement when negative)

**[Description]**  
Moves the print position **relative** to the current position.  
Positive value → moves right  
Negative value → moves left  
Distance = (nH × 256 + nL) dots

**[Notes]**  
- Useful for micro-adjustments, underlining specific parts, or creating simple tables.  
- The motion unit is the same as **ESC $** (usually dots).  
- If the resulting position is outside the printable area, behavior may vary.

**[Reference]** ESC $

### GS L nL nH

**[Name]** Set left margin

**[Format]**  
ASCII: GS L nL nH  
Hex: 1D 4C nL nH  
Decimal: 29 76 nL nH

**[Range]**  
0 ≤ (nH × 256 + nL) ≤ 65535  
(must be less than the printable area width)

**[Description]**  
Sets the left margin position (in dots) from the beginning of the paper.

**[Notes]**  
- The left margin affects the starting position of text and alignment.  
- This command is valid only when processed at the beginning of a line.  
- Commonly used to create indented receipts or align multiple columns.

**[Reference]** GS W, ESC a

### GS W nL nH

**[Name]** Set printing area width

**[Format]**  
ASCII: GS W nL nH  
Hex: 1D 57 nL nH  
Decimal: 29 87 nL nH

**[Range]**  
0 ≤ (nH × 256 + nL) ≤ 65535  
(must not exceed physical printable width)

**[Description]**  
Sets the width of the printing area (in dots) starting from the current left margin.

**[Notes]**  
- This command defines the maximum width for text wrapping and justification.  
- Must be executed at the beginning of a line.  
- Default value is usually the full printable width of the printer (e.g., 384 dots for 80mm paper at 203 dpi).

**[Reference]** GS L

### ESC a n

**[Name]** Select justification

**[Format]**  
ASCII: ESC a n  
Hex: 1B 61 n  
Decimal: 27 97 n

**[Range]**  
0 ≤ n ≤ 2, 48 ≤ n ≤ 50

**[Description]**  
Selects the alignment (justification) of characters in the printing area:

| n   | Alignment     |
|-----|---------------|
| 0, 48 | Left justification |
| 1, 49 | Centering       |
| 2, 50 | Right justification |

**[Notes]**  
- This command is effective only at the beginning of a line.  
- Justification is applied when **LF**, **CR**, **ESC J**, **ESC d**, or **FF** is received.  
- Works in both standard mode and page mode.

**[Default]** n = 0 (left justification)

**[Reference]** GS L, GS W

### GS T n

**[Name]** Select print area for cutting / Select cut position

**[Format]**  
ASCII: GS T n  
Hex: 1D 54 n  
Decimal: 29 84 n

**[Range]**  
n = 0, 1, 48, 49

**[Description]**  
Selects the cutting position relative to the current print position:

| n   | Position                     |
|-----|------------------------------|
| 0, 48 | Cuts at the current position |
| 1, 49 | Cuts after feeding to the cut position |

**[Notes]**  
- Mainly used with printers that have a fixed cutting position.  
- This command helps align the cut line properly on receipts.

**[Reference]** GS V

### ESC W xL xH yL yH dxL dxH dyL dyH

**[Name]** Set print area in page mode

**[Format]**  
ASCII: ESC W xL xH yL yH dxL dxH dyL dyH  
Hex: 1B 57 xL xH yL yH dxL dxH dyL dyH  
Decimal: 27 87 xL xH yL yH dxL dxH dyL dyH

**[Range]**  
0 ≤ xL, xH, yL, yH, dxL, dxH, dyL, dyH ≤ 255  
0 ≤ (xH × 256 + xL) ≤ 65535  
0 ≤ (yH × 256 + yL) ≤ 65535  
1 ≤ (dxH × 256 + dxL) ≤ 65535  
1 ≤ (dyH × 256 + dyL) ≤ 65535

**[Description]**  
In **page mode** only: defines the printing area with  
- (xL xH, yL yH) = origin coordinates (top-left corner)  
- (dxL dxH, dyL dyH) = width and height of the printing area (in dots)

**[Notes]**  
- Must be used in page mode (after **ESC L**).  
- Coordinates are measured from the origin point set by **ESC T**.  
- This is one of the most important commands for complex layouts in page mode.

**[Reference]** ESC L, ESC T

### ESC T n

**[Name]** Select print direction in page mode

**[Format]**  
ASCII: ESC T n  
Hex: 1B 54 n  
Decimal: 27 84 n

**[Range]**  
n = 0, 1, 2, 3

**[Description]**  
Selects the print direction and starting position in page mode:

| n | Direction               | Origin position |
|---|-------------------------|-----------------|
| 0 | Left to right, top to bottom | Top-left       |
| 1 | Bottom to top, left to right | Bottom-left    |
| 2 | Right to left, bottom to top | Bottom-right   |
| 3 | Top to bottom, right to left | Top-right      |

**[Notes]**  
- Only effective in page mode.  
- Commonly used with **ESC W** to define the coordinate system.

**[Reference]** ESC L, ESC W

### GS $ nL nH

**[Name]** Set absolute vertical print position in page mode

**[Format]**  
ASCII: GS $ nL nH  
Hex: 1D 24 nL nH  
Decimal: 29 36 nL nH

**[Range]**  
0 ≤ (nH × 256 + nL) ≤ 65535

**[Description]**  
Sets the absolute vertical position (in dots) from the origin in page mode.

**[Notes]**  
- Only valid in page mode.  
- Works in conjunction with the direction set by **ESC T**.

**[Reference]** ESC T, GS \

### GS \ nL nH

**[Name]** Set relative vertical print position in page mode

**[Format]**  
ASCII: GS \ nL nH  
Hex: 1D 5C nL nH  
Decimal: 29 92 nL nH

**[Range]**  
-32768 ≤ (nH × 256 + nL) ≤ 32767 (signed)

**[Description]**  
Moves the vertical print position relative to the current position in page mode.

**[Notes]**  
- Positive value moves in the paper feed direction.  
- Negative value moves backward.  
- Only valid in page mode.

**[Reference]** GS $

---

These commands are essential for controlling precise positioning, especially when creating structured receipts, tables, or complex layouts using **page mode**.  
The most frequently used are **ESC $**, **ESC a**, **HT**, and the page mode positioning commands (**ESC W**, **ESC T**, **GS $**, **GS \**).