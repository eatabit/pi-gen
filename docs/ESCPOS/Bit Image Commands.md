## 2.7 Bit Image Commands

### ESC * m nL nH d1 ... dk

**[Name]** Select bit-image mode

**[Format]**  
ASCII ESC * m nL nH d1...dk  
Hex 1B 2A m nL nH d1...dk  
Decimal 27 42 m nL nH d1...dk

**[Range]**  
m = 0, 1, 32, 33  
0 ≤ nL ≤ 255  
0 ≤ nH ≤ 3  
0 ≤ d ≤ 25

**[Description]**  
The bit image modes selectable by m are as follows:

| m  | Bit Image Mode       | Vertical dot density | Horizontal dot density |
|----|----------------------|----------------------|------------------------|
| 0  | 8-dot single-density | 68 dpi              | 101 dpi               |
| 1  | 8-dot double-density | 68 dpi              | 203 dpi               |
| 32 | 24-dot single-density| 203 dpi             | 101 dpi               |
| 33 | 24-dot double-density| 203 dpi             | 203 dpi               |

dpi: dots per 25.4 mm (dots per inch)

**[Notes]**  
* If the value of m exceeds the specified range, nL and subsequent data are treated as normal data.  
* nL, nH specifies a bit image in the horizontal direction as (nL + nH × 256) dots.  
* If the bit image data exceeds the number of dots to be printed on a line, the excess data is ignored.  
* d specifies the bit image data (column format). Data (d) specifies a bit printed to 1 and not printed to 0.  
* After printing a bit image, the printer processes normal data.  
* If the printing area set by GS L and GS W is smaller than the required printing width of instruction GS/, the following actions will be executed immediately (but not exceeding the maximum printing width):  
  1. Expand the printing area to the right to accommodate the data volume of the printed bitmap  
  2. If step ① cannot provide sufficient width for the data, the left edge is reduced to fit the data. For each bit of data in single density mode (m=0, 32), the printer prints two dots; for each bit of data in dual density mode (m=1, 33), the printer prints one dot. When calculating the amount of data that can be printed in a row, these must be taken into account.  
* After printing a bitmap, the printer returns to normal data processing mode.  
* Except for the inverted mode, this instruction is not affected by other printing modes (bold, double print, underline, character enlargement, and reverse).  
* The relationship between data and the points to be printed is as follows:  

When selecting an 8-dot density:  
[Diagram: Shows bitmap data (d1, d2, d3) mapping to highest and lowest positions in single density and double density print data, where 1 dot is printed per bit in double density, and 2 dots per bit in single density.]

When selecting a 24-dot density:  
[Diagram: Shows bitmap data (d1 to d9) mapping to highest and lowest positions in single density and double density print data, similar to above.]

### FS q n [xL xH yL yH d1...dk]1...[xL xH yL yH d1...dk]n

Recommend using the GS (L (Function 69) command instead of the FS p command, as it is compatible with the FS p command upwards

**[Name]** Define NV bit image

**[Format]**  
ASCII FS q n [xL xH yL yH d1...dk]...[xL xH yL yH d1...dk]  
Hex 1C 71 n [xL xH yL yH d1...dk]...[xL xH yL yH d1...dk]  
Decimal 28 113 n [xL xH yL yH d1...dk]...[xL xH yL yH d1...dk]

**[Range]**  
1 ≤ n ≤ 255  
0 ≤ xL ≤ 255  
1 ≤ (xL + xH × 256) ≤ 1023  
1 ≤ (yL + yH × 256) ≤ 800  
0 ≤ d ≤ 255  
k = (xL + xH × 256) × (yL + yH × 256) × 8  
The definition area is maximum 64 KB

**[Description]**  
Defines the NV bit image in the NV graphics area.  
• n specifies the number of defined NV bit images.  
• xL, xH specifies (xL + xH × 256) bytes in the horizontal direction for the NV bit image you defined.  
• yL, yH specifies (yL + yH × 256) bytes in the vertical direction for the NV bit image you defined.

**[Notes]**  
• The commands such as bold, overlap, underline, character size, and reverse printing are invalid for this bitmap, but the reverse printing mode setting is valid.  
• In page mode, print the lower image in normal mode normally.

### FS p n m

Recommend using the GS (L (Function 69) command instead of the FS p command, as it is compatible with the FS p command upwards

**[Name]** Print NV bit image

**[Format]**  
ASCII FS p n m  
Hex 1C 70 n m  
Decimal 28 112 n m

**[Range]**  
1 ≤ n ≤ 255, 0 ≤ m ≤ 3, 48 ≤ m ≤ 51

**[Description]**  
Prints NV bit image n using the process of FS q and using the mode specified by m.

| m    | Mode          | Vertical Dot density | Horizontal Dot |
|------|---------------|----------------------|----------------|
| 0, 48| Normal        | 203 dpi             | 203 dpi       |
| 1, 49| Double-width  | 203 dpi             | 101 dpi       |
| 2, 50| Double-height | 101 dpi             | 203 dpi       |
| 3, 51| Quadruple     | 101 dpi             | 101 dpi       |

### GS * x y d1...dk

**[Name]** Define downloaded bit image

**[Format]**  
ASCII GS * x y d1... dk  
Hex 1D 2A x y d1... dk  
Decimal 29 42 x y d1... dk

**[Range]**  
1 ≤ x ≤ 255  
1 ≤ y ≤ 48 [when 1 ≤ x × y ≤ 1536]  
0 ≤ d ≤ 255  
k = x × y × 8

**[Description]**  
Defines the downloaded bit image in the downloaded graphic area.  
• x specifies the number of bytes in horizontal direction as x bytes.  
• y specifies the number of bytes in vertical direction as y bytes.

**[Notes]**  
• A downloaded bit image and a user-defined character cannot be defined simultaneously. When this command is executed, the user-defined character is cleared.  
• Continuously define 2 down conversion bitmaps, with the last one being valid.  
• This command is not affected by the printing mode (bold, overlapping, underline, character size, or reversed printing), but the reverse printing mode setting is valid.

### GS / m

**[Name]** Print downloaded bit image

**[Format]**  
ASCII GS / m  
Hex 1D 2F m  
Decimal 29 47 m

**[Range]**  
0 ≤ m ≤ 3, 48 ≤ m ≤ 51

**[Description]**  
Prints downloaded bit image using the mode specified by m, as follows:

| m    | Mode          | Vertical Dot density | Horizontal Dot density |
|------|---------------|----------------------|------------------------|
| 0,48 | Normal        | 203 dpi             | 203 dpi               |
| 1,49 | Double-width  | 203 dpi             | 101 dpi               |
| 2,50 | Double-height | 101 dpi             | 203 dpi               |
| 3,51 | Quadruple     | 101 dpi             | 101 dpi               |

**[Notes]**  
• This command is ignored if a downloaded bit image has not been defined.  
• The printer is in the beginning of a line and data is not in the print buffer.  
The downloaded bit image is not affected by print mode (emphasized, double-strike, underline, character size, or white/black reverse printing), except for upside-down print mode.  
If a downloaded bit image exceeds one line, the excess data is not printed.  
If the printing area set by GS L and GS W is smaller than the width required for the data transmitted by GS/command, perform the following subsequent operations on the problematic line [printing does not exceed the maximum print area].  
① The width of the printing area is expanded to the right to accommodate the amount of data.  
② If step ① does not provide sufficient width for the data, the left margin is reduced to accommodate the data. For each bit of data in normal mode (m = 0,48) and double high mode (m = 2, 50), the printer prints a point; For each bit of data in double width mode (m = 1, 49) and quadruple mode (m = 3, 51), the printer prints two points.

### GS v 0 m xL xH yL yH d1....dk

**[Name]** Print raster bit image

**[Format]**  
ASCII GS v 0 m xL xH yL yH d1....dk  
Hex 1D 76 30 m xL xH yL yH d1....dk  
Decimal 29 118 48 m xL xH yL yH d1....dk

**[Range]**  
0 ≤ m ≤ 3, 48 ≤ m ≤ 51  
0 ≤ xL ≤ 255  
0 ≤ xH ≤ 255  
0 ≤ yL ≤ 255  
0 ≤ d ≤ 255  
k = (xL + xH × 256) × (yL + yH × 256) (k ≠ 0)

**[Description]**  
Prints a raster bit image using the mode specified by m, as follows:

| m    | Mode          | Vertical Dot density | Horizontal Dot density |
|------|---------------|----------------------|------------------------|
| 0, 48| Normal        | 203 DPI             | 203 DPI               |
| 1, 49| Double-width  | 203 DPI             | 101 DPI               |
| 2, 50| Double-height | 101DPI              | 203 DPI               |
| 3, 51| Quadruple     | 101DPI              | 101 DPI               |

• xL, xH specifies (xL + xH × 256) bytes in horizontal direction for the bit image.  
• yL, yH specifies (yL + yH × 256) dots in vertical direction for the bit image.  
• d specifies the bit image data (raster format).

**[Notes]**  
• When standard mode is selected, this command is enabled only when there is no data in the print buffer.  
• The raster bit image is not affected by print modes (emphasized, double-strike, underline, character size, white/black reverse printing, or upside-down printing).  
• If a raster bit image exceeds one line, the excess data is not printed.  
• ESC a (select alignment mode) is effective for raster bitmap.  
• If this command is processed while a macro is being defined, the printer cancels macro definition, clears the definition, and prints a raster bit image.  
• d specifies the bit image data (raster format). Data (d) specifies a bit printed to 1 and not printed to 0.

**[Reference]** FS p

### GS ( L & GS 8 L

**[Name]** Set graphics data

**[Description]** Processes graphics data.  
* Function code (fn) specifies the function.

| fn    | Function No. | Function name                              |
|-------|--------------|--------------------------------------------|
| 0,48  | 48           | Transmit the NV graphics memory capacity.  |
| 1,49  | 49           | Set the reference standard dot density for graphics. |
| 2,50  | 50           | Print the graphics data in the print buffer. |
| 3,51  | 51           | Transmit the remaining capacity of the NV graphics memory. |
| 4,52  | 52           | Transmit the remaining capacity of the download graphics memory. |
| 64    | 64           | Transmit the key code list for defined NV graphics. |
| 65    | 65           | Delete all NV graphics data.               |
| 66    | 66           | Delete the specified NV graphics data.     |
| 67    | 67           | Define the NV graphics data (raster format). |
| 68    | 68           | Define the NV graphics data (column format). |
| 69    | 69           | Print the specified NV graphics data.      |
| 80    | 80           | Transmit the key code list for defined download graphics. |
| 81    | 81           | Delete all download graphics data.         |
| 82    | 82           | Delete the specified download graphics data. |
| 83    | 83           | Define the downloaded graphics data (raster format). |
| 84    | 84           | Define the downloaded graphics data (column format). |
| 85    | 85           | Print the specified download graphics data. |
| 112   | 112          | Store the graphics data in the print buffer (raster format). |
| 113   | 113          | Store the graphics data in the print buffer (column format). |

* pL, pH specifies (pL + pH × 256) as the number of bytes after pH (m, fn, and [parameters]).  
* p1, p2, p3, and p4 specify (p1 + p2 × 256 + p3 × 65536 + p4 × 16777216) as the number of bytes after pH (m, fn, and [parameters]).  
* Differences between GS (L and GS 8 L  
* All commands possess the same functions for "Graphics data processing."  
* Specifications (conventions) concerning function code (fn) are identical, while only the parameters (pL, pH, p1, p2, p3, and p4) used to specify the parameter values from m differ.

| Command | Description |
|---------|-------------|
| GS ( L | Parameter value is 2 bytes less than that for GS 8 L. Used to fix the parameter value. Used when sending data divided into blocks. |
| GS 8 L | Possesses powerful range of expression. Used for batch transfer of large volumes of data. |

* Be sure to use GS 8 L when the parameter value exceeds 65535 bytes for Functions 67, 68, 83, 84, 112, and 113.

**[Recommended Functions]**  
* This command is recommended for use when printing image data.  
* The image processing controlled using this command is referred to as the "Graphics function." The name is important as it distinguishes it from conventional bit image functions.  
* The graphics functions provided here maintain upward compatibility with conventional bit image processing.

| Graphics type   | Corresponding bit image command (*1) |
|-----------------|--------------------------------------|
| NV graphics     | FS p, FS q                           |
| Download graphics | GS *, GS /                         |
| Graphics        | GS Q 0, GS v 0                       |

(*1) These commands are supported by some of the printer models but will not be supported by future models.

* The various graphics functions (of this command), more user-friendly than conventional bit image functions, offer the following advantages.  
* Definition of multiple items of logo mark and insignia data (with most functions).  
* Management of data using key codes.  
* Deletion of and redefinition of data per key code.  
* Color coding of image-data.  
* Definition of image-data in both raster and column formats.  
* Confirmation of available capacity in domain.  
* Continuous processing possible (without a software reset when a command has been processed).  
* The following three types of graphics functions are included.  
* NV graphics [Functions 48, 51, 64, 65, 66, 67, 68, and 69] Stores data in non-volatile memory.  
Defined data is retained when power is turned off.  
There is a limit on the number of times that non-volatile memory can be written to.  
* Download graphics [Functions 52, 80, 81, 82, 83, 84, and 85] Stores data in volatile memory (RAM).  
Defined data is lost when the ESC @ command is executed, the system is reset, or power is turned off.  
* Graphics [Functions 50, 112, and 113] Stores data in the print buffer.  
When standard mode is selected, prints data using Function 50 and clears the print buffer.  
When page mode is selected, prints data using FF and ESC FF and clears the print buffer after FF is executed.

**[Notes]**  
• The functions of this command are determined by the (fn) setting. Actual command operation varies according to function.  
• The NV graphics and download graphics data is managed using key codes.  
• Expressed as kc1 and kc2, the key codes are used to identify data groups.  
• The key codes have a 2-byte configuration and can be specified using the full range of character codes in Hexadecimal: 20H to 7EH / in Decimal: 32 to 126.  
• The data referred to here is image data specified using d1 through dk of Functions 67, 68, 83, and 84.  
• The printer automatically adds control information when it stores the data. The image data domain is used as the control information. Control information formats and data values vary according to function.  
• Note that it is not possible to create definitions for both NV graphics data (this command) and NV bit image data (FS q). NV bit image data definitions are deleted when this command is used.  
• Note that it is not possible to create definitions for both download graphics data (this command) and download bit image data (GS *). Download bit image data definitions are deleted when this command is used.  
• With certain printers, it is not possible to create definitions for both download graphics data (this command) and download character data (ESC &).  
• Defined download character data is deleted when this command is used.  
• Executing ESC & deletes download graphics data.  
• Always execute Function 50 after executing this command 112 or 113 when the standard mode is selected.  
• When printing the various types of graphics data, using the ESC U command will ensure that the printed results are properly aligned vertically by printing in a single direction.  
• Functions 65, 66, 67, or 68 write data to a non-volatile memory. Note the following items when using the function.  
• Do not turn off the power or reset the printer from the interface when the relevant functions are being executed.  
• The printer may be BUSY when storing data and will not receive any data. In this case, be sure not to transmit data from the host.  
• Excessive use of this function may destroy the non-volatile memory. As a guideline, do not use any combination of the following commands more than 10 times per day for writing data to the nonvolatile memory: GS ( A (part of functions), GS ( C (part of functions), GS ( E (part of functions), GS ( L / GS 8 L (part of functions), GS ( M (part of functions), GS g 0, FS q 1, FS q.  
• The following restrictions apply when performing non-volatile memory operations (including data store and delete).  
• The paper cannot be fed by paper feed switch.  
• The real time command is not processed.  
• The ASB status will not be sent, even when the ASB function is set to enable.

**[Notes for transmission process]**  
* Data send operations are performed using Functions 48, 51, 52, 64, and 80. When you use these functions, obey the following rules.  
* When the host PC transmits the function data, transmit the next data after receiving the corresponding data (Header ^ NULL) from the printer.  
* When operating with a serial interface, be sure to configure operation so that the host computer uses the printer only when it is READY.  
* When operating with a parallel interface, the data sent by this function (starting with Header and ending with NUL), as with other data, is first stored in the send buffer, then output in sequential order when the host computer changes to the reverse mode. Note that the send buffer capacity is 99 bytes, and any data exceeding this volume limit will be lost; therefore, when using this command, it is important to configure the operation so that the host computer's change to the reverse mode and the subsequent status send/receive process is performed quickly.  
* During the interval between the sending of the data header and NUL, ASB status and the real time commands are rendered invalid.  
* When communication with the printer uses XON/XOFF control with serial interface, the XOFF code may interrupt the "Header to NUL" data string.  
* The information for each function can be identified to other transmission data according to specific data of the transmission data block. When the header transmitted by the printer is [hex = 37H/decimal =55], treat NUL [hex = 00H/decimal =0] as a data group and identify it according to the combination of the header and the identifier.

**[Notes for ESC/POS Handshaking Protocol]**  
* It will be necessary to perform the ESC/POS Handshaking Protocol procedures listed below when using Functions 64 and 80.

| Procedure | Host operation               | Printer operation            |
|-----------|------------------------------|------------------------------|
| 1         | This command sends Function 64. | Function 64 is initiated.   |
| 2         | Data is received from printer. | Key code list is sent.      |
| 3         | Response code (*1) is sent.  | Procedures (*2 and *3) are performed according to response code. |

(*1) Response Code

| ASCII | Hexadecimal | Decimal | Request definition          |
|-------|-------------|---------|-----------------------------|
| ACK   | 06          | 6       | Send next data group.       |
| NAK   | 15          | 21      | Resend just-received data group. |
| CAN   | 18          | 24      | Cancel send operation.      |

(*2) Processing According to Response Code

| Code | Description                        |
|------|------------------------------------|
| ACK  | Initiates operation to send next data. |
| NAK  | Resends the just-received data.   |
| CAN  | Cancels processing initiated by this command. |

(*3) Processing According to Response Code (When No More Send Data Remains (indicated by identification status of send data group))

| Response | Description                        |
|----------|------------------------------------|
| ACK, CAN | Cancels procedure initiated by this command. |
| NAK      | Resends the just-received data.   |

* When codes other than the ACK, NAK, or CAN codes are received, the CAN procedure is executed.

### GS 8 L p1 p2 p3 p4 m fn a kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b

**[Name]** Define the NV graphics data (raster format).

**[Format]**  
ASCII GS ( L pL pH m fn a kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b 4C pL pH 30 43 30 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Hex 1D 28 76 pL pH 48 67 48 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Decimal 29 40 L p1 p2 p3 p4 m fn a kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
ASCII GS 8 4C p1 p2 p3 p4 30 43 30 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Hex 1D 38 76 p1 p2 p3 p4 48 67 48 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Decimal 29 56

**[Range]**  
12 ≤ (pL + pH × 256) ≤ 65535 (0 ≤ pL ≤ 255, 0 ≤ pH ≤ 255)  

When using GS 8 L:  
12 ≤ (p1 + p2 × 256 + p3 × 65536 + p4 × 16777216) ≤ 4294967295 m = 48, fn = 67, a = 48  
32 ≤ kc1 ≤ 126  
32 ≤ kc2 ≤ 126  
b = 1, 2  
1 ≤ (xL + xH × 256) ≤ 8192 (0 ≤ xL ≤ 255, 0 ≤ xH ≤ 32)  
1 ≤ (yL + yH × 256) ≤ 2304 (0 ≤ yL ≤ 255, 0 ≤ yH ≤ 9)  
c = 49, 50 (when using recommended two-color paper)  
C=49 (when using recommended solid color paper)  
0 ≤ d ≤ 255  
k = int((xL + xH × 256) + 7)/8 × (yL + yH × 256)  
b=1 (when monochrome printing control is selected)  
b = 1, 2 (When selecting dual color printing control)

**[Description]**  
Defines the NV graphics data (raster format) as a record specified by the key codes (kc1 and kc2) in the NV graphics area.  
• b specifies the number of colors for the defined data.  
• xL and xH specify the number of dots in the horizontal direction as (xL + xH × 256).  
• yL and yH specify the number of dots in the vertical direction as (yL + yH × 256).

| c  | Color specifications |
|----|----------------------|
| 49 | Color 1              |
| 50 | Color 2              |

d specifies the defined data (raster format).  
k indicates the number of the definition data. k is an explanation parameter; therefore it does not need to be transmitted.

**[Notes]**  
In cases where the specified key code already exists in memory, it will be necessary to overwrite the data.  
NV graphics indicate image data groups defined in the printer's internal non-volatile memory. Data definitions for NV graphics data created using this command are valid until redefined by this function or <Function 68>.  
The functions used to define NV graphics data are this function and Function 68. Even with printer models that support both, it is recommended that only one of the functions be used for data definition tasks.  
• The two functions differ only in that one function (this function) defines data in raster format, while the other (Function 68) defines data in column format. The domains and control information are identical.  
• In cases where the key code specified by this function coincides with a key code being used by Function 68, a new data definition is created.  
Use this function at the beginning of the line when the standard mode is selected.  
This function is incompatible with macros, so make sure to avoid including it when defining macros.  
In cases where there is insufficient capacity available for storing NV graphics data, this function cannot be used. Use Function 51 to confirm the available capacity in the NV graphics data area.  
One option is to delete items of NV graphics data that were previously defined to the same key code.  
The data for byte k of d1 ... dk is processed as a single item of defined NV graphics data. The defined data (d) specifies "1" for bits corresponding to dots that will be printed and "0" for bits corresponding to dots that will not be printed.  
NV graphics data is defined using the dot density set by Function 49.  
Specify single data groups [c d1 ... dk] when monochrome is selected (b = 1) as the color.  
Specify b number of data groups [c d1 ... dk] when multiple colors are selected (b ≠ 1). It is also important to specify different colors in units of data groups when specifying color (c).  
NV graphics data is printed using Function 69.  
Note that it is not possible to create definitions for both NV graphics data (this command) and NV bit image data (FS q). NV bit image data definitions are deleted when this command is used.  
The relationship between NV graphics data (raster format) and print results is shown in the table below.

| d1   | d2   | ... | dx   |
|------|------|-----|------|
| dx+1 | dx+2 | ... | dx+2 |
| ...  | ...  | ... | ...  |
| ...  | dk-2 | dk-1| dk   |

X = (xL + xH × 256)  
MSB LSB  
MSB LSB  
MSB LSB  
MSB LSB

### GS 8 L p1 p2 p3 p4 m fn a kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b

**[Name]** Define the NV graphics data (column format).

**[Format]**  
ASCII GS ( L pL pH m fn a kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b 4C pL pH 30 44 30 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Hex 1D 28 76 pL pH 48 68 48 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Decimal 29 40 ASCII GS 8 L p1 p2 p3 p4 m fn a kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Hex 1D 38 4C p1 p2 p3 p4 30 44 30 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b  
Decimal 29 56 76 p1 p2 p3 p4 48 68 48 kc1 kc2 b xL xH yL yH [c d1...dk]1...[c d1...dk]b

**[Range]**  
12 ≤ (pL + pH × 256) ≤ 65535 (0 ≤ pL ≤ 255, 0 ≤ pH ≤ 255)  

When using GS 8 L:  
12 ≤ (p1 + p2 × 256 + p3 × 65536 + p4 × 16777216) ≤ 4294967295 m = 48, fn = 68, a = 48  
32 ≤ kc1 ≤ 126  
32 ≤ kc2 ≤ 126  
0 ≤ d ≤ 255  
k = (xL + xH × 256) × (int((yL + yH × 256) + 7)/8)

**[Description]**  
Defines the NV graphics data (column format) as a record specified by the key codes (kc1 and kc2) in the NV graphics area.  
* b specifies the number of colors for the defined data.  
* xL and xH specify the number of dots in the horizontal direction as (xL + xH × 256).  
* yL and yH specify the number of dots in the vertical direction as (yL + yH × 256).  
* c specifies the color of the defined data.

| c  | Color specifications |
|----|----------------------|
| 49 | Color 1              |
| 50 | Color 2              |
| 51 | Color 3              |

* d specifies the defined data (column format).  
k indicates the number of the definition data. k is an explanation parameter; therefore it does not need to be transmitted.

**[Notes]**  
* In cases where the specified key code already exists in memory, it will be necessary to overwrite the data.  
* NV graphics indicate image data groups defined in the printer's internal non-volatile memory. Data definitions for NV graphics data created using this command are valid until redefined by this function or <Function 67>.  
* The functions used to define NV graphics data are this function and Function 67. Even with printer models that support both, it is recommended that only one of the functions be used for data definition tasks.  
* The two functions differ only in that one function (this function) defines data in raster format, while the other (Function 67) defines data in column format. The domains and control information are identical.  
* In cases where the key code specified by this function coincides with a key code being used by Function 67, a new data definition is created.  
Use this function at the beginning of the line when the standard mode is selected.  
This function is incompatible with macros, so make sure to avoid including it when defining macros.  
* In cases where there is insufficient capacity available for storing NV graphics data, this function cannot be used. Use Function 51 to confirm the available capacity in the NV graphics data area.  
* One option is to delete items of NV graphics data that were previously defined to the same key code.  
* The data for byte k of d1 ... dk is processed as a single item of defined NV graphics data. The defined data (d) specifies "1" for bits corresponding to dots that will be printed and "0" for bits corresponding to dots that will not be printed.  
* NV graphics data is defined using the dot density set by Function 49.  
* Specify single data groups [c d1 ... dk] when monochrome is selected (b = 1) as the color.  
* Specify b number of data groups [c d1 ... dk] when multiple colors are selected (b ≠ 1). It is also important to specify different colors in units of data groups when specifying color (c).  
* NV graphics data is printed using Function 69.  
* Note that it is not possible to create definitions for both NV graphics data (this command) and NV bit image data (FS q). NV bit image data definitions are deleted when this command is used.  
* The relationship between NV graphics data (column format) and print results is shown in the table below.

| d1 | dv+1 | ... | :    | MSB |
|----|------|-----|------|-----|
| d2 | dv+2 | ... | dk-2 | LSB |
| :  | :    | ... | dk-1 | MSB |
| dv | dvx2 | ... | dk   | LSB |

Y = (yL + yH × 256)