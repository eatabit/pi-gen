## 2.4 Basic Character Commands

### ESC SP n

**[Name]** Set right-side character spacing

**[Format]** ASCII ESC SP n Hex 1b 20 n Decimal 27 32 n

**[Range]** $0 \le n \le 255$

**[Default]** $n = 0$

**[Description]** Sets the right-side character spacing to $n \times (\text{horizontal or vertical motion unit})$.

**[Notes]** * The maximum character spacing on the right side is 31.875 millimeters (203/180\"). * The next (character width+character right spacing) exceeds the maximum printable width and jumps to the beginning of the next line for printing.

### ESC ! n

**[Name]** Select print mode(s)

**[Format]** ASCII ESC ! n Hex 1b 21 n Decimal 27 33 n

**[Range]** $0 \le n \le 255$

**[Default]** $n = 0$

**[Description]** Selects the character font and styles (emphasized, double-height, double-width, and underline) together as follows:

| n: | Bit | Off/On | Hex | Decimal | Function |
|----|-----|--------|-----|---------|----------|
| 0  | OFF | 00     | 0   | 0       | Character font 1 selected. |
|    | ON  | 01     | 1   | 1       | Character font 2 selected. |
| 1, 2 | OFF | 00   | 0   | 0       | Undefined. |
|    | ON  | 00     | 0   | 0       | Emphasized mode is turned off. |
| 3  | OFF | 00     | 0   | 0       | Emphasized mode is turned on. |
|    | ON  | 08     | 8   | 8       | Double-height canceled. |
| 4  | OFF | 00     | 0   | 0       | Double-height selected. |
|    | ON  | 10     | 16  | 16      | Double-width canceled. |
| 5  | OFF | 00     | 0   | 0       | Double-width selected. |
|    | ON  | 20     | 32  | 32      | Underline mode is turned off. |
| 6  | OFF | 00     | 0   | 0       | Underline mode is turned on. |
|    | ON  | 80     | 128 | 128     | Underline mode is turned on. |

### ESC M n

**[Name]** Select character font

**[Format]** ASCII ESC M n Hex 1b 4d n Decimal 27 77 n

**[Range]** n = 0, 1, 48, 49

**[Default]** n = 0

**[Description]** Selects a character font, using n as follows:

| n    | Function          |
|------|-------------------|
| 0.48 | Font A: (12 × 24) |
| 1.49 | Font B: (9 × 17)  |

**[Notes]**

• The command ESC ! can also be used to set the font, and the final received command is valid.

• If the font to be set is not configured in the font library, the instruction is invalid.

**[Description]** ESC !

### ESC E n

**[Name]** Turn emphasized mode on/off

**[Format]** ASCII ESC E n Hex 1b 45 n Decimal 27 69 n

**[Range]** 0 ≤ n ≤ 255

**[Default]** n = 0

**[Description]** Turns emphasized mode on or off.

• When the LSB of n is 0, emphasized mode is turned off.

• When the LSB of n is 1, emphasized mode is turned on.

**[Notes]**

• Only the lowest value of n is valid.

• ESC ! command can also select/cancel bold mode, and the last received command is valid.

• Bold and double print ESC G commands can be cancelled from each other, and the last received command is valid.

**[Reference]** ESC !

### ESC G n

**[Name]** Turn double-strike mode on/off

**[Format]** ASCII ESC G n Hex 1b 47 n Decimal 27 71 n

**[Range]** 0 ≤ n ≤ 255

**[Default]** n = 0

**[Description]** Turns double-strike mode on or off.

• When the LSB of n is 0, double-strike mode is turned off.

• When the LSB of n is 1, double-strike mode is turned on.

**[Notes]**

• Only the lowest value of n is valid.

• This command has the same effect as bold printing.

• Bold and double print ESC G commands can be cancelled from each other, and the last received command is valid.

**[Reference]** ESC E

### ESC - n

**[Name]** Turn underline mode on/off

**[Format]** ASCII ESC - n Hex 1b 2d n Decimal 27 45 n

**[Range]** 0 ≤ n ≤ 2, 48 ≤ n ≤ 50

**[Description]** Turns underline mode on or off using n as follows:

| n    | Function                          |
|------|-----------------------------------|
| 0, 48| turns off underline mode          |
| 1, 49| turns on underline mode (1-dot thick) |
| 2, 50| Turns on underline mode (2-dot thick) |

**[Notes]**

• The underline can be added under all characters (including right spacing, spaces), but not including spaces set by HT.

• When underline mode is turned on, 90° clockwise rotated characters and white/black reverse characters cannot be underlined.

• When underline mode is turned off, the following data cannot be underlined, but the thickness is maintained. The default width is 1-dot thick.

• Changing the character size does not affect the current underline thickness.

• This command and bit 7 of ESC ! turn on and off underline mode in the same way. The last executed command is valid.

**[Default]** n = 0

**[Reference]** ESC !

### GS ! n

**[Name]** Select character size

**[Format]** ASCII GS ! n Hex 1d 21 n Decimal 29 33 n

**[Range]** 0 ≤ n ≤ 255 (1 ≤ height ≤ 8, 1 ≤ width ≤ 8)

**[Description]** Selects the character height (vertical number of times normal font size) using bits 0 to 3 and selects the character width (horizontal number of times normal font size) using bits 4 to 7, as follows:

| Bit | Function |
| --- | --- |
| 0-3 | Character width selection, see Table 2 |
| 4-7 | Character height selection, see Table 1 |

Table 1 Character width selection

| Hex | Decimal | Width |
|---|---|---|
| 00 | 0 | 1 (normal) |
| 10 | 16 | 2 (double width) |
| 20 | 32 | 3 |
| 30 | 48 | 4 |
| 40 | 64 | 5 |
| 50 | 80 | 6 |
| 60 | 96 | 7 |
| 70 | 112 | 8 |

Table 2 Character height selection

| Hex | Decimal | Height |
|---|---|---|
| 00 | 0 | 1 (normal) |
| 01 | 1 | 2 (double height) |
| 02 | 2 | 3 |
| 03 | 3 | 4 |
| 04 | 4 | 5 |
| 05 | 5 | 6 |
| 06 | 6 | 7 |
| 07 | 7 | 8 |

**[Notes]** • This instruction is valid for all characters (ASCII characters and Chinese characters), except for HRI characters. • If n is outside the defined range, the command is ignored. • In standard mode, the character is enlarged in the paper feed direction when double-height mode is selected, and it is enlarged perpendicular to the paper feed direction when double-width mode is selected. However, when character orientation changes in 90° clockwise rotation mode, the relationship between double-height and double-width is reversed. • In page mode, double-height and double-width are on the character orientation. • When the characters are enlarged with different heights on one line, all the characters on the line are aligned at the baseline. • ESC ! can also turn double-width and double-height modes on or off.

**[Default]** n = 0

**[Reference]** ESC !

### ESC V n

**[Name]** Turn 90° clockwise rotation mode on/off

**[Format]** ASCII ESC V n Hex 1b 56 n Decimal 27 86 n

**[Range]** 0 ≤ n ≤ 2, 48 ≤ n ≤ 50

**[Default]** n = 0

**[Description]** In standard mode, turns 90° clockwise rotation mode on or off for characters, using n as follows:

| n    | Function                          |
|------|-----------------------------------|
| 0, 48| Turns off 90° clockwise rotation mode. |
| 1, 49| Turns on 90° clockwise rotation mode. |
| 2, 50|                                   |

**[Notes]**

• This command is effective only in the standard mode.

• When underline mode is turned on, the printer does not underline 90° clockwise-rotated characters.

• When character orientation changes in 90° clockwise rotation mode, the relationship between vertical and horizontal directions is reversed.

**[Reference]** ESC !, ESC -

### ESC { n

**[Name]** Turn upside-down print mode on/off

**[Format]** ASCII ESC { n Hex 1b 7b n Decimal 27 123 n

**[Range]** 0 ≤ n ≤ 255

**[Default]** n = 0

**[Description]** In standard mode, turns upside-down print mode on or off.

• When the LSB of n is 0, upside-down print mode is turned off.

• When the LSB of n is 1, upside-down print mode is turned on.

**[Notes]**

• Only the lowest value of n is valid.

• When standard mode is selected, this command is enabled only when processed at the beginning of the line.

• If this command is processed in page mode, an internal flag is activated, and this flag is enabled when the printer returns to standard mode.

**[Example]**

### GS B n

**[Name]** Turn white/black reverse print mode on/off

**[Format]** ASCII GS B n Hex 1d 42 n Decimal 29 66 n

**[Range]** 0 ≤ n ≤ 255

**[Description]** Turns white/black reverse print mode on or off.

• When the LSB of n is 0, white/black reverse print mode is turned off.

• When the LSB of n is 1, white/black reverse print mode is turned on.

**[Notes]**

• Only the lowest value of n is valid.

• This command is valid for all characters except for HRI characters.

• When white/black reverse print mode is turned on, it also affects the right-side character spacing set by ESC SP.

• This command does not affect bitmap, custom bitmap, barcode, HRI character, or HT, ESC $, and ESC \\ setting blank.

• When white/black reverse print mode is turned on, it does not affect the space between lines.

• In white/black reverse print mode, characters are printed in white on a black background. When underline mode is turned on, the printer does not underline white/black reverse characters.

**[Default]** n = 0

### ESC R n

**[Name]** Select an international character set

**[Format]** ASCII ESC R n Hex 1b 52 n Decimal 27 82 n

**[Range]** 0 ≤ n ≤ 15

**[Default]** N=0 [Other than the following model] n=15 [Simplified Chinese model]

**[Description]** Selects an international character set n as follows:

| n | Country       | n  | Country          |
|---|---------------|----|------------------|
| 0 | U.S.A.        | 8  | Japan            |
| 1 | France        | 9  | Norway           |
| 2 | Germany       | 10 | Denmark II       |
| 3 | U.K.          | 11 | Spain II         |
| 4 | Denmark I     | 12 | Latin America    |
| 5 | Sweden        | 13 | Korea            |
| 6 | Italy         | 14 | Slovenia / Croatia |
| 7 | Spain I       | 15 | China            |

**[Note]** • Only Font 0 and Font 1 fonts have international character sets. This instruction is invalid in other fonts.

### ESC t n

**[Name]** Select character code table

**[Format]** ASCII ESC t n Hex 1b 74 n Decimal 27 116 n

**[Range]** 0≤n≤5; 13≤n≤21;n=26; 32≤n≤34;n=36,37; 39≤n≤40; 45≤n≤52

**[Default]** n = 0

**[Description]** Selects a page n from the character code table as follows:

| n  | Character code table                  | n  | Character code table                |
|----|---------------------------------------|----|-------------------------------------|
| 0  | [PC437 (USA: Standard Europe)]        | 40 | [ISO8859-15 (Latin9)]               |
| 1  | [Katakana]                            | 45 | [WPC1250]                           |
| 2  | [PC850 (Multilingual)]                | 46 | [WPC1251(Cyrillic)]                 |
| 3  | [PC860 (Portuguese)]                  | 47 | [WPC1253]                           |
| 4  | [PC863 (Canadian-French)]             | 48 | [WPC1254]                           |
| 5  | [PC865 (Nordic)]                      | 49 | [WPC1255]                           |
| 13 | [PC857 (Turkish)]                     | 50 | [WPC1256]                           |
| 14 | [PC737 (Greek)]                       | 51 | [WPC1257]                           |
| 15 | [ISO8859-7 (Greek)]                   | 52 | [WPC1258]                           |
| 16 | [WPC1252]                             | 54 | [MIK(Cyrillic /Bulgarian)]          |
| 17 | [PC866 (Cyrillic #2)]                 | 55 | [CP755 (East Europe, Latvian 2)]    |
| 18 | [PC852 (Latin 2)]                     | 56 | [Iran]                              |
| 19 | [PC858 (Euro)]                        | 57 | [Iran II]                           |
| 20 | [KU42]                                | 58 | [Latvian]                           |
| 21 | [TIS11 (Thai)]                        | 59 | [ISO-8859-1 (West Europe)]          |
| 26 | [TIS18 (Thai)]                        | 60 | [ISO-8859-3(Latin 3)]               |
| 32 | [PC720]                               | 61 | [ISO-8859-4(Baltic)]                |
| 33 | [WPC775]                              | 62 | [ISO-8859-5(Cyrillic)]              |
| 34 | [PC855 (Cyrillic)]                    | 63 | [ISO-8859-6(Arabic)]                |
| 36 | [PC862 (Hebrew)]                      | 64 | [ISO-8859-8(Hebrew)]                |
| 37 | [PC864 (Arabic)]                      | 65 | [ISO-8859-9(Turkish)]               |
| 39 | [ISO8859-2 (Latin2)]                  | 66 | [PC856]                             |
|    |                                       | 67 | [ABICOMP]                           |

**[Notes]** Page 0/page 2/page 3/page 4/page 5/ page 14/page 17/ page 18/ page 19/ page 20/ page 21/ page 26/page 32 /page 47 Supports both 12x24 and 9x17 fonts.