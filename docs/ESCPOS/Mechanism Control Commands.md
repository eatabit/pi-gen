Here is **Section 2.11 Mechanism Control Commands** converted to clean Markdown format, based on the structure and content style of the ESC/POS Programming Manual (Rev.1.1):

## 2.11 Mechanism Control Commands

### ESC i

**[Name]** Partial cutter cut (one point left uncut)

**[Format]**  
ASCII: ESC i  
Hex: 1B 69  
Decimal: 27 105

**[Range]** — (no parameters)

**[Description]**  
Executes a partial cut (one point left uncut) of the paper.

**[Notes]**  
- This command is executed when it is received.  
- This is a real-time command.  
- The printer executes this command even if it is in the middle of receiving another command sequence.  
- If a full cut is required instead of partial, use ESC m.

**[Reference]** ESC m, GS V

### ESC m

**[Name]** Full cutter cut

**[Format]**  
ASCII: ESC m  
Hex: 1B 6D  
Decimal: 27 109

**[Range]** — (no parameters)

**[Description]**  
Executes a full cut of the paper.

**[Notes]**  
- This command is executed when it is received.  
- This is a real-time command.  
- The printer executes this command even if it is in the middle of receiving another command sequence.  
- If only a partial cut (one point uncut) is desired, use ESC i instead.

**[Reference]** ESC i, GS V

### GS V

**[Name]** Select cut mode and cut paper / Execute paper cut

**[Format]**  
There are two formats:

1. **ASCII**: GS V m  
   **Hex**: 1D 56 m  
   **Decimal**: 29 86 m

2. **ASCII**: GS V m n  
   **Hex**: 1D 56 m n  
   **Decimal**: 29 86 m n

**[Range]**  
- 0 ≤ m ≤ 3, 48 ≤ m ≤ 51  
- When m = 66: 0 ≤ n ≤ 255

**[Description]**  
Executes paper cutting with different modes according to the value of m:

| m    | Function                                                                 |
|------|--------------------------------------------------------------------------|
| 0, 48| Full cut                                                                 |
| 1, 49| Partial cut (one point left uncut)                                       |
| 2, 50| Feeds paper [n × vertical or horizontal motion unit] and performs full cut |
| 3, 51| Feeds paper [n × vertical or horizontal motion unit] and performs partial cut (one point left uncut) |
| 66   | Feeds paper to the cutting position and performs cut (full or partial depending on printer setting) |

**[Notes]**  
- This command is executed when it is received.  
- This is a real-time command.  
- When m = 2 or 3, the paper is fed by the amount calculated from parameter n and the currently set vertical or horizontal motion unit.  
- When m = 66, the printer feeds to the next cutting position regardless of the current line position and then cuts.  
- The actual cutting mode (full or partial) for m = 66 may depend on the printer's internal setting or model.

**[Default]** — (no default)

**[Reference]** ESC i, ESC m

This section includes the three main mechanism control commands commonly found in ESC/POS printers for paper cutting operations. Let me know if you need another section converted!