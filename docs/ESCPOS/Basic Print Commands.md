**## 2.2 Basic Print Commands**

### LF

**[Name]** Print and line feed

**[Format]**  
ASCII: LF  
Hex: 0A  
Decimal: 10

**[Range]** — (no parameters)

**[Description]**  
Prints the data in the print buffer and feeds one line based on the current line spacing.

**[Notes]**  
- This is the most commonly used command to advance to the next line after printing text.  
- The line spacing is controlled by ESC 2 or ESC 3 n.  
- In page mode, this command only moves the print position downward by the current line spacing (no actual printing occurs until FF or ESC FF).

**[Reference]** CR, ESC 2, ESC 3 n

### CR

**[Name]** Carriage return

**[Format]**  
ASCII: CR  
Hex: 0D  
Decimal: 13

**[Range]** — (no parameters)

**[Description]**  
Moves the print position to the beginning of the current line.

**[Notes]**  
- This command does not feed paper/line.  
- Commonly used together with LF (CR+LF) to simulate typewriter-style line ending.  
- In many implementations, CR alone has no visible effect if not followed by LF.  
- In page mode, this command moves the print position to the left margin of the current line.

**[Reference]** LF

### FF

**[Name]** Print and return to standard mode (Form Feed / Page Feed)

**[Format]**  
ASCII: FF  
Hex: 0C  
Decimal: 12

**[Range]** — (no parameters)

**[Description]**  
- In **standard mode**: Prints the data in the buffer and cuts the paper (if auto-cut is enabled).  
- In **page mode**: Prints the entire page (virtual page data) and returns the printer to **standard mode**.

**[Notes]**  
- This is the standard way to finish and eject a receipt in page mode.  
- Behavior in standard mode may vary depending on whether the printer supports auto paper cut.  
- After execution, all page mode data is cleared.

**[Reference]** ESC FF, ESC L, ESC S

### ESC FF

**[Name]** Print data in page mode

**[Format]**  
ASCII: ESC FF  
Hex: 1B 0C  
Decimal: 27 12

**[Range]** — (no parameters)

**[Description]**  
In **page mode** only: Prints all buffered data in the current page without clearing the page buffer and without returning to standard mode.

**[Notes]**  
- Unlike FF, this command keeps the printer in page mode and preserves the page data.  
- Useful when printing multiple copies of the same page layout or when needing to print incrementally.  
- Has no effect in standard mode.

**[Reference]** FF, ESC L (select page mode)

### ESC J n

**[Name]** Print and feed paper

**[Format]**  
ASCII: ESC J n  
Hex: 1B 4A n  
Decimal: 27 74 n

**[Range]**  
0 ≤ n ≤ 255

**[Default]** n = 0 (no feed)

**[Description]**  
Prints the data in the print buffer and feeds the paper n × (vertical motion unit) dots.

**[Notes]**  
- The vertical motion unit is usually set by GS P x y (default 1/180 or 1/203 inch depending on model).  
- Commonly used for fine paper feed control (e.g., extra spacing before cutting).  
- In page mode, this only moves the current print position downward (no actual paper feed occurs until printing).

**[Reference]** GS P x y, ESC d n

### ESC K n

**[Name]** Reverse feed paper (some models only)

**[Format]**  
ASCII: ESC K n  
Hex: 1B 4B n  
Decimal: 27 75 n

**[Range]**  
0 ≤ n ≤ 255

**[Description]**  
Feeds the paper backward n × (vertical motion unit) dots.

**[Notes]**  
- Not supported on all thermal printers (many have no reverse feed capability).  
- When supported, it is useful for adjusting print position or creating overlays.  
- In page mode, moves the print position upward instead of feeding paper backward.

**[Important]** This command may be ignored or cause an error on printers without reverse paper feed mechanism.

**[Reference]** ESC J n

### ESC d n

**[Name]** Print and feed n lines

**[Format]**  
ASCII: ESC d n  
Hex: 1B 64 n  
Decimal: 27 100 n

**[Range]**  
1 ≤ n ≤ 255

**[Description]**  
Prints the data in the print buffer and feeds the paper n lines based on the current line spacing.

**[Notes]**  
- Very useful for adding blank lines after printing text.  
- Equivalent to sending LF command n times.  
- In page mode, moves the print position downward by n × current line spacing.

**[Reference]** LF, ESC 2, ESC 3 n

### ESC e n

**[Name]** Print and reverse feed n lines (some models)

**[Format]**  
ASCII: ESC e n  
Hex: 1B 65 n  
Decimal: 27 101 n

**[Range]**  
1 ≤ n ≤ 255

**[Description]**  
Prints the data in the print buffer and feeds the paper backward n lines.

**[Notes]**  
- Like ESC K n, reverse feed is not supported on most thermal printers.  
- When supported, equivalent to sending reverse line feed n times.  
- In page mode, moves the print position upward by n lines.

**[Important]** This command is often unsupported or ignored on modern thermal receipt printers.

**[Reference]** ESC K n, ESC d n

---

These commands are the core printing and paper feeding operations in ESC/POS.  
They are used in almost every receipt printing job.  
The most frequently used are: **LF**, **ESC J n**, **ESC d n**, and **FF** (for finalizing receipts).